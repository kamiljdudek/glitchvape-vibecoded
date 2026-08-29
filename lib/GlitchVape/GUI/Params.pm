package GlitchVape::GUI::Params;

use strict;
use warnings;

use Gtk3 ();

use List::Util qw(any);

use GlitchVape::Fonts    ();
use GlitchVape::Palette  ();
use GlitchVape::Registry ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Params - parameter declarations as Gtk widgets

=head1 DESCRIPTION

Effects declare their parameters with a type, a default and usually a range,
and that declaration is already what drives the command-line flags and
C<--explain>. This module makes it drive the interface too, so an effect added
to L<GlitchVape::Registry> gets a control without anyone editing the GUI.

    num with a range      Gtk3::Scale       drag it
    num without a range   Gtk3::SpinButton  no sensible track length
    int                   Gtk3::Scale       whole numbers, step 1
    bool                  Gtk3::Switch
    enum                  Gtk3::ComboBoxText
    list                  Gtk3::Entry       comma separated
    str                   Gtk3::Entry; a combo, open or closed, where the
                          parameter says what it offers; or an entry paired
                          with a colour picker, a calendar or a clock

The five string cases are worth the special-casing: a parameter that declares
a suggestion list takes one of those values I<or> anything else typed in,
C<text.font> takes a font role rather than a font name, a colour parameter
typed by hand is the one most likely to be got wrong, and C<osd.date> and
C<osd.time> are a date and a time, which are things people pick rather than
spell.

Gtk3 has a calendar and no clock, so the time picker is built here out of two
spin buttons and a combo. It is the same shape as the calendar deliberately:
a button beside the entry, a popover, and the entry still holding the value.

=head1 THE ENTRY STAYS AUTHORITATIVE

Three parameters get a second widget beside the entry -- a colour picker, a
calendar and a clock -- and in all three the entry is the value and the widget
is a way of filling it in, never the other way round.

That is not symmetry for its own sake. Each has meanings no picker can
express: an empty colour means "no colour", an empty C<osd.date> means "draw
no date line", and both C<osd.date> and C<osd.time> take any literal string at
all -- C<TUESDAY> is a legal timestamp and somebody who typed it meant it. A
calendar has no way to be set to nothing and no way to say TUESDAY. So it
writes into the entry and the entry is what the pipeline reads, which keeps
those states reachable and keeps C<--set osd.date='JAN 05 1995'> and the
window talking about the same string.

=head1 A DECLARATION MAY SAY HOW IT IS PRESENTED

C<suggest> and C<choose> both name the values a parameter offers -- a source
this module knows, or an inline list -- and differ in what typing something
else would mean. C<suggest> gives a combo with an entry in it, for a value the
list cannot enumerate; C<choose> gives a plain drop-down, for one where there
is nothing else to say.

Three more keys are read here and nowhere in the render path: C<order>, which
L<GlitchVape::Registry/sorted_params> sorts by; C<label>, used in place of the
bare parameter name where the key is not the clearest English; and C<needs>,
which L</apply_needs> turns into a greyed-out control.

They are all on the declaration rather than in a table here, for invariant 1's
reason: a table keyed on 'effect.param' means adding an effect edits the GUI.

=cut

# Parameters whose value is a colour. Keyed by name rather than by effect,
# since every effect spells them the same way.
my %COLOUR_PARAM = map { $_ => 1 } qw(tint color shadow background);

# Where a suggestion list comes from. A parameter opts in by declaring
# `suggest => 'palette'` in the registry, and the combo then offers these
# while the entry still takes anything -- a palette parameter also accepts an
# inline '#FF71CE,#01CDFE' list, so the values are an offer, not a set.
#
# Keyed by the kind of suggestion rather than by 'effect.param', which is what
# it used to be. That spelling meant every new effect wanting a palette needed
# a line adding here, so the declaration stopped being the whole story and the
# GUI had to be edited to add an effect. Now a fifth effect wanting palette
# names says so where its other parameters are described, and this file does
# not change.
my %SUGGEST_SOURCE = (
    palette => sub { GlitchVape::Palette::names() },
    duotone => sub { GlitchVape::Palette::duotone_names() },
    ratio   => sub { qw(16:9 2.35:1 4:3 1:1 9:16) },
);

=head2 split( $params )

C<< ( \@ordinary, \@animation ) >>, both in presentation order, from an
effect's parameter hash.

The split is on the declaration's C<animation> flag rather than on the name, so
a new parameter that only bites in a loop says so where its type and range are
declared and is grouped without anything here learning about it.

Two lists rather than one sorted with the animation ones last, because the
caller has to put something between them: a C<drift> sitting under an opacity
with nothing to say it is different is a control that does nothing on the
still somebody is looking at.

=cut

sub split
{
    my ( $params ) = @_;

    my ( @ordinary, @animation );

    for my $key ( GlitchVape::Registry::sorted_params( $params ) )
    {
        if   ( $params->{ $key }{ animation } ) { push @animation, $key }
        else                                    { push @ordinary,  $key }
    }

    return ( \@ordinary, \@animation );
}

=head2 apply_needs( $params, $built, $values )

Grey out the controls whose declared C<needs> are not met, given the effect's
current values. C<$built> is what L</build> returned, keyed by parameter name.

Greyed rather than hidden, and rather than nothing at all. Nothing at all is
what osd used to do, and it is how a date field that quietly stopped mattering
the moment the timestamp switch went off could sit there inviting somebody to
type into it. Hidden would fix that and introduce a worse one: a control that
appears and disappears teaches nobody what turned it on, and every row below
it moves while you are reading it. Greyed says both things at once -- this
exists, and something else has to change before it counts.

The value is left alone, so switching a controlling parameter back on gives
back the date that was already typed.

=cut

sub apply_needs
{
    my ( $params, $built, $values ) = @_;

    for my $key ( keys %{ $built || {} } )
    {
        my $spec = $params->{ $key } or next;

        my $on = GlitchVape::Registry::needs_met( $spec, $values ) ? 1 : 0;

        $built->{ $key }{ label }->set_sensitive( $on );
        $built->{ $key }{ control }->set_sensitive( $on );
    }

    return;
}

=head2 build( %arg )

    effect    => 'scanlines'
    name      => 'opacity'
    spec      => the registry's declaration for that parameter
    value     => current value
    on_change => sub { my ( $value ) = @_ }

Returns C<< { label => $widget, control => $widget, get => $code, stretch =>
$bool } >>. The caller owns the layout; this only decides what the control is.

C<stretch> is false for the one control that has a size of its own. A slider,
a combo and an entry all say more the wider they are, so a caller giving the
column a width is doing them a favour; a C<Gtk3::Switch> is a fixed-size
picture of a lever, and widening it produces a lozenge the length of the
dialog. The switch is the only such control today, but the flag is on the
result rather than a list of exceptions in the caller, because the next
fixed-size control should not have to find every layout that would stretch it.

=cut

# Which control a parameter gets. A lookup table rather than a chain of
# branches: the kinds are unrelated to one another, so there is no ordering
# worth expressing, and a new one is an entry rather than an elsif.
my %BUILDER = (
    bool      => \&_bool,
    enum      => \&_enum,
    numeric   => \&_numeric,
    colour    => \&_colour,
    date      => \&_date,
    time      => \&_time,
    suggested => \&_suggested,
    chosen    => \&_chosen,
    font      => \&_font,
    text      => \&_text,
);

sub build
{
    my ( $class, %arg ) = @_;

    my $spec = $arg{ spec };

    # The declaration's own words where it has them. 'rec_mode' is what the
    # preset key and --set flag are called and has to stay visible somewhere,
    # which is what the popover's header line does; the row itself can afford
    # to say 'DV REC mode'.
    my $label = Gtk3::Label->new( $spec->{ label } // $arg{ name } );
    $label->set_xalign( 0 );
    $label->set_width_chars( 13 );

    # Not wrapped: the column is only as wide as the longest label in it, and
    # a two-line row beside a one-line control reads as a layout that has
    # given up rather than as a name that is long. A label wide enough to
    # widen the popover is a label to shorten, in the declaration.

    my $doc = $spec->{ doc };
    if ( defined $doc && length $doc )
    {
        $label->set_tooltip_text( $doc );
    }

    my $built = $BUILDER{ _kind( \%arg ) }->( \%arg );

    if ( defined $doc && length $doc )
    {
        $built->{ control }->set_tooltip_text( $doc );
    }

    $built->{ label }   = $label;
    $built->{ stretch } = 1 unless exists $built->{ stretch };

    return $built;
}

# The declared type decides it except for strings, where the parameter's own
# name says more than 'str' does: a colour, a value drawn from a known set, or
# free text.
sub _kind
{
    my ( $arg ) = @_;

    my $type = $arg->{ spec }{ type } // 'str';

    return $type       if $type eq 'bool' || $type eq 'enum';
    return 'numeric'   if $type eq 'int'  || $type eq 'num';
    return 'colour'    if _is_colour( $arg );
    return 'date'      if $arg->{ name } eq 'date';
    return 'time'      if $arg->{ name } eq 'time';
    return 'chosen'    if _offered( $arg->{ spec }, 'choose' );
    return 'suggested' if _offered( $arg->{ spec }, 'suggest' );
    return 'font'      if $arg->{ name } eq 'font';
    return 'text';
}

# ---------------------------------------------------------------------------

sub _bool
{
    my ( $arg ) = @_;

    my $sw = Gtk3::Switch->new;
    $sw->set_active( $arg->{ value } ? 1 : 0 );
    $sw->set_halign( 'start' );

    $sw->signal_connect(
        'notify::active' => sub {
            $arg->{ on_change }->( $sw->get_active ? 1 : 0 )
                if $arg->{ on_change };
            return;
        }
    );

    return {
        control => $sw,
        stretch => 0,
        get     => sub { return $sw->get_active ? 1 : 0 },
    };
}

sub _enum
{
    my ( $arg ) = @_;

    my @values = @{ $arg->{ spec }{ values } || [] };

    my $combo = Gtk3::ComboBoxText->new;
    my $index = 0;

    for my $n ( 0 .. $#values )
    {
        $combo->append_text( $values[ $n ] );
        if ( lc $values[ $n ] eq lc( $arg->{ value } // q{} ) )
        {
            $index = $n;
        }
    }

    $combo->set_active( $index );
    $combo->set_hexpand( 1 );

    $combo->signal_connect(
        changed => sub {
            my $text = $combo->get_active_text;
            return unless defined $text;
            $arg->{ on_change }->( $text ) if $arg->{ on_change };
            return;
        }
    );

    return {
        control => $combo,
        get     => sub { return $combo->get_active_text },
    };
}

sub _numeric
{
    my ( $arg ) = @_;

    my $spec = $arg->{ spec };
    my $type = $spec->{ type };
    my $min  = $spec->{ min };
    my $max  = $spec->{ max };

    # Without both ends there is nothing to scale a track against, so an
    # unbounded number gets a spin button with a generous nominal range.
    if ( !defined $min || !defined $max )
    {
        return _spin( $arg, $type, $min, $max );
    }

    my ( $digits, $step ) = _resolution( $type, $min, $max );

    my $scale = Gtk3::Scale->new_with_range( 'horizontal', $min, $max, $step );
    $scale->set_digits( $digits );
    $scale->set_value( $arg->{ value } // $spec->{ default } // $min );
    $scale->set_value_pos( 'right' );
    $scale->set_hexpand( 1 );

    # A mark at the declared default: the reference point for "how far have I
    # pushed this" is the only thing a bare track does not show.
    my $default = $spec->{ default };
    if ( defined $default && $default >= $min && $default <= $max )
    {
        $scale->add_mark( $default, 'bottom', undef );
    }

    $scale->signal_connect(
        'value-changed' => sub {
            $arg->{ on_change }->( $scale->get_value ) if $arg->{ on_change };
            return;
        }
    );

    return { control => $scale, get => sub { return $scale->get_value } };
}

sub _spin
{
    my ( $arg, $type, $min, $max ) = @_;

    my $lo = $min;
    my $hi = $max;
    $lo = -1_000_000 unless defined $lo;
    $hi =  1_000_000 unless defined $hi;

    my $step   = 1;
    my $digits = 0;
    if ( $type eq 'num' )
    {
        $step   = 0.01;
        $digits = 3;
    }

    my $spin = Gtk3::SpinButton->new_with_range( $lo, $hi, $step );
    $spin->set_digits( $digits );
    $spin->set_value( $arg->{ value } // 0 );
    $spin->set_hexpand( 1 );

    $spin->signal_connect(
        'value-changed' => sub {
            $arg->{ on_change }->( $spin->get_value ) if $arg->{ on_change };
            return;
        }
    );

    return { control => $spin, get => sub { return $spin->get_value } };
}

# How finely a slider should move. A 0..1 opacity wants three decimals; a
# 0..500 displacement wants whole numbers, or the track becomes unusable.
sub _resolution
{
    my ( $type, $min, $max ) = @_;

    return ( 0, 1 ) if $type eq 'int';

    my $span = $max - $min;

    return ( 3, 0.001 ) if $span <= 2;
    return ( 2, 0.01 )  if $span <= 20;
    return ( 1, 0.1 )   if $span <= 200;
    return ( 0, 1 );
}

sub _text
{
    my ( $arg ) = @_;

    my $entry = Gtk3::Entry->new;
    $entry->set_text( _as_text( $arg->{ value } ) );
    $entry->set_hexpand( 1 );

    $entry->signal_connect(
        changed => sub {
            $arg->{ on_change }->( $entry->get_text ) if $arg->{ on_change };
            return;
        }
    );

    return { control => $entry, get => sub { return $entry->get_text } };
}

sub _suggested
{
    my ( $arg ) = @_;

    return _combo_with_entry( $arg, _offered( $arg->{ spec }, 'suggest' ) );
}

sub _chosen
{
    my ( $arg ) = @_;

    return _combo_of( $arg, _offered( $arg->{ spec }, 'choose' ) );
}

# What a parameter offers, or undef if it offers nothing. Two spellings, and
# the difference is what typing something else would mean:
#
#   suggest => ...   these, or anything else you can think of
#   choose  => ...   these, and there is nothing else to say
#
# Which of the two a parameter wants is a fact about the parameter and not
# about the widget, so it is declared rather than decided here. bitmap.palette
# chooses: five settings make a bitmap look like a machine, and the palette is
# which machine, so a list is the whole question. palette.name suggests: that
# effect is *about* the colours, so an inline '#FF71CE,#01CDFE' that no list
# could enumerate is exactly what somebody might mean.
#
# Either spelling takes a named source or an inline list, and the difference
# there is whether the values are a fact about the program or about this one
# parameter. The inline form matters for invariant 1: a named source needs a
# line in %SUGGEST_SOURCE, so an effect wanting to offer three strings of its
# own would otherwise have to edit this file to do it.
sub _offered
{
    my ( $spec, $key ) = @_;

    my $offer = $spec->{ $key };
    return undef unless defined $offer;

    return [ @$offer ] if ref $offer eq 'ARRAY';

    my $source = $SUGGEST_SOURCE{ $offer } or return undef;
    return [ $source->() ];
}

# A closed list, unlike the palette pickers above it. A palette parameter
# takes an inline '#FF71CE,#01CDFE' that no list could enumerate, so its combo
# has to stay typeable. A font parameter takes a role, the roles are a fixed
# set, and anything else typed into it resolves to nothing -- so the entry
# offered only the chance to get it wrong.
sub _font
{
    my ( $arg ) = @_;

    my @roles = map { $_->[ 0 ] } @{ GlitchVape::Fonts::available() };

    return _combo_of( $arg, \@roles );
}

sub _combo_of
{
    my ( $arg, $values ) = @_;

    my $combo = Gtk3::ComboBoxText->new;
    $combo->set_hexpand( 1 );

    my $current = _as_text( $arg->{ value } );

    # A value the list does not hold is still the value. Shown as an entry of
    # its own rather than left to fall through to the first one, which would
    # have the control naming a palette the render is not using -- and a
    # closed list is the one place that can happen, since the CLI and the
    # presets accept things the list was never meant to enumerate.
    my @all = @$values;
    if ( length $current && !any { $_ eq $current } @all )
    {
        unshift @all, $current;
    }

    $values = \@all;

    my $active = 0;

    for my $n ( 0 .. $#$values )
    {
        $combo->append_text( $values->[ $n ] );
        $active = $n if $values->[ $n ] eq $current;
    }

    $combo->set_active( $active );

    $combo->signal_connect(
        changed => sub {
            my $at = $combo->get_active;
            return if !defined $at || $at < 0;

            $arg->{ on_change }->( $values->[ $at ] ) if $arg->{ on_change };
            return;
        }
    );

    return { control => $combo, get => sub { $combo->get_active_text } };
}

sub _combo_with_entry
{
    my ( $arg, $values ) = @_;

    my $combo = Gtk3::ComboBoxText->new_with_entry;
    $combo->append_text( $_ ) for @$values;
    $combo->set_hexpand( 1 );

    my $entry = $combo->get_child;
    $entry->set_text( _as_text( $arg->{ value } ) );

    $entry->signal_connect(
        changed => sub {
            $arg->{ on_change }->( $entry->get_text ) if $arg->{ on_change };
            return;
        }
    );

    return { control => $combo, get => sub { return $entry->get_text } };
}

sub _is_colour
{
    my ( $arg ) = @_;

    return 0 unless $COLOUR_PARAM{ $arg->{ name } };

    # curvature.background is a colour; letterbox.color is too. Anything whose
    # default is a hex triplet or a plain word is safe to offer a picker for,
    # but a list of colours is not.
    my $default = $arg->{ spec }{ default };
    return 0 if defined $default && $default =~ /,/;

    return 1;
}

sub _colour
{
    my ( $arg ) = @_;

    my $box = Gtk3::Box->new( 'horizontal', 4 );

    my $entry = Gtk3::Entry->new;
    $entry->set_text( _as_text( $arg->{ value } ) );
    $entry->set_hexpand( 1 );
    $entry->set_width_chars( 9 );

    my $button = Gtk3::ColorButton->new;
    $button->set_tooltip_text( 'Pick a colour' );

    # The entry is the value; the button is a way of filling it in. An empty
    # string means "no colour", which no picker can express, so the entry has
    # to stay authoritative.
    my $sync_button = sub {
        my $rgba = _parse_colour( $entry->get_text );
        $button->set_rgba( $rgba ) if $rgba;
        return;
    };
    $sync_button->();

    $button->signal_connect(
        'color-set' => sub {
            $entry->set_text( _rgba_to_hex( $button->get_rgba ) );
            return;
        }
    );

    $entry->signal_connect(
        changed => sub {
            $sync_button->();
            $arg->{ on_change }->( $entry->get_text ) if $arg->{ on_change };
            return;
        }
    );

    $box->pack_start( $entry,  1, 1, 0 );
    $box->pack_start( $button, 0, 0, 0 );

    return { control => $box, get => sub { return $entry->get_text } };
}

# The camcorder OSD format: three-letter month, zero-padded day, four-digit
# year. Matches GlitchVape::Effect::Overlay's _fake_date, because a date
# picked here and a date it invented have to be the same kind of string --
# otherwise switching from one to the other changes the width of the overlay.
my @MONTH = qw(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC);

# Where the calendar opens when the entry is empty or unreadable. Not today:
# the effect exists to put a 1990s timestamp on a photograph, and opening on
# the present date invites exactly the anachronism it avoids by default.
use constant DEFAULT_YEAR  => 1995;
use constant DEFAULT_MONTH => 5;      # zero-based, so June
use constant DEFAULT_DAY   => 15;

# And where the clock opens, for the same reason and to match osd.time's own
# default, so a picker opened on an unreadable string lands where the
# declaration would have put it.
use constant DEFAULT_MERIDIEM => 'PM';
use constant DEFAULT_HOUR     => 3;
use constant DEFAULT_MINUTE   => 47;

sub _date
{
    my ( $arg ) = @_;

    return _picker(
        $arg,
        icon        => 'x-office-calendar-symbolic',
        tooltip     => 'Pick a date',
        placeholder => 'Not shown',
        build       => sub {
            my ( $entry ) = @_;

            my $calendar = Gtk3::Calendar->new;

            # Pointing the calendar at the entry's value is itself a
            # day-selected -- twice, in fact, since select_month and
            # select_day each emit one -- and without this the act of opening
            # the picker would write the date back over whatever was typed.
            # That is not a cosmetic difference: 'TUESDAY' is a legal
            # osd.date, and a picker that silently replaced it with JUN 15
            # 1995 on the way past would be destroying the value it was
            # opened to show. It would also fire on_change and cost a render
            # nobody asked for.
            my $seeking = 0;

            # Writing into the entry is what commits the choice, and the
            # entry's own changed handler is what tells the caller -- so this
            # does not call on_change itself and cannot report a value twice.
            $calendar->signal_connect(
                'day-selected' => sub {
                    return if $seeking;

                    my ( $year, $month, $day ) = $calendar->get_date;
                    $entry->set_text(
                        sprintf '%s %02d %d',
                        $MONTH[ $month ],
                        $day, $year
                    );
                    return;
                }
            );

            my $inner = Gtk3::Box->new( 'vertical', 6 );
            $inner->pack_start( $calendar, 1, 1, 0 );

            return (
                $inner,
                sub {
                    $seeking = 1;
                    _seek_calendar( $calendar, $_[ 0 ] );
                    $seeking = 0;
                    return;
                }
            );
        },
    );
}

# Gtk3 has GtkCalendar and nothing for a time of day, so this is two spin
# buttons and a meridiem combo. Same shape as the date picker on purpose: a
# button beside the entry, a popover, and the entry still holding the value,
# because osd.time takes any literal string too.
sub _time
{
    my ( $arg ) = @_;

    return _picker(
        $arg,
        icon        => 'preferences-system-time-symbolic',
        tooltip     => 'Pick a time',
        placeholder => 'Not shown',
        build       => sub {
            my ( $entry ) = @_;

            my $seeking = 0;

            my $hour   = Gtk3::SpinButton->new_with_range( 1, 12, 1 );
            my $minute = Gtk3::SpinButton->new_with_range( 0, 59, 1 );

            # Both wrap, because 12:59 and 1:00 are a minute apart and a
            # picker that stops dead between them is asking to be typed round.
            $_->set_wrap( 1 ) for $hour, $minute;

            # The minutes are half of a clock reading, not a number: 3:7 is
            # not a time anybody writes.
            $minute->signal_connect(
                output => sub {
                    my ( $spin ) = @_;
                    $spin->set_text( sprintf '%02d', $spin->get_value );
                    return 1;
                }
            );

            my $meridiem = Gtk3::ComboBoxText->new;
            $meridiem->append_text( $_ ) for qw(AM PM);

            my $commit = sub {
                return if $seeking;

                $entry->set_text(
                    _format_time(
                        $meridiem->get_active_text // DEFAULT_MERIDIEM,
                        $hour->get_value,
                        $minute->get_value
                    )
                );
                return;
            };

            $_->signal_connect( 'value-changed' => $commit ) for $hour, $minute;
            $meridiem->signal_connect( changed => $commit );

            my $inner = Gtk3::Box->new( 'horizontal', 4 );
            $inner->pack_start( $meridiem,               0, 0, 0 );
            $inner->pack_start( $hour,                   0, 0, 0 );
            $inner->pack_start( Gtk3::Label->new( ':' ), 0, 0, 0 );
            $inner->pack_start( $minute,                 0, 0, 0 );

            return (
                $inner,
                sub {
                    my ( $m, $h, $n ) = _parse_time( $_[ 0 ] );

                    $seeking = 1;
                    $meridiem->set_active( $m eq 'AM' ? 0 : 1 );
                    $hour->set_value( $h );
                    $minute->set_value( $n );
                    $seeking = 0;
                    return;
                }
            );
        },
    );
}

# What the date and time pickers have in common, which is everything except
# what is inside the popover: the entry is the value, the button is a way of
# filling it in, and opening the picker points it at what the entry currently
# says rather than at wherever it was left last time.
#
# `build` is handed the entry and returns the popover's contents and a way to
# seek them, which is what lets the guard against writing back over a literal
# live in the closure that needs it.
sub _picker
{
    my ( $arg, %opt ) = @_;

    my $box = Gtk3::Box->new( 'horizontal', 4 );

    my $entry = Gtk3::Entry->new;
    $entry->set_text( _as_text( $arg->{ value } ) );
    $entry->set_hexpand( 1 );
    $entry->set_placeholder_text( $opt{ placeholder } );

    my $button = Gtk3::Button->new;
    $button->set_image(
        Gtk3::Image->new_from_icon_name( $opt{ icon }, 'button' ) );
    $button->set_tooltip_text( $opt{ tooltip } );

    my ( $inner, $seek ) = $opt{ build }->( $entry );
    $inner->set_border_width( 8 );

    my $popover = Gtk3::Popover->new( $button );
    $popover->set_position( 'bottom' );
    $popover->add( $inner );

    $button->signal_connect(
        clicked => sub {
            $seek->( $entry->get_text );

            $popover->show_all;
            $popover->popup;
            return;
        }
    );

    $entry->signal_connect(
        changed => sub {
            $arg->{ on_change }->( $entry->get_text ) if $arg->{ on_change };
            return;
        }
    );

    $box->pack_start( $entry,  1, 1, 0 );
    $box->pack_start( $button, 0, 0, 0 );

    return { control => $box, get => sub { return $entry->get_text } };
}

# Matches GlitchVape::Effect::Overlay's _fake_time, down to the space that
# pads a single-digit hour: a time picked here and a time it invented have to
# be the same kind of string, or switching between them changes the width of
# the overlay.
sub _format_time
{
    my ( $meridiem, $hour, $minute ) = @_;

    return sprintf '%s %2d:%02d', uc $meridiem, $hour, $minute;
}

sub _parse_time
{
    my ( $text ) = @_;

    my @fallback = ( DEFAULT_MERIDIEM, DEFAULT_HOUR, DEFAULT_MINUTE );

    return @fallback unless defined $text;

    my ( $meridiem, $hour, $minute ) =
        $text =~ /\A\s*([AP]M)\s+(\d{1,2}):(\d{2})\s*\z/i;

    return @fallback unless defined $meridiem;
    return @fallback if $hour < 1 || $hour > 12;
    return @fallback if $minute > 59;

    return ( uc $meridiem, 0 + $hour, 0 + $minute );
}

# Point the calendar at what the entry holds. A string it cannot read is not
# an error -- osd.date takes any literal text, and somebody who typed
# 'TUESDAY' meant it -- so the calendar falls back to a 1990s day and leaves
# the entry alone.
sub _seek_calendar
{
    my ( $calendar, $text ) = @_;

    my ( $year, $month, $day ) = _parse_date( $text );

    $calendar->select_month( $month, $year );
    $calendar->select_day( $day );

    return;
}

sub _parse_date
{
    my ( $text ) = @_;

    my @fallback = ( DEFAULT_YEAR, DEFAULT_MONTH, DEFAULT_DAY );

    return @fallback unless defined $text;

    my ( $name, $day, $year ) =
        $text =~ /\A\s*([A-Za-z]{3})\s+(\d{1,2})\s+(\d{4})\s*\z/;

    return @fallback unless defined $name;

    my $month;
    for my $n ( 0 .. $#MONTH )
    {
        $month = $n if lc $MONTH[ $n ] eq lc $name;
    }

    return @fallback unless defined $month;

    # A day the month does not have -- FEB 31 -- is a string somebody typed,
    # not a date to seek to.
    return @fallback if $day < 1 || $day > _days_in( $month, $year );

    # Numbers, not the strings the capture produced: a zero-padded '05' is
    # the same day as 5 and every caller treats it as a number, so returning
    # one that only compares equal numerically is a trap for the next reader.
    return ( 0 + $year, $month, 0 + $day );
}

my @MONTH_LENGTH = ( 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );

sub _days_in
{
    my ( $month, $year ) = @_;

    return 29 if $month == 1 && _is_leap( $year );

    return $MONTH_LENGTH[ $month ];
}

sub _is_leap
{
    my ( $year ) = @_;

    return 0 if $year % 4;
    return 1 if $year % 100;
    return 0 if $year % 400;

    return 1;
}

sub _parse_colour
{
    my ( $text ) = @_;

    return undef unless defined $text && length $text;

    my $rgba = Gtk3::Gdk::RGBA->new(
        red   => 0,
        green => 0,
        blue  => 0,
        alpha => 1
    );

    return undef unless $rgba->parse( $text );
    return $rgba;
}

sub _rgba_to_hex
{
    my ( $rgba ) = @_;

    return sprintf '#%02X%02X%02X',
        int( $rgba->red * 255 + 0.5 ),
        int( $rgba->green * 255 + 0.5 ),
        int( $rgba->blue * 255 + 0.5 );
}

sub _as_text
{
    my ( $v ) = @_;

    return q{} unless defined $v;
    return join ',', @$v if ref $v eq 'ARRAY';
    return "$v";
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Registry>, whose declarations this reads.

=cut
