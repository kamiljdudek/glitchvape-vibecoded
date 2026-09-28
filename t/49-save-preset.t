#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Cwd        ();
use File::Path ();
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
use GlitchVape::Config     ();
use GlitchVape::GUI        ();
use GlitchVape::GUI::State ();

# Save as preset wrote into whichever directory came first on the preset
# path. From a checkout that was the checkout's own presets/, so a preset
# saved while trying things out landed in the source tree; from an installed
# package it was the package's data directory, owned by root, and saving
# failed with "Permission denied". What is pinned here is that a saved preset
# goes in a directory that belongs to the person saving it, and that the
# window says so before shadowing anything.

my $tmp  = File::Temp->newdir( 'gv_save_XXXXXX', TMPDIR => 1 );
my $home = "$tmp/xdg";

local $ENV{ XDG_DATA_HOME } = $home;
delete local $ENV{ GLITCHVAPE_PRESETS };

# Away from the checkout, so ./presets is not the checkout's.
my $was = Cwd::getcwd();
chdir "$tmp" or die "chdir: $!";

my $mine = "$home/glitchvape/presets";

my $gui = GlitchVape::GUI->new;
$gui->{ state } =
    GlitchVape::GUI::State->new( source => 'photo.png', seed => 3 );
$gui->{ state }->add_effect( 'scanlines' );

# The dialogs are replaced rather than driven: what matters is which question
# was asked and what happened after each answer.
my @asked;
my $answer = 1;
my @reported;

no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
## no critic (Variables::ProtectPrivateVars)
local *GlitchVape::GUI::_confirm = sub { push @asked, $_[ 1 ]; return $answer };
local *GlitchVape::GUI::_report  = sub { push @reported, $_[ 1 ]; return };
## use critic
use warnings 'redefine';

# ---------------------------------------------------------------------------
# Saying no leaves nothing behind

# The name is one the program ships, so the window asks first -- and a no
# must not have made the directory on the way to asking.
{
    $answer = 0;
    $gui->_write_preset( 'vhs-decay', 'Mine', 0 );

    is scalar @asked, 1, 'saving over a shipped name asks first';
    like $asked[ 0 ], qr/already a preset called “vhs-decay”/,
        'naming the preset it would stand in for';
    ok !-e $mine,
        'and answering no leaves nothing behind, not even a directory';
}

# ---------------------------------------------------------------------------
# A new name goes into the directory that is yours

{
    @asked  = ();
    $answer = 1;

    $gui->_write_preset( 'mine', 'Mine', 0 );

    ok -f "$mine/mine.yml", 'a preset is saved under XDG_DATA_HOME';
    is scalar @asked, 0, 'without a question, when the name is new';

    my $checkout = "$FindBin::Bin/../presets/mine.yml";
    ok !-e $checkout, 'and never into the checkout it was run from';

    is GlitchVape::Config::find_preset( 'mine' ), "$mine/mine.yml",
        'and it is found by name straight away';
}

# ---------------------------------------------------------------------------
# A shipped name, answered yes

# The saved one is searched first, so the name means it from now on -- the
# shipped one is still there, and is what the name means again once the saved
# one is deleted.
{
    @asked  = ();
    $answer = 1;

    $gui->_write_preset( 'vhs-decay', 'Mine', 0 );

    is scalar @asked, 1, 'a shipped name is asked about again';
    is GlitchVape::Config::find_preset( 'vhs-decay' ), "$mine/vhs-decay.yml",
        'and once saved, the name finds yours';

    unlink "$mine/vhs-decay.yml";
    like GlitchVape::Config::find_preset( 'vhs-decay' ),
        qr{presets/vhs-decay[.]yml\z}, 'and the shipped one again without it';
    isnt GlitchVape::Config::find_preset( 'vhs-decay' ), "$mine/vhs-decay.yml",
        'which was never touched';
}

# ---------------------------------------------------------------------------
# Your own name, again

{
    @asked  = ();
    $answer = 1;

    $gui->_write_preset( 'mine', 'Mine again', 0 );

    is scalar @asked, 1, 'saving over one of your own asks';
    like $asked[ 0 ], qr/Replace the existing preset \Q$mine\E/,
        'and says it would be replaced';
}

# ---------------------------------------------------------------------------
# An explicit directory is obeyed

# Whoever sets GLITCHVAPE_PRESETS has said where presets live.
{
    my $elsewhere = "$tmp/elsewhere";
    File::Path::make_path( $elsewhere );

    local $ENV{ GLITCHVAPE_PRESETS } = "$elsewhere:$tmp/second";

    @asked = ();
    $gui->_write_preset( 'there', 'There', 0 );

    ok -f "$elsewhere/there.yml",
        'with GLITCHVAPE_PRESETS set, a preset goes to its first directory';
}

# ---------------------------------------------------------------------------
# A directory that cannot be made is a message, not a crash

SKIP:
{
    skip 'running as root, which can write anywhere', 2 if $> == 0;

    my $shut = "$tmp/shut";
    File::Path::make_path( $shut );
    chmod 0500, $shut or die "chmod: $!";

    local $ENV{ XDG_DATA_HOME } = $shut;

    @reported = ();
    $gui->_write_preset( 'nowhere', 'Nowhere', 0 );

    is scalar @reported, 1,
        'a preset directory that cannot be made is reported';
    like $reported[ 0 ], qr/Cannot make the preset directory/,
        'as that, rather than as a failure to write the file';

    chmod 0700, $shut;
}

chdir $was;

done_testing;
