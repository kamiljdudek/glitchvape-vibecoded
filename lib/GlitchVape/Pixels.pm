package GlitchVape::Pixels;

use strict;
use warnings;

use GlitchVape::Magick ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Pixels - direct access to an image's raw RGB bytes

=head1 DESCRIPTION

PerlMagick's C<SetPixels> is a silent no-op in ImageMagick 7 as packaged for
Debian: it returns success and changes nothing. Every effect that displaces or
rewrites pixels therefore goes through this class instead, which exports the
image to a raw 8-bit RGB blob, works on it as a Perl string, and reads it back.

That turns out to be the better approach regardless. A 1920x1440 image is 8 MB
as a packed string but roughly 24 million scalars as a Perl list, and moving a
run of pixels sideways is one C<substr> rather than a loop.

=head2 Layout

C<data> is row-major C<RGBRGB...>, one byte per channel, C<stride> bytes per
row. Coordinates are always in pixels; the class does the times-three.

=cut

use constant CHANNELS => 3;

=head2 from_image( $img )

Build a buffer from an L<Image::Magick> object.

=cut

sub from_image
{
    my ( $class, $img ) = @_;

    my ( $w, $h ) = $img->Get( 'width', 'height' );
    die "GlitchVape::Pixels: image has no dimensions\n" unless $w && $h;

    $img->Set( depth => 8 );
    my @blob = $img->ImageToBlob( magick => 'RGB', depth => 8 );

    my $data = $blob[ 0 ];
    my $want = $w * $h * CHANNELS;

    # A short or missing blob means the export silently failed, and every
    # offset computed from it afterwards would be wrong. Report what actually
    # came back rather than just that it was not what was expected.
    my $got = 'nothing';
    if ( defined $data )
    {
        $got = length $data;
    }

    if ( !defined $data || length( $data ) != $want )
    {
        die "GlitchVape::Pixels: expected $want bytes for ${w}x${h}, "
            . "got $got\n";
    }

    return bless {
        w      => $w,
        h      => $h,
        stride => $w * CHANNELS,
        data   => $data,
    }, $class;
}

=head2 to_image()

Convert back to a fresh L<Image::Magick> object.

=cut

sub to_image
{
    my ( $self ) = @_;
    require Image::Magick;

    my $img = Image::Magick->new(
        size   => "$self->{w}x$self->{h}",
        magick => 'RGB',
        depth  => 8,
    );

    GlitchVape::Magick::check( $img->BlobToImage( $self->{ data } ),
        'could not rebuild the image from its pixel buffer' );

    # Without this the object still thinks it is raw RGB and writes headerless
    # files.
    $img->Set( magick => 'PNG', colorspace => 'sRGB' );
    $img->Set( alpha  => 'off' );

    return $img;
}

=head2 edit( $ctx, $callback )

Load the context's image as a buffer, hand it to C<$callback>, then write it
back. The usual entry point:

    GlitchVape::Pixels->edit( $ctx, sub {
        my ($px) = @_;
        $px->set_row( 0, $px->row(1) );
    });

=cut

sub edit
{
    my ( $class, $ctx, $cb ) = @_;

    my $px = $class->from_image( $ctx->image );
    $cb->( $px );
    $ctx->image( $px->to_image );

    return;
}

sub width  { $_[ 0 ]{ w } }
sub height { $_[ 0 ]{ h } }
sub stride { $_[ 0 ]{ stride } }
sub data   { $_[ 0 ]{ data } }

=head2 row( $y ) / set_row( $y, $bytes )

One scanline as a byte string.

=cut

sub row
{
    my ( $self, $y ) = @_;
    return substr( $self->{ data }, $y * $self->{ stride }, $self->{ stride } );
}

sub set_row
{
    my ( $self, $y, $bytes ) = @_;
    substr $self->{ data }, $y * $self->{ stride }, $self->{ stride }, $bytes;
    return;
}

=head2 band( $y, $rows ) / set_band( $y, $rows, $bytes )

A run of whole scanlines. Contiguous in memory, so this is a single C<substr>.

=cut

sub band
{
    my ( $self, $y, $rows ) = @_;
    return substr(
        $self->{ data },
        $y * $self->{ stride },
        $rows * $self->{ stride }
    );
}

sub set_band
{
    my ( $self, $y, $rows, $bytes ) = @_;
    substr $self->{ data }, $y * $self->{ stride }, $rows * $self->{ stride },
        $bytes;
    return;
}

=head2 rect( $x, $y, $w, $h ) / set_rect( $x, $y, $w, $h, $bytes )

An arbitrary rectangle, returned as C<$h> rows of C<$w*3> bytes concatenated.
Not contiguous, so this costs one C<substr> per row.

=cut

sub rect
{
    my ( $self, $x, $y, $w, $h ) = @_;

    my $rw  = $w * CHANNELS;
    my $off = $x * CHANNELS;
    my $out = '';

    for my $r ( 0 .. $h - 1 )
    {
        $out .= substr( $self->{ data },
            ( $y + $r ) * $self->{ stride } + $off, $rw );
    }
    return $out;
}

sub set_rect
{
    my ( $self, $x, $y, $w, $h, $bytes ) = @_;

    my $rw  = $w * CHANNELS;
    my $off = $x * CHANNELS;

    for my $r ( 0 .. $h - 1 )
    {
        substr $self->{ data }, ( $y + $r ) * $self->{ stride } + $off, $rw,
            substr( $bytes, $r * $rw, $rw );
    }
    return;
}

=head2 each_row( $callback )

Call C<< $callback->($y, $bytes) >> for every scanline. If it returns a defined
string, that becomes the new row.

=cut

sub each_row
{
    my ( $self, $cb ) = @_;

    for my $y ( 0 .. $self->{ h } - 1 )
    {
        my $new = $cb->( $y, $self->row( $y ) );
        $self->set_row( $y, $new ) if defined $new;
    }
    return;
}

=head1 FUNCTIONS

=head2 shift_row( $bytes, $width, $shift, $wrap )

Displace one row's worth of bytes sideways by C<$shift> pixels. Positive moves
right. With C<$wrap> the row rotates; otherwise the vacated edge repeats the
pixel that was there, which is what a real signal does when it runs out of
line to draw.

Returns the new byte string.

=cut

sub shift_row
{
    my ( $bytes, $w, $shift, $wrap ) = @_;
    return $bytes unless $shift;

    if ( $wrap )
    {
        my $s = $shift % $w;
        return $bytes unless $s;
        my $cut = ( $w - $s ) * CHANNELS;
        return substr( $bytes, $cut ) . substr( $bytes, 0, $cut );
    }

    my $s = $shift;
    $s = $w  if $s > $w;
    $s = -$w if $s < -$w;

    if ( $s > 0 )
    {
        my $edge = substr( $bytes, 0, CHANNELS );
        return ( $edge x $s ) . substr( $bytes, 0, ( $w - $s ) * CHANNELS );
    }

    my $n    = -$s;
    my $edge = substr( $bytes, -CHANNELS );
    return substr( $bytes, $n * CHANNELS ) . ( $edge x $n );
}

=head2 shift_band( $bytes, $width, $rows, $shift, $wrap )

L</shift_row> applied to every row of a band, all displaced by the same amount.

=cut

sub shift_band
{
    my ( $bytes, $w, $rows, $shift, $wrap ) = @_;
    return $bytes unless $shift;

    my $stride = $w * CHANNELS;
    my $out    = '';

    for my $r ( 0 .. $rows - 1 )
    {
        $out .= shift_row( substr( $bytes, $r * $stride, $stride ),
            $w, $shift, $wrap );
    }
    return $out;
}

=head2 luma( $r, $g, $b )

Rec. 601 luminance, the weighting analogue video actually used.

=cut

sub luma { 0.299 * $_[ 0 ] + 0.587 * $_[ 1 ] + 0.114 * $_[ 2 ] }

=head2 clamp( $v )

Clamp to 0..255 and round.

=cut

sub clamp
{
    my ( $v ) = @_;
    return 0   if $v < 0;
    return 255 if $v > 255;
    return int $v;
}

1;
