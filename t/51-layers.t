#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp  ();
use Time::HiRes ();
use Test::More;

use GlitchVape                  ();
use GlitchVape::Context         ();
use GlitchVape::Effect::Screen  ();
use GlitchVape::Effect::Texture ();
use GlitchVape::Pixels          ();
use GlitchVape::Registry        ();
use GlitchVape::Tools           ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# The ways the render was made faster without being made different. Each block
# holds one of them to the thing it replaced: the replaced thing is written
# out here as the oracle, so that what is being claimed is checked rather than
# remembered.

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
    $img->Set( depth => 8 );

    return $img;
}

sub apply
{
    my ( $effect, $img, %params ) = @_;

    my $ctx = GlitchVape::Context->new( image => $img, seed => 3 );
    GlitchVape::Registry->get( $effect )->{ apply }
        ->( $ctx, GlitchVape::Registry->resolve_params( $effect, \%params ) );

    return $ctx->image;
}

sub levels
{
    my ( $a, $b ) = @_;
    return $a->Compare( image => $b, metric => 'PAE' )->Get( 'error' ) * 255;
}

# ---------------------------------------------------------------------------
# Staging through MIFF gives the pixels staging through PNG gave

# Context::magick used to hand the picture to the other process as PNG. After
# an effect like grade the picture holds sixteen-bit values under an
# eight-bit label, and PNG wrote them at eight -- so the MIFF staging rounds
# them first. Without the rounding every pixel moves a level or two.
{
    my $png_staged = sub {
        my ( $ctx, @args ) = @_;
        my $in  = $ctx->tmpfile( '.png' );
        my $out = $ctx->tmpfile( '.png' );
        $ctx->image->Write( $in );
        system( GlitchVape::Tools::magick_argv( $in, @args, $out ) ) == 0
            or die "magick failed\n";
        my $back = Image::Magick->new;
        $back->Read( $out );
        return $back;
    };

    my $img = picture( 160, 120 );
    $img->Modulate( brightness => 107, saturation => 131, hue => 97 );

    my @args = qw(-colorspace YCbCr -colorspace sRGB);

    my $old = $png_staged->(
        GlitchVape::Context->new( image => $img->Clone, seed => 1 ), @args
    );

    my $ctx = GlitchVape::Context->new( image => $img->Clone, seed => 1 );
    $ctx->magick( @args );

    is levels( $old, $ctx->image ), 0,
        'a picture staged through MIFF comes back as it did through PNG';

    # PNG also dropped an alpha channel that held nothing, and an effect that
    # separates the picture into planes counts on that: with the channel
    # kept, a fourth plane joins the three and the recombined picture is
    # nothing like the one that went in.
    my @planes = (
        '-colorspace', 'YCbCr',       '-separate', '(',
        '-clone',      '0',           ')',         '(',
        '-clone',      '1',           ')',         '(',
        '-clone',      '2',           ')',         '-delete',
        '0-2',         '-combine',    '-set',      'colorspace',
        'YCbCr',       '-colorspace', 'sRGB',
    );

    my $opaque = picture( 160, 120 );
    $opaque->Set( alpha => 'on' );

    my $want = $png_staged->(
        GlitchVape::Context->new( image => $opaque->Clone, seed => 1 ), @planes
    );

    $ctx = GlitchVape::Context->new( image => $opaque->Clone, seed => 1 );
    $ctx->magick( @planes );

    is levels( $want, $ctx->image ), 0,
        'and one carrying an opaque alpha channel is separated into three '
        . 'planes, as it was through PNG';

    my $clear = picture( 40, 30 );
    $clear->Set( alpha => 'on' );
    $clear->Evaluate(
        channel  => 'Alpha',
        operator => 'Multiply',
        value    => 0.5
    );

    $ctx = GlitchVape::Context->new( image => $clear, seed => 1 );
    $ctx->magick( '-colorspace', 'sRGB' );

    is $ctx->image->Get( '%[opaque]' ), 'False',
        'while a channel that holds some transparency is kept';
}

# ---------------------------------------------------------------------------
# grain draws its noise in bulk and grains exactly as it did

{
    my $oracle = sub {
        my ( $ctx, $p ) = @_;
        my $rng = $ctx->rng_for( 'grain' );
        my $sd  = $p->{ amount } * 255;
        GlitchVape::Pixels->edit(
            $ctx,
            sub {
                $_[ 0 ]->each_row(
                    sub {
                        my @v = unpack 'C*', $_[ 1 ];
                        for ( my $i = 0 ; $i < @v ; $i += 3 )
                        {
                            my $scale = 1;
                            $scale =
                                1 - $p->{ shadow_bias } *
                                GlitchVape::Pixels::luma( @v[ $i .. $i + 2 ] )
                                / 255
                                if $p->{ shadow_bias };
                            if ( $p->{ mono } )
                            {
                                my $n = $rng->gauss( 0, $sd ) * $scale;
                                $v[ $_ ] =
                                    GlitchVape::Pixels::clamp( $v[ $_ ] + $n )
                                    for $i .. $i + 2;
                            }
                            else
                            {
                                $v[ $_ ] = GlitchVape::Pixels::clamp(
                                    $v[ $_ ] + $rng->gauss( 0, $sd ) * $scale )
                                    for $i .. $i + 2;
                            }
                        }
                        return pack 'C*', @v;
                    }
                );
            }
        );
    };

    for my $mono ( 0, 1 )
    {
        for my $bias ( 0, 0.6 )
        {
            my %p = (
                amount      => 0.12,
                mono        => $mono,
                shadow_bias => $bias,
                size        => 1,
            );

            my @sig;
            for my $how ( $oracle,
                GlitchVape::Registry->get( 'grain' )->{ apply } )
            {
                my $ctx = GlitchVape::Context->new(
                    image => picture( 120, 90 ),
                    seed  => 8
                );
                $ctx->frames( 12 );
                $ctx->frame( 5 );
                $how->( $ctx, \%p );
                push @sig, $ctx->image->Get( 'signature' );
            }

            is $sig[ 1 ], $sig[ 0 ],
                "grain with mono=$mono and shadow_bias=$bias is the grain "
                . 'it always was';
        }
    }
}

# ---------------------------------------------------------------------------
# chroma_bleed smears along the line, to the right

# It was a -motion-blur at +90, which ImageMagick runs up the columns: every
# preset's horizontal bleed was a smear upwards. What is asked here is where
# the square's colour went.
{
    my $square = sub {
        my $img = Image::Magick->new( size => '80x80' );
        $img->Read( 'xc:gray50' );
        $img->Draw(
            primitive => 'rectangle',
            points    => '35,35 45,45',
            fill      => 'red',
        );
        $img->Set( depth => 8 );
        return $img;
    };

    # Against the untouched grey of the same picture, far from the square,
    # rather than against the source: the trip through YCbCr and back moves
    # the whole canvas by a level, and that is not colour going anywhere.
    my $moved = sub {
        my ( $img, $x, $y ) = @_;
        my @p = split /,/, $img->Get( "pixel[$x,$y]" );
        my @q = split /,/, $img->Get( 'pixel[5,5]' );
        my $d = 0;
        $d += abs( $p[ $_ ] - $q[ $_ ] ) / 257 for 0 .. 2;
        return $d;
    };

    # The square is drawn onto a canvas with an alpha channel, all of it
    # opaque, which is also what osd and text leave behind -- and which the
    # staging has to treat as PNG did, or the separation into Y, Cb and Cr
    # finds a fourth plane and the whole canvas comes back white.
    my $bled = apply( 'chroma_bleed', $square->(), amount => 6 );

    cmp_ok $moved->( $bled, 50, 40 ), '>', 10,
        'amount carries colour past the right-hand edge';
    is $moved->( $bled, 30, 40 ) +
        $moved->( $bled, 40, 30 ) +
        $moved->( $bled, 40, 50 ), 0,
        'and nowhere else: not to the left, not above, not below';

    my $down = apply( 'chroma_bleed', $square->(), amount => 0, vertical => 3 );

    cmp_ok $moved->( $down, 40, 30 ) + $moved->( $down, 40, 50 ), '>', 10,
        'vertical carries colour above and below';
    is $moved->( $down, 30, 40 ) + $moved->( $down, 50, 40 ), 0,
        'and not sideways, which the blur it used to be did';
}

# ---------------------------------------------------------------------------
# glare and vignette built small are within a level of built full size

# Both are smooth layers that used to be built and blurred at the size of the
# picture, which was nearly all of their cost. Built smaller and enlarged,
# the layer lands a little off where it would have been, and _layer_scale
# chooses the scale that keeps that under a level for the layer's own slope
# and strength. Here each is rendered both ways -- with the scale forced to 1
# for the reference -- across the settings that decide the scale.
{
    my @cases = (
        [ 'vignette', {} ],
        [ 'vignette', { strength => 0.9, softness => 2 } ],
        [ 'vignette', { size     => 0.7 } ],
        [ 'glare',    {} ],
        [ 'glare',    { width    => 0.6, strength => 0.3, angle => -25 } ],
        [ 'glare',    { width    => 0.1 } ],
        [ 'glare',    { strength => 1 } ],
    );

    for my $size ( [ 720, 540 ], [ 1000, 750 ] )
    {
        my $src = picture( @$size );

        for my $case ( @cases )
        {
            my ( $effect, $params ) = @$case;

            my $small = apply( $effect, $src->Clone, %$params );

            my $full;
            {
                # The reference is the same effect with the scale forced to
                # one, which is the layer built at full size as it always was.
                ## no critic (TestingAndDebugging::ProhibitNoWarnings, Variables::ProtectPrivateVars)
                no warnings 'redefine';
                local *GlitchVape::Effect::Screen::_layer_scale = sub { 1 };
                ## use critic
                $full = apply( $effect, $src->Clone, %$params );
            }

            my $label = join ', ',
                map { "$_=$params->{ $_ }" } sort keys %$params;
            cmp_ok levels( $small, $full ), '<=', 1.0001,
                sprintf '%s (%s) at %dx%d is within a level of the full-size '
                . 'build', $effect, $label || 'defaults', @$size;
        }
    }
}

# ---------------------------------------------------------------------------
# --timing counts fractions of a second

{
    my $ctx = GlitchVape::Context->new( image => picture( 8, 8 ), seed => 1 );
    $ctx->time_effect( 'nap', sub { Time::HiRes::sleep( 0.05 ) } );

    my ( $took ) = map { $_->[ 1 ] } $ctx->timings;
    ok $took > 0.03 && $took < 0.9,
        'a twentieth of a second is timed as one, not as nought';
}

done_testing;
