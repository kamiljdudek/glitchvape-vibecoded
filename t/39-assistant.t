#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

# Gtk, and the buttons only settle once the window is realised, so this needs
# a display rather than merely the bindings.
BEGIN
{
    eval { require Gtk3; Gtk3->import; 1 }
        or plan skip_all => 'Gtk3 is not available';
    Gtk3::init_check()
        or plan skip_all => 'no display';
}

use GlitchVape                    ();
use GlitchVape::GUI::Assistant    ();
use GlitchVape::GUI::ExportWizard ();
use GlitchVape::GUI::State        ();
use GlitchVape::GUI::Wizard       ();

my $dir = File::Temp->newdir( 'gv_assist_XXXXXX', TMPDIR => 1 );
local $ENV{ GLITCHVAPE_PROFILES } = "$dir";

# The navigation buttons live in the assistant's header bar and there is no
# accessor for any of them, so every question here is asked of the whole set
# and answered by which of them are on screen.
sub nav
{
    my ( $assistant ) = @_;

    return
        grep { $_->isa( 'Gtk3::Button' ) }
        _descendants( $assistant->get_titlebar );
}

sub _descendants
{
    my ( $widget ) = @_;

    return ()      unless $widget;
    return $widget unless $widget->can( 'get_children' );

    return $widget, map { _descendants( $_ ) } $widget->get_children;
}

# Positions rather than the widgets themselves, so a failure prints something
# a person can read and so the labels -- which are translated -- stay out of
# it entirely.
sub showing
{
    my ( @buttons ) = @_;

    return [ grep { $buttons[ $_ ]->get_visible } 0 .. $#buttons ];
}

# ---------------------------------------------------------------------------
# There is a button to suppress, and suppressing it takes that one and no
# other

# The half of this that could rot silently. If a later Gtk stops offering the
# jump-to-the-end button, or offers it under other rules, the wizards below
# would pass for the wrong reason -- there would be nothing to hide and no
# sign that the probe had stopped finding anything.
{
    my $assistant = Gtk3::Assistant->new;

    my @pages;
    for my $spec (
        [ content => 'One' ],
        [ content => 'Two' ],
        [ confirm => 'Three' ]
        )
    {
        my $page = Gtk3::Box->new( 'vertical', 4 );
        $page->pack_start( Gtk3::Label->new( $spec->[ 1 ] ), 0, 0, 0 );

        $assistant->append_page( $page );
        $assistant->set_page_type( $page, $spec->[ 0 ] );
        $assistant->set_page_title( $page, $spec->[ 1 ] );
        $assistant->set_page_complete( $page, 1 );

        push @pages, $page;
    }

    $assistant->show_all;

    my @buttons = nav( $assistant );
    ok @buttons, 'the assistant keeps its navigation in a header bar';

    my $before = showing( @buttons );

    my $suppressed = GlitchVape::GUI::Assistant::navigate( $assistant );
    ok $suppressed,
        'the jump-to-the-end button is found by what it responds to';

    my $after = showing( @buttons );

    is scalar @$after, scalar @$before - 1,
        'and hiding it takes exactly one button off the page';

SKIP:
    {
        skip 'no button was identified', 1 unless $suppressed;

        my %gone = map { $_ => 1 } @$before;
        delete $gone{ $_ } for @$after;

        my ( $which ) = keys %gone;
        is $buttons[ $which ], $suppressed,
            'the one it took is the one it said it had found';
    }

    $assistant->destroy;
}

# ---------------------------------------------------------------------------
# No page grows a button because of how far it is from the end

# What the suppression is for. Gtk shows the jump-to-the-end button whenever
# the pages ahead of the current one are complete, which is a fact about the
# walk rather than about the page -- so a page had one set of buttons the
# first time it was seen and another set on the way back through it.
#
# Asked by marking every page complete, which is the state an assistant is in
# once somebody has been to the end and pressed Back.
sub steady
{
    my ( $assistant, $what ) = @_;

    my $count   = $assistant->get_n_pages;
    my @pages   = map { $assistant->get_nth_page( $_ ) } 0 .. $count - 1;
    my @buttons = nav( $assistant );

    for my $at ( 0 .. $count - 1 )
    {
        $assistant->set_current_page( $at );

        $assistant->set_page_complete( $_, 0 ) for @pages[ $at + 1 .. $#pages ];
        my $ahead = showing( @buttons );

        $assistant->set_page_complete( $_, 1 ) for @pages;
        my $behind = showing( @buttons );

        is_deeply $behind, $ahead,
            "$what page $at looks the same whether or not the rest is done";
    }

    return;
}

{
    for my $animated ( 0, 1 )
    {
        my $wiz = GlitchVape::GUI::ExportWizard->run(
            animated => $animated,
            source   => '/somewhere/IMG_8111.jpg',
            preset   => 'sunset',
            on_done  => sub { },
        );

        steady( $wiz->{ assistant },
            'export (' . ( $animated ? 'video' : 'still' ) . ')' );

        $wiz->{ assistant }->destroy;
    }
}

{
    my $state = GlitchVape::GUI::State->new( source => undef, seed => 3 );

    my $wiz = GlitchVape::GUI::Wizard->run(
        state    => $state,
        render   => FakeRender->new,
        on_apply => sub { },
    );

    steady( $wiz->{ assistant }, 'add effect' );

    $wiz->{ assistant }->destroy;
}

# ---------------------------------------------------------------------------
# Apply answers the question; close takes the window down

# These were one step, and the step destroyed the assistant. Gtk's own click
# handler goes on to work out whether there is a page after this one, so the
# file was written, the window was freed, and the program then read it:
#
#   Gtk-CRITICAL: gtk_assistant_get_n_pages: assertion 'GTK_IS_ASSISTANT'
#   Segmentation fault
#
# It only happened on a successful export, which is what made it look like the
# export had done it.
{
    my $got;

    my $wiz = GlitchVape::GUI::ExportWizard->run(
        animated => 0,
        source   => '/somewhere/IMG_8111.jpg',
        preset   => 'sunset',
        on_done  => sub { $got = [ @_ ] },
    );

    $wiz->{ assistant }
        ->set_current_page( GlitchVape::GUI::ExportWizard::PAGE_WHERE() );

    $wiz->{ assistant }->signal_emit( 'apply' );

    is $wiz->{ assistant }->get_n_pages, 6,
        'the assistant is still standing when apply returns';
    ok !$got,
        'and the export has not started under the window that asked for it';

    $wiz->{ assistant }->signal_emit( 'close' );

    ok $got, 'the export starts once the window has gone';
    like $got->[ 1 ], qr/IMG_8111/, 'with the destination the page was showing';
}

# Cancelling still says nothing to anybody.
{
    my $got;

    my $wiz = GlitchVape::GUI::ExportWizard->run(
        animated => 0,
        source   => '/somewhere/IMG_8111.jpg',
        preset   => 'sunset',
        on_done  => sub { $got = [ @_ ] },
    );

    $wiz->{ assistant }->signal_emit( 'cancel' );

    ok !$got, 'a cancelled assistant exports nothing';
}

# A stand-in for GlitchVape::GUI::Render, as in t/20-gui-wizard.t: the real
# one forks a child and wants an image on disk, and nothing here renders.
{

    package FakeRender;
    sub new     { return bless {}, shift }
    sub busy    { return 0 }
    sub cancel  { return }
    sub preview { return }
}

done_testing;
