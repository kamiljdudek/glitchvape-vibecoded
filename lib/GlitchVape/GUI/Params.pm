package GlitchVape::GUI::Params;

use strict;
use warnings;

use Gtk3 ();

use GlitchVape::Fonts   ();
use GlitchVape::Palette ();

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
    str                   Gtk3::Entry, or a combo where the accepted values
                          are known, or an entry paired with a colour picker
                          or a calendar

The four string cases are worth the special-casing: C<palette.name> takes one
of twelve named palettes I<or> an inline list of hex colours, C<text.font>
takes a font role rather than a font name, a colour parameter typed by hand is
the one most likely to be got wrong, and C<osd.date> is a date, which is a
thing people pick rather than spell.

=head1 THE ENTRY STAYS AUTHORITATIVE

Two parameters get a second widget beside the entry -- a colour picker and a
calendar -- and in both cases the entry is the value and the widget is a way
of filling it in, never the other way round.

That is not symmetry for its own sake. Both parameters have a meaning that no
picker can express: an empty colour means "no colour", and an empty
C<osd.date> means "invent a plausible 1990s date, a different one per seed",
which is the effect's default and the thing most renders want. A calendar has
no way to be set to nothing. So it writes into the entry and the entry is what
the pipeline reads, which keeps the emptiable states reachable and keeps
C<--set osd.date='JAN 05 1995'> and the window talking about the same string.

=cut

# Parameters whose value is a colour. Keyed by name rather than by effect,
# since every effect spells them the same way.
my %COLOUR_PARAM = map { $_ => 1 } qw(tint color shadow background);

# Parameters whose accepted values are known but open: the combo offers them
# and the entry still takes anything, because palette.name also accepts an
# inline '#FF71CE,#01CDFE' list.
my %SUGGESTED = (
    'palette.name'      => sub { GlitchVape::Palette::names() },
    'gradient_map.name' => sub { GlitchVape::Palette::names() },
    'duotone.name'      => sub { GlitchVape::Palette::duotone_names() },
    'letterbox.ratio'   => sub { qw(16:9 2.35:1 4:3 1:1 9:16) },
);

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
    suggested => \&_suggested,
    font      => \&_font,
    text      => \&_text,
);

sub build
{
    my ( $class, %arg ) = @_;

    my $spec = $arg{ spec };

    my $label = Gtk3::Label->new( $arg{ name } );
    $label->set_xalign( 0 );
    $label->set_width_chars( 13 );

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
    return 'suggested' if $SUGGESTED{ "$arg->{effect}.$arg->{name}" };
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

    my @values = $SUGGESTED{ "$arg->{effect}.$arg->{name}" }->();
    return _combo_with_entry( $arg, \@values );
}

sub _font
{
    my ( $arg ) = @_;

    my @roles = map { $_->[ 0 ] } @{ GlitchVape::Fonts::available() };
    return _combo_with_entry( $arg, \@roles );
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

sub _date
{
    my ( $arg ) = @_;

    my $box = Gtk3::Box->new( 'horizontal', 4 );

    my $entry = Gtk3::Entry->new;
    $entry->set_text( _as_text( $arg->{ value } ) );
    $entry->set_hexpand( 1 );
    $entry->set_placeholder_text( 'Any 1990s date' );

    my $button = Gtk3::Button->new;
    $button->set_image(
        Gtk3::Image->new_from_icon_name(
            'x-office-calendar-symbolic', 'button'
        )
    );
    $button->set_tooltip_text( 'Pick a date' );

    my $calendar = Gtk3::Calendar->new;

    # Pointing the calendar at the entry's value is itself a day-selected --
    # twice, in fact, since select_month and select_day each emit one -- and
    # without this the act of opening the picker would write the date back
    # over whatever was typed. That is not a cosmetic difference: 'TUESDAY' is
    # a legal osd.date, and a picker that silently replaced it with JUN 15
    # 1995 on the way past would be destroying the value it was opened to
    # show. It would also fire on_change and cost a render nobody asked for.
    my $seeking = 0;

    # Writing into the entry is what commits the choice, and the entry's own
    # changed handler is what tells the caller -- so this does not call
    # on_change itself and cannot report a value twice.
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

    my $any = Gtk3::Button->new_with_label( 'Any 1990s date' );
    $any->set_tooltip_text(
              "Leave it to the seed: a different plausible date per render.\n"
            . 'This is what an empty field means' );

    my $popover = Gtk3::Popover->new( $button );
    $popover->set_position( 'bottom' );

    my $inner = Gtk3::Box->new( 'vertical', 6 );
    $inner->set_border_width( 8 );
    $inner->pack_start( $calendar, 1, 1, 0 );
    $inner->pack_start( $any,      0, 0, 0 );
    $popover->add( $inner );

    $any->signal_connect(
        clicked => sub {
            $entry->set_text( q{} );
            $popover->popdown;
            return;
        }
    );

    $button->signal_connect(
        clicked => sub {

            # Opened on whatever the entry says, so the calendar is showing
            # the current value rather than wherever it was left last time.
            $seeking = 1;
            _seek_calendar( $calendar, $entry->get_text );
            $seeking = 0;

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
