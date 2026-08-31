package GlitchVape::GUI::Preview;

use strict;
use warnings;

use Gtk3            ();
use Gtk3::ImageView ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Preview - the preview pane, still and animated

=head1 DESCRIPTION

Two ways of showing a render, in a C<Gtk3::Stack>:

=over 4

=item Still

A C<Gtk3::ImageView>, which brings zoom and pan with it. Inspecting a glitch
at 1:1 is most of what the preview is for -- C<chroma_bleed> and C<dither> are
invisible fitted to a pane.

Scaled nearest-neighbour rather than smoothly. See
L</WHY THE PREVIEW DOES NOT INTERPOLATE>.

=item Animated

GStreamer, playing the encoded loop through C<gtksink> into a widget in the
same stack. This is the only thing GStreamer is used for: a still goes through
GdkPixbuf, which does not need a pipeline.

=back

GStreamer is loaded on first use rather than at startup, so a machine without
it -- or without the H.264 decoder the loop needs -- runs the still interface
normally and only reports a problem if the user asks for an animation.

=head1 WHY THE PREVIEW DOES NOT INTERPOLATE

C<Gtk3::ImageView> scales with Cairo's C<good> filter unless told otherwise,
and for a photograph that is the right answer. For this program it is not.

Almost everything here is an artefact one pixel across: the gap between two
scanlines, the checker of a dither, a grain, a halftone cell, the one-pixel
white highlight that is the only thing making a bevel look raised. Smoothed
into a pane at eighty per cent, every one of those becomes a soft grey
suggestion of itself -- and the preview stops being a smaller version of the
export and becomes a different picture, which is exactly the claim
L<GlitchVape::GUI::Render> makes it must not break.

It shows worst on C<chicago>, whose whole subject is hard edges: at anything
but 1:1 the caption goes fuzzy and the window reads as a photograph of a
screen rather than as a screen. But it was never only that effect, and
C<nearest> is the honest filter for all of them. Enlarged it gives square
pixels, which is what the artefact is; reduced it drops pixels rather than
averaging them, which is the same lie a smaller screen tells.

=cut

my $GST_READY;
my $GST_ERROR;

=head2 new()

Returns the pane. C<< ->widget >> is what the caller packs.

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $self = bless {
        stack    => Gtk3::Stack->new,
        view     => Gtk3::ImageView->new,
        pipeline => undef,
        sink     => undef,
        muted    => 0,
        on_error => $arg{ on_error },
    }, $class;

    # Nearest rather than Cairo's default: see above.
    $self->{ view }->set_interpolation( 'nearest' );

    $self->{ stack }->set_transition_type( 'crossfade' );
    $self->{ stack }->set_transition_duration( 120 );

    $self->{ stack }->add_named( $self->_placeholder, 'empty' );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->add( $self->{ view } );
    $self->{ stack }->add_named( $scroll, 'still' );

    $self->{ stack }->set_visible_child_name( 'empty' );

    return $self;
}

sub widget { $_[ 0 ]{ stack } }
sub view   { $_[ 0 ]{ view } }

=head2 show_still( $path )

Display a rendered PNG. Returns true, or false with the reason passed to the
error callback -- a truncated cache entry should make the caller re-render,
not take the window down.

=cut

sub show_still
{
    my ( $self, $path ) = @_;

    $self->stop_video;

    my $pixbuf = eval { Gtk3::Gdk::Pixbuf->new_from_file( $path ) };

    if ( !$pixbuf )
    {
        my $err = $@ || 'could not be decoded';
        $err =~ s/\s+\z//;
        $self->{ on_error }->( "preview image $path $err" )
            if $self->{ on_error };
        return 0;
    }

    $self->{ view }->set_pixbuf( $pixbuf, 1 );
    $self->{ stack }->set_visible_child_name( 'still' );

    return 1;
}

=head2 show_video( $path )

Play an encoded loop. Returns true if playback started.

=cut

sub show_video
{
    my ( $self, $path ) = @_;

    unless ( _gst_ready() )
    {
        $self->{ on_error }->( $GST_ERROR ) if $self->{ on_error };
        return 0;
    }

    $self->stop_video;

    my $sink = Gst::ElementFactory::make( 'gtksink', 'gv-sink' );

    unless ( $sink )
    {
        $self->{ on_error }->(
            "GStreamer has no 'gtksink' element, so the animation cannot be\n"
                . "shown in the window. Install it with:\n"
                . '  sudo apt install gstreamer1.0-gtk3' )
            if $self->{ on_error };
        return 0;
    }

    my $play = Gst::ElementFactory::make( 'playbin', 'gv-play' );

    unless ( $play )
    {
        $self->{ on_error }->( 'GStreamer has no playbin element' )
            if $self->{ on_error };
        return 0;
    }

    $play->set_property( 'video-sink', $sink );
    $play->set_property( 'uri',        _file_uri( $path ) );

    # Set before the pipeline starts, so a loop opened while muted does not
    # get to make a noise on its first frame.
    $play->set_property( 'mute', $self->{ muted } );

    # gtksink hands back the widget it draws into, which is what puts the
    # video inside the pane rather than in a window of its own.
    my $widget = $sink->get_property( 'widget' );

    if ( my $old = $self->{ sink_widget } )
    {
        $self->{ stack }->remove( $old );
    }

    $widget->show;
    $self->{ stack }->add_named( $widget, 'video' );
    $self->{ sink_widget } = $widget;

    my $bus = $play->get_bus;
    $bus->add_signal_watch;

    # A rendered loop is a couple of seconds long, so it has to repeat to be
    # worth looking at. Seeking back on end-of-stream is the whole of it.
    $bus->signal_connect(
        'message::eos' => sub {
            $play->seek_simple( 'time', [ 'flush', 'key-unit' ], 0 );
            return 1;
        }
    );

    $bus->signal_connect(
        'message::error' => sub {
            my ( undef, $message ) = @_;
            my ( $err ) = $message->parse_error;
            $self->{ on_error }->( 'GStreamer: ' . $err->message )
                if $self->{ on_error };
            $self->stop_video;
            return 1;
        }
    );

    $play->set_state( 'playing' );

    $self->{ pipeline } = $play;
    $self->{ stack }->set_visible_child_name( 'video' );

    return 1;
}

=head2 set_muted( $muted )

Silence the animated preview, or let it speak again. Takes effect at once on
whatever is playing, and is remembered for whatever plays next.

This is playbin's own C<mute>, not a volume of zero: it stops the audio being
decoded rather than decoding it and throwing it away, and it cannot drift back
in through a seek. The render is untouched -- the loop on disk still has its
soundtrack, and so does the export.

=cut

sub set_muted
{
    my ( $self, $muted ) = @_;

    $self->{ muted } = 0;
    $self->{ muted } = 1 if $muted;

    my $play = $self->{ pipeline } or return $self->{ muted };

    $play->set_property( 'mute', $self->{ muted } );

    return $self->{ muted };
}

=head2 muted()

Whether it is.

=cut

sub muted { return $_[ 0 ]{ muted } }

=head2 stop_video()

Tear the pipeline down. Called before showing a still, and on shutdown --
leaving a playbin in the playing state holds the decoder and the audio device
open for as long as the process lives.

=cut

sub stop_video
{
    my ( $self ) = @_;

    my $play = $self->{ pipeline } or return 0;

    $play->set_state( 'null' );

    my $bus = $play->get_bus;
    $bus->remove_signal_watch if $bus;

    $self->{ pipeline } = undef;

    return 1;
}

=head2 clear()

Return to the placeholder, as when a new file is opened.

=cut

sub clear
{
    my ( $self ) = @_;
    $self->stop_video;
    $self->{ stack }->set_visible_child_name( 'empty' );
    return;
}

=head2 zoom_in() / zoom_out() / zoom_fit() / zoom_actual()

Preview zoom. C<zoom_actual> is 1:1, which is the one that matters: half the
effects here are single-pixel wide and a fitted view simply does not show
them.

=cut

sub zoom_in
{
    my ( $self ) = @_;
    $self->{ view }->set_zoom_to_fit( 0 );
    $self->{ view }->zoom_in;
    return;
}

sub zoom_out
{
    my ( $self ) = @_;
    $self->{ view }->set_zoom_to_fit( 0 );
    $self->{ view }->zoom_out;
    return;
}

sub zoom_fit
{
    my ( $self ) = @_;
    $self->{ view }->set_zoom_to_fit( 1 );
    return;
}

sub zoom_actual
{
    my ( $self ) = @_;
    $self->{ view }->set_zoom_to_fit( 0 );
    $self->{ view }->set_zoom( 1 );
    return;
}

=head2 gst_available()

Whether an animated preview can be shown, without attempting one.

=cut

sub gst_available { return _gst_ready() }

=head2 gst_error()

Why it cannot, when it cannot.

=cut

sub gst_error { return $GST_ERROR }

# ---------------------------------------------------------------------------

# GStreamer is reached through gobject-introspection: Debian has no Perl
# binding for it, and the typelib is a complete interface to the same library.
sub _gst_ready
{
    return $GST_READY if defined $GST_READY;

    local $@;
    my $ok = eval {
        require Glib::Object::Introspection;
        Glib::Object::Introspection->setup(
            basename => 'Gst',
            version  => '1.0',
            package  => 'Gst',
        );
        Gst::init( [] );
        1;
    };

    if ( $ok )
    {
        $GST_READY = 1;
        return 1;
    }

    my $err = $@ || 'unknown error';
    $err =~ s/\s+\z//;

    $GST_ERROR =
          "GStreamer is not available, so animated previews cannot be shown.\n"
        . "Install it with:\n"
        . "  sudo apt install gir1.2-gstreamer-1.0 gstreamer1.0-plugins-good \\\n"
        . "                   gstreamer1.0-gtk3 gstreamer1.0-libav\n"
        . "($err)";

    $GST_READY = 0;
    return 0;
}

sub _placeholder
{
    my ( $self ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 8 );
    $box->set_valign( 'center' );
    $box->set_halign( 'center' );

    my $icon = Gtk3::Image->new_from_icon_name( 'image-x-generic', 'dialog' );
    $icon->set_opacity( 0.4 );

    my $label = Gtk3::Label->new;
    $label->set_markup( "<span size='large'>No preview yet</span>\n"
            . "<span alpha='60%'>Open an image, add some effects, "
            . 'and press Apply</span>' );
    $label->set_justify( 'center' );

    $box->pack_start( $icon,  0, 0, 0 );
    $box->pack_start( $label, 0, 0, 0 );

    return $box;
}

sub _file_uri
{
    my ( $path ) = @_;

    require File::Spec;
    my $abs = File::Spec->rel2abs( $path );

    # Percent-encode everything outside the unreserved set, or a rendered
    # filename containing a space or a '#' silently fails to open.
    $abs =~ s{([^A-Za-z0-9\-_.~/])}{ sprintf '%%%02X', ord $1 }ge;

    return "file://$abs";
}

sub DESTROY
{
    my ( $self ) = @_;
    local $@;
    eval { $self->stop_video; 1 };
    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Render>, which produces what this displays.

=cut
