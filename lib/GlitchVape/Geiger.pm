package GlitchVape::Geiger;

use strict;
use warnings;
use utf8;

use GlitchVape::Random ();
use GlitchVape::Wav    ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Geiger - a Geiger counter, ticking

=head1 DESCRIPTION

A Geiger-Müller tube discharges when an ionising particle passes through it,
and each discharge is amplified into a click. So there are two things to
synthesise: what a click sounds like, and when the clicks happen.

The second is the one that matters.

=head2 Why the timing is a Poisson process

Radioactive decay has no memory: the chance of a particle arriving in the next
millisecond does not depend on how long it has been since the last one. That
makes the interval between clicks exponentially distributed, and the interval
is drawn accordingly:

    my $gap = -log( $rng->rand( 1 ) ) / $lambda;

This is not an approximation of the sound; it is the sound. What makes a
Geiger counter recognisable is that its clicks B<clump> -- a burst, a pause, a
double-tap -- and that clumping is exactly what a Poisson process produces. The
intuitive alternative, jittering around a fixed interval, produces something
that sounds like a failing metronome instead. The physically correct model is
also the shorter code.

=head2 Dead time

After each discharge the tube is briefly insensitive, so a particle arriving
during that window is simply not counted. That is why a real counter saturates
as it approaches a strong source -- the clicks fuse into a buzz rather than
merely getting denser -- and it is one line here.

It is a constant rather than a parameter because it is a property of the tube,
not something anyone would tune.

=head2 The source wanders

Intensity from a point source follows the inverse square law, so with the
tube at a distance C<r> the count rate is proportional to C<1/r²>. Walking
around with one gives

    λ = baseline + ( strength - baseline ) / ( 1 + ( x / NEAR )² )

where C<x> is how far off the source you are -- a Lorentzian: a sharp peak with
long tails, which is much better to listen to than a sine sweep because a sine
spends most of its travel in the boring middle.

C<x> is a bounded random walk rather than a fixed path. Nothing repeats, and a
track asked to cover three minutes simply wanders for three minutes -- the same
property that lets static carry on indefinitely.

=head2 Why this one is generated at 44.1 kHz

L<GlitchVape::Noise> synthesises at 16 kHz on the grounds that a television's
audio path has nothing above 8 kHz in it. That argument does not transfer: the
sharpness of a click B<is> its content, and band-limiting one to 8 kHz turns a
tick into a thud.

=cut

use constant RATE => GlitchVape::Wav::RATE;

# A Geiger-Müller tube is insensitive for a couple of hundred microseconds
# after a discharge. The exact figure varies by tube; this is the middle of
# the usual range, and what it buys is the saturation at high rates.
use constant DEAD_S => 0.000_15;

# How long a click rings for. Short enough to read as a tick; a longer decay
# turns the counter into a woodblock.
use constant RING_S => 0.004;

# The distance at which the count rate is halfway between baseline and full
# strength, in the same arbitrary units the walk below uses. It sets how
# sharply the peak arrives.
use constant NEAR => 1.0;

# How far the walk may stray. Six of those units puts the rate back within a
# few percent of baseline, so anything wider is just silence with extra steps.
use constant RANGE => 6.0;

# The rate is only recomputed this often rather than per click, because the
# walk moves in seconds and the clicks arrive in milliseconds.
use constant STEP_S => 0.05;

my $PI = 3.14159265358979;

=head2 params()

The declaration this generator is built from, in display order.

=cut

my @PARAM = (
    seconds => {

        # Unbounded for the same reason static's is: the interface gives a
        # range-less number a spin button, and a slider spanning ten minutes
        # is unusable at the ten-second end where it is actually wanted.
        label   => 'Length',
        type    => 'int',
        default => 20,
        doc     => 'How long the counter runs when nothing else sets the '
            . 'length. With an audio track present the track decides, and '
            . 'the counter simply carries on.',
    },
    strength => {
        label   => 'Source strength',
        type    => 'num',
        min     => 1,
        max     => 500,
        default => 60,
        doc     => 'Clicks per second at closest approach -- how hot the '
            . 'thing you are walking past is. Past about 200 the dead time '
            . 'of the tube starts swallowing counts, which is why a very '
            . 'strong source buzzes rather than simply ticking faster.',
    },
    baseline => {
        label   => 'Background',
        type    => 'num',
        min     => 0,
        max     => 20,
        default => 2,
        doc     => 'Clicks per second with nothing nearby. Never goes below '
            . 'this, so the counter is audibly switched on even at its '
            . 'quietest. Two or three a second is roughly the real thing.',
    },
    speed => {
        label   => 'Movement',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.3,
        doc     => 'How quickly you drift towards and away from the source. '
            . 'At 0 the distance never changes and the rate is fixed; at 1 '
            . 'you sweep past it every few seconds.',
    },
    tone => {
        label   => 'Click tone',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.5,
        doc     => 'How bright each click is, which is really how small the '
            . "counter's speaker is. Moves the ring from 800 Hz to 4 kHz "
            . 'logarithmically, because pitch is logarithmic.',
    },
    gain => {
        label   => 'Level',
        type    => 'num',
        min     => 0,
        max     => 2,
        default => 0.7,
        doc     => 'Output level.',
    },
    seed => {
        label   => 'Seed',
        type    => 'int',
        default => 1,
        doc     => 'The same seed gives the same clicks, so a render stays '
            . 'reproducible after the preview cache has forgotten it.',
    },
);

sub params
{
    my %spec = @PARAM;
    return \%spec;
}

=head2 param_order()

The names in the order they should be shown: length first because it is the
only one that changes what you get rather than how it sounds.

=cut

sub param_order
{
    my @names;
    for my $n ( 0 .. $#PARAM )
    {
        push @names, $PARAM[ $n ] if $n % 2 == 0;
    }

    return @names;
}

=head2 duration( $spec )

The requested length. Like static and unlike a dialled phrase, a counter has
no natural end -- this is a setting rather than a consequence.

=cut

sub duration
{
    my ( $spec ) = @_;

    return 0 unless ref $spec eq 'HASH';

    # A floor rather than a declared minimum: the parameter is unbounded so
    # that it gets a spin button, which leaves nothing to stop a zero.
    my $seconds = $spec->{ seconds };
    return 20 unless defined $seconds && $seconds > 0;

    return $seconds;
}

=head2 pcm( $spec, $fill_to )

Packed 16-bit mono samples at L</RATE>.

C<$fill_to> overrides the requested length, which is how an audio track in the
same mix decides how long everything runs. There is nothing to loop, so
covering a longer stretch is simply walking about for longer.

=cut

sub pcm
{
    my ( $spec, $fill_to ) = @_;

    my $seconds = $fill_to;
    $seconds = duration( $spec ) unless $seconds && $seconds > 0;

    my $count = int( RATE * $seconds );
    return q{} unless $count > 0;

    my $rng = GlitchVape::Random->new( seed => $spec->{ seed } // 1 );

    my $strength = $spec->{ strength } // 60;
    my $baseline = $spec->{ baseline } // 2;
    my $speed    = $spec->{ speed }    // 0.3;
    my $gain     = $spec->{ gain }     // 0.7;

    # A source weaker than the background is not a source; keeping the two
    # ordered means the Lorentzian below can only ever raise the rate.
    $strength = $baseline if $strength < $baseline;

    # Logarithmic sweep of the ring frequency, worked out once.
    my $tone = $spec->{ tone } // 0.5;
    my $ring = 800 * ( 4000 / 800 )**$tone;

    my @sample = ( 0 ) x $count;

    # Where the clicks fall. Time is walked in seconds here rather than in
    # samples, because a Poisson gap is a length of time and turning it into
    # an index once at the end is cheaper than counting samples between
    # arrivals.
    my $now  = 0;
    my $last = -DEAD_S;

    # The distance to the source, as a bounded random walk. At speed 0 it
    # never moves, which is a fixed rate rather than a special case.
    my $x        = RANGE / 2;
    my $walked   = 0;
    my $step     = $speed * 0.9;
    my $interval = STEP_S;

    my $lambda = _rate_at( $x, $baseline, $strength );

    while ( $now < $seconds )
    {
        # A rate of zero would divide by zero below and means silence anyway.
        last unless $lambda > 0;

        $now += -log( $rng->rand( 1 ) || 1e-9 ) / $lambda;
        last if $now >= $seconds;

        # The tube is still recovering, so this particle went uncounted. Not
        # `next` on the walk: time has still passed.
        if ( $now - $last >= DEAD_S )
        {
            _click( \@sample, int( $now * RATE ), $ring, $rng );
            $last = $now;
        }

        # Move, at most once per STEP_S however many clicks went by.
        while ( $walked + $interval <= $now )
        {
            $walked += $interval;

            $x += $rng->gauss( 0, $step );
            $x = -RANGE if $x < -RANGE;
            $x = RANGE  if $x > RANGE;

            $lambda = _rate_at( $x, $baseline, $strength );
        }
    }

    return pack 's<*', map { GlitchVape::Wav::quantise( $_ * $gain ) } @sample;
}

# The inverse square law, as a count rate. See L</The source wanders>.
sub _rate_at
{
    my ( $x, $baseline, $strength ) = @_;

    my $near = $x / NEAR;

    return $baseline + ( $strength - $baseline ) / ( 1 + $near * $near );
}

# One click, added in place at $at.
#
# A damped sine for the body of it, with a couple of samples of noise at the
# front. The noise is what stops every click being identical: a tube fires
# into a small speaker, and the attack is never quite the same twice.
sub _click
{
    my ( $sample, $at, $ring, $rng ) = @_;

    my $length = int( RATE * RING_S );
    return if $at < 0 || $at >= @$sample;

    # Slight variation in how hard each discharge hits. Real discharges are
    # more uniform than this -- the tube's dead time sees to that -- but a
    # click of exactly one loudness reads as a machine gun.
    my $level = 0.85 + $rng->rand( 0.3 );

    my $decay = RING_S / 4;

    for my $n ( 0 .. $length - 1 )
    {
        my $i = $at + $n;
        last if $i >= @$sample;

        my $t   = $n / RATE;
        my $env = exp( -$t / $decay );

        my $value = sin( 2 * $PI * $ring * $t ) * $env;

        # The first half-millisecond carries the spit of the discharge.
        $value += ( $rng->rand( 2 ) - 1 ) * $env * 0.4 if $t < 0.0005;

        $sample->[ $i ] += $value * $level * 0.6;
    }

    return;
}

=head2 render( %arg )

    spec    => the counter spec
    output  => path to write, .wav
    fill_to => seconds to cover

=cut

sub render
{
    my ( %arg ) = @_;

    my $spec = $arg{ spec }
        or die "GlitchVape::Geiger: no spec given\n";
    my $output = $arg{ output }
        or die "GlitchVape::Geiger: no output given\n";

    return GlitchVape::Wav::write(
        $output,
        pcm( $spec, $arg{ fill_to } ),
        rate => RATE
    );
}

=head2 describe( $spec )

One line for a track row.

=cut

sub describe
{
    my ( $spec ) = @_;

    return 'geiger' unless ref $spec eq 'HASH';

    my $strength = $spec->{ strength } // 60;

    # The number of counts means nothing to anybody standing there; how alarmed
    # to be does.
    my $character = 'quiet';
    $character = 'ticking' if $strength >= 20;
    $character = 'busy'    if $strength >= 80;
    $character = 'hot'     if $strength >= 200;

    my $line =
        sprintf 'geiger  %s  %s', $character, _mmss( duration( $spec ) );

    $line .= '  wandering' if ( $spec->{ speed } // 0.3 ) > 0.02;

    return $line;
}

sub _mmss
{
    my ( $seconds ) = @_;

    $seconds = 0 unless defined $seconds && $seconds > 0;
    my $minutes = int( $seconds / 60 );

    return sprintf '%d:%04.1f', $minutes, $seconds - $minutes * 60;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Generator>, which registers this as a kind of track,
L<GlitchVape::Heart> for the other one that wanders, and L<GlitchVape::Wav>,
where the samples end up.

=cut
