package GlitchVape::GUI::Wizard;

use strict;
use warnings;

# Literal '…' and '·' appear in page titles and status text below. See the
# note at the top of GlitchVape::GUI for what happens without this.
use utf8;

use Glib ();
use Gtk3 ();

use GlitchVape::Registry       ();
use GlitchVape::GUI::Assistant ();
use GlitchVape::GUI::Params    ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Wizard - the two-page Add Effect assistant

=head1 DESCRIPTION

Forty-six effects are too many for one flat list, so they are shown as a
tree: nine categories, each holding the effects that run at that point in the
chain. The assistant asks two questions.

=over 4

=item 1. Which effect?

The tree, by pretty name, over a search box that looks through every category
at once. Whatever is clicked on -- a category or an effect, since both are
rows -- is described beside it: the English name, the internal name, and what
it is for. See L</THE DESCRIPTION IS OF WHATEVER IS SELECTED>.

=item 2. How strong?

The declared parameters, built by L<GlitchVape::GUI::Params> -- the same
controls the effect gets once it is in the pipeline -- against a live preview.

=back

=head1 A TREE RATHER THAN TWO PAGES

Choosing the category and choosing the effect used to be a page each, which
made the category a decision in its own right: you committed to one of nine
before seeing anything in it, and comparing two effects in different
categories meant walking back and forth. A search box on the second page
looked past the category, which worked, but left the page heading and the list
disagreeing about where you were -- two sentences of explanation to cover one
control doing something the page did not otherwise admit to.

A tree makes the category a heading instead of a step. Nothing is committed to
by opening one, everything is reachable from one screen, and searching simply
prunes the tree rather than changing what the page means.

The categories are still the nine pipeline stages, because where an effect
runs and what it is for are the same fact -- so there is no second taxonomy to
keep in sync.

=head1 THE PREVIEW IS A REAL RENDER

The thumbnail is not an approximation of the effect. It is the whole current
pipeline plus the candidate, rendered through L<GlitchVape::GUI::Render> at
thumbnail size, so what it shows is what Apply will produce. That is
affordable because it is small and because it goes through the same cache as
every other preview: dragging a slider back to a value already seen redraws
from disk.

Renders are coalesced rather than issued per slider step -- see
L</_schedule_preview>.

=head1 NOTHING IS DECIDED UNTIL APPLY

The wizard never touches the caller's state. It previews against a detached
copy from C<< GlitchVape::GUI::State->clone >> and hands the finished choice
back through C<on_apply>, so cancelling at any point -- including after
several previews have been rendered -- leaves the pipeline exactly as it was.

=cut

# Longest edge of the preview thumbnail. Small enough that a render is around
# a second on the effects that cost the most, large enough that scanlines and
# grain are actually visible in it.
use constant PREVIEW_SIZE => 320;

# What the preview pane says when there is nothing to render from. Named
# because it is set from two places, which have to agree.
use constant NO_SOURCE_NOTE => 'Open an image to see this effect previewed.';

# How long a control must be still before its preview is rendered. A slider
# drag emits a value-changed per pixel of travel; without this, letting go of
# one would leave a queue of renders nobody wants to see.
use constant SETTLE_MS => 350;

# Page indices, in the order they are appended.
use constant {
    PAGE_EFFECT   => 0,
    PAGE_SETTINGS => 1,
};

=head2 run( %arg )

    parent   => Gtk3::Window
    state    => GlitchVape::GUI::State
    render   => GlitchVape::GUI::Render
    on_apply => sub { my ( $name, $params ) = @_ }
    on_empty => sub { my ( $message ) = @_ }

Shows the assistant and returns immediately; the outcome arrives through
C<on_apply>. C<on_empty> is called instead when every effect is already in the
pipeline, since there is nothing to put on the first page.

=cut

sub run
{
    my ( $class, %arg ) = @_;

    my $self = bless {
        parent   => $arg{ parent },
        state    => $arg{ state },
        render   => $arg{ render },
        on_apply => $arg{ on_apply },
        stage    => undef,
        effect   => undef,
        params   => {},
        settle   => undef,
    }, $class;

    $self->{ available } = $self->_available;

    unless ( keys %{ $self->{ available } } )
    {
        $arg{ on_empty }->( 'Every effect is already in this pipeline.' )
            if $arg{ on_empty };
        return undef;
    }

    $self->_build;

    # Before the window is shown rather than from the prepare handler, which
    # for the first page fires from the map. Filling it here is what lets a
    # caller -- a test, or the window reopening the assistant -- ask what is
    # in the tree without having run the main loop first.
    $self->_fill_tree;

    $self->{ assistant }->show_all;

    # After show_all, because the navigation buttons have no settled state
    # until the window is realised. There is no forward function here: the
    # two pages are always walked in order.
    GlitchVape::GUI::Assistant::navigate( $self->{ assistant } );

    return $self;
}

# Effect names not yet in the pipeline, grouped by stage. An effect that is
# present but switched off is deliberately excluded: it is already in the
# list, where switching it back on is one click.
sub _available
{
    my ( $self ) = @_;

    my %present = map { $_ => 1 } $self->{ state }->effect_names;
    my $by      = GlitchVape::Registry->by_stage;

    my %out;
    for my $stage ( GlitchVape::Registry->stages )
    {
        my @free = grep { !$present{ $_ } } @{ $by->{ $stage } || [] };
        $out{ $stage } = \@free if @free;
    }

    return \%out;
}

# ---------------------------------------------------------------------------
# Assembly

sub _build
{
    my ( $self ) = @_;

    my $assistant = Gtk3::Assistant->new;
    $assistant->set_transient_for( $self->{ parent } ) if $self->{ parent };
    $assistant->set_modal( 1 );
    $assistant->set_default_size( 860, 640 );
    $assistant->set_title( 'Add effect' );

    $self->{ assistant } = $assistant;

    $self->_add_page( $self->_tree_page,     'content', 'Effect' );
    $self->_add_page( $self->_settings_page, 'confirm', 'Adjust' );

    $assistant->signal_connect(
        prepare => sub {
            $self->_prepare( $assistant->get_current_page );
            return;
        }
    );

    $assistant->signal_connect(
        apply => sub {
            $self->_apply;
            return;
        }
    );

    # Cancel and close both mean "stop"; only apply has told the caller
    # anything, and it has already done so by the time close arrives.
    for my $signal ( qw(cancel close) )
    {
        $assistant->signal_connect( $signal => sub { $self->_finish; return } );
    }

    return;
}

sub _add_page
{
    my ( $self, $widget, $type, $title ) = @_;

    my $assistant = $self->{ assistant };

    $assistant->append_page( $widget );
    $assistant->set_page_type( $widget, $type );
    $assistant->set_page_title( $widget, $title );
    $assistant->set_page_complete( $widget, 0 );

    return $widget;
}

sub _finish
{
    my ( $self ) = @_;

    $self->_cancel_settle;

    # A preview may still be in flight. A cancelled render fires no callback,
    # but one served from cache has already queued its on_done on an idle,
    # and that will run after the widgets are gone.
    $self->{ render }->cancel if $self->{ render } && $self->{ render }->busy;
    $self->{ gone } = 1;

    $self->{ assistant }->destroy;
    return;
}

# ---------------------------------------------------------------------------
# Page 1: the effect tree

# The store's columns. COL_VISIBLE is what the filter reads -- a plain boolean
# the search writes, rather than a visible_func -- because a category has to
# stay on screen whenever any of its effects match, and a callback answering
# for one row at a time cannot know that without walking its children on every
# keystroke.
use constant {
    COL_MARKUP  => 0,    # what the row shows: the pretty name
    COL_NAME    => 1,    # the internal name -- a stage key or an effect name
    COL_EFFECT  => 2,    # true for an effect, false for a category
    COL_STAGE   => 3,    # the category the row is, or is in
    COL_VISIBLE => 4,    # what the search has decided
    COL_SEARCH  => 5,    # the lowercased haystack
};

sub _tree_page
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 8 );
    $box->set_border_width( 12 );

    my $lead = Gtk3::Label->new;
    $lead->set_markup(
              'Effects are grouped by where they run in the chain. '
            . 'Open a category to see what is in it, or search.' );
    $lead->set_xalign( 0 );
    $lead->set_line_wrap( 1 );

    # A wrapped label still asks for its whole natural width unless it is told
    # otherwise, and this one is long enough that letting it do so would widen
    # the assistant.
    $lead->set_max_width_chars( 72 );
    $lead->get_style_context->add_class( 'dim-label' );
    $box->pack_start( $lead, 0, 0, 0 );

    my $search = Gtk3::SearchEntry->new;
    $search->set_placeholder_text( 'Search every effect…' );
    $search->signal_connect(
        'search-changed' => sub {
            $self->_search( $search->get_text );
            return;
        }
    );
    $box->pack_start( $search, 0, 0, 0 );

    my $split = Gtk3::Box->new( 'horizontal', 12 );
    $split->pack_start( $self->_tree_pane,   1, 1, 0 );
    $split->pack_start( $self->_detail_pane, 0, 0, 0 );
    $box->pack_start( $split, 1, 1, 0 );

    my $scope = Gtk3::Label->new;
    $scope->set_xalign( 0 );
    $scope->set_line_wrap( 1 );
    $scope->get_style_context->add_class( 'dim-label' );
    $box->pack_start( $scope, 0, 0, 0 );

    $self->{ effect_search } = $search;
    $self->{ effect_scope }  = $scope;
    $self->{ effect_page }   = $box;

    return $box;
}

sub _tree_pane
{
    my ( $self ) = @_;

    my $store = Gtk3::TreeStore->new(
        qw(Glib::String Glib::String Glib::Boolean
            Glib::String Glib::Boolean Glib::String)
    );

    my $filter = Gtk3::TreeModelFilter->new( $store, undef );
    $filter->set_visible_column( COL_VISIBLE );

    my $tree = Gtk3::TreeView->new( $filter );
    $tree->set_headers_visible( 0 );

    # Gtk's own type-ahead would open a second, floating search box over a
    # page that already has one, and the two would disagree about what was
    # being looked for.
    $tree->set_enable_search( 0 );

    my $cell = Gtk3::CellRendererText->new;
    $cell->set( ypad => 3 );

    # Markup rather than text, so a category can be bold without a second
    # column or a cell data function. Everything put in that column goes
    # through _escape on the way, since three of the stage titles contain an
    # ampersand.
    $tree->append_column(
        Gtk3::TreeViewColumn->new_with_attributes(
            q{}, $cell, markup => COL_MARKUP
        )
    );

    $tree->get_selection->set_mode( 'single' );
    $tree->get_selection->signal_connect(
        changed => sub { $self->_on_tree_selection; return } );

    # A category has children and opens on a double click, which is Gtk's own
    # behaviour for a row with an expander and not worth taking over. An
    # effect has nothing to open, so there the same gesture means "and
    # continue" -- the shortcut both lists had before this was a tree.
    $tree->signal_connect(
        'row-activated' => sub {
            my ( undef, $path ) = @_;
            my ( $iter ) = $filter->get_iter( $path );
            return unless $iter;
            $self->_next if $filter->get_value( $iter, COL_EFFECT );
            return;
        }
    );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );
    $scroll->set_vexpand( 1 );
    $scroll->set_hexpand( 1 );
    $scroll->add( $tree );

    $self->{ store }  = $store;
    $self->{ filter } = $filter;
    $self->{ tree }   = $tree;

    return $scroll;
}

=head2 THE DESCRIPTION IS OF WHATEVER IS SELECTED

Categories and effects are both rows in one tree, so both are things a person
can click on, and a pane that described one but not the other would teach
people not to click on categories. Both answer the same three questions: what
it is called in English, what it is called in a preset, and what it is for.

The internal name is the reason the pane exists at all. It is what C<--set>,
the preset files and the copied command line use, and the tree shows pretty
names -- so without it the window and the manual page would be two
vocabularies for one set of things.

=cut

sub _detail_pane
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 6 );
    $box->set_valign( 'start' );

    # Wide enough for a sentence of prose and no wider: the tree beside it
    # holds the long titles and is the half that should grow with the window.
    $box->set_size_request( 300, -1 );

    my $heading = Gtk3::Label->new;
    $heading->set_xalign( 0 );
    $heading->set_line_wrap( 1 );
    $heading->set_max_width_chars( 34 );

    my $key = Gtk3::Label->new;
    $key->set_xalign( 0 );

    # Selectable, because this is the string that gets typed after --set or
    # pasted into a preset, and retyping it from a screenshot is how a
    # spelling goes wrong.
    $key->set_selectable( 1 );

    my $body = Gtk3::Label->new;
    $body->set_xalign( 0 );
    $body->set_line_wrap( 1 );
    $body->set_max_width_chars( 34 );
    $body->get_style_context->add_class( 'dim-label' );

    my $foot = Gtk3::Label->new;
    $foot->set_xalign( 0 );
    $foot->set_line_wrap( 1 );
    $foot->set_max_width_chars( 34 );

    $box->pack_start( $heading, 0, 0, 0 );
    $box->pack_start( $key,     0, 0, 0 );
    $box->pack_start( $body,    0, 0, 0 );
    $box->pack_start( $foot,    0, 0, 0 );

    $self->{ detail_heading } = $heading;
    $self->{ detail_key }     = $key;
    $self->{ detail_body }    = $body;
    $self->{ detail_foot }    = $foot;

    return $box;
}

# The tree is built once. Rebuilding it per search would throw away the
# expansion state and the selection, which are the two things a search should
# move rather than lose.
sub _fill_tree
{
    my ( $self ) = @_;

    return if $self->{ filled };
    $self->{ filled } = 1;

    my $store = $self->{ store };
    my $all   = GlitchVape::Registry->all;

    # Path strings rather than iters: an iter into a TreeStore is only good
    # until the store changes, and this list outlives every search. The row's
    # own facts are recorded beside the path so that answering a search is a
    # walk over plain Perl rather than over the model.
    my @rows;

    for my $stage ( GlitchVape::Registry->stages )
    {
        my $free = $self->{ available }{ $stage } or next;
        my $info = GlitchVape::Registry->stage_info( $stage );

        my $hay = lc join q{ }, $stage, $info->{ title };

        my $parent = $store->append( undef );
        $store->set(
            $parent,                                      COL_MARKUP,
            '<b>' . _escape( $info->{ title } ) . '</b>', COL_NAME,
            $stage,                                       COL_EFFECT,
            0,                                            COL_STAGE,
            $stage,                                       COL_VISIBLE,
            1,                                            COL_SEARCH,
            $hay,
        );

        push @rows,
            {
            path    => $store->get_string_from_iter( $parent ),
            name    => $stage,
            stage   => $stage,
            effect  => 0,
            search  => $hay,
            visible => 1,
            };

        for my $name ( @$free )
        {
            my $spec = $all->{ $name };

            # Pre-lowercased: the search runs over every row on every
            # keystroke, and lc-ing three strings each time is work with a
            # known answer. Matching the summary as well as the title and the
            # key is what lets somebody who knows the picture they want and
            # somebody who knows the preset key both find it.
            my $straw = lc join q{ }, $name, $spec->{ title },
                $spec->{ summary };

            my $child = $store->append( $parent );
            $store->set(
                $child,                      COL_MARKUP,
                _escape( $spec->{ title } ), COL_NAME,
                $name,                       COL_EFFECT,
                1,                           COL_STAGE,
                $stage,                      COL_VISIBLE,
                1,                           COL_SEARCH,
                $straw,
            );

            push @rows,
                {
                path    => $store->get_string_from_iter( $child ),
                name    => $name,
                stage   => $stage,
                effect  => 1,
                search  => $straw,
                visible => 1,
                };
        }
    }

    $self->{ rows }  = \@rows;
    $self->{ total } = scalar grep { $_->{ effect } } @rows;

    # Opened on the first effect of the first category, so Continue does
    # something from the moment the page is shown. That is only honest
    # because the choice is visible: the highlighted row is the one Continue
    # will act on, and the pane beside it says what that row is.
    $self->_select_first;
    $self->_note_scope( $self->{ total } );

    return;
}

# Which rows the search leaves on screen. A category survives if any of its
# effects do, which is what keeps a match from turning up under no heading.
sub _apply_query
{
    my ( $self ) = @_;

    my $query = $self->{ query };
    my $store = $self->{ store };
    my $rows  = $self->{ rows } || [];

    my $all = !defined $query || !length $query;

    my ( %want, %any );
    my $hits = 0;

    for my $row ( @$rows )
    {
        next unless $row->{ effect };

        my $on = $all || index( $row->{ search }, $query ) >= 0 ? 1 : 0;

        $want{ $row->{ path } } = $on;
        $any{ $row->{ stage } } ||= $on;
        $hits += $on;
    }

    $want{ $_->{ path } } = $any{ $_->{ stage } } ? 1 : 0
        for grep { !$_->{ effect } } @$rows;

    # Written to the model only once every answer is known. Setting a value is
    # a row-changed, which the filter acts on at once, so interleaving the two
    # passes would hide a category between deciding about its first effect and
    # its last.
    for my $row ( @$rows )
    {
        my $on = $want{ $row->{ path } };
        next if $row->{ visible } == $on;

        $row->{ visible } = $on;

        my ( $iter ) = $store->get_iter_from_string( $row->{ path } );
        $store->set( $iter, COL_VISIBLE, $on ) if $iter;
    }

    return $hits;
}

sub _search
{
    my ( $self, $text ) = @_;

    return unless $self->{ filled };

    my $was = $self->{ effect };

    $self->{ query } = lc( $text // q{} );

    my $hits = $self->_apply_query;
    my $tree = $self->{ tree };

    # A match three rows inside a closed category is not a match anybody can
    # see. Cleared, the tree goes back to its nine headings, which is the
    # shape that makes it browsable in the first place.
    if   ( length $self->{ query } ) { $tree->expand_all }
    else                             { $tree->collapse_all }

    # Whatever was chosen stays chosen if it survived, so typing one letter
    # too many and deleting it again lands back where it started. Otherwise
    # the first surviving effect, so Continue never points off screen.
    $self->_select_first
        unless defined $was && $self->_select_effect( $was );

    $self->_note_scope( $hits );
    return;
}

sub _select_first
{
    my ( $self ) = @_;

    my ( $row ) =
        grep { $_->{ effect } && $_->{ visible } } @{ $self->{ rows } || [] };

    return 0 unless $row;
    return $self->_select_effect( $row->{ name } );
}

=head2 _select_effect( $name )

Select the effect with that internal name, if the search has left it on
screen. Returns whether it did.

=cut

sub _select_effect
{
    my ( $self, $name ) = @_;

    my ( $row ) =
        grep { $_->{ effect } && $_->{ name } eq $name }
        @{ $self->{ rows } || [] };

    return 0 unless $row && $row->{ visible };

    my $child = Gtk3::TreePath->new_from_string( $row->{ path } );
    my $path  = $self->{ filter }->convert_child_path_to_path( $child )
        or return 0;

    # Ancestors first: selecting a row inside a closed category selects
    # nothing at all.
    $self->{ tree }->expand_to_path( $path );
    $self->{ tree }->get_selection->select_path( $path );
    $self->{ tree }->scroll_to_cell( $path, undef, 0, 0, 0 );

    return 1;
}

sub _on_tree_selection
{
    my ( $self ) = @_;

    my ( undef, $iter ) = $self->{ tree }->get_selection->get_selected;

    unless ( $iter )
    {
        $self->{ effect } = undef;
        $self->_describe( undef );
        $self->{ assistant }->set_page_complete( $self->{ effect_page }, 0 );
        return;
    }

    my $model  = $self->{ filter };
    my $name   = $model->get_value( $iter, COL_NAME );
    my $effect = $model->get_value( $iter, COL_EFFECT ) ? 1 : 0;

    $self->{ stage }  = $model->get_value( $iter, COL_STAGE );
    $self->{ effect } = $effect ? $name : undef;

    $self->_describe( $name, $effect );

    # A category is a place, not a choice. Selecting one describes it and
    # stops there, rather than letting Continue arrive at a settings page with
    # no effect to settle.
    $self->{ assistant }->set_page_complete( $self->{ effect_page }, $effect );

    return;
}

sub _describe
{
    my ( $self, $name, $is_effect ) = @_;

    my $heading = $self->{ detail_heading };
    my $key     = $self->{ detail_key };
    my $body    = $self->{ detail_body };
    my $foot    = $self->{ detail_foot };

    unless ( defined $name )
    {
        $heading->set_markup( q{} );
        $key->set_markup( q{} );
        $body->set_text( 'Choose an effect from the tree.' );
        $foot->set_markup( q{} );
        return;
    }

    my ( $title, $blurb, $because );

    if ( $is_effect )
    {
        my $spec = GlitchVape::Registry->get( $name ) or return;
        my $info = GlitchVape::Registry->stage_info( $spec->{ stage } );

        $title = $spec->{ title };
        $blurb = $spec->{ summary };

        # Where it runs, said on the effect as well as on the category,
        # because a tree can be searched -- and a match arrived at from the
        # search box has no visible heading above it to have said so.
        $because = sprintf 'Runs at %s. %s', $info->{ title },
            $info->{ because };
    }
    else
    {
        my $info = GlitchVape::Registry->stage_info( $name ) or return;

        $title   = $info->{ title };
        $blurb   = $info->{ blurb };
        $because = $info->{ because };
    }

    $heading->set_markup( '<b>' . _escape( $title ) . '</b>' );
    $key->set_markup(
        "<span alpha='45%'><tt>" . _escape( $name ) . '</tt></span>' );
    $body->set_text( $blurb );
    $foot->set_markup( sprintf q{<span alpha='55%%'><i>%s</i></span>},
        _escape( $because ) );

    return;
}

sub _note_scope
{
    my ( $self, $hits ) = @_;

    my $label = $self->{ effect_scope } or return;
    my $query = $self->{ query };
    my $total = $self->{ total } // 0;

    unless ( defined $query && length $query )
    {
        $label->set_text(
            sprintf '%d effects to add, ' . 'in the order the chain runs them.',
            $total
        );
        return;
    }

    $hits = 0 unless defined $hits;

    $label->set_text(
        $hits
        ? sprintf( '%d of %d effects match. Clear the box for all of them.',
            $hits, $total )
        : 'Nothing matches. Clear the box to see every effect again.'
    );

    return;
}

# ---------------------------------------------------------------------------
# Page 3: settings

sub _settings_page
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 10 );
    $box->set_border_width( 12 );

    my $heading = Gtk3::Label->new;
    $heading->set_xalign( 0 );
    $box->pack_start( $heading, 0, 0, 0 );

    my $summary = Gtk3::Label->new;
    $summary->set_xalign( 0 );
    $summary->set_line_wrap( 1 );
    $summary->get_style_context->add_class( 'dim-label' );
    $box->pack_start( $summary, 0, 0, 0 );

    my $split = Gtk3::Box->new( 'horizontal', 12 );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );
    $scroll->set_vexpand( 1 );
    $scroll->set_hexpand( 1 );

    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 4 );
    $grid->set_column_spacing( 8 );

    $scroll->add( $grid );

    my $column = Gtk3::Box->new( 'vertical', 6 );
    $column->pack_start( $scroll,              1, 1, 0 );
    $column->pack_start( $self->_reset_button, 0, 0, 0 );

    $split->pack_start( $column,              1, 1, 0 );
    $split->pack_start( $self->_preview_pane, 0, 0, 0 );

    $box->pack_start( $split,             1, 1, 0 );
    $box->pack_start( $self->_render_now, 0, 0, 0 );

    $self->{ settings_heading } = $heading;
    $self->{ settings_summary } = $summary;
    $self->{ settings_grid }    = $grid;
    $self->{ settings_page }    = $box;

    return $box;
}

# Under the controls rather than beside the heading, because it acts on the
# list above it and reads as belonging to it. Not in the assistant's button
# row: that row is Cancel, Back and Apply -- decisions about the whole
# assistant -- and Reset is a decision about one page of it.
#
# At the foot of the column rather than immediately under the last control,
# which would put it in a different place for every effect: the settings are
# a scrolling list, and a button that follows the end of one is a button that
# moves as the list is browsed.
# Whether adding the effect should also render.
#
# Off by default and stays off: adding an effect is a decision about the
# pipeline and rendering is a decision about spending several seconds, and a
# wizard that quietly did the second because you asked for the first would be
# a wizard people stopped using on large photographs. It says how long the
# last render took, which is the only honest thing to put beside a tick box
# whose cost is time.
#
# At the foot of the page rather than beside Apply: the assistant's own row is
# Cancel, Back and Apply, which are decisions about the assistant, and this is
# a decision about what happens after it closes.
sub _render_now
{
    my ( $self ) = @_;

    my $check =
        Gtk3::CheckButton->new_with_mnemonic( 'Apply the effect _immediately' );

    $check->set_active( 0 );
    $check->set_tooltip_text(
        'Render the whole pipeline as soon as this closes, with everything '
            . 'already in it. Off, the effect is added and the picture is '
            . 'redrawn when you press Apply.' );

    $self->{ render_now } = $check;

    return $check;
}

sub _reset_button
{
    my ( $self ) = @_;

    my $button = Gtk3::Button->new_with_mnemonic( '_Reset to defaults' );
    $button->set_halign( 'end' );
    $button->set_tooltip_text(
        'Put every setting back to the value the effect declares' );

    $button->signal_connect( clicked => sub { $self->_reset_params; return } );

    $self->{ reset_button } = $button;

    return $button;
}

# Insensitive while there is nothing to undo, which is the same argument as
# the greyed parameters beside it: a button that would do nothing should say
# so rather than being pressed to find out.
sub _sync_reset
{
    my ( $self ) = @_;

    my $button = $self->{ reset_button } or return;

    $button->set_sensitive(
        GlitchVape::Registry->at_defaults( $self->{ effect },
            $self->{ params } ) ? 0 : 1
    );

    return;
}

=head2 _reset_params

Put every parameter back to what the effect declares.

Done by rebuilding the page rather than by writing values into the controls
that are already there: L<GlitchVape::GUI::Params> hands back a control and a
way to hear about changes, never a way to set one, and a setter per widget
kind is the switch on type that the whole design of that module exists to
avoid. Clearing C<settings_for> is what gets past the guard that normally
stops a rebuild.

=cut

sub _reset_params
{
    my ( $self ) = @_;

    return unless $self->{ effect };

    $self->{ settings_for } = undef;
    $self->_fill_settings;

    return;
}

sub _preview_pane
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 4 );
    $box->set_valign( 'start' );

    my $frame = Gtk3::Frame->new;
    $frame->set_shadow_type( 'in' );
    $frame->set_size_request( PREVIEW_SIZE, PREVIEW_SIZE * 3 / 4 );

    my $image = Gtk3::Image->new;
    $frame->add( $image );

    my $note = Gtk3::Label->new;
    $note->set_xalign( 0 );
    $note->set_line_wrap( 1 );
    $note->set_max_width_chars( 34 );
    $note->get_style_context->add_class( 'dim-label' );

    $box->pack_start( $frame, 0, 0, 0 );
    $box->pack_start( $note,  0, 0, 0 );

    $self->{ preview_image } = $image;
    $self->{ preview_note }  = $note;

    return $box;
}

sub _fill_settings
{
    my ( $self ) = @_;

    my $name = $self->{ effect }                  or return;
    my $spec = GlitchVape::Registry->get( $name ) or return;

    return if ( $self->{ settings_for } // q{} ) eq $name;
    $self->{ settings_for } = $name;

    $self->{ params } = GlitchVape::Registry->resolve_params( $name, {} );

    # Everything about the preview belongs to the effect that was on this
    # page a moment ago, and none of it survives the change.
    $self->_invalidate_preview;

    $self->{ settings_heading }->set_markup( '<b>'
            . _escape( $spec->{ title } ) . '</b>'
            . "  <span alpha='45%'><tt>"
            . _escape( $name )
            . '</tt></span>' );
    $self->{ settings_summary }->set_text( $spec->{ summary } );

    my $grid = $self->{ settings_grid };
    $_->destroy for $grid->get_children;

    # Destroyed with the grid, so the map of them goes too: kept, it would be
    # a list of widgets to grey out that no longer exist.
    $self->{ controls } = {};

    my $params = $spec->{ params };
    my $row    = 0;

    unless ( %$params )
    {
        my $none = Gtk3::Label->new( 'This effect takes no parameters.' );
        $none->set_xalign( 0 );
        $none->get_style_context->add_class( 'dim-label' );
        $grid->attach( $none, 0, 0, 2, 1 );
    }

    my ( $ordinary, $animation ) = GlitchVape::GUI::Params::split( $params );

    for my $key ( @$ordinary, @$animation )
    {
        # Grouped as in the settings popover, and for the same reason: these
        # do nothing to the preview beside them, and a control that appears
        # not to work is worse than one that says when it will.
        if ( @$animation && $key eq $animation->[ 0 ] )
        {
            # Only if there is something above it to separate. An effect
            # that is entirely about motion -- flicker is one -- would
            # otherwise open with a rule across an empty space.
            if ( @$ordinary )
            {
                $grid->attach( Gtk3::Separator->new( 'horizontal' ),
                    0, $row, 2, 1 );
                $row++;
            }

            my $heading = Gtk3::Label->new( 'Only in an animation' );
            $heading->set_xalign( 0 );
            $heading->get_style_context->add_class( 'dim-label' );
            $grid->attach( $heading, 0, $row, 2, 1 );
            $row++;
        }

        my $built = GlitchVape::GUI::Params->build(
            effect    => $name,
            name      => $key,
            spec      => $params->{ $key },
            value     => $self->{ params }{ $key },
            on_change => sub {
                $self->_set_param( $key, $_[ 0 ] );
                return;
            },
        );

        # The preview takes a fixed slice of the page, so the controls are
        # sharing what is left with a scrolled viewport that would otherwise
        # shrink every slider to its minimum -- about a centimetre of track,
        # which is not a control anybody can set a value with.
        #
        # Only the ones a width helps. A switch has a size of its own, and
        # asking for 220 pixels of it stretches it into a lever right across
        # the column.
        if ( $built->{ stretch } )
        {
            $built->{ control }->set_size_request( 220, -1 );
        }
        else
        {
            $built->{ control }->set_halign( 'start' );
        }

        $self->{ controls }{ $key } = $built;

        $grid->attach( $built->{ label },   0, $row, 1, 1 );
        $grid->attach( $built->{ control }, 1, $row, 1, 1 );
        $row++;
    }

    $self->_sync_needs;
    $self->_sync_reset;

    $grid->show_all;

    # The last page is a confirm page, so Apply is available the moment it is
    # reached: every parameter already holds its declared default.
    $self->{ assistant }->set_page_complete( $self->{ settings_page }, 1 );

    $self->_schedule_preview;
    return;
}

sub _set_param
{
    my ( $self, $key, $value ) = @_;

    my $resolved = eval {
        GlitchVape::Registry->resolve_params( $self->{ effect },
            { %{ $self->{ params } }, $key => $value } );
    };

    # A half-typed colour or an empty entry fails validation on its way past.
    # That is not an error worth reporting: the next keystroke usually fixes
    # it, so the old value stands and the preview is simply not redrawn.
    return unless $resolved;

    $self->{ params } = $resolved;

    # A switch that has just been moved may have decided whether the controls
    # under it mean anything yet -- the same greying the settings popover
    # does, from the same declaration.
    $self->_sync_needs;
    $self->_sync_reset;

    $self->_schedule_preview;
    return;
}

sub _sync_needs
{
    my ( $self ) = @_;

    my $spec = GlitchVape::Registry->get( $self->{ effect } ) or return;

    GlitchVape::GUI::Params::apply_needs(
        $spec->{ params },
        $self->{ controls },
        $self->{ params }
    );

    return;
}

# ---------------------------------------------------------------------------
# Live preview

# Coalescing, not throttling: each change pushes the render further out, so a
# drag issues exactly one render, when it stops.
sub _schedule_preview
{
    my ( $self ) = @_;

    return unless $self->{ settings_for };

    $self->_cancel_settle;

    $self->{ settle } = Glib::Timeout->add(
        SETTLE_MS,
        sub {
            $self->{ settle } = undef;
            $self->_preview;
            return 0;
        }
    );

    return;
}

sub _cancel_settle
{
    my ( $self ) = @_;

    if ( my $id = $self->{ settle } )
    {
        Glib::Source->remove( $id );
        $self->{ settle } = undef;
    }

    return;
}

=head2 THE PREVIEW BELONGS TO ONE EFFECT

A render started for one effect can arrive while a different one is on the
page. Going Back, choosing something else and coming forward again takes well
under the second a preview costs, and the result then lands in the pane above
the new effect's controls -- a picture of the effect you did not choose,
labelled as the one you did, until the next render happens to replace it.

Cancelling the in-flight render is not enough on its own. A preview that hits
the cache never starts a child at all: it answers from an idle callback, which
C<cancel> knows nothing about because there is no job to cancel.

So every request carries a token, and a result whose token is no longer the
current one is dropped. L</_invalidate_preview> bumps it, which is what makes
"this pane is out of date" one statement rather than a list of things to
remember to undo.

=cut

sub _invalidate_preview
{
    my ( $self ) = @_;

    # Anything already asked for is of the effect that has just left, so its
    # answer is dropped whenever it arrives.
    $self->{ preview_token } = ( $self->{ preview_token } // 0 ) + 1;

    $self->_cancel_settle;
    $self->{ render }->cancel if $self->{ render }->busy;

    # And the picture already in the pane is of that same effect. Left up, it
    # is not merely stale but mislabelled, since the heading beside it has
    # already changed.
    $self->{ preview_image }->clear;
    $self->{ preview_note }->set_text( $self->_pending_note );

    return;
}

# What the pane says while there is no picture in it. Asked here as well as in
# _preview so that the answer does not change 350ms after the page is shown:
# a session with no image open would otherwise blank the one message that
# explains why there is nothing to see.
sub _pending_note
{
    my ( $self ) = @_;

    return NO_SOURCE_NOTE unless $self->{ state }->source;
    return 'Rendering…';
}

sub _preview
{
    my ( $self ) = @_;

    my $name = $self->{ effect } or return;

    unless ( $self->{ state }->source )
    {
        $self->{ preview_note }->set_text( NO_SOURCE_NOTE );
        return;
    }

    # An in-flight render is of settings that have since changed, so its
    # result is of no use to anyone.
    $self->{ render }->cancel if $self->{ render }->busy;

    my $candidate = $self->{ state }->clone;
    $candidate->add_effect( $name );
    $candidate->effects->{ $name }{ params } = { %{ $self->{ params } } };

    $self->{ preview_note }->set_text( 'Rendering…' );

    my $token = $self->{ preview_token } =
        ( $self->{ preview_token } // 0 ) + 1;

    $self->{ render }->preview(
        state   => $candidate,
        size    => PREVIEW_SIZE,
        on_done => sub {
            my ( $path ) = @_;
            return unless $self->_current_preview( $token );
            $self->_show_preview( $path );
            return;
        },
        on_error => sub {
            my ( $message ) = @_;
            return if $self->{ gone };
            return unless $self->_current_preview( $token );
            $message =~ s/\s+\z//;
            $self->{ preview_note }->set_text( $message );
            return;
        },
    );

    return;
}

sub _current_preview
{
    my ( $self, $token ) = @_;

    return ( $self->{ preview_token } // 0 ) == $token ? 1 : 0;
}

sub _show_preview
{
    my ( $self, $path ) = @_;

    # The assistant may have been closed since this render was asked for.
    return if $self->{ gone };

    my $pixbuf = eval { Gtk3::Gdk::Pixbuf->new_from_file( $path ) };

    unless ( $pixbuf )
    {
        $self->{ preview_note }->set_text( 'Preview could not be loaded.' );
        return;
    }

    $self->{ preview_image }->set_from_pixbuf( $pixbuf );

    $self->{ preview_note }->set_text( 'Preview' );

    return;
}

# ---------------------------------------------------------------------------
# Navigation and outcome

sub _next
{
    my ( $self ) = @_;

    my $assistant = $self->{ assistant };
    my $page      = $assistant->get_current_page;

    # Activating a row is only a shortcut for Continue, so it must respect the
    # same completeness the button does.
    return
        unless $assistant->get_page_complete(
        $assistant->get_nth_page( $page ) );

    $assistant->set_current_page( $page + 1 );
    return;
}

# By index rather than by widget identity: the page argument the signal
# carries is a fresh wrapper around the GObject, so comparing it against the
# reference stored at build time is not reliable.
sub _prepare
{
    my ( $self, $index ) = @_;

    if ( $index == PAGE_EFFECT )
    {
        $self->_fill_tree;
        $self->{ effect_search }->grab_focus;
        return;
    }

    if ( $index == PAGE_SETTINGS )
    {
        $self->_fill_settings;
        return;
    }

    return;
}

sub _apply
{
    my ( $self ) = @_;

    return unless $self->{ effect };

    $self->{ on_apply }->(
        $self->{ effect },
        { %{ $self->{ params } } },
        $self->{ render_now } && $self->{ render_now }->get_active ? 1 : 0
    ) if $self->{ on_apply };

    return;
}

# Pango markup, not plain text: an effect titled 'Letterbox & Border' would
# otherwise take the label parser down with it.
sub _escape
{
    my ( $text ) = @_;
    return Glib::Markup::escape_text( $text // q{} );
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Registry> for the stage titles the tree is built from,
L<GlitchVape::GUI::Params> for the controls on the second page, and
L<GlitchVape::GUI::Render> for why the preview happens in a child process.

=cut
