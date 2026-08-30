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

# ---------------------------------------------------------------------------
# The text effect says how random it is, instead of being random by surprise

# An empty string means "pick me a phrase", and what it left unsaid was how
# often. Every frame, as it turns out, which is a good answer -- but it was the
# answer because of which random stream the effect happened to ask for, not
# because anybody chose it, and there was no way to ask for the other one.
{
    my $frames = 6;

    my $render = sub {
        my ( %params ) = @_;

        my @seen;
        for my $n ( 0 .. $frames - 1 )
        {
            my $img = Image::Magick->new;
            $img->Read( $src );

            my $ctx = GlitchVape::Context->new(
                image  => $img,
                source => $src,
                seed   => 7,
            );
            $ctx->frames( $frames );
            $ctx->frame( $n );

            GlitchVape::Pipeline->new( effects => { text => { %params } } )
                ->run( $ctx );

            push @seen, $ctx->image->Get( 'signature' );
        }

        my %distinct = map { $_ => 1 } @seen;
        return scalar keys %distinct;
    };

    is $render->( size => 20 ), $frames,
        'by default a new phrase is drawn on every frame of a loop';

    is $render->( size => 20, reroll => 0 ), 1,
        'and one held for the whole render is available for a caption that '
        . 'is meant to sit still';

    my $blank = do
    {
        my $img = Image::Magick->new;
        $img->Read( $src );
        $img->Get( 'signature' );
    };

    my $img = Image::Magick->new;
    $img->Read( $src );
    my $ctx =
        GlitchVape::Context->new( image => $img, source => $src, seed => 7 );
    GlitchVape::Pipeline->new(
        effects => { text => { size => 20, invent => 0 } } )->run( $ctx );

    is $ctx->image->Get( 'signature' ), $blank,
        'and an empty phrase with the randomness off draws nothing rather '
        . 'than inventing one';
}

# A phrase that was typed is drawn, and the switch above it is what says so.
# Four presets name a phrase, and under the old rule -- a non-empty string
# simply won -- they said it by writing one; under this one they have to turn
# the randomness off, so this is the assertion that would have caught them
# silently drawing Japanese instead.
{
    my $drawn = sub {
        my ( %params ) = @_;

        my $img = Image::Magick->new;
        $img->Read( $src );

        my $ctx = GlitchVape::Context->new(
            image  => $img,
            source => $src,
            seed   => 7
        );

        GlitchVape::Pipeline->new(
            effects => { text => { size => 20, %params } } )->run( $ctx );

        return $ctx->image->Get( 'signature' );
    };

    isnt $drawn->( string => '電脳', invent => 0 ),
        $drawn->( string => '立体', invent => 0 ),
        'two typed phrases draw two different pictures';

    # The seed is fixed, so a picked phrase is the same picture every time --
    # and the point here is that it is not the typed one.
    isnt $drawn->( string => '電脳', invent => 0 ),
        $drawn->( string => '電脳', invent => 1 ),
        'and leaving the randomness on ignores what was typed';
}

# ---------------------------------------------------------------------------
# The camcorder clock is a fact about the tape, not a texture

# The same mistake the text effect had, in a second place. The fake date and
# time came out of rng_for, which folds the frame index in, so a loop rolled
# through a different random date on every frame -- a display whose whole
# point is to look like it has been sitting there since 1994.
#
# rng_fixed derives under the same label as rng_for, so a still renders the
# identical picture it always did; only the loop changes.
{
    my $frames = 6;

    my $across = sub {
        my ( %params ) = @_;

        my @seen;
        for my $n ( 0 .. $frames - 1 )
        {
            my $img = Image::Magick->new;
            $img->Read( $src );

            my $ctx = GlitchVape::Context->new(
                image  => $img,
                source => $src,
                seed   => 3,
            );
            $ctx->frames( $frames );
            $ctx->frame( $n );

            GlitchVape::Pipeline->new(
                effects => {
                    osd => {
                        timestamp => 1,
                        camera    => q{},
                        size      => 6,
                        %params
                    }
                }
            )->run( $ctx );

            push @seen, $ctx->image->Get( 'signature' );
        }

        my %distinct = map { $_ => 1 } @seen;
        return scalar keys %distinct;
    };

    is $across->(), 1,
        'by default the timestamp is the same on every frame of a loop';

    # Kept as a setting because it turns out to be worth having: a clock that
    # cannot settle on a date is a picture of not remembering when something
    # happened, which is a different thing to want and not a broken clock.
    is $across->( reroll => 1 ), $frames,
        'and a date that riffles through the decade is available';

    my $still = sub {
        my ( %params ) = @_;

        my $img = Image::Magick->new;
        $img->Read( $src );

        my $ctx = GlitchVape::Context->new(
            image  => $img,
            source => $src,
            seed   => 3
        );

        GlitchVape::Pipeline->new(
            effects => {
                osd => {
                    timestamp => 1,
                    camera    => q{},
                    size      => 6,
                    %params
                }
            }
        )->run( $ctx );

        return $ctx->image->Get( 'signature' );
    };

    is $still->( reroll => 1 ), $still->( reroll => 0 ),
        'with no loop to differ across, a still is the same either way';
}

# ---------------------------------------------------------------------------
# The camera indicator is one indicator, and it blinks as a whole

# rec and play were two switches with a label each, so "REC and PLAY at once"
# was a reachable setting and a picture no deck ever showed. One mode replaced
# them, which is what lets the glyph follow the value -- and lets a mode typed
# in by hand blink, which the old dot-only blink could not do for it.
{
    my $frames = 6;

    my $frame = sub {
        my ( $n, %params ) = @_;

        my $img = Image::Magick->new;
        $img->Read( $src );

        my $ctx = GlitchVape::Context->new(
            image  => $img,
            source => $src,
            seed   => 3
        );
        $ctx->frames( $frames );
        $ctx->frame( $n );

        GlitchVape::Pipeline->new(
            effects => {
                osd => { timestamp => 0, rec_mode => q{}, size => 6, %params }
            }
        )->run( $ctx );

        return $ctx->image->Get( 'signature' );
    };

    my $blank = do
    {
        my $img = Image::Magick->new;
        $img->Read( $src );
        $img->Get( 'signature' );
    };

    # Past 0.6 of the way round the loop the indicator is dark, and with
    # nothing else switched on that is the untouched source.
    isnt $frame->( 0, camera => 'REC' ), $blank,
        'the indicator is lit at the start of the loop';
    is $frame->( 5, camera => 'REC' ), $blank,
        'and dark at the end of it, because it blinks';

    is $frame->( 5, camera => 'REC', blink => 0 ),
        $frame->( 0, camera => 'REC', blink => 0 ),
        'blink off holds it lit the whole way round';

    # The label goes with the glyph rather than the glyph alone, which is the
    # only reading under which the setting means anything for a mode that has
    # no glyph.
    is $frame->( 5, camera => 'PAUSE' ), $blank,
        'a mode with no glyph of its own blinks too';

    # A camera mode the program does not recognise is text, not a guess at
    # which button is down.
    isnt $frame->( 0, camera => 'PAUSE' ), $frame->( 0, camera => 'PLAY' ),
        'a typed-in mode draws differently from a known one';
}

# ---------------------------------------------------------------------------
# A flicker is nothing at all on a still

# Every parameter it has is an animation parameter, so on one frame there is
# no time for a ripple to happen in and the picture must come out untouched --
# whatever the depth is set to.
{
    my $img = Image::Magick->new;
    $img->Read( $src );
    my $before = $img->Get( 'signature' );

    my $ctx =
        GlitchVape::Context->new( image => $img, source => $src, seed => 1 );
    GlitchVape::Pipeline->new(
        effects => { flicker => { amount => 0.5, rate => 3 } } )->run( $ctx );

    is $ctx->image->Get( 'signature' ), $before,
        'a still is untouched even at half a stop of ripple';

    # And across a loop it closes, because the rate is snapped to whole cycles.
    my $at = sub {
        my ( $n ) = @_;

        my $one = Image::Magick->new;
        $one->Read( $src );

        my $each = GlitchVape::Context->new(
            image  => $one,
            source => $src,
            seed   => 1
        );
        $each->frames( 12 );
        $each->frame( $n );

        GlitchVape::Pipeline->new(
            effects => { flicker => { amount => 0.2, rate => 3 } } )
            ->run( $each );

        return $each->image->Get( 'signature' );
    };

    isnt $at->( 0 ), $at->( 1 ),  'and it does something once there are frames';
    is $at->( 0 ),   $at->( 12 ), 'coming back to where it started';
}

done_testing;
