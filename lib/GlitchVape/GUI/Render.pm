package GlitchVape::GUI::Render;

use strict;
use warnings;

use File::Spec ();
use POSIX      ();

use GlitchVape::Context    ();
use GlitchVape::GUI::Cache ();
use GlitchVape::IO         ();
use GlitchVape::Pipeline   ();
use GlitchVape::Tools      ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Render - background rendering for the interface

=head1 WHY A CHILD PROCESS

A preview of this photograph takes 1.9 seconds at 512 pixels and 8 seconds at
full size. Running that on the main loop would freeze the window for the whole
render, so every render happens in a forked child and the parent is woken by
C<< Glib::Child->watch_add >> when it exits.

Fork rather than threads because PerlMagick is not thread-safe.

=head1 THE PARENT MUST NOT TOUCH IMAGEMAGICK

ImageMagick is built with OpenMP, and a render here uses about three cores.
An OpenMP thread pool does not survive C<fork>: the child inherits the pool's
mutexes in whatever state they were in, but none of the threads that would
release them, so the first parallel operation in the child deadlocks and never
returns.

Caching the decoded source in the parent -- the obvious optimisation, worth
0.4 seconds of HEIC decoding per render -- is therefore exactly the thing that
cannot be done. Every image operation happens in a child that has never
forked, and the parent process never loads an image at all.

The consolation is that this makes the preview more honest rather than less:
it reads the source from disk through C<GlitchVape::IO::load> at the preview
size, which is the same call the command-line tool makes, so a preview differs
from the export only in the size it was rendered at.

=head1 TWO PATHS, DELIBERATELY

=over 4

=item Preview

Builds a L<GlitchVape::Pipeline> from the state's resolved parameters and runs
it at the preview size. Approximate only in scale: effects are pixel-scale
dependent, so a 720-pixel preview of C<grain> or C<scanlines> is a fair
impression of the full-size render rather than a crop of it.

=item Export

Calls L<GlitchVape/render> -- the same function F<bin/glitchvape> calls, with
arguments in the same shape. Not a parallel implementation that ought to
agree with the command-line tool, but the command-line tool's own code path.

=back

=cut

=head2 new( %arg )

    cache => GlitchVape::GUI::Cache

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $self = bless {
        cache  => $arg{ cache },
        source => undef,
        job    => undef,
    }, $class;

    return $self;
}

sub cache { $_[ 0 ]{ cache } }

=head2 source( $path )

Adopt an image. Returns C<< ( width, height ) >> as the pipeline will see
them, or an empty list if they could not be determined -- which is not fatal,
since it only affects what the title bar says.

The file is B<not> decoded here. See L</THE PARENT MUST NOT TOUCH IMAGEMAGICK>:
the dimensions come from a separate C<magick> process instead.

=cut

sub source
{
    my ( $self, $path ) = @_;

    die "GlitchVape: no such file: $path\n" unless -f $path;

    $self->{ source } = $path;

    return _probe_dims( $path );
}

sub source_path { $_[ 0 ]{ source } }

# Dimensions after EXIF rotation, which is what every later stage works in:
# an iPhone HEIC is stored landscape with a rotation flag, so the stored size
# is the wrong way round for a portrait photograph.
#
# -auto-orient in a subprocess, rather than Image::Magick's AutoOrient in this
# one, for the reason given at the top of this file.
sub _probe_dims
{
    my ( $path ) = @_;

    my @argv = eval {
        GlitchVape::Tools::magick_argv( $path, '-auto-orient', '-format',
            '%w %h', 'info:' );
    };
    return () unless @argv;

    my $out = GlitchVape::Tools::capture( @argv );
    return () unless defined $out;

    my ( $w, $h ) = $out =~ /^(\d+)\s+(\d+)/;
    return () unless defined $h;

    return ( $w, $h );
}

=head2 busy()

Whether a render is in flight.

=cut

sub busy { return defined $_[ 0 ]{ job } }

=head2 cancel()

Abandon the running render. The child is signalled and its result discarded;
the callbacks for that job never fire.

Called whenever the user applies a change while a render is still going, which
during a slider-heavy session is most of the time.

=cut

sub cancel
{
    my ( $self ) = @_;

    my $job = $self->{ job } or return 0;

    $self->{ job }      = undef;
    $job->{ cancelled } = 1;

    kill 'TERM', $job->{ pid };

    return 1;
}

=head2 preview( %arg )

    state    => GlitchVape::GUI::State
    size     => N                        longest edge of the render
    animate  => { frames, fps }          render a loop instead of a still
    on_done  => sub { my ( $path ) = @_ }
    on_error => sub { my ( $message ) = @_ }

Returns the cache key. When that key is already on disk the render is skipped
and C<on_done> fires from an idle callback -- from the caller's point of view
a cache hit and a real render behave identically, they just differ in how long
they take. That is what makes undo instant: a state on the history stack has
been rendered before.

=cut

sub preview
{
    my ( $self, %arg ) = @_;

    my $state = $arg{ state };
    my $size  = $arg{ size } || 720;
    my $spec  = $arg{ animate };

    my $suffix = '.png';
    if ( $spec )
    {
        $suffix = '.mp4';
    }

    my $key = $state->cache_key( size => $size, animate => $spec );

    return $key if $self->_serve_cached( $key, $suffix, \%arg );

    my $config = $state->pipeline_config;

    # Built in the parent so that a bad parameter is reported as an error the
    # user can act on, rather than as a child that exited non-zero.
    my $pipeline = eval {
        GlitchVape::Pipeline->new(
            effects => $config->{ effects },
            order   => $config->{ order },
            disable => $config->{ disable },
        );
    };

    if ( my $err = $@ )
    {
        $err =~ s/\s+\z//;
        Glib::Idle->add(
            sub {
                $arg{ on_error }->( $err ) if $arg{ on_error };
                return 0;
            }
        );
        return undef;
    }

    my $staged = $self->{ cache }->scratch( $suffix );

    $self->_spawn(
        key      => $key,
        suffix   => $suffix,
        staged   => $staged,
        on_done  => $arg{ on_done },
        on_error => $arg{ on_error },
        work     => sub {
            $self->_render_preview(
                pipeline => $pipeline,
                seed     => $state->seed,
                size     => $size,
                animate  => $spec,
                output   => $staged,
            );
        },
    );

    return $key;
}

=head2 source_preview( %arg )

    size     => N
    on_done  => sub { my ( $path, $cached ) = @_ }
    on_error => sub { my ( $message ) = @_ }

The source as it is, with no pipeline at all -- what the interface shows the
moment a file is opened, so that opening a photograph puts the photograph on
the screen rather than a placeholder telling you to press a button.

Cheap enough to be worth doing unasked: with nothing to run there is only the
decode and the downscale, which is a fraction of a real preview even on a
twelve-megapixel HEIC. It goes through the same child process and the same
cache as everything else, so reopening a file is a lookup.

Deliberately not the preset's render. A preset may be eight seconds of work,
and the point of this is to be immediate; the preset is what Apply is for.

=cut

sub source_preview
{
    my ( $self, %arg ) = @_;

    my $size = $arg{ size } || 720;

    my $key = $self->source_key( $size );
    return $key unless defined $key;

    return $key if $self->_serve_cached( $key, '.png', \%arg );

    my $staged = $self->{ cache }->scratch( '.png' );

    # An empty pipeline rather than a special case in the child: run() over no
    # effects does nothing, and the load and save either side are the same
    # calls a real preview makes.
    my $pipeline = GlitchVape::Pipeline->new( effects => {} );

    $self->_spawn(
        key      => $key,
        suffix   => '.png',
        staged   => $staged,
        on_done  => $arg{ on_done },
        on_error => $arg{ on_error },
        work     => sub {
            $self->_render_preview(
                pipeline => $pipeline,
                seed     => 0,
                size     => $size,
                output   => $staged,
            );
        },
    );

    return $key;
}

=head2 source_key( $size )

Where an untouched render of the current source lives. The file's size and
modification time are folded in, so editing the photograph outside the
application does not serve its previous contents back.

=cut

sub source_key
{
    my ( $self, $size ) = @_;

    my $source = $self->{ source };
    return undef unless defined $source;

    my @stat = stat $source;

    return GlitchVape::GUI::Cache->key(
        'glitchvape-source-v1',
        $source,
        $stat[ 7 ],
        $stat[ 9 ], $size
    );
}

# A render already on disk is delivered from an idle callback rather than
# returned, so that a cache hit and a real render look identical to the
# caller and differ only in how long they take.
sub _serve_cached
{
    my ( $self, $key, $suffix, $arg ) = @_;

    return 0 unless $self->{ cache }->has( $key, $suffix );

    my $path = $self->{ cache }->preview_path( $key, $suffix );

    Glib::Idle->add(
        sub {
            $arg->{ on_done }->( $path, 1 ) if $arg->{ on_done };
            return 0;
        }
    );

    return 1;
}

=head2 export( %arg )

    state    => GlitchVape::GUI::State
    output   => path
    max_dim  => N                    full-size limit, default from the preset
    animate  => { frames, fps }
    quality  => N
    optimise => bool
    on_done  => sub { my ( $path ) = @_ }
    on_error => sub { my ( $message ) = @_ }

Renders at full size to a file the user chose. Goes through
L<GlitchVape/render>, reading the source from disk exactly as the command-line
tool does, so the export is reproducible from the seed with C<glitchvape>
alone.

=cut

sub export
{
    my ( $self, %arg ) = @_;

    my $state  = $arg{ state };
    my $output = $arg{ output };

    my %render = $state->render_args(
        output   => $output,
        animate  => $arg{ animate },
        quality  => $arg{ quality },
        optimise => $arg{ optimise },
    );

    if ( defined $arg{ max_dim } )
    {
        $render{ max_dim } = $arg{ max_dim };
    }

    $self->_spawn(
        key      => undef,
        final    => $output,
        on_done  => $arg{ on_done },
        on_error => $arg{ on_error },
        work     => sub {
            GlitchVape::render( %render );
        },
    );

    return $output;
}

# ---------------------------------------------------------------------------

# The preview pipeline. Everything here runs in the child, including the
# decode: the parent has never loaded an image and must not start now.
sub _render_preview
{
    my ( $self, %arg ) = @_;

    if ( my $spec = $arg{ animate } )
    {
        return $self->_render_preview_loop( %arg, animate => $spec );
    }

    my $img =
        GlitchVape::IO::load( $self->{ source }, max_dim => $arg{ size } );

    my $ctx = GlitchVape::Context->new(
        image  => $img,
        source => $self->{ source },
        seed   => $arg{ seed },
    );

    $arg{ pipeline }->run( $ctx );

    GlitchVape::IO::save( $ctx->image, $arg{ output }, quality => 92 );

    return $arg{ output };
}

sub _render_preview_loop
{
    my ( $self, %arg ) = @_;

    require GlitchVape::Animate;

    my $spec   = $arg{ animate };
    my $frames = $spec->{ frames } || 24;
    my $fps    = $spec->{ fps }    || 12;

    my $dir = $self->{ cache }->scratch_dir( 'frames' );

    # Decoded once for the whole loop. Safe here in a way it is not in the
    # parent: this process has already forked and will not fork again.
    my $source =
        GlitchVape::IO::load( $self->{ source }, max_dim => $arg{ size } );

    my @paths;
    for my $n ( 0 .. $frames - 1 )
    {
        my $ctx = GlitchVape::Context->new(
            image  => $source->Clone,
            source => $self->{ source },
            seed   => $arg{ seed },
        );
        $ctx->frames( $frames );
        $ctx->frame( $n );

        $arg{ pipeline }->run( $ctx );

        my $path = GlitchVape::Animate::frame_path( $dir, $n );
        GlitchVape::IO::save( $ctx->image, $path, quality => 100, strip => 1 );
        push @paths, $path;
    }

    # The track goes into the preview as well as into the export. It is the
    # part of an animation that cannot be judged by looking at a still, so a
    # preview without it would be answering a question nobody asked.
    GlitchVape::Animate::encode(
        frames => \@paths,
        output => $arg{ output },
        fps    => $fps,
        loop   => 1,
        audio  => $spec->{ audio },
    );

    return $arg{ output };
}

# Fork, run $work, and arrange for the outcome to come back on the main loop.
sub _spawn
{
    my ( $self, %job ) = @_;

    $self->cancel if $self->busy;

    my $errfile = $self->{ cache }->scratch( '.err' );

    my $pid = fork;

    unless ( defined $pid )
    {
        my $why = "GlitchVape: cannot fork a render process: $!";
        Glib::Idle->add(
            sub {
                $job{ on_error }->( $why ) if $job{ on_error };
                return 0;
            }
        );
        return undef;
    }

    unless ( $pid )
    {
        _child( \%job, $errfile );

        # Not reached: _child never returns.
        POSIX::_exit( 70 );
    }

    $job{ pid }     = $pid;
    $job{ errfile } = $errfile;
    $self->{ job }  = \%job;

    my $watch;
    $watch = Glib::Child->watch_add(
        $pid,
        sub {
            my ( undef, $status ) = @_;
            $self->_reaped( \%job, $status );
            return 0;
        }
    );
    $job{ watch } = $watch;

    return $pid;
}

sub _child
{
    my ( $job, $errfile ) = @_;

    # The default handler would run global destruction on the way out, which
    # in this child would include the cache object's cleanup -- deleting the
    # session directory the parent is still using.
    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $SIG{ TERM } = sub { POSIX::_exit( 130 ) };
    ## use critic

    local $@;
    my $ok = eval {
        $job->{ work }->();
        1;
    };

    unless ( $ok )
    {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+\z//;

        if ( open my $fh, '>', $errfile )
        {
            print { $fh } $err;
            close $fh;
        }

        POSIX::_exit( 1 );
    }

    # _exit rather than exit: this process shares the parent's file handles and
    # its Gtk connection, and must not run END blocks, flush the parent's
    # buffers, or tear down anything the parent still owns.
    POSIX::_exit( 0 );
}

sub _reaped
{
    my ( $self, $job, $status ) = @_;

    my $err = _slurp_error( $job->{ errfile } );
    unlink $job->{ errfile };

    return if $job->{ cancelled };

    $self->{ job } = undef;

    if ( $status != 0 )
    {
        my $message = $err;
        if ( !defined $message || !length $message )
        {
            $message = sprintf 'render process failed (exit %d)', $status >> 8;
        }

        $job->{ on_error }->( $message ) if $job->{ on_error };
        return;
    }

    # An export writes straight to its destination; a preview is staged and
    # then moved into the cache, so that a key never names a partial file.
    my $path = $job->{ final };

    if ( defined $job->{ key } )
    {
        unless ( -s $job->{ staged } )
        {
            $job->{ on_error }->( 'the render produced no output' )
                if $job->{ on_error };
            return;
        }

        $path = $self->{ cache }
            ->commit( $job->{ staged }, $job->{ key }, $job->{ suffix } );
        $self->{ cache }->trim;
    }

    $job->{ on_done }->( $path, 0 ) if $job->{ on_done };

    return;
}

sub _slurp_error
{
    my ( $path ) = @_;

    return undef unless defined $path && -s $path;

    open my $fh, '<', $path or return undef;
    my $text = do { local $/ = undef; <$fh> };
    close $fh;

    return $text;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Cache>, L<GlitchVape::GUI::State>.

=cut
