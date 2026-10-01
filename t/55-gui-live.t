#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp  ();
use Time::HiRes ();
use Test::More;

# Gtk, because the render child is reaped by a Glib child watch.
BEGIN
{
    eval { require Gtk3; Gtk3->import; 1 }
        or plan skip_all => 'Gtk3 is not available';
    Gtk3::init_check()
        or plan skip_all => 'no display';
}

use GlitchVape        ();
use GlitchVape::GUI   ();
use GlitchVape::Tools ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );

# The preview follows the settings: a still is rendered a moment after a
# control moves, without Apply, and Apply keeps a step in the history. What is
# pinned here is the ordering, because that is where it can go wrong without
# anything looking broken -- a render thrown away under an export, a picture
# left behind the settings, a window greyed out by a render nobody asked for.

my $root = File::Temp->newdir( 'gv_guilive_XXXXXX', TMPDIR => 1 );

# Its own cache and preferences, so that neither what this machine has
# rendered before nor a preference saved here can decide the outcome.
local $ENV{ XDG_CACHE_HOME }      = "$root/cache";
local $ENV{ GLITCHVAPE_PROFILES } = "$root/profiles";
local $ENV{ GLITCHVAPE_PRESETS }  = "$FindBin::Bin/../presets";

# Written by a child, so that this process never decodes an image: that is
# the rule the window keeps, and the one the render child relies on.
my $picture = "$root/photo.png";
{
    my $pid = fork // die "fork: $!";
    unless ( $pid )
    {
        require Image::Magick;
        my $img = Image::Magick->new( size => '320x240' );
        $img->Read( 'gradient:#102050-#F0C080' );
        $img->Draw(
            primitive => 'rectangle',
            points    => '60,50 200,180',
            fill      => '#E02070',
        );
        $img->Write( $picture );
        require POSIX;
        POSIX::_exit( 0 );
    }
    waitpid $pid, 0;
}

BAIL_OUT( 'could not build the test picture' ) unless -s $picture;

my $gui = GlitchVape::GUI->new;
$gui->{ prefs }{ live_preview } = 1;
$gui->{ preview_size } = 200;

# What the window put on screen, and what it asked the render child for.
my ( @shown, @spawned, @cancelled );
{
    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    ## use critic

    my $show = \&GlitchVape::GUI::Preview::show_still;
    *GlitchVape::GUI::Preview::show_still = sub {
        push @shown, $_[ 1 ];
        return $show->( @_ );
    };

    # A preview started while an export is still the job in hand would be
    # one that cancelled it, so that is recorded as such. The render's own
    # spawn is replaced to see that, which is reaching into it on purpose.
    ## no critic (Variables::ProtectPrivateVars)
    my $spawn = \&GlitchVape::GUI::Render::_spawn;
    *GlitchVape::GUI::Render::_spawn = sub {
        my ( $self, %job ) = @_;
        my $under = $self->{ job } && !defined $self->{ job }{ key };
        push @spawned,
              !defined $job{ key } ? 'export'
            : $under               ? 'preview over an export'
            :                        'preview';
        return $spawn->( @_ );
    };
    ## use critic

    my $cancel = \&GlitchVape::GUI::Render::cancel;
    *GlitchVape::GUI::Render::cancel = sub {
        push @cancelled, 1 if $_[ 0 ]{ job };
        return $cancel->( @_ );
    };
}

# The main loop turned by hand until $done says so: the render child is
# reaped, and the live preview's timer fires, only from in here.
sub pump_until
{
    my ( $done, $limit ) = @_;
    my $until = Time::HiRes::time() + ( $limit // 60 );

    while ( !$done->() && Time::HiRes::time() <= $until )
    {
        if   ( Gtk3::events_pending() ) { Gtk3::main_iteration_do( 0 ) }
        else                            { Time::HiRes::sleep( 0.01 ) }
    }

    return $done->();
}

# Long enough for a change to have been rendered if it was going to be.
sub pump_for
{
    my ( $seconds ) = @_;
    my $until = Time::HiRes::time() + $seconds;
    pump_until( sub { Time::HiRes::time() > $until }, $seconds + 1 );
    return;
}

sub settled
{
    return
           !$gui->{ render }->busy
        && !$gui->{ live_timer }
        && !$gui->{ live_owed };
}

sub on_screen_is_settings
{
    my $want = $gui->{ render }->preview_key( $gui->_preview_args );
    return ( $gui->{ shown_key } // q{} ) eq $want;
}

sub reset_record { @shown = @spawned = @cancelled = (); return }

# ---------------------------------------------------------------------------
# Opening a photograph with a preset shows both, Apply or not

$gui->_open_file( $picture, preset => 'vhs-decay', seed => 3 );

ok pump_until( sub { @shown >= 2 && settled() } ),
    'opening with a preset puts the photograph and then the preset on screen';
ok on_screen_is_settings(), 'and the second is the preset';

my $state = $gui->{ state };

# ---------------------------------------------------------------------------
# A change is rendered on its own, without greying the window

{
    reset_record();

    $state->param( 'vignette', 'strength', 0.31 );
    $gui->_touch;

    ok pump_until( sub { $gui->{ render }->busy || @shown } ),
        'a change starts a render without Apply';
    ok !$gui->{ blocking }, 'which holds nothing else up';
    is $gui->{ apply_label }->get_label, '_Apply',
        'and leaves Apply saying Apply';

    ok pump_until( sub { @shown && settled() } ), 'and is shown';
    ok on_screen_is_settings(), 'showing what the controls say';

    my ( $back ) = $state->depth;

    reset_record();
    $gui->_apply;
    pump_until( sub { @shown && settled() } );

    is scalar( @spawned ), 0,
        'Apply then renders nothing: the picture is already drawn';
    is( ( $state->depth )[ 0 ], $back + 1, 'and keeps it as a step' );
}

# ---------------------------------------------------------------------------
# A change while a render is under way waits for it instead of discarding it

{
    reset_record();

    $state->param( 'grade', 'saturation', 140 );
    $gui->_touch;
    pump_until( sub { $gui->{ render }->busy } );

    $state->param( 'grade', 'saturation', 90 );
    $gui->_touch;

    ok pump_until( sub { settled() && @shown >= 2 } ),
        'a change during a render is rendered after it';
    is scalar( @cancelled ), 0, 'with nothing thrown away';
    ok on_screen_is_settings(), 'ending on the last change';
}

# ---------------------------------------------------------------------------
# An export is never cancelled for a still; the still follows it

{
    reset_record();

    # Held for a second before it renders anything, so that the change below
    # is certain to arrive while it is running. The export child is forked
    # inside _export, and takes the stand-in with it.
    my $out = "$root/export.png";
    {
        ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        no warnings 'redefine';
        ## use critic
        my $real = \&GlitchVape::render;
        local *GlitchVape::render = sub { sleep 1; return $real->( @_ ) };
        $gui->_export( $out );
    }
    pump_until( sub { $gui->{ render }->busy } );

    ok $gui->{ blocking }, 'an export holds the window';

    $state->param( 'grade', 'saturation', 110 );
    $gui->_touch;

    ok pump_until( sub { $gui->{ live_owed } }, 0.9 ),
        'a change during it is owed a render rather than given one';

    is scalar( grep { /over an export/ } @spawned ), 0,
        'a change during it starts no render over it';
    is scalar( @cancelled ), 0, 'and cancels nothing';

    ok pump_until( sub { -s $out && settled() && @shown }, 120 ),
        'the export finishes, and the still it was owed follows';
    ok on_screen_is_settings(), 'showing the change made meanwhile';
}

# ---------------------------------------------------------------------------
# The Add wizard draws its previews through the same child, so the live
# preview waits for it

{
    my $wizard = $gui->_choose_effect;
    ok $wizard, 'the wizard opens';

    reset_record();

    $state->param( 'grade', 'saturation', 120 );
    $gui->_touch;
    pump_for( 0.5 );

    is scalar( @shown ), 0, 'a change while it is open is not rendered';

    $wizard->_finish;

    ok pump_until( sub { @shown && settled() } ),
        'and is rendered once it has gone';
    ok on_screen_is_settings(), 'as the settings are now';
}

# ---------------------------------------------------------------------------
# Undo first takes back what has not been applied

{
    $gui->_apply;
    pump_until( sub { settled() } );

    my $applied = $state->param( 'grade', 'saturation' );

    $state->param( 'grade', 'saturation', 70 );
    $gui->_touch;
    pump_until( sub { settled() && on_screen_is_settings() } );

    reset_record();
    $gui->_step_history( 'undo' );
    pump_until( sub { @shown && settled() } );

    is $state->param( 'grade', 'saturation' ), $applied,
        'undo comes back to the last Apply rather than past it';
    ok on_screen_is_settings(), 'and shows it';
}

# ---------------------------------------------------------------------------
# Off, and for a loop, nothing happens until Apply

{
    $gui->{ prefs }{ live_preview } = 0;
    reset_record();

    $state->param( 'grade', 'saturation', 95 );
    $gui->_touch;
    pump_for( 0.6 );

    is scalar( @spawned ), 0, 'with the live preview off a change waits';

    $gui->{ prefs }{ live_preview } = 1;
    $gui->{ b_animate }->set_active( 1 );
    reset_record();

    $state->param( 'grade', 'saturation', 96 );
    $gui->_touch;
    pump_for( 0.6 );

    is scalar( @spawned ), 0, 'and so does one made for a loop';

    $gui->{ b_animate }->set_active( 0 );

    ok pump_until( sub { @shown && settled() } ),
        'and switching back to a still catches the preview up';
    ok on_screen_is_settings(), 'with every change made meanwhile';
}

$gui->{ closed } = 1;
$gui->{ window }->destroy;

done_testing;
