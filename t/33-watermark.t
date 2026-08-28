#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape           ();
use GlitchVape::Context  ();
use GlitchVape::Pipeline ();
use GlitchVape::Tools    ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

my $dir = File::Temp->newdir( 'gv_wm_XXXXXX', TMPDIR => 1 );

# Flat and dark, so anything that is not the background is watermark.
my $src = "$dir/src.png";
{
    my $img = Image::Magick->new( size => '480x360' );
    $img->Read( 'xc:#101018' );
    my $err = $img->Write( $src );
    BAIL_OUT( "could not build the test source: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;
}

sub render
{
    my ( %params ) = @_;

    my $frame  = delete $params{ _frame }  // 0;
    my $frames = delete $params{ _frames } // 1;

    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new(
        image  => $img,
        source => $src,
        seed   => 11,
    );
    $ctx->frames( $frames );
    $ctx->frame( $frame );

    GlitchVape::Pipeline->new( effects => { watermark => \%params } )
        ->run( $ctx );

    return $ctx->image;
}

# Ink is anything that is not the background, read straight off the pixels
# rather than through a threshold: the text is drawn antialiased and its edges
# are neither colour.
sub inked
{
    my ( $img, $x0, $y0, $w, $h ) = @_;

    my ( $iw, $ih ) = ( $img->Get( 'width' ), $img->Get( 'height' ) );
    my @px = $img->GetPixels(
        map       => 'I',
        width     => $iw,
        height    => $ih,
        normalize => 1
    );

    my $count = 0;
    for my $y ( $y0 .. $y0 + $h - 1 )
    {
        for my $x ( $x0 .. $x0 + $w - 1 )
        {
            $count++ if $px[ $y * $iw + $x ] > 0.2;
        }
    }

    return $count;
}

# ---------------------------------------------------------------------------
# A rotated watermark still covers the whole frame

# Rotate leaves the layer carrying a virtual canvas offset saying where the
# original sat inside the new bounds, and Crop measures from that rather than
# from the pixels. The window therefore came off the corner of the rotated
# square instead of its middle and left a bare wedge -- a seventh of the frame
# at 45 degrees, and nothing anywhere else in the suite looks at coverage.
{
    for my $rotate ( 0, -30, 45, 70, -60 )
    {
        # Tiled tightly on purpose. The cells below have to be bigger than
        # one repetition or a cell can land in the ordinary gap between two
        # of them and be reported as a hole in the coverage; packing the
        # repetitions closer is what makes a bare cell mean something.
        my $img = render(
            rotate  => $rotate,
            opacity => 1,
            color   => '#FFFFFF',
            size    => 4,
            spacing => 1.4,
        );

        my @bare;
        for my $gy ( 0 .. 5 )
        {
            for my $gx ( 0 .. 7 )
            {
                my $n = inked( $img, $gx * 60, $gy * 60, 60, 60 );
                push @bare, "$gx,$gy" unless $n;
            }
        }

        is_deeply \@bare, [],
            "at rotate $rotate every part of the frame is watermarked";
    }
}

# ---------------------------------------------------------------------------
# A long string does not print over the next repetition

# The column spacing used to come from the point size, which only works while
# the string is about as wide as it is tall. A sentence was drawn across its
# own neighbour and the row became a smear.
{
    my $long = 'PROOF COPY DO NOT DISTRIBUTE';

    my $img = render(
        string  => $long,
        font    => 'ui',
        rotate  => 0,
        opacity => 1,
        color   => '#FFFFFF',
        size    => 5,
    );

    # A gap between repetitions shows up as at least one column of the frame
    # with no ink in it at all. Overlapping repetitions leave none: the row is
    # continuous ink from edge to edge.
    my $clear = 0;
    for my $x ( 0 .. 479 )
    {
        $clear++ unless inked( $img, $x, 0, 1, 120 );
    }

    ok $clear > 0, 'a long string leaves clear columns between its repetitions'
        or diag "no bare column anywhere: the repetitions are overlapping";
}

# ---------------------------------------------------------------------------
# Eight directions, and each one goes where it says

# Asked of the slide rather than of two rendered frames. The pattern repeats,
# so a tile leaving one edge and another arriving at the opposite one look
# alike to anything measuring the picture -- an earlier version of this test
# read the ink centroid and reported every direction backwards.
{
    ## no critic (Variables::ProtectPrivateVars)
    my $slide = \&GlitchVape::Effect::Overlay::_watermark_slide;
    ## use critic

    my %want = (
        north     => [  0, -1 ],
        northeast => [  1, -1 ],
        east      => [  1,  0 ],
        southeast => [  1,  1 ],
        south     => [  0,  1 ],
        southwest => [ -1,  1 ],
        west      => [ -1,  0 ],
        northwest => [ -1, -1 ],
    );

    for my $direction ( sort keys %want )
    {
        my $params = { direction => $direction, drift => 4, rotate => 0 };

        # Two adjacent instants early in a very long loop, so the difference
        # between them is the direction of travel and nothing has wrapped.
        my @from = $slide->( _at( 100_000, 1 ), $params, 100, 100 );
        my @to   = $slide->( _at( 100_000, 2 ), $params, 100, 100 );

        my $moved =
            [ _sign( $to[ 0 ] - $from[ 0 ] ), _sign( $to[ 1 ] - $from[ 1 ] ) ];

        is_deeply $moved, $want{ $direction },
            "direction $direction travels " . uc( $direction );
    }
}

# ---------------------------------------------------------------------------
# Every direction still closes its loop

# t/31-drift.t checks the drift, but only in the default direction. The slide
# is two dimensional now and each axis has its own period, so a diagonal has
# two chances to fail to come back.
{
    for my $direction (
        qw(north northeast east southeast south southwest west northwest) )
    {
        my $first = render(
            direction => $direction,
            drift     =>  5,
            rotate    => -30,
            _frame    =>  0,
            _frames   =>  12,
        )->Get( 'signature' );

        my $wrap = render(
            direction => $direction,
            drift     =>  5,
            rotate    => -30,
            _frame    =>  12,
            _frames   =>  12,
        )->Get( 'signature' );

        ok $first eq $wrap, "drifting $direction comes back to the first frame";
    }
}

sub _at
{
    my ( $frames, $frame ) = @_;

    my $ctx = GlitchVape::Context->new( seed => 1 );
    $ctx->frames( $frames );
    $ctx->frame( $frame );

    return $ctx;
}

sub _sign
{
    my ( $value ) = @_;

    return 0 if abs( $value ) < 1e-9;
    return $value < 0 ? -1 : 1;
}

done_testing;
