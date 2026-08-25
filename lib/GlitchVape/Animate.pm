package GlitchVape::Animate;

use strict;
use warnings;

use File::Spec ();

use GlitchVape::Tools ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Animate - encode rendered frame sequences to MP4, WebM or GIF

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

=head1 THE CONTAINER USUALLY PICKS THE CODEC, BUT NOT ALWAYS

F<.mp4> means H.264 and F<.gif> means GIF, and for those the extension is the
whole decision. F<.webm> is the one that is genuinely ambiguous: VP9 and AV1
both live in it, and the file name cannot say which was wanted. So C<codec>
exists, and where it is not given the extension still decides -- C<.webm>
defaulting to VP9, which is what every build of ffmpeg can write.

AV1 is smaller than VP9 at the same quality and slower to encode by a wide
margin. It also needs an encoder that not every ffmpeg has, which is checked
before the first frame rather than discovered at the last step -- see
L<GlitchVape::Tools/ffmpeg_encoder>.

=cut

# Container plus codec to the ffmpeg arguments that write it. Video first,
# then the audio codec that container takes, which is only added when there is
# a track to put in it.
#
# A table rather than branches because the three differ in every field and
# share no defaults worth expressing as a fall-through.
my %CODEC = (
    h264 => {
        encoder => 'libx264',
        label   => 'H.264',
        video   => sub {
            my ( $crf ) = @_;

            # yuv420p and even dimensions are what makes the file play in
            # browsers and phone galleries rather than only in VLC.
            return ( '-c:v', 'libx264', '-crf', $crf, '-preset', 'slow',
                '-pix_fmt', 'yuv420p', '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2' );
        },
        audio => [ '-c:a', 'aac', '-b:a', '192k' ],
    },

    vp9 => {
        encoder => 'libvpx-vp9',
        label   => 'VP9',
        video   => sub {
            my ( $crf ) = @_;

            # -b:v 0 is what puts libvpx into constant-quality mode; without
            # it the CRF is a ceiling on a bitrate-targeted encode.
            return ( '-c:v', 'libvpx-vp9', '-crf', $crf, '-b:v', '0' );
        },
        audio => [ '-c:a', 'libopus', '-b:a', '160k' ],
    },

    av1 => {
        encoder => 'libsvtav1',
        label   => 'AV1',
        video   => sub {
            my ( $crf ) = @_;

            # preset 6 is SVT-AV1's middle: 4 and below spend minutes per
            # frame on material this small, and 10 gives up most of the size
            # advantage that is the reason to choose AV1 at all.
            return ( '-c:v', 'libsvtav1', '-crf', $crf, '-preset', '6',
                '-pix_fmt', 'yuv420p' );
        },
        audio => [ '-c:a', 'libopus', '-b:a', '160k' ],
    },
);

# What an extension means when nothing said otherwise.
my %DEFAULT_CODEC = (
    mp4  => 'h264',
    m4v  => 'h264',
    mov  => 'h264',
    webm => 'vp9',
);

=head2 codecs()

The codec names C<encode> accepts, in the order a chooser should offer them.

=cut

sub codecs { return qw(h264 vp9 av1) }

=head2 codec_available( $name )

Whether this ffmpeg can write that codec. An unknown name is not available.

=cut

sub codec_available
{
    my ( $name ) = @_;

    my $spec = $CODEC{ $name // q{} } or return 0;

    return GlitchVape::Tools::ffmpeg_encoder( $spec->{ encoder } );
}

=head2 require_codec( $name )

Dies unless C<$name> is a codec this ffmpeg can write. Returns its spec.

Two failures, told apart because the fixes are nothing alike: a name this
program does not know is a typo, and a name it knows but cannot write is a
build of ffmpeg without that encoder.

=cut

sub require_codec
{
    my ( $name ) = @_;

    my $spec = $CODEC{ $name // q{} };

    die "GlitchVape::Animate: unknown codec '"
        . ( $name // q{} ) . "'\n"
        . '  Known: '
        . join( ', ', codecs() ) . "\n"
        unless $spec;

    die "GlitchVape::Animate: this ffmpeg cannot write "
        . "$spec->{ label }: no $spec->{ encoder } encoder.\n"
        . "  Check with:  ffmpeg -encoders | grep $spec->{ encoder }\n"
        unless GlitchVape::Tools::ffmpeg_encoder( $spec->{ encoder } );

    return $spec;
}

=head2 encode( %arg )

    frames  => [ paths ]   rendered frames, in order
    output  => path        .mp4, .webm, .gif or .apng
    fps     => 12          frame rate
    loop    => 0           GIF loop count (0 = forever)
    quality => 20          CRF; lower is better
    codec   => 'av1'       h264, vp9 or av1; default from the extension
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

    my $spec = require_codec( codec_for( $output, $arg->{ codec } ) );

    my $dir = _frame_dir( $frames );
    my $fps = $arg->{ fps } || 12;

    # CRF 20 is a reasonable default across all three; lower is better
    # quality. The scales are not identical between codecs, but they are
    # close enough that one number does not need three defaults.
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

    push @argv, $spec->{ video }->( $crf );
    push @argv, @{ $spec->{ audio } } if $track;

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
    die "GlitchVape::Animate: ffmpeg failed encoding $output as "
        . "$spec->{ label } (exit "
        . ( $rc >> 8 ) . ")\n"
        unless $rc == 0 && -s $output;

    return $output;
}

=head2 codec_for( $output, $asked )

The codec that would be used for an output path, given what was asked for.

An explicit codec wins, then the extension's default, then H.264 -- which is
what an unrecognised extension in an MP4-shaped world most likely meant. The
name is returned whether or not this ffmpeg can write it; see
L</require_codec> for that question.

=cut

sub codec_for
{
    my ( $output, $asked ) = @_;

    return lc $asked if defined $asked && length $asked;

    my ( $ext ) = lc( $output ) =~ /\.([^.]+)$/;

    return $DEFAULT_CODEC{ $ext // q{} } // 'h264';
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
