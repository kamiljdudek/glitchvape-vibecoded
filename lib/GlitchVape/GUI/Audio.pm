package GlitchVape::GUI::Audio;

use strict;
use warnings;

# Literal '⚠', '·' and '–' in labels. See the note in GlitchVape::GUI: without
# this they are read as Latin-1 and encoded a second time on the way into Gtk.
use utf8;

use File::Basename qw(basename);
use POSIX          ();

use Glib ();
use Gtk3 ();

use GlitchVape::Audio         ();
use GlitchVape::GUI::Player   ();
use GlitchVape::GUI::Waveform ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Audio - the add-a-track wizard

=head1 DESCRIPTION

A C<Gtk3::Assistant> in three pages: crop the file, choose the filters, confirm
what that produced. It hands back a L<GlitchVape::Audio> spec, which is the
same structure C<--audio> builds -- so a track added here is a command line the
user could have typed, in the same way an exported render is.

=head2 Why an Assistant rather than one dialog

The two decisions are sequential and the second depends on the first: the
filter page auditions the crop, and how long the result is cannot be said
until both are set. An Assistant is also the widget that already knows how to
put Back and Next in the right places for the platform.

=head2 Playback

L<GlitchVape::GUI::Player>, which is also what the dial wizard uses. The crop
page auditions the original file seeked to the selection, so it starts
instantly and the selection can go on being dragged while it plays; the filter
page renders the crop through the chain first and plays that, because the
filters are an ffmpeg chain rather than something GStreamer is holding.

=cut

# The waveform is reduced to this many columns whatever the window is. Wider
# than any plausible window, so the widget is always downsampling rather than
# stretching a coarse peak list across a wide pane.
use constant PEAK_BUCKETS => 2000;

# Chains worth having as one press. Vaporwave is a genre with conventions and
# these are three of them; everything is still adjustable afterwards.
my @QUICK = (
    [
        'Slowed + reverb',
        { slowed => 0.80, reverb => 0.50 },
        'The canonical one',
    ],
    [
        'Mallsoft',
        { slowed => 0.85, muffled => 0.80, reverb => 0.60 },
        'Distant, from two floors up',
    ],
    [
        'Tape dub',
        { slowed => 0.92, wobble => 0.40, muffled => 0.50 },
        'Third generation, played too often',
    ],
    [ 'Nothing', {}, 'The track as it is' ],
);

=head2 choose( %arg )

    parent  => Gtk3::Window
    cache   => GlitchVape::GUI::Cache
    on_done => sub { my ( $spec ) = @_ }

Ask for a file, then run the wizard on it. This is what the C<Add audio track>
button calls.

=cut

sub choose
{
    my ( $class, %arg ) = @_;

    my $dialog = Gtk3::FileChooserDialog->new(
        'Choose an audio file',
        $arg{ parent },
        'open', 'Cancel', 'cancel', 'Open', 'accept'
    );

    my $audio = Gtk3::FileFilter->new;
    $audio->set_name( 'Audio and video' );
    for my $ext ( GlitchVape::Audio::extensions() )
    {
        $audio->add_pattern( "*.$ext" );
        $audio->add_pattern( '*.' . uc $ext );
    }
    $dialog->add_filter( $audio );

    my $all = Gtk3::FileFilter->new;
    $all->set_name( 'All files' );
    $all->add_pattern( '*' );
    $dialog->add_filter( $all );

    my $response = $dialog->run;
    my $path     = $dialog->get_filename;
    $dialog->destroy;

    return unless $response eq 'accept';
    return unless defined $path;

    return $class->edit( %arg, spec => { path => $path } );
}

=head2 edit( %arg )

    spec => an existing spec to reopen

The wizard without the file chooser, for adjusting a track that is already
added.

=cut

sub edit
{
    my ( $class, %arg ) = @_;

    my $spec = $arg{ spec };
    return unless $spec && $spec->{ path };

    my $self = bless {
        parent   => $arg{ parent },
        cache    => $arg{ cache },
        on_done  => $arg{ on_done },
        on_error => $arg{ on_error },
        path     => $spec->{ path },
        start    => $spec->{ start },
        end      => $spec->{ end },
        filters  => { %{ $spec->{ filters } || {} } },
        duration => undef,
        rows     => {},
        player   => undef,
        loading  => 0,
    }, $class;

    $self->{ player } = GlitchVape::GUI::Player->new(
        on_error => sub {
            $self->_report( $_[ 0 ] );
            return;
        },
        on_position => sub {

            # Only meaningful over the original file; the filtered audition is
            # a separate rendering whose clock starts at zero.
            $self->{ wave }->set_playhead( $_[ 0 ] ) if $self->{ scrubbing };
            return;
        },
        on_state => sub {
            $self->_playing( $_[ 0 ] );
            return;
        },
    );

    $self->_build;
    $self->_load_peaks;

    $self->{ assistant }->show_all;
    $self->{ warning }->hide;

    return $self;
}

# ---------------------------------------------------------------------------
# Construction

sub _build
{
    my ( $self ) = @_;

    my $wizard = Gtk3::Assistant->new;
    $wizard->set_title( 'Add audio track' );
    $wizard->set_transient_for( $self->{ parent } ) if $self->{ parent };
    $wizard->set_modal( 1 );
    $wizard->set_default_size( 820, 520 );

    $self->{ assistant } = $wizard;

    $self->_add_page( $self->_build_crop_page, 'content', 'Crop the track',
              'Drag the selection to the part you want. '
            . 'The loop will repeat to cover it.' );

    $self->_add_page( $self->_build_filter_page, 'content', 'Make it vaporwave',
              'Everything here is optional, and everything can be heard '
            . 'before you commit to it.' );

    $self->_add_page( $self->_build_confirm_page,
        'confirm', 'Add this track', undef );

    $wizard->signal_connect(
        prepare => sub {
            $self->_prepare( $_[ 1 ] );
            return;
        }
    );

    $wizard->signal_connect(
        apply => sub {
            $self->{ on_done }->( $self->spec ) if $self->{ on_done };
            return;
        }
    );

    for my $signal ( qw(cancel close) )
    {
        $wizard->signal_connect(
            $signal => sub {
                $self->_finish;
                return;
            }
        );
    }

    # Closing with the title bar's X emits neither cancel nor close, and would
    # otherwise leave a playbin holding the audio device open.
    $wizard->signal_connect(
        delete_event => sub {
            $self->_finish;
            return 1;
        }
    );

    return;
}

sub _add_page
{
    my ( $self, $page, $type, $title, $note ) = @_;

    my $wizard = $self->{ assistant };

    my $box = Gtk3::Box->new( 'vertical', 10 );
    $box->set_border_width( 14 );

    if ( defined $note )
    {
        my $label = Gtk3::Label->new;
        $label->set_markup( "<span alpha='65%'>$note</span>" );
        $label->set_xalign( 0 );
        $label->set_line_wrap( 1 );
        $box->pack_start( $label, 0, 0, 0 );
    }

    $box->pack_start( $page, 1, 1, 0 );

    $wizard->append_page( $box );
    $wizard->set_page_type( $box, $type );
    $wizard->set_page_title( $box, $title );
    $wizard->set_page_complete( $box, 1 );

    return $box;
}

sub _build_crop_page
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 8 );

    $self->{ wave } = GlitchVape::GUI::Waveform->new(
        on_change => sub {
            my ( $start, $end ) = @_;
            $self->{ start } = $start;
            $self->{ end }   = $end;
            $self->_sync_spins;
            $self->_update_length;
            return;
        },
        on_scrub => sub {

            # Dragging an edge while playing should move playback to it,
            # otherwise the preview is of wherever the selection used to be.
            $self->{ player }->seek( $_[ 0 ] );
            return;
        },
    );

    my $frame = Gtk3::Frame->new;
    $frame->add( $self->{ wave }->widget );
    $box->pack_start( $frame, 1, 1, 0 );

    my $row = Gtk3::Box->new( 'horizontal', 8 );

    $self->{ crop_play } = $self->_play_button( sub { $self->_play_crop } );
    $row->pack_start( $self->{ crop_play }, 0, 0, 0 );

    $row->pack_start( Gtk3::Label->new( 'Start' ), 0, 0, 0 );
    $self->{ spin_start } = $self->_time_spin( 'start' );
    $row->pack_start( $self->{ spin_start }, 0, 0, 0 );

    $row->pack_start( Gtk3::Label->new( 'End' ), 0, 0, 0 );
    $self->{ spin_end } = $self->_time_spin( 'end' );
    $row->pack_start( $self->{ spin_end }, 0, 0, 0 );

    $self->{ length_label } = Gtk3::Label->new( q{} );
    $self->{ length_label }->set_xalign( 1 );
    $self->{ length_label }->set_hexpand( 1 );
    $row->pack_start( $self->{ length_label }, 1, 1, 0 );

    $box->pack_start( $row,                  0, 0, 0 );
    $box->pack_start( $self->_build_warning, 0, 0, 0 );

    return $box;
}

# The exclamation for a long selection. An info bar rather than a dialog: it
# appears while the selection is being dragged past the threshold and goes
# away again if the user drags back, which a modal cannot do -- and this is
# advice about how long the render will take, not a question.
sub _build_warning
{
    my ( $self ) = @_;

    my $bar = Gtk3::InfoBar->new;
    $bar->set_message_type( 'warning' );
    $bar->set_no_show_all( 1 );

    my $box = Gtk3::Box->new( 'horizontal', 8 );

    my $icon =
        Gtk3::Image->new_from_icon_name( 'dialog-warning-symbolic', 'button' );

    my $label = Gtk3::Label->new;
    $label->set_xalign( 0 );
    $label->set_line_wrap( 1 );

    $box->pack_start( $icon,  0, 0, 0 );
    $box->pack_start( $label, 1, 1, 0 );

    $bar->get_content_area->add( $box );
    $box->show_all;

    $self->{ warning }       = $bar;
    $self->{ warning_label } = $label;

    return $bar;
}

sub _time_spin
{
    my ( $self, $which ) = @_;

    my $spin = Gtk3::SpinButton->new_with_range( 0, 1, 0.01 );
    $spin->set_digits( 2 );
    $spin->set_width_chars( 8 );
    $spin->set_tooltip_text( "Seconds into the file" );

    $spin->signal_connect(
        'value-changed' => sub {
            return if $self->{ loading };

            $self->{ $which } = $spin->get_value;
            $self->{ wave }->set_selection( $self->{ start }, $self->{ end } );

            # The widget may have clamped what the spin asked for.
            ( $self->{ start }, $self->{ end } ) =
                $self->{ wave }->selection;

            $self->_sync_spins;
            $self->_update_length;
            return;
        }
    );

    return $spin;
}

sub _build_filter_page
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 10 );

    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 8 );
    $grid->set_column_spacing( 12 );

    my $row = 0;
    for my $filter ( @{ GlitchVape::Audio::filters() } )
    {
        $self->_build_filter_row( $grid, $row, $filter );
        $row++;
    }

    $box->pack_start( $grid, 0, 0, 0 );

    my $quick       = Gtk3::Box->new( 'horizontal', 6 );
    my $quick_label = Gtk3::Label->new( 'Or start from' );
    $quick_label->get_style_context->add_class( 'dim-label' );
    $quick->pack_start( $quick_label, 0, 0, 0 );

    for my $preset ( @QUICK )
    {
        my ( $name, $values, $tip ) = @$preset;

        my $button = Gtk3::Button->new_with_label( $name );
        $button->set_tooltip_text( $tip );
        $button->signal_connect(
            clicked => sub {
                $self->{ filters } = { %$values };
                $self->_reload_filters;
                return;
            }
        );
        $quick->pack_start( $button, 0, 0, 0 );
    }

    $box->pack_start( $quick, 0, 0, 0 );

    my $bottom = Gtk3::Box->new( 'horizontal', 8 );

    $self->{ filter_play } =
        $self->_play_button( sub { $self->_play_filtered } );
    $bottom->pack_start( $self->{ filter_play }, 0, 0, 0 );

    my $hint = Gtk3::Label->new( 'Auditions the crop with these filters' );
    $hint->get_style_context->add_class( 'dim-label' );
    $bottom->pack_start( $hint, 0, 0, 0 );

    $self->{ result_label } = Gtk3::Label->new( q{} );
    $self->{ result_label }->set_xalign( 1 );
    $bottom->pack_start( $self->{ result_label }, 1, 1, 0 );

    $box->pack_end( $bottom, 0, 0, 0 );

    return $box;
}

sub _build_filter_row
{
    my ( $self, $grid, $row, $filter ) = @_;

    my $name = $filter->{ name };

    my $check = Gtk3::CheckButton->new_with_label( $filter->{ label } );
    $check->set_tooltip_text( $filter->{ summary } );

    my $scale = Gtk3::Scale->new_with_range(
        'horizontal',
        $filter->{ min },
        $filter->{ max }, 0.01
    );
    $scale->set_digits( $filter->{ digits } );
    $scale->set_value_pos( 'right' );
    $scale->set_hexpand( 1 );
    $scale->set_tooltip_text( $filter->{ doc } );
    $scale->add_mark( $filter->{ default }, 'bottom', undef );

    my $unit = Gtk3::Label->new( $filter->{ unit } );
    $unit->get_style_context->add_class( 'dim-label' );
    $unit->set_xalign( 0 );

    # An absent filter is off, and its slider still shows the value it would
    # take if switched on -- otherwise every filter starts at its minimum,
    # which for 'slowed' is an unusable 0.5.
    my $value = $self->{ filters }{ $name };
    my $on    = 0;
    if ( defined $value )
    {
        $on = 1;
    }
    else
    {
        $value = $filter->{ default };
    }

    $check->set_active( $on );
    $scale->set_value( $value );
    $scale->set_sensitive( $on );

    $check->signal_connect(
        toggled => sub {
            return if $self->{ loading };

            my $active = $check->get_active;
            $scale->set_sensitive( $active );

            if ( $active )
            {
                $self->{ filters }{ $name } = $scale->get_value;
            }
            else
            {
                delete $self->{ filters }{ $name };
            }

            $self->_update_length;
            return;
        }
    );

    $scale->signal_connect(
        'value-changed' => sub {
            return if $self->{ loading };
            return unless $check->get_active;

            $self->{ filters }{ $name } = $scale->get_value;
            $self->_update_length;
            return;
        }
    );

    $grid->attach( $check, 0, $row, 1, 1 );
    $grid->attach( $scale, 1, $row, 1, 1 );
    $grid->attach( $unit,  2, $row, 1, 1 );

    $self->{ rows }{ $name } = { check => $check, scale => $scale };

    return;
}

sub _build_confirm_page
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 10 );

    my $label = Gtk3::Label->new;
    $label->set_xalign( 0 );
    $label->set_line_wrap( 1 );
    $label->set_valign( 'start' );

    $self->{ summary } = $label;
    $box->pack_start( $label, 1, 1, 0 );

    return $box;
}

# Play and Stop are not the same width, and a button that changes size when
# pressed is worse than one that is slightly too wide. Measured rather than
# guessed, as in GlitchVape::GUI.
sub _play_button
{
    my ( $self, $action ) = @_;

    my $button =
        Gtk3::Button->new_with_label( GlitchVape::GUI::Player::PLAY_LABEL );

    my $widest = 0;
    for my $text (
        GlitchVape::GUI::Player::PLAY_LABEL,
        GlitchVape::GUI::Player::STOP_LABEL,
        GlitchVape::GUI::Player::RENDERING_LABEL
        )
    {
        $button->set_label( $text );
        my ( undef, $natural ) = $button->get_preferred_width;
        $widest = $natural if $natural > $widest;
    }
    $button->set_label( GlitchVape::GUI::Player::PLAY_LABEL );
    $button->set_size_request( $widest, -1 );

    $button->signal_connect(
        clicked => sub {
            if ( $self->{ player }->playing || $self->{ rendering } )
            {
                $self->_stop;
                return;
            }

            $action->();
            return;
        }
    );

    return $button;
}

# ---------------------------------------------------------------------------
# Reading the file

# Decoding a whole album track to measure it takes about a second, which is a
# second the window would spend frozen. The same fork-and-watch shape as
# GlitchVape::GUI::Render, and safe for the same reason: no ImageMagick is
# involved on either side of the fork.
sub _load_peaks
{
    my ( $self ) = @_;

    my $out = $self->{ cache }->scratch( '.peaks' );

    my $pid = fork;

    unless ( defined $pid )
    {
        $self->_report( "cannot fork to read the audio file: $!" );
        return;
    }

    unless ( $pid )
    {
        _peaks_child( $self->{ path }, $out );
        POSIX::_exit( 70 );
    }

    Glib::Child->watch_add(
        $pid,
        sub {
            my ( undef, $status ) = @_;
            $self->_peaks_ready( $out, $status );
            return 0;
        }
    );

    return;
}

sub _peaks_child
{
    my ( $path, $out ) = @_;

    local $@;
    my $ok = eval {
        my $probe = GlitchVape::Audio::probe( $path );
        my $peaks = GlitchVape::Audio::peaks( $path, buckets => PEAK_BUCKETS );

        open my $fh, '>', $out or die "cannot write $out: $!\n";
        print { $fh } "$probe->{duration}\n";
        print { $fh } join( "\n", map { sprintf '%.4f', $_ } @$peaks );
        close $fh or die "cannot write $out: $!\n";

        1;
    };

    POSIX::_exit( 0 ) if $ok;

    my $err = $@ || 'unknown error';
    $err =~ s/\s+\z//;

    if ( open my $fh, '>', "$out.err" )
    {
        print { $fh } $err;
        close $fh;
    }

    POSIX::_exit( 1 );
}

sub _peaks_ready
{
    my ( $self, $out, $status ) = @_;

    if ( $status != 0 )
    {
        my $why = _slurp( "$out.err" );
        unlink "$out.err";

        $why = 'the file could not be read' unless defined $why && length $why;
        $self->_report( $why );

        # Nothing can be cropped, so the wizard has nothing to offer.
        $self->_finish;
        return;
    }

    my $text = _slurp( $out );
    unlink $out;

    my ( $duration, @peaks ) = split /\n/, ( $text // q{} );

    unless ( defined $duration && $duration > 0 )
    {
        $self->_report( 'the file reported no duration' );
        $self->_finish;
        return;
    }

    $self->{ duration } = $duration;

    # Taken before set_source, not after: set_source selects the whole file
    # and reports that back through on_change, which overwrites these two --
    # so reading them afterwards would find 0 and the duration, and reopening
    # a track would silently reset the crop the user had already chosen.
    my $wanted_start = $self->{ start };
    my $wanted_end   = $self->{ end };

    $self->{ loading }++;

    for my $spin ( $self->{ spin_start }, $self->{ spin_end } )
    {
        $spin->set_range( 0, $duration );
    }

    $self->{ wave }->set_source( \@peaks, $duration );

    # An existing spec being reopened keeps its selection; a new file starts
    # selected whole, which is what set_source just did.
    if ( defined $wanted_start && defined $wanted_end )
    {
        $self->{ wave }->set_selection( $wanted_start, $wanted_end );
    }

    ( $self->{ start }, $self->{ end } ) = $self->{ wave }->selection;

    $self->{ loading }--;

    $self->_sync_spins;
    $self->_update_length;

    return;
}

sub _slurp
{
    my ( $path ) = @_;

    return undef unless defined $path && -s $path;

    open my $fh, '<', $path or return undef;
    my $text = do { local $/ = undef; <$fh> };
    close $fh;

    return $text;
}

# ---------------------------------------------------------------------------
# Keeping the page in agreement with itself

sub _sync_spins
{
    my ( $self ) = @_;

    $self->{ loading }++;
    $self->{ spin_start }->set_value( $self->{ start } );
    $self->{ spin_end }->set_value( $self->{ end } );
    $self->{ loading }--;

    return;
}

sub _reload_filters
{
    my ( $self ) = @_;

    $self->{ loading }++;

    for my $filter ( @{ GlitchVape::Audio::filters() } )
    {
        my $name = $filter->{ name };
        my $row  = $self->{ rows }{ $name } or next;

        my $value = $self->{ filters }{ $name };
        my $on    = 0;
        if ( defined $value )
        {
            $on = 1;
        }
        else
        {
            $value = $filter->{ default };
        }

        $row->{ check }->set_active( $on );
        $row->{ scale }->set_sensitive( $on );
        $row->{ scale }->set_value( $value );
    }

    $self->{ loading }--;

    $self->_update_length;
    return;
}

sub _update_length
{
    my ( $self ) = @_;

    my $spec   = $self->spec;
    my $length = GlitchVape::Audio::selection_length( $spec );

    $self->{ length_label }->set_markup( sprintf '<b>%s</b> selected',
        GlitchVape::Audio::format_time( $length ) );

    $self->{ result_label }->set_markup(
        sprintf '<b>%s</b> of video',
        GlitchVape::Audio::format_time(
            GlitchVape::Audio::output_duration( $spec )
        )
    );

    $self->_update_warning( $spec );

    return;
}

sub _update_warning
{
    my ( $self, $spec ) = @_;

    unless ( GlitchVape::Audio::is_long( $spec ) )
    {
        $self->{ warning }->hide;
        return;
    }

    my $length = GlitchVape::Audio::selection_length( $spec );

    # Said in loops rather than only in seconds, because the number that
    # matters is how many times the pipeline is about to be re-encoded.
    # No '⚠' in the text: the info bar already carries the icon beside it, and
    # two exclamation marks on one line reads as a stutter rather than as
    # emphasis.
    $self->{ warning_label }->set_markup(
        sprintf '<b>%s selected.</b>  Longer than 30 seconds: the loop will '
            . 'repeat to cover it, so this will be a large file and a slow '
            . 'encode. Drag the edges in if that was not the intention.',
        GlitchVape::Audio::format_time( $length )
    );

    $self->{ warning }->show;

    return;
}

sub _prepare
{
    my ( $self, $page ) = @_;

    # Playback belongs to the page that started it: leaving the crop page
    # while the original is playing, to a page whose Play means something
    # else, would leave two meanings for one Stop button.
    $self->_stop;

    return unless $self->{ summary };
    return unless $self->{ assistant }->get_page_type( $page ) eq 'confirm';

    my $spec = $self->spec;

    my $text =
          sprintf "<big><b>%s</b></big>\n\n"
        . "Section    %s – %s   (%s)\n"
        . "Filters    %s\n"
        . "Result     %s of video, with the loop repeating to cover it\n",
        basename( $self->{ path } ),
        GlitchVape::Audio::format_time( $self->{ start } ),
        GlitchVape::Audio::format_time( $self->{ end } ),
        GlitchVape::Audio::format_time(
        GlitchVape::Audio::selection_length( $spec ) ),
        $self->_filter_summary,
        GlitchVape::Audio::format_time(
        GlitchVape::Audio::output_duration( $spec ) );

    if ( GlitchVape::Audio::is_long( $spec ) )
    {
        $text .= "\n<b>⚠  Over 30 seconds.</b>  This will take a while to "
            . 'render every time you press Apply or Export.';
    }

    $self->{ summary }->set_markup( $text );

    return;
}

sub _filter_summary
{
    my ( $self ) = @_;

    my @on;
    for my $filter ( @{ GlitchVape::Audio::filters() } )
    {
        my $value = $self->{ filters }{ $filter->{ name } };
        next unless defined $value;

        push @on, sprintf '%s %.2f', lc $filter->{ label }, $value;
    }

    return 'none' unless @on;
    return join ' · ', @on;
}

=head2 spec()

The L<GlitchVape::Audio> spec as the wizard currently stands.

=cut

sub spec
{
    my ( $self ) = @_;

    return {
        path    => $self->{ path },
        start   => $self->{ start },
        end     => $self->{ end },
        filters => { %{ $self->{ filters } } },
    };
}

# ---------------------------------------------------------------------------
# Playback

sub _play_crop
{
    my ( $self ) = @_;

    return unless defined $self->{ duration };

    # The original file, seeked. Nothing is rendered for this preview, so it
    # starts instantly and the selection can go on being dragged while it
    # plays.
    $self->{ scrubbing }   = 1;
    $self->{ play_button } = $self->{ crop_play };

    $self->{ player }->play(
        path => $self->{ path },
        from => $self->{ start },
        to   => $self->{ end },
    );

    return;
}

# The filtered audition has to be rendered first: the filters are an ffmpeg
# chain, not something GStreamer is holding.
sub _play_filtered
{
    my ( $self ) = @_;

    return unless defined $self->{ duration };

    my $out  = $self->{ cache }->scratch( '.wav' );
    my $spec = $self->spec;

    my $pid = fork;

    unless ( defined $pid )
    {
        $self->_report( "cannot fork to render the audio: $!" );
        return;
    }

    unless ( $pid )
    {
        local $@;
        my $ok = eval {
            GlitchVape::Audio::render( spec => $spec, output => $out );
            1;
        };

        POSIX::_exit( 0 ) if $ok;
        POSIX::_exit( 1 );
    }

    $self->{ rendering } = $pid;
    $self->{ filter_play }
        ->set_label( GlitchVape::GUI::Player::RENDERING_LABEL );

    Glib::Child->watch_add(
        $pid,
        sub {
            my ( undef, $status ) = @_;

            # Stop pressed while this was rendering: the result is no longer
            # wanted, and playing it now would be the button doing the
            # opposite of what it said.
            my $wanted = $self->{ rendering };
            $self->{ rendering } = undef;
            return 0 unless $wanted;

            $self->{ filter_play }
                ->set_label( GlitchVape::GUI::Player::PLAY_LABEL );

            if ( $status != 0 )
            {
                $self->_report( 'the filtered preview could not be rendered' );
                return 0;
            }

            $self->{ scrubbing }   = 0;
            $self->{ play_button } = $self->{ filter_play };
            $self->{ player }->play( path => $out );

            return 0;
        }
    );

    return;
}

# Both Play buttons read Stop while their own audition runs, and go back when
# it ends for any reason -- including reaching the end of the selection by
# itself, which a button that only reset on a press would miss.
sub _playing
{
    my ( $self, $on ) = @_;

    if ( $on )
    {
        $self->{ play_button }->set_label( GlitchVape::GUI::Player::STOP_LABEL )
            if $self->{ play_button };
        return;
    }

    $self->{ wave }->set_playhead( undef ) if $self->{ wave };

    for my $button ( $self->{ crop_play }, $self->{ filter_play } )
    {
        $button->set_label( GlitchVape::GUI::Player::PLAY_LABEL ) if $button;
    }

    return;
}

sub _stop
{
    my ( $self ) = @_;

    # A filtered audition that has not finished rendering yet. The watch is
    # left in place to reap it; clearing the flag is what tells the watch the
    # result is no longer wanted.
    if ( my $pid = $self->{ rendering } )
    {
        $self->{ rendering } = undef;
        kill 'TERM', $pid;
    }

    $self->{ player }->stop;
    $self->_playing( 0 );

    return;
}

sub _finish
{
    my ( $self ) = @_;

    $self->_stop;
    $self->{ assistant }->destroy if $self->{ assistant };
    $self->{ assistant } = undef;

    return;
}

sub _report
{
    my ( $self, $message ) = @_;

    $message = 'unknown error' unless defined $message && length $message;
    $message =~ s/\s+\z//;

    $self->{ on_error }->( $message ) if $self->{ on_error };

    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Waveform> for the crop control, L<GlitchVape::Audio> for
what the filters actually are, and L<GlitchVape::Animate> for what happens to
the result.

=cut
