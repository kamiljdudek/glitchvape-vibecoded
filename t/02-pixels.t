#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use GlitchVape::Pixels;

# Row displacement underpins every signal and glitch effect, so it is worth
# checking against hand-computed expectations rather than only end to end.

my $W   = 4;
my $row = pack 'C*', ( 10, 10, 10 ),    # pixel 0
    ( 20, 20, 20 ),                     # pixel 1
    ( 30, 30, 30 ),                     # pixel 2
    ( 40, 40, 40 );                     # pixel 3

sub pixels_of
{
    [ map { $_->[ 0 ] } _triples( $_[ 0 ] ) ]
}

sub _triples
{
    my @v = unpack 'C*', $_[ 0 ];
    my @out;
    push @out, [ splice @v, 0, 3 ] while @v;
    return @out;
}

{
    my $out = GlitchVape::Pixels::shift_row( $row, $W, 0, 1 );
    is_deeply pixels_of( $out ), [ 10, 20, 30, 40 ], 'zero shift is a no-op';
}

{
    my $out = GlitchVape::Pixels::shift_row( $row, $W, 1, 1 );
    is_deeply pixels_of( $out ), [ 40, 10, 20, 30 ], 'wrap right by 1 rotates';

    $out = GlitchVape::Pixels::shift_row( $row, $W, -1, 1 );
    is_deeply pixels_of( $out ), [ 20, 30, 40, 10 ], 'wrap left by 1 rotates';

    $out = GlitchVape::Pixels::shift_row( $row, $W, $W, 1 );
    is_deeply pixels_of( $out ), [ 10, 20, 30, 40 ],
        'wrapping by the full width returns the original';
}

# Direction matters for smear: getting the sign wrong duplicates the wrong
# edge, which looks plausible in isolation and wrong in a sequence.
{
    my $out = GlitchVape::Pixels::shift_row( $row, $W, 1, 0 );
    is_deeply pixels_of( $out ), [ 10, 10, 20, 30 ],
        'smear right duplicates the left edge';

    $out = GlitchVape::Pixels::shift_row( $row, $W, -1, 0 );
    is_deeply pixels_of( $out ), [ 20, 30, 40, 40 ],
        'smear left duplicates the right edge';

    $out = GlitchVape::Pixels::shift_row( $row, $W, 2, 0 );
    is_deeply pixels_of( $out ), [ 10, 10, 10, 20 ], 'smear right by 2';
}

{
    for my $shift ( -10, -4, -1, 0, 1, 4, 10 )
    {
        for my $wrap ( 0, 1 )
        {
            my $out = GlitchVape::Pixels::shift_row( $row, $W, $shift, $wrap );
            is length( $out ), length( $row ),
                "shift $shift (wrap=$wrap) preserves row length";
        }
    }
}

{
    my $band = $row x 3;
    my $out  = GlitchVape::Pixels::shift_band( $band, $W, 3, 1, 1 );
    is length( $out ), length( $band ), 'shift_band preserves length';

    my $stride = $W * 3;
    for my $r ( 0 .. 2 )
    {
        is_deeply pixels_of( substr $out, $r * $stride, $stride ),
            [ 40, 10, 20, 30 ], "band row $r shifted identically";
    }
}

{
    is GlitchVape::Pixels::clamp( -5 ),   0,   'clamp floors at 0';
    is GlitchVape::Pixels::clamp( 300 ),  255, 'clamp ceils at 255';
    is GlitchVape::Pixels::clamp( 12.7 ), 12,  'clamp truncates to an integer';

    cmp_ok abs( GlitchVape::Pixels::luma( 255, 255, 255 ) - 255 ), '<', 0.01,
        'luma of white is full scale';
    is GlitchVape::Pixels::luma( 0, 0, 0 ), 0, 'luma of black is zero';
    cmp_ok GlitchVape::Pixels::luma( 0, 255, 0 ), '>',
        GlitchVape::Pixels::luma( 0, 0, 255 ),
        'green weighs more than blue';
}

SKIP:
{
    skip 'Image::Magick not available', 4
        unless eval { require Image::Magick; 1 };

    my $img = Image::Magick->new( size => '8x4' );
    $img->Read( 'xc:#204060' );

    my $px = GlitchVape::Pixels->from_image( $img );
    is $px->width,          8,         'buffer width matches';
    is $px->height,         4,         'buffer height matches';
    is length( $px->data ), 8 * 4 * 3, 'buffer holds one byte per channel';

    # A full round trip must survive: this is the path every pixel effect uses
    # to get its work back into the image.
    $px->set_row( 0, "\xFF" x ( 8 * 3 ) );
    my $back = $px->to_image;
    my @top  = $back->GetPixels(
        width     => 1,
        height    => 1,
        x         => 0,
        y         => 0,
        map       => 'RGB',
        normalize => 1,
    );
    cmp_ok $top[ 0 ], '>', 0.9,
        'writes survive the round trip back to an image';
}

done_testing;
