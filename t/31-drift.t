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
use GlitchVape::Palette         ();
use GlitchVape::Effect::Overlay ();
use GlitchVape::Effect::Screen  ();
use GlitchVape::Effect::Texture ();
use GlitchVape::Random          ();
use GlitchVape::Pipeline        ();
use GlitchVape::Tools           ();

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

# ---------------------------------------------------------------------------
# The letterbox pattern breathes, and comes home

# Another moving parameter under another name, so outside the sweep above and
# owing the same two proofs. One cosine over the loop: out once, home once,
# and slowly -- a pattern that swapped every few frames would be a strobe.
{
    my $colours = sub {
        my ( $frame, $count, $swap ) = @_;

        my $ctx = GlitchVape::Context->new( seed => 1 );
        $ctx->frames( $count );
        $ctx->frame( $frame );

        ## no critic (Subroutines::ProtectPrivateSubs)
        return [
            GlitchVape::Effect::Overlay::_swapping(
                $ctx, { color => '#2A1B4E', ink => '#FF71CE', swap => $swap }
            )
        ];
        ## use critic
    };

    is_deeply $colours->( 12, 12, 1 ), $colours->( 0, 12, 1 ),
        'the pattern comes back to the colours it started the loop in';

    is_deeply $colours->( 0, 12, 1 ), [ '#2A1B4E', '#FF71CE' ],
        'which are the ones it was given';

    is_deeply $colours->( 6, 12, 1 ), [ '#FF71CE', '#2A1B4E' ],
        'and halfway round at a full swap they have changed places';

    is_deeply $colours->( 0, 1, 1 ), [ '#2A1B4E', '#FF71CE' ],
        'a still is drawn in the colours it was given, whatever the setting';

    # Below a full swap they lean towards each other without crossing, which
    # is the pattern breathing rather than inverting.
    my $part = $colours->( 6, 12, 0.4 );

    isnt $part->[ 0 ], '#FF71CE', 'at less than a full swap they do not cross';
    isnt $part->[ 0 ], '#2A1B4E', 'but they do move';
}

# ---------------------------------------------------------------------------
# A grade that wanders comes home

# One setting at a time, out and back on a cosine through excursion, so it
# closes at any amount and a still is graded exactly as it says.
{
    my $graded = sub {
        my ( $frame, $count, %how ) = @_;

        my $ctx = GlitchVape::Context->new( seed => 1 );
        $ctx->frames( $count );
        $ctx->frame( $frame );

        ## no critic (Subroutines::ProtectPrivateSubs)
        return GlitchVape::Effect::Color::_swayed(
            $ctx,
            {
                hue        => 100,
                saturation => 130,
                brightness => 100,
                contrast   => 0,
                sway_by    => 25,
                %how,
            }
        );
        ## use critic
    };

    is $graded->( 12, 12, sway => 'saturation' )->{ saturation },
        $graded->( 0, 12, sway => 'saturation' )->{ saturation },
        'the frame after the last one is graded like the first';

    isnt $graded->( 3, 12, sway => 'saturation' )->{ saturation },
        $graded->( 0, 12, sway => 'saturation' )->{ saturation },
        'having moved in between';

    is $graded->( 3, 1, sway => 'saturation' )->{ saturation }, 130,
        'and a still is graded at exactly what it was set to';

    # Only the one named. A grade is a decision about the whole picture, and
    # two of them moving at once is a colour wheel.
    my $moved = $graded->( 3, 12, sway => 'saturation' );

    is $moved->{ hue },        100, 'hue is left where it was';
    is $moved->{ brightness }, 100, 'and so is brightness';

    is $graded->( 3, 12, sway => 'none' )->{ saturation }, 130,
        'and with nothing swaying, nothing moves';

    # Clamped to the setting's own range rather than run off the end of it:
    # a saturation below nought is not a colour, and ImageMagick would take
    # the negative rather than complain about it.
    my $far = $graded->(
        9, 12,
        sway       => 'saturation',
        saturation => 10,
        sway_by    => 50
    );

    is $far->{ saturation }, 0,
        'a swing wider than the range stops at the end of it';
}

# ---------------------------------------------------------------------------
# The one-sided rock, for quantities that have no other direction

# Context::excursion spends half the loop negative, which is right for a band
# that sweeps one way and then the other and wrong for anything that is a
# fraction of something. Swell is the same rock folded onto one side, with the
# extreme in the middle of the loop rather than twice at the quarters.
{
    my $at = sub {
        my ( $frame, $count ) = @_;

        my $ctx = GlitchVape::Context->new( seed => 1 );
        $ctx->frames( $count );
        $ctx->frame( $frame );

        return $ctx->swell( 1 );
    };

    is $at->( 0,  12 ), 0,              'the loop opens at nought';
    is $at->( 12, 12 ), $at->( 0, 12 ), 'and the frame after the last one too';
    is $at->( 6,  12 ), 1,              'with the whole amount half way round';

    is sprintf( '%.6f', $at->( 3, 12 ) ), sprintf( '%.6f', $at->( 9, 12 ) ),
        'a quarter in and a quarter from the end are the same distance out';

    my @negative = grep { $at->( $_, 12 ) < 0 } 0 .. 11;

    is_deeply \@negative, [], 'and no frame of the loop is on the far side'
        or diag "negative at: @negative";

    is $at->( 3, 1 ), 0, 'a still has not gone anywhere';

    my $ctx = GlitchVape::Context->new( seed => 1 );
    $ctx->frames( 12 );
    $ctx->frame( 6 );

    is $ctx->swell( 0 ), 0, 'and nought amount goes nowhere either';
}

# ---------------------------------------------------------------------------
# A duotone that swaps comes back the ramp it started as

# The swap is one-sided -- a swap of minus a third is not a thing -- so it
# rides Context::swell rather than excursion, which puts the extreme in the
# middle of the loop and nought at both ends.
{
    my $stops = sub {
        my ( $frame, $count, $level ) = @_;

        my $ctx = GlitchVape::Context->new( seed => 1 );
        $ctx->frames( $count );
        $ctx->frame( $frame );

        ## no critic (Subroutines::ProtectPrivateSubs)
        return GlitchVape::Effect::Color::_duotone_stops( $ctx,
            { ramp => 'pinkcyan', swap => $level } );
        ## use critic
    };

    is_deeply $stops->( 12, 12, 1 ), $stops->( 0, 12, 1 ),
        'the frame after the last one maps through the ramp it opened with';

    is_deeply $stops->( 6, 12, 1 ), [ '#01CDFE', '#FF71CE' ],
        'and half way round the ramp is exactly that ramp reversed';

    is_deeply $stops->( 3, 12, 1 ), $stops->( 9, 12, 1 ),
        'a quarter in and a quarter from the end are the same place';

    isnt $stops->( 3, 12, 1 )->[ 0 ], $stops->( 0, 12, 1 )->[ 0 ],
        'which is not where it started';

    is_deeply $stops->( 6, 1, 1 ), [ '#FF71CE', '#01CDFE' ],
        'and a still is mapped through the ramp exactly as it is set';

    is_deeply $stops->( 6, 12, 0 ), [ '#FF71CE', '#01CDFE' ],
        'as is every frame of a loop with the swap off';

    # Below one it leans without arriving, which is what makes the setting a
    # level rather than a switch.
    my $half = $stops->( 6, 12, 0.5 );

    isnt $half->[ 0 ], '#FF71CE', 'half a swap has moved';
    isnt $half->[ 0 ], '#01CDFE', 'without getting there';
}

# ---------------------------------------------------------------------------
# The gradient map turns end for end and comes back

# The same setting as the duotone's, under the same name and doing the same
# thing to more colours -- which is the point of it being one function in
# Palette rather than two in the effects.
{
    my $ramp  = \&swapped_vapor;
    my $vapor = GlitchVape::Palette::colors( 'vapor' );

    is_deeply $ramp->( 0,  12, 1 ), $vapor, 'the loop opens on the palette';
    is_deeply $ramp->( 12, 12, 1 ), $vapor, 'and the frame after the last one';
    is_deeply $ramp->( 6,  12, 1 ), [ reverse @$vapor ],
        'with the palette exactly reversed half way round';

    is_deeply $ramp->( 6, 1, 1 ), $vapor,
        'and a still maps through the palette as it is written';

    is_deeply $ramp->( 6, 12, 0 ), $vapor,
        'as does every frame of a loop with the swap off';
}

# ---------------------------------------------------------------------------
# Snow that comes and goes, and specks that are not only two colours

# The specks themselves are redrawn every frame from the frame's own stream
# and are avowedly not periodic -- that is what snow is, and rng_for says so.
# What has to close is the *amount*: the loop opens and ends at the density
# it was set to, whatever it did in between.
{
    my $amount = \&snow_at;

    is $amount->( 0,  12 ), 0.04, 'the loop opens at the density it was set to';
    is $amount->( 12, 12 ), $amount->( 0, 12 ), 'and ends where it opened';
    is $amount->( 6,  12 ), 1,
        'with a whole surge losing the picture entirely half way round';

    cmp_ok $amount->( 3, 12 ), '>', 0.04, 'a quarter in there is more snow';
    cmp_ok $amount->( 3, 12 ), '<', 1,    'though not yet all of it';

    is $amount->( 6, 1 ), 0.04, 'and a still is snowed exactly as it says';

    is $amount->( 6, 12, surge => 0 ), 0.04,
        'as is every frame of a loop with the surge off';

    # Measured towards 1 rather than as a multiple, so no setting can ask for
    # a density there is no room for.
    is_deeply overfull_frames(), [],
        'and nothing anywhere asks for more than all of it';
}

# Snow is a level that varies, not two values. The old behaviour is spread 0
# and is still reachable, which is also what keeps it drawing the same stream
# it always drew.
{
    my $levels = \&speck_levels;

    is_deeply [ sort { $a <=> $b } keys %{ $levels->( 0 ) } ], [ 0, 255 ],
        'with no spread a speck is black or white and nothing else';

    my $some = $levels->( 0.35 );

    cmp_ok scalar keys %$some, '>', 2, 'given some, they take many levels';

    my @outside = strayed_from_a_pole( $some, 0.35 );

    is_deeply \@outside, [], 'none of them further from its pole than allowed'
        or diag "strayed: @outside";

    # Both ends fall back, not just one. A speck that is sometimes off-white
    # and always dead black is a different look and not the one asked for.
    my ( $light, $dark ) = levels_each_side( $some );

    cmp_ok $light, '>', 1, 'the light ones take several levels';
    cmp_ok $dark,  '>', 1, 'and so do the dark ones';

    # One draw at spread 0 and two above it, so an existing render moves only
    # because the default moved and not because the stream did.
    is two_valued_snow_draws(), one_coin_toss_each(),
        'and two-valued snow draws exactly the one number it always drew';
}

# The vapor palette part of the way through turning end for end.
sub swapped_vapor
{
    my ( $frame, $count, $level ) = @_;

    my $ctx = GlitchVape::Context->new( seed => 1 );
    $ctx->frames( $count );
    $ctx->frame( $frame );

    ## no critic (Subroutines::ProtectPrivateSubs)
    return GlitchVape::Effect::Color::_swap_at( $ctx,
        GlitchVape::Palette::colors( 'vapor' ), $level );
    ## use critic
}

# How much of the picture is snow on one frame of a loop.
sub snow_at
{
    my ( $frame, $count, %how ) = @_;

    my $ctx = GlitchVape::Context->new( seed => 1 );
    $ctx->frames( $count );
    $ctx->frame( $frame );

    ## no critic (Subroutines::ProtectPrivateSubs)
    return GlitchVape::Effect::Texture::_static_density( $ctx,
        { density => 0.04, surge => 1, %how } );
    ## use critic
}

# Any frame of a heavily snowed loop asking for more picture than there is.
sub overfull_frames
{
    return [ grep { snow_at( $_, 12, density => 0.9 ) > 1 } 0 .. 12 ];
}

# The distinct levels a few thousand specks land on at one spread.
sub speck_levels
{
    my ( $spread ) = @_;

    my $rng = GlitchVape::Random->new( seed => 'snow' );
    my %seen;

    ## no critic (Subroutines::ProtectPrivateSubs)
    $seen{ GlitchVape::Effect::Texture::_speck_level( $rng, $spread ) }++
        for 1 .. 4000;
    ## use critic

    return \%seen;
}

# Levels further from black or white than the spread allows.
sub strayed_from_a_pole
{
    my ( $seen, $spread ) = @_;

    my $reach = $spread * 127.5;

    return grep { $_ > $reach && $_ < 255 - $reach } keys %$seen;
}

# How many distinct levels each pole was approached through.
sub levels_each_side
{
    my ( $seen ) = @_;

    return (
        scalar( grep { $_ > 127.5 } keys %$seen ),
        scalar( grep { $_ <= 127.5 } keys %$seen )
    );
}

# The next number left in the stream after fifty two-valued specks...
sub two_valued_snow_draws
{
    my $rng = GlitchVape::Random->new( seed => 'snow' );

    ## no critic (Subroutines::ProtectPrivateSubs)
    GlitchVape::Effect::Texture::_speck_level( $rng, 0 ) for 1 .. 50;
    ## use critic

    return $rng->rand;
}

# ...and after fifty of the coin tosses the old code drew instead.
sub one_coin_toss_each
{
    my $rng = GlitchVape::Random->new( seed => 'snow' );

    $rng->chance( 0.5 ) for 1 .. 50;

    return $rng->rand;
}

done_testing;
