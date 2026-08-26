#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;

# Gtk, because the progress channel is a Glib IO watch on the main loop.
BEGIN
{
    eval { require Gtk3; Gtk3->import; 1 }
        or plan skip_all => 'Gtk3 is not available';
    Gtk3::init_check()
        or plan skip_all => 'no display';
}

use GlitchVape::GUI         ();
use GlitchVape::GUI::Cache  ();
use GlitchVape::GUI::Render ();

local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

# How a render says how far it has got. Nothing here renders anything: the
# child is handed a closure that reports and exits, which exercises the pipe,
# the watch and the teardown without waiting on ImageMagick.

# Run the main loop until $done goes true, or give up.
sub pump_until
{
    my ( $done, $limit ) = @_;
    $limit ||= 10_000;

    my $expired = 0;

    # Each clears its own id as it fires, because a source that returned 0 has
    # already been removed and removing it again is a GLib-CRITICAL.
    my ( $timer, $poll );

    $timer = Glib::Timeout->add(
        $limit,
        sub {
            $expired = 1;
            $timer   = undef;
            Gtk3->main_quit;
            return 0;
        }
    );

    $poll = Glib::Timeout->add(
        20,
        sub {
            return 1 unless $done->();
            $poll = undef;
            Gtk3->main_quit;
            return 0;
        }
    );

    Gtk3->main;

    Glib::Source->remove( $_ ) for grep { defined } ( $timer, $poll );

    return !$expired;
}

# ---------------------------------------------------------------------------
# The child's counting reaches the parent, in order and complete

# The pipe hands over whatever has arrived, which on a fast child is several
# lines at once and can be half of one -- so this deliberately reports faster
# than the parent can possibly wake up.

{
    my $render =
        GlitchVape::GUI::Render->new( cache => GlitchVape::GUI::Cache->new );

    my @seen;
    my $finished = 0;

    $render->_spawn(
        key         => undef,
        final       => undef,
        on_progress => sub { push @seen, [ @_ ] },
        on_done     => sub { $finished = 1 },
        on_error    => sub { $finished = 1; fail "render error: $_[0]" },
        work        => sub {
            my ( $report ) = @_;
            $report->( $_, 25 ) for 1 .. 24;
            return;
        },
    );

    ok pump_until( sub { $finished } ), 'the child was reaped';

    is scalar @seen, 24, 'every report the child made arrived';

    my $ordered = 1;
    my $totals  = 1;
    for my $n ( 0 .. $#seen )
    {
        $ordered = 0 unless $seen[ $n ][ 0 ] == $n + 1;
        $totals  = 0 unless $seen[ $n ][ 1 ] == 25;
    }

    ok $ordered, 'in order, with none dropped or duplicated';

    # One denominator for the whole render. If the last report changed it, the
    # bar would jump backwards at the moment it was meant to be finishing.
    ok $totals, 'and all of them against the same total';
}

# ---------------------------------------------------------------------------
# A cancelled render stops reporting

# Its callbacks never fire, and progress is one of them: the bar belongs to a
# render nobody is waiting for any more.

{
    my $render =
        GlitchVape::GUI::Render->new( cache => GlitchVape::GUI::Cache->new );

    my $after_cancel = 0;
    my $cancelled    = 0;

    $render->_spawn(
        key         => undef,
        final       => undef,
        on_progress => sub { $after_cancel++ if $cancelled },
        on_done     => sub { },
        on_error    => sub { },
        work        => sub {
            my ( $report ) = @_;

            # Slowly, so the cancel below lands in the middle of it.
            for my $n ( 1 .. 40 )
            {
                $report->( $n, 41 );
                select undef, undef, undef, 0.05;    ## no critic (ProhibitSleepViaSelect)
            }
            return;
        },
    );

    # Let a few through first, so this is testing the cancel and not a race
    # to start.
    # One-shot: it removes itself by returning 0, so nothing removes it here.
    Glib::Timeout->add(
        400,
        sub {
            Gtk3->main_quit;
            return 0;
        }
    );
    Gtk3->main;

    $render->cancel;
    $cancelled = 1;

    Glib::Timeout->add(
        600,
        sub {
            Gtk3->main_quit;
            return 0;
        }
    );
    Gtk3->main;

    is $after_cancel, 0, 'nothing is reported once the render is cancelled';
}

# ---------------------------------------------------------------------------
# What the window does with the numbers

my $gui = GlitchVape::GUI->new;
$gui->{ window }->show_all;
$gui->_sync_actions;

# The bar is hidden until something counts. A still is one step and the step
# is the whole render, so it never appears.
{
    $gui->_busy( 1, 'Rendering…' );

    ok $gui->{ spinner_badge }->get_visible, 'the badge is up while rendering';
    ok !$gui->{ spinner_bar }->get_visible,
        'but a still shows no progress bar, having one step to show';

    $gui->_busy( 0 );
}

# A loop counts, and the last step is the encode rather than a frame.
{
    $gui->_busy( 1, 'Rendering…' );

    $gui->_progress( 1, 9 );

    ok $gui->{ spinner_bar }->get_visible, 'a loop brings the bar out';
    is $gui->{ spinner_label }->get_text, 'Frame 1 of 8',
        'and counts frames, not the encode that follows them';

    cmp_ok $gui->{ spinner_bar }->get_fraction, '>', 0;
    cmp_ok $gui->{ spinner_bar }->get_fraction, '<', 1;

    # The frames are done but the ffmpeg run is not. A bar sitting at full
    # through it would be saying the render had finished.
    $gui->_progress( 8, 9 );

    is $gui->{ spinner_label }->get_text, 'Encoding…',
        'the step past the last frame says what it is waiting for';
    cmp_ok $gui->{ spinner_bar }->get_fraction, '<', 1,
        'and leaves the bar something still to fill';

    $gui->_busy( 0 );
    ok !$gui->{ spinner_bar }->get_visible,
        'and the bar goes away with the badge';
}

# ---------------------------------------------------------------------------
# The estimate says nothing until it has something to say

# The first frame pays for decoding the source, which every later frame
# reuses. Extrapolating from it alone promises a wait half again as long as
# the one that follows, and a figure that then falls steadily is worse than no
# figure at all.

{
    $gui->{ progress_seen } = [];
    is $gui->_estimate( 1, 24 ), undef, 'no estimate from nothing';

    $gui->{ progress_seen } = [ 100 ];
    is $gui->_estimate( 1, 24 ), undef, 'nor from one frame';

    $gui->{ progress_seen } = [ 100, 110 ];
    is $gui->_estimate( 2, 24 ), undef,
        'nor from two, the first of which was the slow one';

    # Three timings: the first is discarded, leaving one interval of 2s.
    # Twenty-one frames left at 2s each is 42 seconds.
    $gui->{ progress_seen } = [ 100, 110, 112 ];
    is $gui->_estimate( 3, 24 ), '42s',
        'and from three it extrapolates off the frames after the first';

    # Long enough to be worth minutes.
    $gui->{ progress_seen } = [ 0, 10, 20 ];
    is $gui->_estimate( 3, 24 ), '3m 30s', 'reported in minutes once it is';

    # Nothing left to wait for.
    $gui->{ progress_seen } = [ 100, 110, 112 ];
    is $gui->_estimate( 24, 24 ), undef, 'and nothing at all on the last frame';
}

done_testing;
