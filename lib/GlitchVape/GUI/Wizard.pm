package GlitchVape::GUI::Wizard;

use strict;
use warnings;

# Literal '…' and '·' appear in page titles and status text below. See the
# note at the top of GlitchVape::GUI for what happens without this.
use utf8;

use Glib ();
use Gtk3 ();

use GlitchVape::Registry    ();
use GlitchVape::GUI::Params ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Wizard - the three-page Add Effect assistant

=head1 DESCRIPTION

Thirty-nine effects is too many for one list. The assistant asks three
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
    $lead->set_markup(
              'Effects are grouped by where they run in the chain, '
            . 'which is also what they are for. The chain always runs in '
            . 'the same order, and that order changes the picture — '
            . 'scanlines added before the frame is shrunk get shrunk away '
            . 'with it. So choose the part of the chain you want to change, '
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

    $box->pack_start( $head,  0, 0, 0 );
    $box->pack_start( $blurb, 0, 0, 0 );

    return $box;
}

# ---------------------------------------------------------------------------
# Page 2: effect

sub _effect_page
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 8 );
    $box->set_border_width( 12 );

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

    $self->{ effect_search } = $search;
    $self->{ effect_list }   = $list;
    $self->{ effect_scope }  = $scope;
    $self->{ effect_page }   = $box;

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
    my $label = $self->{ effect_scope };

    if ( defined $query && length $query )
    {
        $label->set_text( 'Searching every category. Clear the box to go '
                . 'back to the one you picked.' );
        return;
    }

    my $info = GlitchVape::Registry->stage_info( $self->{ stage } );
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
    $split->pack_start( $scroll,              1, 1, 0 );
    $split->pack_start( $self->_preview_pane, 0, 0, 0 );

    $box->pack_start( $split, 1, 1, 0 );

    $self->{ settings_heading } = $heading;
    $self->{ settings_summary } = $summary;
    $self->{ settings_grid }    = $grid;
    $self->{ settings_page }    = $box;

    return $box;
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

    $self->{ settings_heading }->set_markup( '<b>'
            . _escape( $spec->{ title } ) . '</b>'
            . "  <span alpha='45%'><tt>"
            . _escape( $name )
            . '</tt></span>' );
    $self->{ settings_summary }->set_text( $spec->{ summary } );

    my $grid = $self->{ settings_grid };
    $_->destroy for $grid->get_children;

    my $params = $spec->{ params };
    my $row    = 0;

    unless ( %$params )
    {
        my $none = Gtk3::Label->new( 'This effect takes no parameters.' );
        $none->set_xalign( 0 );
        $none->get_style_context->add_class( 'dim-label' );
        $grid->attach( $none, 0, 0, 2, 1 );
    }

    for my $key ( sort keys %$params )
    {
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

        $grid->attach( $built->{ label },   0, $row, 1, 1 );
        $grid->attach( $built->{ control }, 1, $row, 1, 1 );
        $row++;
    }

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
    $self->_schedule_preview;
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

sub _preview
{
    my ( $self ) = @_;

    my $name = $self->{ effect } or return;

    unless ( $self->{ state }->source )
    {
        $self->{ preview_note }
            ->set_text( 'Open an image to see this effect previewed.' );
        return;
    }

    # An in-flight render is of settings that have since changed, so its
    # result is of no use to anyone.
    $self->{ render }->cancel if $self->{ render }->busy;

    my $candidate = $self->{ state }->clone;
    $candidate->add_effect( $name );
    $candidate->effects->{ $name }{ params } = { %{ $self->{ params } } };

    $self->{ preview_note }->set_text( 'Rendering…' );

    $self->{ render }->preview(
        state   => $candidate,
        size    => PREVIEW_SIZE,
        on_done => sub {
            my ( $path ) = @_;
            $self->_show_preview( $path );
            return;
        },
        on_error => sub {
            my ( $message ) = @_;
            return if $self->{ gone };
            $message =~ s/\s+\z//;
            $self->{ preview_note }->set_text( $message );
            return;
        },
    );

    return;
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
