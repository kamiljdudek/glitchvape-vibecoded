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

done_testing;
