package GlitchVape::Drive;

use strict;
use warnings;
use utf8;

use GlitchVape::Random ();
use GlitchVape::Wav    ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Drive - a hard disk working, under a fan

=head1 DESCRIPTION

A spinning-platter drive: the whirr of the fan and the spindle underneath, and
on top of it the chirps of the head assembly being flung across the platter
and stopped.

=head2 Why a drive is worth synthesising rather than sampling

Because almost none of what makes it recognisable is timbre. A recording of
one seek is one seek; what says I<hard disk> is the I<pattern> -- long quiet,
then a rattle, then quiet again -- and a pattern is a thing you can only get
right by generating it.

=head2 Activity comes in bursts

The part worth protecting. Seeks are not a Poisson process the way Geiger
clicks are: a drive is idle almost all the time, and then something reads a
file and the head moves twenty times in half a second. Drawing gaps from one
distribution gives an even scatter of ticks, which reads as a metronome with a
fault -- exactly the failure L<GlitchVape::Geiger> avoids by going the other
way.

So there are two states. Idle waits an exponential gap. A burst is a run of
seeks a few tens of milliseconds apart, and the run length is geometric, so
most bursts are short and the occasional one goes on and on. That alternation
is the whole sound.

=head2 A seek's pitch is how far the head went

The other half. A drive's head is a mass on a voice coil: driven hard, moved,
and stopped. A short hop is a tick; a long sweep across the platter is a lower,
longer C<brrp>. Both are the same mechanism ringing, so both are a swept
resonance -- it is the sweep that makes it a chirp rather than a click.

Seek time goes as roughly the square root of the distance, because the
actuator spends the move accelerating and then decelerating rather than
travelling at a speed. That is modelled, and it is why a drive reading one
file sounds different from one being defragmented: the same drive, a different
distribution of distances.

=head2 The bed is not just noise

A fan is broadband air noise I<plus> a tone at its blade-pass frequency --
blades times revolutions per second -- and a drive adds the spindle's own
rotation under that. Noise alone is a hiss; the tones are what make it a
machine. They are kept faint, because a fan you can hear the pitch of is a fan
with something wrong with it.

=cut

use constant RATE => GlitchVape::Wav::RATE;

# A seven-bladed fan, which is what a small one has, running at a fraction of
# the spindle's speed the way a case fan does.
use constant BLADES    => 7;
use constant FAN_SHARE => 0.42;

# How long a seek takes: a floor for the shortest hop, and how much the
# longest one adds on top. Both from what a drive of the period actually did --
# a track-to-track seek around a millisecond, a full stroke around twenty.
use constant SEEK_MIN_S  => 0.0015;
use constant SEEK_SPAN_S => 0.019;

# The resonance the actuator rings at, swept down over the move. A short hop
# starts near the top of this and a full stroke near the bottom.
use constant RING_HI => 2800;
use constant RING_LO => 950;

# Where the sweep ends, as a fraction of where it started.
use constant SWEEP_TO => 0.45;

# Gaps within a burst, and how long a burst tends to run.
use constant BURST_GAP_S  => 0.012;
use constant BURST_SPAN_S => 0.055;
use constant BURST_STAY   => 0.82;

my $PI = 3.14159265358979;

=head2 params()

The declaration this generator is built from, in display order.

=cut

my @PARAM = (
    seconds => {

        # Unbounded, for the reason Geiger's is: a range-less number gets a
        # spin button, and a slider spanning ten minutes is unusable at the
        # ten-second end where it is actually wanted.
        label   => 'Length',
        type    => 'int',
        default => 20,
        doc     => 'How long the drive runs when nothing else sets the '
            . 'length. With an audio track present the track decides, and '
            . 'the drive simply carries on working.',
    },
    activity => {
        label   => 'Activity',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.35,
        doc     => 'How often the drive is asked for something. At 0 it '
            . 'spins and nothing else; at 1 it barely stops. What changes is '
            . 'the quiet between bursts, not the bursts themselves.',
    },
    travel => {
        label   => 'Head travel',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.3,
        doc     => 'How far the head goes. Low is one file being read and '
            . 'sounds like ticking; high is the whole platter and sounds '
            . 'like a defragment, because a longer seek is a longer and '
            . 'lower chirp.',
    },
    fan => {
        label   => 'Fan',
        type    => 'num',
        min     => 0,
        max     => 1,
        default => 0.4,
        doc     => 'The whirr behind it all: air noise, the fan\'s blade '
            . 'tone and the spindle, in that order of loudness. At 0 there '
            . 'is only the drive working in silence.',
    },
    rpm => {
        label   => 'Spindle',
        type    => 'int',
        min     => 1800,
        max     => 15_000,
        default => 5400,
        doc     => 'Revolutions per minute, which sets the pitch of the '
            . 'whine and of the fan tone under it. 3600 is an old drive, '
            . '5400 a quiet one, 7200 a desktop, 15000 something in a rack.',
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
        doc     => 'The same seed gives the same work, so a render stays '
            . 'reproducible after the preview cache has forgotten it.',
    },
);

sub params
{
    my %spec = @PARAM;
    return \%spec;
}

=head2 param_order()

The names in the order they should be shown: length first, because it is the
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

The requested length. A drive has no natural end, so this is a setting rather
than a consequence.

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

=head2 seeks( $spec, $seconds )

When the head moves and how far, as C<< [ [ $at_seconds, $distance ], ... ] >>
with C<$distance> in platters -- 0 for a track-to-track hop and 1 for a full
stroke.

Separated out because it is the half worth checking, and checking it by
listening to a wave file is not checking it. See
L</Activity comes in bursts>.

=cut

sub seeks
{
    my ( $spec, $seconds ) = @_;

    my $rng = GlitchVape::Random->new( seed => $spec->{ seed } // 1 );

    my $activity = _clamp( $spec->{ activity }, 0, 1, 0.35 );
    my $travel   = _clamp( $spec->{ travel },   0, 1, 0.3 );

    return [] unless $activity > 0;

    # The mean quiet between bursts, in seconds. Five seconds of nothing at
    # the bottom of the slider and a tenth of a second at the top.
    my $idle = 5 * ( 0.02 / 5 )**$activity;

    my @seek;
    my $now  = 0;
    my $head = $rng->rand( 1 );

    while ( $now < $seconds )
    {
        $now += -log( $rng->rand( 1 ) || 1e-9 ) * $idle;
        last if $now >= $seconds;

        # One burst. Geometric length, so most are a handful of seeks and
        # every so often one runs on -- which is what a large file being read
        # sounds like against a directory being stat'ed.
        while ( $now < $seconds )
        {
            my $to = _next_track( $rng, $head, $travel );

            push @seek, [ $now, abs( $to - $head ) ];
            $head = $to;

            last unless $rng->chance( BURST_STAY );

            $now += BURST_GAP_S + $rng->rand( BURST_SPAN_S );
        }
    }

    return \@seek;
}

# Where the head goes next. Mostly a short hop from where it is, because
# reading a file is reading consecutive tracks; occasionally right across,
# because something else wanted something else.
sub _next_track
{
    my ( $rng, $head, $travel ) = @_;

    my $to =
          $rng->chance( 0.12 + 0.5 * $travel )
        ? $rng->rand( 1 )
        : $head + $rng->gauss( 0, 0.02 + 0.35 * $travel );

    $to = 0 if $to < 0;
    $to = 1 if $to > 1;

    return $to;
}

=head2 pcm( $spec, $fill_to )

Packed 16-bit mono samples at C<RATE>, which is CD rate: the sharpness of a
chirp is its content, and band-limiting one turns it into a thud.

C<$fill_to> overrides the requested length, which is how an audio track in the
same mix decides how long everything runs. There is nothing to loop, so
covering a longer stretch is simply leaving the machine on for longer.

=cut

sub pcm
{
    my ( $spec, $fill_to ) = @_;

    my $seconds = $fill_to;
    $seconds = duration( $spec ) unless $seconds && $seconds > 0;

    my $count = int( RATE * $seconds );
    return q{} unless $count > 0;

    my $gain = _clamp( $spec->{ gain }, 0, 2, 0.7 );

    my @sample = ( 0 ) x $count;

    _lay_bed( \@sample, $spec );

    my $rng = GlitchVape::Random->new( seed => ( $spec->{ seed } // 1 ) + 1 );

    for my $seek ( @{ seeks( $spec, $seconds ) } )
    {
        _chirp( \@sample, int( $seek->[ 0 ] * RATE ), $seek->[ 1 ], $rng );
    }

    return pack 's<*', map { GlitchVape::Wav::quantise( $_ * $gain ) } @sample;
}

# The whirr. Air noise low-passed to a rumble, the fan's blade tone over it
# and the spindle under that, all faint -- see L</The bed is not just noise>.
sub _lay_bed
{
    my ( $sample, $spec ) = @_;

    my $fan = _clamp( $spec->{ fan }, 0, 1, 0.4 );
    return unless $fan > 0;

    my $rng = GlitchVape::Random->new( seed => ( $spec->{ seed } // 1 ) + 2 );

    my $rpm    = _clamp( $spec->{ rpm }, 1800, 15_000, 5400 );
    my $spin   = $rpm / 60;
    my $fan_hz = $spin * FAN_SHARE * BLADES;

    # A one-pole low-pass at 260 Hz, which is where a whirr stops being a
    # hiss, and a matching high-pass so it is a whirr rather than a thud.
    my $low_a  = 1 - exp( -2 * $PI * 260 / RATE );
    my $high_a = 1 - exp( -2 * $PI * 40 / RATE );

    my $blade_step = 2 * $PI * $fan_hz / RATE;
    my $spin_step  = 2 * $PI * $spin / RATE;

    # Two unrelated wobbles, so the whirr breathes instead of pulsing.
    my $wob_a = 2 * $PI * 0.09 / RATE;
    my $wob_b = 2 * $PI * 0.23 / RATE;

    my ( $low, $high ) = ( 0, 0 );

    for my $n ( 0 .. $#$sample )
    {
        my $white = $rng->rand( 2 ) - 1;

        $low  += $low_a * ( $white - $low );
        $high += $high_a * ( $low - $high );

        my $air = $low - $high;

        my $wobble = 1 + 0.18 * sin( $wob_a * $n ) + 0.11 * sin( $wob_b * $n );

        # Blade tone with a second harmonic, and the spindle an octave-ish
        # below it. Both well under the air, which is the order they come in
        # on a machine that is working properly.
        my $tone =
            0.16 * sin( $blade_step * $n ) +
            0.06 * sin( 2 * $blade_step * $n ) +
            0.09 * sin( $spin_step * $n );

        $sample->[ $n ] += $fan * 0.25 * ( $air * 3.2 + $tone ) * $wobble;
    }

    return;
}

# One seek, added in place. A two-pole resonator driven by noise, with its
# resonance swept downward across the move -- which is what turns a click into
# a chirp, and the sweep is the sound of the actuator settling.
sub _chirp
{
    my ( $sample, $at, $distance, $rng ) = @_;

    return if $at < 0 || $at >= @$sample;

    $distance = 0 if $distance < 0;
    $distance = 1 if $distance > 1;

    # Square root, because the actuator accelerates and then decelerates
    # rather than travelling at a speed: four times the distance is twice the
    # time, not four times.
    my $span   = SEEK_MIN_S + SEEK_SPAN_S * sqrt( $distance );
    my $length = int( RATE * $span );
    return unless $length > 1;

    my $start = RING_HI + ( RING_LO - RING_HI ) * $distance;
    my $end   = $start * SWEEP_TO;

    # How ringy: a long move rattles the whole assembly and rings longer.
    my $r = 0.982 + 0.012 * $distance;

    my $level = 0.55 + $rng->rand( 0.35 );

    my ( $y1, $y2 ) = ( 0, 0 );

    for my $n ( 0 .. $length - 1 )
    {
        my $i = $at + $n;
        last if $i >= @$sample;

        my $through = $n / $length;

        my $hz = $start + ( $end - $start ) * $through;
        my $w  = 2 * $PI * $hz / RATE;

        # Fast in, slow out: the coil is driven hard at the start of the move
        # and everything after that is the mechanism settling.
        my $envelope =
              $through < 0.06
            ? $through / 0.06
            : exp( -4.2 * ( $through - 0.06 ) );

        # Normalised by (1 - r squared), because a two-pole resonator's gain
        # at its own frequency goes as 1/(1-r) -- at the ringiest end of the
        # range that is a factor of eighty, and an unnormalised one does not
        # come out loud, it comes out clipped. Which it did.
        my $drive = ( $rng->rand( 2 ) - 1 ) * $envelope * ( 1 - $r * $r );

        my $y = $drive + 2 * $r * cos( $w ) * $y1 - $r * $r * $y2;

        $y2 = $y1;
        $y1 = $y;

        $sample->[ $i ] += $y * $level * 1.1;
    }

    return;
}

=head2 render( %arg )

    spec    => the drive spec
    output  => path to write, .wav
    fill_to => seconds to cover

=cut

sub render
{
    my ( %arg ) = @_;

    my $spec = $arg{ spec }
        or die "GlitchVape::Drive: no spec given\n";
    my $output = $arg{ output }
        or die "GlitchVape::Drive: no output given\n";

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

    return 'drive' unless ref $spec eq 'HASH';

    my $activity = $spec->{ activity } // 0.35;

    # What the machine is doing, rather than a number nobody standing beside
    # one would know.
    my $doing = 'idle';
    $doing = 'ticking'   if $activity >= 0.15;
    $doing = 'working'   if $activity >= 0.45;
    $doing = 'thrashing' if $activity >= 0.8;

    my $line = sprintf 'drive  %s  %s  %d rpm', $doing,
        _mmss( duration( $spec ) ), $spec->{ rpm } // 5400;

    $line .= '  no fan' unless ( $spec->{ fan } // 0.4 ) > 0;

    return $line;
}

sub _clamp
{
    my ( $value, $low, $high, $fallback ) = @_;

    $value = $fallback unless defined $value;
    $value = $low  if $value < $low;
    $value = $high if $value > $high;

    return $value;
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
L<GlitchVape::Geiger> for the other one whose timing is the point of it, and
L<GlitchVape::Wav>, where the samples end up.

=cut
