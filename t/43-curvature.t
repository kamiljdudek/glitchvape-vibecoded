#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape                 ();
use GlitchVape::Context        ();
use GlitchVape::Effect::Screen ();
use GlitchVape::Pipeline       ();
use GlitchVape::Tools          ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# The tube is out of focus at its rim and sharp in its middle.
#
# A real CRT is focused for one point on its face -- the centre of it -- so the
# beam lands a little wider everywhere else and the corners are never as crisp,
# whatever the signal is. That is a fact about the glass rather than about the
# picture, and it is why the bulge alone never read as one: a warped photograph
# is exactly a bulge with a perfectly sharp rim.
#
# What is measured is sharpness itself, region by region, and not the
# difference between two renders. The claim is about where detail survives, so
# a test that asks where the picture *changed* would pass just as well for a
# softness that put the blur in the middle.

my $dir = File::Temp->newdir( 'gv_curve_XXXXXX', TMPDIR => 1 );

# Noise, and nothing but noise: blur is only visible where there is detail to
# lose, and the corner of a gradient has none. Every region of this source has
# exactly as much to lose as every other, which is what makes two of them
# comparable at all.
my $src = "$dir/src.png";
{
    my $img = Image::Magick->new( size => '480x360' );
    $img->Read( 'xc:black' );
    $img->AddNoise( noise => 'Random' );
    my $err = $img->Write( $src );
    BAIL_OUT( "could not build the test source image: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;
}

sub render
{
    my ( %set ) = @_;

    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new(
        image  => $img,
        source => $src,
        seed   => 7,
    );

    GlitchVape::Pipeline->new( effects => { curvature => { %set } } )
        ->run( $ctx );

    return $ctx->image;
}

# How sharp one region of a render is: the average step between neighbouring
# pixels across it. Noise has the largest steps a picture can have, and blur is
# precisely the operation that makes them smaller, so this falls as the region
# goes out of focus and is flat against everything else the effect does.
sub sharpness
{
    my ( $img, $x, $y ) = @_;

    my ( $w, $h ) = ( 120, 90 );
    my @px = $img->GetPixels(
        map       => 'I',
        width     => $w,
        height    => $h,
        x         => $x,
        y         => $y,
        normalize => 1,
    );

    my $total = 0;
    my $steps = 0;

    for my $row ( 0 .. $h - 1 )
    {
        for my $col ( 1 .. $w - 1 )
        {
            my $at = $row * $w + $col;
            $total += abs( $px[ $at ] - $px[ $at - 1 ] );
            $steps++;
        }
    }

    return $steps ? $total / $steps : 0;
}

my $CENTRE = [ 180, 135 ];
my $CORNER = [ 0,   0 ];

# The bulge is left out of the measurements on purpose. It moves every pixel,
# so a distorted render has nothing to compare against -- and the softness is
# not a property of the distortion, which is half of what this file is for.
my $sharp = render( amount => 0, softness => 0 );
my $soft = render( amount => 0, softness => 0.8, focus => 1.2 );

# The source is uniform noise, so this is really a check on the measurement:
# an untouched render must not already look softer at the edge than in the
# middle, or the comparison below would be measuring the source.
my $flat = sharpness( $sharp, @$CORNER ) / sharpness( $sharp, @$CENTRE );
cmp_ok abs( $flat - 1 ), '<', 0.1,
    'an untouched render is equally sharp at its corner and its centre';

cmp_ok sharpness( $soft, @$CORNER ), '<', sharpness( $soft, @$CENTRE ) * 0.8,
    'the softened render has lost detail at the corner';

# The falloff is squared for this: an even ramp from the centre outwards puts
# a third of the blur over the middle of the picture, where it stops reading as
# a tube and starts reading as a soft-focus filter. Noise is the harshest thing
# to ask it of -- there is no finer detail in any picture to lose.
cmp_ok sharpness( $soft, @$CENTRE ), '>',
    sharpness( $sharp, @$CENTRE ) * 0.95,
    'and kept it in the middle, where the tube is focused';

# A softness of zero is not a small softness. Presets written before this
# parameter existed say nothing about it, so the value meaning "leave it alone"
# has to leave every pixel alone rather than nearly all of them.
my $again = render( amount => 0, softness => 0 );
is $sharp->Get( 'signature' ), $again->Get( 'signature' ),
    'softness 0 renders the picture untouched';

# The bulge and the focus are independent settings, and each has to work with
# the other at zero: a softness that appears only once the picture is bowed is
# a slider that does nothing to anybody who reaches for it first.
isnt $sharp->Get( 'signature' ), $soft->Get( 'signature' ),
    'the softness applies with no bulge asked for';

my $bowed = render( amount => 0.08, softness => 0 );
isnt $sharp->Get( 'signature' ), $bowed->Get( 'signature' ),
    'and the bulge applies with no softness asked for';

# focus is the radius of the sharp middle, so widening it moves the falloff
# outwards and the same region of the picture keeps more of its detail.
my $tight = render( amount => 0, softness => 0.8, focus => 0.8 );
my $wide  = render( amount => 0, softness => 0.8, focus => 3 );

cmp_ok sharpness( $wide, @$CORNER ), '>', sharpness( $tight, @$CORNER ),
    'a wider focus keeps more of the picture crisp';

done_testing;
