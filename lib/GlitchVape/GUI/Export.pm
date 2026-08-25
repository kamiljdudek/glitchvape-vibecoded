package GlitchVape::GUI::Export;

use strict;
use warnings;

# Literal '·' and '…' appear in labels below. See the note at the top of
# GlitchVape::GUI for what happens without this.
use utf8;

use File::Basename qw(fileparse);

use Gtk3 ();

use GlitchVape::Animate ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Export - what Export writes, and at what size

=head1 DESCRIPTION

Export used to ask one question, in a file chooser: where. Everything else
followed from the name that was typed there -- the extension picked the
encoder, and the size was whatever the preset happened to say. That is a fine
default and a poor only option, because the two things people actually change
are the size and the format, and neither should require knowing that C<.webm>
means VP9.

So they are settings, held in one place and edited in one dialog, with a tab
each for the two outputs. They are not the same question asked twice: a video
has a frame rate and a codec, a still has a palette, and the one thing they
share -- how big -- means different enough things in the two cases that it is
asked differently.

=head1 THE SETTINGS ARE A PLAIN HASH

C<run> is handed one and hands a new one back; nothing here holds state
between calls. That keeps this module a dialog rather than a second place
where the truth about an export lives, and it is what lets
L<GlitchVape::GUI::CommandLine> print the same settings without going through
a window.

=head2 Frame rate is one setting, shown twice

The frame rate is on the video tab and also in Animation settings, because it
is genuinely both: it is how fast the loop plays, which is a property of the
animation, and it is the rate of the file, which is a property of the export.
Rather than have two numbers that can disagree, both dialogs read and write
the same one -- and the video tab says so.

=head1 SIZES ARE A CAP ON THE LONG EDGE

The resolution list is the previewer's, extended upwards, and it means what
the previewer's means: a limit on the longer side, aspect preserved, never
enlarged. C<720> is 720x540 for a 4:3 photograph and 540x720 for a portrait
one. It is not the broadcast sense of 720p -- nothing here pads a picture out
to a frame it does not fill.

C<Native> is the exception, and is deliberately not the default: it means "do
not cap at all", and on a modern phone photograph that is a 12-megapixel
video, which is not what somebody who has not thought about it wants.

=cut

# Longest edge, and the label for it. The first three are the previewer's own
# list so that a preview and an export at the same setting mean the same
# thing; the rest are there because an export is where the large sizes are
# actually wanted.
my @SIZES = (
    [ 512,  'Small · 512 px' ],
    [ 720,  'Standard · 720 px' ],
    [ 900,  'Detailed · 900 px' ],
    [ 1080, 'Large · 1080 px' ],
    [ 1440, 'Very large · 1440 px' ],
    [ 1920, 'Full HD · 1920 px' ],
    [ 0,    'Native — no limit' ],
);

# key => container extension, codec for GlitchVape::Animate, and what to call
# it. Keyed rather than positional because the key is what gets stored, and a
# stored index would silently mean something else the day a format is added.
my @VIDEO_FORMATS = (
    {
        key   => 'mp4',
        ext   => 'mp4',
        codec => 'h264',
        label => 'MP4 · H.264',
        note  => 'Common default.',
    },
    {
        key   => 'webm',
        ext   => 'webm',
        codec => 'vp9',
        label => 'WebM · VP9',
        note  => 'Smaller than MP4 at the same quality; plays in browsers.',
    },
    {
        key   => 'webm-av1',
        ext   => 'webm',
        codec => 'av1',
        label => 'WebM · AV1',
        note  => 'Smallest of the three, modern and demanding codec.',
    },
);

my @STILL_FORMATS = (
    {
        key   => 'origin',
        label => 'Same as the original',
        note  => 'A JPEG in stays a JPEG out; a HEIC stays a HEIC.',
    },
    {
        key   => 'png',
        ext   => 'png',
        label => 'PNG',
        note  => 'Lossless and popular',
    },
    {
        key    => 'bmp256',
        ext    => 'bmp',
        colors => 256,
        label  => 'Windows Bitmap · 256 colours',
        note   => 'An 8-bit .bmp with a dithered palette, as a 1995 '
            . 'desktop would have held it.',
    },
);

# The retro box, in the orientation of a landscape picture. It turns with the
# photograph -- see GlitchVape::IO -- so a portrait shot gets 480x640 rather
# than 360x480, which is what a screen of this size actually did with one.
use constant RETRO_BOX => [ 640, 480 ];

=head2 defaults()

The settings a fresh session starts with.

=cut

sub defaults
{
    return {
        video_size   => 720,
        video_format => 'mp4',
        fps          => 12,
        still_format => 'origin',
        retro        => 0,
    };
}

=head2 run( %arg )

    parent   => Gtk3::Window
    settings => the current hash
    on_done  => sub { my ( $settings ) = @_ }

Modal. C<on_done> is called with a new hash when the dialog is closed, and not
at all if it is cancelled.

=cut

sub run
{
    my ( $class, %arg ) = @_;

    my %settings = ( %{ defaults() }, %{ $arg{ settings } || {} } );

    my $dialog = Gtk3::Dialog->new_with_buttons(
        'Export settings',
        $arg{ parent },
        'modal', 'Cancel', 'cancel', 'Save', 'accept'
    );
    $dialog->set_default_size( 460, -1 );

    my $book = Gtk3::Notebook->new;
    $book->set_border_width( 10 );

    my $video = _video_page( \%settings );
    my $still = _still_page( \%settings );

    $book->append_page( $video->{ page }, Gtk3::Label->new( 'Video' ) );
    $book->append_page( $still->{ page }, Gtk3::Label->new( 'Stills' ) );

    $dialog->get_content_area->add( $book );
    $dialog->set_default_response( 'accept' );
    $dialog->show_all;

    my $answer = $dialog->run;

    # Read back only on Save. The controls have been writing into their own
    # copy all along, so Cancel is simply not passing it on.
    my %out =
        ( %settings, %{ $video->{ read }->() }, %{ $still->{ read }->() } );

    $dialog->destroy;

    return unless $answer eq 'accept';

    $arg{ on_done }->( \%out ) if $arg{ on_done };

    return \%out;
}

# ---------------------------------------------------------------------------
# Pages

sub _video_page
{
    my ( $settings ) = @_;

    my $grid = _grid();
    my $row  = 0;

    my $fps = Gtk3::SpinButton->new_with_range( 1, 60, 1 );
    $fps->set_value( $settings->{ fps } );
    $fps->set_tooltip_text( 'How fast the loop plays. The same setting as '
            . 'the frame rate in Animation settings' );

    my $size = _size_combo( $settings->{ video_size } );
    $size->set_tooltip_text(
        'A limit on the longer side. The aspect ratio is never changed and '
            . 'a smaller picture is never enlarged' );

    my $format = Gtk3::ComboBoxText->new;
    $format->append_text( _format_label( $_ ) ) for @VIDEO_FORMATS;
    $format->set_active(
        _index_of( \@VIDEO_FORMATS, $settings->{ video_format } ) );

    my $note = _note_label();

    my $describe = sub {
        my $chosen = $VIDEO_FORMATS[ $format->get_active ] or return;
        my $text   = $chosen->{ note };

        # Said at the moment of choosing rather than at the end of a long
        # encode that fails: an ffmpeg without libsvtav1 is an ordinary
        # Fedora install, not a broken one.
        $text .=
              "\nThis ffmpeg cannot write it — install an ffmpeg with "
            . 'the AV1 encoder, or choose another format.'
            unless GlitchVape::Animate::codec_available( $chosen->{ codec } );

        $note->set_text( $text );
        return;
    };

    $format->signal_connect( changed => sub { $describe->(); return } );
    $describe->();

    $row = _pair( $grid, $row, 'Frame rate', $fps );
    $row = _pair( $grid, $row, 'Resolution', $size );
    $row = _pair( $grid, $row, 'Format',     $format );

    $grid->attach( $note, 0, $row++, 2, 1 );

    return {
        page => $grid,
        read => sub {
            return {
                fps          => int $fps->get_value,
                video_size   => $SIZES[ $size->get_active ][ 0 ],
                video_format => $VIDEO_FORMATS[ $format->get_active ]{ key },
            };
        },
    };
}

sub _still_page
{
    my ( $settings ) = @_;

    my $grid = _grid();
    my $row  = 0;

    my $format = Gtk3::ComboBoxText->new;
    $format->append_text( _format_label( $_ ) ) for @STILL_FORMATS;
    $format->set_active(
        _index_of( \@STILL_FORMATS, $settings->{ still_format } ) );

    my $note = _note_label();

    $format->signal_connect(
        changed => sub {
            my $chosen = $STILL_FORMATS[ $format->get_active ] or return;
            $note->set_text( $chosen->{ note } );
            return;
        }
    );
    $note->set_text( $STILL_FORMATS[ $format->get_active ]{ note } );

    my ( $bw, $bh ) = @{ +RETRO_BOX };

    my $retro = Gtk3::CheckButton->new_with_label(
        "Keep retro-friendly dimensions (${bw}×${bh})" );
    $retro->set_active( $settings->{ retro } ? 1 : 0 );
    $retro->set_tooltip_text(
              "Shrink the exported picture until it fits a ${bw}×${bh} "
            . "screen, keeping its proportions.\n"
            . 'The box turns with the photograph, so a portrait shot '
            . "becomes ${bh}×${bw} rather than being made tiny" );

    $row = _pair( $grid, $row, 'Format', $format );

    $grid->attach( $note,  0, $row++, 2, 1 );
    $grid->attach( $retro, 0, $row++, 2, 1 );

    my $why = _note_label();
    $why->set_text( 'Applied to the finished picture, so a border or a '
            . 'letterbox added by an effect is inside the box rather than '
            . 'pushing the result out of it.' );
    $grid->attach( $why, 0, $row++, 2, 1 );

    return {
        page => $grid,
        read => sub {
            return {
                still_format => $STILL_FORMATS[ $format->get_active ]{ key },
                retro        => $retro->get_active ? 1 : 0,
            };
        },
    };
}

# ---------------------------------------------------------------------------
# What the settings mean to a render

=head2 video_target( $settings )

C<< ( ext => 'webm', codec => 'av1' ) >> for the chosen video format.

=cut

sub video_target
{
    my ( $settings ) = @_;

    my $chosen = _entry( \@VIDEO_FORMATS, $settings->{ video_format } );

    return ( ext => $chosen->{ ext }, codec => $chosen->{ codec } );
}

=head2 still_extension( $settings, $source )

The extension a still should be written with. C<origin> resolves against the
file that was opened, falling back to PNG for a source whose extension is not
one anything can write back -- a HEIC on a machine without an HEVC encoder is
the ordinary case, and L<GlitchVape::IO> would have to route around it.

=cut

sub still_extension
{
    my ( $settings, $source ) = @_;

    my $chosen = _entry( \@STILL_FORMATS, $settings->{ still_format } );

    return $chosen->{ ext } if $chosen->{ ext };

    my ( undef, undef, $ext ) = fileparse( lc( $source // q{} ), qr/[.][^.]*/ );
    $ext =~ s/^[.]//;

    return 'png' unless length $ext;
    return $ext;
}

=head2 render_options( $settings, $animated )

The arguments L<GlitchVape/render> needs to honour these settings, as a list
suitable for splicing into its call. Which ones apply depends on what is being
written, so the caller says which it is.

=cut

sub render_options
{
    my ( $settings, $animated ) = @_;

    if ( $animated )
    {
        my %target = video_target( $settings );

        # A size of 0 is Native, which is the absence of a cap rather than a
        # cap of zero -- so it is left out entirely and the preset's own
        # max_dim stands.
        my @argv = ( codec => $target{ codec } );
        push @argv, max_dim => $settings->{ video_size }
            if $settings->{ video_size };

        return @argv;
    }

    my $chosen = _entry( \@STILL_FORMATS, $settings->{ still_format } );

    my @argv;
    push @argv, colors => $chosen->{ colors } if $chosen->{ colors };
    push @argv, fit    => RETRO_BOX           if $settings->{ retro };

    return @argv;
}

=head2 describe( $settings, $animated )

One line for the status bar.

=cut

sub describe
{
    my ( $settings, $animated ) = @_;

    if ( $animated )
    {
        my $chosen = _entry( \@VIDEO_FORMATS, $settings->{ video_format } );

        return sprintf '%s · %s · %d fps', $chosen->{ label },
            _size_label( $settings->{ video_size } ), $settings->{ fps };
    }

    my $chosen = _entry( \@STILL_FORMATS, $settings->{ still_format } );
    my $said   = $chosen->{ label };

    $said .= sprintf ' · fits %d×%d', @{ +RETRO_BOX } if $settings->{ retro };

    return $said;
}

=head2 retro_box()

The box C<retro> fits into, as C<< [ W, H ] >>.

=cut

sub retro_box { return RETRO_BOX }

=head2 sizes()

The resolution list, as C<< [ [ px, label ], ... ] >>. Exported for the tests
and for anything that needs to know what is on offer without building a combo.

=cut

sub sizes
{
    return [ map { [ @$_ ] } @SIZES ];
}

# ---------------------------------------------------------------------------

sub _entry
{
    my ( $list, $key ) = @_;

    for my $entry ( @$list )
    {
        return $entry if $entry->{ key } eq ( $key // q{} );
    }

    # A settings hash from somewhere unexpected should not take the export
    # down; the first entry is the default in every one of these lists.
    return $list->[ 0 ];
}

sub _index_of
{
    my ( $list, $key ) = @_;

    for my $n ( 0 .. $#$list )
    {
        return $n if $list->[ $n ]{ key } eq ( $key // q{} );
    }

    return 0;
}

sub _format_label { return $_[ 0 ]{ label } }

sub _size_label
{
    my ( $px ) = @_;

    for my $entry ( @SIZES )
    {
        return $entry->[ 1 ] if $entry->[ 0 ] == ( $px // 0 );
    }

    return "$px px";
}

sub _size_combo
{
    my ( $current ) = @_;

    my $combo = Gtk3::ComboBoxText->new;
    my $index = 0;

    for my $n ( 0 .. $#SIZES )
    {
        $combo->append_text( $SIZES[ $n ][ 1 ] );
        $index = $n if $SIZES[ $n ][ 0 ] == ( $current // 0 );
    }

    $combo->set_active( $index );

    return $combo;
}

sub _grid
{
    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 8 );
    $grid->set_column_spacing( 10 );
    $grid->set_border_width( 14 );

    return $grid;
}

sub _pair
{
    my ( $grid, $row, $text, $control ) = @_;

    my $label = Gtk3::Label->new( $text );
    $label->set_xalign( 0 );

    $control->set_hexpand( 1 );

    $grid->attach( $label,   0, $row, 1, 1 );
    $grid->attach( $control, 1, $row, 1, 1 );

    return $row + 1;
}

sub _note_label
{
    my $label = Gtk3::Label->new;
    $label->set_xalign( 0 );
    $label->set_line_wrap( 1 );
    $label->set_max_width_chars( 46 );
    $label->get_style_context->add_class( 'dim-label' );

    return $label;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Animate> for the codecs, L<GlitchVape::IO> for what C<fit> and
C<colors> do to a file, and L<GlitchVape::GUI> for the menu that opens this.

=cut
