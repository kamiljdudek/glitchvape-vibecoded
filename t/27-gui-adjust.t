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

# One effect's settings, in a window of its own. The properties pinned here
# are the ones that make several of them usable at once -- which is the whole
# reason the parameters left the list.

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

    my ( $row ) = $gui->{ effect_list }->get_children;
    $gui->{ effect_list }->select_row( $row );
    $gui->_sync_actions;

    ok $gui->{ b_adjust }->get_sensitive, 'and becomes one once a row is';
}

# ---------------------------------------------------------------------------
# Several may be open at once

# The reason these are not modal: deciding how much chroma_shift answers this
# much scanlines means having both sets of controls in front of you.

{
    $gui->_adjust_effect( 'scanlines' );
    $gui->_adjust_effect( 'vignette' );

    is scalar( keys %{ $gui->{ adjust } } ), 2,
        'two effects can have their settings open at the same time';

    for my $name ( 'scanlines', 'vignette' )
    {
        my $window = $gui->{ adjust }{ $name }->window;
        ok $window,             "$name has a window";
        ok !$window->get_modal, "and the $name window is not modal";
        is $window->get_transient_for, $gui->{ window },
            "but does belong to the main window";
    }
}

# Asking twice raises the window that is open rather than stacking a second
# copy: two windows writing the same parameters would disagree the moment
# either was touched.
{
    my $before = $gui->{ adjust }{ scanlines };
    $gui->_adjust_effect( 'scanlines' );

    is $gui->{ adjust }{ scanlines }, $before,
        'asking again reuses the window rather than opening a second';
    is scalar( keys %{ $gui->{ adjust } } ), 2, 'so the count does not grow';
}

# ---------------------------------------------------------------------------
# The checkbox and the switch are one fact

# Shown twice, so each has to move when the other does -- and neither may
# count being told as being set, or the two answer each other forever.

{
    my $window = $gui->{ adjust }{ scanlines };
    my $check  = $gui->{ rows }{ scanlines }{ check };

    ok $check->get_active, 'a new effect starts enabled on its row';
    ok $window->{ switch }->get_active, 'and on its switch';

    $check->set_active( 0 );

    ok !$gui->{ state }->enabled( 'scanlines' ),
        'unticking the row disables the effect';
    ok !$window->{ switch }->get_active,
        'and moves the switch in the open window with it';

    $window->{ switch }->set_active( 1 );

    ok $gui->{ state }->enabled( 'scanlines' ),
        'and the switch enables it again';
    ok $check->get_active, 'moving the checkbox back';
}

# ---------------------------------------------------------------------------
# Removing an effect closes the window describing it

# A settings window for something no longer in the pipeline would write to
# state that is not there.

{
    my $window = $gui->{ adjust }{ vignette }->window;
    ok $window, 'vignette has an open window';

    # Taken out of the state directly, so what is being tested is that
    # rebuilding the list notices the orphan by itself -- a preset or an undo
    # removes effects without going anywhere near the row's minus button.
    $gui->{ state }->remove_effect( 'vignette' );
    $gui->_rebuild_effects;

    ok !$gui->{ adjust }{ vignette },
        'removing the effect leaves no window behind';

    is_deeply [ rows_of( $gui->{ effect_list } ) ], [ 'scanlines' ],
        'and the row goes with it';

    ok $gui->{ adjust }{ scanlines }, 'while the other window is left alone';
}

# The same holds when the removal comes from the row's own minus button,
# which is the way it actually happens.
{
    $gui->{ state }->add_effect( 'grain' );
    $gui->_rebuild_effects;
    $gui->_adjust_effect( 'grain' );

    ok $gui->{ adjust }{ grain }, 'grain has an open window';

    # The minus button is the last child of the row's box.
    my ( $row ) =
        grep { $_->{ effect } eq 'grain' } $gui->{ effect_list }->get_children;
    my ( $box ) = $row->get_children;
    my ( $remove ) =
        grep { $_->isa( 'Gtk3::Button' ) && !$_->isa( 'Gtk3::CheckButton' ) }
        $box->get_children;

    $remove->clicked;

    ok !$gui->{ adjust }{ grain },
        'pressing the minus on the row closes its settings window too';
    ok !grep( { $_ eq 'grain' } rows_of( $gui->{ effect_list } ) ),
        'and takes the effect out of the pipeline';
}

# ---------------------------------------------------------------------------
# An open window follows an undo

# Undo steps over whole configurations, so a window built against the old one
# is showing values that are no longer set.

{
    my $state = $gui->{ state };

    $state->param( 'scanlines', 'opacity', 0.9 );
    $state->commit;

    $state->param( 'scanlines', 'opacity', 0.1 );
    $state->commit;

    is $state->param( 'scanlines', 'opacity' ), 0.1, 'the later value is set';

    # The state is undone and the widgets reloaded directly, rather than
    # through _step_history: that would also start a render, and there is no
    # real picture behind this state to render.
    $state->undo;
    $gui->_reload_widgets;

    is $state->param( 'scanlines', 'opacity' ), 0.9,
        'undo puts the earlier one back';

    ok $gui->{ adjust }{ scanlines },
        'and the settings window is still open across it';
}

# ---------------------------------------------------------------------------
# Closing a window forgets it, so the next ask opens a fresh one

{
    my $window = $gui->{ adjust }{ scanlines };
    $window->window->destroy;

    ok !$gui->{ adjust }{ scanlines },
        'a window closed by the user is dropped from the register';

    $gui->_adjust_effect( 'scanlines' );

    ok $gui->{ adjust }{ scanlines }, 'and asking again opens a new one';
    isnt $gui->{ adjust }{ scanlines }, $window, 'which is not the old one';
}

# ---------------------------------------------------------------------------
# Switching page drops the effect selection

# The Adjust button acts on it and only the Image page has effects to act on,
# so a selection kept across the switch would be a button pointing at
# something not on screen.

{
    $gui->{ left_stack }->set_visible_child_name( 'image' );

    my ( $row ) = $gui->{ effect_list }->get_children;
    $gui->{ effect_list }->select_row( $row );
    $gui->_sync_actions;

    ok defined $gui->_selected_effect,
        'an effect is selected on the Image page';
    ok $gui->{ b_adjust }->get_sensitive, 'so Adjust is an action';

    $gui->{ left_stack }->set_visible_child_name( 'soundtrack' );

    ok !defined $gui->_selected_effect,
        'switching to Soundtrack drops the selection';
    ok !$gui->{ b_adjust }->get_sensitive, 'and Adjust stops being an action';

    # Lost, not remembered: coming back to a row still highlighted from
    # several minutes ago invites adjusting the wrong effect.
    $gui->{ left_stack }->set_visible_child_name( 'image' );

    ok !defined $gui->_selected_effect, 'and coming back does not put it back';
    ok !$gui->{ b_adjust }->get_sensitive, 'so Adjust is still waiting';
}

# ---------------------------------------------------------------------------
# Add is gated on there being an animation to carry a track

{
    $gui->{ left_stack }->set_visible_child_name( 'soundtrack' );
    $gui->{ b_animate }->set_active( 0 );
    $gui->_sync_actions;

    ok !$gui->{ b_add }->get_sensitive,
        'with no animation, Add on the Soundtrack page is not an action';

    $gui->{ b_animate }->set_active( 1 );

    ok $gui->{ b_add }->get_sensitive, 'and becomes one once Animate is on';
}

# ---------------------------------------------------------------------------
# The Add popover offers the file once, and the generators always

# There is one cropped file at most; generated tracks stack.

{
    $gui->_add_to_current_page;

    my $popover = $gui->{ add_track_popover };
    ok $popover, 'pressing Add on the Soundtrack page builds a popover';

    is $popover->get_relative_to, $gui->{ b_add },
        'hung off the Add button that opened it';
    is $popover->get_position, 'top',
        'and pointing upwards, since Add is at the foot of the pane';

    ok $gui->{ audio_add_file }->get_visible,
        'the audio-file line is offered while there is no file in the mix';

    $gui->{ audio } = { path => '/nonexistent/track.mp3' };
    $gui->_sync_actions;

    ok !$gui->{ audio_add_file }->get_visible,
        'and goes away once one has been added';

    # The generated kinds are not gated that way -- as many as you like.
    my @rows = $gui->{ audio_list }->get_children;
    is scalar @rows, 1, 'the file has a row in the track list';
    isa_ok $rows[ 0 ], 'Gtk3::ListBoxRow', 'which';
    ok $rows[ 0 ]->{ edit }, 'and carries the way to reopen its wizard';

    $gui->{ audio } = undef;
    $gui->_sync_actions;
}

done_testing;
