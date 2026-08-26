package GlitchVape::Heart;

use strict;
use warnings;
use utf8;

use GlitchVape::Random ();
use GlitchVape::Wav    ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Heart - a heartbeat

=head1 DESCRIPTION

Two sounds a beat, both of them valves closing. B<S1> -- the "lub" -- is the
mitral and tricuspid valves shutting as the ventricles begin to contract:
lower, and the longer of the two. B<S2> -- the "dub" -- is the aortic and
pulmonary valves shutting as they finish: a little higher and noticeably
shorter.

=head2 Why the two gaps are not equal

This is the whole thing. S1 to S2 -- systole, the beat itself -- is much
shorter than S2 to the next S1, which is the heart refilling. At rest the
split is roughly a third and two thirds, so the pattern is B<lub-dub ... ...
lub-dub ... ...> and not four evenly spaced events. Space them evenly and what
comes out is a drum loop.

=head2 Why a fast heartbeat sounds urgent

The ratio is not fixed either. As the rate rises, systole shortens far less
than diastole does -- the contraction takes about as long as it takes, while
the pause between beats is squeezed out of existence. At 60 bpm the pause is
most of the cycle; by 150 it has all but gone.

That is B<why> a racing heart reads as alarming rather than merely quick, so it
is worth modelling: systole is scaled by the square root of the cycle length,
which is the same shape the QT interval is corrected by and close enough for
something nobody is going to diagnose from.

=head2 Why the rate wanders

A real heart is not a metronome, and one held at exactly N beats a minute
reads as a loop within about four beats. So the rate wanders, and the two
parameters that govern it say how far and how fast rather than in what
pattern: the wandering stays irregular whatever they are set to, because it is
a random walk that is being shaped and not a waveform.

=head2 Why the sounds are noise and not tones

A valve closing is a broadband thud, not a pitch. A sine burst -- the obvious
implementation -- gives a synthesised kick drum, which is recognisably not a
heart. What is here is a burst of noise through a low-pass tuned low, with a
little damped sine underneath for body.

Almost none of the result is above 200 Hz, which is why 16 kHz is a generous
sampling rate for it rather than a compromise.

=cut

# Nothing in a heart sound comes near 8 kHz, so this is already luxurious.
# The final band limit is ffmpeg's on the way into the mix.
use constant RATE => 16_000;

# Systole at a one-second cycle, in seconds -- the S1-to-S2 gap at 60 bpm.
# Everything else is scaled off this; see L</Why a fast heartbeat sounds
# urgent>.
use constant SYSTOLE_AT_60 => 0.30;

# The two closures, each described in one place: the resonance it sits on, how
# long it rings, and how hard it hits. S2 is the higher, shorter and quieter
# of the two, which between them is what tells the "dub" from the "lub".
use constant S1 => { hz => 40, seconds => 0.14, level => 1.00 };
use constant S2 => { hz => 58, seconds => 0.10, level => 0.75 };

# How often the wandering rate is redrawn. Slower than a beat, because it is
# meant to be heard across beats rather than within one.
use constant SWAY_STEP_S => 0.25;

my $PI = 3.14159265358979;

=head2 params()

The declaration this generator is built from, in display order.

=cut

my @PARAM = (
    seconds => {

        # Unbounded, like the other generators' lengths: the interface gives
        # a range-less number a spin button rather than a slider.
        label   => 'Length',
        type    => 'int',
        default => 20,
        doc     => 'How long the heartbeat runs when nothing else sets the '
            . 'length. With an audio track present the track decides.',
    },
    bpm => {
        label   => 'Rate',
        type    => 'num',
        min     => 30,
        max     => 200,
        default => 70,
        doc     => 'Beats per minute, before any wandering. Sixty to eighty '
            . 'is a person at rest; past about 120 the pause between beats '
            . 'is gone and it stops sounding calm.',
    },
    sway => {
        label   => 'Fluctuation',
        type    => 'num',
        min     => 0,
        max     => 40,
        default => 8,
        doc     => 'How far the rate may wander either side of that, in '
            . 'beats per minute. It is a ceiling, not a target: the rate '
            . 'drifts up and down within it and never past it. Zero is a '
            . 'metronome, which is the one thing a heart never is.',
    },
    sway_rate => {
        label   => 'Fluctuation speed',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.3,
        doc     => 'How quickly it wanders within that ceiling. Low is a '
            . 'slow swell across half a minute; high is restless, changing '
            . 'every few beats. It stays irregular at either end -- this '
            . 'sets the pace of the wandering, never its pattern.',
    },
    depth => {
        label   => 'Depth',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.5,
        doc     => 'How much chest is around it. 0 is a stethoscope, close '
            . 'and papery; 1 is felt through a wall. Rolls the top off both '
            . 'thuds and lengthens their decay.',
    },
    gain => {
        label   => 'Level',
        type    => 'num',
        min     => 0,
        max     => 2,
        default => 0.8,
        doc     => 'Output level.',
    },
    seed => {
        label   => 'Seed',
        type    => 'int',
        default => 1,
        doc     => 'The same seed gives the same wandering, so a render '
            . 'stays reproducible after the preview cache has forgotten it.',
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

The requested length. A heart has no natural end either.

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

C<$fill_to> overrides the requested length. There is nothing to loop and no
seam to hide: it simply goes on beating.

=cut

sub pcm
{
    my ( $spec, $fill_to ) = @_;

    my $seconds = $fill_to;
    $seconds = duration( $spec ) unless $seconds && $seconds > 0;

    my $count = int( RATE * $seconds );
    return q{} unless $count > 0;

    my $rng = GlitchVape::Random->new( seed => $spec->{ seed } // 1 );

    my $bpm   = $spec->{ bpm }   // 70;
    my $sway  = $spec->{ sway }  // 8;
    my $depth = $spec->{ depth } // 0.5;
    my $gain  = $spec->{ gain }  // 0.8;

    # The wander is a bounded random walk on the rate, redrawn on its own
    # clock rather than per beat: at 40 bpm a per-beat walk would take a
    # minute to go anywhere, and the parameter is meant to mean the same
    # thing at every rate.
    my $sway_rate = $spec->{ sway_rate } // 0.3;
    my $step      = $sway * ( 0.02 + $sway_rate * 0.28 );

    my @sample = ( 0 ) x $count;

    my $now    = 0;
    my $swayed = 0;
    my $offset = 0;

    while ( $now < $seconds )
    {
        my $rate = $bpm + $offset;
        $rate = 20 if $rate < 20;

        my $cycle = 60 / $rate;

        # Systole scales with the square root of the cycle, so the pause is
        # what disappears as the rate climbs -- see the POD above. Capped at
        # nine tenths of the cycle so a very fast rate still has S2 inside
        # its own beat rather than landing on the next S1.
        my $systole = SYSTOLE_AT_60 * sqrt( $cycle );
        $systole = $cycle * 0.9 if $systole > $cycle * 0.9;

        _thud( \@sample, int( $now * RATE ),                S1, $depth, $rng );
        _thud( \@sample, int( ( $now + $systole ) * RATE ), S2, $depth, $rng );

        $now += $cycle;

        # Move the wander along by however much time that beat took.
        while ( $swayed + SWAY_STEP_S <= $now )
        {
            $swayed += SWAY_STEP_S;

            $offset += $rng->gauss( 0, $step );
            $offset = -$sway if $offset < -$sway;
            $offset = $sway  if $offset > $sway;
        }
    }

    return pack 's<*', map { GlitchVape::Wav::quantise( $_ * $gain ) } @sample;
}

# One valve closure, added in place at $at.
#
# Noise through a one-pole low-pass for the body of it -- a valve is a thud
# and not a pitch -- with a damped sine underneath so it has a centre. Depth
# closes the filter and lengthens the decay together, because both are what
# distance through a chest actually does.
sub _thud
{
    my ( $sample, $at, $sound, $depth, $rng ) = @_;

    return if $at < 0 || $at >= @$sample;

    my $hz       = $sound->{ hz };
    my $level    = $sound->{ level };
    my $length_s = $sound->{ seconds };

    my $length = int( RATE * $length_s * ( 1 + $depth * 0.5 ) );

    # The corner comes down as depth goes up: 260 Hz against the chest wall,
    # 90 Hz through it.
    my $corner = 260 - $depth * 170;
    my $alpha  = 1 - exp( -2 * $PI * $corner / RATE );

    my $decay = $length_s / 2.2;
    my $low   = 0;

    for my $n ( 0 .. $length - 1 )
    {
        my $i = $at + $n;
        last if $i >= @$sample;

        my $t = $n / RATE;

        # A fast attack rather than an instant one: a step into a low-pass
        # clicks, and a heart does not click.
        my $env = exp( -$t / $decay );
        $env *= $t / 0.004 if $t < 0.004;

        my $white = $rng->rand( 2 ) - 1;
        $low += $alpha * ( $white - $low );

        my $body = sin( 2 * $PI * $hz * $t ) * 0.5;

        $sample->[ $i ] += ( $low * 1.6 + $body ) * $env * $level * 0.7;
    }

    return;
}

=head2 render( %arg )

    spec    => the heartbeat spec
    output  => path to write, .wav
    fill_to => seconds to cover

=cut

sub render
{
    my ( %arg ) = @_;

    my $spec = $arg{ spec }
        or die "GlitchVape::Heart: no spec given\n";
    my $output = $arg{ output }
        or die "GlitchVape::Heart: no output given\n";

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

    return 'heartbeat' unless ref $spec eq 'HASH';

    my $bpm = $spec->{ bpm } // 70;

    # What it means to hear it, rather than the number.
    my $character = 'slow';
    $character = 'resting' if $bpm >= 55;
    $character = 'quick'   if $bpm >= 95;
    $character = 'racing'  if $bpm >= 130;

    my $line = sprintf 'heartbeat  %s  %d bpm  %s', $character, $bpm,
        _mmss( duration( $spec ) );

    my $sway = $spec->{ sway } // 8;
    $line .= sprintf '  ±%d', $sway if $sway > 0.5;

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
L<GlitchVape::Geiger> for the other one whose timing is the point, and
L<GlitchVape::Wav>, where the samples end up.

=cut
