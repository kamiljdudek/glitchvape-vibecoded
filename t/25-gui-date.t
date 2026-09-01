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
use GlitchVape::Generator   ();
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

# ---------------------------------------------------------------------------
# A seed is a number nobody wants to choose

# The same argument as the calendar's, from the other direction. A seed is
# there so a render can be repeated -- type the number back in and the same
# clicks come out -- so it has to stay a number you can read and type. But
# almost every time anybody touches one, what they want is not a particular
# number, it is a different one, and a spin button offers 1, 2, 3 as though
# the numbers near each other were near each other.
#
# So both: the box for the rare case and a button for the common one.
{
    my @with_seed =
        grep { GlitchVape::Generator::get( $_ )->{ params }{ seed } }
        GlitchVape::Generator::kinds();

    ok scalar @with_seed, 'some generated tracks have a seed';

    for my $kind ( @with_seed )
    {
        my $spec = GlitchVape::Generator::get( $kind )->{ params }{ seed };

        my $built = GlitchVape::GUI::Params->build(
            effect    => $kind,
            name      => 'seed',
            spec      => $spec,
            value     => 1,
            on_change => sub { },
        );

        my @kids =
              $built->{ control }->can( 'get_children' )
            ? $built->{ control }->get_children
            : ();

        my ( $shown ) = grep { $_->isa( 'Gtk3::Label' ) } @kids;
        my ( $roll )  = grep { $_->isa( 'Gtk3::Button' ) } @kids;

        ok $shown, "$kind shows the seed it is using";
        ok $roll,  'and a button is the only way to change it';

        ok !( grep { $_->isa( 'Gtk3::Entry' ) } @kids ),
            'with nothing to type an exact one into';
    }
}

# ---------------------------------------------------------------------------
# The button picks a different one, and says so

{
    my $spec = GlitchVape::Generator::get( 'drive' )->{ params }{ seed };

    my @told;
    my $built = GlitchVape::GUI::Params->build(
        effect    => 'drive',
        name      => 'seed',
        spec      => $spec,
        value     => 1,
        on_change => sub { push @told, $_[ 0 ] },
    );

    my @kids      = $built->{ control }->get_children;
    my ( $shown ) = grep { $_->isa( 'Gtk3::Label' ) } @kids;
    my ( $roll )  = grep { $_->isa( 'Gtk3::Button' ) } @kids;

SKIP:
    {
        skip 'no reroll button', 4 unless $shown && $roll;

        my %seen;
        for ( 1 .. 8 )
        {
            $roll->clicked;
            $seen{ $built->{ get }->() }++;
        }

        cmp_ok scalar keys %seen, '>', 5,
            'eight presses give eight or nearly eight different seeds';

        cmp_ok scalar @told, '>=', 6,
            'and the caller hears about each one, so the track re-renders';

        # Shown rather than hidden, because seeing it change is how anybody
        # knows the button did anything -- and that number is what travels in
        # a saved preset and in the copied command line.
        is $shown->get_text, $built->{ get }->(),
            'the number on screen is the seed being used';

        ok $roll->get_tooltip_text, 'and the button says what it does';
    }
}

# ---------------------------------------------------------------------------
# A number that names the values people use gets the list, not a track

# The same argument as the calendar and the seed, a third time. A slider is
# for a quantity, and a drive's spindle is not one: it spins at 5400 or 7200,
# and a track between them is a track whose whole length is wrong answers.
#
# Typeable rather than closed, because the number still means something on its
# own -- and the declared range still has the last word over what is typed.
{
    my $spec = GlitchVape::Generator::get( 'drive' )->{ params }{ rpm };

    ok $spec->{ suggest }, 'the spindle names the speeds drives were built at';

    my @told;
    my $built = GlitchVape::GUI::Params->build(
        effect    => 'drive',
        name      => 'rpm',
        spec      => $spec,
        value     => 5400,
        on_change => sub { push @told, $_[ 0 ] },
    );

    my $combo = $built->{ control };

    isa_ok $combo, 'Gtk3::ComboBoxText',
        'an int that suggests values gets a list rather than a slider';

    my @offered;
    $combo->get_model->foreach(
        sub { push @offered, $_[ 0 ]->get_value( $_[ 2 ], 0 ); return 0 } );

    is_deeply \@offered, [ 4200, 5400, 7200, 10_000, 15_000 ],
        'and offers exactly the ones the declaration names';

    is $built->{ get }->(), 5400, 'opening on the one it was given';

    # Still an entry underneath: a drive that spun at something else is a
    # drive somebody may want.
    $combo->get_child->set_text( 6800 );

    is $built->{ get }->(), 6800, 'a speed not on the list can be typed';
    is $told[ -1 ],         6800, 'and the caller hears about it';
}

# ---------------------------------------------------------------------------
# A colour is recognised by what it is, not by what it is called

# There was a list of four names here -- tint, color, shadow, background --
# and cmyk.paper is a colour that is not one of them, so it got a plain box
# for a thing nobody can spell. Anything whose default is a hex triplet is a
# colour whatever it is called, which is the same argument the rest of this
# module rests on: the declaration says what a parameter is.
{
    my $picker = sub {
        my ( $effect, $name ) = @_;

        my $spec = GlitchVape::Registry->get( $effect )->{ params }{ $name };
        return 0 unless $spec;

        my $built = GlitchVape::GUI::Params->build(
            effect    => $effect,
            name      => $name,
            spec      => $spec,
            value     => $spec->{ default },
            on_change => sub { },
        );

        my @kids =
              $built->{ control }->can( 'get_children' )
            ? $built->{ control }->get_children
            : ();

        return scalar grep { $_->isa( 'Gtk3::ColorButton' ) } @kids;
    };

    ok $picker->( 'cmyk', 'paper' ),
        'the paper a halftone is printed on gets a picker';

    # The named ones still do: two of these declare no hex default at all --
    # a tint is empty until it is asked for, and a letterbox is 'black'.
    for my $pair (
        [ 'grade',     'tint' ],
        [ 'letterbox', 'color' ],
        [ 'curvature', 'background' ],
        [ 'text',      'shadow' ],
        )
    {
        ok $picker->( @$pair ), "$pair->[0].$pair->[1] still gets one";
    }

    # And a number is not a colour however it is spelled.
    ok !$picker->( 'cmyk', 'pitch' ), 'a screen ruling does not get one';
}

# ---------------------------------------------------------------------------
# Four angles are four controls

# They were one text box holding '15,75,0,45', which is four numbers in a
# trench coat: no range, no label saying which ink is which, and a typo
# anywhere in it failing the whole effect.
{
    my $spec = GlitchVape::Registry->get( 'cmyk' )->{ params };

    ok !$spec->{ angles }, 'the comma-separated box is gone';

    for my $ink ( qw(cyan magenta yellow black) )
    {
        ok $spec->{ $ink }, "there is a control for the $ink plate";

        my $built = GlitchVape::GUI::Params->build(
            effect    => 'cmyk',
            name      => $ink,
            spec      => $spec->{ $ink },
            value     => $spec->{ $ink }{ default },
            on_change => sub { },
        );

        isa_ok $built->{ control }, 'Gtk3::Scale', "and $ink is a track";
    }

    is_deeply
        [ map { $spec->{ $_ }{ default } } qw(cyan magenta yellow black) ],
        [ 15, 75, 0, 45 ],
        'opening on the classical angles the string used to hold';
}

done_testing;
