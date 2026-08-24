#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use GlitchVape ();
use GlitchVape::Registry;

{
    my $spec = GlitchVape::Registry->get( 'scanlines' );
    ok $spec, 'a known effect resolves';
    is $spec->{ stage }, 'optics', 'scanlines is an optics-stage effect';
    ok length $spec->{ summary }, 'effects carry a summary';
    is $spec->{ title }, 'Scanlines', 'effects carry a presentable title';

    ok !GlitchVape::Registry->get( 'no_such_effect' ),
        'unknown effect returns undef';
}

# Every registered effect must be fully described, or --explain and the
# override parser have nothing to work from.
{
    my $all = GlitchVape::Registry->all;
    for my $name ( sort keys %$all )
    {
        my $spec = $all->{ $name };
        ok length $spec->{ summary }, "$name has a summary";
        ok length $spec->{ title },   "$name has a title";
        ok( GlitchVape::Registry->stage_info( $spec->{ stage } ),
            "$name sits in a declared stage" );

        for my $p ( sort keys %{ $spec->{ params } } )
        {
            my $d = $spec->{ params }{ $p };
            ok exists $d->{ default },      "$name.$p has a default";
            ok length( $d->{ doc } // '' ), "$name.$p is documented";

            if ( $d->{ type } eq 'enum' )
            {
                ok @{ $d->{ values } || [] }, "$name.$p lists its enum values";
                ok scalar( grep { $_ eq $d->{ default } } @{ $d->{ values } } ),
                    "$name.$p default is one of its own enum values";
            }

            if ( defined $d->{ min } && defined $d->{ max } )
            {
                cmp_ok $d->{ default }, '>=', $d->{ min },
                    "$name.$p default is not below its minimum";
                cmp_ok $d->{ default }, '<=', $d->{ max },
                    "$name.$p default is not above its maximum";
            }
        }
    }
}

{
    my $p = GlitchVape::Registry->resolve_params( 'scanlines', {} );
    is $p->{ spacing }, 3, 'defaults are filled in';

    $p = GlitchVape::Registry->resolve_params( 'scanlines', { spacing => 8 } );
    is $p->{ spacing }, 8,   'given values override defaults';
    is $p->{ opacity }, .35, 'unmentioned parameters keep their defaults';
}

# A typo in a preset must be loud. Silently ignoring it means the effect just
# does not happen, which is far harder to debug than an error.
{
    my $err = do
    {
        local $@;
        eval {
            GlitchVape::Registry->resolve_params( 'scanlines',
                { spacng => 3 } );
        };
        $@;
    };
    like $err, qr/no parameter 'spacng'/, 'unknown parameter is rejected';
    like $err, qr/Valid:/, 'the error lists the valid parameters';
}

{
    my $err = do
    {
        local $@;
        eval {
            GlitchVape::Registry->resolve_params( 'scanlines',
                { spacing => 'wide' } );
        };
        $@;
    };
    like $err, qr/expects a number/, 'non-numeric value is rejected';

    $err = do
    {
        local $@;
        eval {
            GlitchVape::Registry->resolve_params( 'scanlines',
                { opacity => 5 } );
        };
        $@;
    };
    like $err, qr/must be <= 1/, 'out-of-range value is rejected';

    $err = do
    {
        local $@;
        eval {
            GlitchVape::Registry->resolve_params( 'pixelsort',
                { direction => 'sideways' } );
        };
        $@;
    };
    like $err, qr/must be one of/, 'invalid enum value is rejected';
}

{
    my $p = GlitchVape::Registry->resolve_params( 'scanlines',
        { spacing => '4.6' } );
    is $p->{ spacing }, 5, 'int parameters round rather than truncate';

    $p =
        GlitchVape::Registry->resolve_params( 'quantize', { dither => 'off' } );
    is $p->{ dither }, 0, 'bool parameters accept off';

    $p =
        GlitchVape::Registry->resolve_params( 'quantize', { dither => 'yes' } );
    is $p->{ dither }, 1, 'bool parameters accept yes';
}

{
    my @names = GlitchVape::Registry->names;
    my $all   = GlitchVape::Registry->all;

    my @orders = map  { $all->{ $_ }{ order } } @names;
    my @sorted = sort { $a <=> $b } @orders;
    is_deeply \@orders, \@sorted, 'names() returns effects in pipeline order';
}

done_testing;
