package GlitchVape::Context;

use strict;
use warnings;

use File::Spec  ();
use File::Temp  ();
use Time::HiRes ();

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

        # Given by the animation loop so that the frames share one, and left
        # undef by everything else: see L</cachedir()>.
        cachedir => $arg{ cachedir },
        _rngs    => {},
        _timing  => [],
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

=head2 swell( $amount )

The same rocking motion as C<excursion>, but one-sided: nought at the start of
the loop, C<$amount> half way round, nought again at the end. Returns 0 for a
still.

For a quantity that has no other direction to go in. How far two colours have
traded places is a fraction of a swap, and a swap of minus a third is not a
thing -- so what C<excursion> does after half way round, which is to do the
same again the other way, would have to be thrown away. It is a raised cosine
rather than the sine's absolute value because the extreme belongs in the
middle of the loop, where it is furthest from the seam, rather than twice at
the quarters.

=cut

sub swell
{
    my ( $self, $amount ) = @_;

    return 0 unless $amount && $self->{ frames } > 1;

    return $amount * ( 1 - cos( 2 * PI() * $self->phase ) ) / 2;
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

=head2 rng_phase( $name )

Like C<rng_for>, but keyed on where the frame sits around the loop rather than
on which frame it is, so that the frame after the last one is the first one
again.

The three streams are the three answers to "how random is this, frame to
frame", and an effect wants exactly one of them:

    rng_for     a fresh roll every frame, and no two loops line up
    rng_phase   a fresh roll every frame, and the loop closes
    rng_fixed   one roll, held for the whole render

C<rng_for> is right for noise -- grain, static, dropouts. Those never close
and are not meant to: film grain that repeated every twenty-four frames would
read as a texture stuck to the lens rather than as grain, and the seam is
invisible anyway because every frame is already unlike the one before it.

C<rng_phase> is for the things that jump about but are I<one thing> doing it:
a window shaking in place, a caption that will not sit still. There the seam
is invisible for the same reason -- one more jump among all the others -- but
the thing itself is recognisable from frame to frame, so a loop that came back
to a different position would be a jolt somebody could point at.

The two are the same stream on a still and the same stream on any frame of the
first pass; they differ only at the wrap, which is the whole point.

=cut

sub rng_phase
{
    my ( $self, $name ) = @_;

    return $self->rng_for( $name ) if $self->{ frames } <= 1;

    # The frame index modulo the loop, which is the frame's position around it
    # -- the same thing phase() returns, counted in frames rather than as a
    # fraction. In a real render this is the frame index and changes nothing;
    # it is what happens at frame == frames that this is for.
    my $at = $self->{ frame } % $self->{ frames };

    return $self->{ _rngs }{ "phase:$name#$at" } ||=
        $self->{ rng }->derive( "$name#$at" );
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

=head2 cachedir()

Where a file that depends only on the settings goes -- a screen, a tile, a
colour lookup table. The same directory for every frame of one animation,
which C<tmpdir> is not.

Every frame is rendered from its own context, so a cache kept in C<tmpdir>
lives exactly one frame: C<cmyk> was rebuilding four two-thousand-pixel
rotations per frame for screens it had already built, and the same went for
the scanline and grille tiles, the Bayer matrices and the palette lookups.
Eight frames of C<cmyk> cost eight times one frame rather than the one-and-a-
bit the module claimed.

Separate from C<tmpdir> rather than shared with it, because the per-frame
scratch files are numbered from one in each frame and sharing the directory
would have frame two writing over frame one's working files.

Falls back to C<tmpdir> when nobody handed one over, which is what a still
does: there is one frame, so the two are the same thing.

It can outlive the render as well as the frame. The window hands every
preview the same one for as long as it is open, which is what turns a second
Apply of C<cmyk> from four screens built into four screens read; and the
frames of a loop may be rendered by several processes at once, all writing
into it. So a file goes in through L</cached( $name, $build )>, which is what makes both
safe.

=cut

sub cachedir
{
    my ( $self ) = @_;

    return "$self->{cachedir}" if $self->{ cachedir };

    return $self->tmpdir;
}

=head2 cached( $name, $build )

The path of C<$name> in L</cachedir()>, built first if it is not there yet:

    my $path = $ctx->cached( "screen_${pitch}.png", sub {
        my ( $tmp ) = @_;
        system( magick_argv( ..., $tmp ) ) == 0 or die ...;
    } );

C<$build> is handed a path to write to rather than the real one, and the
result is renamed into place only once it is complete. That is the whole
point: the directory is shared -- between the frames of a loop rendered in
parallel, and in the window between one preview and the next, which may start
while a cancelled one is still writing -- and a file that exists under its
real name is then always a finished one. The same test on the real path
straight after building it, as every cache here used to do, would hand a
second process half a screen.

The temporary name keeps the real one's extension, since that is how
ImageMagick decides what to write. Two processes that both miss build the file
twice and the second rename wins, which costs time and nothing else.

=head2 cached_file( $path, $build )

The same, as a plain function over a full path, for the modules that are handed
a directory rather than a context.

=cut

sub cached
{
    my ( $self, $name, $build ) = @_;

    return cached_file( File::Spec->catfile( $self->cachedir, $name ), $build );
}

my $CACHED_SEQ = 0;

sub cached_file
{
    my ( $path, $build ) = @_;

    return $path if -s $path;

    my ( $vol, $dir, $file ) = File::Spec->splitpath( $path );
    $CACHED_SEQ++;
    my $tmp = File::Spec->catpath( $vol, $dir, ".$$-$CACHED_SEQ-$file" );

    local $@;
    my $ok  = eval { $build->( $tmp ); 1 };
    my $err = $@;

    unless ( $ok && -s $tmp && rename $tmp, $path )
    {
        unlink $tmp;
        die $err if !$ok;
        die "GlitchVape: could not build $path\n";
    }

    return $path;
}

=head2 tmpfile( $suffix )

Path to a not-yet-existing file inside C<tmpdir>.

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

=head3 Staged as MIFF, rounded to eight bits

The image crosses to the other process and back as MIFF, which is
ImageMagick's own format: the pixels as they are, and nothing to compress.
It used to cross as PNG, and at 1920 pixels the zlib at either end cost a
second a call -- more than most of the effects that make one, and a render
can make several.

Both ends are rounded to eight bits first, because that is what the PNG
staging did without saying so: an effect before this one may have left
sixteen-bit values behind (C<grade>'s Modulate does), and PNG wrote them at
the depth the image was labelled with, which is eight. Handing them across at
full depth instead moves most pixels of a render by a level or two -- nothing
anybody could see, and a different picture from the same seed all the same.
Rounded, the two stagings give the same pixels.

And an alpha channel with nothing in it is dropped at both ends, which is the
other thing PNG did unasked. C<osd> and C<text> leave the picture with one,
fully opaque; PNG wrote that as plain RGB, so no effect ever saw a fourth
channel from it -- and the ones that C<-separate> the picture count on there
being three, and recombine a mess when there are four. A channel that does
hold transparency is kept, as PNG kept it.

=cut

sub magick
{
    my ( $self, @args ) = @_;

    my $in  = $self->tmpfile( '.miff' );
    my $out = $self->tmpfile( '.miff' );

    $self->{ image }->Set( depth => 8 );
    _drop_opaque_alpha( $self->{ image } );

    GlitchVape::Magick::check( $self->{ image }->Write( $in ),
        'staging write failed' );

    my @argv =
        GlitchVape::Tools::magick_argv( $in, @args, '-depth', '8', $out );
    my $rc = system( @argv );

    die "GlitchVape: ImageMagick failed (exit "
        . ( $rc >> 8 )
        . "):\n  "
        . join( ' ', @argv ) . "\n"
        unless $rc == 0 && -s $out;

    require Image::Magick;
    my $new = Image::Magick->new;
    GlitchVape::Magick::check( $new->Read( $out ),
        'could not read back the ImageMagick result' );

    _drop_opaque_alpha( $new );

    $self->{ image } = $new;
    return $new;
}

sub _drop_opaque_alpha
{
    my ( $img ) = @_;

    return unless $img->Get( 'matte' );
    return unless ( $img->Get( '%[opaque]' ) // q{} ) eq 'True';

    $img->Set( alpha => 'off' );
    return;
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

With the clock's fractions of a second. Core C<time> counts whole seconds,
which made every effect under a second report C<0.00s> and the slow ones
report whatever the second boundary happened to fall across.

=cut

sub time_effect
{
    my ( $self, $name, $code ) = @_;
    my $t0 = Time::HiRes::time();
    my @r  = $code->();
    push @{ $self->{ _timing } }, [ $name, Time::HiRes::time() - $t0 ];

    # Propagate the caller's context to the wrapped code's return value.
    if ( wantarray )
    {
        return @r;
    }

    return $r[ 0 ];
}

sub timings { @{ $_[ 0 ]{ _timing } } }

1;
