package GlitchVape::Wav;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Wav - packed samples into a RIFF/WAVE file

=head1 DESCRIPTION

Twenty lines of C<pack> shared by every generator that synthesises its own
audio. Not a general WAV library: it writes 16-bit PCM and nothing else,
because 16-bit PCM is the only thing anything here produces.

=head2 Why the header is built by hand

A WAV is a RIFF container, so it can carry chunks beside the audio -- cue
markers, their labels, Broadcast Wave metadata. ffmpeg surfaces those as a
second stream of type C<bin_data>, and that stream then travels through a
filter graph dragging the audio's timing along with it. It is a genuinely
confusing failure: the mix comes out offset and nothing in the filter chain
explains why.

Assembling the header here means there is nothing in the file but C<fmt > and
C<data>, so there is nothing for ffmpeg to find.

=cut

# CD rate is what the mixer and the muxer work in, so it is the default for
# anything that does not have a reason to differ. A generator with a reason --
# noise, which has no content above a few kilohertz -- says so.
use constant RATE => 44_100;

=head2 quantise( $value )

One float in C<[-1, 1]> to a signed 16-bit integer, clamped. The clamp is not
decoration: a generator that sums several components can exceed 1, and
C<pack 's<'> silently wraps a value that does not fit, turning a loud peak into
a full-scale spike of the opposite sign.

=cut

sub quantise
{
    my ( $value ) = @_;

    my $sample = int( $value * 32_767 );

    return -32_768 if $sample < -32_768;
    return 32_767  if $sample > 32_767;

    return $sample;
}

=head2 silence( $samples )

That many samples of nothing, packed.

=cut

sub silence
{
    my ( $samples ) = @_;

    return q{} unless $samples && $samples > 0;

    return "\0" x ( int( $samples ) * 2 );
}

=head2 bytes( $pcm, %arg )

    rate     => 44100
    channels => 1

The complete file as a string.

=cut

sub bytes
{
    my ( $pcm, %arg ) = @_;

    my $rate = $arg{ rate } || RATE;

    my $channels = $arg{ channels } || 1;
    my $block    = $channels * 2;

    return
          'RIFF'
        . pack( 'V',      36 + length $pcm ) . 'WAVE' . 'fmt '
        . pack( 'V',      16 )
        . pack( 'vvVVvv', 1, $channels, $rate, $rate * $block, $block, 16 )
        . 'data'
        . pack( 'V', length $pcm )
        . $pcm;
}

=head2 write( $path, $pcm, %arg )

As above, to a file. Returns the path.

=cut

sub write
{
    my ( $path, $pcm, %arg ) = @_;

    open my $fh, '>:raw', $path
        or die "GlitchVape::Wav: cannot write $path: $!\n";
    print { $fh } bytes( $pcm, %arg );
    close $fh
        or die "GlitchVape::Wav: cannot write $path: $!\n";

    return $path;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::DTMF> and L<GlitchVape::Noise>, which both end here.

=cut
