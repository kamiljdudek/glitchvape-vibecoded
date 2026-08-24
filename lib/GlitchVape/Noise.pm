package GlitchVape::Noise;

use strict;
use warnings;

use GlitchVape::Random ();
use GlitchVape::Wav    ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Noise - the sound of an untuned television

=head1 DESCRIPTION

Analogue snow: the hiss of a set tuned to a channel that is not broadcasting,
with the mains hum of the set itself under it and the occasional crackle of
the signal trying and failing to lock.

=head2 Why it is not white noise

White noise has equal power at every frequency, which means most of its energy
sits in the top octave -- and the top octave is where hearing is most easily
fatigued. Half a minute of it is unpleasant in a way that has nothing to do
with how loud it is.

Real static is not white anyway. It reaches the ear through a small speaker at
the back of a wooden box, which rolls the extremes off at both ends. So the
source here is B<pink> -- equal power per octave, falling 3 dB per octave,
which is the distribution rain and waterfalls have and the reason those are
restful rather than tiring -- and then band-limited on top of that.

The result is unmistakably static, and can be left running under a loop
without anybody wanting it turned off.

=head2 Why it is generated at 16 kHz

A television's audio path has nothing above about 8 kHz in it, so neither does
this. Synthesising at twice that rather than at CD rate makes the buffer a
third of the size, and hands the final band limit to ffmpeg's resampler on the
way into the mix -- which is a far better low-pass filter than the one-pole
this would otherwise need, and free.

=cut

# Nyquist at 16 kHz is 8 kHz, which is where a television's audio ends anyway.
use constant RATE => 16_000;

# Pink noise by Paul Kellet's economy method: three one-pole filters summed,
# which tracks a true -3 dB/octave slope to within a fraction of a decibel
# across the audible range for the cost of three multiply-adds a sample.
my @PINK_POLE = ( 0.99765,   0.96300,   0.57000 );
my @PINK_GAIN = ( 0.0990460, 0.2965164, 1.0526913 );
use constant PINK_DIRECT => 0.1848;

# The summed poles run hot; this brings the result back to roughly unity peak
# before anything else is done to it.
use constant PINK_TRIM => 0.14;

# Mains hum. 50 Hz because this is a European set; the second harmonic is what
# actually makes it sound like a transformer rather than a test tone.
use constant HUM_HZ => 50;

# A crackle is a couple of milliseconds of full-band noise, which is short
# enough to read as a tick rather than as a burst.
use constant CRACKLE_MS => 3;

my $PI = 3.14159265358979;

=head2 params()

The declaration this generator is built from, in display order. Read by
L<GlitchVape::Generator>, which is what turns it into command-line validation
and into widgets.

=cut

my @PARAM = (
    seconds => {

        # Whole seconds, and deliberately unbounded: a length is a number
        # somebody types, so the interface should give it a spin button, and
        # it only does that for a parameter with no range to draw a slider
        # against. A slider spanning ten minutes would be unusable at the
        # ten-second end where it is actually wanted.
        label   => 'Length',
        type    => 'int',
        default => 10,
        doc     => 'How long the static runs when nothing else sets the '
            . 'length. With an audio track present the track decides, and '
            . 'the static simply carries on for as long as it lasts.',
    },
    tone => {
        label   => 'Tone',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.35,
        doc     => 'How far open the top end is. 0 is a set in the next '
            . 'room, 1 is one you are sitting in front of. Moves the '
            . 'low-pass corner from 700 Hz to 7 kHz logarithmically, '
            . 'because pitch is logarithmic and a linear sweep would spend '
            . 'most of its travel doing nothing audible.',
    },
    drift => {
        label   => 'Drift',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.3,
        doc     => 'Slow swell in the level, as the signal wanders. Static '
            . 'held at exactly one volume reads as a synthesiser; this is '
            . 'most of what stops it.',
    },
    hum => {
        label   => 'Mains hum',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.15,
        doc     => 'The 50 Hz buzz of the set itself, with its second '
            . 'harmonic. Subtle by default, and the single most evocative '
            . 'component: hiss alone could be anything, hiss over hum is a '
            . 'television.',
    },
    crackle => {
        label   => 'Crackle',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.2,
        doc     => 'How often the signal ticks and spits, as a badly tuned '
            . 'one does. Zero is a clean dead channel.',
    },
    gain => {
        label   => 'Level',
        type    => 'num',
        min     => 0,
        max     => 2,
        default => 0.5,
        doc     => 'Output level. Lower than the other generators by '
            . 'default, because static is a bed rather than a part.',
    },
    seed => {

        # Deliberately unbounded: the interface gives a range-less number a
        # spin button rather than a slider, and a slider spanning two billion
        # values is not a control.
        label   => 'Seed',
        type    => 'int',
        default => 1,
        doc     => 'The same seed gives the same static, so a render stays '
            . 'reproducible after the preview cache has forgotten it.',
    },
);

sub params
{
    my %spec = @PARAM;
    return \%spec;
}

=head2 param_order()

The names in the order they should be shown, which is not alphabetical: length
first because it is the only one that changes what you get rather than how it
sounds.

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

The requested length. Unlike a dialled phrase, static has no natural end --
this is a setting rather than a consequence.

=cut

sub duration
{
    my ( $spec ) = @_;

    return 0 unless ref $spec eq 'HASH';

    # A floor rather than a declared minimum: the parameter is unbounded so
    # that it gets a spin button, which leaves nothing to stop a zero.
    my $seconds = $spec->{ seconds };
    return 10 unless defined $seconds && $seconds > 0;

    return $seconds;
}

=head2 pcm( $spec, $fill_to )

Packed 16-bit mono samples at L</RATE>.

C<$fill_to> overrides the requested length, which is how an audio track
present in the same mix decides how long everything runs. Static has nothing
to loop or run out of, so covering a longer stretch is simply generating more
of it -- there is no seam to hide.

=cut

sub pcm
{
    my ( $spec, $fill_to ) = @_;

    my $seconds = $fill_to;
    $seconds = duration( $spec ) unless $seconds && $seconds > 0;

    my $count = int( RATE * $seconds );
    return q{} unless $count > 0;

    my $rng = GlitchVape::Random->new( seed => $spec->{ seed } // 1 );

    my $gain    = $spec->{ gain }    // 0.5;
    my $drift   = $spec->{ drift }   // 0.3;
    my $hum     = $spec->{ hum }     // 0.15;
    my $crackle = $spec->{ crackle } // 0.2;

    # Logarithmic sweep of the low-pass corner. The one-pole coefficient for a
    # corner frequency f is the standard RC form, worked out once rather than
    # per sample.
    my $tone   = $spec->{ tone } // 0.35;
    my $corner = 700 * ( 7000 / 700 )**$tone;
    my $alpha  = 1 - exp( -2 * $PI * $corner / RATE );

    # And a fixed high-pass to take out the rumble a one-pole low-pass leaves
    # behind, so the hum has somewhere to sit.
    my $hp_alpha = 1 - exp( -2 * $PI * 90 / RATE );

    # Two drift oscillators at unrelated rates, so the swell does not settle
    # into an audible pulse the way a single one does.
    my $drift_a = 2 * $PI * 0.13 / RATE;
    my $drift_b = 2 * $PI * 0.37 / RATE;

    my $hum_step = 2 * $PI * HUM_HZ / RATE;

    # Probability per sample of a crackle starting. Scaled so the top of the
    # slider is busy rather than continuous.
    my $crackle_chance = $crackle * 12 / RATE;
    my $crackle_len    = int( RATE * CRACKLE_MS / 1000 );
    my $crackle_left   = 0;

    my ( $p0, $p1, $p2 ) = ( 0, 0, 0 );
    my $low  = 0;
    my $high = 0;

    my @sample;

    for my $n ( 0 .. $count - 1 )
    {
        my $white = $rng->rand( 2 ) - 1;

        $p0 = $PINK_POLE[ 0 ] * $p0 + $white * $PINK_GAIN[ 0 ];
        $p1 = $PINK_POLE[ 1 ] * $p1 + $white * $PINK_GAIN[ 1 ];
        $p2 = $PINK_POLE[ 2 ] * $p2 + $white * $PINK_GAIN[ 2 ];

        my $value = ( $p0 + $p1 + $p2 + $white * PINK_DIRECT ) * PINK_TRIM;

        # One-pole low-pass, then subtract a one-pole low-pass of the result
        # to get the high-pass: two lines for a band-pass, and both states are
        # scalars rather than arrays.
        $low  += $alpha * ( $value - $low );
        $high += $hp_alpha * ( $low - $high );

        $value = $low - $high;

        if ( $crackle_left > 0 )
        {
            # Crackles are deliberately not band-limited: their whole
            # character is that they get through when the rest does not.
            $value += ( $rng->rand( 2 ) - 1 ) * 0.5;
            $crackle_left--;
        }
        elsif ( $crackle_chance > 0 && $rng->rand < $crackle_chance )
        {
            $crackle_left = $crackle_len;
        }

        if ( $drift )
        {
            $value *=
                1 +
                $drift * 0.45 * ( sin( $n * $drift_a ) + sin( $n * $drift_b ) )
                / 2;
        }

        if ( $hum )
        {
            my $phase = $n * $hum_step;
            $value +=
                $hum * 0.10 * ( sin( $phase ) + 0.4 * sin( 2 * $phase ) );
        }

        push @sample, GlitchVape::Wav::quantise( $value * $gain );
    }

    _fade( \@sample );

    return pack 's<*', @sample;
}

# Static that starts and stops at full level clicks like any other cut. Twenty
# milliseconds is inaudible as a fade and enough to remove it.
sub _fade
{
    my ( $sample ) = @_;

    my $ramp = int( RATE * 0.02 );
    $ramp = int( @$sample / 2 ) if $ramp > @$sample / 2;
    return unless $ramp > 0;

    for my $n ( 0 .. $ramp - 1 )
    {
        my $factor = 0.5 - 0.5 * cos( $PI * $n / $ramp );

        $sample->[ $n ] = int( $sample->[ $n ] * $factor );
        $sample->[ -1 - $n ] = int( $sample->[ -1 - $n ] * $factor );
    }

    return;
}

=head2 render( %arg )

    spec    => the static spec
    output  => path to write, .wav
    fill_to => seconds to cover

=cut

sub render
{
    my ( %arg ) = @_;

    my $spec = $arg{ spec }
        or die "GlitchVape::Noise: no spec given\n";
    my $output = $arg{ output }
        or die "GlitchVape::Noise: no output given\n";

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

    return 'static' unless ref $spec eq 'HASH';

    my $tone = $spec->{ tone } // 0.35;

    # The number means nothing to anybody; what it sounds like does.
    my $character = 'distant';
    $character = 'muffled' if $tone >= 0.2;
    $character = 'open'    if $tone >= 0.45;
    $character = 'harsh'   if $tone >= 0.75;

    my $line = sprintf 'static  %s  %s', $character, _mmss( duration( $spec ) );

    my @extra;
    push @extra, 'hum'     if ( $spec->{ hum }     // 0.15 ) > 0.02;
    push @extra, 'crackle' if ( $spec->{ crackle } // 0.2 ) > 0.02;

    $line .= '  ' . join ' + ', @extra if @extra;

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

L<GlitchVape::Generator>, which registers this as a kind of track, and
L<GlitchVape::Wav>, where the samples end up.

=cut
