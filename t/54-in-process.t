#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape                  ();
use GlitchVape::Context         ();
use GlitchVape::Effect::Color   ();
use GlitchVape::Effect::Overlay ();
use GlitchVape::Effect::Screen  ();
use GlitchVape::Effect::Texture ();
use GlitchVape::Palette         ();
use GlitchVape::Raster          ();
use GlitchVape::Registry        ();
use GlitchVape::Tools           ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# The effects that stopped shelling out to the command line and do the same
# work through the binding, in this process -- GlitchVape::Context/in_process.
# Each is held to the command line it replaced, which is written out here as
# the oracle: the same arguments, run through Context::magick as they were.
#
# Held to the bit, and to the form of the picture as well as its pixels where
# the next effect can tell the difference: one that quantizes does nothing to
# a palette picture that already has few enough colours.

my $cache = File::Temp->newdir( 'gv_inproc_XXXXXX', TMPDIR => 1 );

# The oracles reach into the effects for the helpers the effects themselves
# use -- a halftone's creep, a duotone's stops, a dither's offset -- because
# what is being checked is the command line against the binding, and those
# are the same on both sides of it.
## no critic (Subroutines::ProtectPrivateSubs)

sub picture
{
    my ( $w, $h ) = @_;

    my $img = Image::Magick->new( size => "${w}x$h" );
    $img->Read( 'gradient:#102050-#F0C080' );
    $img->Draw(
        primitive => 'rectangle',
        points    => join( ',', int( $w * .2 ), int( $h * .2 ) ) . ' '
            . join( ',', int( $w * .6 ), int( $h * .7 ) ),
        fill => '#E02070',
    );
    $img->Draw(
        primitive => 'circle',
        points    => join( ',', int( $w * .8 ), int( $h * .5 ) ) . ' '
            . join( ',', int( $w * .9 ), int( $h * .5 ) ),
        fill => '#20E0A0',
    );
    $img->Set( depth => 8 );

    return $img;
}

# What the effects are actually handed: a picture grade has been through,
# holding sixteen-bit values under an eight-bit label -- and carrying the mark
# the binding's Modulate leaves on it, which is the reason the trip in
# in_process exists.
my %INPUT;
{
    my $graded = picture( 160, 120 );
    $graded->Modulate( brightness => 107, saturation => 131, hue => 97 );
    $INPUT{ graded } = $graded;

    # And with an alpha channel that holds nothing, as osd and text leave.
    my $opaque = picture( 160, 120 );
    $opaque->Set( alpha => 'on' );
    $INPUT{ 'opaque alpha' } = $opaque;
}

sub context
{
    my ( $img, %frame ) = @_;

    my $ctx = GlitchVape::Context->new(
        image    => $img->Clone,
        seed     => 3,
        cachedir => "$cache",
    );

    if ( $frame{ frames } )
    {
        $ctx->frames( $frame{ frames } );
        $ctx->frame( $frame{ frame } );
    }

    return $ctx;
}

sub params { return GlitchVape::Registry->resolve_params( @_ ) }

sub levels
{
    my ( $a, $b ) = @_;
    return 'sizes differ'
        unless join( 'x', $a->Get( 'width', 'height' ) ) eq
        join( 'x', $b->Get( 'width', 'height' ) );
    return $a->Compare( image => $b, metric => 'PAE' )->Get( 'error' ) * 255;
}

# Run $oracle and the effect on fresh contexts over each input, and compare.
sub same
{
    my ( $effect, $p, $oracle, %frame ) = @_;

    for my $name ( sort keys %INPUT )
    {
        my $want = context( $INPUT{ $name }, %frame );
        $oracle->( $want, $p );

        my $got = context( $INPUT{ $name }, %frame );
        GlitchVape::Registry->get( $effect )->{ apply }->( $got, $p );

        is levels( $want->image, $got->image ), 0,
            "$effect, on a picture with $name: the pixels the command line gave";
        is $got->image->Get( 'class' ), $want->image->Get( 'class' ),
            '  and in the same form';
    }

    return;
}

# ---------------------------------------------------------------------------
# A tile laid over the picture and multiplied

{
    my $settings = params( 'scanlines', { spacing => 4, softness => 0.5 } );

    same(
        'scanlines',
        $settings,
        sub {
            my ( $ctx, $p ) = @_;
            my $tile = GlitchVape::Raster::scanline_tile(
                $ctx->cachedir,
                spacing   => $p->{ spacing },
                thickness => $p->{ thickness },
                opacity   => $p->{ opacity },
                softness  => $p->{ softness },
                offset    => 0,
            );
            $ctx->magick( GlitchVape::Raster::tiled( $ctx, $tile, $ctx->dims ),
                '-compose', 'Multiply', '-composite' );
        }
    );

    $settings =
        params( 'grille', { width => 2, strength => 0.5, brighten => 1.2 } );

    same(
        'grille',
        $settings,
        sub {
            my ( $ctx, $p ) = @_;
            my $tile = GlitchVape::Raster::grille_tile(
                $ctx->cachedir,
                width    => $p->{ width },
                strength => $p->{ strength },
            );
            $ctx->magick( GlitchVape::Raster::tiled( $ctx, $tile, $ctx->dims ),
                '-compose', 'Multiply', '-composite' );
            $ctx->image->Modulate( brightness => $p->{ brighten } * 100 );
        }
    );
}

# ---------------------------------------------------------------------------
# Ordered dither, under a matrix the picture is moved beneath

{
    my $settings = params( 'halftone',
        { map => 'h6x6a', levels => 3, strength => 0.6, drift => 2 } );

    same(
        'halftone',
        $settings,
        sub {
            my ( $ctx, $p ) = @_;
            my $orig  = $ctx->clone;
            my $creep = GlitchVape::Effect::Screen::_halftone_creep( $ctx, $p );
            $ctx->magick( '-roll', sprintf '%+d%+d', $creep, $creep )
                if $creep;
            $ctx->magick( '-ordered-dither', "$p->{map},$p->{levels}" );
            $ctx->magick( '-roll', sprintf '%+d%+d', -$creep, -$creep )
                if $creep;
            $ctx->image->Composite(
                image   => $orig->[ 0 ],
                compose => 'Blend',
                args    => int( ( 1 - $p->{ strength } ) * 100 + 0.5 ),
            );
        },
        frames => 8,
        frame  => 3,
    );

    $settings = params( 'dither', { map => 'o3x3', levels => 2, reroll => 1 } );

    same(
        'dither',
        $settings,
        sub {
            my ( $ctx, $p ) = @_;
            my ( $dx, $dy ) =
                GlitchVape::Effect::Texture::_dither_offset( $ctx, $p );
            $ctx->magick( '-roll', sprintf( '%+d%+d', $dx, $dy ) )
                if $dx || $dy;
            $ctx->magick( '-ordered-dither', "$p->{map},$p->{levels}" );
            $ctx->magick( '-roll',           sprintf( '%+d%+d', -$dx, -$dy ) )
                if $dx || $dy;
        },
        frames => 8,
        frame  => 5,
    );
}

# ---------------------------------------------------------------------------
# A palette, by remapping -- whose form depends on the dither

for my $dither ( qw(none floydsteinberg riemersma) )
{
    my $settings =
        params( 'palette', { name => 'gameboy', dither => $dither } );

    same(
        'palette',
        $settings,
        sub {
            my ( $ctx, $p ) = @_;
            my $remap = GlitchVape::Palette::remap_file(
                GlitchVape::Effect::Color::_palette_spec( $p ),
                $ctx->cachedir );
            $ctx->magick( '-dither', $p->{ dither }, '-remap', $remap );
        }
    );
}

# ---------------------------------------------------------------------------
# Grey, then a colour ramp

{
    my $settings = params( 'duotone', { contrast => 35, strength => 1 } );

    same(
        'duotone',
        $settings,
        sub {
            my ( $ctx, $p ) = @_;
            my $clut = GlitchVape::Palette::gradient_file(
                GlitchVape::Effect::Color::_duotone_stops( $ctx, $p ),
                $ctx->cachedir );
            $ctx->magick( '-colorspace', 'Gray', '-brightness-contrast',
                "0x$p->{contrast}", $clut, '-clut' );
        }
    );

    $settings = params( 'gradient_map', { strength => 1 } );

    same(
        'gradient_map',
        $settings,
        sub {
            my ( $ctx, $p ) = @_;
            my $stops = GlitchVape::Effect::Color::_swap_at(
                $ctx,
                GlitchVape::Palette::colors(
                    GlitchVape::Effect::Color::_palette_spec( $p )
                ),
                $p->{ swap }
            );
            my $clut =
                GlitchVape::Palette::gradient_file( $stops, $ctx->cachedir );
            $ctx->magick( '-colorspace', 'Gray', $clut, '-clut' );
        }
    );
}

# ---------------------------------------------------------------------------
# The colour smeared, without pulling the planes apart

{
    my $settings = params( 'chroma_bleed',
        { amount => 9, vertical => 1.5, saturation => 1.25 } );

    same(
        'chroma_bleed',
        $settings,
        sub {
            my ( $ctx, $p ) = @_;
            my @chroma = (
                '-morphology',
                'Correlate',
                GlitchVape::Effect::Color::_trail_kernel( $p->{ amount } ),
                '-morphology',
                'Convolve',
                sprintf( 'Blur:0x%.3f,90', $p->{ vertical } ),
            );
            $ctx->magick(
                '-colorspace', 'YCbCr',      '-separate', '(',
                '-clone',      '0',          ')',         '(',
                '-clone',      '1',          @chroma,     ')',
                '(',           '-clone',     '2',         @chroma,
                ')',           '-delete',    '0-2',       '-combine',
                '-set',        'colorspace', 'YCbCr',     '-colorspace',
                'sRGB',
            );
            $ctx->image->Modulate( saturation => $p->{ saturation } * 100 );
        }
    );

    # The one place the two part company, and the old one was wrong: with
    # transparency in the picture, -separate made four planes and the
    # alpha was recombined as a colour. Nothing in the program hands this
    # effect such a picture -- loading drops alpha and nothing before it
    # adds any -- so this pins the repair rather than a change anybody saw.
    my $flat = Image::Magick->new( size => '40x30' );
    $flat->Read( 'xc:#FF71CE' );
    $flat->Set( alpha => 'on' );
    $flat->Evaluate( channel => 'Alpha', operator => 'Multiply', value => 0.4 );

    my $ctx = context( $flat );
    GlitchVape::Registry->get( 'chroma_bleed' )->{ apply }
        ->( $ctx, params( 'chroma_bleed', { amount => 6 } ) );

    my @rgba = split /,/, $ctx->image->Get( 'pixel[20,15]' );
    my $q    = Image::Magick->QuantumRange;
    is_deeply [ map { int( $_ / $q * 255 + 0.5 ) } @rgba ],
        [ 255, 113, 206, 102 ],
        'a flat translucent picture keeps its colour and its alpha';
}

# ---------------------------------------------------------------------------
# Shapes drawn on the picture, a staging each

{
    my $draw = sub {
        my ( $how ) = @_;
        my $ctx = context( $INPUT{ graded } );

        if ( $how eq 'oracle' )
        {
            $ctx->magick(
                '-fill',   '#FF2020',
                '-stroke', 'none',
                '-draw',   'circle 30,40 40,40'
            );
            $ctx->magick(
                '-fill',   '#FFFFFF',
                '-stroke', 'none',
                '-draw',   'polygon 60,20 60,60 94,40'
            );
            $ctx->magick(
                '-fill',   '#FFFFFF',
                '-stroke', 'none',
                '-draw',   'polygon 81,20 81,60 115,40'
            );
        }
        else
        {
            GlitchVape::Effect::Overlay::_osd_draw( $ctx, '#FF2020', 'circle',
                '30,40 40,40' );
            GlitchVape::Effect::Overlay::_osd_draw( $ctx, '#FFFFFF', 'polygon',
                '60,20 60,60 94,40' );
            GlitchVape::Effect::Overlay::_osd_draw( $ctx, '#FFFFFF', 'polygon',
                '81,20 81,60 115,40' );
        }

        return $ctx->image;
    };

    is levels( $draw->( 'oracle' ), $draw->( 'binding' ) ), 0,
        "osd's record lamp and overlapping fast-wind triangles are drawn as "
        . 'the command line drew them';
}

# ---------------------------------------------------------------------------
# Bars and a border, whose colours were options of the run and not of the
# picture

{
    my $settings = params( 'letterbox',
        { ratio => '16:9', border => 0.05, color => '#FF71CE' } );

    same(
        'letterbox',
        $settings,
        sub {
            my ( $ctx, $p ) = @_;
            my ( $w,   $h ) = $ctx->dims;
            my $target = 16 / 9;
            my ( $nw, $nh ) =
                $w / $h > $target
                ? ( $w, int( $w / $target ) )
                : ( int( $h * $target ), $h );
            $ctx->magick(
                '-background', $p->{ color }, '-gravity', 'Center',
                '-extent',     "${nw}x${nh}"
            );
            my $b = int( ( $nw < $nh ? $nw : $nh ) * $p->{ border } );
            $ctx->magick( '-bordercolor', $p->{ color }, '-border', $b );
        }
    );

    my $ctx = context( $INPUT{ graded } );
    my $was = $ctx->image->Get( 'background' );
    GlitchVape::Registry->get( 'letterbox' )->{ apply }->( $ctx, $settings );

    is $ctx->image->Get( 'background' ), $was,
        'and the bar colour is not left behind for the next effect to fill with';
}

# ---------------------------------------------------------------------------
# The bulge, then the zoom that hides its corners

{
    my $settings = params( 'curvature', { amount => 0.12, zoom => 1.15 } );

    same(
        'curvature',
        $settings,
        sub {
            my ( $ctx, $p ) = @_;
            my ( $w,   $h ) = $ctx->dims;
            $ctx->magick(
                '-virtual-pixel', 'background',
                '-background',    $p->{ background },
                '-distort',       'Barrel',
                sprintf( '0.0 0.0 %.5f', $p->{ amount } ),
            );
            $ctx->magick(
                '-resize',
                int( $w * $p->{ zoom } ) . 'x' . int( $h * $p->{ zoom } ) . '!',
                '-gravity',
                'Center',
                '-extent',
                "${w}x${h}",
            );
            GlitchVape::Effect::Screen::_defocus_rim( $ctx, $p );
        }
    );
}

# ---------------------------------------------------------------------------
# One run of the command line, which stays one staging

{
    my $settings = params(
        'bitmap',
        {
            factor  => 5,
            palette => 'spectrum',
            matrix  => 'o4x4',
            amount  => 0.25,
            reroll  => 1,
        }
    );

    same(
        'bitmap',
        $settings,
        sub {
            my ( $ctx, $p )  = @_;
            my ( $w,   $h )  = $ctx->dims;
            my ( $sw,  $sh ) = ( int( $w / 5 ), int( $h / 5 ) );
            my $remap = GlitchVape::Palette::remap_file( $p->{ palette },
                $ctx->cachedir );
            my $tile = GlitchVape::Effect::Texture::_bayer_file( $p->{ matrix },
                $ctx->cachedir );
            my ( $dx, $dy ) =
                GlitchVape::Effect::Texture::_bitmap_offset( $ctx, $p );
            $ctx->magick(
                '-filter',
                'Point',
                '-resize',
                "${sw}x${sh}!",
                ( $dx || $dy ? ( '-roll', sprintf '%+d%+d', $dx, $dy ) : () ),
                '(', '-size',
                "${sw}x${sh}",
                "tile:$tile",
                ')',
                '-compose',
                'Mathematics',
                '-define',
                sprintf(
                    'compose:args=0,%.4f,1,%.4f',
                    $p->{ amount },
                    -$p->{ amount } / 2
                ),
                '-composite',
                ( $dx || $dy ? ( '-roll', sprintf '%+d%+d', -$dx, -$dy ) : () ),
                '-dither',
                'None', '-remap', $remap,
                '-filter',
                'Point',
                '-resize',
                "${w}x${h}!",
            );
        },
        frames => 8,
        frame  => 2,
    );
}

# ---------------------------------------------------------------------------
# Why the trip through MIFF is still made

# grade's Modulate leaves modulate:colorspace=HSB on the picture, and the next
# Modulate not told otherwise works in that. A picture read back from a file
# has forgotten it, and every effect after a staging was handed it so.
{
    my $staged = sub {
        my ( $how ) = @_;
        my $ctx = context( $INPUT{ graded } );

        if ( $how eq 'file' ) { $ctx->magick( '-colorspace', 'sRGB' ) }
        else
        {
            $ctx->in_process( sub { } );
        }

        $ctx->image->Modulate( saturation => 125 );
        return $ctx->image;
    };

    is levels( $staged->( 'file' ), $staged->( 'memory' ) ), 0,
        'a staging in this process forgets what one through a file forgot';
}

## use critic

done_testing;
