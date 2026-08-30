#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape           ();
use GlitchVape::Context  ();
use GlitchVape::Pipeline ();
use GlitchVape::Registry ();
use GlitchVape::Tools    ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# A frozen glitch is a look, and it used to be unreachable.
#
# Every damage effect draws from rng_for, which folds the frame index into the
# stream, so a loop is damaged differently on every frame -- a tape being
# chewed while it plays. The other reading was not available at all: the same
# corruption held for the whole loop, a frame that broke once and stayed
# broken, which is a staple of the genre.
#
# `reroll` is that switch, and what is pinned here is both halves of it: off
# really does hold the picture still across a loop, and on really does not.
#
# Driven off the registry rather than a list, so an effect that grows a reroll
# is covered the day it is declared and not the day somebody remembers this
# file.

my $dir = File::Temp->newdir( 'gv_reroll_XXXXXX', TMPDIR => 1 );

# Structure in both axes, and deliberately not a smooth ramp. Several of these
# effects move pixels along a row, and a row of a vertical gradient is a row
# of identical pixels -- sorting or shifting one changes nothing, so a flat
# wash would report "held still" for an effect that was boiling merrily.
my $src = "$dir/src.png";
{
    my $img = Image::Magick->new( size => '240x180' );
    $img->Read( 'plasma:fractal' );

    my $err = $img->Write( $src );
    BAIL_OUT( "could not build the test source image: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;
}

my $registry = 'GlitchVape::Registry';

my @rerollers =
    sort grep { $registry->get( $_ )->{ params }{ reroll } } $registry->names;

ok scalar @rerollers, 'some effects declare a reroll'
    or BAIL_OUT( 'none found' );
diag "reroll is declared by: @rerollers";

# What an effect needs set before the question can be asked of it at all. Two
# effects need something, for opposite reasons, and both are worth recording.
#
# pixelsort asks the RNG which lines to sort, and at the default coverage of 1
# the answer is always "all of them" -- so it consults no randomness until
# coverage comes down, which makes its reroll switch look broken at defaults
# and is said in the parameter's own documentation for that reason.
#
# osd blinks its camera indicator, which is motion around the loop rather than
# randomness: it varies frame to frame whatever reroll says, and would answer
# this test's question with a fact about a different parameter.
my %NUDGE = (
    pixelsort => { coverage => 0.5 },
    osd       => { blink    => 0 },
);

# One frame, as ImageMagick's signature of its pixels -- not as a written
# file, since a PNG carries a creation time and two encodings of one identical
# picture differ as bytes while being the same image.
sub render_frame
{
    my ( $effect, $frame, $frames, %params ) = @_;

    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new(
        image  => $img,
        source => $src,
        seed   => 11,
    );
    $ctx->frames( $frames );
    $ctx->frame( $frame );

    GlitchVape::Pipeline->new(
        effects => { $effect => { %{ $NUDGE{ $effect } || {} }, %params } } )
        ->run( $ctx );

    return $ctx->image->Get( 'signature' );
}

sub distinct_frames
{
    my ( $effect, %params ) = @_;

    my $frames = 5;

    my %seen;
    for my $n ( 0 .. $frames - 1 )
    {
        $seen{ render_frame( $effect, $n, $frames, %params ) } = 1;
    }

    return scalar keys %seen;
}

# ---------------------------------------------------------------------------
# Off holds the picture still

# The half that is new, and the half that is universally true: whatever the
# effect is and whatever else it has been set to, a loop with the randomness
# frozen is one picture repeated.
for my $effect ( @rerollers )
{
    is distinct_frames( $effect, reroll => 0 ), 1,
        "$effect with reroll off draws one picture for the whole loop";
}

# ---------------------------------------------------------------------------
# On does not

# Otherwise the switch would be pinned by a test that passes because the
# effect never varied in the first place.
for my $effect ( @rerollers )
{
    my $spec = $registry->get( $effect )->{ params }{ reroll };

    cmp_ok distinct_frames( $effect, reroll => 1 ), '>', 1,
        "$effect with reroll on draws a different picture on every frame";

    # Which way it comes is a fact about the effect rather than about the
    # switch: damage that boils is what a running tape does and arrives on,
    # while a dither that shimmered by default would change what every preset
    # using one already renders, so it arrives off.
    ok defined $spec->{ default }, "$effect declares which of the two it is";
}

# ---------------------------------------------------------------------------
# A still is untouched either way

# reroll is an animation parameter, so a preset carrying one has to render the
# same still it rendered before the parameter existed -- for both values, since
# with a single frame there is no second frame to differ from.
for my $effect ( @rerollers )
{
    my $on  = render_frame( $effect, 0, 1, reroll => 1 );
    my $off = render_frame( $effect, 0, 1, reroll => 0 );

    is $on, $off, "$effect renders one still, whatever reroll says";
}

# ---------------------------------------------------------------------------
# The bleed wanders only when it is asked to

# chroma_bleed says the same thing with a number rather than a switch, because
# what varies is a magnitude: the bandwidth a struggling tape gives to colour
# is not on or off, it is more or less.
{
    is distinct_frames( 'chroma_bleed' ), 1,
        'a bleed with no jitter is the same on every frame of a loop';

    cmp_ok distinct_frames( 'chroma_bleed', jitter => 0.5 ), '>', 1,
        'and wanders once there is jitter to wander by';

    my $still = render_frame( 'chroma_bleed', 0, 1 );

    is render_frame( 'chroma_bleed', 0, 1, jitter => 1 ), $still,
        'while a still is untouched however far the jitter goes';
}

done_testing;
