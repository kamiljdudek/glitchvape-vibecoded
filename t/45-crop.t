#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape                  ();
use GlitchVape::Context         ();
use GlitchVape::Effect::Texture ();
use GlitchVape::Pipeline        ();
use GlitchVape::Registry        ();
use GlitchVape::Tools           ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# What a crop promises, and the two halves of it that can quietly stop being
# true.
#
# The frame is the largest rectangle of the chosen shape that the picture
# could hold -- which is a claim about arithmetic, and one that reads the same
# whether the comparison is the right way round or backwards. Getting it
# backwards asks for a frame bigger than the thing it is cut out of, and
# ImageMagick answers that by leaving the picture alone, so the effect looks
# like a setting that does nothing rather than like a bug.
#
# And zoom magnifies rather than shrinks, which is what the word says. The
# frame that comes out has to be the same size at every zoom, or the rest of
# the chain is handed a smaller canvas at every setting above 1 and the export
# changes size with a slider nobody thought was about size.

my $dir = File::Temp->newdir( 'gv_crop_XXXXXX', TMPDIR => 1 );

# A straight ramp, running one way only. A picture whose brightness changes
# monotonically along one axis is what lets "where did the crop land" be read
# off an average -- and a ramp at an angle would not do, because rotating one
# clips at the corners and the average stops being monotonic exactly where the
# test is looking.
sub source
{
    my ( $w, $h, $along ) = @_;

    $along ||= 'down';

    my $path = "$dir/src-${w}x$h-$along.png";
    return $path if -e $path;

    # ImageMagick's gradient runs top to bottom, so the other one is that one
    # turned a quarter: built the tall way round and rotated into shape.
    my $img =
        Image::Magick->new(
        size => $along eq 'across' ? "${h}x$w" : "${w}x$h" );
    $img->Read( 'gradient:black-white' );
    $img->Rotate( degrees => 90 ) if $along eq 'across';
    $img->Set( page => '0x0+0+0' );

    my $err = $img->Write( $path );
    BAIL_OUT( "could not build the test source image: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;

    return $path;
}

sub render
{
    my ( $src, %given ) = @_;

    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new(
        image  => $img,
        source => $src,
        seed   => 7,
    );

    GlitchVape::Pipeline->new( effects => { crop => { %given } } )->run( $ctx );

    return $ctx->image;
}

sub dims { return $_[ 0 ]->Get( 'width', 'height' ) }

# The shapes, as the effect's own documentation gives them.
my %RATIO = (
    square   => 1 / 1,
    classic  => 4 / 3,
    wide     => 16 / 9,
    cinema   => 2.39,
    portrait => 4 / 5,
    tall     => 9 / 16,
);

# ---------------------------------------------------------------------------
# Every shape is declared, and every declared shape is tested

# Driven off the registry rather than off the list above, so a shape added to
# the effect and not to this file is a failure rather than a silence.
{
    my $spec = GlitchVape::Registry->get( 'crop' );
    ok $spec, 'crop is registered';

    my @values = @{ $spec->{ params }{ shape }{ values } };

    is_deeply [ sort grep { $_ ne 'none' } @values ], [ sort keys %RATIO ],
        'every shape the effect offers is one this file knows the ratio of';

    is $spec->{ stage }, 'format',
        'and it runs at format, so the rest of the chain works on what is left';
}

# ---------------------------------------------------------------------------
# The frame is the largest rectangle of that shape that fits

# Asked of a landscape source and a portrait one, because the arithmetic
# branches on which edge runs out first and a test with only one orientation
# exercises one branch.
for my $size ( [ 600, 400 ], [ 400, 600 ] )
{
    my ( $w, $h ) = @$size;
    my $src = source( $w, $h );

    for my $shape ( sort keys %RATIO )
    {
        my ( $cw, $ch ) = dims( render( $src, shape => $shape ) );

        ok( ( $cw <= $w && $ch <= $h ),
            "${w}x$h cropped to $shape fits inside the picture" )
            or diag "got ${cw}x$ch";

        # One edge has to be the source's own, or the rectangle was not the
        # largest one available.
        ok $cw == $w || $ch == $h, "and touches the edge it was limited by";

        my $got  = $cw / $ch;
        my $want = $RATIO{ $shape };

        # A pixel of rounding on the short edge, which is all int() can cost.
        cmp_ok abs( $got - $want ) / $want, '<', 0.01,
            "and comes out $shape shaped"
            or diag sprintf 'wanted %.3f, got %.3f', $want, $got;
    }
}

# ---------------------------------------------------------------------------
# Zoom magnifies; it does not shrink the frame

# The whole reason the crop is resized afterwards. Without it the word "zoom"
# would mean "hand everything downstream a smaller picture", and the exported
# file would change size with a slider nobody thought was about size.
{
    my $src = source( 600, 400 );

    for my $shape ( qw(none wide portrait) )
    {
        my @at_one = dims( render( $src, shape => $shape ) );

        for my $zoom ( 1.5, 2, 4, 8 )
        {
            my @at_zoom =
                dims( render( $src, shape => $shape, zoom => $zoom ) );

            is_deeply \@at_zoom, \@at_one,
                "$shape at zoom $zoom comes out the size it does at zoom 1";
        }
    }
}

# ---------------------------------------------------------------------------
# And it does move in on the picture

# The frame staying the same size is exactly what makes the previous block
# unable to tell a zoom from a no-op, so the content has to be asked about
# separately: a magnified picture is a smoother one, because the same number
# of source pixels is spread over more of them. Read along the ramp, where
# there is something to be smooth.
{
    my $src = source( 600, 400, 'across' );

    my $rough  = _detail( render( $src, shape => 'none' ) );
    my $smooth = _detail( render( $src, shape => 'none', zoom => 6 ) );

    cmp_ok $smooth, '<', 0.6 * $rough,
        'zooming in spreads the same pixels over more of them'
        or diag sprintf 'detail %.4f against %.4f', $smooth, $rough;
}

# How much a picture changes from one pixel to the next, averaged. An
# enlargement has less of it than the thing it was enlarged from, whatever
# either of them is a picture of.
sub _detail
{
    my ( $img ) = @_;

    my ( $w, $h ) = dims( $img );
    my @row = $img->GetPixels(
        map       => 'I',
        normalize => 1,
        x         => 0,
        y         => int( $h / 2 ),
        width     => $w,
        height    => 1
    );

    my $sum = 0;
    $sum += abs( $row[ $_ ] - $row[ $_ - 1 ] ) for 1 .. $#row;

    return $sum / ( @row - 1 );
}

# ---------------------------------------------------------------------------
# Across and Down choose what is inside

# They are measured across whatever slack the shape and the zoom left, so 0 is
# against one edge and 1 against the other however much room there is. On a
# gradient that runs corner to corner, that is readable straight off the
# average brightness.
{
    my $src = source( 600, 400 );

    my $across = source( 600, 400, 'across' );

    my %at;
    for my $where ( 0, 0.5, 1 )
    {
        # Each axis against the ramp that runs along it, so a move of the
        # frame is a move of the average and nothing else is.
        $at{ "x$where" } = _mean(
            render(
                $across,
                shape => 'none',
                zoom  => 3,
                x     => $where
            )
        );
        $at{ "y$where" } =
            _mean( render( $src, shape => 'none', zoom => 3, y => $where ) );
    }

    cmp_ok $at{ x0 }, '!=', $at{ x1 },
        'the two ends of Across are different places in the picture';
    cmp_ok $at{ y0 }, '!=', $at{ y1 }, 'and so are the two ends of Down';

    # And the middle is between them, which is what says the control slides
    # rather than merely switching.
    for my $axis ( qw(x y) )
    {
        my ( $lo, $mid, $hi ) = @at{ "${axis}0", "${axis}0.5", "${axis}1" };

        ( $lo, $hi ) = ( $hi, $lo ) if $lo > $hi;

        ok $mid > $lo && $mid < $hi,
            "the middle of $axis is between its two ends";
    }
}

sub _mean
{
    my ( $img ) = @_;

    my ( $w, $h ) = dims( $img );
    my @px = $img->GetPixels(
        map       => 'I',
        normalize => 1,
        x         => 0,
        y         => 0,
        width     => $w,
        height    => $h
    );

    my $sum = 0;
    $sum += $_ for @px;

    return $sum / @px;
}

# ---------------------------------------------------------------------------
# Switched on, it does something; asked for nothing, it does nothing

# Both halves matter and they pull against each other. An effect added to a
# pipeline and changing nothing is one nobody can tell they have added, which
# is what t/10-render.t sweeps for -- so the shape it starts at is a real one.
# But a crop is also the one effect here whose neutral setting is an option
# rather than an omission, and 'none' at a zoom of 1 has to be exactly that.
{
    my $src = source( 600, 400 );

    my ( $w, $h ) = dims( render( $src ) );

    ok( ( $w < 600 || $h < 400 ),
        'crop at its declared defaults reframes rather than sitting there' )
        or diag "got ${w}x$h from 600x400";

    my $img = Image::Magick->new;
    $img->Read( $src );

    is _pixels( render( $src, shape => 'none', zoom => 1 ) ), _pixels( $img ),
        'and at no shape and no zoom it leaves the picture alone';
}

# The pixels rather than a written file: a PNG carries the time it was made,
# so two identical pictures encoded a second apart are different files.
sub _pixels
{
    my ( $img ) = @_;

    my ( $w, $h ) = dims( $img );

    return join q{,},
        $img->GetPixels(
        map    => 'RGB',
        x      => 0,
        y      => 0,
        width  => $w,
        height => $h
        );
}

# ---------------------------------------------------------------------------
# The crop leaves no history behind it

# ImageMagick remembers where a crop came from, and the page offset it keeps
# reappears as transparent margins the moment anything composites onto the
# result -- which most of the chain after format does. It is cleared, and this
# is the only place that would notice if it stopped being.
{
    my $src = source( 600, 400 );

    for my $shape ( qw(wide portrait square) )
    {
        my $img = render( $src, shape => $shape, zoom => 2 );

        # '0x0+0+0' is ImageMagick for "this picture is not part of anything
        # larger". Left alone a crop says '600x400+140+31' instead, and says
        # it all the way into the written file.
        is $img->Get( 'page' ), '0x0+0+0',
            "a $shape crop comes back with no page offset on it";
    }
}

done_testing;
