package GlitchVape::GUI;

use strict;
use warnings;

# This file contains literal '…' and '·' in button and status text. Without
# this the source bytes are read as Latin-1, and Glib -- which encodes Perl
# strings to UTF-8 on the way into Gtk -- would encode them a second time,
# putting mojibake on the buttons. The same reason bin/glitchvape does it.
use utf8;

use Encode         ();
use File::Basename qw(basename);
use File::Spec     ();
use POSIX          ();

use Glib ();
use Gtk3 ();

use GlitchVape                    ();
use GlitchVape::Audio             ();
use GlitchVape::Config            ();
use GlitchVape::Fonts             ();
use GlitchVape::Generator         ();
use GlitchVape::IO                ();
use GlitchVape::Registry          ();
use GlitchVape::Tools             ();
use GlitchVape::GUI::About        ();
use GlitchVape::GUI::Adjust       ();
use GlitchVape::GUI::Audio        ();
use GlitchVape::GUI::CommandLine  ();
use GlitchVape::GUI::Cache        ();
use GlitchVape::GUI::Export       ();
use GlitchVape::GUI::Preferences  ();
use GlitchVape::GUI::Prefs        ();
use GlitchVape::GUI::Deps         ();
use GlitchVape::GUI::ExportWizard ();
use GlitchVape::GUI::Profiles     ();
use GlitchVape::GUI::Generated    ();
use GlitchVape::GUI::Params       ();
use GlitchVape::GUI::Preview      ();
use GlitchVape::GUI::Render       ();
use GlitchVape::GUI::State        ();
use GlitchVape::GUI::Wizard       ();

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

=head2 ANOTHER PHOTOGRAPH IS ANOTHER WINDOW

Open used to replace the state, which meant that opening a second photograph
threw away the pipeline, the soundtrack and the whole undo history of the
first one -- silently, and with no way back, since the history went with it.
Nothing else in this program can destroy that much in one click.

So Open starts a second copy of the program on the new file and leaves this
one alone. The first Open in a window is the exception: there is nothing to
lose yet, so the empty window fills itself rather than spawning a second one
and leaving an empty one behind.

That is a rule about whether anything is open, not about whether anything has
been done to it. "Have you changed enough to be worth keeping" is a question
this program cannot answer for somebody -- an untouched photograph and a
fifteen-effect pipeline are the same click away from being lost -- and a
window that sometimes replaces what is in it is worse than one that never
does, because the only way to find out which is to lose the work.

The new instance is a new process rather than a second window in this one:
every window would otherwise share this process's cache, its render child and
its preferences, and the reason this program forks for every render (see
L<GlitchVape::GUI::Render>) is that its state does not survive being shared.
A process per photograph needs none of that reasoning to hold.

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
    program => path        this program, for opening a second window with

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

        # How to start another copy of this program -- see L</ANOTHER
        # PHOTOGRAPH IS ANOTHER WINDOW>. Told rather than worked out from
        # $0, which is the launcher's fact to know and not this module's to
        # guess at.
        program => $arg{ program },

        # The settings popover, built on first use because it hangs off a
        # button that does not exist yet. One of them: see
        # GlitchVape::GUI::Adjust/WHY A POPOVER AND NOT A WINDOW.
        adjust       => undef,
        loading      => 0,
        preview_size => 720,
        animate      => 0,
        audio        => undef,

        # Read once, here, and written back whenever the Preferences window
        # changes one. The three below are copies of preferences that the
        # rest of the window already reads by these names; keeping the copies
        # rather than reaching into the hash everywhere means the preference
        # file is the only thing that had to learn about them.
        prefs  => GlitchVape::GUI::Prefs::load(),
        export => GlitchVape::GUI::Export::defaults(),
    }, $class;

    $self->{ frames } = $self->{ prefs }{ frames };
    $self->{ fps }    = $self->{ prefs }{ fps };
    $self->{ muted }  = $self->{ prefs }{ muted };

    # The frame rate belongs to both dialogs -- see
    # GlitchVape::GUI::Export/Frame rate is one setting, shown twice -- and
    # this is the copy either of them edits.
    $self->{ export }{ fps } = $self->{ fps };

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

    # cleanup always: it removes this session's scratch files, which nothing
    # else will. purge is the cache itself, and that is the preference.
    $self->{ cache }->cleanup;
    $self->{ cache }->purge if $self->{ prefs }{ clear_cache_on_exit };

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

    # delete-event fires before destroy and can refuse it: true stops the
    # close. Hooking destroy instead would be too late, the window already
    # being on its way out by the time anybody was asked.
    $win->signal_connect(
        'delete-event' => sub {
            return $self->_confirm_close ? 0 : 1;
        }
    );

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

    # pack_end fills from the right, so the first packed sits outermost: the
    # menu is hard against the window controls and Export is inboard of it.
    $bar->pack_end( $self->_build_menu );
    $bar->pack_end( $export );

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

    # Grouped by what an entry is for rather than by how often it is reached:
    # move through the picture, then change it, then keep it, then throw
    # something away, then settings, then things that only tell you something,
    # then About. A separator between each, so the grouping is visible rather
    # than merely intended.
    #
    # Undo and Redo are in the header bar as well. They are here because a menu
    # is where a keyboard-first user looks for them and because their being
    # absent from a menu that has everything else reads as an omission, not as
    # a statement that the buttons are enough.
    for my $item (
        [ 'Undo', sub { return $self->_step_history( 'undo' ) }, 'undo' ],
        [ 'Redo', sub { return $self->_step_history( 'redo' ) }, 'redo' ],
        undef,
        [ 'Randomize', sub { return $self->_randomize }, 'seed' ],
        undef,
        [ 'Save as preset…', sub { return $self->_save_preset }, 'preset' ],
        undef,
        [
            'Reset all effects to defaults',
            sub { return $self->_reset_effects },
            'reset'
        ],
        [ 'Clear all effects', sub { return $self->_clear_effects }, 'clear' ],
        [ 'Clear preview cache', sub { return $self->_clear_cache } ],
        undef,
        [ 'Preferences…',     sub { return $self->_preferences } ],
        [ 'Export profiles…', sub { return $self->_export_profiles } ],
        undef,
        [ 'Check dependencies…', sub { return $self->_show_deps } ],
        [
            'Copy command line…', sub { return $self->_copy_command },
            'command'
        ],
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

            # The popover belongs to a list that is no longer on screen, and
            # being non-modal it would otherwise stay up over the other page.
            $self->{ adjust }->popdown if $self->{ adjust };

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
#
# Two faces, like the soundtrack page: the list, and -- when the pipeline is
# empty -- a line saying how to fill it. An empty pane with a heading over
# nothing does not say whether there is something to do or something wrong.
sub _build_image_page
{
    my ( $self ) = @_;

    my $stack = Gtk3::Stack->new;
    $stack->set_transition_type( 'crossfade' );
    $stack->set_transition_duration( 120 );

    $stack->add_named(
        _empty_page(
            'applications-graphics-symbolic',
            "Use the '+' button to add effects or apply a preset."
        ),
        'empty'
    );

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
    # Adjust button acts on and what a column of hand-packed boxes could not
    # express. Rows carry a checkbox and a remove button and nothing else; the
    # parameters are in the Adjust popover, which follows this selection.
    my $list = Gtk3::ListBox->new;
    $list->set_selection_mode( 'single' );

    # No row activation. Settings are the Adjust button's popover, which
    # follows the selection -- so selecting is the whole gesture, and a double
    # click would be a second way to do what one click has already done.
    $list->signal_connect(
        'row-selected' => sub {
            $self->_follow_selection;
            return;
        }
    );

    # Stage headings. GtkListBox draws these itself, from a function it calls
    # per row -- so they are not rows: they cannot be selected, cannot be
    # counted as effects, and cannot be left behind by a rebuild.
    $list->set_header_func( sub { $self->_stage_header( @_ ); return } );

    $self->{ effect_list } = $list;
    $box->pack_start( $list, 0, 0, 0 );

    $scroll->add( $box );
    $stack->add_named( $scroll, 'ready' );

    $self->{ effect_stack } = $stack;

    return $stack;
}

# The empty face of either page: an icon over a line of explanation, centred.
#
# One helper because the two pages are saying the same kind of thing -- what
# this pane would hold, and what to do about it being empty -- and two
# hand-built columns would drift apart in spacing the first time either was
# touched.
sub _empty_page
{
    my ( $icon_name, $text ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 12 );
    $box->set_halign( 'center' );
    $box->set_valign( 'center' );
    $box->set_border_width( 24 );

    my $icon = Gtk3::Image->new_from_icon_name( $icon_name, 'dialog' );
    $icon->get_style_context->add_class( 'dim-label' );

    my $label = Gtk3::Label->new( $text );
    $label->set_line_wrap( 1 );
    $label->set_justify( 'center' );
    $label->set_max_width_chars( 28 );
    $label->get_style_context->add_class( 'dim-label' );

    $box->pack_start( $icon,  0, 0, 0 );
    $box->pack_start( $label, 0, 0, 0 );

    return $box;
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

    # The bar only appears for a render that has frames to count -- see
    # _progress. A still is one step, and a bar with one step in it says
    # nothing a spinner has not already said.
    my $bar = Gtk3::ProgressBar->new;
    $bar->set_size_request( 160, -1 );
    $bar->set_valign( 'center' );
    $bar->set_no_show_all( 1 );

    my $text = Gtk3::Box->new( 'vertical', 4 );
    $text->pack_start( $label, 0, 0, 0 );
    $text->pack_start( $bar,   0, 0, 0 );

    $badge->pack_start( $spinner, 0, 0, 0 );
    $badge->pack_start( $text,    0, 0, 0 );

    # Hidden rather than faded: it is over the picture now, not in a row of
    # buttons whose widths it would disturb, so there is nothing to hold a
    # place for.
    #
    # The contents are shown once, here, because set_no_show_all stops
    # show_all descending into the badge later -- so _busy shows the badge
    # itself and the two widgets inside it are already visible.
    $spinner->show;
    $label->show;
    $text->show;
    $badge->set_no_show_all( 1 );

    $overlay->add_overlay( $badge );
    $overlay->set_overlay_pass_through( $badge, 1 );

    $self->{ spinner }       = $spinner;
    $self->{ spinner_badge } = $badge;
    $self->{ spinner_label } = $label;
    $self->{ spinner_bar }   = $bar;

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

    # The icon is the same one a track carries in the list, so the empty page
    # and the full one are visibly about the same thing.
    $stack->add_named(
        _empty_page(
            'audio-x-generic-symbolic',
            'You must enable video animation if you want to add the sound.'
        ),
        'needs-animation'
    );

    $stack->add_named(
        _empty_page(
            'audio-x-generic-symbolic',
            "Use the '+' button to add a soundtrack."
        ),
        'empty'
    );

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

    # Nothing to activate, as on the effect list: settings are the action
    # bar's Adjust button, which acts on whichever list is showing.
    $list->signal_connect(
        'row-selected' => sub {
            $self->_sync_actions;
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
                GlitchVape::Generator::icon( $kind ),
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

# One line per thing in the soundtrack: the file if there is one, then each
# generated track in the order it will be described.
sub _rebuild_audio_rows
{
    my ( $self ) = @_;

    my $audio = $self->{ audio };

    # Only when the mix has actually changed.
    #
    # This is reached from _sync_actions, which runs on every selection
    # change -- and selecting a row would otherwise destroy that very row
    # from inside its own signal handler, which leaves the list drawing
    # widgets it no longer holds. The signature is what the rows would say,
    # so anything that changes a row changes it.
    my $signature = join "\n",
        map { GlitchVape::Generator::describe( $_ ) }
        GlitchVape::Audio::generated( $audio );

    $signature =
        GlitchVape::Audio::describe( { %$audio, generated => undef } )
        . "\n$signature"
        if GlitchVape::Audio::has_file( $audio );

    return
        if defined $self->{ audio_signature }
        && $self->{ audio_signature } eq $signature;

    $self->{ audio_signature } = $signature;

    $_->destroy for $self->{ audio_list }->get_children;

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

        $self->{ audio_list }->add(
            $self->_audio_row(
                GlitchVape::Generator::icon( $made[ $n ]{ kind } ),
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
# again on the right, and its settings behind the same Adjust button the
# effects use. One gesture for both lists -- select, then press the cog.
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
    $label->set_tooltip_text( $tip );

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

    # Two lines, which t/26-gui-layout.t holds every tooltip to. The long
    # version of this is next to the switch in Preview settings now, so this
    # one keeps the fact that matters and points at the room.
    $mute->set_tooltip_text( "Play the preview silently; the export keeps "
            . "its sound.\nAlso in Preview settings." );
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

    # Destroying the rows clears the selection, and re-adding them sets it
    # again -- both of which emit row-selected. Left unguarded the first one
    # tells the popover that nothing is selected and it closes, so rebuilding
    # the list for an unrelated reason would put away settings somebody was
    # in the middle of using.
    $self->{ rebuilding }++;

    $_->destroy for $list->get_children;
    $self->{ rows } = {};

    unless ( $self->{ state } )
    {
        $self->{ rebuilding }--;
        $self->{ adjust }->popdown if $self->{ adjust };
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

    $self->{ rebuilding }--;

    # The popover is showing values an undo or a preset may have just
    # replaced, and may be showing an effect that is no longer here at all --
    # refresh handles both, closing itself in the second case.
    $self->{ adjust }->refresh if $self->{ adjust };

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

=head2 WHY THE LIST IS BANDED

The pipeline is sorted by stage and the rows cannot be dragged, so an effect
added to the list appears wherever its stage falls rather than where it was
dropped. Without something to say why, that is a list which rearranges itself
and refuses to be rearranged -- the worst reading available, and the one a
plain sorted list invites.

Under stage headings it is nine bands with effects in them, and the order
belongs to the bands rather than to the rows. The heading carries the stage's
reason for running where it does, from
L<GlitchVape::Registry/STAGE_INFO>, so the answer is one hover away from the
question.

Only the occupied stages appear, which is what a header function gives for
free: it is asked about a row and the row before it, so a stage with nothing
in it is never mentioned.

=cut

sub _stage_header
{
    my ( $self, $row, $before ) = @_;

    my $stage = $self->_stage_of( $row );
    return unless defined $stage;

    # Same band as the row above: the heading is already up there.
    if ( defined $before )
    {
        my $above = $self->_stage_of( $before );
        if ( defined $above && $above eq $stage )
        {
            $row->set_header( undef );
            return;
        }
    }

    my $info = GlitchVape::Registry->stage_info( $stage ) or return;

    my $label = Gtk3::Label->new;
    $label->set_markup(
        sprintf q{<span alpha='60%%'><b>%s</b></span>},
        Glib::Markup::escape_text( uc $info->{ title } )
    );
    $label->set_xalign( 0 );

    # The margin is above rather than around, so the heading sits with the
    # rows it introduces instead of floating between two bands.
    $label->set_margin_top( 10 );
    $label->set_margin_bottom( 2 );
    $label->set_margin_start( 6 );

    $label->set_tooltip_text(
        sprintf "%s\n\nRuns %s in the chain: %s",
        $info->{ blurb },
        _stage_position( $stage ),
        $info->{ because }
    );

    $label->show_all;
    $row->set_header( $label );

    return;
}

sub _stage_of
{
    my ( $self, $row ) = @_;

    my $name = $row->{ effect }                   or return undef;
    my $spec = GlitchVape::Registry->get( $name ) or return undef;

    return $spec->{ stage };
}

# 'fifth of nine', so that a heading says where in the chain it is without
# the list having to show the seven stages that are empty.
sub _stage_position
{
    my ( $stage ) = @_;

    my @stages = GlitchVape::Registry->stages;

    my $at = 0;
    for my $n ( 0 .. $#stages )
    {
        $at = $n + 1 if $stages[ $n ] eq $stage;
    }

    return sprintf '%d of %d', $at, scalar @stages;
}

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

            # The same fact is on the switch in the popover, when the popover
            # happens to be showing this effect.
            my $adjust = $self->{ adjust };
            if ( $adjust && ( $adjust->effect // q{} ) eq $name )
            {
                $adjust->set_enabled( $on );
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
        sprintf "%s\n%s stage",
        $spec->{ summary },
        $stage->{ title }
    );

    my $remove = _icon_button( 'list-remove-symbolic',
        "Remove $spec->{title} from this pipeline" );
    $remove->set_relief( 'none' );
    $remove->set_valign( 'center' );
    $remove->signal_connect(
        clicked => sub {

            # _rebuild_effects refreshes the popover, which closes itself if
            # this was the effect it had been showing.
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
# The settings popover

# The effect whose row is selected, or undef.
sub _selected_effect
{
    my ( $self ) = @_;

    my $row = $self->{ effect_list }->get_selected_row or return undef;
    return $row->{ effect };
}

# The one popover, built on first use because it hangs off a button the panes
# build. There is only ever one: see GlitchVape::GUI::Adjust/WHY A POPOVER AND
# NOT A WINDOW.
sub _adjust
{
    my ( $self ) = @_;

    $self->{ adjust } ||= GlitchVape::GUI::Adjust->new(
        relative_to => $self->{ b_adjust },
        state       => $self->{ state },
        on_change   => sub {
            $self->_touch;
            return;
        },
        on_enabled => sub {
            my ( $name, $on ) = @_;

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
    );

    # The popover outlives any one state -- a new file is a new state and the
    # same popover -- so it is told which one to write to rather than being
    # rebuilt.
    $self->{ adjust }{ state } = $self->{ state };

    return $self->{ adjust };
}

# Adjust, pressed.
#
# Like Add, it acts on whichever page is showing, so there is one gesture for
# both lists: select a row, press the cog. On the soundtrack that reopens the
# track's own wizard, which stays a dialog -- it has a real Cancel, and
# building a track is a decision you can back out of in a way that moving a
# slider is not.
#
# On the effect page it toggles, because the popover is not modal and will not
# dismiss itself: without this there would be no way to put it away with the
# control that summoned it.
sub _adjust_selected
{
    my ( $self ) = @_;

    if ( $self->_on_soundtrack_page )
    {
        $self->_edit_selected_track;
        return;
    }

    my $adjust = $self->_adjust;

    if ( $adjust->visible )
    {
        $adjust->popdown;
        return;
    }

    my $name = $self->_selected_effect or return;
    $adjust->show_effect( $name );

    return;
}

# The selected track's row remembers how to reopen whatever made it -- the
# crop wizard for the file, the generator's own dialog for the rest.
sub _edit_selected_track
{
    my ( $self ) = @_;

    my $row  = $self->{ audio_list }->get_selected_row or return;
    my $edit = $row->{ edit }                          or return;

    $edit->();

    return;
}

# The selection moved. The popover shows the selected effect, so if it is up
# it changes what it is showing rather than being left describing a row nobody
# is looking at any more.
sub _follow_selection
{
    my ( $self ) = @_;

    # The list is being rebuilt underneath, and the selection it reports on
    # the way through is not one anybody made.
    return if $self->{ rebuilding };

    my $adjust = $self->{ adjust };

    if ( $adjust && $adjust->visible )
    {
        my $name = $self->_selected_effect;

        if   ( defined $name ) { $adjust->show_effect( $name ) }
        else                   { $adjust->popdown }
    }

    $self->_sync_actions;
    return;
}

# One edit to the configuration. Every path that changes what would be
# rendered ends here, so that the actions agree with the new state -- Adjust
# in particular, which is only an action while a row is selected and so has to
# be re-decided after a rebuild that dropped the selection.
#
# It does not render: what has changed is the configuration, and the picture
# on screen is still the last one asked for. Applying is a separate gesture
# because it is the one with a render bill attached.
sub _touch
{
    my ( $self ) = @_;

    $self->{ dirty } = 1;
    $self->_sync_actions;

    return;
}

# ---------------------------------------------------------------------------
# Files

# What our own exec reports when it fails, which is the one status this
# program never exits with of its own accord -- so a child that comes back
# with it failed to become the new instance, and anything else is that
# instance living its own life and eventually being closed.
use constant EXEC_FAILED => 127;

sub _choose_input
{
    my ( $self ) = @_;

    # Decided before the dialog is built rather than after it returns, so the
    # title can say which of the two this is. Being told afterwards that a
    # second window has appeared is a surprise; being told beforehand is an
    # answer to "will this cost me what I have open".
    my $elsewhere = $self->_has_source;

    my $title = 'Open image';
    $title = 'Open image in a new window' if $elsewhere;

    my $dialog = Gtk3::FileChooserDialog->new( $title, $self->{ window },
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

        return $self->_open_elsewhere( $path ) if $elsewhere;

        $self->_open_file( $path );
        return;
    }

    $dialog->destroy;
    return;
}

# An argument on its way to exec. A path out of the file chooser is character
# data -- 'Zdjęcie.png' is six characters and eight bytes -- and exec passes
# the internal form, which is the right bytes with a "Wide character" warning
# attached. Encoding it here says what is meant, and matches the decode
# bin/glitchvape-gui does to @ARGV on the way back in.
#
# Only when it is characters: $program comes from FindBin, which reads the
# filesystem and hands back bytes. Encoding those again would spell a
# non-ASCII directory name twice over.
sub _argv_bytes
{
    my ( $text ) = @_;

    return $text unless utf8::is_utf8( $text );
    return Encode::encode( 'UTF-8', $text );
}

sub _has_source
{
    my ( $self ) = @_;

    return 0 unless $self->{ state };
    return 0 unless defined $self->{ state }->source;

    return 1;
}

=head2 _open_elsewhere( $path )

Start a second instance of this program on C<$path>, leaving this one exactly
as it was. See L</ANOTHER PHOTOGRAPH IS ANOTHER WINDOW>.

The fork is safe where the render's is delicate: this child does nothing but
C<exec>, so it never reaches an ImageMagick call with an inherited thread pool
-- which is the hazard L<GlitchVape::GUI::Render> exists to avoid.

Never falls back to opening the file in this window. The fallback would be
the exact thing this exists to prevent, so a failure is reported and the work
stays put.

=cut

sub _open_elsewhere
{
    my ( $self, $path ) = @_;

    my $program = $self->{ program };

    unless ( defined $program && length $program && -e $program )
    {
        $self->_report( 'Cannot find glitchvape-gui to open a second window '
                . 'with, so nothing was opened.' );
        return 0;
    }

    my $pid = fork;

    unless ( defined $pid )
    {
        $self->_report( "Cannot start a second window: $!" );
        return 0;
    }

    unless ( $pid )
    {
        # The same interpreter, so a checkout started with a particular perl
        # gets that perl again; the script re-derives its own lib path.
        #
        # _exit, not exit or die: this process is a launcher that failed, and
        # running the parent's END blocks or flushing its buffers from here
        # would be a second copy of everything it has to say.
        exec { $^X } $^X, map { _argv_bytes( $_ ) } $program, $path
            or POSIX::_exit( EXEC_FAILED );
    }

    # Reaped so it does not stand as a zombie for as long as this window
    # lives. The status is worth reading only for our own sentinel: any other
    # is the new window being closed, minutes or hours from now, which is not
    # news.
    Glib::Child->watch_add(
        $pid,
        sub {
            my ( undef, $status ) = @_;

            if ( ( $status >> 8 ) == EXEC_FAILED )
            {
                $self->_report(
                    'Could not start a second window; nothing was opened.' );
            }

            return 0;
        }
    );

    $self->_status( sprintf 'Opened %s in a new window', basename( $path ) );

    return 1;
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

    # The wizard, not a file chooser. Everything it asks used to be settled
    # somewhere else and days earlier -- in a menu dialog that had to be
    # visited first and said nothing about the export it was for. Asking on
    # the way through puts the decisions where they are made.
    GlitchVape::GUI::ExportWizard->run(
        parent   => $self->{ window },
        animated => $self->{ animate },
        source   => $self->{ state }->source,
        preset   => $self->{ state }->preset,

        # The frame rate lives in one place and two windows edit it, so the
        # live value goes in rather than whatever this hash last held.
        settings => {
            %{ $self->{ export } },
            fps    => $self->{ fps },
            frames => $self->{ frames },
        },

        on_done => sub {
            my ( $settings, $path ) = @_;

            # Kept, so the next export opens where this one left off and the
            # copied command line matches what was just written.
            $self->{ export } = $settings;
            $self->{ fps }    = $settings->{ fps }    if $settings->{ fps };
            $self->{ frames } = $settings->{ frames } if $settings->{ frames };

            $self->_export( $path );
            return;
        },
    );

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

        # Preferences rather than export settings: these are answers about
        # the program, not about this file, so they are the same for every
        # export until somebody changes them in Preferences.
        $self->_export_prefs,

        # An export is the long one: full size rather than preview size, so
        # the frames it counts are the slowest this program renders.
        on_progress => sub {
            $self->_progress( @_ );
            return;
        },

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

# The preferences GlitchVape::render takes, as a list to splice into the call.
#
# Watermarking and metadata are both "what this program does to a file it
# writes", and neither belongs in an export profile: a profile is a size and a
# container, and somebody switching from MP4 to WebM is not saying anything
# about whether their GPS coordinates should travel with it.
sub _export_prefs
{
    my ( $self ) = @_;

    my $prefs = $self->{ prefs } || {};

    return (
        watermark => $prefs->{ watermark },
        metadata  => ( $prefs->{ metadata_keep }   ? 'keep' : 'strip' ),
        credit    => ( $prefs->{ metadata_credit } ? 1      : 0 ),
    );
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
# Every effect in the pipeline back to what it declares, in one step.
#
# Beside Clear all effects rather than beside Undo, because it is the same
# kind of act: throwing away work on the pipeline. The difference is which
# work -- Clear throws away which effects are in it, this throws away what
# they were set to and keeps the pipeline.
#
# One history entry for the lot. Fifteen effects reset one at a time would be
# fifteen presses of Undo to get back, which is not an undo anybody would use.
# Whether any effect in the pipeline has been moved off its declaration.
sub _anything_moved
{
    my ( $self ) = @_;

    return 0 unless $self->{ state };

    my $effects = $self->{ state }->effects;

    for my $name ( keys %$effects )
    {
        return 1
            unless GlitchVape::Registry->at_defaults( $name,
            $effects->{ $name }{ params } || {} );
    }

    return 0;
}

sub _reset_effects
{
    my ( $self ) = @_;

    return unless $self->{ state };

    my $effects = $self->{ state }->effects;

    for my $name ( keys %$effects )
    {
        $effects->{ $name }{ params } =
            GlitchVape::Registry->resolve_params( $name, {} );
    }

    # The preset is a claim about the parameters as much as about which
    # effects are in the pipeline, and it is no longer true of these.
    $self->{ state }->preset( undef );

    $self->_reload_widgets;
    $self->_touch;

    return;
}

sub _clear_effects
{
    my ( $self ) = @_;

    return unless $self->{ state };

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

    # Before the commit, so the new seed is part of the history entry this
    # Apply makes: undo then steps back to the render that had the old one,
    # rather than to a configuration that no longer describes any picture.
    #
    # Here and not in _render, because _render is also how undo and redo put a
    # stored configuration back on screen -- reseeding there would make
    # stepping through the history change the pictures it was stepping to.
    if ( $self->{ prefs }{ randomize_each_render } )
    {
        $self->{ state }->seed( int rand 2**31 );
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

    # Only if the preference says to show it. Off, the preview is the picture
    # the pipeline made and the mark appears in the exported file alone --
    # which is the honest reading of "show watermark in preview" being a
    # separate switch from the watermark itself.
    my $mark = $self->{ prefs }{ watermark };
    $mark = 'none' unless $self->{ prefs }{ watermark_preview };

    $self->{ render }->preview(
        state       => $self->{ state },
        size        => $size,
        animate     => $spec,
        watermark   => $mark,
        on_progress => sub {
            $self->_progress( @_ );
            return;
        },
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
sub _preferences
{
    my ( $self ) = @_;

    GlitchVape::GUI::Preferences->run(
        parent => $self->{ window },
        prefs  => $self->{ prefs },

        on_change => sub {
            my ( $prefs, $what ) = @_;

            # Saved on every change rather than on Close, because Close is
            # not a commit -- see GlitchVape::GUI::Preferences/CHANGES APPLY
            # AS THEY ARE MADE. A window killed with the settings unwritten
            # would be the one case where the dialog lied.
            GlitchVape::GUI::Prefs::save( $prefs );

            $self->_adopt_prefs( $what );
            return;
        },
    );

    return;
}

# The preferences that something in the window is already holding a copy of,
# put back where that copy lives. Called with the key that moved, or 'all'
# after a restore.
sub _adopt_prefs
{
    my ( $self, $what ) = @_;

    my $every = !defined $what || $what eq 'all';

    $self->{ frames } = $self->{ prefs }{ frames }
        if $every || $what eq 'frames';

    if ( $every || $what eq 'fps' )
    {
        $self->{ fps } = $self->{ prefs }{ fps };
        $self->{ export }{ fps } = $self->{ fps };
    }

    if ( $every || $what eq 'muted' )
    {
        my $on = $self->{ prefs }{ muted } ? 1 : 0;

        $self->{ muted } = $on;
        $self->{ preview }->set_muted( $on );
        $self->{ b_mute }->set_active( $on );
    }

    # A watermark shown in the preview is part of the picture as far as the
    # cache is concerned, so changing either of these invalidates what is on
    # screen and the render has to be asked for again.
    if ( $every || $what =~ /^watermark/ )
    {
        $self->_status( 'Watermark changed. Press Apply to see it.' );
    }

    return;
}

# What Export writes and at what size. Behind the menu for the same reason the
# animation settings are: set once, then left, while the button they govern is
# in the header bar where the decision to export at all gets made.
sub _export_profiles
{
    my ( $self ) = @_;

    GlitchVape::GUI::Export->manage(
        parent => $self->{ window },

        on_done => sub {
            my ( $profiles ) = @_;

            my $mine = grep { !$_->{ builtin } } @$profiles;

            $self->_status(
                sprintf 'Export profiles: %d in all, %d of them yours.',
                scalar @$profiles, $mine );
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

    GlitchVape::GUI::Deps->run( parent => $self->{ window } );

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

        # Cleared per render rather than per frame: the bar and the timings
        # behind the estimate both belong to one render, and a still leaves
        # the bar hidden entirely because nothing will ever call _progress.
        $self->{ progress_seen } = [];
        $self->{ spinner_bar }->set_fraction( 0 );
        $self->{ spinner_bar }->hide;

        $self->{ spinner_badge }->show;
        $self->_set_apply( STOP_ICON, '_Stop',
            'Abandon this render. The settings are untouched' );
        $self->_status( $message ) if defined $message;
    }
    else
    {
        $self->{ spinner }->stop;
        $self->{ spinner_bar }->hide;
        $self->{ spinner_badge }->hide;
        $self->_set_apply( APPLY_ICON, '_Apply',
                  'Render the pipeline and show the result. '
                . 'Nothing on the left takes effect until this is pressed' );
    }

    $self->_sync_actions;
    return;
}

# One frame of a loop has landed.
#
# The estimate is deliberately not shown for the first couple of frames. The
# first is slower than the rest -- it pays for decoding the source, which the
# others reuse -- so extrapolating from it alone promises a wait half again as
# long as the one that follows, and a figure that then falls steadily is worse
# than no figure at all.
#
# $total counts one past the frames, for the encode; see
# GlitchVape::GUI::Render/PROGRESS IS COUNTED IN FRAMES. That last step has no
# duration anybody can predict, so the wait is only estimated while frames
# remain.
sub _progress
{
    my ( $self, $done, $total ) = @_;

    return unless $total > 1;

    my $bar = $self->{ spinner_bar };
    $bar->set_fraction( $done / $total );
    $bar->show;

    $self->{ progress_seen } ||= [];
    push @{ $self->{ progress_seen } }, time;

    my $frames = $total - 1;

    if ( $done >= $frames )
    {
        $self->{ spinner_label }->set_text( 'Encoding…' );
        $self->_status( 'Encoding…' );
        return;
    }

    my $text = sprintf 'Frame %d of %d', $done, $frames;

    if ( my $remaining = $self->_estimate( $done, $frames ) )
    {
        $text .= sprintf ' · about %s left', $remaining;
    }

    $self->{ spinner_label }->set_text( $text );
    $self->_status( $text );

    return;
}

# Roughly how much longer, or undef while there is not enough to say.
#
# Measured from the second frame onwards for the reason above, and reported in
# whole units: a countdown that reads "about 12s left" is doing its job, and
# one that reads "11.6s" is claiming a precision the next frame will disprove.
sub _estimate
{
    my ( $self, $done, $frames ) = @_;

    my $seen = $self->{ progress_seen } or return undef;
    return undef if @$seen < 3;

    my $elapsed = $seen->[ -1 ] - $seen->[ 1 ];
    my $counted = @$seen - 2;
    return undef unless $counted > 0 && $elapsed > 0;

    my $each      = $elapsed / $counted;
    my $remaining = int( $each * ( $frames - $done ) + 0.5 );

    return undef if $remaining < 1;
    return sprintf '%ds', $remaining if $remaining < 60;

    return sprintf '%dm %02ds', int( $remaining / 60 ), $remaining % 60;
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

# What closing the window would throw away, named so the warning can say it
# rather than gesturing at "your work".
#
# Split out from the dialog because the decision is the interesting half and a
# dialog cannot be asked what it would have said. This returns the list; the
# dialog only arranges it into a sentence.
sub _unsaved
{
    my ( $self ) = @_;

    my @lost;

    my $effects = $self->{ state } ? scalar $self->{ state }->effect_names : 0;
    if ( $effects )
    {
        push @lost, $effects == 1 ? 'one effect' : "$effects effects";
    }

    my $tracks = scalar GlitchVape::Audio::generated( $self->{ audio } );
    $tracks++ if GlitchVape::Audio::has_file( $self->{ audio } );
    if ( $tracks )
    {
        push @lost, $tracks == 1 ? 'a soundtrack' : "$tracks tracks";
    }

    return @lost;
}

# Whether it is all right to close. False stops the window closing.
#
# Asked only when there is something to lose. A dialog on every close, most of
# which have nothing behind them, is one people learn to dismiss without
# reading -- and then it is not there when it matters.
#
# The source image is not in the list. Losing it costs one trip through Open,
# and naming it alongside a pipeline somebody spent ten minutes on suggests
# they are comparable.
sub _confirm_close
{
    my ( $self ) = @_;

    my @lost = $self->_unsaved;
    return 1 unless @lost;

    my $what = @lost > 1 ? join( ' and ', @lost ) : $lost[ 0 ];

    # Says which of it can still be rescued and by which menu entry, because
    # "are you sure" with no way back is a question the window already knows
    # the answer to.
    my $advice = '"Save as preset…" keeps the effects and their settings, '
        . 'and "Copy command line…" records the seed with them.';

    # Asked of the mix rather than of the sentence above it. Reading the answer
    # back out of prose means rewording the prose silently drops the advice,
    # and the wording is the part most likely to be revised.
    my $soundtrack = GlitchVape::Audio::has_file( $self->{ audio } )
        || scalar GlitchVape::Audio::generated( $self->{ audio } );

    if ( $soundtrack )
    {
        $advice .= ' The soundtrack is not part of a preset and would have '
            . 'to be put together again.';
    }

    my $dialog = Gtk3::MessageDialog->new( $self->{ window },
        'modal', 'warning', 'none', '%s', 'Close without saving?' );

    $dialog->format_secondary_text( "This window holds $what.\n\n$advice" );

    $dialog->add_button( 'Cancel', 'cancel' );

    my $discard = $dialog->add_button( 'Close without saving', 'ok' );
    $discard->get_style_context->add_class( 'destructive-action' );

    # Cancel, so that Escape and Return both keep the window rather than one
    # of them being the destructive answer.
    $dialog->set_default_response( 'cancel' );

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

    my $can_undo = $ready && $self->{ state }->can_undo;
    my $can_redo = $ready && $self->{ state }->can_redo;

    # The button and the menu entry are the same action seen twice, so they
    # are greyed together rather than one of them offering what the other
    # already refuses.
    $self->{ b_undo }->set_sensitive( $can_undo );
    $self->{ b_redo }->set_sensitive( $can_redo );
    $self->{ m_undo }->set_sensitive( $can_undo );
    $self->{ m_redo }->set_sensitive( $can_redo );
    $self->{ b_export }->set_sensitive( $ready );

    my $soundtrack = $self->_on_soundtrack_page;

    # Adjust acts on the selected row of whichever list is showing, so it is
    # an action once there is one to act on and not before. Without this it is
    # a button that does nothing and says nothing about why.
    my $selected =
        $soundtrack
        ? defined $self->{ audio_list }->get_selected_row
        : defined $self->_selected_effect;

    $self->{ b_adjust }->set_sensitive( $ready && $selected );
    $self->{ m_preset }->set_sensitive( $have );
    $self->{ m_clear }->set_sensitive( $ready );

    # Greyed while every effect already is at its defaults, the same argument
    # as the button in the settings popover: a menu entry that would do
    # nothing should say so rather than be chosen to find out.
    $self->{ m_reset }->set_sensitive( $ready && $self->_anything_moved );
    $self->{ m_command }->set_sensitive( $have );
    $self->{ m_seed }->set_sensitive( $have );
    $self->{ b_apply }->set_sensitive( $have );

    # The effect page says how to fill itself while there is nothing in it.
    # Driven from the state rather than from the row count so that it is
    # right before the first _rebuild_effects has run.
    my $has_effects = $have && scalar( $self->{ state }->effect_names );
    $self->{ effect_stack }
        ->set_visible_child_name( $has_effects ? 'ready' : 'empty' );

    my $animated = $self->{ animate };

    # Three faces, because there are three things the page can be saying.
    # Without an animation it explains what it is waiting for; with one and
    # nothing in it, how to fill it; otherwise it shows the mix.
    #
    # Nothing is cleared here -- $self->{audio} is untouched -- so a mix put
    # together with Animate on is still there after switching it off and on
    # again, and the page goes straight back to 'ready'.
    my $has_tracks = GlitchVape::Audio::has_file( $self->{ audio } )
        || scalar GlitchVape::Audio::generated( $self->{ audio } );

    my $page = 'needs-animation';
    if ( $animated )
    {
        $page = $has_tracks ? 'ready' : 'empty';
    }

    $self->{ audio_stack }->set_visible_child_name( $page );

    # One button, two meanings, so it says which one it currently has. On the
    # soundtrack page with no animation to carry a track it is not an action
    # at all -- which is the same thing the page itself is saying.
    if ( $soundtrack )
    {
        $self->{ b_add }->set_sensitive( $ready && $animated );
        $self->{ b_add }
            ->set_tooltip_text( 'Add a track to the soundtrack (Alt+D)' );
        $self->{ b_adjust }
            ->set_tooltip_text( 'Reopen the selected track (Alt+J)' );
    }
    else
    {
        $self->{ b_add }->set_sensitive( $ready );
        $self->{ b_add }
            ->set_tooltip_text( 'Add an effect to the pipeline (Alt+D)' );
        $self->{ b_adjust }->set_tooltip_text(
                  "Show the settings of the selected effect (Alt+J).\n"
                . 'Press again to put them away' );
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
