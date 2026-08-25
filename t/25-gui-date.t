#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;

# Gtk, so this needs a display.
BEGIN
{
    eval { require Gtk3; Gtk3->import; 1 }
        or plan skip_all => 'Gtk3 is not available';
    Gtk3::init_check()
        or plan skip_all => 'no display';
}

use GlitchVape              ();
use GlitchVape::Registry    ();
use GlitchVape::GUI::Params ();

# osd.date is a date, which is a thing people pick rather than spell -- but it
# is still a string parameter that accepts anything, and the two facts have to
# stay true at the same time.

my $SPEC = GlitchVape::Registry->get( 'osd' );

# Popovers are not in the container tree, so they are recorded as they are
# built. A test-only hook: nothing in the module knows about it.
our @POPOVERS;
{
    # Redefining a constructor is the point, so the warning about doing it is
    # noise. Scoped to this block and to the test file: nothing in the module
    # knows this hook exists.
    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    ## use critic
    my $original = \&Gtk3::Popover::new;
    *Gtk3::Popover::new = sub {
        my $popover = $original->( @_ );
        push @POPOVERS, $popover;
        return $popover;
    };
}

sub date_control
{
    my ( $value, $seen ) = @_;

    @POPOVERS = ();

    my $built = GlitchVape::GUI::Params->build(
        effect    => 'osd',
        name      => 'date',
        spec      => $SPEC->{ params }{ date },
        value     => $value,
        on_change => sub { push @$seen, $_[ 0 ] if $seen; return },
    );

    my ( $entry ) =
        grep { $_->isa( 'Gtk3::Entry' ) } $built->{ control }->get_children;
    my ( $button ) =
        grep { $_->isa( 'Gtk3::Button' ) } $built->{ control }->get_children;

    return {
        built  => $built,
        entry  => $entry,
        button => $button,
        open   => sub {
            $button->clicked;

            my $inner = $POPOVERS[ 0 ]->get_child;

            my ( $calendar ) =
                grep { $_->isa( 'Gtk3::Calendar' ) } $inner->get_children;
            my ( $any ) =
                grep { $_->isa( 'Gtk3::Button' ) } $inner->get_children;

            return ( $calendar, $any );
        },
    };
}

sub shown_as
{
    my ( $calendar ) = @_;

    my ( $year, $month, $day ) = $calendar->get_date;

    return sprintf '%d-%02d-%02d', $year, $month + 1, $day;
}

# ---------------------------------------------------------------------------
# The shape of the control

{
    my $c = date_control( 'JAN 05 1995' );

    isa_ok $c->{ built }{ control }, 'Gtk3::Box', 'the date control';
    ok $c->{ entry },  'has an entry';
    ok $c->{ button }, 'and a button to open a calendar with';

    is $c->{ built }{ get }->(), 'JAN 05 1995',
        'and reads its value from the entry';

    # The neighbouring parameter is deliberately untouched: only a parameter
    # actually called 'date' gets a calendar.
    my $time = GlitchVape::GUI::Params->build(
        effect => 'osd',
        name   => 'time',
        spec   => $SPEC->{ params }{ time },
        value  => q{},
    );

    isa_ok $time->{ control }, 'Gtk3::Entry', 'osd.time';
}

# ---------------------------------------------------------------------------
# The calendar opens on the value, not on today

{
    my $c = date_control( 'JAN 05 1995' );
    my ( $calendar ) = $c->{ open }->();

    is shown_as( $calendar ), '1995-01-05',
        'the calendar opens on the date in the entry';
}

# An empty entry means "invent one per seed", which no calendar can show, so
# it opens on a 1990s day rather than on today -- a present-day timestamp is
# the anachronism this effect exists to avoid.
{
    my $c = date_control( q{} );
    my ( $calendar ) = $c->{ open }->();

    my ( $year ) = $calendar->get_date;

    cmp_ok $year, '>=', 1990, 'an empty date opens in the nineties';
    cmp_ok $year, '<=', 1999, 'and not later';
}

# ---------------------------------------------------------------------------
# Picking a day writes the camcorder format

{
    my @seen;
    my $c = date_control( q{}, \@seen );
    my ( $calendar ) = $c->{ open }->();

    @seen = ();

    $calendar->select_month( 11, 1999 );
    $calendar->select_day( 31 );

    is $c->{ entry }->get_text, 'DEC 31 1999',
        'picking a day writes the three-letter month form the OSD draws';
    is $c->{ built }{ get }->(), 'DEC 31 1999', 'which is what get() returns';
    is $seen[ -1 ],              'DEC 31 1999', 'and what the caller is told';

    # Zero-padded, because the overlay is monospaced and a one-character day
    # would shift everything beside it.
    $calendar->select_month( 0, 1995 );
    $calendar->select_day( 5 );

    is $c->{ entry }->get_text, 'JAN 05 1995', 'the day is zero-padded';
}

# ---------------------------------------------------------------------------
# Opening the picker changes nothing

# Seeking the calendar emits day-selected -- twice, since select_month and
# select_day each do. Without a guard, opening the picker would write the date
# back over what was typed and cost a render nobody asked for.

{
    my @seen;
    my $c = date_control( 'TUESDAY', \@seen );

    @seen = ();
    my ( $calendar ) = $c->{ open }->();

    is $c->{ entry }->get_text, 'TUESDAY',
        'a string the calendar cannot read survives the picker being opened';
    is scalar @seen, 0, 'and opening it reports no change';

    cmp_ok +( $calendar->get_date )[ 0 ], '>=', 1990,
        'while the calendar still lands somewhere sensible';
}

# The same for a date it *can* read but would spell differently: opening the
# picker must not quietly reformat what somebody typed.
{
    my @seen;
    my $c = date_control( 'jan 5 1995', \@seen );

    @seen = ();
    my ( $calendar ) = $c->{ open }->();

    is $c->{ entry }->get_text, 'jan 5 1995',
        'a differently-spelled date is not rewritten by opening the picker';
    is scalar @seen,          0,            'and still reports no change';
    is shown_as( $calendar ), '1995-01-05', 'though the calendar found it';
}

# ---------------------------------------------------------------------------
# Getting back to "any 1990s date"

# The empty state is the effect's default and the one most renders want, so it
# has to be reachable from the picker rather than only by clearing the field
# by hand -- which nobody would guess means "generate one".
{
    my @seen;
    my $c = date_control( 'JAN 05 1995', \@seen );
    my ( undef, $any ) = $c->{ open }->();

    ok $any, 'the picker offers a way back to a generated date';

    @seen = ();
    $any->clicked;

    is $c->{ entry }->get_text, q{}, 'which empties the field';
    is $seen[ -1 ],             q{}, 'and reports the empty value';
}

# ---------------------------------------------------------------------------
# Reading a date out of the entry

{
    # Reached by name because it is genuinely private -- nothing outside the
    # date control has any business parsing an osd.date -- but where a
    # calendar lands for a given string is exactly the behaviour worth
    # pinning, and driving it through the widget would test Gtk rather than
    # this.
    ## no critic (Variables::ProtectPrivateVars)
    my $parse = \&GlitchVape::GUI::Params::_parse_date;

    is_deeply [ $parse->( 'JAN 05 1995' ) ], [ 1995, 0, 5 ],
        'the format the effect writes is read back';
    is_deeply [ $parse->( 'jan 5 1995' ) ], [ 1995, 0, 5 ],
        'case and padding are not required';
    is_deeply [ $parse->( 'DEC 31 1999' ) ], [ 1999, 11, 31 ],
        'December is month eleven, zero-based as Gtk wants it';
    is_deeply [ $parse->( 'FEB 29 1996' ) ], [ 1996, 1, 29 ],
        'a leap day in a leap year is a date';

    # Anything unreadable falls back rather than failing: osd.date takes any
    # literal string, so this is a question about where to point a calendar,
    # not about whether the value is valid.
    my @fallback = $parse->( undef );

    cmp_ok $fallback[ 0 ], '>=', 1990, 'the fallback is in the nineties';

    for my $bad ( q{}, 'TUESDAY', '13 JAN 1995', 'FEB 30 1996', 'FEB 29 1997' )
    {
        is_deeply [ $parse->( $bad ) ], \@fallback,
            "'$bad' falls back rather than being read as a date";
    }
}

done_testing;
