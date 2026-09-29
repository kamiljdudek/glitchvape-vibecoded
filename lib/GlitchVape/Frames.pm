package GlitchVape::Frames;

use strict;
use warnings;

use File::Spec ();
use POSIX      ();

use GlitchVape::Animate   ();
use GlitchVape::Context   ();
use GlitchVape::IO        ();
use GlitchVape::Watermark ();
use GlitchVape::Workers   ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Frames - render every frame of a loop, several at a time

=head1 SYNOPSIS

    my $done = GlitchVape::Frames::render(
        load      => sub { GlitchVape::IO::load( $path, max_dim => 720 ) },
        pipeline  => $pipeline,
        seed      => 1337,
        frames    => 24,
        dir       => $frame_dir,
        cachedir  => $cache_dir,
        on_frame  => sub { my ( $done, $total ) = @_ },
    );

    GlitchVape::Animate::encode( frames => $done->{ paths }, ... );

=head1 DESCRIPTION

The one loop that renders frames, for the export and the window's preview
alike: they used to have a copy each.

=head2 The frames are rendered in parallel, because nothing joins them

Every frame is computed from the seed and its own position in the loop and
from nothing else -- C<stars> and C<defrag> are written that way precisely so
that no frame needs the one before it. So a loop is as many independent
renders as it has frames, and on a machine with cores to spare they are shared
out between worker processes. On four cores a twenty-four frame loop takes a
third of the time it took in one process, which is the difference between
waiting a minute for a preview and waiting twenty seconds.

The workers are forked I<before> anything is decoded, and each decodes the
source for itself -- the one thing that cannot be done is decode it once here
and fork afterwards, for the reason L<GlitchVape::Workers> gives. Where this
process is already past that point, having decoded something or started a
thread of any kind, the frames are rendered here, one after another, exactly
as they always were. So are they when there is one core, or one frame, or the
caller asked for C<< jobs => 1 >>.

Each worker claims the next frame nobody has claimed, by making a directory
named after it -- which either succeeds or does not, whoever else is trying --
so a worker that draws the expensive frames does not hold the others up.

Which process renders a frame makes no difference to it. The frames come out
the same either way, and F<t/50-frames.t> holds the two to that.

=head2 Frames are PPM

A frame is written once and read once, by ffmpeg, a moment later. As PNG it
spent a quarter of a second at 1920 pixels being compressed for that, which is
six seconds of a twenty-four frame export; as PPM it is the pixels with a line
of header.

=head2 Stopping

A caller that is stopped with C<TERM> -- the window cancelling a preview --
takes its workers with it: the handler here passes the signal on to them
before doing whatever the caller's own handler does. A worker whose parent has
gone anyway stops at the next frame rather than finishing a loop nobody will
encode.

=head2 render( %arg )

    load      => sub { image }   the source, decoded; called once per process
    pipeline  => GlitchVape::Pipeline
    seed      => scalar
    frames    => N
    dir       => path            where the frames go
    cachedir  => path            shared by every frame; see Context
    source    => path            what $ctx->source reports
    watermark => spec            GlitchVape::Watermark::apply's
    fit       => [ W, H ]        applied as each frame is written
    verbose   => bool
    jobs      => N               at most this many processes; default one
                                 per core
    on_frame  => sub { my ( $done, $total ) = @_ }

Returns C<< { paths => [ ... ], dims => [ W, H ], timings => [ ... ] } >>:
the frames in order, the size they came out at, and the per-effect timings of
frame 0.

=cut

sub render
{
    my ( %arg ) = @_;

    my $frames = $arg{ frames } or die "GlitchVape::Frames: no frame count\n";

    my $jobs = _jobs( \%arg );

    my $timings;
    if ( $jobs > 1 )
    {
        $timings = _parallel( \%arg, $jobs );
    }
    else
    {
        $timings = _serial( \%arg );
    }

    my @paths =
        map { GlitchVape::Animate::frame_path( $arg{ dir }, $_ ) }
        0 .. $frames - 1;

    return {
        paths   => \@paths,
        dims    => [ _ppm_size( $paths[ 0 ] ) ],
        timings => $timings || [],
    };
}

# How many processes: what was asked for, or a core each, but never more than
# there are frames -- and one whenever forking here is not safe.
sub _jobs
{
    my ( $arg ) = @_;

    my $jobs = $arg->{ jobs } // GlitchVape::Workers::cpus();
    $jobs = $arg->{ frames } if $jobs > $arg->{ frames };

    return 1 if $jobs <= 1;
    return 1 unless GlitchVape::Workers::fork_safe();

    return $jobs;
}

sub _serial
{
    my ( $arg ) = @_;

    my $source = $arg->{ load }->();
    my $timings;

    for my $n ( 0 .. $arg->{ frames } - 1 )
    {
        my $took = _frame( $arg, $source, $n );
        $timings = $took if $n == 0;

        _report( $arg, $n + 1 );
    }

    return $timings;
}

sub _parallel
{
    my ( $arg, $jobs ) = @_;

    my $claims = File::Spec->catdir( $arg->{ dir }, '.claimed' );
    mkdir $claims or die "GlitchVape::Frames: cannot create $claims: $!\n";

    # Shared out, so the workers together use the cores and no more.
    my $threads = int( GlitchVape::Workers::cpus() / $jobs ) || 1;

    pipe my $read, my $write
        or die "GlitchVape::Frames: cannot open a pipe: $!\n";

    my @pids;
    my $parent = $$;

    for my $k ( 1 .. $jobs )
    {
        my $pid = fork;

        unless ( defined $pid )
        {
            my $why = $!;
            kill 'TERM', map { -$_ } @pids;
            waitpid $_, 0 for @pids;
            die "GlitchVape::Frames: cannot fork a frame worker: $why\n";
        }

        unless ( $pid )
        {
            close $read;
            POSIX::setpgid( 0, 0 );
            _worker( $arg, $k, $threads, $claims, $write, $parent );

            # Not reached: _worker never returns.
            POSIX::_exit( 70 );
        }

        # Each worker leads a process group of its own, so that stopping it
        # stops the magick it may be waiting on as well -- which otherwise
        # runs on after it and complains, to whoever is watching stderr, that
        # its scratch directory has gone. Set from both sides of the fork,
        # which is the usual way of not caring which side runs first.
        POSIX::setpgid( $pid, $pid );
        push @pids, $pid;
    }

    close $write;

    # Pass a TERM or an INT on to the workers, then do whatever was going to
    # be done with it anyway -- in the window's render child that is to exit,
    # and a worker left behind would go on rendering a preview nobody wants.
    # INT as well because the workers are in groups of their own, and a ^C at
    # the terminal reaches only the foreground group.
    my $stop = sub {
        kill 'TERM', map { -$_ } @pids;
    };

    my %previous = map { $_ => $SIG{ $_ } } qw(TERM INT);
    local $SIG{ TERM } =
        sub { $stop->(); _pass_on( 'TERM', $previous{ TERM } ) };
    local $SIG{ INT } = sub { $stop->(); _pass_on( 'INT', $previous{ INT } ) };

    my $done   = 0;
    my $failed = 0;

    while ( my $line = <$read> )
    {
        if ( $line =~ /^ok\b/ )
        {
            $done++;
            _report( $arg, $done );
            next;
        }

        # One worker failing is the render failing, and the others need not
        # finish their frames first.
        $failed = 1;
        $stop->();
        last;
    }

    close $read;

    my @failed_workers;
    for my $k ( 1 .. @pids )
    {
        waitpid $pids[ $k - 1 ], 0;
        push @failed_workers, $k if $? != 0;
    }

    if ( $failed || @failed_workers || $done != $arg->{ frames } )
    {
        die _worker_error( $arg, @failed_workers )
            // "GlitchVape::Frames: a frame worker failed\n";
    }

    return _read_timings( $arg );
}

# Do with a signal what would have been done with it had render() not been
# listening: the caller's own handler, or the default, which is to go.
sub _pass_on
{
    my ( $signal, $previous ) = @_;

    if ( ref $previous eq 'CODE' )
    {
        $previous->( $signal );
        return;
    }

    return if defined $previous && $previous eq 'IGNORE';

    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $SIG{ $signal } = 'DEFAULT';
    ## use critic
    kill $signal, $$;

    return;
}

sub _worker
{
    my ( $arg, $k, $threads, $claims, $write, $parent ) = @_;

    # Scratch files go under the frame directory rather than the system's,
    # so that whoever removes the frames removes them too. A worker told to
    # stop can then simply go: not by dying, because a signal that lands
    # while a destructor runs turns the die into a warning and the worker
    # carries on drawing; and not by clearing up first, because the magick it
    # may be waiting on is still reading from that directory and would say
    # so.
    my $scratch = File::Spec->catdir( $arg->{ dir }, ".worker-$k" );
    mkdir $scratch;
    local $ENV{ TMPDIR } = $scratch;

    local $SIG{ TERM } = sub { POSIX::_exit( 143 ) };

    my $ok = eval {
        GlitchVape::Workers::limit_threads( $threads );

        my $source = $arg->{ load }->();

        for my $n ( 0 .. $arg->{ frames } - 1 )
        {
            next unless mkdir File::Spec->catdir( $claims, $n );

            # Orphaned: whoever wanted these frames has gone.
            last if getppid() != $parent;

            my $took = _frame( $arg, $source, $n );
            _write_timings( $arg, $took ) if $n == 0;

            syswrite $write, "ok $n\n";
        }

        1;
    };

    unless ( $ok )
    {
        my $err = $@ || 'unknown error';
        _write_error( $arg, $k, $err );
        syswrite $write, "fail $k\n";
        POSIX::_exit( 1 );
    }

    # _exit, not exit: this is a fork of whoever called render(), and their
    # END blocks and temporary directories are theirs to run and remove.
    POSIX::_exit( 0 );
}

# One frame, rendered and written. Returns its per-effect timings.
sub _frame
{
    my ( $arg, $source, $n ) = @_;

    my $ctx = GlitchVape::Context->new(
        image    => $source->Clone,
        source   => $arg->{ source },
        seed     => $arg->{ seed },
        verbose  => $arg->{ verbose },
        cachedir => $arg->{ cachedir },
    );
    $ctx->frames( $arg->{ frames } );
    $ctx->frame( $n );

    $arg->{ pipeline }->run( $ctx );

    # Every frame, or the encoder is handed two shapes: the bar makes the
    # picture taller and a loop whose first frame alone had one would not
    # encode at all.
    $ctx->image(
        GlitchVape::Watermark::apply( $ctx->image, $arg->{ watermark } ) )
        if $arg->{ watermark };

    # Rounded to eight bits here, which is what the PNG writer did to a frame
    # when frames were PNG: the pipeline leaves fractional sixteen-bit values
    # behind, and the PNM writer rounds those its own way, a level apart from
    # PNG's on a quarter of the pixels of some presets. Done here, the encoder
    # is handed what it always was -- and an encode is eight bits whatever it
    # is given.
    $ctx->image->Set( depth => 8 );

    # Frames keep the blunt strip. They are intermediate files that exist for
    # as long as the encode takes, and a per-frame exiftool run would be
    # twenty-four subprocesses to scrub something nobody will read.
    GlitchVape::IO::save(
        $ctx->image, GlitchVape::Animate::frame_path( $arg->{ dir }, $n ),
        quality => 100,
        strip   => 1,
        fit     => $arg->{ fit },
    );

    return [ $ctx->timings ];
}

sub _report
{
    my ( $arg, $done ) = @_;

    warn sprintf( "  frame %d/%d\n", $done, $arg->{ frames } )
        if $arg->{ verbose };

    $arg->{ on_frame }->( $done, $arg->{ frames } ) if $arg->{ on_frame };

    return;
}

sub _write_timings
{
    my ( $arg, $timings ) = @_;

    my $path = File::Spec->catfile( $arg->{ dir }, '.timings' );
    open my $fh, '>', $path or return;
    printf { $fh } "%s\t%s\n", @$_ for @$timings;
    close $fh;

    return;
}

sub _read_timings
{
    my ( $arg ) = @_;

    my $path = File::Spec->catfile( $arg->{ dir }, '.timings' );
    open my $fh, '<', $path or return [];
    my @lines = <$fh>;
    close $fh;

    chomp @lines;
    return [ map { [ split /\t/ ] } @lines ];
}

sub _write_error
{
    my ( $arg, $k, $err ) = @_;

    my $path = File::Spec->catfile( $arg->{ dir }, ".worker-$k.err" );
    open my $fh, '>', $path or return;
    print { $fh } $err;
    close $fh;

    return;
}

# The first failed worker's own message, which is the error the render would
# have died with in one process. A worker stopped because another failed
# leaves none, so what is found is the one that started it.
sub _worker_error
{
    my ( $arg, @failed ) = @_;

    my @messages;
    for my $k ( @failed )
    {
        my $path = File::Spec->catfile( $arg->{ dir }, ".worker-$k.err" );
        open my $fh, '<', $path or next;
        my $text = do { local $/ = undef; <$fh> };
        close $fh;

        push @messages, $text if defined $text && length $text;
    }

    return $messages[ 0 ];
}

# Width and height from a PPM's header, which is all this process may read of
# the frame: see GlitchVape::Workers.
sub _ppm_size
{
    my ( $path ) = @_;

    open my $fh, '<:raw', $path or return ();
    read $fh, my $head, 512;
    close $fh;

    $head =~ s/#[^\n]*\n//g;
    my ( $w, $h ) = $head =~ /^P[36]\s+(\d+)\s+(\d+)/ or return ();

    return ( $w, $h );
}

1;
