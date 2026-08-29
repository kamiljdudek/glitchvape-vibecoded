package GlitchVape::Context;

use strict;
use warnings;

use File::Spec ();
use File::Temp ();

use GlitchVape::Magick ();
use GlitchVape::Random ();
use GlitchVape::Tools  ();

our $VERSION = '0.01';

use constant PI => 4 * atan2( 1, 1 );

=head1 NAME

GlitchVape::Context - per-render state shared by every effect

=head1 DESCRIPTION

Holds the working image, the seeded RNG, a scratch directory and the log
sink. Effects receive one of these and mutate C<< $ctx->image >> in place.

=head2 Frames

When rendering an animation the same context is reused across frames with
C<frame>/C<frames> updated. Effects that want per-frame variation read
C<< $ctx->phase >> (0..1 around the loop) rather than re-randomising, so a
loop actually cycles instead of flickering.

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $self = bless {
        image  => $arg{ image },
        source => $arg{ source },
        rng => $arg{ rng } || GlitchVape::Random->new( seed => $arg{ seed } ),
        verbose => $arg{ verbose } || 0,
        frame   => 0,
        frames  => 1,
        tmpdir  => undef,
        _rngs   => {},
        _timing => [],
    }, $class;

    return $self;
}

# Read-only accessors.
sub source  { $_[ 0 ]{ source } }
sub rng     { $_[ 0 ]{ rng } }
sub verbose { $_[ 0 ]{ verbose } }

# Read/write accessors. Called with an argument they set and return the new
# value; called bare they read. Written out rather than generated so that the
# get and set paths are both visible.
sub image
{
    my ( $self, $value ) = @_;

    if ( @_ > 1 )
    {
        $self->{ image } = $value;
    }

    return $self->{ image };
}

sub frame
{
    my ( $self, $value ) = @_;

    if ( @_ > 1 )
    {
        $self->{ frame } = $value;
    }

    return $self->{ frame };
}

sub frames
{
    my ( $self, $value ) = @_;

    if ( @_ > 1 )
    {
        $self->{ frames } = $value;
    }

    return $self->{ frames };
}

=head2 phase()

Position around the animation loop as a float in C<[0,1)>. Always 0 for a
still. Effects should drive periodic motion from this so the last frame joins
back onto the first.

=cut

sub phase
{
    my $self = shift;
    return 0 if $self->{ frames } <= 1;
    return $self->{ frame } / $self->{ frames };
}

=head2 travel( $distance, $repeat )

How far a repeating pattern has moved by this frame, for an effect with a
C<drift> parameter. C<$distance> is what the user asked for over one whole
loop and C<$repeat> is the period of the thing being moved -- a line spacing,
a tile, two rows of a field. Returns 0 for a still.

The distance is snapped to a whole number of repeats first, because a loop has
to close: travel two and a half line spacings and the last frame does not join
the first, which shows as a jolt once per loop for as long as the video plays.
Snapping is silent and deliberate. The alternative is refusing the value, and
nobody setting C<drift> wants an error about the least interesting digit in it.

It never snaps to zero. Rounding 1 down to 0 when the repeat is 6 would turn a
drift somebody asked for into an effect that does nothing, which reads as a
broken parameter rather than as a rounded one.

=cut

sub travel
{
    my ( $self, $distance, $repeat ) = @_;

    return 0 unless $distance && $self->{ frames } > 1;

    $repeat = abs( $repeat || 1 );

    my $steps = int( abs( $distance ) / $repeat + 0.5 ) || 1;
    my $total = $steps * $repeat;
    $total = -$total if $distance < 0;

    return $total * $self->phase;
}

=head2 excursion( $amount )

How far a B<non>-repeating feature has moved by this frame -- the one bright
band of a reflection, the delay of an echo. Returns 0 for a still.

These have nowhere to travel to. A single band swept off one edge has to
reappear at the other, and that jump is visible in a way a repeating pattern's
is not, because there is no second band to disguise it. So this rocks: out to
C<$amount> and back over the loop, which closes at any value and is anyway
what the physical thing does. A window reflection moves because the room does,
and rooms do not scroll.

=cut

sub excursion
{
    my ( $self, $amount ) = @_;

    return 0 unless $amount && $self->{ frames } > 1;

    return $amount * sin( 2 * PI() * $self->phase );
}

=head2 rng_for( $effect_name )

A dedicated RNG stream for one effect, derived from the master seed. Effects
must use this rather than the shared stream: it means enabling an effect does
not shift the random sequence of every effect after it, so tweaking one knob
in a preset leaves the rest of the render alone.

For animations the frame index is folded in, so successive frames differ but
the whole sequence is still reproducible from the one seed.

=cut

sub rng_for
{
    my ( $self, $name ) = @_;

    # For a still there is one stream per effect. For an animation the frame
    # index is folded into the key as well, so each frame gets its own noise
    # while the whole sequence stays reproducible from the one seed.
    my $key = $name;
    if ( $self->{ frames } > 1 )
    {
        $key = "$name#$self->{frame}";
    }

    return $self->{ _rngs }{ $key } ||= $self->{ rng }->derive( $key );
}

=head2 rng_fixed( $name )

Like C<rng_for>, but the same stream on every frame of a loop.

C<rng_for> folds the frame index in, which is what makes static flicker and
grain move. Some choices are not that kind of random: which phrase a text
effect draws is decided once about the picture, and re-rolling it per frame
gives a caption that changes twenty-four times a second. This is for those --
still derived from the seed, so still reproducible, and still its own stream so
that using it does not disturb anybody else's.

=cut

sub rng_fixed
{
    my ( $self, $name ) = @_;

    # Cached apart from rng_for's stream but derived from the same label, so
    # that on a still the two are the same numbers. Otherwise moving an effect
    # onto this would change what a still renders -- a different fake date on
    # the camcorder display, say -- for no reason anybody could see.
    return $self->{ _rngs }{ "fixed:$name" } ||=
        $self->{ rng }->derive( $name );
}

=head2 dims()

C<< ($width, $height) >> of the working image.

=cut

sub dims
{
    my $self = shift;
    return $self->{ image }->Get( 'width', 'height' );
}

sub width  { ( $_[ 0 ]->dims )[ 0 ] }
sub height { ( $_[ 0 ]->dims )[ 1 ] }

=head2 clone()

A detached copy of the working image, for effects that need to composite the
original back over a modified version (bloom, ghosting).

=cut

sub clone
{
    my $self = shift;
    my $copy = $self->{ image }->Clone;
    return $copy;
}

=head2 tmpdir()

A scratch directory that lives as long as the context. Cleaned up on
destruction.

=cut

sub tmpdir
{
    my $self = shift;
    $self->{ tmpdir } ||=
        File::Temp->newdir( 'glitchvape_XXXXXX', TMPDIR => 1 );
    return "$self->{tmpdir}";
}

=head2 tmpfile( $suffix )

Path to a not-yet-existing file inside L</tmpdir>.

=cut

sub tmpfile
{
    my ( $self, $suffix ) = @_;
    $suffix ||= '.png';
    $self->{ _seq }++;
    return File::Spec->catfile( $self->tmpdir,
        sprintf( 'step%03d%s', $self->{ _seq }, $suffix ) );
}

=head2 log( $fmt, @args )

Verbose diagnostics to STDERR. Silent unless C<--verbose>.

=cut

sub log
{
    my ( $self, $fmt, @args ) = @_;
    return unless $self->{ verbose };

    # Called either as log('literal') or as log('%s', $value); only run the
    # format through sprintf when there is something to interpolate, so a
    # literal containing a stray % is not misread as a directive.
    my $msg = $fmt;
    if ( @args )
    {
        $msg = sprintf $fmt, @args;
    }

    # Frame-numbered prefix during an animation, so interleaved output from
    # successive frames stays attributable.
    my $prefix = q{};
    if ( $self->{ frames } > 1 )
    {
        $prefix = sprintf '[%03d] ', $self->{ frame };
    }

    warn "  $prefix$msg\n";
    return;
}

=head2 magick( @args )

Run the ImageMagick CLI on the working image: writes it to a temp file,
appends that as the input operand, runs C<@args>, reads the result back.

Most effects use PerlMagick directly. This exists for the handful of
operations whose CLI form is dramatically clearer than the binding's -- the
C<-fx> expression compiler and multi-image C<-layers> composites in
particular.

=cut

sub magick
{
    my ( $self, @args ) = @_;

    my $in  = $self->tmpfile( '.png' );
    my $out = $self->tmpfile( '.png' );

    GlitchVape::Magick::check( $self->{ image }->Write( $in ),
        'staging write failed' );

    my @argv = GlitchVape::Tools::magick_argv( $in, @args, $out );
    my $rc   = system( @argv );

    die "GlitchVape: ImageMagick failed (exit "
        . ( $rc >> 8 )
        . "):\n  "
        . join( ' ', @argv ) . "\n"
        unless $rc == 0 && -s $out;

    require Image::Magick;
    my $new = Image::Magick->new;
    GlitchVape::Magick::check( $new->Read( $out ),
        'could not read back the ImageMagick result' );

    $self->{ image } = $new;
    return $new;
}

=head2 pixels( $callback )

Direct pixel access, delegated to L<GlitchVape::Pixels>:

    $ctx->pixels(sub {
        my ($px) = @_;
        $px->set_row( 0, $px->row(1) );
    });

PerlMagick's own C<SetPixels> silently does nothing on ImageMagick 7, so this
is the only supported way to write pixels. See L<GlitchVape::Pixels> for why.
Values are 8-bit, 0..255.

=cut

sub pixels
{
    my ( $self, $cb ) = @_;
    require GlitchVape::Pixels;
    return GlitchVape::Pixels->edit( $self, $cb );
}

=head2 time_effect( $name, $code )

Run C<$code>, recording wall time against C<$name> for C<--timing>.

=cut

sub time_effect
{
    my ( $self, $name, $code ) = @_;
    my $t0 = time;
    my @r  = $code->();
    push @{ $self->{ _timing } }, [ $name, time - $t0 ];

    # Propagate the caller's context to the wrapped code's return value.
    if ( wantarray )
    {
        return @r;
    }

    return $r[ 0 ];
}

sub timings { @{ $_[ 0 ]{ _timing } } }

1;
