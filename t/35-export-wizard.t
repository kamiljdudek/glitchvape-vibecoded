#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

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

use GlitchVape                    ();
use GlitchVape::GUI::Export       ();
use GlitchVape::GUI::ExportWizard ();
use GlitchVape::GUI::Profiles     ();

my $dir = File::Temp->newdir( 'gv_wizard_XXXXXX', TMPDIR => 1 );
local $ENV{ GLITCHVAPE_PROFILES } = "$dir";

sub wizard
{
    my ( %arg ) = @_;

    return GlitchVape::GUI::ExportWizard->run(
        source  => '/somewhere/IMG_8111.jpg',
        preset  => 'sunset',
        on_done => sub { },
        %arg,
    );
}

# The route the assistant would take from the first page to the last, by asking
# the same forward function the assistant asks.
sub route
{
    my ( $wiz, $express ) = @_;

    $wiz->{ express } = $express;

    my @seen = ( 0 );
    my $at   = 0;

    while ( $at < GlitchVape::GUI::ExportWizard::PAGE_WHERE() )
    {
        my $next = $wiz->_next( $at );
        last if $next <= $at;
        push @seen, $next;
        $at = $next;
    }

    return \@seen;
}

# ---------------------------------------------------------------------------
# Express is one page and then the destination

# The point of the express route is that it is short. If it ever starts walking
# the middle pages it has stopped being the thing it is offered as.
{
    for my $animated ( 0, 1 )
    {
        my $wiz = wizard( animated => $animated );

        is_deeply route( $wiz, 1 ),
            [ 0, GlitchVape::GUI::ExportWizard::PAGE_WHERE() ],
            "express goes straight to the destination ("
            . ( $animated ? 'video' : 'still' ) . ')';

        $wiz->{ assistant }->destroy;
    }
}

# ---------------------------------------------------------------------------
# The advanced route asks only what applies

# A still has no frame rate and the video formats have no options of their own,
# so each drops the page the other needs. A page shown greyed out to say it
# does not apply teaches nothing that leaving it out does not.
{
    my $still = wizard( animated => 0 );
    is_deeply route( $still, 0 ),
        [
        0,
        GlitchVape::GUI::ExportWizard::PAGE_SIZE(),
        GlitchVape::GUI::ExportWizard::PAGE_FORMAT(),
        GlitchVape::GUI::ExportWizard::PAGE_OPTION(),
        GlitchVape::GUI::ExportWizard::PAGE_WHERE(),
        ],
        'a still is asked about format options and not about frame rate';
    $still->{ assistant }->destroy;

    my $video = wizard( animated => 1 );
    is_deeply route( $video, 0 ),
        [
        0,
        GlitchVape::GUI::ExportWizard::PAGE_SIZE(),
        GlitchVape::GUI::ExportWizard::PAGE_FORMAT(),
        GlitchVape::GUI::ExportWizard::PAGE_MOTION(),
        GlitchVape::GUI::ExportWizard::PAGE_WHERE(),
        ],
        'and a video the other way round';
    $video->{ assistant }->destroy;
}

# ---------------------------------------------------------------------------
# The destination is filled in, and it is somewhere sensible

# The filename is the whole reason the express route can be one click: if it
# arrived empty there would be nothing express about it.
{
    my $wiz = wizard( animated => 1 );
    $wiz->_prepare( $wiz->{ where_page } );

    like $wiz->{ name }->get_text, qr/\A IMG_8111 .* [.] mp4 \z/x,
        'a video is named after the source and the chosen container';

    ok defined $wiz->{ folder }->get_filename, 'and a folder is already chosen';

    ok length $wiz->{ summary }->get_text,
        'with a line saying what is about to be written';

    $wiz->{ assistant }->destroy;
}

# ---------------------------------------------------------------------------
# What comes out is a whole settings hash and a whole path

# The caller renders straight from these, so a missing key here is a render
# with a default silently substituted for something the user chose.
{
    my $got;
    my $wiz = wizard( animated => 0, on_done => sub { $got = [ @_ ] } );

    $wiz->_prepare( $wiz->{ where_page } );
    $wiz->_finish;

    ok $got, 'on_done fires when the assistant is applied';

    my ( $settings, $path ) = @$got;

    for my $key ( sort keys %{ GlitchVape::GUI::Profiles::defaults() } )
    {
        ok exists $settings->{ $key }, "the settings carry $key";
    }

    ok $path =~ m{/}, 'and the path has a directory on it';
    like $path, qr/IMG_8111/, 'named after the source';
}

# ---------------------------------------------------------------------------
# Express applies the profile it was showing

# The profile is applied on the way into the last page rather than when it is
# picked, so this checks the settings that come out are the profile's and not
# the ones the wizard opened with.
{
    my $all = GlitchVape::GUI::Profiles::load();

    push @$all,
        {
        name     => 'Test · tiny webm',
        kind     => 'video',
        builtin  => 0,
        settings => { video_size => 512, video_format => 'webm', fps => 5 },
        };
    GlitchVape::GUI::Profiles::save( $all );

    my $got;
    my $wiz = wizard(
        animated => 1,
        settings => { video_size => 1920, video_format => 'mp4', fps => 30 },
        on_done  => sub { $got = [ @_ ] },
    );

    # Pick the one just added, wherever the list put it.
    my $at;
    for my $n ( 0 .. $#{ $wiz->{ profile_order } } )
    {
        $at = $n if $wiz->{ profile_order }[ $n ]{ name } eq 'Test · tiny webm';
    }

    ok defined $at, 'the saved profile is offered on the express page';

SKIP:
    {
        skip 'profile not offered', 3 unless defined $at;

        $wiz->{ profile_list }->set_active( $at );
        $wiz->{ express } = 1;
        $wiz->_prepare( $wiz->{ where_page } );
        $wiz->_finish;

        is $got->[ 0 ]{ video_size }, 512,
            'express exports at the profile size, not the one it opened with';
        is $got->[ 0 ]{ fps }, 5, 'and the profile frame rate';
        like $got->[ 1 ], qr/[.]webm\z/,
            'and names the file for the profile container';
    }
}

# ---------------------------------------------------------------------------
# The profiles pane says why a button is unavailable, not just that it is

# The action bar is icons alone, so every word about it lives in a tooltip --
# including the one that has something to explain. A greyed-out Remove with no
# tooltip is a button that has stopped working for no stated reason.
#
# It only reads as unavailable rather than broken because the tooltip is on an
# EventBox around the button instead of on the button: an insensitive widget
# takes no pointer events, and a tooltip needs the pointer to be over
# something.
{
    my $profiles = GlitchVape::GUI::Profiles::load();

    push @$profiles,
        {
        name     => 'Mine to delete',
        kind     => 'video',
        builtin  => 0,
        settings => { video_size => 1080 },
        };

    my $window = Gtk3::Window->new( 'toplevel' );

    ## no critic (Subroutines::ProtectPrivateSubs)
    my $pane =
        GlitchVape::GUI::Export::_profile_pane( $window, $profiles, 'video' );
    ## use critic

    $window->add( $pane->{ page } );
    $window->show_all;
    Gtk3::main_iteration while Gtk3::events_pending;

    # The bar is EventBoxes, one around each button, in the order they were
    # packed: Add, Duplicate, Edit, Remove.
    my @wrappers;
    my $walk;
    $walk = sub {
        my ( $widget ) = @_;
        push @wrappers, $widget if $widget->isa( 'Gtk3::EventBox' );
        return unless $widget->can( 'get_children' );
        $walk->( $_ ) for $widget->get_children;
        return;
    };
    $walk->( $pane->{ page } );

    is scalar @wrappers, 4, 'the action bar has four buttons';

    my $list;
    my $find;
    $find = sub {
        my ( $widget ) = @_;
        $list = $widget if $widget->isa( 'Gtk3::ListBox' );
        return unless $widget->can( 'get_children' );
        $find->( $_ ) for $widget->get_children;
        return;
    };
    $find->( $pane->{ page } );

    my $remove = $wrappers[ 3 ];
    my ( $remove_button ) = $remove->get_children;

    ok $remove->get_sensitive,
        'the box around Remove stays sensitive so it can be pointed at';

    my @rows = $list->get_children;

    # A shipped profile: not removable at all, and the tooltip says which of
    # the two reasons it is.
    $list->select_row( $rows[ 0 ] );
    Gtk3::main_iteration while Gtk3::events_pending;

    ok !$remove_button->get_sensitive,
        'Remove is unavailable for a default profile';
    is $remove->get_tooltip_text, 'You cannot remove a default profile',
        'and says so rather than leaving the user guessing';

    # Edit goes the same way, and for a sharper reason than matching Remove.
    # Editing a default used to work by turning it into the user's own copy,
    # and the only way back was noticing that Remove had become available --
    # a permanent change with an undiscoverable undo. Read-only is simpler.
    my $edit = $wrappers[ 2 ];
    my ( $edit_button ) = $edit->get_children;

    ok !$edit_button->get_sensitive,
        'a default profile cannot be edited either';
    like $edit->get_tooltip_text, qr/[Dd]uplicate/,
        'and the tooltip points at the way forward instead of only refusing';

    # Duplicate stays available on a default: it is that way forward.
    my ( $copy_button ) = $wrappers[ 1 ]->get_children;
    ok $copy_button->get_sensitive, 'and duplicating one is allowed';

    # One of the user's own: removable, and the tooltip names it.
    $list->select_row( $rows[ -1 ] );
    Gtk3::main_iteration while Gtk3::events_pending;

    ok $remove_button->get_sensitive, 'Remove works on a profile of your own';
    ok $edit_button->get_sensitive,   'and so does Edit';
    like $remove->get_tooltip_text, qr/Mine to delete/,
        'and names the one it would remove';

    # Nothing selected is a third state and not the same sentence as either.
    $list->unselect_all;
    Gtk3::main_iteration while Gtk3::events_pending;

    is $remove->get_tooltip_text, 'Select a profile to remove',
        'with nothing selected it asks for a selection instead';

    $window->destroy;
}

done_testing;
