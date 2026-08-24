package GlitchVape::Animate;

use strict;
use warnings;

use File::Spec ();

use GlitchVape::Tools ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Animate - encode rendered frame sequences to MP4 or GIF

=head1 DESCRIPTION

Frames are rendered by re-running the whole pipeline once per frame with
C<< $ctx->frame >> advanced. Effects that consult C<< $ctx->phase >> then move
smoothly and rejoin at the end of the loop, while effects that draw from
C<rng_for> get a fresh but reproducible pattern each frame -- which is what
makes static flicker rather than sit still.

=head1 AUDIO DECIDES THE LENGTH

A loop is two seconds; a piece of music is not. When an audio spec is given
the frame sequence is repeated for as long as the track lasts rather than the
track being cut to the length of the loop, so the crop the user chose in the
wizard is what determines the length of the finished file.

That is C<-stream_loop -1> on the image sequence with C<-shortest>, and the
track's own measured duration as a C<-t> as well: an infinite input needs more
than one thing telling it where to stop.

=cut

=head2 encode( %arg )

    frames  => [ paths ]   rendered frames, in order
    output  => path        .mp4, .webm, .gif or .apng
    fps     => 12          frame rate
    loop    => 0           GIF loop count (0 = forever)
    quality => 20          H.264 CRF; lower is better
    audio   => { ... }     a GlitchVape::Audio spec to mux in

=cut

sub encode
{
    my ( %arg ) = @_;

    my $frames = $arg{ frames } or die "GlitchVape::Animate: no frames given\n";
    my $output = $arg{ output } or die "GlitchVape::Animate: no output given\n";

    die "GlitchVape::Animate: frame list is empty\n" unless @$frames;

    my ( $ext ) = lc( $output ) =~ /\.([^.]+)$/;
    $ext ||= 'mp4';

    if ( $ext eq 'gif' )
    {
        # Reported rather than refused: the user asked for a GIF and a GIF is
        # what they get, but silently dropping a track they spent a wizard
        # choosing would look like a bug.
        warn "GlitchVape::Animate: a GIF cannot carry audio, so the added "
            . "track is not in $output.\n  Write .mp4 or .webm for sound.\n"
            if $arg{ audio };

        return _encode_gif( $frames, $output, \%arg );
    }

    return _encode_video( $frames, $output, \%arg );
}

=head2 frame_pattern( $dir )

The printf-style path used for numbered frames in C<$dir>.

=cut

sub frame_pattern
{
    my ( $dir ) = @_;
    return File::Spec->catfile( $dir, 'frame_%05d.png' );
}

=head2 frame_path( $dir, $n )

Path for frame C<$n>.

=cut

sub frame_path
{
    my ( $dir, $n ) = @_;
    return File::Spec->catfile( $dir, sprintf( 'frame_%05d.png', $n ) );
}

sub _encode_video
{
    my ( $frames, $output, $arg ) = @_;

    my $ffmpeg = GlitchVape::Tools::require_tool( 'ffmpeg', 'to write video' );

    my $dir = _frame_dir( $frames );
    my $fps = $arg->{ fps } || 12;

    # CRF 20 is a reasonable default for H.264; lower is better quality.
    my $crf = 20;
    if ( defined $arg->{ quality } )
    {
        $crf = $arg->{ quality };
    }

    my $track = _render_track( $arg, $dir );

    my @argv = ( $ffmpeg, '-y', '-loglevel', 'error' );

    # The loop is repeated to cover the track. Without a track there is
    # nothing to stop an infinite input, so this is only ever added alongside
    # one.
    push @argv, '-stream_loop', '-1' if $track;

    push @argv, '-framerate', $fps, '-i', frame_pattern( $dir );
    push @argv, '-i', $track->{ path } if $track;

    if ( $output =~ /\.webm$/i )
    {
        push @argv, '-c:v', 'libvpx-vp9', '-crf', $crf, '-b:v', '0';
        push @argv, '-c:a', 'libopus', '-b:a', '160k' if $track;
    }
    else
    {
        # yuv420p and even dimensions are what makes the file play in browsers
        # and phone galleries rather than only in VLC.
        push @argv,
            '-c:v',     'libx264',
            '-crf',     $crf,
            '-preset',  'slow',
            '-pix_fmt', 'yuv420p',
            '-vf',      'pad=ceil(iw/2)*2:ceil(ih/2)*2';

        push @argv, '-c:a', 'aac', '-b:a', '192k' if $track;
    }

    if ( $track )
    {
        push @argv, '-shortest';

        # And an explicit length as well where the track could be measured.
        # -shortest alone has been enough in testing, but the failure mode of
        # it not being enough is an encode that never returns, which is not a
        # thing to leave to one mechanism.
        push @argv, '-t', sprintf( '%.3f', $track->{ duration } )
            if $track->{ duration };
    }

    push @argv, $output;

    my $rc = system( @argv );
    die "GlitchVape::Animate: ffmpeg failed encoding $output (exit "
        . ( $rc >> 8 ) . ")\n"
        unless $rc == 0 && -s $output;

    return $output;
}

# Cut and filter the added track into the frame directory, which is already a
# temporary the caller owns and cleans up. Returns undef when there is no
# audio, or C<< { path, duration } >> when there is.
sub _render_track
{
    my ( $arg, $dir ) = @_;

    my $spec = $arg->{ audio } or return undef;

    require GlitchVape::Audio;

    my $path = File::Spec->catfile( $dir, 'track.wav' );

    GlitchVape::Audio::render( spec => $spec, output => $path );

    # Measured rather than estimated: GlitchVape::Audio::output_duration is
    # honest about being an approximation, and this is the number the encoder
    # stops on.
    my $duration;
    local $@;
    if (
        eval { $duration = GlitchVape::Audio::probe( $path )->{ duration }; 1 }
        )
    {
        return { path => $path, duration => $duration };
    }

    return { path => $path, duration => undef };
}

sub _encode_gif
{
    my ( $frames, $output, $arg ) = @_;

    my $ffmpeg = GlitchVape::Tools::require_tool( 'ffmpeg', 'to write GIF' );

    my $dir = _frame_dir( $frames );
    my $fps = $arg->{ fps } || 12;

    # ffmpeg treats a GIF loop count of 0 as "forever", which is what a
    # glitch loop wants unless the caller says otherwise.
    my $loop = 0;
    if ( defined $arg->{ loop } )
    {
        $loop = $arg->{ loop };
    }

    # A GIF built without a generated palette dithers against the default web
    # palette and looks nothing like the frames. palettegen/paletteuse costs a
    # second pass and is worth it every time.
    my $palette = File::Spec->catfile( $dir, 'palette.png' );

    my $rc =
        system( $ffmpeg, '-y', '-loglevel', 'error', '-framerate', $fps,
        '-i',  frame_pattern( $dir ),
        '-vf', 'palettegen=stats_mode=diff', $palette, );
    die "GlitchVape::Animate: ffmpeg failed generating a GIF palette\n"
        unless $rc == 0 && -s $palette;

    $rc = system(
        $ffmpeg,      '-y',
        '-loglevel',  'error',
        '-framerate', $fps,
        '-i',         frame_pattern( $dir ),
        '-i',         $palette,
        '-lavfi',     'paletteuse=dither=bayer:bayer_scale=3',
        '-loop',      $loop,
        $output,
    );
    die "GlitchVape::Animate: ffmpeg failed encoding $output\n"
        unless $rc == 0 && -s $output;

    if ( my $gifsicle = GlitchVape::Tools::find( 'gifsicle' ) )
    {
        system( $gifsicle, '--batch', '--optimize=3', $output );
    }

    return $output;
}

sub _frame_dir
{
    my ( $frames ) = @_;
    my ( undef, $dir ) = File::Spec->splitpath( $frames->[ 0 ] );
    $dir =~ s{/\z}{};

    # A bare filename splits to an empty directory, which means the current
    # one.
    if ( !length $dir )
    {
        return '.';
    }

    return $dir;
}

1;
