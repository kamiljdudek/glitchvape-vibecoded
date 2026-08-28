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

use GlitchVape             ();
use GlitchVape::GUI        ();
use GlitchVape::GUI::State ();

local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

# Closing the window is the one irreversible thing the interface does.
#
# There is no project file: a pipeline lives in the window and nowhere else
# until somebody saves it as a preset, and a soundtrack cannot be saved at all
# because a preset is a look and does not carry paths to files on one
# machine. So the close has to ask -- but only when there is an answer worth
# giving, which is the part worth testing.
#
# _unsaved rather than the dialog: the decision is the interesting half, and a
# dialog cannot be asked what it would have said without blocking the suite on
# a button nobody is going to press.

my $gui = GlitchVape::GUI->new;

# ---------------------------------------------------------------------------
# Nothing to lose closes without a word

# A window opened and closed again, which is most of them. A dialog here is one
# people learn to click through, and then it is not read when it matters.
{
    is_deeply [ $gui->_unsaved ], [],
        'a window with nothing in it has nothing to lose';

    ok $gui->_confirm_close, 'so closing it is allowed without asking anything';
}

# ---------------------------------------------------------------------------
# A pipeline is worth asking about, and is counted

# The state is built directly rather than by opening a file: what is at risk is
# the configuration, and whether an image happens to be loaded behind it makes
# no difference to that.
{
    $gui->{ state } = GlitchVape::GUI::State->new( source => 'nowhere.png' );

    $gui->{ state }->add_effect( 'scanlines' );
    is_deeply [ $gui->_unsaved ], [ 'one effect' ],
        'one effect is named in the singular';

    $gui->{ state }->add_effect( 'grain' );
    $gui->{ state }->add_effect( 'bloom' );
    is_deeply [ $gui->_unsaved ], [ '3 effects' ], 'and several are counted';
}

# ---------------------------------------------------------------------------
# A soundtrack is listed separately, because it is the part a preset cannot keep

# Both kinds count and they add up: a file and a generated track are two things
# to rebuild, and saying "a soundtrack" would undercount the work.
{
    $gui->{ audio } = { path => '/nowhere/track.wav' };
    is_deeply [ $gui->_unsaved ], [ '3 effects', 'a soundtrack' ],
        'an audio file is named alongside the effects';

    $gui->{ audio } = { generated => [ { kind => 'dtmf' } ] };
    is_deeply [ $gui->_unsaved ], [ '3 effects', 'a soundtrack' ],
        'and so is a single generated track';

    $gui->{ audio } = {
        path      => '/nowhere/track.wav',
        generated => [ { kind => 'dtmf' }, { kind => 'geiger' } ],
    };
    is_deeply [ $gui->_unsaved ], [ '3 effects', '3 tracks' ],
        'a file and two generated tracks are three things to rebuild';
}

# ---------------------------------------------------------------------------
# A soundtrack alone is enough

# Assembling a mix is work even with no effects on the picture, and it is the
# work that no preset can rescue.
{
    $gui->{ state } = GlitchVape::GUI::State->new( source => 'nowhere.png' );

    is_deeply [ $gui->_unsaved ], [ '3 tracks' ],
        'a soundtrack on its own is still worth a warning';

    $gui->{ audio } = undef;
    is_deeply [ $gui->_unsaved ], [],
        'and clearing it leaves nothing to warn about again';

    ok $gui->_confirm_close, 'which closes silently once more';
}

# ---------------------------------------------------------------------------
# The answer is wired to the window the right way round

# delete-event runs backwards from every other handler here: returning TRUE
# stops the close rather than reporting success. Inverted, the confirmation
# either never appears or makes the window impossible to shut -- and both
# survive every other test in the suite, because the dialog itself is fine and
# only the wiring is wrong.
{
    $gui->{ window }->show_all;
    Gtk3::main_iteration while Gtk3::events_pending;

    my $event = Gtk3::Gdk::Event->new( 'delete' );

    # _confirm_close is replaced rather than driven, so this asks about the
    # wiring alone and never opens a dialog the suite would then sit on. Same
    # deliberate reach into a private sub as t/28-generators.t makes, and for
    # the same reason: the alternative is driving a dialog nobody can click.
    for my $case ( [ 1, 0, 'allowed' ], [ 0, 1, 'blocked' ] )
    {
        my ( $answer, $want, $what ) = @$case;

        no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        ## no critic (Variables::ProtectPrivateVars)
        local *GlitchVape::GUI::_confirm_close = sub { return $answer };
        ## use critic

        my $stopped = $gui->{ window }->signal_emit( 'delete-event', $event );

        is !!$stopped, !!$want,
              "answering "
            . ( $answer ? 'yes' : 'no' )
            . " leaves the close $what";
    }
}

done_testing;
