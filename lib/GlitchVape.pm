package GlitchVape;

use strict;
use warnings;

use File::Spec ();
use File::Temp ();

use GlitchVape::Config   ();
use GlitchVape::Context  ();
use GlitchVape::IO       ();
use GlitchVape::Pipeline ();
use GlitchVape::Registry ();
use GlitchVape::Random   ();

# Loading these registers every effect. Order does not matter; the registry
# sorts by declared stage.
use GlitchVape::Effect::Color   ();
use GlitchVape::Effect::Texture ();
use GlitchVape::Effect::Signal  ();
use GlitchVape::Effect::Glitch  ();
use GlitchVape::Effect::Screen  ();
use GlitchVape::Effect::Overlay ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape - vaporwave and glitch-art transformations for photographs

=head1 SYNOPSIS

    use GlitchVape;

    GlitchVape::render(
        input  => 'Pictures/IMG_8111.HEIC',
        output => 'out/IMG_8111.png',
        preset => 'vhs-decay',
        seed   => 1337,
    );

    GlitchVape::render(
        input   => 'Pictures/IMG_8111.HEIC',
        output  => 'out/loop.mp4',
        preset  => 'vhs-decay',
        animate => { frames => 24, fps => 12 },
    );

=head1 DESCRIPTION

The pipeline is built from a preset plus overrides, validated up front, then
applied to a decoded image. See L<GlitchVape::Registry> for the stage ordering
that determines what runs when, and L<GlitchVape::Config> for the preset
format.

=head1 FUNCTIONS

=head2 render( %arg )

    input     => path              required
    output    => path              required
    preset    => name              preset to build from
    set       => [ 'a.b=c' ]       dotted parameter overrides
    enable    => [ names ]         switch effects on with defaults
    disable   => [ names ]         switch effects off
    seed      => scalar            any string or number; omit for random
    max_dim   => N                 downscale the source first (default 1920)
    fit       => [ W, H ]          downscale to fit a box; see below
    quality   => N                 output quality for lossy formats
    colors    => N                 quantise the still to an N-entry palette
    codec     => name              h264, vp9 or av1; default from the extension
    animate   => { frames, fps }   render a loop instead of a still
    verbose   => bool
    dry_run   => bool              resolve and describe, render nothing

C<fit> is the two-number form of C<max_dim>, applied along the picture's own
long edge, and is how "must land on a 640x480 screen" is said -- which one
number cannot say. See L<GlitchVape::IO/fit is a box, and the box turns with
the picture>. Both may be given.

It is applied to the source I<and> to the result, because effects that add
furniture -- C<letterbox>, C<border> -- make the picture bigger than the one
they were handed, and a box that only constrained the input would be a promise
this makes and does not keep.

C<colors> and C<codec> are each about one output: C<colors> quantises a still
before it is written, which is what makes a 256-colour bitmap 256 colours, and
C<codec> settles the F<.webm> question that the extension leaves open.

An C<audio> key inside C<animate> adds a soundtrack, and changes what the
length of the result means: see L<GlitchVape::Animate/AUDIO DECIDES THE
LENGTH>.

    animate => {
        frames => 24,
        fps    => 12,
        audio  => {
            path    => 'track.mp3',
            start   => 12.5,
            end     => 28.0,
            filters => { slowed => 0.8, reverb => 0.4 },
        },
    }

Returns a hashref describing what happened: C<output>, C<seed>, C<pipeline>,
C<dims>, C<elapsed>.

=cut

sub render
{
    my ( %arg ) = @_;

    my $input = $arg{ input }
        or die "GlitchVape: render() requires an 'input' path\n";
    my $output = $arg{ output }
        or die "GlitchVape: render() requires an 'output' path\n";

    die "GlitchVape: no such file: $input\n" unless -f $input;

    my $config = GlitchVape::Config::load(
        preset  => $arg{ preset },
        set     => $arg{ set },
        enable  => $arg{ enable },
        disable => $arg{ disable },
    );

    my $seed = $arg{ seed };
    $seed = $config->{ seed } if !defined $seed && defined $config->{ seed };
    $seed = int( rand 2**31 ) unless defined $seed;

    my $pipeline = GlitchVape::Pipeline->new(
        effects => $config->{ effects },
        order   => $config->{ order },
        disable => $config->{ disable },
    );

    return {
        output   => $output,
        seed     => $seed,
        pipeline => $pipeline,
        dry_run  => 1,
        }
        if $arg{ dry_run };

    my $started = time;

    my $max_dim = $arg{ max_dim };
    $max_dim = $config->{ output }{ max_dim } unless defined $max_dim;
    $max_dim = 1920                           unless defined $max_dim;

    my %job = (
        input    => $input,
        output   => $output,
        config   => $config,
        pipeline => $pipeline,
        seed     => $seed,
        max_dim  => $max_dim,
        opt      => \%arg,
    );

    my $result;
    if ( $arg{ animate } )
    {
        $result = _render_animation( \%job );
    }
    else
    {
        $result = _render_still( \%job );
    }

    $result->{ seed }     = $seed;
    $result->{ pipeline } = $pipeline;
    $result->{ elapsed }  = time - $started;

    return $result;
}

sub _render_still
{
    my ( $job ) = @_;

    my $arg    = $job->{ opt };
    my $config = $job->{ config };

    my $img = GlitchVape::IO::load(
        $job->{ input },
        max_dim => $job->{ max_dim },
        fit     => $arg->{ fit },
    );

    my $ctx = GlitchVape::Context->new(
        image   => $img,
        source  => $job->{ input },
        seed    => $job->{ seed },
        verbose => $arg->{ verbose },
    );

    $job->{ pipeline }->run( $ctx );

    GlitchVape::IO::save(
        $ctx->image, $job->{ output },
        quality  => $arg->{ quality }  // $config->{ output }{ quality }  // 92,
        optimise => $arg->{ optimise } // $config->{ output }{ optimise } // 0,
        fit      => $arg->{ fit },
        colors   => $arg->{ colors },
    );

    # Read after the write, not before it: save may shrink the image to fit
    # the box, and what this reports is meant to be the size of the file.
    my ( $w, $h ) = $ctx->dims;

    return {
        output  => $job->{ output },
        dims    => [ $w, $h ],
        frames  => 1,
        timings => [ $ctx->timings ],
    };
}

sub _render_animation
{
    my ( $job ) = @_;

    require GlitchVape::Animate;

    my $arg    = $job->{ opt };
    my $spec   = $arg->{ animate };
    my $frames = $spec->{ frames } || 24;
    my $fps    = $spec->{ fps }    || 12;

    die "GlitchVape: animate.frames must be at least 2, got $frames\n"
        if $frames < 2;

    # Before the loop rather than after it. Encoding is the last step of a job
    # whose first twenty-four steps are whole renders, and finding out then
    # that the codec is a typo -- or that this ffmpeg cannot write it -- would
    # waste every one of them.
    my $codec = $arg->{ codec } // $spec->{ codec };
    GlitchVape::Animate::require_codec( lc $codec )
        if defined $codec && length $codec;

    my $dir = File::Temp->newdir( 'glitchvape_frames_XXXXXX', TMPDIR => 1 );

    # The source is decoded once and cloned per frame. Re-reading a 3 MB HEIC
    # twenty-four times is the slowest thing this program could plausibly do.
    my $source = GlitchVape::IO::load(
        $job->{ input },
        max_dim => $job->{ max_dim },
        fit     => $arg->{ fit },
    );

    my @paths;
    my @timings;

    for my $n ( 0 .. $frames - 1 )
    {
        my $ctx = GlitchVape::Context->new(
            image   => $source->Clone,
            source  => $job->{ input },
            seed    => $job->{ seed },
            verbose => $arg->{ verbose },
        );
        $ctx->frames( $frames );
        $ctx->frame( $n );

        $job->{ pipeline }->run( $ctx );

        my $path = GlitchVape::Animate::frame_path( "$dir", $n );
        GlitchVape::IO::save(
            $ctx->image, $path,
            quality => 100,
            strip   => 1,
            fit     => $arg->{ fit },
        );
        push @paths,   $path;
        push @timings, [ $ctx->timings ];

        warn sprintf( "  frame %d/%d\n", $n + 1, $frames ) if $arg->{ verbose };
    }

    GlitchVape::Animate::encode(
        frames  => \@paths,
        output  => $job->{ output },
        fps     => $fps,
        loop    => $spec->{ loop },
        quality => $spec->{ quality },
        codec   => $arg->{ codec } // $spec->{ codec },
        audio   => $spec->{ audio },
    );

    my ( $w, $h ) = $source->Get( 'width', 'height' );

    return {
        output  => $job->{ output },
        dims    => [ $w, $h ],
        frames  => $frames,
        fps     => $fps,
        audio   => $spec->{ audio },
        timings => $timings[ 0 ] || [],
    };
}

=head2 effect_list()

C<< [ { name, title, stage, summary, params }, ... ] >> for every registered
effect.

=cut

sub effect_list
{
    my $all = GlitchVape::Registry->all;
    return [
        map {
            {
                name    => $_,
                title   => $all->{ $_ }{ title },
                stage   => $all->{ $_ }{ stage },
                summary => $all->{ $_ }{ summary },
                doc     => $all->{ $_ }{ doc },
                params  => $all->{ $_ }{ params },
            }
        } GlitchVape::Registry->names
    ];
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Registry> for the effect stage model, L<GlitchVape::Config> for
the preset format, and the F<glitchvape> command-line tool.

=cut
