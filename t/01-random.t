#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use GlitchVape::Random;

# Reproducibility is the whole point of the seed: if this ever fails, --seed
# stops being a promise and every rendered image becomes unrepeatable.
{
    my @a = map { GlitchVape::Random->new( seed => 42 )->rand } 1 .. 3;
    my @b = map { GlitchVape::Random->new( seed => 42 )->rand } 1 .. 3;
    is_deeply \@a, \@b, 'same seed gives the same sequence';

    my $x = GlitchVape::Random->new( seed => 42 );
    my $y = GlitchVape::Random->new( seed => 43 );
    isnt $x->rand, $y->rand, 'different seeds diverge';
}

{
    my $r = GlitchVape::Random->new( seed => 'mallsoft' );
    ok defined $r->rand, 'string seeds are accepted';

    my $s = GlitchVape::Random->new( seed => 'mallsoft' );
    is $r->seed, $s->seed, 'the same string hashes to the same seed';
}

# Derived streams let one effect be re-tuned without shifting every other
# effect's randomness.
{
    my $master = GlitchVape::Random->new( seed => 7 );
    my $a1     = $master->derive( 'grain' )->rand;
    my $a2     = $master->derive( 'grain' )->rand;
    is $a1, $a2, 'deriving the same label twice gives the same stream';

    isnt $master->derive( 'grain' )->rand, $master->derive( 'static' )->rand,
        'different labels give different streams';
}

{
    my $r = GlitchVape::Random->new( seed => 1 );

    my @v = map { $r->rand } 1 .. 500;
    ok !grep( { $_ < 0 || $_ >= 1 } @v ), 'rand stays in [0,1)';

    my @i = map { $r->int_between( 3, 7 ) } 1 .. 500;
    ok !grep( { $_ < 3 || $_ > 7 } @i ), 'int_between respects both bounds';

    my %seen;
    $seen{ $_ } = 1 for @i;
    is_deeply [ sort { $a <=> $b } keys %seen ], [ 3, 4, 5, 6, 7 ],
        'int_between reaches every value in range';

    is $r->int_between( 5, 5 ), 5, 'degenerate range returns the bound';
}

{
    my $r = GlitchVape::Random->new( seed => 9 );
    my @g = map { $r->gauss( 0, 1 ) } 1 .. 4000;

    my $mean = 0;
    $mean += $_ for @g;
    $mean /= @g;

    my $var = 0;
    $var += ( $_ - $mean )**2 for @g;
    $var /= @g;

    cmp_ok abs( $mean ),            '<', 0.1, 'gauss is centred on its mean';
    cmp_ok abs( sqrt( $var ) - 1 ), '<', 0.1, 'gauss has the requested spread';
}

{
    my $r    = GlitchVape::Random->new( seed => 5 );
    my @walk = $r->walk( 200, step => 0.1, min => -1, max => 1 );

    is scalar @walk, 200, 'walk returns the requested count';
    ok !grep( { $_ < -1 || $_ > 1 } @walk ), 'walk stays within bounds';
}

done_testing;
