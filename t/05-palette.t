#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use GlitchVape::Palette;

{
    my @names = GlitchVape::Palette::names();
    cmp_ok scalar @names, '>=', 8, 'palettes are registered';

    for my $n ( @names )
    {
        my $c = GlitchVape::Palette::colors( $n );
        cmp_ok scalar @$c, '>=', 2, "palette $n has at least two colours";
        ok !grep( { !/^#[0-9A-F]{6}$/ } @$c ),      "palette $n is all #RRGGBB";
        ok length GlitchVape::Palette::title( $n ), "palette $n has a title";
    }
}

{
    ok GlitchVape::Palette::known( 'vapor' ), 'known() finds a real palette';
    ok !GlitchVape::Palette::known( 'nope' ), 'known() rejects an unknown name';
}

{
    my $c = GlitchVape::Palette::colors( '#FF71CE,#01CDFE' );
    is_deeply $c, [ '#FF71CE', '#01CDFE' ], 'inline colour lists parse';

    $c = GlitchVape::Palette::colors( '#abc' );
    is_deeply $c, [ '#AABBCC' ], 'short hex expands';

    $c = GlitchVape::Palette::colors( 'FF71CE,01CDFE' );
    is_deeply $c, [ '#FF71CE', '#01CDFE' ], 'a missing # is tolerated';
}

{
    my $err = do
    {
        local $@;
        eval { GlitchVape::Palette::colors( 'not-a-palette' ) };
        $@;
    };
    like $err, qr/unknown palette/, 'unknown palette is reported';
    like $err, qr/Known:/,          'the error lists known palettes';

    $err = do
    {
        local $@;
        eval { GlitchVape::Palette::colors( '#GGGGGG' ) };
        $@;
    };
    like $err, qr/not a #RRGGBB colour/, 'invalid hex is reported';
}

{
    my $d = GlitchVape::Palette::duotone( 'pinkcyan' );
    is scalar @$d, 2, 'a duotone ramp has exactly two stops';

    # Falling back to a full palette's extremes is what lets any palette name
    # be used wherever a duotone is expected.
    $d = GlitchVape::Palette::duotone( 'vapor' );
    my $full = GlitchVape::Palette::colors( 'vapor' );
    is_deeply $d, [ $full->[ 0 ], $full->[ -1 ] ],
        'a palette used as a duotone takes its darkest and lightest';
}

{
    my $stops = GlitchVape::Palette::gradient_stops( 'vapor', 64 );
    is scalar @$stops, 64, 'gradient_stops returns the requested count';

    my $full = GlitchVape::Palette::colors( 'vapor' );
    is $stops->[ 0 ], $full->[ 0 ],
        'the ramp starts on the first palette colour';
    is $stops->[ -1 ], $full->[ -1 ],
        'the ramp ends on the last palette colour';

    ok !grep( { !/^#[0-9A-F]{6}$/ } @$stops ),
        'every interpolated stop is valid hex';
}

{
    # A single-colour palette must not divide by zero when interpolated.
    my $stops = GlitchVape::Palette::gradient_stops( [ '#FF0000' ], 8 );
    is scalar @$stops, 8, 'a one-colour ramp still fills the requested length';
    is $stops->[ 0 ],  $stops->[ -1 ], 'a one-colour ramp is constant';
}

{
    my $stops =
        GlitchVape::Palette::gradient_stops( [ '#000000', '#FFFFFF' ], 3 );
    is $stops->[ 0 ],  '#000000', 'two-stop ramp starts correctly';
    is $stops->[ -1 ], '#FFFFFF', 'two-stop ramp ends correctly';
    is $stops->[ 1 ],  '#808080', 'two-stop ramp interpolates the midpoint';
}

# ---------------------------------------------------------------------------
# Two colours trading places go round each other, not through

# Mixed channel by channel they would both arrive at the same colour half way,
# which makes a half-on swap the flattest thing on the slider and the middle
# of a control the worst place on it. Going opposite ways round the hue circle
# reaches the same swap having stayed two colours throughout.
{
    my $pair = [ '#FF71CE', '#01CDFE' ];

    is_deeply GlitchVape::Palette::swapped( $pair, 0 ), $pair,
        'nought hands back the ramp it was given';

    is_deeply GlitchVape::Palette::swapped( $pair, 1 ),
        [ '#01CDFE', '#FF71CE' ],
        'and a whole swap hands back exactly that ramp reversed';

    # The claim the hue path exists for, asked at every step rather than only
    # at the half way point, since a mix through the middle is equal there
    # and merely close either side of it.
    my @met;
    for my $step ( 1 .. 19 )
    {
        my $at = GlitchVape::Palette::swapped( $pair, $step / 20 );

        push @met, $step / 20 if uc $at->[ 0 ] eq uc $at->[ 1 ];
    }

    is_deeply \@met, [], 'and nowhere in between are the two ends one colour'
        or diag "flat at: @met";

    # Greys have no hue to go round, and asking one to travel would invent a
    # colour that neither end of the ramp had.
    my $grey = [ '#404040', '#404040' ];

    is_deeply GlitchVape::Palette::swapped( $grey, 0.5 ), $grey,
        'two greys have nowhere to go and stay where they are';

    is_deeply GlitchVape::Palette::swapped( undef, 1 ), undef,
        'and nothing at all is handed straight back';

    # More than two, which is what gradient_map maps through. The same
    # operation at any length: every stop is heading for the place its
    # opposite number started from.
    my $many = GlitchVape::Palette::colors( 'vapor' );

    is_deeply GlitchVape::Palette::swapped( $many, 1 ),
        [ reverse @$many ],
        'a five-stop palette swaps to exactly itself reversed';

    my $middle = GlitchVape::Palette::swapped( $many, 0.4 );

    is $middle->[ 2 ], $many->[ 2 ],
        'the odd one in the middle is its own opposite and does not move';

    isnt $middle->[ 0 ], $many->[ 0 ], 'while the pairs either side do';

    # No frame of it collapses, which is the property the hue path buys and
    # the one a longer palette gives more chances to break.
    my @flat;
    for my $step ( 1 .. 19 )
    {
        my $at  = GlitchVape::Palette::swapped( $many, $step / 20 );
        my %ink = map { uc $_ => 1 } @$at;

        push @flat, $step / 20 if keys %ink < @$many;
    }

    is_deeply \@flat, [], 'and nowhere along the way do two stops become one'
        or diag "collided at: @flat";
}

done_testing;
