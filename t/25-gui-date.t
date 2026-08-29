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

# osd.date and osd.time are a date and a time, which are things people pick
# rather than spell -- but they are still string parameters that accept
# anything, and the two facts have to stay true at the same time.
#
# Gtk3 has a calendar and nothing for a time of day, so the clock is built out
# of spin buttons here. It is deliberately the same shape as the calendar: the
# entry holds the value either way.

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

# Both pickers are the same arrangement -- an entry that holds the value and a
# button that opens a popover -- so one helper drives either of them, which is
# itself the property being pinned.
sub picker_control
{
    my ( $name, $value, $seen ) = @_;

    @POPOVERS = ();

    my $built = GlitchVape::GUI::Params->build(
        effect    => 'osd',
        name      => $name,
        spec      => $SPEC->{ params }{ $name },
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
        inner  => sub {
            $button->clicked;
            return $POPOVERS[ 0 ]->get_child;
        },
    };
}

sub date_control
{
    my ( $value, $seen ) = @_;

    my $c = picker_control( 'date', $value, $seen );

    $c->{ open } = sub {
        my $inner = $c->{ inner }->();

        my ( $calendar ) =
            grep { $_->isa( 'Gtk3::Calendar' ) } $inner->get_children;

        return ( $calendar, $inner );
    };

    return $c;
}

sub time_control
{
    my ( $value, $seen ) = @_;

    my $c = picker_control( 'time', $value, $seen );

    $c->{ open } = sub {
        my $inner = $c->{ inner }->();

        my ( $meridiem ) =
            grep { $_->isa( 'Gtk3::ComboBoxText' ) } $inner->get_children;
        my ( $hour, $minute ) =
            grep { $_->isa( 'Gtk3::SpinButton' ) } $inner->get_children;

        return ( $meridiem, $hour, $minute );
    };

    return $c;
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

    # The neighbouring parameter gets the same arrangement and a different
    # picker: two spin buttons and a meridiem, because Gtk3 has no clock.
    my $t = time_control( 'PM  3:47' );

    isa_ok $t->{ built }{ control }, 'Gtk3::Box', 'the time control';
    ok $t->{ entry },  'has an entry';
    ok $t->{ button }, 'and a button to open a clock with';

    is $t->{ built }{ get }->(), 'PM  3:47',
        'and reads its value from the entry too';

    # Everything else is still a plain entry: only the two parameters that
    # name a moment get a picker.
    my $mode = GlitchVape::GUI::Params->build(
        effect => 'osd',
        name   => 'camera',
        spec   => $SPEC->{ params }{ camera },
        value  => 'REC',
    );

    isa_ok $mode->{ control }, 'Gtk3::ComboBoxText', 'osd.camera';
}

# ---------------------------------------------------------------------------
# The clock opens on the value and writes the format the overlay draws

{
    my @seen;
    my $c = time_control( 'AM 11:05', \@seen );

    my ( $meridiem, $hour, $minute ) = $c->{ open }->();

    is $meridiem->get_active_text, 'AM', 'the clock opens on the meridiem';
    is $hour->get_value,           11,   'the hour';
    is $minute->get_value,         5,    'and the minute in the entry';

    @seen = ();
    $hour->set_value( 3 );

    # Two spaces before a single-digit hour, because the overlay is monospaced
    # and the effect's own invented times are padded the same way -- switching
    # between an invented time and a picked one must not change the width of
    # the display.
    is $c->{ entry }->get_text, 'AM  3:05',
        'moving the hour writes the padded form the OSD draws';
    is $seen[ -1 ], 'AM  3:05', 'and the caller is told';

    $meridiem->set_active( 1 );
    is $c->{ entry }->get_text, 'PM  3:05', 'and the meridiem is part of it';

    $minute->set_value( 30 );
    is $c->{ entry }->get_text, 'PM  3:30', 'as is the minute, zero-padded';
}

# ---------------------------------------------------------------------------
# Opening the clock changes nothing either

# The same guard as the calendar, and for the same reason: seeking the spin
# buttons emits value-changed, so without it opening the picker would write a
# time back over a literal somebody typed.
{
    my @seen;
    my $c = time_control( 'TEATIME', \@seen );

    @seen = ();
    my ( undef, $hour ) = $c->{ open }->();

    is $c->{ entry }->get_text, 'TEATIME',
        'a string the clock cannot read survives the picker being opened';
    is scalar @seen, 0, 'and opening it reports no change';

    cmp_ok $hour->get_value, '>=', 1, 'while the clock still lands somewhere';
}

# ---------------------------------------------------------------------------
# Reading a time out of the entry

{
    ## no critic (Variables::ProtectPrivateVars)
    my $parse = \&GlitchVape::GUI::Params::_parse_time;

    is_deeply [ $parse->( 'PM  3:47' ) ], [ 'PM', 3, 47 ],
        'the format the effect writes is read back';
    is_deeply [ $parse->( 'am 11:05' ) ], [ 'AM', 11, 5 ],
        'case and padding are not required';

    my @fallback = $parse->( undef );

    for my $bad ( q{}, 'TEATIME', '25:00', 'PM 13:00', 'PM 3:60', '3:47' )
    {
        is_deeply [ $parse->( $bad ) ], \@fallback,
            "'$bad' falls back rather than being read as a time";
    }
}

# ---------------------------------------------------------------------------
# The calendar opens on the value, not on today

{
    my $c = date_control( 'JAN 05 1995' );
    my ( $calendar ) = $c->{ open }->();

    is shown_as( $calendar ), '1995-01-05',
        'the calendar opens on the date in the entry';
}

# An empty entry means "draw no date", which no calendar can show, so it opens
# on a 1990s day rather than on today -- a present-day timestamp is the
# anachronism this effect exists to avoid.
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
# The picker no longer has to explain the empty field

# It used to carry an "Any 1990s date" button, because an empty field was how
# the effect was told to invent a timestamp -- a meaning nothing on screen
# said, so the picker had to say it. osd.invent says it now, in a switch two
# rows above, and an empty field means the plain thing it looks like. A button
# still offering to empty the field would be a second, quieter way to spell a
# setting that is already visible.
{
    my $c = date_control( 'JAN 05 1995' );
    my ( undef, $inner ) = $c->{ open }->();

    my @buttons = grep { $_->isa( 'Gtk3::Button' ) } $inner->get_children;

    is_deeply \@buttons, [],
        'the calendar popover is a calendar and nothing else';
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
