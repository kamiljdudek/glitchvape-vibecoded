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

use GlitchVape      ();
use GlitchVape::GUI ();

local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

# The arrangement of the window, rather than what any one control does. These
# are the properties a rearrangement is most likely to break quietly: a button
# that lost its tooltip, an accent that stopped applying, two controls
# answering the same key.

# No input file: the window builds without one, which is also what happens
# when the program is started from a desktop launcher.
my $gui = GlitchVape::GUI->new;
$gui->{ window }->show_all;
$gui->_sync_actions;

sub descendants
{
    my ( $widget, $class ) = @_;

    my @found;
    my $walk;
    $walk = sub {
        my ( $w ) = @_;
        push @found, $w if $w->isa( $class );
        $walk->( $_ )
            for ( $w->isa( 'Gtk3::Container' ) ? $w->get_children : () );
        return;
    };
    $walk->( $widget );

    return @found;
}

# ---------------------------------------------------------------------------
# The left pane ends in an action bar

{
    my @bars = descendants( $gui->{ window }, 'Gtk3::ActionBar' );

    is scalar @bars, 1, 'the window has exactly one action bar';

    my ( $bar ) = @bars;

    # Both buttons are in it, and both are outside the scrolled list, so a
    # long pipeline cannot scroll either of them out of reach.
    for my $key ( qw(b_add b_apply) )
    {
        my @up;
        my $w = $gui->{ $key };
        while ( $w = $w->get_parent ) { push @up, $w }

        ok scalar( grep { $_ == $bar } @up ), "$key is in the action bar";
        ok !scalar( grep { $_->isa( 'Gtk3::ScrolledWindow' ) } @up ),
            "$key cannot be scrolled out of sight";
    }
}

# The one destination action keeps its accent; the one that opens a dialog
# does not. A GtkActionBar is a container, not a style, so this survives being
# put in one -- which is the whole reason the accent could be kept.
{
    ok $gui->{ b_apply }->get_style_context->has_class( 'suggested-action' ),
        'Apply is still the suggested action inside the bar';
    ok !$gui->{ b_add }->get_style_context->has_class( 'suggested-action' ),
        'and Add effect is not competing with it';
}

# ---------------------------------------------------------------------------
# Everything in the bars says what it does

{
    my %expect = (
        b_add     => 'Add effect',
        b_adjust  => 'Adjust',
        b_apply   => 'Apply',
        b_animate => 'Animate',
        b_mute    => 'Mute',
    );

    for my $key ( sort keys %expect )
    {
        my $tip = $gui->{ $key }->get_tooltip_text;

        ok defined $tip && length $tip, "$expect{$key} has a tooltip";

        # Concise: a tooltip is read standing still with the mouse held, so
        # two lines is the budget.
        cmp_ok scalar( split /\n/, $tip ), '<=', 2,
            "$expect{$key}'s tooltip is at most two lines";
    }
}

# ---------------------------------------------------------------------------
# No two controls answer the same key

# Alt+A has been Apply since there was a window and Alt+E has been Export;
# adding buttons to the same window is exactly when a collision gets
# introduced, and a collision is silent -- Gtk simply cycles between them.
my %claimed;

{
    for my $label ( descendants( $gui->{ window }, 'Gtk3::Label' ) )
    {
        # Only a label pointing at a widget actually claims the key.
        next unless $label->get_mnemonic_widget;

        my $text = $label->get_label // q{};
        next unless $text =~ /_(\w)/;

        push @{ $claimed{ lc $1 } }, $text;
    }

    my @collisions = grep { @{ $claimed{ $_ } } > 1 } sort keys %claimed;

    is_deeply \@collisions, [],
        'no two controls in the main window claim the same mnemonic'
        or diag explain \%claimed;

    # And the ones that have always meant something still do.
    ok $claimed{ a } || $claimed{ s }, 'Apply (or Stop) claims a key';
    ok $claimed{ e },                  'Export is still Alt+E';
}

# ---------------------------------------------------------------------------
# The icon-only buttons kept their keys as accelerators

# Add, Adjust and Animate carry no label, so they claim no mnemonic and the
# check above cannot see them. The keys still have to work, and a key that
# quietly stops working is worse than one that never existed.
#
# Fired rather than merely declared -- accel_groups_activate returns true only
# if something actually answered -- because a group added to the wrong window
# would look identical to a group that works.
{
    for my $spec (
        [ 'd', 'b_add',     'Add effect' ],
        [ 'j', 'b_adjust',  'Adjust' ],
        [ 'n', 'b_animate', 'Animate' ],
        )
    {
        my ( $letter, $key, $what ) = @$spec;

        ok !$claimed{ $letter },
            "$what claims no mnemonic, having no label to put one in";

        ok Gtk3::accel_groups_activate( $gui->{ window },
            Gtk3::Gdk::keyval_from_name( $letter ), 'mod1-mask' ),
            "but Alt+\U$letter\E still reaches $what";
    }

    # Animate answered its accelerator above, which means it toggled. Put it
    # back before the tests that care what mode the window is in.
    $gui->{ b_animate }->set_active( 0 );
}

# ---------------------------------------------------------------------------
# The left pane is a stack of two lists

# Effects and soundtrack are both answers to "what goes into the render", so
# they are two pages of one stack rather than one list with a second bolted
# under it on the far side of the window.
{
    my ( $switcher ) = descendants( $gui->{ window }, 'Gtk3::StackSwitcher' );
    ok $switcher, 'the left pane has a stack switcher';

    my $stack = $gui->{ left_stack };
    isa_ok $stack, 'Gtk3::Stack', 'what it switches';

    ok $stack->get_child_by_name( 'image' ),      'holding an Image page';
    ok $stack->get_child_by_name( 'soundtrack' ), 'and a Soundtrack page';
    my @pages = $stack->get_children;
    is scalar @pages, 2, 'and no others';

    # The titles are what the switcher actually puts on its buttons, so they
    # are read back off the buttons rather than off the stack's child
    # properties -- what a person sees is the thing worth pinning.
    my @titles =
        sort map { $_->get_label // q{} }
        descendants( $switcher, 'Gtk3::Label' );

    is_deeply \@titles, [ 'Image', 'Soundtrack' ],
        'under the titles the switcher shows';
}

# ---------------------------------------------------------------------------
# One Add button, and it adds to whichever page is showing

# "Add something here" is one action, so it is one button. Giving each page
# its own pair of Add buttons said it was several, and put a second set of
# controls inside a pane that already had a bar for them.
{
    $gui->{ left_stack }->set_visible_child_name( 'image' );
    $gui->_sync_actions;

    like $gui->{ b_add }->get_tooltip_text, qr/effect/i,
        'on the Image page Add offers an effect';

    $gui->{ left_stack }->set_visible_child_name( 'soundtrack' );
    $gui->_sync_actions;

    like $gui->{ b_add }->get_tooltip_text, qr/soundtrack|track/i,
        'and on the Soundtrack page it offers a track';

    # Both tooltips still name the key, since an accelerator is invisible.
    like $gui->{ b_add }->get_tooltip_text, qr/Alt\+D/,
        'either way it says which key presses it';

    # There is no image open in this file, so Add is insensitive on both
    # pages regardless. What it is gated on beyond that -- Animate, for the
    # soundtrack -- is pinned in t/27-gui-adjust.t, which has a state.
    ok !$gui->{ b_add }->get_sensitive,
        'and with no image open it is not an action on either page';

    $gui->{ left_stack }->set_visible_child_name( 'image' );
    $gui->_sync_actions;
}

# ---------------------------------------------------------------------------
# The soundtrack list is shaped like the effect list

{
    my $list = $gui->{ audio_list };
    isa_ok $list, 'Gtk3::ListBox', 'the track list';

    ok !$list->get_activate_on_single_click,
        'and activates on a double click, as the effect list does';
}

# ---------------------------------------------------------------------------
# The effect list activates on a double click, not a single one

# A list where activating a row opens a window cannot be browsed if a single
# click activates: passing over three rows with the arrow keys would leave
# three windows open.
{
    my $list = $gui->{ effect_list };
    isa_ok $list, 'Gtk3::ListBox', 'the effect list';

    ok !$list->get_activate_on_single_click,
        'and a single click does not activate a row';

    is $list->get_selection_mode, 'single',
        'exactly one row can be selected, which is what Adjust acts on';
}

# ---------------------------------------------------------------------------
# Animate is a toggle, and it sits with Apply

# Not with the preview controls. It does not change how the result is
# displayed -- it changes what Apply does and what Export writes -- and among
# zoom and mute it read as another free adjustment.

{
    isa_ok $gui->{ b_animate }, 'Gtk3::ToggleButton', 'Animate';

    my @up;
    my $w = $gui->{ b_animate };
    while ( $w = $w->get_parent ) { push @up, $w }

    ok scalar( grep { $_->isa( 'Gtk3::ActionBar' ) } @up ),
        'Animate is in the left pane action bar';

    # Specifically the bar Apply is in, rather than merely some action bar.
    my ( $bar ) = descendants( $gui->{ window }, 'Gtk3::ActionBar' );
    ok scalar( grep { $_ == $bar } @up ), 'the same one Apply is in';

    ok !scalar( grep { $_->isa( 'Gtk3::ScrolledWindow' ) } @up ),
        'and cannot be scrolled out of sight either';

    # And nowhere near the preview controls: among zoom and mute it would
    # read as another free adjustment rather than something with a render
    # bill behind it.
    my %above = map { $_ => 1 } @up;
    my @mute_up;
    my $m = $gui->{ b_mute };
    while ( $m = $m->get_parent ) { push @mute_up, $m }

    my @shared = grep { $above{ $_ } } @mute_up;

    # They share the window and the paned, and nothing below that.
    ok !
        scalar( grep { $_->isa( 'Gtk3::ActionBar' ) || $_->isa( 'Gtk3::Box' ) }
            @shared ),
        'and shares no bar with the preview controls';
}

# Toggling it drives the render mode and unlocks the soundtrack page.
#
# The page is always reachable now, so what changes is which of its two faces
# is showing: the controls, or the note explaining what they are waiting for.
# A tab that vanished taught nobody what it had been for.
{
    ok !$gui->{ animate }, 'animation is off to begin with';
    is $gui->{ audio_stack }->get_visible_child_name, 'needs-animation',
        'and the soundtrack page says why it is empty';

    $gui->{ b_animate }->set_active( 1 );

    ok $gui->{ animate }, 'switching the toggle on turns animation on';
    is $gui->{ audio_stack }->get_visible_child_name, 'empty',
        'and with nothing in the mix the page says how to fill it';

    # Three faces, not two: without an animation the page explains what it is
    # waiting for, with one and nothing in it how to fill it, and only with
    # something in it does it show the list. The middle one is easy to lose --
    # it is the state a person is in for the whole time they are deciding.
    $gui->{ audio } = { generated => [ { kind => 'heart', bpm => 70 } ] };
    $gui->_sync_actions;

    is $gui->{ audio_stack }->get_visible_child_name, 'ready',
        'and once there is a track it shows the mix';

    $gui->{ audio } = undef;
    $gui->{ b_animate }->set_active( 0 );

    ok !$gui->{ animate }, 'and switching it off turns it off again';
    is $gui->{ audio_stack }->get_visible_child_name, 'needs-animation',
        'and the page goes back to explaining itself';
}

# ---------------------------------------------------------------------------
# The effect page says how to fill itself while it is empty

# A pane holding a heading over nothing does not say whether there is
# something to do or something wrong.
{
    ok !$gui->{ state }, 'no image is open in this file';
    is $gui->{ effect_stack }->get_visible_child_name, 'empty',
        'so the effect page is showing its empty state';

    my ( $label ) =
        grep { ( $_->get_label // q{} ) =~ /\+/ }
        descendants( $gui->{ effect_stack }, 'Gtk3::Label' );

    ok $label, 'which names the button that would fill it';
}

# ---------------------------------------------------------------------------
# Apply and Stop are one button wearing two hats

{
    my $label = sub { return $gui->{ apply_label }->get_label };
    my $icon  = sub {
        my ( $name ) = $gui->{ apply_icon }->get_icon_name;
        return $name;
    };

    is $label->(), '_Apply', 'the button reads Apply when idle';
    is $icon->(),  GlitchVape::GUI::APPLY_ICON, 'and shows the start icon';

    my $idle_tip = $gui->{ b_apply }->get_tooltip_text;

    $gui->_busy( 1, 'Rendering…' );

    is $label->(), '_Stop',                    'and reads Stop while rendering';
    is $icon->(),  GlitchVape::GUI::STOP_ICON, 'with the stop icon';

    isnt $gui->{ b_apply }->get_tooltip_text, $idle_tip,
        'and the tooltip stops explaining how to start';

    $gui->_busy( 0 );

    is $label->(), '_Apply',                    'back to Apply when done';
    is $icon->(),  GlitchVape::GUI::APPLY_ICON, 'and back to the start icon';
    is $gui->{ b_apply }->get_tooltip_text, $idle_tip, 'and to its tooltip';
}

# The button must not resize as it changes word, or the bar twitches every
# time a render starts.
{
    my ( $request ) = $gui->{ b_apply }->get_size_request;

    cmp_ok $request, '>', 0, 'the Apply button has a pinned width';

    $gui->_busy( 1 );
    my ( $busy_request ) = $gui->{ b_apply }->get_size_request;
    $gui->_busy( 0 );

    is $busy_request, $request, 'which does not change when it says Stop';
}

# ---------------------------------------------------------------------------
# The spinner is over the picture, and does not steal the pointer

# Over the preview rather than in the action bar, where it would have to be
# faded rather than hidden so that appearing did not shove the button beside
# it. What makes that safe is pass-through: without it the overlay's event
# window swallows the drags that pan and zoom the preview, which are most of
# what the preview is for.
{
    my ( $overlay ) = descendants( $gui->{ window }, 'Gtk3::Overlay' );
    ok $overlay, 'the preview sits in an overlay';

    my $badge = $gui->{ spinner_badge };

    my @up;
    my $w = $badge;
    while ( $w = $w->get_parent ) { push @up, $w }
    ok scalar( grep { $_ == $overlay } @up ), 'with the spinner over it';

    ok $overlay->get_overlay_pass_through( $badge ),
        'and every press still reaches the picture underneath';

    ok !$badge->get_visible, 'the spinner is out of the way when idle';

    $gui->_busy( 1, 'Rendering…' );
    ok $badge->get_visible, 'and appears over the picture while rendering';
    ok $gui->{ spinner }->get_property( 'active' ), 'actually spinning';
    is $gui->{ spinner_label }->get_text, 'Rendering…',
        'saying what it is waiting for';

    $gui->_busy( 0 );
    ok !$badge->get_visible, 'and goes away again when the render is done';
}

# ---------------------------------------------------------------------------
# A soundtrack survives switching animation off and on

# The page hides the mix rather than clearing it, so going back to a still to
# check one frame does not cost the tracks that were already assembled.
{
    $gui->{ b_animate }->set_active( 1 );
    $gui->{ audio } = { path => '/nonexistent/track.mp3' };

    $gui->{ b_animate }->set_active( 0 );
    $gui->{ b_animate }->set_active( 1 );

    is_deeply $gui->{ audio }, { path => '/nonexistent/track.mp3' },
        'the soundtrack is still there after animation was switched off';

    $gui->{ audio } = undef;
    $gui->{ b_animate }->set_active( 0 );
}

done_testing;
