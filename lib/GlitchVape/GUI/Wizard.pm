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

GlitchVape::GUI::Wizard - the three-page Add Effect assistant

=head1 DESCRIPTION

Forty-five effects are too many for one list. The assistant asks three
questions in the order a person actually has them:

=over 4

=item 1. What kind of thing am I after?

The nine pipeline stages, under their presentable titles. A stage is where an
effect runs I<and> what it is for, which is why it can be browsed as a
category rather than needing a second taxonomy alongside it.

=item 2. Which one?

Everything free in that stage, by title and summary, with a search box. The
search matches the title, the summary and the internal name, so someone who
knows the picture they want and someone who knows the preset key both find it.

=item 3. How strong?

The declared parameters, built by L<GlitchVape::GUI::Params> -- the same
controls the effect gets once it is in the pipeline -- against a live preview.

=back

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
    PAGE_CATEGORY => 0,
    PAGE_EFFECT   => 1,
    PAGE_SETTINGS => 2,
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
    $self->{ assistant }->show_all;

    # After show_all, because the navigation buttons have no settled state
    # until the window is realised. There is no forward function here: the
    # three pages are always walked in order.
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

    $self->_add_page( $self->_category_page, 'content', 'Category' );
    $self->_add_page( $self->_effect_page,   'content', 'Effect' );
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
# Page 1: category

sub _category_page
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 8 );
    $box->set_border_width( 12 );

    my $lead = Gtk3::Label->new;

    # The example that used to be here -- scanlines shrunk away by a
    # downsample -- has moved into the stages themselves, where it belongs to
    # the one stage it is about. Saying it twice made the lead longer than the
    # first row it introduces.
    $lead->set_markup(
              'Effects are grouped by where they run in the chain, '
            . 'which is also what they are for. The chain always runs in '
            . 'the same order, and each part below says why it runs where '
            . 'it does. So choose the part of the chain you want to change, '
            . 'then the effect.' );
    $lead->set_xalign( 0 );
    $lead->set_line_wrap( 1 );

    # Wrapped, but a wrapped label still asks for its whole natural width
    # unless it is told otherwise, and this one is now long enough that
    # letting it do so would widen the assistant. Bounded to the same measure
    # the stage blurbs use, so the two columns of prose agree.
    $lead->set_max_width_chars( 60 );
    $lead->get_style_context->add_class( 'dim-label' );
    $box->pack_start( $lead, 0, 0, 0 );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );
    $scroll->set_vexpand( 1 );

    my $list = Gtk3::ListBox->new;
    $list->set_selection_mode( 'single' );

    for my $stage ( GlitchVape::Registry->stages )
    {
        my $free = $self->{ available }{ $stage } or next;
        my $info = GlitchVape::Registry->stage_info( $stage );

        my $row = Gtk3::ListBoxRow->new;
        $row->add( _category_row( $info, scalar @$free ) );
        $row->{ stage } = $stage;
        $list->add( $row );
    }

    $list->signal_connect(
        'row-selected' => sub {
            my ( undef, $row ) = @_;
            return unless $row;
            $self->{ stage } = $row->{ stage };
            $self->{ assistant }->set_page_complete( $box, 1 );
            return;
        }
    );

    # Double-click or Enter should go straight on rather than making the user
    # find Continue. A single click must not: it is how the row gets selected
    # in the first place, and a page that leaves as soon as it is touched
    # gives nobody a chance to look at what else is on it. GtkListBox
    # activates on single click by default, so this has to be said.
    $list->set_activate_on_single_click( 0 );
    $list->signal_connect( 'row-activated' => sub { $self->_next; return } );

    # GtkListBox selects its first row as soon as it takes focus, so the page
    # is complete from the moment it is shown and Continue always does
    # something. That is only safe because the choice is visible: the
    # highlighted row is the one Continue will act on.

    $scroll->add( $list );
    $box->pack_start( $scroll, 1, 1, 0 );

    $self->{ category_list } = $list;
    $self->{ category_page } = $box;

    return $box;
}

sub _category_row
{
    my ( $info, $count ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 2 );
    $box->set_border_width( 8 );

    my $head = Gtk3::Box->new( 'horizontal', 8 );

    my $title = Gtk3::Label->new;
    $title->set_markup( '<b>' . _escape( $info->{ title } ) . '</b>' );
    $title->set_xalign( 0 );
    $title->set_hexpand( 1 );

    my $tally = Gtk3::Label->new;
    $tally->set_markup( sprintf "<span alpha='55%%'>%d available</span>",
        $count );
    $tally->set_xalign( 1 );

    $head->pack_start( $title, 1, 1, 0 );
    $head->pack_start( $tally, 0, 0, 0 );

    my $blurb = Gtk3::Label->new( $info->{ blurb } );
    $blurb->set_xalign( 0 );
    $blurb->set_line_wrap( 1 );
    $blurb->set_max_width_chars( 60 );
    $blurb->get_style_context->add_class( 'dim-label' );

    # Why this stage runs where it does, said here as well as in the list's
    # headings. This is the page where somebody is deciding *which part of
    # the chain* to change, so it is the page where the chain having an order
    # is the thing they are actually reasoning about -- and unlike a heading
    # in a narrow pane, there is room for the sentence itself rather than a
    # tooltip carrying it.
    my $because = Gtk3::Label->new;
    $because->set_markup( sprintf q{<span alpha='55%%'><i>%s</i></span>},
        _escape( $info->{ because } ) );
    $because->set_xalign( 0 );
    $because->set_line_wrap( 1 );
    $because->set_max_width_chars( 60 );

    $box->pack_start( $head,    0, 0, 0 );
    $box->pack_start( $blurb,   0, 0, 0 );
    $box->pack_start( $because, 0, 0, 0 );

    return $box;
}

# ---------------------------------------------------------------------------
# Page 2: effect

sub _effect_page
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 8 );
    $box->set_border_width( 12 );

    # Which category this is a list of, above the box that can take you out
    # of it. The first page is a list of nine and the second is a list of
    # effects, and without this the second page does not say which of the nine
    # it came from -- so coming back to it after a detour, or arriving at it
    # by the keyboard, meant guessing from the contents.
    my $heading = Gtk3::Label->new;
    $heading->set_xalign( 0 );
    $box->pack_start( $heading, 0, 0, 0 );

    my $search = Gtk3::SearchEntry->new;
    $search->set_placeholder_text( 'Search effects…' );
    $box->pack_start( $search, 0, 0, 0 );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );
    $scroll->set_vexpand( 1 );

    my $list = Gtk3::ListBox->new;
    $list->set_selection_mode( 'single' );

    # Searching looks outside the chosen category, because someone who types
    # 'scanline' while standing in Colour meant the effect, not the category.
    # The scope note under the box is what keeps that from being a surprise.
    $list->set_filter_func(
        sub {
            my ( $row ) = @_;
            return $self->_matches( $row );
        }
    );

    $search->signal_connect(
        'search-changed' => sub {
            $self->{ query } = lc $search->get_text;
            $list->invalidate_filter;
            $self->_resync_selection;
            $self->_note_scope;
            return;
        }
    );

    $list->signal_connect(
        'row-selected' => sub {
            my ( undef, $row ) = @_;
            $self->{ effect } = $row ? $row->{ effect } : undef;
            $self->{ assistant }->set_page_complete( $box, $row ? 1 : 0 );
            return;
        }
    );

    # As on the first page: clicking a name picks it, and only a double click
    # or Enter moves on.
    $list->set_activate_on_single_click( 0 );
    $list->signal_connect( 'row-activated' => sub { $self->_next; return } );

    $scroll->add( $list );
    $box->pack_start( $scroll, 1, 1, 0 );

    my $scope = Gtk3::Label->new;
    $scope->set_xalign( 0 );
    $scope->set_line_wrap( 1 );
    $scope->get_style_context->add_class( 'dim-label' );
    $box->pack_start( $scope, 0, 0, 0 );

    $self->{ effect_heading } = $heading;
    $self->{ effect_search }  = $search;
    $self->{ effect_list }    = $list;
    $self->{ effect_scope }   = $scope;
    $self->{ effect_page }    = $box;

    return $box;
}

# Rows for every free effect anywhere are built once; the filter decides which
# are on screen. Rebuilding the list per category would throw away the
# selection state Gtk keeps and makes cross-category search impossible.
sub _fill_effects
{
    my ( $self ) = @_;

    return if $self->{ filled };
    $self->{ filled } = 1;

    my $all  = GlitchVape::Registry->all;
    my $list = $self->{ effect_list };

    for my $stage ( GlitchVape::Registry->stages )
    {
        my $free = $self->{ available }{ $stage } or next;

        for my $name ( @$free )
        {
            my $spec = $all->{ $name };

            my $row = Gtk3::ListBoxRow->new;
            $row->add( _effect_row( $spec ) );
            $row->{ effect } = $name;
            $row->{ stage }  = $stage;

            # Pre-lowercased: the filter runs over every row on every
            # keystroke, and lc-ing three strings each time is work with a
            # known answer.
            $row->{ haystack } = lc join q{ }, $name, $spec->{ title },
                $spec->{ summary };

            $list->add( $row );
        }
    }

    $list->show_all;
    return;
}

sub _effect_row
{
    my ( $spec ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 2 );
    $box->set_border_width( 8 );

    my $head = Gtk3::Box->new( 'horizontal', 8 );

    my $title = Gtk3::Label->new;
    $title->set_markup( '<b>' . _escape( $spec->{ title } ) . '</b>' );
    $title->set_xalign( 0 );
    $title->set_hexpand( 1 );

    # The internal name rides along because it is what presets, --set and the
    # copied command line all use. Someone reading the README needs to be able
    # to connect the two.
    my $key = Gtk3::Label->new;
    $key->set_markup( "<span alpha='45%'><tt>"
            . _escape( $spec->{ name } )
            . '</tt></span>' );
    $key->set_xalign( 1 );

    $head->pack_start( $title, 1, 1, 0 );
    $head->pack_start( $key,   0, 0, 0 );

    my $summary = Gtk3::Label->new( $spec->{ summary } );
    $summary->set_xalign( 0 );
    $summary->set_line_wrap( 1 );
    $summary->set_max_width_chars( 60 );
    $summary->get_style_context->add_class( 'dim-label' );

    $box->pack_start( $head,    0, 0, 0 );
    $box->pack_start( $summary, 0, 0, 0 );

    return $box;
}

# A row that the filter has just hidden can keep its selection, which would
# leave Continue pointing at an effect that is no longer on screen. Dropping
# it lets the list select the first surviving row instead.
sub _resync_selection
{
    my ( $self ) = @_;

    my $list = $self->{ effect_list };
    my $row  = $list->get_selected_row or return;

    return if $self->_matches( $row );

    $list->unselect_row( $row );

    my ( $first ) = grep { $self->_matches( $_ ) } $list->get_children;
    $list->select_row( $first ) if $first;

    return;
}

sub _matches
{
    my ( $self, $row ) = @_;

    my $query = $self->{ query };

    if ( defined $query && length $query )
    {
        return index( $row->{ haystack }, $query ) >= 0;
    }

    return 0 unless defined $self->{ stage };
    return $row->{ stage } eq $self->{ stage };
}

sub _note_scope
{
    my ( $self ) = @_;

    my $query = $self->{ query };
    my $info  = GlitchVape::Registry->stage_info( $self->{ stage } );
    my $where = $info ? $info->{ title } : 'the whole chain';

    my $heading = $self->{ effect_heading };
    my $label   = $self->{ effect_scope };

    # The two say different things and have to keep agreeing: the heading is
    # where you are, the note under the list is what that place is for. A
    # search moves you somewhere else, so both have to say so -- a heading
    # still naming one category over a list showing all of them is worse than
    # no heading at all.
    if ( defined $query && length $query )
    {
        $heading->set_markup( '<b>Every category</b>' );

        $label->set_text( "Searching every category. Clear the box to go "
                . "back to $where." );
        return;
    }

    $heading->set_markup( '<b>' . _escape( $where ) . '</b>' );

    $label->set_text( $info ? $info->{ blurb } : q{} );
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

    $box->pack_start( $split, 1, 1, 0 );

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
        $self->_fill_effects;
        $self->{ effect_list }->invalidate_filter;
        $self->_resync_selection;
        $self->_note_scope;
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

    $self->{ on_apply }->( $self->{ effect }, { %{ $self->{ params } } } )
        if $self->{ on_apply };

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

L<GlitchVape::Registry> for the stage titles the first page is built from,
L<GlitchVape::GUI::Params> for the controls on the third, and
L<GlitchVape::GUI::Render> for why the preview happens in a child process.

=cut
