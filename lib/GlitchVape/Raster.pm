package GlitchVape::Raster;

use strict;
use warnings;

use File::Spec ();

use GlitchVape::Tools ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Raster - build small procedural pattern images

=head1 DESCRIPTION

Scanline masks, phosphor grilles and dither tiles are all tiny images that get
tiled up to full size. Writing them as raw PPM and letting ImageMagick convert
avoids assembling command lines with hundreds of C<-draw> operands, and is
enough faster to matter when an animation rebuilds the pattern every frame.

=cut

=head2 write_ppm( $path, $width, $height, $bytes )

Write a binary P6 PPM. C<$bytes> is a packed RGB string of exactly
C<$width * $height * 3> bytes.

=cut

sub write_ppm
{
    my ( $path, $w, $h, $bytes ) = @_;

    my $want = $w * $h * 3;
    die "GlitchVape::Raster: expected $want bytes for ${w}x${h}, got "
        . length( $bytes ) . "\n"
        if length( $bytes ) != $want;

    open my $fh, '>:raw', $path
        or die "GlitchVape::Raster: cannot write $path: $!\n";
    print { $fh } "P6\n$w $h\n255\n", $bytes;
    close $fh or die "GlitchVape::Raster: cannot close $path: $!\n";

    return $path;
}

=head2 pattern_png( $dir, $key, $w, $h, $bytes )

Write a pattern as PPM, convert it to PNG, and return the PNG path. Results are
cached by C<$key> within C<$dir>, so a tiled pattern is built once per render
even when several effects ask for it.

=cut

sub pattern_png
{
    my ( $dir, $key, $w, $h, $bytes ) = @_;

    my $png = File::Spec->catfile( $dir, "pat_$key.png" );
    return $png if -f $png;

    my $ppm = File::Spec->catfile( $dir, "pat_$key.ppm" );
    write_ppm( $ppm, $w, $h, $bytes );

    system( GlitchVape::Tools::magick_argv( $ppm, $png ) ) == 0
        or die "GlitchVape::Raster: failed converting $ppm to PNG\n";
    unlink $ppm;

    return $png;
}

=head2 scanline_tile( $dir, %opt )

A vertically-repeating scanline pattern, one pixel wide.

    spacing   => 3      distance between line centres
    thickness => 1      how many rows are darkened
    opacity   => 0.35   0 = invisible, 1 = solid black lines
    offset    => 0      shift the pattern down, for animated roll
    softness  => 0      blend the line edges (0 = hard)

=cut

sub scanline_tile
{
    my ( $dir, %opt ) = @_;

    my $spacing   = int( $opt{ spacing }   || 3 );
    my $thickness = int( $opt{ thickness } || 1 );
    my $opacity   = $opt{ opacity } || 0;
    my $offset    = int( $opt{ offset } || 0 );
    my $soft      = $opt{ softness } || 0;

    $spacing   = 1        if $spacing < 1;
    $thickness = $spacing if $thickness > $spacing;

    my $dark = int( 255 * ( 1 - $opacity ) + 0.5 );
    $dark = 0 if $dark < 0;

    my $bytes = '';
    for my $y ( 0 .. $spacing - 1 )
    {
        my $pos = ( $y + $offset ) % $spacing;
        my $v;
        if ( $pos < $thickness )
        {
            $v = $dark;
        }
        elsif ( $soft > 0 && $pos < $thickness + $soft )
        {
            # Ramp back to white over $soft rows so the lines do not alias
            # into moire when the image is later resized.
            my $t = ( $pos - $thickness + 1 ) / ( $soft + 1 );
            $v = int( $dark + ( 255 - $dark ) * $t + 0.5 );
        }
        else
        {
            $v = 255;
        }
        $bytes .= pack 'C3', $v, $v, $v;
    }

    my $key = join '_', 'scan', $spacing, $thickness,
        sprintf( '%.3f', $opacity ), $offset, $soft;

    return pattern_png( $dir, $key, 1, $spacing, $bytes );
}

=head2 grille_tile( $dir, %opt )

An aperture-grille phosphor mask: repeating vertical red/green/blue stripes.
Multiplied over an image this is what makes it read as a CRT close-up rather
than just a dark-striped photo.

    width    => 1      pixels per phosphor stripe
    strength => 0.3    0 = invisible, 1 = fully saturated stripes

=cut

sub grille_tile
{
    my ( $dir, %opt ) = @_;

    my $width    = int( $opt{ width } || 1 );
    my $strength = $opt{ strength };
    $strength = 0.3 unless defined $strength;
    $width    = 1 if $width < 1;

    # Each stripe keeps its own channel at full and dims the other two.
    my $lo      = int( 255 * ( 1 - $strength ) + 0.5 );
    my @stripes = ( [ 255, $lo, $lo ], [ $lo, 255, $lo ], [ $lo, $lo, 255 ], );

    my $bytes = '';
    for my $s ( @stripes )
    {
        $bytes .= pack( 'C3', @$s ) x $width;
    }

    my $key = join '_', 'grille', $width, sprintf( '%.3f', $strength );
    return pattern_png( $dir, $key, $width * 3, 1, $bytes );
}

=head2 tiled( $ctx, $tile_png, $w, $h )

Expand a tile to C<${w}x${h}> and return the path.

=cut

sub tiled
{
    my ( $ctx, $tile, $w, $h ) = @_;

    my $out = $ctx->tmpfile( '.png' );
    my @argv =
        GlitchVape::Tools::magick_argv( '-size', "${w}x${h}", "tile:$tile",
        $out );

    die "GlitchVape::Raster: failed tiling $tile to ${w}x${h}\n"
        unless system( @argv ) == 0 && -s $out;

    return $out;
}

1;
