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

=head2 desktop_names() / desktop_tile( $dir, %opt )

The eight-by-eight patterns a background can be filled with, and one of them
as a PNG tile.

    name   => which, from desktop_names()
    ground => the colour behind it
    ink    => the colour of its marks
    scale  => image pixels per pattern pixel

Windows shipped a list of these under Desktop, all eight pixels square and all
two colours, and that is the shape they are kept in here for the reason
L<GlitchVape::VGA>'s font is: a pattern is a picture of hard pixels, and a
rasteriser that could smooth it would.

They are scaled by pixel replication, so a tile at scale four is four-pixel
blocks rather than a blurred eight-pixel one.

=cut

my %DESKTOP = (
    checker => [
        '#.#.#.#.', '.#.#.#.#', '#.#.#.#.', '.#.#.#.#',
        '#.#.#.#.', '.#.#.#.#', '#.#.#.#.', '.#.#.#.#',
    ],
    grid => [
        '########', '#.......', '#.......', '#.......',
        '#.......', '#.......', '#.......', '#.......',
    ],
    stripes => [
        '########', '........', '........', '........',
        '########', '........', '........', '........',
    ],
    diamonds => [
        '...#....', '..#.#...', '.#...#..', '#.....#.',
        '.#...#..', '..#.#...', '...#....', '........',
    ],
    dots => [
        '#.......', '........', '........', '........',
        '....#...', '........', '........', '........',
    ],
    thatch => [
        '###.###.', '#...#...', '###.###.', '....#...',
        '###.###.', '#...#...', '###.###.', '....#...',
    ],
);

sub desktop_names
{
    my @names = sort keys %DESKTOP;
    return @names;
}

sub desktop_tile
{
    my ( $dir, %opt ) = @_;

    my $art = $DESKTOP{ $opt{ name } // q{} } or return undef;

    my $scale = int( $opt{ scale } || 1 );
    $scale = 1 if $scale < 1;

    my $ink    = colour_bytes( $opt{ ink },    255, 255, 255 );
    my $ground = colour_bytes( $opt{ ground }, 0,   0,   0 );

    my $side = 8 * $scale;

    my $bytes = q{};
    for my $row ( @$art )
    {
        my $line = q{};
        $line .= ( $_ eq '#' ? $ink : $ground ) x $scale for split //, $row;

        $bytes .= $line x $scale;
    }

    my $key = join '_', 'desk', $opt{ name }, $scale,
        unpack( 'H6', $ink ), unpack( 'H6', $ground );

    return pattern_png( $dir, $key, $side, $side, $bytes );
}

=head2 colour_bytes( $spec, @fallback )

Three bytes of RGB for a hex triplet or for any colour ImageMagick can name.

Named as well as hex, because the parameters that reach here accept both --
C<letterbox.color> arrives as the word C<black> in three of the four presets
that use it, and a pattern drawn in a colour it could not read would come out
in whatever the fallback happened to be.

Not fatal on a colour nobody can read: a typo in a preset should draw a
pattern, not stop the render.

=cut

my %COLOUR;

sub colour_bytes
{
    my ( $spec, @fallback ) = @_;

    @fallback = ( 0, 0, 0 ) unless @fallback == 3;

    my $want = $spec // q{};

    my @rgb =
        $want =~ m{ \A [#]? ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}) \z }xi;

    return pack 'C3', map { hex } @rgb if @rgb == 3;

    return $COLOUR{ $want } if exists $COLOUR{ $want };

    return $COLOUR{ $want } = pack 'C3', @fallback unless length $want;

    require Image::Magick;

    my $swatch  = Image::Magick->new( size => '1x1' );
    my $trouble = $swatch->Read( "xc:$want" );

    return $COLOUR{ $want } = pack 'C3', @fallback
        if "$trouble" && "$trouble" =~ /\A Exception \s+ [45]/x;

    my @px = $swatch->GetPixels( map => 'RGB', width => 1, height => 1 );

    # A name ImageMagick does not know reads back as nothing rather than as
    # an exception, so the length is the test and not the return code.
    return $COLOUR{ $want } = pack 'C3', @fallback unless @px >= 3;

    return $COLOUR{ $want } = pack 'C3',
        map { int( $_ / 257 + 0.5 ) } @px[ 0 .. 2 ];
}

=head2 mixed( $from, $to, $amount )

Two colours blended, as C<#RRGGBB>. C<$amount> 0 is the first, 1 the second.

Hex out rather than three bytes, so that what comes back is a colour like any
other and every caller keeps taking colours. Bytes would have to be told apart
from a colour somehow, and C<red> is three characters long.

=cut

sub mixed
{
    my ( $from, $to, $amount ) = @_;

    my @a = unpack 'C3', colour_bytes( $from );
    my @b = unpack 'C3', colour_bytes( $to );

    return sprintf '#%02X%02X%02X',
        map { int( $a[ $_ ] + ( $b[ $_ ] - $a[ $_ ] ) * $amount + 0.5 ) }
        0 .. 2;
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

    $spacing = 1 if $spacing < 1;

    # One row lighter than the spacing, never equal to it. A line as thick as
    # the gap between lines is not a thick line, it is no line at all: every
    # row comes out dark and the whole effect collapses into a flat multiply.
    # At the default spacing of three that was the top thirty of the
    # thickness slider's thirty-two positions doing nothing but dimming the
    # picture, which reads as the effect having been turned off.
    my $most = $spacing - 1;
    $most      = 1     if $most < 1;
    $thickness = $most if $thickness > $most;

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
