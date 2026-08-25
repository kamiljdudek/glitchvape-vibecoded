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

    # Both buttons are in it, and both are outside the scrolled list -- Add
    # effect used to be inside, where a long pipeline could scroll it away.
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
{
    my %claimed;

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
    ok $claimed{ n },
        'Animate is still Alt+N, as it was when it was a checkbox';
    ok $claimed{ e }, 'Export is still Alt+E';
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

    # And nowhere near the preview controls, which is where it briefly was.
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

# Toggling it drives the render mode and reveals the soundtrack row, which is
# what it did as a checkbox.
{
    ok !$gui->{ animate }, 'animation is off to begin with';
    ok !$gui->{ audio_revealer }->get_reveal_child,
        'and the soundtrack row is hidden';

    $gui->{ b_animate }->set_active( 1 );

    ok $gui->{ animate }, 'switching the toggle on turns animation on';
    ok $gui->{ audio_revealer }->get_reveal_child,
        'and reveals the soundtrack row';

    $gui->{ b_animate }->set_active( 0 );

    ok !$gui->{ animate }, 'and switching it off turns it off again';
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

# The spinner holds its place whether or not it is spinning, for the same
# reason: showing and hiding it would move the button beside it.
{
    ok $gui->{ spinner }->get_visible, 'the spinner is always in the layout';

    $gui->_busy( 1 );
    cmp_ok $gui->{ spinner }->get_opacity, '>', 0, 'and is faded in when busy';

    $gui->_busy( 0 );
    is $gui->{ spinner }->get_opacity, 0, 'and out again when not';
}

done_testing;
