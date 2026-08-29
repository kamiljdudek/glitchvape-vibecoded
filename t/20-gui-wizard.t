#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;

# The wizard is Gtk, so this needs a display. On a build machine without one
# there is nothing to test rather than something failing.
BEGIN
{
    eval { require Gtk3; Gtk3->import; 1 }
        or plan skip_all => 'Gtk3 is not available';
    Gtk3::init_check()
        or plan skip_all => 'no display';
}

use GlitchVape             ();
use GlitchVape::Registry   ();
use GlitchVape::GUI::State ();
use GlitchVape::GUI::Wizard;

# ---------------------------------------------------------------------------
# The taxonomy the first page is built from

{
    my @stages = GlitchVape::Registry->stages;

    is_deeply \@stages,
        [
        qw(format colour channels damage signal grain optics overlay framing) ],
        'stages are ordered as the pipeline runs them';

    for my $stage ( @stages )
    {
        my $info = GlitchVape::Registry->stage_info( $stage );
        ok length $info->{ title }, "$stage has a presentable title";
        ok length $info->{ blurb }, "$stage has a description";
        is $info->{ order }, GlitchVape::Registry::STAGES->{ $stage },
            "$stage agrees with STAGES on its order";
    }

    ok !GlitchVape::Registry->stage_info( 'destroy' ),
        'the old stage names are gone rather than aliased';
}

# Titles have to be unique, or the effect list shows two rows a person cannot
# tell apart.
{
    my $all = GlitchVape::Registry->all;
    my %seen;
    my @clashes;

    for my $name ( GlitchVape::Registry->names )
    {
        my $title = $all->{ $name }{ title };
        push @clashes, $title if $seen{ $title }++;
    }

    is_deeply \@clashes, [], 'every effect title is unique';
}

# ---------------------------------------------------------------------------
# Walking the three pages

sub wizard
{
    my ( %arg ) = @_;

    my $state = GlitchVape::GUI::State->new( source => undef, seed => 3 );
    $state->add_effect( $_ ) for @{ $arg{ present } || [] };

    my @applied;

    my $wizard = GlitchVape::GUI::Wizard->run(
        state    => $state,
        render   => FakeRender->new,
        on_apply => sub { push @applied, [ @_ ];               return },
        on_empty => sub { push @applied, [ 'EMPTY', $_[ 0 ] ]; return },
    );

    return ( $wizard, \@applied, $state );
}

# A stand-in for GlitchVape::GUI::Render. The real one forks a child and
# needs an image on disk; what is being tested here is the wizard's own
# sequencing, so it only has to record that a preview was asked for.
{

    package FakeRender;
    sub new    { return bless { asked => [] }, shift }
    sub busy   { return 0 }
    sub cancel { return }

    sub preview
    {
        my ( $self, %arg ) = @_;
        push @{ $self->{ asked } }, \%arg;
        return 'fake-key';
    }
}

{
    my ( $wizard, $applied ) = wizard();

    ok $wizard, 'the wizard opens when there are effects to add';

    my $assistant = $wizard->{ assistant };
    is $assistant->get_n_pages, 3, 'three pages';
    is $assistant->get_page_type( $assistant->get_nth_page( 2 ) ), 'confirm',
        'the last page is the one with Apply on it';

    # GtkListBox selects its first row on focus, so Continue is live from the
    # start rather than looking broken until something is clicked.
    ok $assistant->get_page_complete( $assistant->get_nth_page( 0 ) ),
        'the category page opens with a category chosen';
    is $wizard->{ stage }, 'format', 'and it is the first one in the chain';

    # Page 1: pick Signal & Tape.
    my ( $row ) =
        grep { $_->{ stage } eq 'signal' }
        $wizard->{ category_list }->get_children;
    ok $row, 'the signal category is offered';

    $wizard->{ category_list }->select_row( $row );
    is $wizard->{ stage }, 'signal', 'selecting a category records it';
    ok $assistant->get_page_complete( $assistant->get_nth_page( 0 ) ),
        'a chosen category completes the page';

    # Page 2: the effect list is filtered to that category.
    $wizard->_prepare( GlitchVape::GUI::Wizard::PAGE_EFFECT );

    my @visible =
        grep { $wizard->_matches( $_ ) } $wizard->{ effect_list }->get_children;

    is_deeply [ sort map { $_->{ effect } } @visible ],
        [ qw(dropout ghost head_switch interlace static tracking vhold wave) ],
        'the list shows exactly the chosen category';

    # Search reaches outside it, which is the point of having a search box.
    $wizard->{ query } = 'scanline';
    my @found =
        grep { $wizard->_matches( $_ ) } $wizard->{ effect_list }->get_children;
    is_deeply [ map { $_->{ effect } } @found ], [ 'scanlines' ],
        'search crosses categories';

    # Matching is over the title and summary as well as the internal name.
    $wizard->{ query } = 'aberration';
    @found =
        grep { $wizard->_matches( $_ ) } $wizard->{ effect_list }->get_children;
    is_deeply [ map { $_->{ effect } } @found ], [ 'chroma_shift' ],
        'search matches the presentable title, not just the key';

    $wizard->{ query } = 'wobble';
    @found =
        grep { $wizard->_matches( $_ ) } $wizard->{ effect_list }->get_children;
    is_deeply [ map { $_->{ effect } } @found ], [ 'wave' ],
        'the internal name need not be known to find the effect';

    $wizard->{ query } = q{};

    # Page 3: parameters, seeded with the declared defaults.
    my ( $wave ) = grep { $_->{ effect } eq 'wave' }
        $wizard->{ effect_list }->get_children;
    $wizard->{ effect_list }->select_row( $wave );
    is $wizard->{ effect }, 'wave', 'selecting an effect records it';

    $wizard->_prepare( GlitchVape::GUI::Wizard::PAGE_SETTINGS );

    is_deeply $wizard->{ params },
        GlitchVape::Registry->resolve_params( 'wave', {} ),
        'the settings page starts at the declared defaults';

    ok $assistant->get_page_complete( $assistant->get_nth_page( 2 ) ),
        'Apply is available as soon as the settings page is reached';

    # Apply hands the caller a name and a resolved parameter set.
    $wizard->{ params }{ amplitude } = 12;
    $wizard->_apply;

    is scalar @$applied,     1,               'apply reports once';
    is $applied->[ 0 ][ 0 ], 'wave',          'apply reports the internal name';
    is $applied->[ 0 ][ 1 ]{ amplitude }, 12, 'apply carries the settings';

    $wizard->_finish;
}

# Nothing the wizard does may reach the caller's state before Apply.
{
    my ( $wizard, undef, $state ) = wizard( present => [ 'grain' ] );

    my ( $row ) = grep { $_->{ stage } eq 'optics' }
        $wizard->{ category_list }->get_children;
    $wizard->{ category_list }->select_row( $row );
    $wizard->_prepare( GlitchVape::GUI::Wizard::PAGE_EFFECT );

    my ( $bloom ) = grep { $_->{ effect } eq 'bloom' }
        $wizard->{ effect_list }->get_children;
    $wizard->{ effect_list }->select_row( $bloom );
    $wizard->_prepare( GlitchVape::GUI::Wizard::PAGE_SETTINGS );

    $wizard->_set_param( 'threshold', 0.9 );

    is_deeply [ $state->effect_names ], [ 'grain' ],
        'previewing leaves the pipeline alone';

    $wizard->_finish;
    is_deeply [ $state->effect_names ], [ 'grain' ], 'cancelling adds nothing';
}

# An effect already in the pipeline is not offered again.
{
    my @all = GlitchVape::Registry->names;
    my ( $wizard, $applied ) = wizard( present => \@all );

    ok !$wizard, 'the wizard does not open with nothing left to add';
    is $applied->[ 0 ][ 0 ], 'EMPTY', 'the caller is told why';
}

{
    my ( $wizard ) = wizard( present => [ 'scanlines' ] );

    my ( $row ) = grep { $_->{ stage } eq 'optics' }
        $wizard->{ category_list }->get_children;
    $wizard->{ category_list }->select_row( $row );
    $wizard->_prepare( GlitchVape::GUI::Wizard::PAGE_EFFECT );

    my @offered = map { $_->{ effect } }
        grep { $wizard->_matches( $_ ) } $wizard->{ effect_list }->get_children;

    ok !( grep { $_ eq 'scanlines' } @offered ),
        'an effect already in the pipeline is not offered twice';
    ok( ( grep { $_ eq 'bloom' } @offered ), 'the rest of the category is' );

    $wizard->_finish;
}

# The preview renders the whole pipeline plus the candidate, against a copy.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 5 );
    $state->add_effect( 'grain' );

    my $render = FakeRender->new;

    my $wizard = GlitchVape::GUI::Wizard->run(
        state    => $state,
        render   => $render,
        on_apply => sub { return },
    );

    $wizard->{ effect }       = 'vignette';
    $wizard->{ settings_for } = 'vignette';
    $wizard->{ params } =
        GlitchVape::Registry->resolve_params( 'vignette', {} );

    $wizard->_preview;

    is scalar @{ $render->{ asked } }, 1, 'a preview is requested';

    my $asked = $render->{ asked }[ 0 ];
    is $asked->{ size }, GlitchVape::GUI::Wizard::PREVIEW_SIZE,
        'at thumbnail size';

    is_deeply [ $asked->{ state }->effect_names ], [ 'grain', 'vignette' ],
        'the preview is the pipeline plus the candidate';

    isnt $asked->{ state }, $state, 'rendered against a copy, not the state';
    is_deeply [ $state->effect_names ], [ 'grain' ],
        'and the real state is untouched';

    $wizard->_finish;
}

# ---------------------------------------------------------------------------
# Putting the settings back

# The controls are rebuilt rather than written into: GlitchVape::GUI::Params
# returns a control and a way to hear about changes, never a way to set one,
# and a setter per widget kind is the switch on type that module exists to
# avoid.
{
    my $state  = GlitchVape::GUI::State->new( source => undef, seed => 5 );
    my $render = FakeRender->new;

    my $wizard = GlitchVape::GUI::Wizard->run(
        state    => $state,
        render   => $render,
        on_apply => sub { return },
    );

    $wizard->{ effect } = 'vignette';
    $wizard->_prepare( GlitchVape::GUI::Wizard::PAGE_SETTINGS );

    my $defaults = GlitchVape::Registry->resolve_params( 'vignette', {} );

    ok !$wizard->{ reset_button }->get_sensitive,
        'nothing to reset on a page that has just been opened';

    $wizard->_set_param( 'strength', 0.9 );
    is $wizard->{ params }{ strength }, 0.9, 'a setting moved';
    ok $wizard->{ reset_button }->get_sensitive,
        'and now there is something to put back';

    $wizard->_reset_params;

    is_deeply $wizard->{ params }, $defaults,
        'reset puts every parameter back to what the effect declares';
    ok !$wizard->{ reset_button }->get_sensitive,
        'and says there is nothing left to reset';

    # Rebuilt, not merely re-recorded: a control still showing 0.9 over a
    # parameter holding the default is the worst of both.
    is $wizard->{ controls }{ strength }{ get }->(), $defaults->{ strength },
        'the control on screen shows the default too';

    $wizard->_finish;
}

# ---------------------------------------------------------------------------
# A preview belongs to the effect it was asked for

# Back, a different effect, forward again takes well under the second a
# preview costs, so the render started for the first one can land in the pane
# above the second one's controls. Cancelling is not enough on its own: a
# preview served from the cache never starts a child at all, so there is no
# job to cancel and its on_done is already queued on an idle.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 5 );
    my $render = FakeRender->new;

    my $wizard = GlitchVape::GUI::Wizard->run(
        state    => $state,
        render   => $render,
        on_apply => sub { return },
    );

    $wizard->{ effect } = 'vignette';
    $wizard->_prepare( GlitchVape::GUI::Wizard::PAGE_SETTINGS );
    $wizard->_preview;

    my $stale = $render->{ asked }[ -1 ];
    ok $stale, 'a preview was asked for';

    # Back, and a different effect.
    $wizard->{ effect } = 'bloom';
    $wizard->_prepare( GlitchVape::GUI::Wizard::PAGE_SETTINGS );

    is $wizard->{ preview_note }->get_text, 'Rendering…',
        'the pane says it is working on the new effect';

    # The first effect's render arriving now. The path is not a picture, so
    # honouring it would say so in the note -- which is how this tells the
    # difference between dropped and merely failed.
    $stale->{ on_done }->( 'no-such-file.png' );

    is $wizard->{ preview_note }->get_text, 'Rendering…',
        'a render of the effect that has left is dropped, not shown';

    # While the one asked for now is not.
    $wizard->_preview;
    $render->{ asked }[ -1 ]{ on_done }->( 'no-such-file.png' );

    is $wizard->{ preview_note }->get_text, 'Preview could not be loaded.',
        'and the current effect\'s render is still honoured';

    # An error from a departed render is dropped for the same reason: it
    # would otherwise replace the note the new effect had just set.
    my $orphan = $render->{ asked }[ -1 ];
    $wizard->{ effect } = 'vignette';
    $wizard->_prepare( GlitchVape::GUI::Wizard::PAGE_SETTINGS );
    $orphan->{ on_error }->( 'something went wrong' );

    is $wizard->{ preview_note }->get_text, 'Rendering…',
        'an error from a departed render is dropped too';

    $wizard->_finish;
}

# ---------------------------------------------------------------------------
# With no image open, the pane says so rather than blinking

# The message is set when the page is filled as well as when the render is
# asked for, so it does not disappear for the third of a second the settle
# timer takes -- in a session with no image that is the only thing explaining
# why the pane is empty.
{
    my $state = GlitchVape::GUI::State->new( source => undef, seed => 5 );

    my $wizard = GlitchVape::GUI::Wizard->run(
        state    => $state,
        render   => FakeRender->new,
        on_apply => sub { return },
    );

    $wizard->{ effect } = 'vignette';
    $wizard->_prepare( GlitchVape::GUI::Wizard::PAGE_SETTINGS );

    is $wizard->{ preview_note }->get_text,
        GlitchVape::GUI::Wizard::NO_SOURCE_NOTE,
        'a wizard with no image says why the pane is empty';

    $wizard->_finish;
}

done_testing;
