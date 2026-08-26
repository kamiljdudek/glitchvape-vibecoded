package GlitchVape::GUI;

use strict;
use warnings;

# This file contains literal '…' and '·' in button and status text. Without
# this the source bytes are read as Latin-1, and Glib -- which encodes Perl
# strings to UTF-8 on the way into Gtk -- would encode them a second time,
# putting mojibake on the buttons. The same reason bin/glitchvape does it.
use utf8;

use File::Basename qw(basename);
use File::Spec     ();

use Glib ();
use Gtk3 ();

use GlitchVape                   ();
use GlitchVape::Audio            ();
use GlitchVape::Config           ();
use GlitchVape::Fonts            ();
use GlitchVape::Generator        ();
use GlitchVape::IO               ();
use GlitchVape::Registry         ();
use GlitchVape::Tools            ();
use GlitchVape::GUI::About       ();
use GlitchVape::GUI::Adjust      ();
use GlitchVape::GUI::Audio       ();
use GlitchVape::GUI::CommandLine ();
use GlitchVape::GUI::Cache       ();
use GlitchVape::GUI::Export      ();
use GlitchVape::GUI::Generated   ();
use GlitchVape::GUI::Params      ();
use GlitchVape::GUI::Preview     ();
use GlitchVape::GUI::Render      ();
use GlitchVape::GUI::State       ();
use GlitchVape::GUI::Wizard      ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI - a Gtk3 window over the effect pipeline

=head1 SYNOPSIS

    glitchvape-gui                       # open empty
    glitchvape-gui photo.heic            # open a file
    glitchvape-gui -p vhs-decay photo.heic

=head1 DESCRIPTION

Presets and their parameters on the left, the render on the right, an explicit
Apply between them. Nothing here reimplements an effect: the left pane is
generated from L<GlitchVape::Registry>'s declarations, and Export goes through
L<GlitchVape/render>, the same entry point F<bin/glitchvape> uses.

=head2 Why Apply is a button

A render is one to eight seconds depending on size, so there is no live
preview to be had. Making the moment of rendering explicit also gives undo
something to be a step of: one Apply is one entry in the history, rather than
fifty near-identical entries from dragging a slider.

=head2 Preview fidelity

Previews render at a reduced size, chosen in the toolbar. Effects are
pixel-scale dependent -- C<grain>, C<scanlines> and C<dither> all work in
pixels rather than fractions of the frame -- so a small preview is an
impression of the render, not a crop of it.

Export renders at the size the export settings ask for, which is the preset's
own full size unless somebody has said otherwise -- see
L<GlitchVape::GUI::Export>. The preview size is never that size: it is a
property of the window, and changing it changes nothing about the file.

=head2 What an export is, is settings

Where it goes is asked in a file chooser, at the moment of exporting. What it
is -- format, size, frame rate, palette -- is set once in a dialog behind the
menu and then left, because those are the answers that stay the same across a
session's worth of renders while the filename does not.

Both halves are held here, in C<< $self->{ export } >>, and both reach the
render through L<GlitchVape::GUI::Export/render_options> rather than being
assembled twice: the export and the command line equivalent are built from
the same hash, so they cannot come to disagree about what would be written.

=head2 The left pane is two lists

Effects and soundtrack are both answers to "what goes into this render", so
they are two pages of one C<Gtk3::Stack> under a switcher rather than one list
with a second bolted on beneath it.

They share the action bar at the foot. Apply renders whatever both of them
say, and Add adds to whichever one is showing -- the effect assistant from the
Image page, a popover of track kinds from the Soundtrack page. Adjust belongs
to the effect list alone, so switching page drops the effect selection and
Adjust goes back to waiting for one.

=head2 Where an effect's parameters are

Not in the list. A row says whether an effect is in the render, what it is
called, and offers to take it out again; its parameters open in a window of
their own -- see L<GlitchVape::GUI::Adjust>.

That keeps the list as short as the pipeline is long rather than as tall as
the settings of everything in it, and it lets two effects' controls be held
against the picture at once -- deciding how much C<chroma_shift> answers this
much C<scanlines> means seeing both.

Whether an effect is enabled is therefore shown twice -- a checkbox on the
row, a switch in the window -- and the two are kept in step.

=head2 The soundtrack page

The second page of the left pane builds a soundtrack. There is one cropped
file at most, through L<GlitchVape::GUI::Audio>, and any number of generated
tracks through L<GlitchVape::GUI::Generated> -- static under a dialled phrase
under a piece of music is an ordinary thing to want. Each gets its own line
with its own remove, so dropping one leaves the rest alone; the Add button's
popover stops offering the file once there is one, which is the only place
that asymmetry shows.

A soundtrack only means anything for an animation, but that is now said rather
than enacted: with Animate off the page explains what it is waiting for
instead of disappearing, because a tab that vanishes teaches nobody what it
was for. Nothing is discarded when Animate goes off -- the page covers the mix
rather than clearing it -- so going back to a still to check one frame does
not cost the tracks already assembled.

The resulting spec lives here rather than in
L<GlitchVape::GUI::State>, alongside C<frames> and C<fps> and for the same
reason: it is a property of this render rather than part of the configuration
being edited, so it is not an undo step and is not written into a saved
preset. A preset is a look, and a look does not include a path to a file of
music on this machine.

It does reach L<GlitchVape::GUI::State/cache_key>, because it changes the
encoded preview even though it changes no frame.

=cut

# Longest edge for a preview, and roughly what each costs on a 12-megapixel
# photograph. 'Full' resolves to the preset's own max_dim at render time.
# Apply runs the pipeline and Stop interrupts it, so the button carries the
# transport pair rather than a tick: what it does is start something that
# takes time, and the icon that means "stop" is only obvious next to the icon
# that means "start".
use constant {
    APPLY_ICON => 'media-playback-start-symbolic',
    STOP_ICON  => 'media-playback-stop-symbolic',
};

# Room for the icon, the gap after it and the button's padding, added to the
# width of the widest word the button can show. A constant because all three
# are constant: only the word changes.
use constant APPLY_EXTRA => 46;

my @PREVIEW_SIZES = (
    [ 512, 'Fast (512 px)' ],
    [ 720, 'Balanced (720 px)' ],
    [ 900, 'Detailed (900 px)' ],
    [ 0,   'Full size' ],
);

=head2 new( %arg )

    input   => path        file to open at startup
    preset  => name        preset to select at startup
    seed    => scalar

=cut

# Gtk3::Button::new_from_icon_name reaches GTK through introspection, which
# wants the icon size as the integer of the enum rather than its nickname.
# Building the image separately keeps the readable form.
sub _icon_button
{
    my ( $icon, $tooltip ) = @_;

    my $button = Gtk3::Button->new;
    $button->set_image( Gtk3::Image->new_from_icon_name( $icon, 'button' ) );
    $button->set_tooltip_text( $tooltip ) if defined $tooltip;

    return $button;
}

# An icon beside a word. Only Apply is dressed this way now -- the other three
# buttons in the bar are icon-only, and the bar did not have room for four
# labels -- but Apply needs both halves and needs to swap them together, which
# is what this exists for.
#
# The child is built by hand rather than with set_image plus
# set_always_show_image, because set_label on such a button rebuilds the child
# and drops the image -- and Apply changes its label every time a render
# starts. Owning the box means the icon and the word can be swapped together.
sub _action_button
{
    my ( $icon, $label, $tooltip ) = @_;

    return _dress_button( Gtk3::Button->new, $icon, $label, $tooltip );
}

# The same for a button that already exists, which is how a Gtk3::ToggleButton
# gets one: the two classes differ in what pressing them means and not at all
# in what they look like.
sub _dress_button
{
    my ( $button, $icon, $label, $tooltip ) = @_;

    $button->set_tooltip_text( $tooltip ) if defined $tooltip;

    my $image = Gtk3::Image->new_from_icon_name( $icon, 'button' );

    my $text = Gtk3::Label->new_with_mnemonic( $label );
    $text->set_mnemonic_widget( $button );

    my $box = Gtk3::Box->new( 'horizontal', 6 );
    $box->set_halign( 'center' );
    $box->pack_start( $image, 0, 0, 0 );
    $box->pack_start( $text,  0, 0, 0 );

    $button->add( $box );

    return ( $button, $image, $text );
}

sub new
{
    my ( $class, %arg ) = @_;

    my $cache = GlitchVape::GUI::Cache->new;
    $cache->install_signal_handlers;

    my $self = bless {
        cache  => $cache,
        render => GlitchVape::GUI::Render->new( cache => $cache ),
        state  => undef,
        rows   => {},

        # Open settings windows, keyed by the effect each describes. Keyed
        # rather than listed because the question asked of it is always "is
        # this one already open?" -- see _adjust_effect.
        adjust       => {},
        loading      => 0,
        preview_size => 720,
        animate      => 0,
        frames       => 24,
        fps          => 12,
        audio        => undef,
        muted        => 0,
        export       => GlitchVape::GUI::Export::defaults(),
    }, $class;

    # The frame rate belongs to both dialogs -- see
    # GlitchVape::GUI::Export/Frame rate is one setting, shown twice -- and
    # this is the copy either of them edits.
    $self->{ fps } = $self->{ export }{ fps };

    $self->_build_window;

    if ( $arg{ input } )
    {
        $self->_open_file(
            $arg{ input },
            preset => $arg{ preset },
            seed   => $arg{ seed }
        );
    }

    return $self;
}

=head2 run()

Show the window and enter the main loop. Returns when the window is closed.

=cut

sub run
{
    my ( $self ) = @_;

    $self->{ window }->show_all;
    $self->_sync_actions;

    Gtk3->main;

    $self->{ preview }->stop_video;
    $self->{ render }->cancel if $self->{ render }->busy;
    $self->{ cache }->cleanup;

    return 0;
}

# ---------------------------------------------------------------------------
# Window construction

sub _build_window
{
    my ( $self ) = @_;

    my $win = Gtk3::Window->new( 'toplevel' );
    $win->set_default_size( 1180, 760 );
    $win->set_titlebar( $self->_build_header );

    $win->signal_connect(
        destroy => sub {
            Gtk3->main_quit;
            return;
        }
    );

    my $paned = Gtk3::Paned->new( 'horizontal' );
    $paned->set_position( 380 );
    $paned->pack1( $self->_build_left, 0, 0 );
    $paned->pack2( $self->_build_right, 1, 0 );

    $win->add( $paned );

    $self->{ window } = $win;

    # After the panes, because it presses buttons the panes build.
    $self->_install_accelerators;

    return;
}

sub _build_header
{
    my ( $self ) = @_;

    my $bar = Gtk3::HeaderBar->new;
    $bar->set_show_close_button( 1 );
    $bar->set_title( 'GlitchVape' );
    $bar->set_subtitle( 'no image open' );

    my $open = Gtk3::Button->new_with_mnemonic( '_Open' );
    $open->signal_connect(
        clicked => sub {
            $self->_choose_input;
            return;
        }
    );
    $bar->pack_start( $open );

    # Undo and redo as a linked pair, which is how every other Gtk
    # application presents them.
    my $history = Gtk3::Box->new( 'horizontal', 0 );
    $history->get_style_context->add_class( 'linked' );

    my $undo = _icon_button( 'edit-undo-symbolic', 'Undo the last Apply' );
    $undo->signal_connect(
        clicked => sub {
            $self->_step_history( 'undo' );
            return;
        }
    );

    my $redo = _icon_button( 'edit-redo-symbolic', 'Redo' );
    $redo->signal_connect(
        clicked => sub {
            $self->_step_history( 'redo' );
            return;
        }
    );

    $history->pack_start( $undo, 0, 0, 0 );
    $history->pack_start( $redo, 0, 0, 0 );
    $bar->pack_start( $history );

    my $export = Gtk3::Button->new_with_mnemonic( '_Export…' );
    $export->get_style_context->add_class( 'suggested-action' );
    $export->set_tooltip_text( 'Render at full size and save' );
    $export->signal_connect(
        clicked => sub {
            $self->_choose_output;
            return;
        }
    );
    $bar->pack_end( $export );
    $bar->pack_end( $self->_build_menu );

    $self->{ header }   = $bar;
    $self->{ b_undo }   = $undo;
    $self->{ b_redo }   = $redo;
    $self->{ b_export } = $export;

    return $bar;
}

# The primary menu, where the platform puts one: at the end of the header bar,
# holding what is done rarely enough not to earn a button of its own. Nothing
# in it is on a hot path -- saving a preset, reading a report, emptying a
# cache -- which is the test for whether something belongs behind a hamburger
# rather than in front of one.
sub _build_menu
{
    my ( $self ) = @_;

    my $button = Gtk3::MenuButton->new;
    $button->set_image(
        Gtk3::Image->new_from_icon_name( 'open-menu-symbolic', 'button' ) );
    $button->set_tooltip_text( 'Menu' );

    my $menu = Gtk3::Menu->new;

    for my $item (
        [ 'Randomize',         sub { return $self->_randomize },     'seed' ],
        [ 'Clear all effects', sub { return $self->_clear_effects }, 'clear' ],
        [ 'Animation settings…', sub { return $self->_animation_settings } ],
        [ 'Export settings…',    sub { return $self->_export_settings } ],
        undef,
        [ 'Save as preset…', sub { return $self->_save_preset }, 'preset' ],
        [
            'Copy command line…', sub { return $self->_copy_command },
            'command'
        ],
        undef,
        [ 'Check dependencies…', sub { return $self->_show_deps } ],
        [ 'Clear preview cache', sub { return $self->_clear_cache } ],
        undef,
        [ 'About GlitchVape', sub { return $self->_show_about } ],
        )
    {
        unless ( $item )
        {
            $menu->append( Gtk3::SeparatorMenuItem->new );
            next;
        }

        my ( $label, $action, $key ) = @$item;

        my $entry = Gtk3::MenuItem->new_with_label( $label );
        $entry->signal_connect(
            activate => sub {
                $action->();
                return;
            }
        );

        $menu->append( $entry );

        # The ones that need an image open are remembered so that
        # _sync_actions can grey them; the rest are always available.
        $self->{ "m_$key" } = $entry if $key;
    }

    $menu->show_all;
    $button->set_popup( $menu );

    $self->{ b_menu } = $button;

    return $button;
}

# The left pane holds two lists that are both answers to "what goes into the
# render": the effects, and the soundtrack. They are the same kind of thing at
# the same level, so they are two pages of one Gtk3::Stack rather than one
# list with a second bolted underneath it -- and both halves of one pipeline
# stay on one side of the window.
sub _build_left
{
    my ( $self ) = @_;

    my $outer = Gtk3::Box->new( 'vertical', 0 );

    my $stack = Gtk3::Stack->new;
    $stack->set_transition_type( 'slide-left-right' );
    $stack->set_transition_duration( 150 );

    $stack->add_titled( $self->_build_image_page, 'image', 'Image' );
    $stack->add_titled( $self->_build_soundtrack_page,
        'soundtrack', 'Soundtrack' );

    my $switcher = Gtk3::StackSwitcher->new;
    $switcher->set_stack( $stack );
    $switcher->set_halign( 'center' );
    $switcher->set_margin_top( 8 );
    $switcher->set_margin_bottom( 8 );

    # Switching page drops the effect selection. The Adjust button acts on it
    # and only the Image page has one to act on, so a selection kept across
    # the switch would be a button pointing at something not on screen -- and
    # coming back to find a row still highlighted from several minutes ago
    # invites adjusting the wrong effect.
    $stack->signal_connect(
        'notify::visible-child-name' => sub {
            $self->{ effect_list }->unselect_all;
            $self->_sync_actions;
            return;
        }
    );

    $self->{ left_stack }    = $stack;
    $self->{ left_switcher } = $switcher;

    $outer->pack_start( $switcher,                            0, 0, 0 );
    $outer->pack_start( Gtk3::Separator->new( 'horizontal' ), 0, 0, 0 );
    $outer->pack_start( $stack,                               1, 1, 0 );
    $outer->pack_start( $self->_build_left_actions,           0, 0, 0 );

    return $outer;
}

# The effects in the pipeline, which is what Apply renders.
sub _build_image_page
{
    my ( $self ) = @_;

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );
    $scroll->set_vexpand( 1 );

    my $box = Gtk3::Box->new( 'vertical', 12 );
    $box->set_border_width( 12 );

    my $heading = Gtk3::Label->new;
    $heading->set_markup( '<b>Effects</b>' );
    $heading->set_xalign( 0 );
    $box->pack_start( $heading, 0, 0, 0 );

    # A GtkListBox, so that one effect is *selected* -- which is what the
    # Adjust button needs and what a column of hand-packed boxes could not
    # express. Rows carry a checkbox and a remove button and nothing else; the
    # parameters moved out to GlitchVape::GUI::Adjust, where several effects'
    # worth can be open at once and compared.
    my $list = Gtk3::ListBox->new;
    $list->set_selection_mode( 'single' );

    # Single-click activation would mean browsing the list opened a window per
    # row passed over. Double-click and Enter activate instead, which is also
    # what a file manager does with the same widget.
    $list->set_activate_on_single_click( 0 );

    $list->signal_connect(
        'row-activated' => sub {
            my ( undef, $row ) = @_;
            $self->_adjust_effect( $row->{ effect } ) if $row;
            return;
        }
    );

    $list->signal_connect(
        'row-selected' => sub {
            $self->_sync_actions;
            return;
        }
    );

    $self->{ effect_list } = $list;
    $box->pack_start( $list, 0, 0, 0 );

    $scroll->add( $box );

    return $scroll;
}

# The actions belonging to the pipeline above, in a Gtk3::ActionBar.
#
# An action bar rather than a box of buttons because that is what it is: the
# platform's container for the actions belonging to the view above it, with
# the separator, the padding and the start/end split already decided. Every
# button in it is outside the scrolled list, so a long pipeline cannot push
# one of them off the screen.
#
# Four buttons, and only Apply keeps its word. Four labels do not fit the
# pane at its usable width, and of the four it is Apply whose label has to
# stay: it is the one with a bill attached, it is the one that changes to
# Stop, and a row where exactly one button is labelled says which button
# matters more clearly than a row where all four are. The other three are the
# standard plus, cog and camera, and each carries a tooltip.
#
# A button with no label claims no mnemonic, so the keys are put back on an
# accelerator group -- see _install_accelerators.
#
# Apply keeps its accent colour. A GtkActionBar imposes nothing on the buttons
# inside it -- it is a container, not a style -- so suggested-action works
# there exactly as it did before, and the one destination action stays
# distinguishable from the ones that open a window.
sub _build_left_actions
{
    my ( $self ) = @_;

    my $bar = Gtk3::ActionBar->new;

    # What it adds depends on which page is showing -- see
    # _add_to_current_page. The tooltip is rewritten to match by
    # _sync_actions, because a button whose meaning changes has to say so.
    my $add = _icon_button( 'list-add-symbolic' );
    $add->signal_connect(
        clicked => sub {
            $self->_add_to_current_page;
            return;
        }
    );
    $bar->pack_start( $add );

    # Opens the settings for whichever effect is selected. Insensitive with
    # no selection rather than hidden, because it is the button that explains
    # what selecting a row is for.
    my $adjust = _icon_button( 'preferences-system-symbolic',
              "Open the settings for the selected effect (Alt+J).\n"
            . 'Double-clicking its row does the same' );
    $adjust->signal_connect(
        clicked => sub {
            $self->_adjust_selected;
            return;
        }
    );
    $bar->pack_start( $adjust );

    my ( $apply, $apply_icon, $apply_label ) = _action_button(
        APPLY_ICON,
        '_Apply',
        'Render the pipeline and show the result. '
            . 'Nothing on the left takes effect until this is pressed'
    );
    $apply->get_style_context->add_class( 'suggested-action' );
    $apply->signal_connect(
        clicked => sub {
            $self->_apply;
            return;
        }
    );

    # The button reads Apply or Stop depending on what is happening, and the
    # two words are not the same width. Pin it to the wider of the two,
    # measured rather than guessed so a theme with a different font does not
    # reintroduce the problem.
    $apply->set_size_request( _widest_label( $apply_label, '_Apply', '_Stop' ),
        -1 );

    # Whether to render a loop instead of a still. A toggle rather than a
    # checkbox because it is a mode the window is in and stays in, and a
    # pressed button says that at a glance from across the room in a way a
    # tick in a box does not.
    #
    # Beside Apply, and that is the point of where it is. It does not change
    # how the result is displayed; it changes what Apply *does* -- twenty-four
    # renders instead of one -- and what Export then writes. Among the preview
    # controls it read as another free adjustment like zoom, and the cost was
    # discoverable only by hovering.
    my $animate = Gtk3::ToggleButton->new;
    $animate->set_image(
        Gtk3::Image->new_from_icon_name( 'camera-video-symbolic', 'button' ) );
    $animate->set_tooltip_text(
              "Render a looping animation instead of a still (Alt+N).\n"
            . 'Costs one render per frame, and unlocks the Soundtrack page' );
    $animate->signal_connect(
        toggled => sub {
            $self->{ animate } = $animate->get_active;
            $self->_sync_actions;
            return;
        }
    );

    # pack_end fills from the right, so these go in reverse of how they read:
    # Apply at the end, and the toggle that decides what pressing it will cost
    # before it. The spinner belonging to Apply is over the picture rather
    # than in this bar -- see _build_preview_overlay.
    $bar->pack_end( $apply );
    $bar->pack_end( $animate );

    $self->{ b_animate }   = $animate;
    $self->{ b_add }       = $add;
    $self->{ b_adjust }    = $adjust;
    $self->{ b_apply }     = $apply;
    $self->{ apply_icon }  = $apply_icon;
    $self->{ apply_label } = $apply_label;

    return $bar;
}

# The keys the three icon-only buttons would have carried as labels.
#
# Alt+D for Add and Alt+N for Animate are the keys those buttons already had;
# Alt+J is new, for Adjust, and is neither Alt+A (Apply, since there was a
# window) nor Alt+E (Export, in the header bar). An accelerator is invisible,
# so each one is named in the tooltip of the button it presses -- otherwise
# the keys would exist and nobody would know.
sub _install_accelerators
{
    my ( $self ) = @_;

    my $accel = Gtk3::AccelGroup->new;

    my %key = (
        d => $self->{ b_add },
        j => $self->{ b_adjust },
        n => $self->{ b_animate },
    );

    for my $letter ( sort keys %key )
    {
        my $button = $key{ $letter };

        # activate rather than clicked: a GtkToggleButton flips on activate,
        # which is what Animate needs, and an ordinary button treats the two
        # the same. An insensitive button ignores it either way, so Adjust
        # with nothing selected does nothing rather than failing.
        $accel->connect(
            Gtk3::Gdk::keyval_from_name( $letter ),
            'mod1-mask',
            'visible',
            sub {
                $button->activate;
                return 1;
            }
        );
    }

    $self->{ window }->add_accel_group( $accel );
    $self->{ accel } = $accel;

    return;
}

# Natural width of the widest of several words, measured on the label that
# will hold them. The text is put back before returning, so this is only a
# measurement.
#
# Measured on the label rather than on the button because the button's child
# is a box holding an icon as well, and set_label on such a button would
# replace the box -- see _action_button. The icon's width is constant, so the
# widest label still gives the widest button once the caller adds the
# button's own padding by asking it for a size request.
sub _widest_label
{
    my ( $label, @words ) = @_;

    my $original = $label->get_label;
    my $widest   = 0;

    for my $text ( @words )
    {
        $label->set_text_with_mnemonic( $text );
        my ( undef, $natural ) = $label->get_preferred_width;
        $widest = $natural if $natural > $widest;
    }

    $label->set_text_with_mnemonic( $original );

    # The icon, the box spacing and the button's own padding sit either side
    # of the text and are not in that number.
    return $widest + APPLY_EXTRA;
}

sub _build_right
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 0 );

    my $bar = Gtk3::InfoBar->new;
    $bar->set_message_type( 'error' );
    $bar->set_no_show_all( 1 );
    $bar->add_button( 'Dismiss', 'close' );
    $bar->signal_connect(
        response => sub {
            $bar->hide;
            return;
        }
    );

    my $bar_label = Gtk3::Label->new;
    $bar_label->set_line_wrap( 1 );
    $bar_label->set_xalign( 0 );
    $bar_label->set_selectable( 1 );
    $bar->get_content_area->add( $bar_label );
    $bar_label->show;

    $self->{ infobar }       = $bar;
    $self->{ infobar_label } = $bar_label;

    $self->{ preview } = GlitchVape::GUI::Preview->new(
        on_error => sub {
            $self->_report( $_[ 0 ] );
            return;
        }
    );

    $box->pack_start( $bar,                                 0, 0, 0 );
    $box->pack_start( $self->_build_preview_overlay,        1, 1, 0 );
    $box->pack_start( Gtk3::Separator->new( 'horizontal' ), 0, 0, 0 );
    $box->pack_start( $self->_build_preview_bar,            0, 0, 0 );
    $box->pack_start( $self->_build_status,                 0, 0, 0 );

    return $box;
}

# The spinner sits on the picture rather than beside the button that started
# it, because the picture is what the eye is on while a render runs and a
# 16-pixel spinner in an action bar is not news.
#
# gtk_overlay_set_overlay_pass_through is what makes this safe: without it the
# overlay's event window would sit over the preview and swallow the drags that
# pan and zoom it, which are most of what the preview is for. With it the
# spinner is scenery and every press still reaches the GtkImageView beneath.
sub _build_preview_overlay
{
    my ( $self ) = @_;

    my $overlay = Gtk3::Overlay->new;
    $overlay->add( $self->{ preview }->widget );

    my $badge = Gtk3::Box->new( 'horizontal', 10 );
    $badge->set_halign( 'center' );
    $badge->set_valign( 'center' );
    $badge->set_border_width( 14 );

    # Given the frame and background of a tooltip, so that it stays legible
    # over a bright frame and a dark one alike -- which a bare spinner on a
    # rendered photograph does not.
    $badge->get_style_context->add_class( 'app-notification' );

    my $spinner = Gtk3::Spinner->new;
    $spinner->set_size_request( 24, 24 );
    $spinner->set_valign( 'center' );

    my $label = Gtk3::Label->new( 'Rendering…' );

    $badge->pack_start( $spinner, 0, 0, 0 );
    $badge->pack_start( $label,   0, 0, 0 );

    # Hidden rather than faded: it is over the picture now, not in a row of
    # buttons whose widths it would disturb, so there is nothing to hold a
    # place for.
    #
    # The contents are shown once, here, because set_no_show_all stops
    # show_all descending into the badge later -- so _busy shows the badge
    # itself and the two widgets inside it are already visible.
    $spinner->show;
    $label->show;
    $badge->set_no_show_all( 1 );

    $overlay->add_overlay( $badge );
    $overlay->set_overlay_pass_through( $badge, 1 );

    $self->{ spinner }       = $spinner;
    $self->{ spinner_badge } = $badge;
    $self->{ spinner_label } = $label;

    return $overlay;
}

# The soundtrack page.
#
# A soundtrack still only means anything for an animation -- a still with
# music is nothing -- but that is now said rather than enacted. The page is
# always reachable; when Animate is off it shows why it is empty instead of
# vanishing, because a tab that disappears teaches nobody what it was for,
# and a permanently insensitive one teaches them even less.
#
# Nothing is discarded when Animate goes off. The tracks live in
# $self->{audio}, which the placeholder covers rather than clears, so
# switching animation off to look at a still frame and back on again finds
# the mix exactly as it was.
#
# One file at most and any number of generated tracks, so the lines are
# rebuilt from the spec rather than being a fixed pair -- the same shape the
# effect list uses, and for the same reason.
#
# The page is nothing but that list. Adding is the action bar's Add button,
# the same one the effect list uses, because "add something to what this pane
# is showing" is one action and having a second pair of Add buttons inside the
# page said otherwise. See _add_to_current_page for how one button serves two
# pages.
sub _build_soundtrack_page
{
    my ( $self ) = @_;

    my $stack = Gtk3::Stack->new;
    $stack->set_transition_type( 'crossfade' );
    $stack->set_transition_duration( 120 );

    $stack->add_named( $self->_build_soundtrack_placeholder,
        'needs-animation' );

    my $box = Gtk3::Box->new( 'vertical', 12 );
    $box->set_border_width( 12 );

    my $heading = Gtk3::Label->new;
    $heading->set_markup( '<b>Tracks</b>' );
    $heading->set_xalign( 0 );
    $box->pack_start( $heading, 0, 0, 0 );

    # A GtkListBox for the same reasons the effect list is one, and with the
    # same activation rule: double-click and Enter reopen a track's wizard,
    # a single click merely selects.
    my $list = Gtk3::ListBox->new;
    $list->set_selection_mode( 'single' );
    $list->set_activate_on_single_click( 0 );

    $list->signal_connect(
        'row-activated' => sub {
            my ( undef, $row ) = @_;
            $row->{ edit }->() if $row && $row->{ edit };
            return;
        }
    );

    $self->{ audio_list } = $list;
    $box->pack_start( $list, 0, 0, 0 );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );
    $scroll->set_vexpand( 1 );
    $scroll->add( $box );

    $stack->add_named( $scroll, 'ready' );

    $self->{ audio_stack } = $stack;

    return $stack;
}

# What the page shows when there is no animation to put a soundtrack on.
#
# The icon is the same one a track carries in the list below, so the empty
# page and the full one are visibly about the same thing.
sub _build_soundtrack_placeholder
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 12 );
    $box->set_halign( 'center' );
    $box->set_valign( 'center' );
    $box->set_border_width( 24 );

    my $icon =
        Gtk3::Image->new_from_icon_name( 'audio-x-generic-symbolic', 'dialog' );
    $icon->get_style_context->add_class( 'dim-label' );

    my $text = Gtk3::Label->new(
        'You must enable video animation if you want to add the sound.' );
    $text->set_line_wrap( 1 );
    $text->set_justify( 'center' );
    $text->set_max_width_chars( 28 );
    $text->get_style_context->add_class( 'dim-label' );

    $box->pack_start( $icon, 0, 0, 0 );
    $box->pack_start( $text, 0, 0, 0 );

    return $box;
}

# What the Add button offers while the Soundtrack page is showing: the one
# file, then one row per registered generator -- so a third kind appears here
# the moment it is registered, the same property the effect pane has.
#
# Asking which kind first and configuring it afterwards, rather than opening
# one dialog with a combo at the top: the kind decides what every other
# control in that window is, so choosing it there meant a dialog that rebuilt
# itself underneath the pointer.
#
# The file sits above a separator rather than among the generators because it
# is the odd one out in two ways -- it comes off the disk, and there can only
# ever be one. Its row is hidden once there is one.
sub _build_add_track_popover
{
    my ( $self ) = @_;

    my $popover = Gtk3::Popover->new( $self->{ b_add } );

    # Upwards: the Add button is at the foot of the pane, so there is never
    # room below it. Gtk would flip it there anyway; saying so means the arrow
    # is not asking for something that cannot happen.
    $popover->set_position( 'top' );

    my $box = Gtk3::Box->new( 'vertical', 2 );
    $box->set_border_width( 6 );

    my $file = $self->_popover_row(
        'audio-x-generic-symbolic',
        'Audio file…',
        'Crop a section of a file on disk',
        sub {
            $popover->popdown;
            $self->_choose_audio;
            return;
        }
    );

    # Shown all the way down *before* no_show_all goes on, because show_all
    # returns early on a widget carrying that flag -- setting it first would
    # leave the row's own children unrealised and the row permanently blank.
    # The flag is what then stops the $box->show_all below undoing the
    # decision _sync_actions makes about whether this line belongs here.
    $file->show_all;
    $file->set_no_show_all( 1 );

    my $rule = Gtk3::Separator->new( 'horizontal' );
    $rule->set_margin_top( 4 );
    $rule->set_margin_bottom( 4 );

    $box->pack_start( $file, 0, 0, 0 );
    $box->pack_start( $rule, 0, 0, 0 );

    $self->{ audio_add_file } = $file;

    for my $kind ( GlitchVape::Generator::kinds() )
    {
        my $declared = GlitchVape::Generator::get( $kind );

        $box->pack_start(
            $self->_popover_row(
                _generated_icon( $kind ),
                $declared->{ label },
                $declared->{ summary },
                sub {
                    $popover->popdown;
                    $self->_open_generated( kind => $kind );
                    return;
                }
            ),
            0,
            0,
            0
        );
    }

    $box->show_all;
    $popover->add( $box );

    return $popover;
}

# One line of an Add popover: an icon, what it is, and what it gives you.
sub _popover_row
{
    my ( $self, $icon, $label_text, $summary_text, $on_click ) = @_;

    my $row = Gtk3::Box->new( 'horizontal', 8 );

    $row->pack_start( Gtk3::Image->new_from_icon_name( $icon, 'button' ),
        0, 0, 0 );

    my $text = Gtk3::Box->new( 'vertical', 0 );

    my $label = Gtk3::Label->new( $label_text );
    $label->set_xalign( 0 );

    my $summary = Gtk3::Label->new( $summary_text );
    $summary->set_xalign( 0 );
    $summary->get_style_context->add_class( 'dim-label' );

    $text->pack_start( $label,   0, 0, 0 );
    $text->pack_start( $summary, 0, 0, 0 );
    $row->pack_start( $text, 1, 1, 0 );

    my $button = Gtk3::Button->new;
    $button->set_relief( 'none' );
    $button->add( $row );
    $button->signal_connect(
        clicked => sub {
            $on_click->();
            return;
        }
    );

    return $button;
}

# The same icons the track rows use, so a line in the popover and the line it
# produces are recognisably the same thing.
sub _generated_icon
{
    my ( $kind ) = @_;

    return 'call-start-symbolic' if $kind eq 'dtmf';
    return 'audio-speakers-symbolic';
}

# One line per thing in the soundtrack: the file if there is one, then each
# generated track in the order it will be described.
sub _rebuild_audio_rows
{
    my ( $self ) = @_;

    $_->destroy for $self->{ audio_list }->get_children;

    my $audio = $self->{ audio };

    if ( GlitchVape::Audio::has_file( $audio ) )
    {
        # The file's own description, with the generated tracks taken out of
        # the spec so they are not repeated on its line.
        $self->{ audio_list }->add(
            $self->_audio_row(
                'audio-x-generic-symbolic',
                GlitchVape::Audio::describe( { %$audio, generated => undef } ),
                'Reopen the crop and filter wizard',
                sub { return $self->_edit_audio },
                sub { return $self->_remove_audio },
            )
        );
    }

    my @made = GlitchVape::Audio::generated( $audio );

    for my $n ( 0 .. $#made )
    {
        my $index = $n;

        my $icon = 'audio-speakers-symbolic';
        $icon = 'call-start-symbolic' if $made[ $n ]{ kind } eq 'dtmf';

        $self->{ audio_list }->add(
            $self->_audio_row(
                $icon,
                GlitchVape::Generator::describe( $made[ $n ] ),
                'Reopen this generated track',
                sub { return $self->_edit_generated( $index ) },
                sub { return $self->_remove_generated( $index ) },
            )
        );
    }

    $self->{ audio_list }->show_all;

    return;
}

# Shaped like an effect row: what it is on the left, the way to take it out
# again on the right.
#
# It keeps an explicit Edit button, which the effect rows do not need. Adjust
# in the action bar acts on the effect list only, so double-clicking would
# otherwise be this list's sole route to a track's settings -- and a route
# with nothing on screen pointing at it is one most people never find.
sub _audio_row
{
    my ( $self, $icon, $text, $tip, $edit_with, $remove_with ) = @_;

    my $row = Gtk3::ListBoxRow->new;

    # Hung on the row so that activating it -- double click, or Enter -- does
    # what the Edit button does.
    $row->{ edit } = $edit_with;

    my $box = Gtk3::Box->new( 'horizontal', 6 );
    $box->set_border_width( 6 );

    my $image = Gtk3::Image->new_from_icon_name( $icon, 'button' );

    my $label = Gtk3::Label->new( $text );
    $label->set_xalign( 0 );
    $label->set_ellipsize( 'middle' );
    $label->set_hexpand( 1 );
    $label->set_tooltip_text( "$text\n\nDouble-click to edit" );

    my $edit = Gtk3::Button->new_with_label( 'Edit…' );
    $edit->set_tooltip_text( $tip );
    $edit->set_valign( 'center' );
    $edit->signal_connect(
        clicked => sub {
            $edit_with->();
            return;
        }
    );

    my $remove =
        _icon_button( 'list-remove-symbolic', 'Remove this from the mix' );
    $remove->set_relief( 'none' );
    $remove->set_valign( 'center' );
    $remove->signal_connect(
        clicked => sub {
            $remove_with->();
            return;
        }
    );

    $box->pack_start( $image,  0, 0, 0 );
    $box->pack_start( $label,  1, 1, 0 );
    $box->pack_start( $edit,   0, 0, 0 );
    $box->pack_start( $remove, 0, 0, 0 );

    $row->add( $box );

    return $row;
}

sub _build_preview_bar
{
    my ( $self ) = @_;

    my $bar = Gtk3::Box->new( 'horizontal', 8 );
    $bar->set_border_width( 8 );

    my $quality = Gtk3::ComboBoxText->new;
    $quality->append_text( $_->[ 1 ] ) for @PREVIEW_SIZES;
    $quality->set_active( 1 );
    $quality->set_tooltip_text(
        'Preview render size. Export is always full size' );
    $quality->signal_connect(
        changed => sub {
            my $n = $quality->get_active;
            $self->{ preview_size } = $PREVIEW_SIZES[ $n ][ 0 ]
                if $n >= 0;
            return;
        }
    );
    $bar->pack_start( $quality, 0, 0, 0 );

    # Rendering an animation with a soundtrack and then playing it over and
    # over while tuning an effect is how this interface is actually used, and
    # the fifth time round the tones are not telling anybody anything. Muting
    # is a property of the player, not of the render: it takes effect at once,
    # costs no re-render, and the exported file is untouched.
    my $mute = Gtk3::ToggleButton->new;
    $mute->set_image(
        Gtk3::Image->new_from_icon_name(
            'audio-volume-muted-symbolic', 'button'
        )
    );
    $mute->set_tooltip_text( "Play the preview silently.\n"
            . 'The soundtrack is still rendered, and still in the export' );
    $mute->signal_connect(
        toggled => sub {
            $self->{ muted } = $mute->get_active;
            $self->{ preview }->set_muted( $self->{ muted } );
            return;
        }
    );
    $bar->pack_start( $mute, 0, 0, 0 );

    $self->{ b_mute } = $mute;

    my $zoom = Gtk3::Box->new( 'horizontal', 0 );
    $zoom->get_style_context->add_class( 'linked' );

    for my $spec (
        [ 'zoom-out-symbolic',      'Zoom out',          'zoom_out' ],
        [ 'zoom-fit-best-symbolic', 'Fit',               'zoom_fit' ],
        [ 'zoom-original-symbolic', 'Actual size (1:1)', 'zoom_actual' ],
        [ 'zoom-in-symbolic',       'Zoom in',           'zoom_in' ],
        )
    {
        my ( $icon, $tip, $method ) = @$spec;
        my $b = _icon_button( $icon, $tip );
        $b->signal_connect(
            clicked => sub {
                $self->{ preview }->$method;
                return;
            }
        );
        $zoom->pack_start( $b, 0, 0, 0 );
    }

    $bar->pack_end( $zoom, 0, 0, 0 );

    return $bar;
}

sub _build_status
{
    my ( $self ) = @_;

    my $label = Gtk3::Label->new( 'Open an image to begin.' );
    $label->set_xalign( 0 );
    $label->set_ellipsize( 'end' );
    $label->set_margin_start( 10 );
    $label->set_margin_end( 10 );
    $label->set_margin_top( 4 );
    $label->set_margin_bottom( 6 );
    $label->get_style_context->add_class( 'dim-label' );

    $self->{ status } = $label;
    return $label;
}

# ---------------------------------------------------------------------------
# Effect list

sub _rebuild_effects
{
    my ( $self ) = @_;

    my $list = $self->{ effect_list };

    # Which row was selected, so that rebuilding the list after a parameter
    # change does not silently take the selection -- and the Adjust button --
    # away from whatever the user was working on.
    my $selected = $self->_selected_effect;

    $_->destroy for $list->get_children;
    $self->{ rows } = {};

    unless ( $self->{ state } )
    {
        $self->_close_all_adjust;
        return;
    }

    my %present;

    for my $name ( $self->{ state }->effect_names )
    {
        $present{ $name } = 1;
        $list->add( $self->_effect_row( $name ) );
    }

    $list->show_all;

    if ( defined $selected && $present{ $selected } )
    {
        $list->select_row( $self->{ rows }{ $selected }{ row } );
    }

    # An open settings window for an effect that is no longer in the pipeline
    # would write to state that is not there, so it goes; the survivors are
    # rebuilt from the state, because an undo or a preset has just replaced
    # every value they were showing.
    for my $name ( sort keys %{ $self->{ adjust } || {} } )
    {
        if ( $present{ $name } )
        {
            $self->{ adjust }{ $name }->refresh;
        }
        else
        {
            $self->_close_adjust( $name );
        }
    }

    $self->_sync_actions;
    return;
}

# One line per effect: whether it is in the render, what it is called, and a
# way to take it out again. The parameters are not here -- they are in
# GlitchVape::GUI::Adjust, a window at a time.
#
# One row is one line high whatever the effect declares, so the length of the
# list is the length of the pipeline and a long one can still be read at a
# glance.
sub _effect_row
{
    my ( $self, $name ) = @_;

    my $spec  = GlitchVape::Registry->get( $name );
    my $state = $self->{ state };

    my $row = Gtk3::ListBoxRow->new;
    $row->{ effect } = $name;

    my $box = Gtk3::Box->new( 'horizontal', 8 );
    $box->set_border_width( 6 );

    # A checkbox rather than a switch. A switch is for a setting that takes
    # effect as you leave it alone; this is one of a column of like things
    # being ticked off, which is what a checkbox is for -- and it is a third
    # of the width, which the row needs for the name.
    my $check = Gtk3::CheckButton->new;
    $check->set_active( $state->enabled( $name ) ? 1 : 0 );
    $check->set_valign( 'center' );
    $check->set_tooltip_text( "Include $spec->{title} in the pipeline" );
    $check->signal_connect(
        toggled => sub {
            return if $self->{ loading };

            my $on = $check->get_active ? 1 : 0;
            $state->enabled( $name, $on );

            # The same fact is on the switch in that effect's settings window
            # if one is open, and it has to move with this.
            if ( my $window = $self->{ adjust }{ $name } )
            {
                $window->set_enabled( $on );
            }

            $self->_touch;
            return;
        }
    );

    # Title first because that is what the effect is; the internal name
    # second because that is what a preset, --set and the copied command line
    # all call it, and the two need to be connectable at a glance.
    my $label = Gtk3::Label->new;
    $label->set_markup(
        sprintf q{<b>%s</b>  <span alpha='45%%'><tt>%s</tt></span>},
        Glib::Markup::escape_text( $spec->{ title } ),
        Glib::Markup::escape_text( $name )
    );
    $label->set_xalign( 0 );
    $label->set_hexpand( 1 );

    # Ellipsised so that the longest pairing -- 'VGA Text Corruption vgatext'
    # -- cannot dictate a minimum width for the whole left pane and push the
    # divider across the preview. The divider is draggable for anyone who
    # wants the full pairing; the tooltip has it either way.
    $label->set_ellipsize( 'end' );

    my $stage = GlitchVape::Registry->stage_info( $spec->{ stage } );
    $label->set_tooltip_text(
        sprintf "%s\n%s stage\n\nDouble-click to adjust",
        $spec->{ summary },
        $stage->{ title }
    );

    my $remove = _icon_button( 'list-remove-symbolic',
        "Remove $spec->{title} from this pipeline" );
    $remove->set_relief( 'none' );
    $remove->set_valign( 'center' );
    $remove->signal_connect(
        clicked => sub {

            # Before the state loses it, because closing is keyed on the name
            # and the window would otherwise be left describing nothing.
            $self->_close_adjust( $name );

            $self->{ state }->remove_effect( $name );
            $self->_rebuild_effects;
            $self->_touch;
            return;
        }
    );

    $box->pack_start( $check,  0, 0, 0 );
    $box->pack_start( $label,  1, 1, 0 );
    $box->pack_start( $remove, 0, 0, 0 );

    $row->add( $box );

    $self->{ rows }{ $name } = { row => $row, check => $check };

    return $row;
}

# ---------------------------------------------------------------------------
# Settings windows

# The effect whose row is selected, or undef.
sub _selected_effect
{
    my ( $self ) = @_;

    my $row = $self->{ effect_list }->get_selected_row or return undef;
    return $row->{ effect };
}

sub _adjust_selected
{
    my ( $self ) = @_;

    my $name = $self->_selected_effect or return;
    $self->_adjust_effect( $name );

    return;
}

# One window per effect, so asking twice raises the one that is open rather
# than stacking a second copy on top of it -- two windows writing the same
# parameters would disagree the moment either was touched.
sub _adjust_effect
{
    my ( $self, $name ) = @_;

    return unless $self->{ state };
    return unless defined $name;

    if ( my $open = $self->{ adjust }{ $name } )
    {
        $open->present;
        return;
    }

    $self->{ adjust }{ $name } = GlitchVape::GUI::Adjust->new(
        parent    => $self->{ window },
        name      => $name,
        state     => $self->{ state },
        on_change => sub {
            $self->_touch;
            return;
        },
        on_enabled => sub {
            my ( $on ) = @_;

            # The checkbox on the row is the same fact seen from the list.
            if ( my $row = $self->{ rows }{ $name } )
            {
                $self->{ loading }++;
                $row->{ check }->set_active( $on ? 1 : 0 );
                $self->{ loading }--;
            }

            $self->_touch;
            return;
        },
        on_closed => sub {
            delete $self->{ adjust }{ $_[ 0 ] };
            return;
        },
    );

    return;
}

sub _close_adjust
{
    my ( $self, $name ) = @_;

    my $window = delete $self->{ adjust }{ $name } or return;
    $window->close;

    return;
}

sub _close_all_adjust
{
    my ( $self ) = @_;

    $self->_close_adjust( $_ ) for sort keys %{ $self->{ adjust } || {} };
    return;
}

sub _touch
{
    my ( $self ) = @_;
    $self->{ dirty } = 1;
    $self->_sync_actions;
    return;
}

# ---------------------------------------------------------------------------
# Files

sub _choose_input
{
    my ( $self ) = @_;

    my $dialog = Gtk3::FileChooserDialog->new( 'Open image', $self->{ window },
        'open', 'Cancel', 'cancel', 'Open', 'accept' );

    my $images = Gtk3::FileFilter->new;
    $images->set_name( 'Images' );
    $images->add_pattern( "*.$_" )
        for qw(png jpg jpeg heic heif tif tiff webp bmp gif avif
        PNG JPG JPEG HEIC HEIF TIF TIFF WEBP BMP GIF AVIF);
    $dialog->add_filter( $images );

    my $all = Gtk3::FileFilter->new;
    $all->set_name( 'All files' );
    $all->add_pattern( '*' );
    $dialog->add_filter( $all );

    if ( $dialog->run eq 'accept' )
    {
        my $path = $dialog->get_filename;
        $dialog->destroy;
        $self->_open_file( $path );
        return;
    }

    $dialog->destroy;
    return;
}

sub _open_file
{
    my ( $self, $path, %arg ) = @_;

    unless ( GlitchVape::IO::is_supported( $path ) )
    {
        $self->_report(
            "$path has an unusual extension; attempting to open it anyway." );
    }

    my ( $w, $h ) = eval { $self->{ render }->source( $path ) };

    if ( my $err = $@ )
    {
        $err =~ s/\s+\z//;
        $self->_report( $err );
        return 0;
    }

    $self->{ state } = GlitchVape::GUI::State->new(
        source => $path,
        seed   => $arg{ seed },
    );

    my $preset = $arg{ preset };
    if ( defined $preset && length $preset )
    {
        local $@;
        unless ( eval { $self->{ state }->load_preset( $preset ); 1 } )
        {
            my $err = $@;
            $err =~ s/\s+\z//;
            $self->_report( $err );
        }
    }

    $self->{ preview }->clear;
    $self->{ state }->commit;

    $self->_reload_widgets;

    $self->{ header }->set_title( basename( $path ) );

    # Dimensions are probed with a separate 'magick' process and may not come
    # back on an unusual format; that is not worth refusing to open the file
    # over, so the subtitle just says less.
    my $subtitle = $path;
    if ( defined $h )
    {
        $subtitle = sprintf '%d x %d', $w, $h;
    }
    $self->{ header }->set_subtitle( $subtitle );

    $self->_status( 'Opening…' );
    $self->_sync_actions;
    $self->_show_source;

    return 1;
}

# Put the photograph on the screen straight away, before anything has been
# applied to it. Opening a file and being shown a placeholder that says to
# press a button is a poor answer to "what does this picture look like", and
# with no effects to run this costs only the decode.
#
# Not the preset's render even when one was asked for: that can be eight
# seconds, and this is meant to be the thing that happens immediately. The
# preset is what Apply is for.
sub _show_source
{
    my ( $self ) = @_;

    my $size = $self->{ preview_size };
    $size = $self->_full_size unless $size;

    $self->_busy( 1, 'Opening…' );

    $self->{ render }->source_preview(
        size    => $size,
        on_done => sub {
            my ( $path ) = @_;

            $self->_busy( 0 );
            $self->{ preview }->show_still( $path );
            $self->_status( 'Add effects, adjust anything, then press Apply.' );
            return;
        },
        on_error => sub {

            # Not being able to show the source is not a reason to refuse to
            # open it -- everything else about the file is already loaded, and
            # Apply will report the same problem more usefully.
            $self->_busy( 0 );
            $self->_status( 'Add effects, adjust anything, then press Apply.' );
            return;
        },
    );

    return;
}

sub _choose_output
{
    my ( $self ) = @_;

    return unless $self->{ state };

    my $suggested = $self->_suggested_output;

    my $dialog = Gtk3::FileChooserDialog->new(
        'Export render',
        $self->{ window },
        'save', 'Cancel', 'cancel', 'Export', 'accept'
    );
    $dialog->set_do_overwrite_confirmation( 1 );
    $dialog->set_current_name( basename( $suggested ) );

    if ( $dialog->run ne 'accept' )
    {
        $dialog->destroy;
        return;
    }

    my $path = $dialog->get_filename;
    $dialog->destroy;

    $self->_export( $path );
    return;
}

# Where an export would go if nobody moved it: the name the file chooser opens
# with, and the '-o' in the command line equivalent. One derivation for both,
# so that what the command says is where the button would have written.
#
# The extension comes from the export settings rather than from the mode
# alone, which is what makes 'Windows Bitmap' or 'WebM' show up as a filename
# rather than as something that has to be typed over.
sub _suggested_output
{
    my ( $self ) = @_;

    return undef unless $self->{ state };

    my $format;

    if ( $self->{ animate } )
    {
        my %target = GlitchVape::GUI::Export::video_target( $self->{ export } );
        $format = $target{ ext };
    }
    else
    {
        $format = GlitchVape::GUI::Export::still_extension( $self->{ export },
            $self->{ state }->source );
    }

    return GlitchVape::IO::derive_output_path(
        $self->{ state }->source,
        dir    => 'out',
        format => $format,
        preset => $self->{ state }->preset,
    );
}

sub _export
{
    my ( $self, $path ) = @_;

    # Export is the one operation that must not be pre-empted by the preview
    # currently rendering, and equally must not be started twice.
    $self->{ render }->cancel if $self->{ render }->busy;

    my $spec = $self->_animate_spec;

    # A GIF has nowhere to put the audio. Said here rather than only in the
    # warning GlitchVape::Animate writes to stderr, which nobody running the
    # interface from a desktop launcher will ever see.
    if ( $spec && $spec->{ audio } && $path =~ /\.gif\z/i )
    {
        $self->_report( 'A GIF cannot carry audio, so the added track will '
                . 'not be in this file. Export as .mp4 or .webm for sound.' );
    }

    $self->_busy( 1, sprintf 'Exporting to %s  ·  %s',
        $path, GlitchVape::GUI::Export::describe( $self->{ export }, $spec ) );

    $self->{ render }->export(
        state   => $self->{ state },
        output  => $path,
        animate => $spec,

        # Size, codec, palette and the retro box, whichever of them apply to
        # what is being written. The settings decide; this only passes them
        # on, which is what keeps the export and the command line equivalent
        # unable to disagree.
        GlitchVape::GUI::Export::render_options( $self->{ export }, $spec ),

        on_done => sub {
            my ( $written ) = @_;
            $self->_busy( 0 );
            $self->_status( "Exported $written" );
            return;
        },
        on_error => sub {
            $self->_busy( 0 );
            $self->_report( $_[ 0 ] );
            return;
        },
    );

    return;
}

# ---------------------------------------------------------------------------
# Audio

sub _choose_audio
{
    my ( $self ) = @_;

    GlitchVape::GUI::Audio->choose(
        parent  => $self->{ window },
        cache   => $self->{ cache },
        on_done => sub {
            $self->_set_audio_file( $_[ 0 ] );
            return;
        },
        on_error => sub {
            $self->_report( $_[ 0 ] );
            return;
        },
    );

    return;
}

sub _edit_audio
{
    my ( $self ) = @_;

    return unless GlitchVape::Audio::has_file( $self->{ audio } );

    GlitchVape::GUI::Audio->edit(
        parent  => $self->{ window },
        cache   => $self->{ cache },
        spec    => $self->{ audio },
        on_done => sub {
            $self->_set_audio_file( $_[ 0 ] );
            return;
        },
        on_error => sub {
            $self->_report( $_[ 0 ] );
            return;
        },
    );

    return;
}

# Adding and editing are the same dialog: it is small enough that reopening it
# on an existing phrase is exactly reopening it, with no file chooser in the
# way to make the two feel different.
# Adding and editing are the same dialog: it is small enough that reopening it
# on an existing track is exactly reopening it, with nothing in the way to
# make the two feel different.
sub _edit_generated
{
    my ( $self, $index ) = @_;

    my @made = GlitchVape::Audio::generated( $self->{ audio } );
    return unless $made[ $index ];

    $self->_open_generated( index => $index );

    return;
}

# Adding and editing are the same dialog, differing only in where the kind
# comes from: the popover for a new track, the track itself for an existing
# one. Either way the dialog is told which kind it is and does not ask.
sub _open_generated
{
    my ( $self, %arg ) = @_;

    my $index = $arg{ index };
    my $kind  = $arg{ kind };

    my $current;

    if ( defined $index )
    {
        my @made = GlitchVape::Audio::generated( $self->{ audio } );
        $current = $made[ $index ] or return;
        $kind    = $current->{ kind };
    }

    GlitchVape::GUI::Generated->run(
        parent  => $self->{ window },
        cache   => $self->{ cache },
        kind    => $kind,
        spec    => $current,
        on_done => sub {
            $self->_set_generated( $index, $_[ 0 ] );
            return;
        },
        on_error => sub {
            $self->_report( $_[ 0 ] );
            return;
        },
    );

    return;
}

# The file half and the generated list are set and cleared independently, so
# each writes only its own keys into the one spec they share.
sub _set_audio_file
{
    my ( $self, $spec ) = @_;

    my $audio = $self->{ audio } || {};
    $audio->{ $_ } = $spec->{ $_ } for qw(path start end filters gain);
    $self->{ audio } = $audio;

    $self->_audio_changed(
        'Track added. Press Apply to hear it over the loop.' );

    return;
}

sub _set_generated
{
    my ( $self, $index, $spec ) = @_;

    my $audio = $self->{ audio } || {};
    $audio->{ generated } ||= [];

    if ( defined $index )
    {
        $audio->{ generated }[ $index ] = $spec;
    }
    else
    {
        push @{ $audio->{ generated } }, $spec;
    }

    $self->{ audio } = $audio;

    my $said = sprintf '%s added. Press Apply to hear it.',
        GlitchVape::Generator::label( $spec->{ kind } );

    if ( GlitchVape::Audio::has_file( $audio ) )
    {
        $said = sprintf '%s added, mixed under the track. Press Apply to '
            . 'hear it.', GlitchVape::Generator::label( $spec->{ kind } );
    }

    $self->_warn_truncated( $audio );
    $self->_audio_changed( $said );

    return;
}

# The file decides the length, so anything longer loses its tail. The rule
# working as designed, but what disappears is the end of something the user
# typed, so it does not get to happen quietly.
sub _warn_truncated
{
    my ( $self, $audio ) = @_;

    for my $cut ( GlitchVape::Audio::truncated( $audio ) )
    {
        $self->_report(
            sprintf "The last %s of this will not be heard, because the "
                . "soundtrack is shorter than it is:\n    %s\n"
                . 'Lengthen the crop, or shorten the track.',
            GlitchVape::Audio::format_time( $cut->[ 1 ] ),
            $cut->[ 0 ]
        );
    }

    return;
}

# Removing is deliberately one press with no confirmation: both dialogs are
# quick to run again, and the alternative is a dialog between the user and
# undoing something they can see is wrong.
sub _remove_audio
{
    my ( $self ) = @_;

    return unless GlitchVape::Audio::has_file( $self->{ audio } );

    delete $self->{ audio }{ $_ } for qw(path start end filters gain);
    $self->_drop_audio_if_empty;

    $self->_audio_changed( 'Removed the audio track.' );

    return;
}

sub _remove_generated
{
    my ( $self, $index ) = @_;

    my $list = $self->{ audio }{ generated } or return;
    return unless $list->[ $index ];

    my $gone = GlitchVape::Generator::describe( $list->[ $index ] );

    splice @$list, $index, 1;
    delete $self->{ audio }{ generated } unless @$list;

    $self->_drop_audio_if_empty;
    $self->_audio_changed( "Removed $gone." );

    return;
}

sub _drop_audio_if_empty
{
    my ( $self ) = @_;

    return if GlitchVape::Audio::has_file( $self->{ audio } );
    return if GlitchVape::Audio::has_generated( $self->{ audio } );

    $self->{ audio } = undef;

    return;
}

sub _audio_changed
{
    my ( $self, $said ) = @_;

    $self->_sync_actions;
    $self->_status( $said );

    return;
}

# The animation spec both the preview and the export are built from, so that
# the two cannot disagree about what is being rendered.
sub _animate_spec
{
    my ( $self ) = @_;

    return undef unless $self->{ animate };

    return {
        frames => $self->{ frames },
        fps    => $self->{ fps },
        audio  => $self->{ audio },
    };
}

# ---------------------------------------------------------------------------
# Presets

# Empty the pipeline without leaving the image.
#
# In the menu rather than beside the effect list: it discards every effect at
# once, which is not something to have within a slip of the Add button. It is
# an ordinary edit, so undo steps back over it like any other.
sub _clear_effects
{
    my ( $self ) = @_;

    return unless $self->{ state };

    $self->_close_all_adjust;

    $self->{ state }->preset( undef );
    $self->{ state }{ current }{ effects } = {};

    $self->_reload_widgets;
    $self->_touch;

    return;
}

sub _select_preset
{
    my ( $self, $name ) = @_;

    return unless $self->{ state };
    return unless defined $name;

    local $@;
    unless ( eval { $self->{ state }->load_preset( $name ); 1 } )
    {
        my $err = $@;
        $err =~ s/\s+\z//;
        $self->_report( $err );
        return;
    }

    $self->_reload_widgets;
    $self->_touch;
    $self->_status( "Preset '$name' loaded. Press Apply to render it." );

    return;
}

sub _save_preset
{
    my ( $self ) = @_;

    return unless $self->{ state };

    my $dialog = Gtk3::Dialog->new_with_buttons(
        'Save as preset',
        $self->{ window },
        'modal', 'Cancel', 'cancel', 'Save', 'accept'
    );

    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 6 );
    $grid->set_column_spacing( 8 );
    $grid->set_border_width( 12 );

    my $name = Gtk3::Entry->new;
    $name->set_placeholder_text( 'my-look' );
    $name->set_activates_default( 1 );

    my $title = Gtk3::Entry->new;
    $title->set_placeholder_text( 'One line describing it' );

    my $keep = Gtk3::CheckButton->new_with_label( 'Record the current seed' );
    $keep->set_tooltip_text(
              "A preset with a seed always renders identically.\n"
            . 'Leave this off for a preset meant to be used on many photos' );

    $grid->attach( Gtk3::Label->new( 'Name' ),  0, 0, 1, 1 );
    $grid->attach( $name,                       1, 0, 1, 1 );
    $grid->attach( Gtk3::Label->new( 'Title' ), 0, 1, 1, 1 );
    $grid->attach( $title,                      1, 1, 1, 1 );
    $grid->attach( $keep,                       1, 2, 1, 1 );

    $dialog->get_content_area->add( $grid );
    $dialog->set_default_response( 'accept' );
    $dialog->show_all;

    if ( $dialog->run ne 'accept' )
    {
        $dialog->destroy;
        return;
    }

    my $chosen = $name->get_text;
    my $desc   = $title->get_text;
    my $seed   = $keep->get_active;
    $dialog->destroy;

    $chosen =~ s/^\s+|\s+\z//g;
    $chosen =~ s/\.ya?ml$//;

    unless ( length $chosen )
    {
        $self->_report( 'A preset needs a name.' );
        return;
    }

    # Anything that is not a plain name would escape the preset directory or
    # produce a file the loader cannot find by name.
    if ( $chosen !~ /^[\w-]+$/ )
    {
        $self->_report( "'$chosen' is not a usable preset name.\n"
                . 'Use letters, digits, hyphens and underscores.' );
        return;
    }

    $self->_write_preset( $chosen, $desc, $seed );
    return;
}

sub _write_preset
{
    my ( $self, $name, $title, $keep_seed ) = @_;

    my ( $dir ) = GlitchVape::Config::preset_dirs();
    $dir = 'presets' unless defined $dir && length $dir;

    unless ( -d $dir )
    {
        require File::Path;
        File::Path::make_path( $dir );
    }

    my $path = File::Spec->catfile( $dir, "$name.yml" );

    if ( -e $path && !$self->_confirm( "Replace the existing preset $path?" ) )
    {
        return;
    }

    my $yaml = $self->{ state }->to_preset_yaml(
        name      => $name,
        title     => $title,
        keep_seed => $keep_seed,
    );

    # Written as bytes: preset text can contain Japanese, and the loader reads
    # raw and decodes itself.
    my $ok = open my $fh, '>:raw', $path;

    unless ( $ok )
    {
        $self->_report( "Cannot write $path: $!" );
        return;
    }

    require Encode;
    print { $fh } Encode::encode( 'UTF-8', $yaml );
    close $fh;

    $self->_status( "Saved $path -- usable now as: glitchvape -p $name" );

    return;
}

# One Add button, two pages. Which list it adds to is whichever list the pane
# is showing, because "add something here" is one action and giving each page
# its own pair of Add buttons said it was several.
#
# The effect page opens the assistant directly; the soundtrack page has a
# choice to make first -- a file, or which kind of generated track -- so it
# gets a popover hung off the button.
sub _add_to_current_page
{
    my ( $self ) = @_;

    if ( $self->_on_soundtrack_page )
    {
        # Built on first use rather than with the window: the generator
        # registry is read to build it, and nothing guarantees every
        # generator has registered by the time the window goes up.
        unless ( $self->{ add_track_popover } )
        {
            $self->{ add_track_popover } = $self->_build_add_track_popover;

            # Built after the last sync, so it has never been told whether a
            # file is already in the mix.
            $self->_sync_actions;
        }

        $self->{ add_track_popover }->popup;
        return;
    }

    $self->{ add_effect_popover } ||= $self->_build_add_effect_popover;
    $self->{ add_effect_popover }->popup;

    return;
}

# What the Add button offers while the Image page is showing: one effect, or
# everything a preset names.
#
# A preset is a set of effects with their parameters already dialled in, so it
# belongs beside "one effect" as the other size of the same action rather than
# in a control of its own. It is the only entry that replaces what is already
# there, which is why it says so on its second line.
sub _build_add_effect_popover
{
    my ( $self ) = @_;

    my $popover = Gtk3::Popover->new( $self->{ b_add } );
    $popover->set_position( 'top' );

    my $box = Gtk3::Box->new( 'vertical', 2 );
    $box->set_border_width( 6 );

    $box->pack_start(
        $self->_popover_row(
            'list-add-symbolic',
            'Single effect…',
            'Choose one, and dial it in against a preview',
            sub {
                $popover->popdown;
                $self->_choose_effect;
                return;
            }
        ),
        0,
        0,
        0
    );

    $box->pack_start(
        $self->_popover_row(
            'view-list-symbolic',
            'Effects from a preset…',
            'A whole look at once — replaces what is here',
            sub {
                $popover->popdown;
                $self->_choose_preset;
                return;
            }
        ),
        0,
        0,
        0
    );

    $box->show_all;
    $popover->add( $box );

    return $popover;
}

# The preset chooser.
#
# A dialog rather than a third level of popover: this is the one action in the
# window that discards work, so it is worth a moment's deliberation and a
# button that has to be pressed on purpose. The list is read from disk each
# time it opens, so a preset saved from the menu is in it immediately.
sub _choose_preset
{
    my ( $self ) = @_;

    return unless $self->{ state };

    my $presets = GlitchVape::Config::list_presets();

    unless ( @$presets )
    {
        $self->_report( 'No presets were found. '
                . 'GLITCHVAPE_PRESETS says where to look for them.' );
        return;
    }

    my $dialog = Gtk3::Dialog->new_with_buttons(
        'Effects from a preset',
        $self->{ window },
        'modal',
        'Cancel' => 'cancel',
        'Load'   => 'ok',
    );
    $dialog->set_default_size( 420, 460 );
    $dialog->set_default_response( 'ok' );

    my $content = $dialog->get_content_area;
    $content->set_border_width( 12 );
    $content->set_spacing( 8 );

    my $lead = Gtk3::Label->new(
        'Loading a preset replaces every effect in the pipeline.' );
    $lead->set_xalign( 0 );
    $lead->set_line_wrap( 1 );
    $lead->set_max_width_chars( 44 );
    $lead->get_style_context->add_class( 'dim-label' );
    $content->pack_start( $lead, 0, 0, 0 );

    my $list = Gtk3::ListBox->new;
    $list->set_selection_mode( 'single' );

    for my $preset ( @$presets )
    {
        my $row = Gtk3::ListBoxRow->new;
        $row->{ preset } = $preset->{ name };

        my $text = Gtk3::Box->new( 'vertical', 0 );
        $text->set_border_width( 6 );

        my $title = Gtk3::Label->new( $preset->{ title } );
        $title->set_xalign( 0 );

        # The name second, because that is what -p wants and what the saved
        # file is called.
        my $name = Gtk3::Label->new;
        $name->set_markup( "<span alpha='45%'><tt>"
                . Glib::Markup::escape_text( $preset->{ name } )
                . '</tt></span>' );
        $name->set_xalign( 0 );

        $text->pack_start( $title, 0, 0, 0 );
        $text->pack_start( $name,  0, 0, 0 );
        $row->add( $text );
        $list->add( $row );
    }

    # Double-clicking a row is the same as pressing Load, which is what the
    # rest of the window's lists do.
    $list->set_activate_on_single_click( 0 );
    $list->signal_connect(
        'row-activated' => sub {
            $dialog->response( 'ok' );
            return;
        }
    );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );
    $scroll->set_vexpand( 1 );
    $scroll->add( $list );
    $content->pack_start( $scroll, 1, 1, 0 );

    $dialog->show_all;

    my $answer = $dialog->run;
    my $row    = $list->get_selected_row;
    my $chosen = ( $answer eq 'ok' && $row ) ? $row->{ preset } : undef;

    $dialog->destroy;

    $self->_select_preset( $chosen ) if defined $chosen;

    return;
}

sub _on_soundtrack_page
{
    my ( $self ) = @_;

    my $page = $self->{ left_stack }->get_visible_child_name // 'image';
    return $page eq 'soundtrack';
}

sub _choose_effect
{
    my ( $self ) = @_;

    return unless $self->{ state };

    GlitchVape::GUI::Wizard->run(
        parent   => $self->{ window },
        state    => $self->{ state },
        render   => $self->{ render },
        on_empty => sub { $self->_report( $_[ 0 ] ); return },
        on_apply => sub {
            my ( $name, $params ) = @_;
            $self->_accept_effect( $name, $params );
            return;
        },
    );

    return;
}

# The wizard hands back a name and the settings dialled in against its
# preview; from here on the effect is an ordinary member of the pipeline with
# no memory of how it was added.
sub _accept_effect
{
    my ( $self, $name, $params ) = @_;

    $self->{ state }->add_effect( $name );

    for my $key ( sort keys %$params )
    {
        $self->{ state }->param( $name, $key, $params->{ $key } );
    }

    $self->_rebuild_effects;
    $self->_touch;

    # Reveal what was just added, or the button appears to have done nothing
    # on a pipeline long enough to need scrolling.
    if ( my $row = $self->{ rows }{ $name } )
    {
        $row->{ disclose }->set_active( 1 );
    }

    my $title = GlitchVape::Registry->get( $name )->{ title };
    $self->_status( "Added '$title'. Press Apply to see it." );

    return;
}

# ---------------------------------------------------------------------------
# Rendering

sub _apply
{
    my ( $self ) = @_;

    return unless $self->{ state };

    if ( $self->{ render }->busy )
    {
        $self->{ render }->cancel;
        $self->_busy( 0 );
        $self->_status( 'Render cancelled.' );
        return;
    }

    $self->{ state }->commit;
    $self->{ dirty } = 0;

    $self->_render;
    return;
}

sub _render
{
    my ( $self ) = @_;

    my $size = $self->{ preview_size };

    # 'Full size' means whatever the pipeline would use for a real render,
    # which the preset may have lowered from the 1920 default.
    if ( !$size )
    {
        $size = $self->_full_size;
    }

    my $spec = $self->_animate_spec;

    my $started = time;
    $self->_busy( 1, 'Rendering…' );

    $self->{ render }->preview(
        state   => $self->{ state },
        size    => $size,
        animate => $spec,
        on_done => sub {
            my ( $path, $cached ) = @_;
            $self->_busy( 0 );
            $self->_show( $path, $spec );
            $self->_report_timing( $started, $cached, $size );
            return;
        },
        on_error => sub {
            $self->_busy( 0 );
            $self->_report( $_[ 0 ] );
            return;
        },
    );

    $self->_sync_actions;
    return;
}

sub _show
{
    my ( $self, $path, $animated ) = @_;

    if ( $animated )
    {
        return $self->{ preview }->show_video( $path );
    }

    return $self->{ preview }->show_still( $path );
}

sub _report_timing
{
    my ( $self, $started, $cached, $size ) = @_;

    my ( $back, $forward ) = $self->{ state }->depth;

    my $how = sprintf 'rendered in %ds', time - $started;
    if ( $cached )
    {
        $how = 'from cache';
    }

    my $plural = 's';
    $plural = q{} if $back == 1;

    # The seed is here because it is nowhere else: it lost its entry when
    # Randomize moved into the menu, and it is the one thing needed to
    # reproduce a render that turned out well.
    $self->_status(
        sprintf '%s  ·  %d px  ·  %s  ·  seed %s  ·  %d step%s back',
        $self->{ state }->summary,
        $size, $how, $self->{ state }->seed,
        $back, $plural
    );

    return;
}

sub _full_size
{
    my ( $self ) = @_;

    my $preset = $self->{ state }->preset;
    return 1920 unless defined $preset && length $preset;

    my $config = eval { GlitchVape::Config::load( preset => $preset ) };
    return 1920 unless $config;

    return $config->{ output }{ max_dim } || 1920;
}

sub _step_history
{
    my ( $self, $direction ) = @_;

    return unless $self->{ state };
    return unless $self->{ state }->$direction;

    $self->_reload_widgets;
    $self->{ dirty } = 0;

    # The state being restored has been rendered before, so this is a cache
    # lookup rather than a re-render -- which is the whole reason undo steps
    # over configurations instead of images.
    $self->_render;

    return;
}

# Rebuild every control from the state without the resulting 'changed'
# signals writing back into it.
sub _reload_widgets
{
    my ( $self ) = @_;

    $self->{ loading }++;

    $self->_rebuild_effects;

    $self->{ loading }--;

    $self->_sync_actions;
    return;
}

# ---------------------------------------------------------------------------
# Menu actions

# A new seed, which reshuffles every effect that draws on randomness while
# leaving every parameter alone. Not an entry with the number in it: a seed is
# never typed, because what it is only matters after the fact,
# for reproducing a render somebody liked, and Copy command line carries it
# for that. So the action stays and the field goes.
sub _randomize
{
    my ( $self ) = @_;

    return unless $self->{ state };

    my $seed = int rand 2**31;
    $self->{ state }->seed( $seed );

    $self->_touch;
    $self->_status( "Seed $seed. Press Apply to see it." );

    return;
}

# Frames and rate. Behind the menu because they are set once and then left --
# the default two-second loop is what almost every render uses -- while the
# toggle they govern is in the preview bar, where the decision to animate at
# all actually gets made.
sub _animation_settings
{
    my ( $self ) = @_;

    my $dialog = Gtk3::Dialog->new_with_buttons(
        'Animation settings',
        $self->{ window },
        'modal', 'Close', 'close'
    );

    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 8 );
    $grid->set_column_spacing( 10 );
    $grid->set_border_width( 14 );

    my $length = Gtk3::Label->new( q{} );
    $length->set_xalign( 0 );
    $length->get_style_context->add_class( 'dim-label' );

    my $frames = Gtk3::SpinButton->new_with_range( 2, 120, 1 );
    $frames->set_value( $self->{ frames } );
    $frames->set_tooltip_text(
        'How many frames the loop is made of. Each one is a whole render' );

    my $fps = Gtk3::SpinButton->new_with_range( 1, 60, 1 );
    $fps->set_value( $self->{ fps } );
    $fps->set_tooltip_text( 'How fast they are played back' );

    # The two numbers separately say very little; what they come to is the
    # length of the loop, which is the thing being chosen.
    my $describe = sub {
        $length->set_text(
            sprintf '%d frames at %d fps  ·  %.1f second loop',
            $self->{ frames },
            $self->{ fps },
            $self->{ frames } / $self->{ fps }
        );
        return;
    };

    $frames->signal_connect(
        'value-changed' => sub {
            $self->{ frames } = int $frames->get_value;
            $describe->();
            return;
        }
    );

    $fps->signal_connect(
        'value-changed' => sub {
            $self->{ fps } = int $fps->get_value;
            $describe->();
            return;
        }
    );

    $describe->();

    my $frames_label = Gtk3::Label->new( 'Frames' );
    $frames_label->set_xalign( 0 );

    my $fps_label = Gtk3::Label->new( 'Frame rate' );
    $fps_label->set_xalign( 0 );

    $grid->attach( $frames_label, 0, 0, 1, 1 );
    $grid->attach( $frames,       1, 0, 1, 1 );
    $grid->attach( $fps_label,    0, 1, 1, 1 );
    $grid->attach( $fps,          1, 1, 1, 1 );
    $grid->attach( $length,       0, 2, 2, 1 );

    $dialog->get_content_area->add( $grid );
    $dialog->show_all;
    $dialog->run;
    $dialog->destroy;

    return;
}

# What Export writes and at what size. Behind the menu for the same reason the
# animation settings are: set once, then left, while the button they govern is
# in the header bar where the decision to export at all gets made.
sub _export_settings
{
    my ( $self ) = @_;

    GlitchVape::GUI::Export->run(
        parent => $self->{ window },

        # The frame rate lives in one place and two dialogs edit it, so the
        # current value goes in rather than whatever this hash was last saved
        # with -- Animation settings may have changed it since.
        settings => { %{ $self->{ export } }, fps => $self->{ fps } },

        on_done => sub {
            my ( $settings ) = @_;

            $self->{ export } = $settings;
            $self->{ fps }    = $settings->{ fps };

            $self->_status(
                'Export settings: '
                    . GlitchVape::GUI::Export::describe(
                    $settings, $self->{ animate }
                    )
            );
            return;
        },
    );

    return;
}

# The interface claims to be a front end rather than a second implementation.
# This is that claim made legible: the same settings as a command somebody can
# paste into a terminal, shown whole and copied on request.
#
# Shown rather than only copied because the command is the one thing here that
# is worth reading. It names every effect that differs from the preset, so it
# doubles as a summary of what has been dialled in -- and a clipboard is a
# poor place to read anything from.
sub _copy_command
{
    my ( $self ) = @_;

    return unless $self->{ state };

    my %arg = (
        state   => $self->{ state },
        animate => $self->_animate_spec,
        export  => $self->{ export },
        output  => $self->_suggested_output,
    );

    # Two shapes of one command: the wrapped one is what is on screen, and it
    # is also what is copied. Backslash continuations paste into a shell as
    # readily as one long line, and stay readable afterwards.
    my $shown = GlitchVape::GUI::CommandLine::format( %arg, wrap => 1 );

    $self->_show_report(
        'Command line equivalent',
        $shown,
        copy => $shown,
        lead => 'The command that produces this export. The output path is '
            . 'where Export would have put it.',
    );

    return;
}

# What --check-deps prints, in a window -- because a graphical session is
# exactly the place where nobody has a terminal open to run it in.
sub _show_deps
{
    my ( $self ) = @_;

    my @lines = ( 'External tools' );

    for my $tool ( GlitchVape::Tools::report() )
    {
        my ( $name, $path, $package ) = @$tool;

        my $where = $path;
        $where = "missing - sudo apt install $package" unless $path;

        push @lines, sprintf '    %-10s %s', $name, $where;
    }

    push @lines, q{}, 'Animated preview';

    my $gst = 'available';
    $gst = 'unavailable - the still interface still works'
        unless GlitchVape::GUI::Preview::gst_available();

    push @lines, sprintf( '    %-10s %s', 'gstreamer', $gst ), q{}, 'Fonts';

    for my $entry ( @{ GlitchVape::Fonts::available() } )
    {
        my ( $role, $path ) = @$entry;
        push @lines, sprintf '    %-10s %s', $role, ( $path // 'missing' );
    }

    $self->_show_report( 'Dependencies', join "\n", @lines );

    return;
}

sub _clear_cache
{
    my ( $self ) = @_;

    my ( $count, $bytes ) = $self->{ cache }->purge;

    # Nothing needs invalidating beyond this: the keys are content-addressed,
    # so an entry that is gone is simply a miss and the next Apply renders.
    my $plural = 's';
    $plural = q{} if $count == 1;

    $self->_status(
        sprintf 'Cleared %d cached render%s (%.1f MB). The next Apply will '
            . 'render rather than recall.',
        $count, $plural, $bytes / 1024 / 1024 );

    return;
}

sub _show_about
{
    my ( $self ) = @_;

    GlitchVape::GUI::About->show( $self->{ window } );

    return;
}

# A response id of this program's own. Positive, so that it cannot collide
# with any GtkResponseType -- those are all negative -- and comes back from
# gtk_dialog_run as the number rather than as a nickname.
use constant COPY_RESPONSE => 1;

# A monospaced, selectable, scrolling block of text. Selectable because the
# entire point of a dependency report is to be pasted somewhere else.
#
#     lead => text     a sentence above the box, in the window's own font
#     copy => text     adds a Copy button that puts this on the clipboard
#
# The box scrolls both ways and the dialog has a size of its own, so a line
# longer than the window scrolls rather than widening it -- which is what a
# command line full of --set flags would otherwise do.
sub _show_report
{
    my ( $self, $title, $text, %arg ) = @_;

    my $dialog = Gtk3::Dialog->new_with_buttons( $title, $self->{ window },
        'modal', 'Close', 'close' );
    $dialog->set_default_size( 620, 460 );

    my $box = Gtk3::Box->new( 'vertical', 8 );
    $box->set_border_width( 12 );

    if ( defined $arg{ lead } && length $arg{ lead } )
    {
        my $lead = Gtk3::Label->new( $arg{ lead } );
        $lead->set_xalign( 0 );
        $lead->set_line_wrap( 1 );
        $lead->get_style_context->add_class( 'dim-label' );
        $box->pack_start( $lead, 0, 0, 0 );
    }

    my $label = Gtk3::Label->new( $text );
    $label->set_xalign( 0 );
    $label->set_yalign( 0 );
    $label->set_selectable( 1 );
    $label->set_margin_start( 8 );
    $label->set_margin_end( 8 );
    $label->set_margin_top( 6 );
    $label->set_margin_bottom( 6 );

    # Called as a function, not as a method. Pango::FontDescription::from_string
    # takes one argument, so the arrow form hands it the class name as well and
    # the binding drops the excess -- leaving a description of a font family
    # literally called 'Pango::FontDescription', which resolves to the default
    # UI font. It looked like it worked, because a fallback always does.
    $label->override_font( Pango::FontDescription::from_string( 'monospace' ) );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'automatic', 'automatic' );
    $scroll->set_shadow_type( 'in' );
    $scroll->set_vexpand( 1 );
    $scroll->add( $label );

    $box->pack_start( $scroll, 1, 1, 0 );

    # In the action area beside Close rather than over the text: it acts on the
    # whole box, and a button inside the box would suggest it acts on the
    # selection.
    $dialog->add_button( '_Copy', COPY_RESPONSE ) if defined $arg{ copy };

    $dialog->get_content_area->add( $box );
    $dialog->show_all;

    # Every response ends gtk_dialog_run, Copy included, so it has to be run
    # again afterwards -- otherwise copying closes the window, which is the
    # one thing a Copy button must not do.
    while ( 1 )
    {
        my $answer = $dialog->run;

        last unless defined $answer && "$answer" eq COPY_RESPONSE;

        $self->_to_clipboard( $arg{ copy } );
    }

    $dialog->destroy;

    return;
}

sub _to_clipboard
{
    my ( $self, $text ) = @_;

    my $clipboard =
        Gtk3::Clipboard::get( Gtk3::Gdk::Atom::intern( 'CLIPBOARD', 0 ) );
    $clipboard->set_text( $text, -1 );

    $self->_status( 'Copied to the clipboard.' );

    return;
}

# ---------------------------------------------------------------------------
# Feedback

sub _busy
{
    my ( $self, $busy, $message ) = @_;

    if ( $busy )
    {
        $self->{ spinner }->start;
        $self->{ spinner_label }->set_text( $message // 'Rendering…' );
        $self->{ spinner_badge }->show;
        $self->_set_apply( STOP_ICON, '_Stop',
            'Abandon this render. The settings are untouched' );
        $self->_status( $message ) if defined $message;
    }
    else
    {
        $self->{ spinner }->stop;
        $self->{ spinner_badge }->hide;
        $self->_set_apply( APPLY_ICON, '_Apply',
                  'Render the pipeline and show the result. '
                . 'Nothing on the left takes effect until this is pressed' );
    }

    $self->_sync_actions;
    return;
}

# Apply and Stop are one button wearing two hats, so all three things that
# say which hat it has on change together. The tooltip is included because a
# button labelled Stop that still explains how to start is worse than none.
sub _set_apply
{
    my ( $self, $icon, $label, $tooltip ) = @_;

    $self->{ apply_icon }->set_from_icon_name( $icon, 'button' );
    $self->{ apply_label }->set_text_with_mnemonic( $label );
    $self->{ b_apply }->set_tooltip_text( $tooltip );

    return;
}

sub _status
{
    my ( $self, $text ) = @_;
    $self->{ status }->set_text( $text );
    return;
}

sub _report
{
    my ( $self, $message ) = @_;

    $message = 'unknown error' unless defined $message && length $message;
    $message =~ s/\s+\z//;

    $self->{ infobar_label }->set_text( $message );
    $self->{ infobar }->show;

    # Also on stderr: a message that scrolled past in the info bar is still
    # wanted when the interface is being run from a terminal.
    warn "glitchvape-gui: $message\n";

    return;
}

sub _confirm
{
    my ( $self, $question ) = @_;

    my $dialog = Gtk3::MessageDialog->new( $self->{ window },
        'modal', 'question', 'ok-cancel', '%s', $question );

    my $answer = $dialog->run;
    $dialog->destroy;

    return $answer eq 'ok';
}

sub _sync_actions
{
    my ( $self ) = @_;

    my $have  = defined $self->{ state };
    my $busy  = $self->{ render }->busy;
    my $ready = $have && !$busy;

    $self->{ b_undo }->set_sensitive( $ready && $self->{ state }->can_undo );
    $self->{ b_redo }->set_sensitive( $ready && $self->{ state }->can_redo );
    $self->{ b_export }->set_sensitive( $ready );

    my $soundtrack = $self->_on_soundtrack_page;

    # Adjust acts on the selected effect, so it is only an action on the page
    # that has effects on it, and only once one is picked. Without this it is
    # a button that does nothing and says nothing about why.
    $self->{ b_adjust }->set_sensitive( $ready
            && !$soundtrack
            && defined $self->_selected_effect );
    $self->{ m_preset }->set_sensitive( $have );
    $self->{ m_clear }->set_sensitive( $ready );
    $self->{ m_command }->set_sensitive( $have );
    $self->{ m_seed }->set_sensitive( $have );
    $self->{ b_apply }->set_sensitive( $have );

    my $animated = $self->{ animate };

    # The soundtrack page says why it is empty rather than emptying. Nothing
    # is cleared here -- $self->{audio} is untouched -- so a mix put together
    # with Animate on is still there after switching it off and on again.
    $self->{ audio_stack }
        ->set_visible_child_name( $animated ? 'ready' : 'needs-animation' );

    # One button, two meanings, so it says which one it currently has. On the
    # soundtrack page with no animation to carry a track it is not an action
    # at all -- which is the same thing the page itself is saying.
    if ( $soundtrack )
    {
        $self->{ b_add }->set_sensitive( $ready && $animated );
        $self->{ b_add }
            ->set_tooltip_text( 'Add a track to the soundtrack (Alt+D)' );
    }
    else
    {
        $self->{ b_add }->set_sensitive( $ready );
        $self->{ b_add }
            ->set_tooltip_text( 'Add an effect to the pipeline (Alt+D)' );
    }

    # There is one file at most, so its line in the popover goes away once it
    # has been used; generated tracks stack, so theirs never do.
    if ( my $file = $self->{ audio_add_file } )
    {
        $file->set_visible( !GlitchVape::Audio::has_file( $self->{ audio } ) );
    }

    $self->_rebuild_audio_rows;

    # Muting is about listening rather than about rendering, so it stays
    # available whenever there is an animation to listen to -- and says
    # nothing about what will be exported.
    $self->{ b_mute }->set_sensitive( $animated );

    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::State> for why undo works the way it does,
L<GlitchVape::GUI::Cache> for what makes it fast, and L<glitchvape> for the
command-line tool this is a front end to.

=cut
