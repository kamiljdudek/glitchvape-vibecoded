package GlitchVape::GUI::Adjust;

use strict;
use warnings;
use utf8;

use Gtk3 ();

use GlitchVape::Registry    ();
use GlitchVape::GUI::Params ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Adjust - one effect's settings, in a window of its own

=head1 DESCRIPTION

The effect list says what is in the pipeline; this says what one member of it
is set to. One window per effect, opened by double-clicking its row or by the
Adjust button, and closed when the effect leaves the pipeline.

=head1 WHY IT IS NOT MODAL

The settings that matter are the ones you can see against the picture, and a
modal window is a window you cannot look past. Worse, comparing two effects --
how much C<chroma_shift> to answer this much C<scanlines> with -- means having
both sets of controls at once, which a modal dialog forbids by construction.

So these are plain toplevels: several may be open, the main window stays
usable behind them, and Apply can be pressed without closing any of them.
C<transient_for> is still set, because they belong to that window and should
stay above it and travel with it between workspaces -- that is what transience
means, and it is separate from modality.

The cost is that they can outlive what they describe. Removing an effect
therefore closes its window (see L</close>), and anything that replaces the
whole configuration -- a preset, an undo -- calls L</refresh> so the controls
show what the state now holds rather than what it held when they were built.

=head1 THE SWITCH AND THE CHECKBOX ARE ONE FACT

Whether an effect is in the render is shown twice: as a checkbox on its row
and as a switch at the top of this window. Both write the same state, and
each is told when the other has moved, guarded so that being told does not
count as being set -- otherwise the two would answer each other forever.

=cut

=head2 new( %arg )

    parent     => Gtk3::Window
    name       => effect name
    state      => GlitchVape::GUI::State
    on_change  => sub { }              a parameter moved
    on_enabled => sub { my ( $on ) = @_ }
    on_closed  => sub { my ( $name ) = @_ }

Builds the window and shows it.

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $name = $arg{ name };
    my $spec = GlitchVape::Registry->get( $name )
        or die "GlitchVape: no such effect '$name'\n";

    my $self = bless {
        name       => $name,
        spec       => $spec,
        state      => $arg{ state },
        on_change  => $arg{ on_change },
        on_enabled => $arg{ on_enabled },
        on_closed  => $arg{ on_closed },
        loading    => 0,
    }, $class;

    my $window = Gtk3::Window->new( 'toplevel' );
    $window->set_title( $spec->{ title } );
    $window->set_transient_for( $arg{ parent } ) if $arg{ parent };
    $window->set_destroy_with_parent( 1 );
    $window->set_type_hint( 'dialog' );

    # Deliberately not set_modal: see L</WHY IT IS NOT MODAL>.

    $window->set_default_size( 380, -1 );
    $window->set_resizable( 1 );

    $window->signal_connect(
        destroy => sub {
            $self->{ window } = undef;
            my $closed = $self->{ on_closed };
            $closed->( $self->{ name } ) if $closed;
            return;
        }
    );

    # Escape closes it, which is what every other settings window on the desk
    # does. A non-modal window gets no such handling for free.
    $window->signal_connect(
        'key-press-event' => sub {
            my ( undef, $event ) = @_;
            return 0 unless $event->keyval == Gtk3::Gdk::KEY_Escape();
            $self->close;
            return 1;
        }
    );

    $self->{ window } = $window;

    my $outer = Gtk3::Box->new( 'vertical', 12 );
    $outer->set_border_width( 14 );

    $outer->pack_start( $self->_build_header,                 0, 0, 0 );
    $outer->pack_start( Gtk3::Separator->new( 'horizontal' ), 0, 0, 0 );

    # The parameters go in a scroller because an effect is free to declare as
    # many as it likes -- osd declares nine -- and a window taller than the
    # screen cannot be closed with the pointer.
    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );
    $scroll->set_vexpand( 1 );
    $scroll->set_propagate_natural_height( 1 );

    $self->{ body } = Gtk3::Box->new( 'vertical', 0 );
    $scroll->add( $self->{ body } );
    $outer->pack_start( $scroll, 1, 1, 0 );

    $self->_build_params;

    $window->add( $outer );
    $window->show_all;

    return $self;
}

=head2 name()

The effect this window belongs to.

=cut

sub name { $_[ 0 ]{ name } }

=head2 window()

The toplevel, or undef once it has been destroyed.

=cut

sub window { $_[ 0 ]{ window } }

=head2 present()

Raise an already-open window rather than opening a second one for the same
effect.

=cut

sub present
{
    my ( $self ) = @_;
    $self->{ window }->present if $self->{ window };
    return;
}

=head2 close()

Destroy the window. Called when the effect it describes is removed, which is
the case this exists for: a settings window for something no longer in the
pipeline would write to state that is not there.

=cut

# 'close' is on ProhibitAmbiguousNames' list because it is also an adjective.
# On a window object it is a verb and nothing else, and every other name for
# this -- dismiss, dispose -- is worse at saying what happens.
sub close    ## no critic (NamingConventions::ProhibitAmbiguousNames)
{
    my ( $self ) = @_;
    my $window = $self->{ window } or return;

    # Cleared first so the destroy handler does not report a closure the
    # caller asked for as one the user performed.
    $self->{ window }    = undef;
    $self->{ on_closed } = undef;
    $window->destroy;

    return;
}

=head2 set_enabled( $on )

Move the switch to match the row's checkbox without writing back to state.

=cut

sub set_enabled
{
    my ( $self, $on ) = @_;
    return unless $self->{ switch };

    $self->{ loading }++;
    $self->{ switch }->set_active( $on ? 1 : 0 );
    $self->{ loading }--;

    return;
}

=head2 refresh()

Rebuild the controls from the state. Undo, redo and loading a preset all
replace the whole configuration, so a window built against the old one is
showing values that are no longer set.

=cut

sub refresh
{
    my ( $self ) = @_;
    return unless $self->{ window };

    $self->set_enabled( $self->{ state }->enabled( $self->{ name } ) );
    $self->_build_params;

    return;
}

sub _build_header
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'horizontal', 12 );

    my $text = Gtk3::Box->new( 'vertical', 2 );

    my $summary = Gtk3::Label->new( $self->{ spec }{ summary } );
    $summary->set_xalign( 0 );
    $summary->set_line_wrap( 1 );
    $summary->set_max_width_chars( 40 );
    $summary->get_style_context->add_class( 'dim-label' );

    # The internal name, because that is what a preset, --set and the copied
    # command line all call this effect -- the same pairing the row shows.
    my $key = Gtk3::Label->new;
    $key->set_markup( "<span alpha='45%'><tt>"
            . Glib::Markup::escape_text( $self->{ name } )
            . '</tt></span>' );
    $key->set_xalign( 0 );

    $text->pack_start( $summary, 0, 0, 0 );
    $text->pack_start( $key,     0, 0, 0 );

    my $switch = Gtk3::Switch->new;
    $switch->set_valign( 'center' );
    $switch->set_active( $self->{ state }->enabled( $self->{ name } ) ? 1 : 0 );
    $switch->set_tooltip_text( "Include $self->{spec}{title} in the pipeline" );
    $switch->signal_connect(
        'notify::active' => sub {
            return if $self->{ loading };

            my $on = $switch->get_active ? 1 : 0;
            $self->{ state }->enabled( $self->{ name }, $on );
            $self->{ on_enabled }->( $on ) if $self->{ on_enabled };
            return;
        }
    );

    $self->{ switch } = $switch;

    $box->pack_start( $text,   1, 1, 0 );
    $box->pack_start( $switch, 0, 0, 0 );

    return $box;
}

# Built rather than updated in place, because GlitchVape::GUI::Params hands
# back a control and a way to hear about changes, not a way to set one -- and
# a setter per widget kind is a second switch on type that the whole design of
# that module exists to avoid.
sub _build_params
{
    my ( $self ) = @_;

    $_->destroy for $self->{ body }->get_children;

    my $params = $self->{ spec }{ params };

    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 6 );
    $grid->set_column_spacing( 12 );

    unless ( %$params )
    {
        my $none = Gtk3::Label->new( 'This effect takes no parameters.' );
        $none->set_xalign( 0 );
        $none->get_style_context->add_class( 'dim-label' );
        $grid->attach( $none, 0, 0, 2, 1 );
    }

    my $row = 0;
    for my $key ( sort keys %$params )
    {
        my $built = GlitchVape::GUI::Params->build(
            effect    => $self->{ name },
            name      => $key,
            spec      => $params->{ $key },
            value     => $self->{ state }->param( $self->{ name }, $key ),
            on_change => sub {
                return if $self->{ loading };
                $self->_set_param( $key, $_[ 0 ] );
                return;
            },
        );

        # A width on everything stretches the switches into levers; the flag
        # is what says which controls a width actually helps.
        if ( $built->{ stretch } )
        {
            $built->{ control }->set_hexpand( 1 );
        }
        else
        {
            $built->{ control }->set_halign( 'start' );
        }

        $grid->attach( $built->{ label },   0, $row, 1, 1 );
        $grid->attach( $built->{ control }, 1, $row, 1, 1 );
        $row++;
    }

    $self->{ body }->pack_start( $grid, 0, 0, 0 );
    $self->{ body }->show_all;

    return;
}

sub _set_param
{
    my ( $self, $key, $value ) = @_;

    local $@;

    # A half-typed value -- '#FF' on the way to '#FF00AA' -- fails the
    # registry's validation, and that is not an error worth interrupting
    # anybody over. It just means this keystroke is not a value yet.
    my $ok = eval {
        $self->{ state }->param( $self->{ name }, $key, $value );
        1;
    };
    return unless $ok;

    $self->{ on_change }->() if $self->{ on_change };
    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Params> for how one parameter becomes one control, and
L<GlitchVape::GUI::Wizard> for the other place those same controls are built.

=cut
