#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use GlitchVape ();
use GlitchVape::Registry;
use GlitchVape::Test  ();
use GlitchVape::Tools ();

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
# override parser have nothing to work from. The check itself is in
# GlitchVape::Test, where a plug-in's tests can make it too.
{
    GlitchVape::Test::declared_ok( $_ )
        for sort keys %{ GlitchVape::Registry->all };
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

# ---------------------------------------------------------------------------
# A need can name several values, meaning any one of them

# An enum whose off position is a word -- 'none' -- cannot be asked about as
# a truth, because a word is true. Naming the values that are not it says
# what is meant without inventing a grammar for negation.
{
    my $spec = { needs => { sway => [ qw(hue saturation) ] } };

    ok GlitchVape::Registry::needs_met( $spec, { sway => 'hue' } ),
        'the first of the listed values meets the need';
    ok GlitchVape::Registry::needs_met( $spec, { sway => 'saturation' } ),
        'and so does the second';
    ok !GlitchVape::Registry::needs_met( $spec, { sway => 'none' } ),
        'a value that is not on the list does not';
    ok !GlitchVape::Registry::needs_met( $spec, {} ),
        'and neither does no value at all';

    # The declaration this exists for, so the greying follows the effect
    # rather than a copy of its values here.
    my $by = GlitchVape::Registry->get( 'grade' )->{ params }{ sway_by };

    ok !GlitchVape::Registry::needs_met( $by, { sway => 'none' } ),
        'how far the grade sways means nothing while nothing sways';
    ok GlitchVape::Registry::needs_met( $by, { sway => 'contrast' } ),
        'and means something as soon as something does';
}

# ---------------------------------------------------------------------------
# An effect's values with the motion taken out of them

# What the camera on an effect's row does, expressed where the answer lives:
# which parameters only bite in a loop is a fact about the declaration.
{
    my $held = GlitchVape::Registry->without_animation( 'static',
        { density => 0.5, spread => 0.9, surge => 1 } );

    is $held->{ surge }, 0,
        'a loop-only setting comes back at what the effect declares';
    is $held->{ density }, 0.5, 'and everything else is left exactly as it was';
    is $held->{ spread },  0.9, 'including the settings next to it';

    # A copy, or switching the motion off for a preview would switch it off
    # for good.
    my $given = { surge => 1 };
    GlitchVape::Registry->without_animation( 'static', $given );

    is $given->{ surge }, 1, 'and the values it was given are not touched';

    # Nothing to take out of an effect that declares no motion, which is also
    # how the interface knows not to draw a camera on its row.
    ok( GlitchVape::Registry->animated( 'static' ),
        'static says it has something that only happens in a loop' );
    ok( !GlitchVape::Registry->animated( 'vignette' ),
        'and a vignette says it has not' );

    my $flat = { size => 1.8 };

    is_deeply( GlitchVape::Registry->without_animation( 'vignette', $flat ),
        $flat, 'so its values come back untouched' );
}

# ---------------------------------------------------------------------------
# A declaration is checked when it is made

# Everything that reads a declaration trusts it, and each of these used to be
# accepted and then fail somewhere else, later, in its own way: an enum with no
# values made --explain die, a stage left out quietly became optics, a name
# with a dot in it could never be reached by --set. Every effect that ships
# passes all of it, which loading them at the top of this file shows; what is
# pinned here is that each is refused, with a sentence saying which rule, and
# that a refused declaration leaves nothing registered.
{
    my $n = 0;

    my $refusal = sub {
        my ( %spec ) = @_;

        my %declared = (
            name    => 'test_refused_' . $n++,
            stage   => 'colour',
            summary => 'A declaration with something wrong with it',
            apply   => sub { return },
            %spec,
        );

        my $ok = eval { GlitchVape::Registry->register( %declared ); 1 };
        return 'accepted' if $ok;

        my $why = $@;
        return "registered anyway: $why"
            if $declared{ name } ne 'grain'
            && GlitchVape::Registry->get( $declared{ name } // q{} );

        return $why;
    };

    my $param = sub {
        my ( %d ) = @_;
        return ( params => { p => { doc => 'one parameter', %d } } );
    };

    like $refusal->( name => 'with.dot' ), qr/must be lower case letters/,
        'a name with a dot in it, which --set could never reach';
    like $refusal->( name => 'Upper' ), qr/must be lower case letters/,
        'and one in capitals, which a preset key would not match';
    like $refusal->( stage => undef ), qr/does not say which stage it runs at/,
        'a declaration that does not say where it runs';
    like $refusal->( stage => 'lens' ), qr/unknown stage 'lens'/,
        'or says somewhere that does not exist';
    like $refusal->( sumary => 'typo' ), qr/'sumary', which means nothing here/,
        'a key the declaration does not have, which would be ignored in silence';
    like $refusal->( $param->( default => 1, mn => 0 ) ),
        qr/'mn', which means nothing here/,
        'and the same inside a parameter';
    like $refusal->( params => { 'with.dot' => { default => 1 } } ),
        qr/parameter name '\S+[.]with[.]dot' must be lower/,
        'a parameter name with a dot in it';
    like $refusal->( $param->( default => 'a', type => 'enum' ) ),
        qr/is an enum and lists no values/,
        'an enum with no values, which made --explain die';
    like $refusal->( $param->( default => '#fff', type => 'colour' ) ),
        qr/unknown type 'colour'/,
        'a type nothing knows, which was passed through as a string';
    like $refusal->( $param->( default => 1, min => 2, max => 0 ) ),
        qr/runs from 2 to 0, which is backwards/,
        'a range that runs backwards';
    like $refusal->(
        $param->( default => 5, type => 'num', min => 0, max => 1 ) ),
        qr/refuses its own default/,
        'a default outside its own range, which nobody could use unchanged';
    like $refusal->(
        $param->( default => 'c', type => 'enum', values => [ qw(a b) ] ) ),
        qr/refuses its own default/,
        'an enum default that is not one of its values';
    like $refusal->( $param->( default => 'x', suggest => 'palettes' ) ),
        qr/names 'palettes', which is not a list the program knows/,
        'a suggestion list nobody has, which used to be a combo offering nothing';
    like $refusal->(
        $param->( default => 'x', suggest => [ 'x' ], choose => [ 'x' ] ) ),
        qr/says both suggest and choose/,
        'suggest and choose at once, which are two answers to one question';
    like $refusal->( $param->( default => '#000,#fff', stops => [ 3, 2 ] ) ),
        qr/stops must be a count, or a \[least, most\] pair/,
        'a colour count that runs backwards';
    like $refusal->( requires => [ 'no_such_tool' ] ),
        qr/'no_such_tool', which GlitchVape::Tools has never/,
        'a requirement on a tool that could only ever be reported missing';
    like $refusal->( name => 'grain' ),
        qr/'grain' registered twice -- the program itself/,
        'and a name that is taken, saying whose it is';

    # A tool registered first is one requires may name.
    GlitchVape::Tools->register( name => 'test_tool', bins => [ 'perl' ] );
    is $refusal->( requires => [ 'test_tool' ] ), 'accepted',
        'a tool GlitchVape::Tools has been told about can be required';
}

# ---------------------------------------------------------------------------
# What a parameter offers

# Inline, or a named list -- which is the registry's to keep now, and the
# window only asks it.
{
    is_deeply GlitchVape::Registry::offered( { suggest => [ qw(a b) ] },
        'suggest' ), [ qw(a b) ], 'an inline list is offered as it stands';

    my $ratios =
        GlitchVape::Registry::offered( { choose => 'ratio' }, 'choose' );
    is $ratios->[ 0 ], 'native', 'a named list is offered from its source';

    is GlitchVape::Registry::offered( { choose => 'ratio' }, 'suggest' ), undef,
        'and nothing is offered under the key a parameter does not use';

    GlitchVape::Registry->register_source(
        name   => 'test_list',
        values => [ qw(one two) ]
    );
    is_deeply GlitchVape::Registry::offered( { suggest => 'test_list' },
        'suggest' ), [ qw(one two) ], 'a registered list is a named list';

    ok !eval {
        GlitchVape::Registry->register_source(
            name   => 'palette',
            values => [ 'x' ]
        );
        1;
    }, 'and a name that is taken is refused';
}

done_testing;
