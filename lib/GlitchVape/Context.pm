package GlitchVape::Context;

use strict;
use warnings;

use File::Spec ();
use File::Temp ();

use GlitchVape::Magick ();
use GlitchVape::Random ();
use GlitchVape::Tools  ();

our $VERSION = '0.01';

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
