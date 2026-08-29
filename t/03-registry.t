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

# ---------------------------------------------------------------------------
# A parameter may say where it sits, and everything that lists them agrees

# Alphabetical is the right default and stays the default: it is stable and it
# needs no decision from an effect that has none to make. What it cannot do is
# group, and osd is the effect that proves it -- a timestamp switch has to sit
# above the four settings that only mean anything once it is on, and no
# spelling of their names puts them there.
{
    my $params = GlitchVape::Registry->get( 'osd' )->{ params };

    my @order = GlitchVape::Registry::sorted_params( $params );

    is_deeply \@order, [
        qw(color font size margin timestamp invent date time camera rec_mode
            reroll blink)
        ],
        'osd is presented in the order it declared, not alphabetically';

    # An effect that declares nothing is sorted as it always was, so the
    # feature costs the other forty effects nothing.
    my $grade = GlitchVape::Registry->get( 'grade' )->{ params };
    is_deeply [ GlitchVape::Registry::sorted_params( $grade ) ],
        [ sort keys %$grade ],
        'an effect with no declared order is still alphabetical';

    # Mixed: the numbered ones first, in their numbers, then the rest.
    my %mixed = (
        zebra => { default => 1, order => 10 },
        alpha => { default => 1 },
        yak   => { default => 1, order => 20 },
        beta  => { default => 1 },
    );
    is_deeply [ GlitchVape::Registry::sorted_params( \%mixed ) ],
        [ qw(zebra yak alpha beta) ],
        'numbered parameters lead, and the unnumbered follow alphabetically';
}

# ---------------------------------------------------------------------------
# A parameter can say what has to hold before it means anything

# The interface greys a control whose needs are not met, but the question is a
# fact about the declaration rather than about Gtk, so the answer lives here
# and this test runs without a display.
{
    my $params = GlitchVape::Registry->get( 'osd' )->{ params };

    my $met = sub {
        my ( $key, %values ) = @_;
        return GlitchVape::Registry::needs_met( $params->{ $key }, \%values );
    };

    ok $met->( 'color', timestamp => 0 ),
        'a parameter declaring no needs always means something';

    ok $met->( 'date', timestamp => 1, invent => 0 ),
        'the date matters with a timestamp that is not invented';
    ok !$met->( 'date', timestamp => 1, invent => 1 ),
        'and not when the timestamp is being invented';
    ok !$met->( 'date', timestamp => 0, invent => 0 ),
        'and not when there is no timestamp at all';

    # Every clause has to hold, which is what makes reroll -- wanted on only
    # when there is an invented timestamp to reroll -- expressible at all.
    ok $met->( 'reroll', timestamp => 1, invent => 1 ),
        'reroll needs both of the switches above it';
    ok !$met->( 'reroll', timestamp => 1, invent => 0 ), 'and says so';

    # A wanted 1 asks about truth, so one spelling serves a switch that is on
    # and a string that is not empty.
    ok $met->( 'blink', camera => 'REC' ),
        'a blink matters while there is an indicator to flash';
    ok !$met->( 'blink', camera => q{} ),
        'and not when the camera mode is empty';

    # A wanted string is compared as one, so a future needs => { mode => 'x' }
    # reads as it looks rather than asking about truth.
    my $spec = { needs => { mode => 'frame' } };
    ok GlitchVape::Registry::needs_met( $spec, { mode => 'frame' } ),
        'a wanted value other than 0 or 1 is an equality test';
    ok !GlitchVape::Registry::needs_met( $spec, { mode => 'once' } ),
        'which a different value fails';
}

# ---------------------------------------------------------------------------
# A need on a parameter that does not exist is caught at load time

# Left unchecked it produces a control greyed out for ever, which looks like a
# bug in the widget rather than a typo in the declaration.
{
    my $ok = eval {
        GlitchVape::Registry->register(
            name   => 'test_bad_needs',
            stage  => 'overlay',
            params => {
                one => { default => 1, type  => 'bool' },
                two => { default => 1, needs => { none => 1 } },
            },
            apply => sub { return },
        );
        1;
    };

    ok !$ok, 'a needs naming a parameter the effect lacks is fatal';
    like $@, qr/needs 'none'/, 'and says which one it could not find';
}

done_testing;
