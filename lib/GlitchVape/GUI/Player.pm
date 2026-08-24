package GlitchVape::GUI::Player;

use strict;
use warnings;

use Glib ();
use Gtk3 ();

use GlitchVape::GUI::Preview ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Player - audition a stretch of an audio file

=head1 DESCRIPTION

The Play button behind both soundtrack wizards: play this file, from here to
there, and tell me where it has got to. Nothing on screen -- the caller owns
the button and whatever it draws with the position.

=head1 WHY IT IS PAUSED FIRST

A GStreamer pipeline cannot be seeked until it has prerolled, so a request to
start twelve seconds in cannot be honoured at the moment it is made. Setting
the pipeline playing and seeking as soon as it accepts one is the obvious
answer and the wrong one: the first fraction of a second of the wrong part of
the file is heard every time, which on a crop wizard is a click on every
press.

So the pipeline goes to B<paused>, and the position timer -- which has to
exist anyway to move the playhead -- watches for a duration query to succeed.
That is the first thing a prerolled pipeline can answer, and it means a seek
will now be accepted. The seek happens, and only then does the state go to
playing. Nothing is heard until it is the right thing.

=head1 NO VIDEO

C<playbin> is given a C<fakesink> for video. A soundtrack taken out of an MP4
would otherwise open a video window of its own beside the wizard.

=cut

# How often the position is polled. Fast enough for a playhead that does not
# visibly step, slow enough not to matter.
use constant TICK_MS => 60;

use constant NS_PER_SECOND => 1_000_000_000;

=head2 new( %arg )

    on_error    => sub { my ( $message ) = @_ }
    on_position => sub { my ( $seconds ) = @_ }
    on_state    => sub { my ( $playing ) = @_ }

C<on_state> fires with true when playback starts and false whenever it stops,
however it stopped -- the end of the range, the end of the stream, an error,
or L</stop>. Callers use it to put their button back.

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $self = bless {
        on_error    => $arg{ on_error },
        on_position => $arg{ on_position },
        on_state    => $arg{ on_state },
        pipeline    => undef,
        timer       => undef,
        seeking     => 0,
        from        => 0,
        to          => undef,
    }, $class;

    return $self;
}

=head2 playing()

Whether a pipeline is up. True from the moment L</play> is called, including
while it is still prerolling.

=cut

sub playing { return defined $_[ 0 ]{ pipeline } }

=head2 available() / error()

Whether GStreamer could be reached at all, and why not when it could not.
Delegated to L<GlitchVape::GUI::Preview>, which owns the one-time
introspection setup.

=cut

sub available { return GlitchVape::GUI::Preview::gst_available() }
sub error     { return GlitchVape::GUI::Preview::gst_error() }

=head2 play( %arg )

    path => file to play
    from => seconds to start at (default 0)
    to   => seconds to stop at, or undef for the end of the stream

Returns true if a pipeline was built. Any previous playback is stopped first.

=cut

sub play
{
    my ( $self, %arg ) = @_;

    unless ( available() )
    {
        $self->_report( error() );
        return 0;
    }

    $self->stop;

    my $play = Gst::ElementFactory::make( 'playbin', 'gv-player' );

    unless ( $play )
    {
        $self->_report( 'GStreamer has no playbin element' );
        return 0;
    }

    if ( my $fake = Gst::ElementFactory::make( 'fakesink', 'gv-novideo' ) )
    {
        $play->set_property( 'video-sink', $fake );
    }

    $play->set_property( 'uri', _file_uri( $arg{ path } ) );

    my $bus = $play->get_bus;
    $bus->add_signal_watch;

    $bus->signal_connect(
        'message::eos' => sub {
            $self->stop;
            return 1;
        }
    );

    $bus->signal_connect(
        'message::error' => sub {
            my ( undef, $message ) = @_;
            my ( $err ) = $message->parse_error;
            $self->_report( 'GStreamer: ' . $err->message );
            $self->stop;
            return 1;
        }
    );

    # Paused, not playing. See L</WHY IT IS PAUSED FIRST>.
    $play->set_state( 'paused' );

    $self->{ pipeline } = $play;
    $self->{ from }     = $arg{ from } || 0;
    $self->{ to }       = $arg{ to };
    $self->{ seeking }  = 1;

    $self->{ timer } =
        Glib::Timeout->add( TICK_MS, sub { return $self->_tick } );

    $self->{ on_state }->( 1 ) if $self->{ on_state };

    return 1;
}

=head2 seek( $seconds )

Move playback while it is running. Ignored when nothing is playing, and
ignored while the initial seek is still pending -- that one is about to happen
anyway and would only be undone.

=cut

sub seek
{
    my ( $self, $seconds ) = @_;

    my $play = $self->{ pipeline } or return 0;
    return 0 if $self->{ seeking };

    $self->_seek( $seconds );

    return 1;
}

=head2 stop()

Tear the pipeline down. Safe to call when nothing is playing.

Leaving a playbin in the playing state holds the decoder and the audio device
open for as long as the process lives, so this is what every exit path has to
reach.

=cut

sub stop
{
    my ( $self ) = @_;

    my $was = defined $self->{ pipeline };

    if ( my $timer = $self->{ timer } )
    {
        Glib::Source->remove( $timer );
        $self->{ timer } = undef;
    }

    if ( my $play = $self->{ pipeline } )
    {
        $play->set_state( 'null' );

        my $bus = $play->get_bus;
        $bus->remove_signal_watch if $bus;

        $self->{ pipeline } = undef;
    }

    $self->{ seeking } = 0;

    $self->{ on_state }->( 0 ) if $was && $self->{ on_state };

    return $was;
}

# ---------------------------------------------------------------------------

sub _tick
{
    my ( $self ) = @_;

    my $play = $self->{ pipeline } or return 0;

    if ( $self->{ seeking } )
    {
        # A duration is the first thing a prerolled pipeline can answer, and
        # answering it means a seek will now be accepted.
        my ( $ok ) = $play->query_duration( 'time' );
        return 1 unless $ok;

        $self->_seek( $self->{ from } );
        $play->set_state( 'playing' );
        $self->{ seeking } = 0;

        return 1;
    }

    my ( $ok, $position ) = $play->query_position( 'time' );
    return 1 unless $ok;

    my $seconds = $position / NS_PER_SECOND;

    $self->{ on_position }->( $seconds ) if $self->{ on_position };

    if ( defined $self->{ to } && $seconds >= $self->{ to } )
    {
        $self->stop;
        return 0;
    }

    return 1;
}

sub _seek
{
    my ( $self, $seconds ) = @_;

    my $play = $self->{ pipeline } or return;

    $play->seek_simple(
        'time',
        [ 'flush', 'accurate' ],
        int( ( $seconds || 0 ) * NS_PER_SECOND )
    );

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

sub _file_uri
{
    my ( $path ) = @_;

    require File::Spec;
    my $abs = File::Spec->rel2abs( $path );

    # Percent-encode everything outside the unreserved set, or a filename
    # containing a space or a '#' silently fails to open.
    $abs =~ s{([^A-Za-z0-9\-_.~/])}{ sprintf '%%%02X', ord $1 }ge;

    return "file://$abs";
}

sub DESTROY
{
    my ( $self ) = @_;
    local $@;
    eval { $self->stop; 1 };
    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Audio> and L<GlitchVape::GUI::Dtmf>, which both press it
into service behind a Play button.

=cut
