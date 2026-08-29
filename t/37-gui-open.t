#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Encode     ();
use File::Spec ();
use File::Temp ();
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

# Opening a second photograph used to replace the state, which threw away the
# pipeline, the soundtrack and the whole undo history of the first one -- in
# one click, silently, with no way back since the history went with it.
#
# It starts a second instance instead. What is pinned here is that the first
# window keeps everything it had, in the failure cases as much as in the happy
# one: a fallback to opening the file in this window would be the exact thing
# this exists to prevent.

my $dir = File::Temp->newdir;

# Stands in for bin/glitchvape-gui. It records the arguments it was handed and
# exits, which is everything this needs to know about the new instance --
# whether a real one draws a window is bin/glitchvape-gui's business and is
# not worth a second Gtk process in the suite.
sub stub_program
{
    my ( $out ) = @_;

    my $path = "$dir/stub-program.pl";

    open my $fh, '>', $path or die "cannot write $path: $!";
    print { $fh } <<"END_STUB";
open my \$fh, '>', '$out' or exit 3;
print { \$fh } join "\\n", \@ARGV;
close \$fh;
END_STUB
    close $fh or die "cannot write $path: $!";

    return $path;
}

# The child is reaped by a Glib::Child watch inside the window, so the loop
# has to keep turning while this waits. A deadline rather than a fixed sleep:
# an exec is quick, and a suite that waits a flat second per test for it is a
# suite people stop running.
sub wait_for_file
{
    my ( $path ) = @_;

    my $deadline = time + 10;

    while ( time < $deadline )
    {
        Gtk3::main_iteration while Gtk3::events_pending;
        return 1 if -s $path;

        select undef, undef, undef, 0.02;    ## no critic (ProhibitSleepViaSelect)
    }

    return 0;
}

sub slurp
{
    my ( $path ) = @_;

    open my $fh, '<', $path or die "cannot read $path: $!";
    my $text = do { local $/ = undef; <$fh> };
    close $fh or die "cannot read $path: $!";

    return $text;
}

sub opened_gui
{
    my ( %arg ) = @_;

    my $gui = GlitchVape::GUI->new( %arg );

    # Straight into the state rather than through _open_file, which probes the
    # file with a magick subprocess: what these tests are about is what
    # happens to the state, and a real photograph would only slow them down.
    $gui->{ state } =
        GlitchVape::GUI::State->new( source => 'first.png', seed => 7 );
    $gui->{ state }->add_effect( 'scanlines' );
    $gui->{ state }->commit;

    return $gui;
}

# ---------------------------------------------------------------------------
# The first Open fills the window it was pressed in

# There is nothing to lose yet, so spawning here would leave an empty window
# behind for no reason.

{
    my $gui = GlitchVape::GUI->new;

    ok !$gui->_has_source, 'a window with nothing open says so';

    $gui->{ state } =
        GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );

    ok $gui->_has_source, 'and one with a photograph in it says that';
}

# ---------------------------------------------------------------------------
# The second Open starts a second instance

{
    my $out     = "$dir/argv-plain";
    my $gui     = opened_gui( program => stub_program( $out ) );
    my @history = $gui->{ state }->depth;

    ok $gui->_open_elsewhere( "$dir/second.png" ), 'a second window is opened';

    ok wait_for_file( $out ), 'and the new instance really was executed';

    my @argv = split /\n/, slurp( $out );

    is $argv[ 0 ], "$dir/second.png",
        'the new instance is handed the file that was chosen';

    # The window this was pressed in is untouched -- which is the whole point,
    # so it is asserted about the state rather than about the picture.
    is $gui->{ state }->source, 'first.png', 'the first window keeps its file';
    is_deeply [ $gui->{ state }->effect_names ], [ 'scanlines' ],
        'and its pipeline';
    is_deeply [ $gui->{ state }->depth ], \@history, 'and its history';
}

# ---------------------------------------------------------------------------
# A filename that is not ASCII survives the handover

# The chooser hands back character data -- 'Zdjęcie.png' is eleven characters
# and twelve bytes -- and exec passes the internal form. Encoding it on the
# way out is what makes it the same name on the way back in, where
# bin/glitchvape-gui decodes @ARGV as UTF-8.

{
    my $out  = "$dir/argv-utf8";
    my $gui  = opened_gui( program => stub_program( $out ) );
    my $name = "$dir/Zdjęcie ćmy.png";

    ok utf8::is_utf8( $name ), 'the name under test really is character data';

    $gui->_open_elsewhere( $name );
    ok wait_for_file( $out ), 'the new instance was executed';

    is Encode::decode( 'UTF-8', slurp( $out ) ), $name,
        'and the name it was handed decodes back to the one chosen';
}

# ---------------------------------------------------------------------------
# Nowhere to start it from is reported, not worked around

# The obvious fallback -- open it in this window after all -- is the behaviour
# this whole thing exists to prevent, so there is deliberately none.

{
    # _report says it on stderr as well as in the infobar, and a suite that
    # prints its expected failures reads like a broken one.
    #
    # Held open for the block rather than closed at once, which is the whole
    # point of it: it is STDERR for as long as the failures are being
    # provoked, and closing it early would put them back on the terminal.
    ## no critic (InputOutput::RequireBriefOpen)
    open my $quiet, '>', File::Spec->devnull
        or die "cannot open the null device: $!";
    ## use critic
    local *STDERR = $quiet;

    for my $program ( undef, "$dir/no-such-program" )
    {
        my $gui = opened_gui( program => $program );

        my $what = 'no program at all';
        $what = 'a program that is not there' if defined $program;

        ok !$gui->_open_elsewhere( "$dir/second.png" ), "$what reports failure";

        like $gui->{ infobar_label }->get_text, qr/nothing was opened/,
            'and says so where the window says things';

        is $gui->{ state }->source, 'first.png',
            'while the work in this window stays where it was';
    }
}

done_testing;
