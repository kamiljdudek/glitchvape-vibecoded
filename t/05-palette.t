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

done_testing;
