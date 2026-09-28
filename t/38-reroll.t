#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;

use GlitchVape           ();
use GlitchVape::Context  ();
use GlitchVape::Pipeline ();
use GlitchVape::Registry ();
use GlitchVape::Test     ();
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

# All three halves -- off holds the picture still, on does not, and a still is
# the same either way, since reroll is an animation parameter and a preset
# carrying one must render the still it rendered before the parameter existed
# -- are asked by GlitchVape::Test, where a plug-in's own tests can ask them.
# The picture has structure in both axes and is deliberately not a smooth
# ramp: several of these effects move pixels along a row, and a row of a
# vertical gradient is a row of identical pixels, so a flat wash would report
# "held still" for an effect that was boiling merrily.
GlitchVape::Test::reroll_ok( $_, %{ $NUDGE{ $_ } || {} } ) for @rerollers;

# ---------------------------------------------------------------------------
# The bleed wanders only when it is asked to

# chroma_bleed says the same thing with a number rather than a switch, because
# what varies is a magnitude: the bandwidth a struggling tape gives to colour
# is not on or off, it is more or less.
{
    is GlitchVape::Test::distinct( 'reroll', 'chroma_bleed' ), 1,
        'a bleed with no jitter is the same on every frame of a loop';

    cmp_ok GlitchVape::Test::distinct(
        'reroll', 'chroma_bleed', { jitter => 0.5 }
        ),
        '>', 1,
        'and wanders once there is jitter to wander by';

    my $still = GlitchVape::Test::frame( 'reroll', 'chroma_bleed', {}, 0, 1 );

    is GlitchVape::Test::frame( 'reroll', 'chroma_bleed', { jitter => 1 },
        0, 1 ),
        $still,
        'while a still is untouched however far the jitter goes';
}

done_testing;
