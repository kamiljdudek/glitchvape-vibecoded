package GlitchVape::GUI::ExportWizard;

use strict;
use warnings;
use utf8;

use File::Basename ();
use File::Spec     ();

use Gtk3 ();

use GlitchVape::GUI::Assistant ();
use GlitchVape::GUI::Export    ();
use GlitchVape::GUI::Profiles  ();
use GlitchVape::IO             ();
use GlitchVape::Tools          ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::ExportWizard - the questions an export has to answer

=head1 DESCRIPTION

A C<Gtk3::Assistant> over the export settings and the destination, replacing
the file chooser that used to be the whole of it.

=head1 WHY A WIZARD AND NOT A DIALOG

Export used to be one file chooser. That put every decision except the
filename somewhere else -- in a settings dialog reached from the menu, which
had to be visited before exporting and said nothing about the export about to
happen. The two halves of one action were in two places and only one of them
was on the way.

An assistant puts them in the order they are decided: how big, in what, with
what options, how long, and where to put it. Each is a page with room to say
what the answer means, which a row in a grid does not have.

=head1 EXPRESS IS THE FIRST PAGE, NOT A SHORTCUT PAST IT

Most exports are the same export as last time. So the first page is a choice
between a saved profile -- one click, the filename already decided and shown --
and answering the questions.

It is first rather than a button on the last page because it changes how many
pages there are. Offering it at the end would mean walking the pages to find
out they were not needed.

=head1 THE PAGES SKIP THEMSELVES

C<set_forward_page_func> decides what comes next, so a still never sees the
frame rate page and a format with no options of its own never shows an empty
one. A page that appears greyed out to say it does not apply teaches nothing
that leaving it out does not.

=cut

# Page indices. Named because the forward function talks about them and a
# bare 3 in that code would be unreadable the day a page is inserted.
use constant {
    PAGE_START  => 0,
    PAGE_SIZE   => 1,
    PAGE_FORMAT => 2,
    PAGE_OPTION => 3,
    PAGE_MOTION => 4,
    PAGE_WHERE  => 5,
};

=head2 run( %arg )

    parent    => Gtk3::Window
    settings  => the current export settings hash
    animated  => whether an animation is being written
    source    => the file that was opened, for naming the output after it
    preset    => the preset name, likewise
    on_done   => sub { my ( $settings, $path ) = @_ }

Modal. C<on_done> is called once, with the settings to export under and the
path to write, and not at all if the assistant is cancelled.

=cut

sub run
{
    my ( $class, %arg ) = @_;

    my $self = bless {
        animated => $arg{ animated } ? 1 : 0,
        source   => $arg{ source },
        preset   => $arg{ preset },
        on_done  => $arg{ on_done },
        settings => {
            %{ GlitchVape::GUI::Export::defaults() },
            %{ $arg{ settings } || {} },
        },
        profiles => GlitchVape::GUI::Profiles::load(),
        express  => 1,
    }, $class;

    my $assistant = Gtk3::Assistant->new;
    $assistant->set_transient_for( $arg{ parent } ) if $arg{ parent };
    $assistant->set_modal( 1 );
    $assistant->set_default_size( 560, 420 );
    $assistant->set_title( 'Export' );

    $self->{ assistant } = $assistant;

    $self->_add_start;
    $self->_add_size;
    $self->_add_format;
    $self->_add_option;
    $self->_add_motion;
    $self->_add_where;

    $assistant->signal_connect( cancel => sub { $self->_close; return } );
    $assistant->signal_connect( close  => sub { $self->_close; return } );

    # Apply records the answer and nothing else. Destroying the assistant from
    # here took the window down in the middle of Gtk's own click handler,
    # which goes on to work out whether there is a page after this one -- so
    # the export was written, the assistant was freed, and the program then
    # segfaulted reading it. Gtk emits close straight afterwards, and that is
    # where a window is allowed to go.
    $assistant->signal_connect(
        apply => sub {
            $self->_finish;
            return;
        }
    );

    # The destination line is derived from everything before it, so it is
    # rebuilt on the way in rather than kept up to date from every control
    # that could have changed it.
    $assistant->signal_connect(
        prepare => sub {
            my ( undef, $page ) = @_;
            $self->_prepare( $page );
            return;
        }
    );

    $assistant->show_all;

    # After show_all, and it installs the forward function itself: see
    # GlitchVape::GUI::Assistant for both reasons.
    GlitchVape::GUI::Assistant::navigate( $assistant,
        sub { return $self->_next( $_[ 0 ] ) } );

    return $self;
}

# ---------------------------------------------------------------------------
# Page 0: express or advanced

sub _add_start
{
    my ( $self ) = @_;

    my $box = _page_box();

    my $express = Gtk3::RadioButton->new_with_label( undef,
        'Express — use a saved profile' );
    my $advanced =
        Gtk3::RadioButton->new_with_label_from_widget( $express,
        'Advanced — choose everything' );

    $box->pack_start( $express, 0, 0, 0 );

    # The profile list belongs to the Express choice, so it is indented under
    # it rather than sitting alongside as a third thing on the page.
    my $indent = Gtk3::Box->new( 'vertical', 6 );
    $indent->set_margin_start( 26 );

    my $list = Gtk3::ComboBoxText->new;
    my $kind = $self->{ animated } ? 'video' : 'still';
    my $mine = GlitchVape::GUI::Profiles::of_kind( $self->{ profiles }, $kind );

    $list->append_text( $_->{ name } ) for @$mine;
    $list->set_active( 0 ) if @$mine;

    $self->{ profile_list }  = $list;
    $self->{ profile_order } = $mine;

    $indent->pack_start( $list, 0, 0, 0 );

    # What the one click would actually do, spelled out. An express export
    # with nothing shown is a button that writes a file somewhere.
    my $hint = Gtk3::Label->new( q{} );
    $hint->set_xalign( 0 );
    $hint->set_line_wrap( 1 );
    $hint->get_style_context->add_class( 'dim-label' );
    $self->{ express_hint } = $hint;
    $indent->pack_start( $hint, 0, 0, 0 );

    $box->pack_start( $indent,   0, 0, 0 );
    $box->pack_start( $advanced, 0, 0, 0 );

    my $sync = sub {
        $self->{ express } = $express->get_active ? 1 : 0;
        $indent->set_sensitive( $self->{ express } );
        $self->_describe_express;
        return;
    };

    $express->signal_connect( toggled => $sync );
    $list->signal_connect(
        changed => sub { $self->_describe_express; return } );

    # No profiles of this kind is not an error, but Express cannot be the
    # answer either, so it says so and Advanced takes over.
    unless ( @$mine )
    {
        $express->set_sensitive( 0 );
        $advanced->set_active( 1 );
        $hint->set_text( "No saved profiles for a $kind yet. "
                . 'Advanced will ask instead.' );
    }

    $sync->();

    $self->_append( $box, 'Export mode', 'intro' );

    return;
}

sub _describe_express
{
    my ( $self ) = @_;

    return unless $self->{ express };

    my $profile  = $self->_chosen_profile or return;
    my $settings = GlitchVape::GUI::Profiles::settings( $profile );

    $self->{ express_hint }->set_text(
        GlitchVape::GUI::Export::describe( $settings, $self->{ animated } )
            . "\n"
            . File::Spec->catfile(
            _default_dir( $self->{ animated } ),
            $self->_filename( $settings )
            )
    );

    return;
}

sub _chosen_profile
{
    my ( $self ) = @_;

    my $at = $self->{ profile_list }->get_active;
    return undef if !defined $at || $at < 0;

    return $self->{ profile_order }[ $at ];
}

# ---------------------------------------------------------------------------
# Page 1: resolution

sub _add_size
{
    my ( $self ) = @_;

    my $box = _page_box();

    $box->pack_start(
        _explain(
                  'A cap on the longer side, with the aspect kept and the '
                . 'picture never enlarged. Native means no cap at all, which '
                . 'on a phone photograph is a twelve-megapixel video.'
        ),
        0, 0, 0
    );

    my $combo = Gtk3::ComboBoxText->new;
    my $sizes = GlitchVape::GUI::Export::sizes();
    my $want  = $self->{ animated } ? $self->{ settings }{ video_size } : 0;

    my $active = 0;
    for my $n ( 0 .. $#$sizes )
    {
        $combo->append_text( $sizes->[ $n ][ 1 ] );
        $active = $n if $sizes->[ $n ][ 0 ] == ( $want // 0 );
    }
    $combo->set_active( $active );

    $combo->signal_connect(
        changed => sub {
            my $at = $combo->get_active;
            $self->{ settings }{ video_size } = $sizes->[ $at ][ 0 ]
                if defined $at && $at >= 0;
            return;
        }
    );

    $box->pack_start( $combo, 0, 0, 0 );

    # A still's size is the source's, or the retro box on the options page.
    # Saying so is better than a control that does nothing.
    $box->pack_start(
        _explain(
                  'Stills are written at the size the effects produced; '
                . 'the next pages have the one option that changes that.'
        ),
        0, 0, 0
    ) unless $self->{ animated };

    $combo->set_sensitive( $self->{ animated } );

    $self->_append( $box, 'Resolution', 'content' );

    return;
}

# ---------------------------------------------------------------------------
# Page 2: format

sub _add_format
{
    my ( $self ) = @_;

    my $box = _page_box();

    my $formats =
        $self->{ animated }
        ? GlitchVape::GUI::Export::video_formats()
        : GlitchVape::GUI::Export::still_formats();

    my $key = $self->{ animated } ? 'video_format' : 'still_format';

    my $note = Gtk3::Label->new( q{} );
    $note->set_xalign( 0 );
    $note->set_line_wrap( 1 );
    $note->get_style_context->add_class( 'dim-label' );

    my $first;
    for my $format ( @$formats )
    {
        my $radio =
            $first
            ? Gtk3::RadioButton->new_with_label_from_widget( $first,
            $format->{ label } )
            : Gtk3::RadioButton->new_with_label( undef, $format->{ label } );
        $first ||= $radio;

        $radio->set_active( 1 )
            if $format->{ key } eq ( $self->{ settings }{ $key } // q{} );

        $radio->signal_connect(
            toggled => sub {
                return unless $radio->get_active;
                $self->{ settings }{ $key } = $format->{ key };
                $note->set_text( $format->{ note } // q{} );
                return;
            }
        );

        $box->pack_start( $radio, 0, 0, 0 );
    }

    $note->set_text(
        GlitchVape::GUI::Export::format_note(
            $self->{ settings },
            $self->{ animated }
        )
    );

    $box->pack_start( $note, 0, 0, 0 );

    $self->_append( $box, 'Format', 'content' );

    return;
}

# ---------------------------------------------------------------------------
# Page 3: whatever the format itself asks

sub _add_option
{
    my ( $self ) = @_;

    my $box = _page_box();

    # Only stills have one, and it is the retro box. If a video format ever
    # grows an option of its own it goes here and _has_options lets the page
    # through; until then the page is skipped rather than shown empty.
    my $retro = Gtk3::CheckButton->new_with_label(
        sprintf 'Fit inside %d×%d, as a screen of the period would have',
        @{ GlitchVape::GUI::Export::retro_box() } );

    $retro->set_active( $self->{ settings }{ retro } ? 1 : 0 );
    $retro->signal_connect(
        toggled => sub {
            $self->{ settings }{ retro } = $retro->get_active ? 1 : 0;
            return;
        }
    );

    $box->pack_start( $retro, 0, 0, 0 );
    $box->pack_start(
        _explain(
                  'Shrinks the finished picture to fit the box, turning it '
                . 'for a portrait photograph. It is a fit, not a crop: '
                . 'nothing is cut off and nothing is padded.'
        ),
        0, 0, 0
    );

    $self->_append( $box, 'Format options', 'content' );

    return;
}

sub _has_options
{
    my ( $self ) = @_;

    return $self->{ animated } ? 0 : 1;
}

# ---------------------------------------------------------------------------
# Page 4: how long, and how fast

sub _add_motion
{
    my ( $self ) = @_;

    my $box = _page_box();

    $box->pack_start(
        _explain(
                  'The loop is rendered once and repeated to cover any '
                . 'soundtrack, so this is the length of the loop rather than '
                . 'the length of the file.'
        ),
        0, 0, 0
    );

    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 8 );
    $grid->set_column_spacing( 10 );

    my $frames = Gtk3::SpinButton->new_with_range( 2, 240, 1 );
    $frames->set_value( $self->{ settings }{ frames } // 24 );
    $frames->signal_connect(
        'value-changed' => sub {
            $self->{ settings }{ frames } = $frames->get_value_as_int;
            $self->_update_length;
            return;
        }
    );

    my $fps = Gtk3::SpinButton->new_with_range( 1, 60, 1 );
    $fps->set_value( $self->{ settings }{ fps } // 12 );
    $fps->signal_connect(
        'value-changed' => sub {
            $self->{ settings }{ fps } = $fps->get_value_as_int;
            $self->_update_length;
            return;
        }
    );

    my $row = 0;
    for my $pair ( [ 'Frames in the loop', $frames ],
        [ 'Frames per second', $fps ] )
    {
        my $label = Gtk3::Label->new( $pair->[ 0 ] );
        $label->set_xalign( 0 );
        $grid->attach( $label,       0, $row, 1, 1 );
        $grid->attach( $pair->[ 1 ], 1, $row, 1, 1 );
        $row++;
    }

    $box->pack_start( $grid, 0, 0, 0 );

    my $length = Gtk3::Label->new( q{} );
    $length->set_xalign( 0 );
    $length->get_style_context->add_class( 'dim-label' );
    $self->{ length_label } = $length;
    $box->pack_start( $length, 0, 0, 0 );

    $self->_update_length;

    $self->_append( $box, 'Frames and frame rate', 'content' );

    return;
}

sub _update_length
{
    my ( $self ) = @_;

    return unless $self->{ length_label };

    my $frames = $self->{ settings }{ frames } // 24;
    my $fps    = $self->{ settings }{ fps } || 1;

    $self->{ length_label }
        ->set_text( sprintf 'One loop lasts %.1f seconds.', $frames / $fps );

    return;
}

# ---------------------------------------------------------------------------
# Page 5: where it goes

sub _add_where
{
    my ( $self ) = @_;

    my $box = _page_box();

    my $chooser = Gtk3::FileChooserButton->new( 'Folder', 'select-folder' );
    $chooser->set_filename( _default_dir( $self->{ animated } ) );
    $self->{ folder } = $chooser;

    my $name = Gtk3::Entry->new;
    $name->set_activates_default( 1 );
    $self->{ name } = $name;

    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 8 );
    $grid->set_column_spacing( 10 );

    my $row = 0;
    for my $pair ( [ 'Folder', $chooser ], [ 'File name', $name ] )
    {
        my $label = Gtk3::Label->new( $pair->[ 0 ] );
        $label->set_xalign( 0 );
        $pair->[ 1 ]->set_hexpand( 1 );
        $grid->attach( $label,       0, $row, 1, 1 );
        $grid->attach( $pair->[ 1 ], 1, $row, 1, 1 );
        $row++;
    }

    $box->pack_start( $grid, 0, 0, 0 );

    my $summary = Gtk3::Label->new( q{} );
    $summary->set_xalign( 0 );
    $summary->set_line_wrap( 1 );
    $summary->get_style_context->add_class( 'dim-label' );
    $self->{ summary } = $summary;
    $box->pack_start( $summary, 0, 0, 0 );

    # An empty name is the one answer this page cannot accept, so Apply goes
    # away rather than writing a file called nothing.
    $name->signal_connect(
        changed => sub {
            $self->{ assistant }
                ->set_page_complete( $box, length( $name->get_text ) ? 1 : 0 );
            return;
        }
    );

    $self->{ where_page } = $box;
    $self->_append( $box, 'File location', 'confirm' );

    # Nothing is in it until _prepare fills it in, and Apply on an empty
    # destination would write a file called nothing.
    $self->{ assistant }->set_page_complete( $box, 0 );

    return;
}

# ---------------------------------------------------------------------------

# What comes after the page just left. Express jumps the middle out entirely;
# the others drop themselves when they have nothing to ask.
sub _next
{
    my ( $self, $from ) = @_;

    return PAGE_WHERE if $from == PAGE_START && $self->{ express };
    return PAGE_SIZE  if $from == PAGE_START;

    if ( $from == PAGE_FORMAT )
    {
        return PAGE_OPTION if $self->_has_options;
        return $self->{ animated } ? PAGE_MOTION : PAGE_WHERE;
    }

    return $self->{ animated } ? PAGE_MOTION : PAGE_WHERE
        if $from == PAGE_OPTION;

    return PAGE_WHERE if $from == PAGE_MOTION;

    return $from + 1;
}

sub _prepare
{
    my ( $self, $page ) = @_;

    return unless $self->{ where_page } && $page == $self->{ where_page };

    # Express never visited the pages that would have changed the settings, so
    # the profile is applied here -- at the point where it is first needed and
    # after the user has had a page on which to change their mind.
    if ( $self->{ express } )
    {
        if ( my $profile = $self->_chosen_profile )
        {
            $self->{ settings } =
                GlitchVape::GUI::Profiles::settings( $profile );
        }
    }

    $self->{ name }->set_text( $self->_filename( $self->{ settings } ) );
    $self->{ summary }->set_text(
        GlitchVape::GUI::Export::describe(
            $self->{ settings },
            $self->{ animated }
        )
    );

    $self->{ assistant }->set_page_complete( $self->{ where_page }, 1 );

    return;
}

# What was chosen, read off the page while it is still standing. Splitting the
# answer from the acting on it is what lets the window come down at the moment
# Gtk expects it to and the export start once it has.
sub _finish
{
    my ( $self ) = @_;

    my $dir = $self->{ folder }->get_filename
        // _default_dir( $self->{ animated } );

    $self->{ chosen } = [
        $self->{ settings },
        File::Spec->catfile( $dir, $self->{ name }->get_text ),
    ];

    return;
}

# Cancel and close both mean the window goes; only one of them has been
# through apply, and that is what tells the caller anything.
sub _close
{
    my ( $self ) = @_;

    $self->{ assistant }->destroy;

    my $chosen = delete $self->{ chosen } or return;

    $self->{ on_done }->( @$chosen ) if $self->{ on_done };

    return;
}

# The name only, without a directory: the folder is chosen separately and
# joining them here would put the old one back.
sub _filename
{
    my ( $self, $settings ) = @_;

    my $format;
    if ( $self->{ animated } )
    {
        my %target = GlitchVape::GUI::Export::video_target( $settings );
        $format = $target{ ext };
    }
    else
    {
        $format = GlitchVape::GUI::Export::still_extension( $settings,
            $self->{ source } );
    }

    my $path = GlitchVape::IO::derive_output_path(
        $self->{ source } // 'render',
        dir    => q{.},
        format => $format,
        preset => $self->{ preset },
    );

    return File::Basename::basename( $path );
}

# Where a video or a picture goes on this desktop. xdg-user-dir knows the
# localised names -- a German desktop has Videos but a French one has Vidéos --
# and falls back to the English ones, which is also what happens when it is not
# installed at all.
sub _default_dir
{
    my ( $animated ) = @_;

    my $key  = $animated ? 'VIDEOS' : 'PICTURES';
    my $name = $animated ? 'Videos' : 'Pictures';

    my $home = $ENV{ HOME };
    return File::Spec->curdir unless defined $home && length $home;

    # Through Tools rather than backticks: no shell, so a home directory with
    # a space or a quote in it is a path and not three arguments.
    my $found = GlitchVape::Tools::capture( 'xdg-user-dir', $key );
    $found = q{} unless defined $found;
    chomp $found;

    return $found if length $found && -d $found && $found ne $home;

    my $guess = File::Spec->catdir( $home, $name );
    return -d $guess ? $guess : $home;
}

sub _page_box
{
    my $box = Gtk3::Box->new( 'vertical', 10 );
    $box->set_border_width( 16 );

    return $box;
}

sub _explain
{
    my ( $text ) = @_;

    my $label = Gtk3::Label->new( $text );
    $label->set_xalign( 0 );
    $label->set_line_wrap( 1 );
    $label->set_max_width_chars( 54 );
    $label->get_style_context->add_class( 'dim-label' );

    return $label;
}

sub _append
{
    my ( $self, $page, $title, $type ) = @_;

    my $assistant = $self->{ assistant };

    $assistant->append_page( $page );
    $assistant->set_page_title( $page, $title );
    $assistant->set_page_type( $page, $type );
    $assistant->set_page_complete( $page, 1 );

    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Export> for what the settings mean and
L<GlitchVape::GUI::Profiles> for where the saved ones live.

=cut
