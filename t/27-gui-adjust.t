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

# One effect's settings, in a popover hung off the Adjust button. What is
# pinned here is the behaviour that makes a popover workable in a program
# whose rendering is an explicit Apply: it follows the selection, and it does
# not dismiss itself.

my $gui = GlitchVape::GUI->new;
$gui->{ window }->show_all;

# A state without a real file on disk: nothing here renders, and every
# question asked below is about the configuration rather than the picture.
$gui->{ state } =
    GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
$gui->{ state }->add_effect( 'scanlines' );
$gui->{ state }->add_effect( 'vignette' );
$gui->_rebuild_effects;

sub rows_of
{
    my ( $list ) = @_;
    return map { $_->{ effect } } $list->get_children;
}

# Select an effect and make sure the popover is showing it. Adjust is a
# toggle, so pressing it blindly closes a popover that is already up.
sub open_on
{
    my ( $name ) = @_;

    select_effect( $name );
    $gui->_adjust_selected unless $gui->{ adjust } && $gui->{ adjust }->visible;

    return;
}

sub select_effect
{
    my ( $name ) = @_;

    my ( $row ) =
        grep { $_->{ effect } eq $name } $gui->{ effect_list }->get_children;
    $gui->{ effect_list }->select_row( $row );

    return $row;
}

# ---------------------------------------------------------------------------
# The list shows what is in the pipeline, in the order it will run

{
    my @names = rows_of( $gui->{ effect_list } );

    is_deeply \@names, [ 'scanlines', 'vignette' ],
        'the list holds one row per effect, in pipeline order';
}

# ---------------------------------------------------------------------------
# Adjust needs a selection, and says so by being insensitive without one

{
    $gui->{ effect_list }->unselect_all;
    $gui->_sync_actions;

    ok !$gui->{ b_adjust }->get_sensitive,
        'Adjust is not an action while no row is selected';

    select_effect( 'scanlines' );
    $gui->_sync_actions;

    ok $gui->{ b_adjust }->get_sensitive, 'and becomes one once a row is';
}

# ---------------------------------------------------------------------------
# It is a popover, and it is not modal

# Rendering is an explicit Apply, so a modal popover would close the moment
# Apply was pressed and have to be reopened for every single render.

{
    $gui->_adjust_selected;

    my $adjust = $gui->{ adjust };
    ok $adjust, 'pressing Adjust builds the popover';

    isa_ok $adjust->popover, 'Gtk3::Popover', 'what it shows';

    ok !$adjust->popover->get_modal,
        'which is not modal, so an Apply does not dismiss it';

    is $adjust->popover->get_relative_to, $gui->{ b_adjust },
        'and is hung off the button that opened it';

    is $adjust->popover->get_position, 'top',
        'pointing upwards, since Adjust is at the foot of the pane';

    ok $adjust->visible, 'it is up';
    is $adjust->effect, 'scanlines', 'showing the selected effect';
}

# Pressing Adjust again puts it away. Without this there would be no way to
# dismiss it with the control that summoned it, a non-modal popover not
# closing itself.
{
    $gui->_adjust_selected;

    ok !$gui->{ adjust }->visible, 'pressing Adjust again puts it away';
    is $gui->{ adjust }->effect, undef, 'and it is showing nothing';
}

# ---------------------------------------------------------------------------
# It follows the selection

{
    select_effect( 'scanlines' );
    $gui->_adjust_selected;

    is $gui->{ adjust }->effect, 'scanlines', 'open on scanlines';

    select_effect( 'vignette' );

    is $gui->{ adjust }->effect, 'vignette',
        'selecting another row moves the popover to it';
    ok $gui->{ adjust }->visible, 'without closing it';

    # Nothing selected is nothing to show.
    $gui->{ effect_list }->unselect_all;

    ok !$gui->{ adjust }->visible, 'and clearing the selection puts it away';
}

# While it is closed, moving the selection does not open it: the popover is
# summoned, not sprung.
{
    ok !$gui->{ adjust }->visible, 'the popover is closed';

    select_effect( 'scanlines' );

    ok !$gui->{ adjust }->visible,
        'selecting a row while it is closed leaves it closed';
}

# ---------------------------------------------------------------------------
# The checkbox and the switch are one fact

# Shown twice, so each has to move when the other does -- and neither may
# count being told as being set, or the two answer each other forever.

{
    open_on( 'scanlines' );

    my $check = $gui->{ rows }{ scanlines }{ check };

    ok $check->get_active, 'a new effect starts enabled on its row';
    ok $gui->{ adjust }{ switch }->get_active, 'and on the popover switch';

    $check->set_active( 0 );

    ok !$gui->{ state }->enabled( 'scanlines' ),
        'unticking the row disables the effect';
    ok !$gui->{ adjust }{ switch }->get_active,
        'and moves the switch with it, the popover showing that effect';

    $gui->{ adjust }{ switch }->set_active( 1 );

    ok $gui->{ state }->enabled( 'scanlines' ),
        'and the switch enables it again';
    ok $check->get_active, 'moving the checkbox back';
}

# ---------------------------------------------------------------------------
# Removing the effect it is showing closes it

# A popover left describing something no longer in the pipeline would write to
# state that is not there.

{
    open_on( 'vignette' );
    is $gui->{ adjust }->effect, 'vignette', 'showing vignette';

    # Taken out of the state directly, so what is being tested is that
    # rebuilding the list notices by itself -- a preset or an undo removes
    # effects without going anywhere near the row's minus button.
    $gui->{ state }->remove_effect( 'vignette' );
    $gui->_rebuild_effects;

    ok !$gui->{ adjust }->visible,
        'removing the effect it was showing closes the popover';

    is_deeply [ rows_of( $gui->{ effect_list } ) ], [ 'scanlines' ],
        'and the row goes with it';
}

# Removing a different effect leaves it alone.
{
    $gui->{ state }->add_effect( 'grain' );
    $gui->_rebuild_effects;

    open_on( 'scanlines' );
    ok $gui->{ adjust }->visible, 'the popover is showing scanlines';

    $gui->{ state }->remove_effect( 'grain' );
    $gui->_rebuild_effects;

    ok $gui->{ adjust }->visible, 'removing a different effect leaves it up';
    is $gui->{ adjust }->effect, 'scanlines', 'still on the same one';
}

# ---------------------------------------------------------------------------
# It survives an undo, showing what the state now holds

# Undo steps over whole configurations, so a popover built against the old one
# is showing values that are no longer set.

{
    my $state = $gui->{ state };

    $state->param( 'scanlines', 'opacity', 0.9 );
    $state->commit;

    $state->param( 'scanlines', 'opacity', 0.1 );
    $state->commit;

    is $state->param( 'scanlines', 'opacity' ), 0.1, 'the later value is set';

    # Undone and the widgets reloaded directly rather than through
    # _step_history: that would also start a render, and there is no real
    # picture behind this state to render.
    $state->undo;
    $gui->_reload_widgets;

    is $state->param( 'scanlines', 'opacity' ), 0.9,
        'undo puts the earlier one back';

    ok $gui->{ adjust }->visible, 'and the popover is still open across it';
    is $gui->{ adjust }->effect, 'scanlines', 'on the same effect';
}

# ---------------------------------------------------------------------------
# Adjust acts on whichever list is showing

# One gesture for both pages: select a row, press the cog. The soundtrack
# keeps its dialogs -- a track has a real Cancel and building one is a
# decision you can back out of, which moving a slider is not -- so what the
# cog opens there is a wizard rather than a popover.

{
    $gui->{ animate } = 1;
    $gui->{ audio } =
        { generated => [ { kind => 'heart', bpm => 70, seconds => 20 } ] };

    $gui->{ left_stack }->set_visible_child_name( 'soundtrack' );
    $gui->{ audio_list }->unselect_all;
    $gui->_sync_actions;

    ok !$gui->{ adjust }->visible,
        'leaving the effect page puts the popover away';

    ok !$gui->{ b_adjust }->get_sensitive,
        'and with no track selected Adjust is not an action';

    my ( $row ) = $gui->{ audio_list }->get_children;
    ok $row, 'the mix has a track in it';

    $gui->{ audio_list }->select_row( $row );
    $gui->_sync_actions;

    ok $gui->{ b_adjust }->get_sensitive,
        'selecting a track makes Adjust an action again';

    like $gui->{ b_adjust }->get_tooltip_text, qr/track/i,
        'and it says it will reopen the track';

    # The row carries the way back into whatever built it, which is what
    # Adjust presses now that the rows have no Edit button of their own.
    ok $row->{ edit }, 'the row knows how to reopen its wizard';

    my ( $box ) = $row->get_children;
    my @buttons = grep { $_->isa( 'Gtk3::Button' ) } $box->get_children;

    is scalar @buttons, 1,
        'and carries one button, the minus, having lost its Edit';

    $gui->{ audio }   = undef;
    $gui->{ animate } = 0;
    $gui->{ left_stack }->set_visible_child_name( 'image' );
    $gui->_sync_actions;
}

# ---------------------------------------------------------------------------
# Selecting a track does not rebuild the list underneath itself

# _sync_actions rebuilds the track rows, and it runs on every selection
# change: without a guard, selecting a row destroys that row from inside its
# own signal handler and the list draws widgets it no longer holds.

{
    $gui->{ animate } = 1;
    $gui->{ audio }   = {
        generated => [
            { kind => 'heart',  bpm      => 70, seconds => 20 },
            { kind => 'geiger', strength => 60, seconds => 20 },
        ]
    };

    $gui->{ left_stack }->set_visible_child_name( 'soundtrack' );
    $gui->_sync_actions;

    my @before = $gui->{ audio_list }->get_children;
    is scalar @before, 2, 'two tracks, two rows';

    $gui->{ audio_list }->select_row( $before[ 1 ] );
    $gui->_sync_actions;

    my @after = $gui->{ audio_list }->get_children;
    is scalar @after, 2, 'still two rows after selecting one';

    ok defined $gui->{ audio_list }->get_selected_row,
        'and the selection survived';

    $gui->{ audio }   = undef;
    $gui->{ animate } = 0;
    $gui->{ left_stack }->set_visible_child_name( 'image' );
    $gui->_sync_actions;
}

# ---------------------------------------------------------------------------
# A setting that cannot matter yet says so

# osd is the effect this exists for. Its date and time did nothing at all
# unless the timestamp was switched on and left un-invented, and neither fact
# was said anywhere: the fields sat there looking typeable, and typing in one
# changed nothing about the render. Greyed rather than hidden, because a row
# that vanishes teaches nobody what turned it on -- and greyed rather than
# removed from the state, because ticking the switch back on has to give back
# the date that was already there.
{
    $gui->{ state }->add_effect( 'osd' );
    $gui->_rebuild_effects;
    open_on( 'osd' );

    my $controls = $gui->{ adjust }{ controls };

    my $sensitive = sub {
        my ( $key ) = @_;
        return $controls->{ $key }{ control }->get_sensitive ? 1 : 0;
    };

    # The default: a timestamp, invented. So the two fields it would be typed
    # into are inert, and the reroll under them is not.
    is $sensitive->( 'timestamp' ), 1, 'the timestamp switch is always live';
    is $sensitive->( 'date' ), 0, 'an invented timestamp greys the date field';
    is $sensitive->( 'time' ), 0, 'and the time field';
    is $sensitive->( 'reroll' ), 1,
        'while rerolling it is exactly what an invented one can do';

    # The label goes with the control. A live label beside a dead field reads
    # as a widget that failed to draw rather than as a setting waiting on
    # another.
    is $controls->{ date }{ label }->get_sensitive, '',
        'the label is greyed with its control';

    $gui->{ state }->param( 'osd', 'invent', 0 );
    $gui->{ adjust }->refresh;
    $controls = $gui->{ adjust }{ controls };

    is $sensitive->( 'date' ),   1, 'turning invent off wakes the date field';
    is $sensitive->( 'time' ),   1, 'and the time field';
    is $sensitive->( 'reroll' ), 0, 'and there is nothing left to reroll';

    # And the switch above them takes all four with it.
    $gui->{ state }->param( 'osd', 'timestamp', 0 );
    $gui->{ adjust }->refresh;
    $controls = $gui->{ adjust }{ controls };

    is $sensitive->( 'date' ),   0, 'no timestamp, no date to set';
    is $sensitive->( 'time' ),   0, 'nor time';
    is $sensitive->( 'invent' ), 0, 'nor anything to invent';

    # Nothing was thrown away on the way: the value is still there to come
    # back to, which is the whole argument for greying rather than clearing.
    is $gui->{ state }->param( 'osd', 'date' ), 'JUN 15 1995',
        'and the greyed-out value is still what it was';

    # Moving a control re-evaluates the rest, rather than waiting for the
    # popover to be rebuilt: the switch and the fields under it are in the
    # same popover and the answer has to arrive with the click.
    $gui->{ adjust }->_set_param( 'timestamp', 1 );
    is $sensitive->( 'invent' ), 1,
        'moving a switch wakes what it gates, without a rebuild';

    $gui->{ state }->remove_effect( 'osd' );
    $gui->_rebuild_effects;
}

done_testing;
