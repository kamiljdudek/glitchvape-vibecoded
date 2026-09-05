package GlitchVape::Effect::Signal;

use strict;
use warnings;

use GlitchVape::Registry ();
use GlitchVape::Pixels   ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Effect::Signal - transport artefacts of tape and broadcast

=head1 DESCRIPTION

Damage that happens between the source and the screen: mistracked tape, head
switching, multipath ghosting, a vertical hold that will not lock. These are
all displacements of whole scanlines, because that is the unit an analogue
video signal is actually made of -- one line at a time, left to right.

Every effect here works on raw pixel rows rather than going through
ImageMagick, since the operation is "move this run of pixels sideways by n",
which has no clean equivalent in the CLI's vocabulary.

=cut

my $R  = 'GlitchVape::Registry';
my $PI = 3.14159265358979;

# ---------------------------------------------------------------------------

$R->register(
    name    => 'wave',
    title   => 'Tape Wobble',
    stage   => 'signal',
    summary => 'Sinusoidal horizontal wobble (tape stretch)',
    doc     => <<'DOC',
Displaces each scanline by a sine of its vertical position. Physically this is
a tape whose speed is oscillating slightly as it passes the head. Two waves at
different frequencies are summed, because a single clean sine reads as a
deliberate graphic effect rather than as a fault.

C<phase> and C<drift> are the two halves of the same fact and are easy to
confuse: C<phase> is where the wobble starts and does not move, C<drift> is how
many whole cycles it travels while the loop plays. C<drift> defaults to one,
which is the single cycle per loop this effect always did and had no way to
change. Set it to 0 to freeze the wobble mid-stretch -- still bent, no longer
crawling -- or higher to run it faster.
DOC
    params => {
        amplitude => {
            default => 4,
            type    => 'num',
            min     => 0,
            max     => 200,
            doc     => 'Maximum sideways displacement in pixels',
        },
        wavelength => {
            default => 90,
            type    => 'num',
            min     => 2,
            max     => 4000,
            doc     => 'Vertical period of the main wave in pixels',
        },
        harmonic => {
            default => 0.4,
            type    => 'num',
            min     => 0,
            max     => 2,
            doc     => 'Relative strength of a second, faster wave',
        },
        phase => {
            default => 0,
            type    => 'num',
            min     => -360,
            max     =>  360,
            doc     => 'Starting phase in degrees; does not move',
        },
        drift => {
            animation => 1,
            default   => 1,
            type      => 'num',
            min       => -16,
            max       =>  16,
            doc       => 'Whole cycles the wobble travels per loop',
        },
        edge => {
            default => 'wrap',
            type    => 'enum',
            values  => [ qw(wrap smear) ],
            doc => 'What fills the gap: wrap around, or smear the edge pixel',
        },
    },
    apply => \&_wave,
);

sub _wave
{
    my ( $ctx, $p ) = @_;
    return if $p->{ amplitude } <= 0;

    # A cycle is the repeat, so whole cycles are what bring the wobble back to
    # where the loop found it; travel() rounds to them and returns nothing at
    # all for a still.
    #
    # Only the fraction of a turn is kept. A sine does not care about the whole
    # ones, but the arithmetic does: 2*pi*7 is not seven times 2*pi to the last
    # bit, and the error is enough to round one row's displacement to a
    # different pixel on the frame that closes the loop. Discarding the turns
    # before the multiply makes the last frame's phase exactly the first's.
    my $turns = $ctx->travel( $p->{ drift }, 1 );
    $turns -= int $turns;

    my $base = $p->{ phase } * $PI / 180;
    $base += 2 * $PI * $turns;

    my $wrap = $p->{ edge } eq 'wrap';

    # Summing two waves would otherwise push the peak displacement past the
    # requested amplitude, so normalise by their combined weight.
    my $norm = 1 + $p->{ harmonic };

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my $w = $px->width;

            $px->each_row(
                sub {
                    my ( $y, $row ) = @_;

                    my $t = 2 * $PI * $y / $p->{ wavelength } + $base;
                    my $d = sin( $t );
                    $d += $p->{ harmonic } * sin( $t * 2.7 + 1.3 )
                        if $p->{ harmonic };

                    my $shift = int( $d * $p->{ amplitude } / $norm + 0.5 );
                    return undef unless $shift;

                    return GlitchVape::Pixels::shift_row( $row, $w, $shift,
                        $wrap );
                }
            );
        }
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'tracking',
    title   => 'Tracking Error',
    stage   => 'signal',
    summary => 'VCR tracking error: displaced, noisy horizontal bands',
    doc     => <<'DOC',
Picks a number of horizontal bands and shifts each sideways, optionally filling
it with noise. This is the single most recognisable VHS artefact -- the picture
holding steady while a ragged strip of it slides off to one side.

Band positions come from this effect's own RNG stream, so changing the seed
moves them without disturbing any other effect.

With C<crawl> at nought the bands are redrawn every frame of a loop, which is
tracking noise: the tape is being read badly and where it goes wrong is a
different place each time. Above nought they instead keep their places and
their displacement and creep up the picture, wrapping at the top -- the other
half of the artefact, and the one a mistracked tape shows while it is playing
steadily. A band that moves has to be the same band, so its place and shift
come from the fixed stream in that case; the noise inside it goes on
re-rolling either way, because that is the medium and not the fault.
DOC
    params => {
        bands => {
            default => 3,
            type    => 'int',
            min     => 0,
            max     => 60,
            doc     => 'How many damaged bands to create',
        },
        crawl => {
            animation => 1,

            # A crawl needs something to crawl: with no bands there is
            # nothing on the picture to move.
            needs   => { bands => 1 },
            default => 0,
            type    => 'int',
            min     => 0,
            max     => 4,
            doc     => 'Times the bands creep the height of the picture over '
                . 'the loop. 0 redraws them somewhere new each frame instead',
        },
        height => {
            default => 18,
            type    => 'int',
            min     => 1,
            max     => 400,
            doc     => 'Average band height in pixels',
        },
        displacement => {
            default => 30,
            type    => 'num',
            min     => 0,
            max     => 500,
            doc     => 'Maximum sideways shift of a band',
        },
        noise => {
            default => 0.35,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How much static is mixed into the band',
        },
        brighten => {
            default => 0.2,
            type    => 'num',
            min     => -1,
            max     =>  1,
            doc     => 'Lift applied inside bands; tape dropout runs bright',
        },
        edge => {
            default => 'wrap',
            type    => 'enum',
            values  => [ qw(wrap smear) ],
            doc     => 'Fill mode for the vacated edge',
        },
    },
    apply => \&_tracking,
);

# One run of scanlines, which may start near the bottom and finish at the top.
#
# A crawling band has to leave the picture somewhere, and a band that is
# simply clipped there is one that shrinks and vanishes instead of passing.
# Two substrs where it straddles the edge, one everywhere else.
sub _band_of
{
    my ( $px, $y, $rows ) = @_;

    my $h = $px->height;
    return $px->band( $y, $rows ) if $y + $rows <= $h;

    my $first = $h - $y;
    return $px->band( $y, $first ) . $px->band( 0, $rows - $first );
}

sub _set_band_of
{
    my ( $px, $y, $rows, $bytes ) = @_;

    my $h = $px->height;
    return $px->set_band( $y, $rows, $bytes ) if $y + $rows <= $h;

    my $first = $h - $y;
    my $split = $first * $px->width * 3;

    $px->set_band( $y, $first, substr $bytes, 0, $split );
    $px->set_band( 0, $rows - $first, substr $bytes, $split );

    return;
}

sub _tracking
{
    my ( $ctx, $p ) = @_;
    return if $p->{ bands } <= 0;

    my $rng  = $ctx->rng_for( 'tracking' );
    my $wrap = $p->{ edge } eq 'wrap';

    # Where a band is and how far it is pushed come from the fixed stream
    # once it has somewhere to crawl to, so that it is recognisably the same
    # band a frame later. Without a crawl it is the rolling stream, which is
    # also what keeps a still and an uncrawled loop rendering as they did.
    my $place = $p->{ crawl } ? $ctx->rng_fixed( 'tracking' ) : $rng;

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my ( $w, $h ) = ( $px->width, $px->height );

            # Whole pictures per loop, so the wrap lands on the frame that
            # closes it: a band is back where it started rather than a little
            # past it.
            my $creep = int $ctx->travel( $p->{ crawl } * $h, $h );

            for ( 1 .. $p->{ bands } )
            {
                my $bh = $place->int_between( 1, $p->{ height } * 2 );
                $bh = $h if $bh > $h;
                my $by = $place->int_between( 0, $h - $bh );

                # Squaring a uniform draw biases displacement small: most
                # tracking errors are minor, with the occasional large one.
                my $mag = $place->rand**2;

                # Bands drift either way; the sign is an independent coin
                # flip from the magnitude.
                my $direction = -1;
                if ( $place->chance( 0.5 ) )
                {
                    $direction = 1;
                }

                my $shift = int( $mag * $p->{ displacement } * $direction );

                $by = ( $by + $creep ) % $h if $creep;

                my $bytes = _band_of( $px, $by, $bh );
                $bytes =
                    GlitchVape::Pixels::shift_band( $bytes, $w, $bh, $shift,
                    $wrap )
                    if $shift;

                if ( $p->{ noise } > 0 || $p->{ brighten } )
                {
                    my $amt  = $p->{ noise } * 255;
                    my $lift = $p->{ brighten } * 255;

                    my @v = unpack 'C*', $bytes;
                    for my $j ( 0 .. $#v )
                    {
                        my $x = $v[ $j ] + $lift;
                        $x += ( $rng->rand( 2 ) - 1 ) * $amt if $amt;
                        $v[ $j ] = GlitchVape::Pixels::clamp( $x );
                    }
                    $bytes = pack 'C*', @v;
                }

                _set_band_of( $px, $by, $bh, $bytes );
            }
        }
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'head_switch',
    title   => 'Head-Switching Noise',
    stage   => 'signal',
    summary => 'Torn, noisy strip along the bottom edge',
    doc     => <<'DOC',
A helical-scan VCR switches heads a few lines before the end of each field, and
the switch is not clean. The result is a band of skewed, desaturated hash at the
very bottom of the picture that broadcast masks off but a raw tape capture
shows. Its presence is a strong tell that an image is meant to be tape.
DOC
    params => {
        height => {
            default => 14,
            type    => 'int',
            min     => 0,
            max     => 200,
            doc     => 'Height of the disturbed strip',
        },
        skew => {
            default => 26,
            type    => 'num',
            min     => -300,
            max     =>  300,
            doc     => 'Sideways displacement at the very bottom row',
        },
        noise => {
            default => 0.5,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Static mixed into the strip',
        },
        desaturate => {
            default => 0.7,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How grey the strip goes',
        },
    },
    apply => \&_head_switch,
);

sub _head_switch
{
    my ( $ctx, $p ) = @_;
    return if $p->{ height } <= 0;

    my $rng = $ctx->rng_for( 'head_switch' );

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my ( $w, $h ) = ( $px->width, $px->height );

            # Never ask for a strip taller than the picture.
            my $bh = $p->{ height };
            if ( $bh > $h )
            {
                $bh = $h;
            }
            my $y0 = $h - $bh;

            for my $r ( 0 .. $bh - 1 )
            {
                my $y = $y0 + $r;

                # Displacement ramps up towards the bottom row, which is what
                # makes it look torn rather than merely offset.
                my $t     = ( $r + 1 ) / $bh;
                my $shift = int( $p->{ skew } * $t * $t + 0.5 );

                my $row = $px->row( $y );
                $row = GlitchVape::Pixels::shift_row( $row, $w, $shift, 0 )
                    if $shift;

                my $amt = $p->{ noise } * $t * 255;
                my $des = $p->{ desaturate } * $t;
                next if $amt <= 0 && $des <= 0;

                my @v = unpack 'C*', $row;
                for ( my $i = 0 ; $i < @v ; $i += 3 )
                {
                    if ( $des > 0 )
                    {
                        my $grey =
                            GlitchVape::Pixels::luma( @v[ $i .. $i + 2 ] );
                        $v[ $_ ] += ( $grey - $v[ $_ ] ) * $des
                            for $i .. $i + 2;
                    }
                    if ( $amt > 0 )
                    {
                        # One noise value for all three channels: head-switch
                        # hash is luminance noise, not colour confetti.
                        my $n = ( $rng->rand( 2 ) - 1 ) * $amt;
                        $v[ $_ ] = GlitchVape::Pixels::clamp( $v[ $_ ] + $n )
                            for $i .. $i + 2;
                    }
                    else
                    {
                        $v[ $_ ] = int $v[ $_ ] for $i .. $i + 2;
                    }
                }

                $px->set_row( $y, pack 'C*', @v );
            }
        }
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'ghost',
    title   => 'RF Ghosting',
    stage   => 'signal',
    summary => 'RF multipath echo',
    doc     => <<'DOC',
Semi-transparent copies of the picture offset to one side, as when a broadcast
signal arrives twice having bounced off something. Successive echoes get
weaker and further away.

C<drift> wanders the echo delay back and forth over a loop rather than sliding
it one way. An echo is a single feature with nowhere to travel to -- pushed off
one side it would have to reappear at the other, and with only one of it there
is nothing to cover the jump. Wandering is also what the real thing does: the
delay follows whatever the signal is bouncing off, and reflectors sway rather
than orbit.
DOC
    params => {
        offset => {
            default => 14,
            type    => 'num',
            min     => -400,
            max     =>  400,
            doc     => 'Horizontal offset of the first echo',
        },
        vertical => {
            default => 0,
            type    => 'num',
            min     => -400,
            max     =>  400,
            doc     => 'Vertical offset of the first echo',
        },
        count => {
            default => 1,
            type    => 'int',
            min     => 1,
            max     => 8,
            doc     => 'Number of echoes',
        },
        drift => {
            animation => 1,
            default   => 0,
            type      => 'num',
            min       => -200,
            max       =>  200,
            doc       => 'Pixels the delay wanders either way over a loop',
        },
        strength => {
            default => 0.35,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Opacity of the first echo',
        },
        falloff => {
            default => 0.5,
            type    => 'num',
            min     => 0.05,
            max     => 1,
            doc     => 'Multiplier applied to each subsequent echo',
        },
    },
    apply => \&_ghost,
);

sub _ghost
{
    my ( $ctx, $p ) = @_;
    return if $p->{ strength } <= 0;

    my $opacity = $p->{ strength };

    # Added to the nominal delay before it is multiplied out across the
    # echoes, so a later echo wanders further than an earlier one -- which is
    # what a changing path length does to a train of reflections.
    my $wander = $ctx->excursion( $p->{ drift } );

    for my $i ( 1 .. $p->{ count } )
    {
        last if $opacity < 0.01;

        my $echo = $ctx->clone;
        my $pct  = int( ( 1 - $opacity ) * 100 + 0.5 );

        $echo->Roll(
            x => int( ( $p->{ offset } + $wander ) * $i + 0.5 ),
            y => int( $p->{ vertical } * $i + 0.5 ),
        );

        $ctx->image->Composite(
            image   => $echo->[ 0 ],
            compose => 'Blend',
            args    => "$pct",
        );

        $opacity *= $p->{ falloff };
    }
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'vhold',
    title   => 'Vertical Hold Slip',
    stage   => 'signal',
    summary => 'Vertical hold slip, with a tear line',
    doc     => <<'DOC',
Rolls the picture vertically as on a set whose vertical hold has drifted. The
seam where the bottom wraps to the top is darkened and blurred, since on a real
tube that boundary is the retrace and never appears as a clean cut.

In an animation the roll advances with the loop, so the picture climbs
continuously and rejoins itself at the end.
DOC
    params => {
        offset => {
            default => 0.25,
            type    => 'num',
            min     => -1,
            max     =>  1,
            doc     => 'Roll distance as a fraction of image height',
        },
        tear => {
            default => 6,
            type    => 'int',
            min     => 0,
            max     => 100,
            doc     => 'Height in pixels of the darkened seam',
        },
        animate => {
            animation => 1,
            default   => 1,
            type      => 'bool',
            doc       => 'Advance the roll across animation frames',
        },
    },
    apply => \&_vhold,
);

sub _vhold
{
    my ( $ctx, $p ) = @_;

    my ( $w, $h ) = $ctx->dims;

    my $frac = $p->{ offset };
    $frac += $ctx->phase if $p->{ animate } && $ctx->frames > 1;

    my $shift = int( $frac * $h ) % $h;
    return if !$shift && !$p->{ tear };

    $ctx->image->Roll( x => 0, y => $shift );
    return unless $p->{ tear } > 0;

    # The seam sits where the original top edge landed.
    my $seam = $shift % $h;
    my $th   = $p->{ tear };
    my $y    = $seam - int( $th / 2 );
    $y  = 0       if $y < 0;
    $th = $h - $y if $y + $th > $h;
    return if $th <= 0;

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my $bytes = $px->band( $y, $th );
            $px->set_band( $y, $th,
                pack 'C*', map { int( $_ * 0.25 ) } unpack 'C*', $bytes );
        }
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'interlace',
    title   => 'Interlacing',
    stage   => 'signal',
    summary => 'Field separation: offset or dim alternate lines',
    doc     => <<'DOC',
Interlaced video sends odd and even lines as separate fields taken at different
instants. On anything moving, the two fields disagree -- which is why a paused
tape shows a comb pattern along every edge. Offsetting alternate lines
horizontally reproduces that.

C<drift> is the interlace crawl: the slow swap of which field is displaced
that a mistimed field rate gives. Two rows is the whole pattern, so a crawl
has exactly two states however far it is said to travel -- which is why this
counts swaps rather than rows. 1 is one swap and one swap back over the whole
loop, 2 is twice, and it closes at any of them.

It used to be measured in rows per loop over a range of 481 values, which was
a lie about a pattern with two states: every value did one of the same two
things, and any multiple of twice the frame count did neither, because the
crawl then stepped a whole number of field pairs between frames and the comb
never moved at all. Nothing said so.

It is held to a quarter of the frame count, so each field is on screen for at
least two frames. A comb that changes every frame is not the fifty-hertz field
alternation it looks like it should be; at any frame rate this program writes
it lands as flicker rather than as anything anyone would recognise.
DOC
    params => {
        offset => {
            default => 3,
            type    => 'int',
            min     => -200,
            max     =>  200,
            doc     => 'Sideways displacement of the second field',
        },
        dim => {
            default => 0.12,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How much darker the second field is',
        },
        field => {
            default => 'odd',
            type    => 'enum',
            values  => [ qw(odd even) ],
            doc     => 'Which field gets displaced',
        },
        drift => {
            animation => 1,
            default   => 0,
            type      => 'int',
            min       => 0,
            max       => 12,
            doc       => 'Times the field pattern swaps and swaps back over '
                . 'the loop; held to a quarter of the frame count',
        },
    },
    apply => \&_interlace,
);

# How many times the field pattern has swapped by this frame.
#
# Counted rather than travelled: two rows is the whole pattern, so the only
# thing a crawl can do is swap which field is displaced, and asking travel for
# a distance in rows means most distances land on a whole number of field
# pairs and nothing moves. Held to a quarter of the frame count so that each
# field is up for two frames at least -- one frame each is a flicker, not a
# comb.
sub _crawled
{
    my ( $ctx, $swaps ) = @_;

    my $frames = $ctx->frames;
    return 0 unless $swaps && $frames > 1;

    my $most = int( $frames / 4 ) || 1;
    $swaps = $most if $swaps > $most;

    # Twice, because one swap out and one home is what closes the loop.
    return int( 2 * $swaps * $ctx->phase );
}

sub _interlace
{
    my ( $ctx, $p ) = @_;
    return if !$p->{ offset } && $p->{ dim } <= 0;

    # Rows whose index modulo two equals this are the displaced field.
    my $want = 0;
    if ( $p->{ field } eq 'odd' )
    {
        $want = 1;
    }

    $want = ( $want + _crawled( $ctx, $p->{ drift } ) ) % 2;

    my $scale = 1 - $p->{ dim };

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my $w = $px->width;

            $px->each_row(
                sub {
                    my ( $y, $row ) = @_;
                    return undef unless $y % 2 == $want;

                    $row =
                        GlitchVape::Pixels::shift_row( $row, $w,
                        $p->{ offset }, 1 )
                        if $p->{ offset };

                    $row = pack 'C*', map { int( $_ * $scale ) } unpack 'C*',
                        $row
                        if $p->{ dim } > 0;

                    return $row;
                }
            );
        }
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'dropout',
    title   => 'Tape Dropout',
    stage   => 'signal',
    summary => 'Bright horizontal streaks where the tape has shed oxide',
    doc     => <<'DOC',
Short bright dashes scattered across the picture. Physically these are places
where the head momentarily lost contact with the tape and the signal went to
white. Sparse and short reads as wear; dense and long reads as a tape that is
falling apart.
DOC
    params => {
        count => {
            default => 14,
            type    => 'int',
            min     => 0,
            max     => 500,
            doc     => 'Number of streaks',
        },
        length => {
            default => 90,
            type    => 'int',
            min     => 2,
            max     => 2000,
            doc     => 'Maximum streak length in pixels',
        },
        thickness => {
            default => 2,
            type    => 'int',
            min     => 1,
            max     => 40,
            doc     => 'Streak height in pixels',
        },
        brightness => {
            default => 0.85,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How far towards white the streak goes',
        },
    },
    apply => \&_dropout,
);

sub _dropout
{
    my ( $ctx, $p ) = @_;
    return if $p->{ count } <= 0;

    my $rng = $ctx->rng_for( 'dropout' );
    my $b   = $p->{ brightness };

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my ( $w, $h ) = ( $px->width, $px->height );

            for ( 1 .. $p->{ count } )
            {
                my $len = $rng->int_between( 2, $p->{ length } );
                $len = $w if $len > $w;
                my $th = $rng->int_between( 1, $p->{ thickness } );
                $th = $h if $th > $h;

                my $x = $rng->int_between( 0, $w - $len );
                my $y = $rng->int_between( 0, $h - $th );

                my $bytes = $px->rect( $x, $y, $len, $th );
                $px->set_rect( $x, $y, $len, $th, pack 'C*',
                    map { int( $_ + ( 255 - $_ ) * $b ) } unpack 'C*', $bytes );
            }
        }
    );
    return;
}

1;
