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

# gauss_list writes the generator and the polar method out again, for grain's
# sake, so it is only correct for as long as it agrees with gauss number for
# number. Every way the two could drift apart is here: an odd count, which
# leaves the second of a pair spare; a gauss after that, which has to spend
# it; a mean and a spread applied to both halves of a pair; and a count of
# none, which must leave the generator where it was.
{
    my @asked = ( 1, 2, 3, 7, 0, 1, 1000, 4, 0, 5 );

    my $one  = GlitchVape::Random->new( seed => 'grain#3' );
    my $bulk = GlitchVape::Random->new( seed => 'grain#3' );

    my ( @by_one, @by_list );
    for my $n ( @asked )
    {
        push @by_one,  map { $one->gauss( 0, 22.95 ) } 1 .. $n;
        push @by_list, $bulk->gauss_list( $n, 0, 22.95 );

        # And a single draw between each, the way two effects sharing a
        # stream would interleave them.
        push @by_one,  $one->gauss( 3, 2 );
        push @by_list, $bulk->gauss( 3, 2 );
    }

    is scalar @by_list, scalar @by_one, 'gauss_list draws as many as asked';
    is_deeply \@by_list, \@by_one,
        'and exactly the numbers the same number of gauss calls would';
    is $bulk->rand, $one->rand, 'leaving the generator where they would';
}

{
    my $r    = GlitchVape::Random->new( seed => 5 );
    my @walk = $r->walk( 200, step => 0.1, min => -1, max => 1 );

    is scalar @walk, 200, 'walk returns the requested count';
    ok !grep( { $_ < -1 || $_ > 1 } @walk ), 'walk stays within bounds';
}

done_testing;
