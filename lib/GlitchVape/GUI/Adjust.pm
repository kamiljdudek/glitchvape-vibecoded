package GlitchVape::GUI::Adjust;

use strict;
use warnings;
use utf8;

use Gtk3 ();

use GlitchVape::Registry    ();
use GlitchVape::GUI::Params ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Adjust - one effect's settings, in a popover

=head1 DESCRIPTION

The effect list says what is in the pipeline; this says what the selected
member of it is set to. One popover, hung off the Adjust button, showing
whichever effect the list has selected.

=head1 WHY A POPOVER AND NOT A WINDOW

There is no OK here and no Cancel, and there never was: a control writes to
the state the moment it moves. A window with a title bar and no confirming
buttons looks like a dialog and behaves like a panel, which is a promise it
does not keep -- people look for the button that commits the change, and the
only one they find is Apply, which belongs to the whole pipeline rather than
to this effect.

A popover says what is true. It is attached to the control that opened it, so
what it belongs to is visible rather than remembered; it has no title bar to
suggest a decision is pending; and dismissing it discards nothing, because
nothing was being held back.

=head2 It is deliberately not modal

C<set_modal(0)>, which is not a popover's default. Rendering here is an
explicit Apply, so a modal popover -- one that closes the moment anything else
is clicked -- would have to be reopened after every render: adjust, Apply,
watch, reopen, adjust. Left non-modal it stays up across an Apply, and closes
when Adjust is pressed again or the effect it describes leaves the pipeline.

=head2 What this costs

One effect at a time. Two effects' settings were once open together, which is
genuinely the better way to decide how much C<chroma_shift> answers this much
C<scanlines>. That is the price of the popover being honest about what it is,
and it is paid knowingly.

=head1 THE SWITCH AND THE CHECKBOX ARE ONE FACT

Whether an effect is in the render is shown twice: as a checkbox on its row
and as a switch at the top of this popover. Both write the same state, and
each is told when the other has moved, guarded so that being told does not
count as being set -- otherwise the two would answer each other forever.

=cut

# Taller than this and the popover runs off the screen. osd declares twelve
# parameters, which is the one that makes this necessary.
use constant MAX_HEIGHT => 420;

=head2 new( %arg )

    relative_to => the widget to hang off
    state       => GlitchVape::GUI::State
    on_change   => sub { }                       a parameter moved
    on_enabled  => sub { my ( $name, $on ) = @_ }

Builds the popover empty and closed. Nothing is shown until L</show_effect>.

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $self = bless {
        state      => $arg{ state },
        on_change  => $arg{ on_change },
        on_enabled => $arg{ on_enabled },
        effect     => undef,
        controls   => {},
        shown      => 0,
        loading    => 0,
    }, $class;

    my $popover = Gtk3::Popover->new( $arg{ relative_to } );

    # Upwards: the Adjust button is at the foot of the pane, so there is never
    # room below it.
    $popover->set_position( 'top' );

    # See L</It is deliberately not modal>.
    $popover->set_modal( 0 );

    my $box = Gtk3::Box->new( 'vertical', 10 );
    $box->set_border_width( 12 );

    $self->{ header } = Gtk3::Box->new( 'horizontal', 12 );
    $box->pack_start( $self->{ header },                    0, 0, 0 );
    $box->pack_start( Gtk3::Separator->new( 'horizontal' ), 0, 0, 0 );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );
    $scroll->set_propagate_natural_height( 1 );
    $scroll->set_max_content_height( MAX_HEIGHT );

    $self->{ body } = Gtk3::Box->new( 'vertical', 0 );
    $scroll->add( $self->{ body } );
    $box->pack_start( $scroll, 1, 1, 0 );

    # popdown() closes with a transition, so the widget's own visibility lags
    # behind the decision by the length of it. Callers ask this object whether
    # it is up and expect the answer to be true the instant it is, so the
    # decision is kept here and the signal catches a close from anywhere else.
    $popover->signal_connect(
        closed => sub {
            $self->{ shown }  = 0;
            $self->{ effect } = undef;
            return;
        }
    );

    $popover->add( $box );

    $self->{ popover } = $popover;
    $self->{ box }     = $box;

    return $self;
}

=head2 popover()

The widget, for a caller that needs to query it.

=cut

sub popover { $_[ 0 ]{ popover } }

=head2 effect()

The effect currently shown, or undef.

=cut

sub effect { $_[ 0 ]{ effect } }

=head2 visible()

Whether the popover is up.

=cut

sub visible { return $_[ 0 ]{ shown } ? 1 : 0 }

=head2 show_effect( $name )

Fill the popover with that effect's settings and open it. Called again with a
different name while it is already open, it simply changes what it shows --
which is what following the list selection looks like.

=cut

sub show_effect
{
    my ( $self, $name ) = @_;

    return unless defined $name;
    return unless GlitchVape::Registry->get( $name );

    $self->{ effect } = $name;
    $self->_build;

    $self->{ shown } = 1;
    $self->{ popover }->popup;

    return;
}

=head2 popdown()

Close it. Safe when it is already closed.

=cut

sub popdown
{
    my ( $self ) = @_;

    $self->{ shown }  = 0;
    $self->{ effect } = undef;
    $self->{ popover }->popdown;

    return;
}

=head2 refresh()

Rebuild the controls from the state, for when something has replaced the whole
configuration underneath -- an undo, a redo, a preset. Closes instead if the
effect it was showing is no longer in the pipeline.

=cut

sub refresh
{
    my ( $self ) = @_;

    my $name = $self->{ effect };
    return unless defined $name;

    my $effects = $self->{ state } ? $self->{ state }->effects : undef;

    unless ( $effects && $effects->{ $name } )
    {
        $self->popdown;
        return;
    }

    $self->_build;

    return;
}

=head2 set_enabled( $on )

Move the switch to match the row's checkbox without writing back to state.

=cut

sub set_enabled
{
    my ( $self, $on ) = @_;

    my $switch = $self->{ switch } or return;

    $self->{ loading }++;
    $switch->set_active( $on ? 1 : 0 );
    $self->{ loading }--;

    return;
}

# Header and body together: the header names an effect, so it is rebuilt with
# the body rather than updated in place.
sub _build
{
    my ( $self ) = @_;

    my $name = $self->{ effect };
    my $spec = GlitchVape::Registry->get( $name ) or return;

    $_->destroy for $self->{ header }->get_children;
    $_->destroy for $self->{ body }->get_children;

    # Destroyed with the grid they were in, so the map has to go with them:
    # kept, it would be a list of widgets to grey out that no longer exist.
    $self->{ controls } = {};

    $self->{ header }->pack_start( $self->_titles( $name, $spec ), 1, 1, 0 );
    $self->{ header }->pack_start( $self->_switch( $name, $spec ), 0, 0, 0 );

    $self->{ body }->pack_start( $self->_params( $name, $spec ), 0, 0, 0 );

    # The whole tree, not just the two boxes that were rebuilt: popup() shows
    # the popover and nothing inside it, so the scroller and the separator
    # between them would never be realised and the popover would open empty.
    $self->{ box }->show_all;

    return;
}

sub _titles
{
    my ( $self, $name, $spec ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 2 );

    # A popover has no title bar to put this in, which is rather the point:
    # what it belongs to is said here and pointed at by the arrow.
    my $title = Gtk3::Label->new;
    $title->set_markup(
        '<b>' . Glib::Markup::escape_text( $spec->{ title } ) . '</b>' );
    $title->set_xalign( 0 );

    my $summary = Gtk3::Label->new( $spec->{ summary } );
    $summary->set_xalign( 0 );
    $summary->set_line_wrap( 1 );
    $summary->set_max_width_chars( 34 );
    $summary->get_style_context->add_class( 'dim-label' );

    # The internal name, because that is what a preset, --set and the copied
    # command line all call this effect -- the same pairing the row shows.
    my $key = Gtk3::Label->new;
    $key->set_markup( "<span alpha='45%'><tt>"
            . Glib::Markup::escape_text( $name )
            . '</tt></span>' );
    $key->set_xalign( 0 );

    $box->pack_start( $title,   0, 0, 0 );
    $box->pack_start( $summary, 0, 0, 0 );
    $box->pack_start( $key,     0, 0, 0 );

    return $box;
}

sub _switch
{
    my ( $self, $name, $spec ) = @_;

    my $switch = Gtk3::Switch->new;
    $switch->set_valign( 'start' );
    $switch->set_active( $self->{ state }->enabled( $name ) ? 1 : 0 );
    $switch->set_tooltip_text( "Include $spec->{title} in the pipeline" );
    $switch->signal_connect(
        'notify::active' => sub {
            return if $self->{ loading };

            my $on = $switch->get_active ? 1 : 0;
            $self->{ state }->enabled( $name, $on );
            $self->{ on_enabled }->( $name, $on ) if $self->{ on_enabled };
            return;
        }
    );

    $self->{ switch } = $switch;

    return $switch;
}

# Built rather than updated in place, because GlitchVape::GUI::Params hands
# back a control and a way to hear about changes, not a way to set one -- and a
# setter per widget kind is a second switch on type that the whole design of
# that module exists to avoid.
sub _params
{
    my ( $self, $name, $spec ) = @_;

    my $params = $spec->{ params };

    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 6 );
    $grid->set_column_spacing( 12 );

    unless ( %$params )
    {
        my $none = Gtk3::Label->new( 'This effect takes no parameters.' );
        $none->set_xalign( 0 );
        $none->get_style_context->add_class( 'dim-label' );
        $grid->attach( $none, 0, 0, 2, 1 );

        return $grid;
    }

    my ( $ordinary, $animation ) = GlitchVape::GUI::Params::split( $params );

    my $row = 0;
    for my $key ( @$ordinary, @$animation )
    {
        # Everything that only means something in a loop goes below the rest,
        # under a line saying so. Mixed in, a drift of zero reads as a control
        # that does nothing -- which is true of the still on screen and false
        # of the effect, and there is no way to tell those apart from a row in
        # a grid.
        if ( @$animation && $key eq $animation->[ 0 ] )
        {
            # Only if there is something above it to separate. An effect
            # that is entirely about motion -- flicker is one -- would
            # otherwise open with a rule across an empty space.
            if ( @$ordinary )
            {
                $grid->attach( Gtk3::Separator->new( 'horizontal' ),
                    0, $row, 2, 1 );
                $row++;
            }

            my $heading = Gtk3::Label->new( 'Only in an animation' );
            $heading->set_xalign( 0 );
            $heading->get_style_context->add_class( 'dim-label' );
            $grid->attach( $heading, 0, $row, 2, 1 );
            $row++;
        }

        my $built = GlitchVape::GUI::Params->build(
            effect    => $name,
            name      => $key,
            spec      => $params->{ $key },
            value     => $self->{ state }->param( $name, $key ),
            on_change => sub {
                return if $self->{ loading };
                $self->_set_param( $key, $_[ 0 ] );
                return;
            },
        );

        # A width on everything stretches the switches into levers; the flag
        # is what says which controls a width actually helps. Asked for rather
        # than expanded into, because a popover sizes itself to its contents
        # and hexpand in one would simply make it wider than it needs to be.
        if ( $built->{ stretch } )
        {
            $built->{ control }->set_size_request( 200, -1 );
        }
        else
        {
            $built->{ control }->set_halign( 'start' );
        }

        $self->{ controls }{ $key } = $built;

        $grid->attach( $built->{ label },   0, $row, 1, 1 );
        $grid->attach( $built->{ control }, 1, $row, 1, 1 );
        $row++;
    }

    $self->_sync_needs;

    return $grid;
}

# A control whose declared needs are not met is greyed rather than left
# looking usable. Done for the whole effect on every change rather than
# wiring each dependency to its dependants: one parameter can gate several
# and be gated itself -- osd.reroll needs the timestamp on and the timestamp
# invented -- so the cheap complete answer beats a graph of signals.
sub _sync_needs
{
    my ( $self ) = @_;

    my $name = $self->{ effect }                  or return;
    my $spec = GlitchVape::Registry->get( $name ) or return;

    my %values =
        map { $_ => $self->{ state }->param( $name, $_ ) }
        keys %{ $spec->{ params } };

    GlitchVape::GUI::Params::apply_needs( $spec->{ params },
        $self->{ controls }, \%values );

    return;
}

sub _set_param
{
    my ( $self, $key, $value ) = @_;

    my $name = $self->{ effect } or return;

    local $@;

    # A half-typed value -- '#FF' on the way to '#FF00AA' -- fails the
    # registry's validation, and that is not an error worth interrupting
    # anybody over. It just means this keystroke is not a value yet.
    my $ok = eval {
        $self->{ state }->param( $name, $key, $value );
        1;
    };
    return unless $ok;

    # Before the render, not after: the switch that was just moved may have
    # decided whether the four controls under it mean anything.
    $self->_sync_needs;

    $self->{ on_change }->() if $self->{ on_change };
    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Params> for how one parameter becomes one control, and
L<GlitchVape::GUI::Wizard> for the other place those same controls are built.

=cut
