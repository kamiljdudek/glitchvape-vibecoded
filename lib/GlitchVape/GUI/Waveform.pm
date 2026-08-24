package GlitchVape::GUI::Waveform;

use strict;
use warnings;

use Gtk3 ();

use GlitchVape::Audio   ();
use GlitchVape::Palette ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Waveform - a waveform with a draggable selection

=head1 DESCRIPTION

The crop control: one C<Gtk3::DrawingArea> showing the whole file, with a
selection that can be dragged by either end or moved as a block, and a
playhead that follows playback.

There is no zoom. The whole file is always across the width, because the
selection is also editable to a hundredth of a second in the spin buttons
beside it -- so the widget is for finding the section by eye, which it is good
at, and the numbers are for placing the edge exactly, which a 0.3-seconds-per-pixel
track is bad at. Adding a viewport would mean a scroll offset in every
coordinate conversion below, to replace something that is already handled.

=head2 Interaction

    press within 7 px of an edge   drag that edge
    press inside the selection     move the whole selection, keeping its length
    press anywhere else            start a new selection there and drag it out

=cut

# Drawn in the project's own palette, because it may as well be. Index 0 of
# 'vapor' is its deep purple; the rest carry the signal.
#
# A hash rather than five `use constant`s: the palette is read at run time and
# a constant is folded at compile time, so constants here would every one of
# them be undef.
my %COLOUR;

{
    my $vapor = GlitchVape::Palette::colors( 'vapor' );

    %COLOUR = (
        background => $vapor->[ 0 ],
        quiet      => $vapor->[ 1 ],    # waveform outside the selection
        edge       => $vapor->[ 2 ],    # the two handles
        loud       => $vapor->[ 3 ],    # waveform inside the selection
        playhead   => $vapor->[ 4 ],
    );
}

# How near an edge a press has to be to grab it rather than to start
# something else. Seven pixels is about a finger's worth of aim at a mouse.
use constant GRAB_PX => 7;

# Room under the waveform for the time ruler.
use constant RULER_H => 16;

=head2 new( %arg )

    on_change => sub { my ( $start, $end ) = @_ }
    on_scrub  => sub { my ( $seconds ) = @_ }

C<on_scrub> fires when the user drags an edge, so the wizard can move playback
to follow it. C<< ->widget >> is what the caller packs.

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $self = bless {
        area      => Gtk3::DrawingArea->new,
        peaks     => [],
        duration  => 0,
        start     => 0,
        end       => 0,
        playhead  => undef,
        drag      => undef,
        on_change => $arg{ on_change },
        on_scrub  => $arg{ on_scrub },
    }, $class;

    my $area = $self->{ area };
    $area->set_size_request( -1, 150 );
    $area->set_hexpand( 1 );
    $area->set_vexpand( 1 );

    $area->add_events(
        [
            qw(button-press-mask button-release-mask pointer-motion-mask
                leave-notify-mask)
        ]
    );

    $area->signal_connect( draw => sub { return $self->_draw( $_[ 1 ] ) } );

    $area->signal_connect(
        'button-press-event' => sub { return $self->_press( $_[ 1 ] ) } );
    $area->signal_connect(
        'button-release-event' => sub { return $self->_release( $_[ 1 ] ) } );
    $area->signal_connect(
        'motion-notify-event' => sub { return $self->_motion( $_[ 1 ] ) } );

    return $self;
}

sub widget { $_[ 0 ]{ area } }

=head2 set_source( $peaks, $duration )

Adopt a decoded file: the peak list from L<GlitchVape::Audio/peaks> and the
length it covers. Resets the selection to the whole file.

=cut

sub set_source
{
    my ( $self, $peaks, $duration ) = @_;

    $self->{ peaks }    = $peaks    || [];
    $self->{ duration } = $duration || 0;
    $self->{ start }    = 0;
    $self->{ end }      = $self->{ duration };
    $self->{ playhead } = undef;

    $self->{ area }->queue_draw;
    $self->_changed;

    return;
}

=head2 selection()

C<< ( start, end ) >> in seconds.

=cut

sub selection { return ( $_[ 0 ]{ start }, $_[ 0 ]{ end } ) }

=head2 set_selection( $start, $end )

Move the selection from outside -- what the spin buttons call. Does not fire
C<on_change>, so that the widget and the spins cannot drive each other in a
loop; the caller already knows what it just set.

=cut

sub set_selection
{
    my ( $self, $start, $end ) = @_;

    ( $self->{ start }, $self->{ end } ) = $self->_clamp( $start, $end );
    $self->{ area }->queue_draw;

    return;
}

=head2 set_playhead( $seconds )

Where playback has reached, or undef to remove it.

=cut

sub set_playhead
{
    my ( $self, $seconds ) = @_;

    $self->{ playhead } = $seconds;
    $self->{ area }->queue_draw;

    return;
}

# ---------------------------------------------------------------------------
# Coordinates

sub _width { return $_[ 0 ]{ area }->get_allocated_width }

sub _wave_height
{
    my ( $self ) = @_;

    my $h = $self->{ area }->get_allocated_height - RULER_H;
    return 1 if $h < 1;

    return $h;
}

sub _time_at
{
    my ( $self, $x ) = @_;

    my $width = $self->_width;
    return 0 unless $width > 0 && $self->{ duration } > 0;

    my $seconds = $x * $self->{ duration } / $width;

    $seconds = 0                   if $seconds < 0;
    $seconds = $self->{ duration } if $seconds > $self->{ duration };

    return $seconds;
}

sub _x_at
{
    my ( $self, $seconds ) = @_;

    return 0 unless $self->{ duration } > 0;

    return ( $seconds || 0 ) * $self->_width / $self->{ duration };
}

# Keep a selection inside the file, in order, and non-empty. A zero-length
# selection would render as an invisible line the user then cannot grab.
sub _clamp
{
    my ( $self, $start, $end ) = @_;

    my $duration = $self->{ duration };

    $start = 0         unless defined $start;
    $end   = $duration unless defined $end;

    ( $start, $end ) = ( $end, $start ) if $start > $end;

    $start = 0         if $start < 0;
    $end   = $duration if $end > $duration;

    my $shortest = 0.05;
    if ( $end - $start < $shortest )
    {
        $end = $start + $shortest;
        if ( $end > $duration )
        {
            $end   = $duration;
            $start = $end - $shortest;
            $start = 0 if $start < 0;
        }
    }

    return ( $start, $end );
}

sub _changed
{
    my ( $self ) = @_;

    $self->{ on_change }->( $self->{ start }, $self->{ end } )
        if $self->{ on_change };

    return;
}

# ---------------------------------------------------------------------------
# Events

sub _press
{
    my ( $self, $event ) = @_;

    return 0 unless $self->{ duration } > 0;

    my $x     = $event->x;
    my $start = $self->_x_at( $self->{ start } );
    my $end   = $self->_x_at( $self->{ end } );

    if ( abs( $x - $start ) <= GRAB_PX )
    {
        $self->{ drag } = { mode => 'start' };
    }
    elsif ( abs( $x - $end ) <= GRAB_PX )
    {
        $self->{ drag } = { mode => 'end' };
    }
    elsif ( $x > $start && $x < $end )
    {
        $self->{ drag } = {
            mode   => 'move',
            offset => $self->_time_at( $x ) - $self->{ start },
            length => $self->{ end } - $self->{ start },
        };
    }
    else
    {
        # A press on empty ground starts a new selection rather than jumping
        # the nearest edge across the file, which is what a nearest-edge rule
        # does and always feels like a misclick.
        my $at = $self->_time_at( $x );
        $self->{ start } = $at;
        $self->{ end }   = $at;
        $self->{ drag }  = { mode => 'end' };
    }

    $self->_motion( $event );

    return 1;
}

sub _motion
{
    my ( $self, $event ) = @_;

    my $drag = $self->{ drag };

    unless ( $drag )
    {
        $self->_update_cursor( $event->x );
        return 0;
    }

    my $at = $self->_time_at( $event->x );

    if ( $drag->{ mode } eq 'start' )
    {
        ( $self->{ start }, $self->{ end } ) =
            $self->_clamp( $at, $self->{ end } );
        $self->_scrub( $self->{ start } );
    }
    elsif ( $drag->{ mode } eq 'end' )
    {
        ( $self->{ start }, $self->{ end } ) =
            $self->_clamp( $self->{ start }, $at );
        $self->_scrub( $self->{ end } );
    }
    else
    {
        my $start = $at - $drag->{ offset };
        $start = 0 if $start < 0;

        my $end = $start + $drag->{ length };
        if ( $end > $self->{ duration } )
        {
            $end   = $self->{ duration };
            $start = $end - $drag->{ length };
            $start = 0 if $start < 0;
        }

        ( $self->{ start }, $self->{ end } ) = $self->_clamp( $start, $end );
    }

    $self->{ area }->queue_draw;
    $self->_changed;

    return 1;
}

sub _release
{
    my ( $self ) = @_;

    $self->{ drag } = undef;
    return 1;
}

# An edge that can be grabbed should say so before it is grabbed.
sub _update_cursor
{
    my ( $self, $x ) = @_;

    my $window = $self->{ area }->get_window or return;

    my $name = 'left_ptr';
    if ( $self->{ duration } > 0 )
    {
        my $start = $self->_x_at( $self->{ start } );
        my $end   = $self->_x_at( $self->{ end } );

        if ( abs( $x - $start ) <= GRAB_PX || abs( $x - $end ) <= GRAB_PX )
        {
            $name = 'sb_h_double_arrow';
        }
    }

    return if ( $self->{ cursor } || q{} ) eq $name;
    $self->{ cursor } = $name;

    local $@;
    eval {
        $window->set_cursor( Gtk3::Gdk::Cursor->new( $name ) );
        1;
    };

    return;
}

sub _scrub
{
    my ( $self, $seconds ) = @_;

    $self->{ on_scrub }->( $seconds ) if $self->{ on_scrub };
    return;
}

# ---------------------------------------------------------------------------
# Drawing

sub _draw
{
    my ( $self, $cr ) = @_;

    my $width  = $self->_width;
    my $height = $self->_wave_height;

    _set_colour( $cr, $COLOUR{ background }, 1 );
    $cr->paint;

    unless ( @{ $self->{ peaks } } && $self->{ duration } > 0 )
    {
        _set_colour( $cr, $COLOUR{ quiet }, 0.7 );
        $cr->select_font_face( 'Sans', 'normal', 'normal' );
        $cr->set_font_size( 13 );
        $cr->move_to( 12, $height / 2 );
        $cr->show_text( 'Reading the file…' );
        return 0;
    }

    my $from = $self->_x_at( $self->{ start } );
    my $to   = $self->_x_at( $self->{ end } );

    $self->_draw_wave( $cr, $width, $height, $from, $to );
    $self->_draw_selection( $cr, $height, $from, $to );
    $self->_draw_ruler( $cr, $width, $height );
    $self->_draw_playhead( $cr, $height );

    return 0;
}

# One vertical bar per pixel column, mirrored about the centre. The peak for a
# column is the loudest of every bucket that falls in it, so a transient stays
# visible however much the file is squeezed into the width -- averaging here
# is what turns a waveform into a grey sausage.
sub _draw_wave
{
    my ( $self, $cr, $width, $height, $from, $to ) = @_;

    my $peaks  = $self->{ peaks };
    my $count  = scalar @$peaks;
    my $middle = $height / 2;

    $cr->set_line_width( 1 );

    for my $x ( 0 .. $width - 1 )
    {
        my $lo = int( $x * $count / $width );
        my $hi = int( ( $x + 1 ) * $count / $width ) - 1;
        $hi = $lo        if $hi < $lo;
        $hi = $count - 1 if $hi > $count - 1;

        my $peak = 0;
        for my $i ( $lo .. $hi )
        {
            $peak = $peaks->[ $i ] if $peaks->[ $i ] > $peak;
        }

        my $tall = $peak * ( $middle - 4 );
        $tall = 0.5 if $tall < 0.5;

        if ( $x >= $from && $x <= $to )
        {
            _set_colour( $cr, $COLOUR{ loud }, 0.95 );
        }
        else
        {
            _set_colour( $cr, $COLOUR{ quiet }, 0.35 );
        }

        # Half-pixel offsets, or a one-pixel line straddles two columns and
        # the whole waveform comes out blurred.
        $cr->move_to( $x + 0.5, $middle - $tall );
        $cr->line_to( $x + 0.5, $middle + $tall );
        $cr->stroke;
    }

    return;
}

sub _draw_selection
{
    my ( $self, $cr, $height, $from, $to ) = @_;

    _set_colour( $cr, $COLOUR{ loud }, 0.10 );
    $cr->rectangle( $from, 0, $to - $from, $height );
    $cr->fill;

    _set_colour( $cr, $COLOUR{ edge }, 1 );
    $cr->set_line_width( 2 );

    for my $x ( $from, $to )
    {
        $cr->move_to( $x, 0 );
        $cr->line_to( $x, $height );
        $cr->stroke;

        # A grip at the top of each edge, so the thing to aim at is a shape
        # rather than a two-pixel line.
        $cr->rectangle( $x - 3, 0, 6, 12 );
        $cr->fill;
    }

    return;
}

sub _draw_playhead
{
    my ( $self, $cr, $height ) = @_;

    my $at = $self->{ playhead };
    return unless defined $at;

    my $x = $self->_x_at( $at );

    _set_colour( $cr, $COLOUR{ playhead }, 0.9 );
    $cr->set_line_width( 1.5 );
    $cr->move_to( $x, 0 );
    $cr->line_to( $x, $height );
    $cr->stroke;

    return;
}

# Ticks at a spacing chosen so there are never more than about a dozen: a
# fixed interval is unreadable on a four-minute file and pointless on a
# four-second one.
sub _draw_ruler
{
    my ( $self, $cr, $width, $height ) = @_;

    my $step = _tick_step( $self->{ duration } );

    _set_colour( $cr, $COLOUR{ quiet }, 0.75 );
    $cr->select_font_face( 'Sans', 'normal', 'normal' );
    $cr->set_font_size( 10 );
    $cr->set_line_width( 1 );

    for ( my $t = 0 ; $t <= $self->{ duration } ; $t += $step )
    {
        my $x = $self->_x_at( $t );

        $cr->move_to( $x + 0.5, $height );
        $cr->line_to( $x + 0.5, $height + 4 );
        $cr->stroke;

        # The last label would be clipped by the right edge of the widget.
        next if $x > $width - 30;

        # Whole seconds, not the tenths GlitchVape::Audio::format_time gives:
        # every tick is at an integer here, so the decimal is a column of
        # zeroes cluttering a strip that is 16 pixels tall.
        $cr->move_to( $x + 3, $height + RULER_H - 3 );
        $cr->show_text( sprintf '%d:%02d', int( $t / 60 ), $t % 60 );
    }

    return;
}

sub _tick_step
{
    my ( $duration ) = @_;

    for my $step ( 1, 2, 5, 10, 15, 30, 60, 120, 300 )
    {
        return $step if $duration / $step <= 12;
    }

    return 600;
}

sub _set_colour
{
    my ( $cr, $hex, $alpha ) = @_;

    my @channel = $hex =~ /^#(..)(..)(..)$/;

    $cr->set_source_rgba(
        hex( $channel[ 0 ] ) / 255,
        hex( $channel[ 1 ] ) / 255,
        hex( $channel[ 2 ] ) / 255, $alpha
    );

    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Audio>, the wizard this is the first page of.

=cut
