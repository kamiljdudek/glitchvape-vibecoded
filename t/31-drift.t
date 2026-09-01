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

# Every drift closes its loop.
#
# The property is that the frame after the last one is the first one again. A
# video plays a loop end to end and then starts it over, so a drift that does
# not come back to where it began puts a jolt in at that join -- once per
# repeat, for as long as the file plays. It is the one defect in an animation
# that gets worse the longer somebody watches, and it is invisible in any
# single frame, which is why nothing else in the suite would catch it.
#
# GlitchVape::Context::travel snaps a periodic pattern's distance to whole
# repeats and ::excursion rocks a one-off feature out and back, so both close
# by construction. This checks the construction actually holds, at values
# chosen to be awkward: primes, non-multiples of every plausible period, and
# fractions.
#
# Driven off the registry rather than a list, so an effect that grows a drift
# parameter is covered the day it is declared and not the day somebody
# remembers this file.

my $dir = File::Temp->newdir( 'gv_drift_XXXXXX', TMPDIR => 1 );

# Structure rather than a flat wash: several of these move edges around, and
# an edge is the only thing that shows it.
my $src = "$dir/src.png";
{
    my $img = Image::Magick->new( size => '240x180' );
    $img->Read( 'gradient:#101040-#FFE0A0' );
    $img->Draw(
        primitive => 'rectangle',
        points    => '45,38 165,120',
        fill      => '#FF2090',
    );
    my $err = $img->Write( $src );
    BAIL_OUT( "could not build the test source image: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;
}

my $registry = 'GlitchVape::Registry';

my @drifters =
    sort grep { $registry->get( $_ )->{ params }{ drift } } $registry->names;

ok scalar @drifters, 'some effects declare a drift' or BAIL_OUT( 'none found' );
diag "drift is declared by: @drifters";

# One frame of one effect, as ImageMagick's signature of its pixels.
#
# The signature and not the written file: a PNG carries a creation time, so two
# encodings of one identical picture differ as bytes while being the same
# image. Comparing files here reported a jolt in effects that did not have one.
sub render_frame
{
    my ( $effect, $drift, $frame, $frames ) = @_;

    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new(
        image  => $img,
        source => $src,
        seed   => 99,
    );
    $ctx->frames( $frames );
    $ctx->frame( $frame );

    GlitchVape::Pipeline->new( effects => { $effect => { drift => $drift } } )
        ->run( $ctx );

    return $ctx->image->Get( 'signature' );
}

my $frames = 12;

# Deliberately unhelpful: none of these is a whole number of any period the
# effects use, which is the case that used to jolt.
my @awkward = ( 1, 3, 7, 10, 0.5 );

for my $effect ( @drifters )
{
    my $spec = $registry->get( $effect )->{ params }{ drift };

    for my $drift ( @awkward )
    {
        next if defined $spec->{ max } && $drift > $spec->{ max };

        my $first = render_frame( $effect, $drift, 0,       $frames );
        my $wrap  = render_frame( $effect, $drift, $frames, $frames );

        ok $first eq $wrap,
            "$effect at drift $drift comes back to the first frame";
    }
}

# A drift is an animation parameter and must leave a still alone, whatever it
# is set to: presets carry it, and rendering one as a still should give the
# same picture it gave before the parameter existed.
for my $effect ( @drifters )
{
    my $spec = $registry->get( $effect )->{ params }{ drift };

    # The largest this effect will take, so the test is asking the parameter
    # for everything it has rather than for a number that happens to be small.
    my $most = $spec->{ max };
    $most = 10 if !defined $most || $most > 10;

    my $off = render_frame( $effect, 0,     0, 1 );
    my $on  = render_frame( $effect, $most, 0, 1 );

    ok $off eq $on, "$effect ignores drift when there is only one frame";
}

# ---------------------------------------------------------------------------
# The stream a drift can be random from and still close

# Every drift above closes by arithmetic: Context::travel snaps a distance to
# whole repeats. Not everything that moves can -- 'chicago' has a jitter,
# which picks a new place every frame and travels nowhere, so there is no
# period to snap. Context::rng_phase is what lets that close instead: it keys
# the roll on where the frame sits around the loop rather than on which frame
# it is. It is tested here because closing loops is what this file is about;
# the jitter itself is in t/40-chicago.t.
#
# The contract has two halves and both matter. Inside one pass it must be
# rng_for exactly, or a drift built on it would render differently for no
# reason anybody asked for; at the wrap it must not be, which is the whole
# point of having it.
{
    my $rolls = sub {
        my ( $method, $frame, $length ) = @_;

        my $ctx = GlitchVape::Context->new( seed => 41 );
        $ctx->frames( $length );
        $ctx->frame( $frame );

        return $ctx->$method( 'probe' )->rand;
    };

    for my $frame ( 0, 1, 5, 11 )
    {
        is $rolls->( 'rng_phase', $frame, 12 ),
            $rolls->( 'rng_for', $frame, 12 ),
            "on frame $frame of a loop rng_phase is rng_for";
    }

    is $rolls->( 'rng_phase', 12, 12 ), $rolls->( 'rng_phase', 0, 12 ),
        'and the frame after the last one is the first one again';

    isnt $rolls->( 'rng_for', 12, 12 ), $rolls->( 'rng_for', 0, 12 ),
        'which rng_for is not, and is not meant to be';

    # A still has no loop to come round, so there is nothing to distinguish.
    is $rolls->( 'rng_phase', 0, 1 ), $rolls->( 'rng_for', 0, 1 ),
        'on a still the two are the same stream';
}

# ---------------------------------------------------------------------------
# A wobble is a drift under another name, and closes like one

# 'cmyk' rocks its four screen angles over the loop rather than travelling
# them, so it is outside the sweep above -- which greps the registry for a
# parameter called 'drift'. It owes the same two proofs here.
#
# The angles are what is checked rather than the pixels: four screens a
# quarter of a degree apart make a picture that differs from its neighbour in
# ways no signature comparison would tell you anything useful about, and the
# angles are the thing the parameter actually moves.
{
    my $plates = {
        cyan    => 15,
        magenta => 75,
        yellow  => 0,
        black   => 45,
        wobble  => 1.5,
    };

    my $at = sub {
        my ( $frame, $count ) = @_;

        my $ctx = GlitchVape::Context->new( seed => 1 );
        $ctx->frames( $count );
        $ctx->frame( $frame );

        ## no critic (Subroutines::ProtectPrivateSubs)
        return [ GlitchVape::Effect::Screen::_angles( $ctx, $plates ) ];
        ## use critic
    };

    is_deeply $at->( 12, 12 ), $at->( 0, 12 ),
        'cmyk comes back to the angles it started the loop on';

    isnt join( q{}, @{ $at->( 3, 12 ) } ), join( q{}, @{ $at->( 0, 12 ) } ),
        'having moved them in between';

    is_deeply $at->( 0, 1 ), [ 15, 75, 0, 45 ],
        'and a still is set at exactly the angles it was given';

    # The plates move against one another rather than together, which is the
    # difference between a rosette breathing and the whole screen turning.
    my $moved = $at->( 3, 12 );
    my $from  = [ 15, 75, 0, 45 ];

    my @way = map { $moved->[ $_ ] <=> $from->[ $_ ] } 0 .. 3;

    ok(
        ( grep { $_ > 0 } @way ) && ( grep { $_ < 0 } @way ),
        'with some plates ahead of where they started and some behind'
    );

    # Quantised, so that a loop asks for a couple of dozen screens rather than
    # four per frame -- each of which is a rotation of a square twice the
    # picture's diagonal.
    my %angle;
    for my $frame ( 0 .. 23 )
    {
        $angle{ $_ }++ for @{ $at->( $frame, 24 ) };
    }

    cmp_ok scalar keys %angle, '<', 24 * 4 / 2,
        'and far fewer distinct screens than frames times plates';
}

done_testing;
