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
use GlitchVape::GUI        ();
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

    # Adding an effect and spending several seconds rendering are two
    # decisions, so the second is asked for rather than assumed. It starts
    # off every time the wizard is opened: a tick that remembered itself
    # would surprise somebody adding five effects to a large photograph.
    ok !$applied->[ 0 ][ 2 ], 'and does not ask for a render unless told to';
    ok !$wizard->{ render_now }->get_active, 'the render-now tick starts clear';

    $wizard->{ render_now }->set_active( 1 );
    $wizard->_apply;

    ok $applied->[ 1 ][ 2 ], 'ticked, apply asks the caller to render';

    $wizard->_finish;
}

# Opening the wizard again clears the tick rather than carrying it over.
{
    my ( $again, $told ) = wizard;

    ok !$again->{ render_now }->get_active,
        'a second wizard starts with the tick clear again';

    $again->{ effect } = 'wave';
    $again->_apply;

    ok !$told->[ 0 ][ 2 ], 'so it adds without rendering';

    $again->_finish;
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

# ---------------------------------------------------------------------------
# The effect page says which category it is a list of

# The first page is a list of nine categories and the second is a list of
# effects, and the second used to say nothing about which of the nine it came
# from -- so arriving there by the keyboard, or coming back after a detour,
# meant working it out from the contents.
#
# The heading and the note under the list say different things and have to
# keep agreeing: the heading is where you are, the note is what that place is
# for. A search moves you out of the category, so both have to say so.
{
    my ( $wizard ) = wizard();

    for my $stage ( GlitchVape::Registry->stages )
    {
        my $info = GlitchVape::Registry->stage_info( $stage );

        $wizard->{ stage } = $stage;
        $wizard->{ query } = q{};
        $wizard->_note_scope;

        is $wizard->{ effect_heading }->get_text, $info->{ title },
            "the heading names $stage by the title the first page used";

        is $wizard->{ effect_scope }->get_text, $info->{ blurb },
            "and the note under the list still says what $stage is for";
    }

    # An ampersand in three of those titles, and the heading is markup.
    $wizard->{ stage } = 'optics';
    $wizard->{ query } = q{};
    $wizard->_note_scope;

    like $wizard->{ effect_heading }->get_text, qr/&/,
        'a title with an ampersand in it survives being set as markup';

    # Searching looks outside the category, so the heading stops claiming one.
    $wizard->{ query } = 'scan';
    $wizard->_note_scope;

    isnt $wizard->{ effect_heading }->get_text,
        GlitchVape::Registry->stage_info( 'optics' )->{ title },
        'while searching, the heading no longer names one category';

    like $wizard->{ effect_scope }->get_text, qr/Screen & Optics/,
        'and the note names the one to clear the box to get back to';

    $wizard->{ assistant }->destroy;
}

# ---------------------------------------------------------------------------
# Ticked, the window it belongs to renders -- from the window, not the wizard

# The tick is a claim about what the main window does after the wizard shuts,
# so it is asked of the real window and the wizard it really opens rather than
# of a stand-in. GUI::_apply is replaced for the duration because the state
# here names a photograph that is not on disk: what is being counted is that
# the render was asked for, and the asking is the whole claim.
{
    my $gui = GlitchVape::GUI->new;

    $gui->{ state } =
        GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );

    my $rendered = 0;
    my $real     = \&GlitchVape::GUI::_apply;    ## no critic (ProtectPrivateVars)

    {
        no warnings 'redefine';                  ## no critic (ProhibitNoWarnings)
        ## no critic (ProhibitNoStrict)
        no strict 'refs';
        *{ 'GlitchVape::GUI::_apply' } = sub { $rendered++; return };
        ## use critic
    }

    my $ask = sub {
        my ( $tick ) = @_;

        my $wizard = $gui->_choose_effect;

        $wizard->{ effect } = 'wave';
        $wizard->{ params } =
            { %{ GlitchVape::Registry->resolve_params( 'wave', {} ) } };
        $wizard->{ render_now }->set_active( $tick );
        $wizard->_apply;
        $wizard->_finish;

        # The render is deferred to an idle, because this runs inside the
        # assistant's own apply handler and the assistant is destroyed from
        # the close that follows it.
        Gtk3::main_iteration_do( 0 ) while Gtk3::events_pending();

        return;
    };

    $ask->( 0 );

    is $rendered, 0, 'adding an effect on its own renders nothing';
    ok scalar( grep { $_ eq 'wave' } $gui->{ state }->effect_names ),
        'though the effect is added';

    # And revealed, which is selecting it: the per-row disclosure that used
    # to be opened here went when the settings became a popover, and calling
    # for it died inside the assistant's own handler -- where a die is a
    # warning on stderr and a status line nobody ever saw.
    my $row = $gui->{ effect_list }->get_selected_row;

    ok $row, 'and a row is selected afterwards';
    is $gui->_selected_effect, 'wave',
        'namely the one that was just added, which is how it is revealed';

    $ask->( 1 );

    is $rendered, 1, 'and ticked, the window renders once';

    {
        no warnings 'redefine';    ## no critic (ProhibitNoWarnings)
        ## no critic (ProhibitNoStrict)
        no strict 'refs';
        *{ 'GlitchVape::GUI::_apply' } = $real;
        ## use critic
    }

    $gui->{ window }->destroy;
}

done_testing;
