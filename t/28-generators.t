#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;

use GlitchVape::Drive     ();
use GlitchVape::Generator ();
use GlitchVape::Geiger    ();
use GlitchVape::Heart     ();
use GlitchVape::Random    ();
use GlitchVape::Wav       ();

# The generators whose point is their timing rather than their timbre. What is
# pinned here is the timing: a Geiger counter that ticks evenly is not a Geiger
# counter, a heartbeat with equal gaps is a drum loop, and a hard disk that
# seeks at a steady rate is a metronome in a box.

# The gaps between one drive's seeks, in seconds.
sub seek_gaps
{
    my ( $seek ) = @_;

    return map { $seek->[ $_ ][ 0 ] - $seek->[ $_ - 1 ][ 0 ] } 1 .. $#$seek;
}

# One seek on its own: how long it rings for, roughly what pitch, and how
# loud. Zero crossings stand in for pitch, as a rate rather than a count --
# the chirps being compared are different lengths, so counting over a fixed
# window counts silence for one of them and they come out equal.
sub one_seek
{
    my ( $distance ) = @_;

    my @sample = ( 0 ) x int( GlitchVape::Drive::RATE * 0.2 );
    my $rng    = GlitchVape::Random->new( seed => 4 );

    ## no critic (Subroutines::ProtectPrivateSubs)
    GlitchVape::Drive::_chirp( \@sample, 10, $distance, $rng );
    ## use critic

    my $ends = 0;
    my $peak = 0;
    for my $n ( 0 .. $#sample )
    {
        next unless abs $sample[ $n ] > 0.002;

        $ends = $n;
        $peak = abs $sample[ $n ] if abs $sample[ $n ] > $peak;
    }

    my $crossings = 0;
    for my $n ( 11 .. $ends )
    {
        $crossings++ if ( $sample[ $n ] >= 0 ) != ( $sample[ $n - 1 ] >= 0 );
    }

    my $hz =
          $ends > 11
        ? $crossings * GlitchVape::Drive::RATE / ( 2 * ( $ends - 10 ) )
        : 0;

    return ( $ends, $hz, $peak );
}

# ---------------------------------------------------------------------------
# Both are registered, and the interface can find an icon without being told

# A mapping from kind to icon used to live in GlitchVape::GUI, in two copies
# that had begun to disagree. It is declared now, which is what keeps adding a
# kind to one register() call.
{
    my %kind = map { $_ => 1 } GlitchVape::Generator::kinds();

    ok $kind{ geiger }, 'geiger is a registered kind';
    ok $kind{ heart },  'heart is a registered kind';
    ok $kind{ drive },  'drive is a registered kind';

    for my $k ( GlitchVape::Generator::kinds() )
    {
        my $icon = GlitchVape::Generator::icon( $k );
        ok defined $icon && length $icon, "$k declares an icon";
    }

    isnt GlitchVape::Generator::icon( 'geiger' ),
        GlitchVape::Generator::icon( 'heart' ),
        'and two kinds do not share one';

    # An unknown kind still gets something rather than dying: the interface
    # asks before it has any reason to believe the kind exists.
    ok GlitchVape::Generator::icon( 'nonesuch' ),
        'an unknown kind falls back rather than failing';
}

# ---------------------------------------------------------------------------
# Geiger: the clicks are a Poisson process, not a metronome

# Recorded at the point they are scheduled rather than detected in the audio.
# Once the rate is high enough for dead time to matter the clicks overlap, and
# no onset detector can separate them -- which would make the test measure the
# detector rather than the generator.
my @CLICKS;

# Reaching into another package's private sub on purpose: the point of this
# file is when the clicks are scheduled, and the only alternative -- detecting
# them in the audio -- stops working at exactly the rates the dead-time tests
# are about.
## no critic (Variables::ProtectPrivateVars)
my $REAL_CLICK = \&GlitchVape::Geiger::_click;

# Kept so it can be put back: with the recorder in place pcm() writes silence,
# which would make the reproducibility checks at the foot of this file pass
# for the wrong reason -- two empty buffers are equal whatever the seed was.
sub record_clicks
{
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    *GlitchVape::Geiger::_click = sub {
        push @CLICKS, $_[ 1 ] / GlitchVape::Geiger::RATE;
        return;
    };
    return;
}

sub real_clicks
{
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    *GlitchVape::Geiger::_click = $REAL_CLICK;
    return;
}
## use critic

record_clicks();

sub click_times
{
    my ( %spec ) = @_;

    @CLICKS = ();
    GlitchVape::Geiger::pcm( { seed => 5, %spec } );

    return @CLICKS;
}

{
    my @t =
        click_times( seconds => 60, strength => 8, baseline => 8, speed => 0 );

    cmp_ok scalar @t, '>', 100, 'a minute at eight a second produces clicks';

    my @gap = map { $t[ $_ + 1 ] - $t[ $_ ] } 0 .. $#t - 1;

    my $mean = 0;
    $mean += $_ for @gap;
    $mean /= @gap;

    my @sorted = sort { $a <=> $b } @gap;
    my $median = $sorted[ int( @sorted / 2 ) ];

    # An exponential distribution has median = ln(2) * mean, about 0.693 of
    # it. Evenly spaced clicks would put the ratio at 1. This is the whole
    # character of the sound in one number: it is why the clicks clump.
    my $ratio = $median / $mean;

    cmp_ok $ratio, '>', 0.55, 'the gaps between clicks are exponentially '
        . 'distributed, not uniform (lower bound)';
    cmp_ok $ratio, '<', 0.85, 'the gaps between clicks are exponentially '
        . 'distributed, not uniform (upper bound)';

    # And the mean gap is the reciprocal of the rate asked for.
    cmp_ok abs( $mean - 1 / 8 ), '<', 0.02,
        'and their mean matches the requested rate';
}

# ---------------------------------------------------------------------------
# Geiger: dead time makes a strong source saturate

# A real tube is insensitive for a moment after each discharge, so the counts
# it reports fall behind the particles arriving. That is why a hot source
# buzzes rather than merely ticking faster, and the standard non-paralysable
# model says how far behind: m = n / (1 + n * dead).

{
    my $dead = GlitchVape::Geiger::DEAD_S;

    for my $nominal ( 100, 500, 2000 )
    {
        my @t = click_times(
            seconds  => 10,
            strength => $nominal,
            baseline => $nominal,
            speed    => 0
        );

        my $observed = @t / 10;
        my $expected = $nominal / ( 1 + $nominal * $dead );

        cmp_ok abs( $observed - $expected ) / $expected, '<', 0.05,
            "at $nominal counts a second the observed rate follows the "
            . 'non-paralysable dead-time model';
    }

    # At the top of that range the loss is large enough to hear, which is the
    # point of modelling it at all.
    my @t = click_times(
        seconds  => 10,
        strength => 2000,
        baseline => 2000,
        speed    => 0
    );

    cmp_ok @t / 10, '<', 2000 * 0.85,
        'and a very strong source loses a good fraction of its counts';
}

# ---------------------------------------------------------------------------
# Geiger: the source wanders, and standing still means standing still

{
    my $count_in_halves = sub {
        my ( @t ) = @_;

        my ( $early, $later ) = ( 0, 0 );
        for my $x ( @t )
        {
            if   ( $x < 10 ) { $early++ }
            else             { $later++ }
        }
        return ( $early, $later );
    };

    # Speed 0 is a fixed distance, so the two halves should agree closely.
    my @still = click_times(
        seconds  => 20,
        strength => 40,
        baseline => 40,
        speed    => 0
    );
    my ( $a, $b ) = $count_in_halves->( @still );

    cmp_ok abs( $a - $b ) / ( ( $a + $b ) / 2 ), '<', 0.2,
        'at movement 0 the rate is steady across the track';

    # Moving, the rate should visibly differ between one stretch and another.
    # Measured as the spread across five buckets rather than two, because two
    # can agree by coincidence at any speed.
    my @moving = click_times(
        seconds  => 40,
        strength => 200,
        baseline => 1,
        speed    => 0.6
    );

    my @bucket = ( 0 ) x 8;
    for my $x ( @moving )
    {
        my $n = int( $x / 5 );
        $n = 7 if $n > 7;
        $bucket[ $n ]++;
    }

    my ( $lo, $hi ) = ( $bucket[ 0 ], $bucket[ 0 ] );
    for my $n ( @bucket )
    {
        $lo = $n if $n < $lo;
        $hi = $n if $n > $hi;
    }

    cmp_ok $hi, '>', $lo * 2,
        'and moving, some stretches are far busier than others';
}

# ---------------------------------------------------------------------------
# Heart: the gap inside a beat is shorter than the gap between beats

# This is the single thing that separates a heartbeat from a drum machine.
#
# Read off the schedule rather than out of the audio, the same way the Geiger
# clicks above are. It used to detect onsets in the sample buffer, and that
# worked only while the thuds were sharp: softening the attack and lengthening
# the decay -- which is what makes a heartbeat sound like one heard through a
# chest rather than through a stethoscope -- left the tail crossing the
# threshold twice at the top of the rate range, and the timing tests failed on
# a sound whose timing had not changed at all.
#
# What these tests are about is when the thuds are scheduled. Asking _thud
# directly says exactly that, and says it whatever the thuds end up sounding
# like.

my @THUDS;

sub thud_times
{
    my ( %spec ) = @_;

    @THUDS = ();

    {
        no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        ## no critic (Variables::ProtectPrivateVars)
        local *GlitchVape::Heart::_thud = sub {
            push @THUDS, $_[ 1 ] / GlitchVape::Heart::RATE;
            return;
        };
        ## use critic

        GlitchVape::Heart::pcm( { seed => 1, sway => 0, %spec } );
    }

    my @at = sort { $a <=> $b } @THUDS;

    return @at;
}

# systole and diastole, as the mean of the short gaps and of the long ones.
sub split_gaps
{
    my ( @at ) = @_;

    my @gap    = map  { $at[ $_ + 1 ] - $at[ $_ ] } 0 .. $#at - 1;
    my @sorted = sort { $a <=> $b } @gap;
    my $median = $sorted[ int( @sorted / 2 ) ];

    my ( $short, $ns, $long, $nl ) = ( 0, 0, 0, 0 );
    for my $g ( @gap )
    {
        if   ( $g < $median ) { $short += $g; $ns++ }
        else                  { $long  += $g; $nl++ }
    }

    return ( 0,            0 ) unless $ns && $nl;
    return ( $short / $ns, $long / $nl );
}

{
    my @at = thud_times( seconds => 12, bpm => 60 );

    cmp_ok scalar @at, '>', 20, 'a heartbeat produces two sounds a beat';

    my ( $systole, $diastole ) = split_gaps( @at );

    cmp_ok $diastole, '>', $systole,
        'the pause between beats is longer than the beat itself';

    # At rest it is roughly a third and two thirds, which is what makes the
    # rhythm read as lub-dub rather than as an even four.
    cmp_ok $diastole / $systole, '>', 1.8,
        'and at 60 bpm it is more than half as long again';

    cmp_ok abs( $systole - GlitchVape::Heart::SYSTOLE_AT_60 ), '<', 0.02,
        'systole at 60 bpm is the declared constant';
}

# ---------------------------------------------------------------------------
# Heart: speeding it up squeezes out the pause, not the beat

# Which is why a racing heart sounds urgent rather than merely quick. If both
# gaps shrank together, a fast heartbeat would be a slow one played faster and
# would carry no more alarm than a metronome does.

{
    my ( $slow_s, $slow_d ) =
        split_gaps( thud_times( seconds => 12, bpm => 60 ) );
    my ( $fast_s, $fast_d ) =
        split_gaps( thud_times( seconds => 12, bpm => 150 ) );

    cmp_ok $slow_d / $slow_s, '>', $fast_d / $fast_s,
        'the beat takes up more of the cycle as the rate rises';

    cmp_ok $fast_d / $fast_s, '<', 1.4,
        'and by 150 bpm the pause has all but gone';

    # Systole shortens too, but far less than the cycle does: between those
    # two rates the cycle falls to 40% of its length and systole to about 63%,
    # which is the square-root scaling.
    cmp_ok $fast_s / $slow_s, '>', 0.5,
        'systole shortens by much less than the cycle does';
}

# ---------------------------------------------------------------------------
# Both are reproducible, and both cover whatever length they are asked for

{
    # Clicks are written again from here on; see record_clicks above.
    real_clicks();

    for my $mod ( 'GlitchVape::Geiger', 'GlitchVape::Heart' )
    {
        my $pcm = $mod->can( 'pcm' );

        is $pcm->( { seconds => 2, seed => 9 } ),
            $pcm->( { seconds => 2, seed => 9 } ),
            "$mod gives the same samples for the same seed";

        isnt $pcm->( { seconds => 2, seed => 9 } ),
            $pcm->( { seconds => 2, seed => 10 } ),
            'and different samples for a different one';

        # fill_to is how an audio file in the same mix decides the length.
        # Neither of these has anything to loop, so covering longer is simply
        # going on for longer.
        my $rate = $mod->can( 'RATE' )->();
        my $long = $pcm->( { seconds => 2, seed => 9 }, 5 );

        is length $long, $rate * 5 * 2,
            'and fills to the length the mix asks for';
    }
}

# ---------------------------------------------------------------------------
# The rows they produce say something a person can act on

{
    like GlitchVape::Geiger::describe( { strength => 300, seconds => 10 } ),
        qr/hot/, 'a strong source describes itself as hot';
    like GlitchVape::Geiger::describe( { strength => 5, seconds => 10 } ),
        qr/quiet/, 'and a weak one as quiet';

    like GlitchVape::Heart::describe( { bpm => 150, seconds => 10 } ),
        qr/racing/, 'a fast heartbeat describes itself as racing';
    like GlitchVape::Heart::describe( { bpm => 70, seconds => 10 } ),
        qr/resting/, 'and a slow one as resting';

    # The ± is a non-ASCII literal, and a module without `use utf8` would
    # hand back the bytes rather than the character -- which reaches the
    # status line as mojibake.
    my $line = GlitchVape::Heart::describe( { bpm => 70, sway => 15 } );
    like $line, qr/\N{PLUS-MINUS SIGN}15/,
        'and the fluctuation is reported as a character, not as bytes';
}

# ---------------------------------------------------------------------------
# A drive's seeks come in bursts, which is what says hard disk

# The one thing that makes the sound recognisable, and the one an even
# scattering of ticks would lose. A drive is idle almost all the time and then
# something reads a file and the head moves twenty times in half a second, so
# the gaps have to be bimodal: a cloud of short ones inside bursts and a
# handful of long ones between them.
#
# Asked of the seek schedule rather than of the samples, because a rattle of
# seeks fifteen milliseconds apart overlaps in the wave and no onset detector
# would separate them -- the same reason t/28's Geiger tests read the click
# schedule instead of the audio.
{
    my $spec = {
        seconds  => 60,
        activity => 0.35,
        travel   => 0.3,
        seed     => 5,
    };

    my $seek = GlitchVape::Drive::seeks( $spec, 60 );

    cmp_ok scalar @$seek, '>', 30, 'a drive at rest still does some work';

    my @gap = seek_gaps( $seek );

    my $inside  = grep { $_ < 0.1 } @gap;
    my $between = grep { $_ > 0.5 } @gap;

    cmp_ok $inside,  '>', 0.5 * scalar @gap, 'most gaps are inside a burst';
    cmp_ok $between, '>', 2, 'and some are the quiet between bursts';

    # Which is the bit an even scatter would fail: the longest quiet has to be
    # many times the typical gap, not a few times it.
    my @sorted = sort { $a <=> $b } @gap;
    my $median = $sorted[ $#sorted / 2 ];

    cmp_ok $sorted[ -1 ], '>', 10 * $median,
        'and the longest quiet dwarfs the usual gap, as an idle drive does';
}

# ---------------------------------------------------------------------------
# Activity changes the quiet, not the bursts

# Turning it up should mean the drive is asked for something more often, not
# that it seeks faster while it is working -- a drive's seek rate inside a
# burst is a property of the drive.
{
    my $busy = sub {
        my ( $activity ) = @_;

        my $seek = GlitchVape::Drive::seeks(
            { seconds => 60, activity => $activity, travel => 0.3, seed => 9 },
            60
        );

        my @gap = seek_gaps( $seek );

        my @inside = sort { $a <=> $b } grep { $_ < 0.1 } @gap;

        return ( scalar @$seek, $inside[ $#inside / 2 ] );
    };

    my ( $quiet, $quiet_gap ) = $busy->( 0.1 );
    my ( $loud,  $loud_gap )  = $busy->( 0.9 );

    cmp_ok $loud, '>', 3 * $quiet, 'a busy drive does far more work';

    cmp_ok abs( $loud_gap - $quiet_gap ), '<', 0.01,
        'but the seeks inside a burst are as far apart either way';

    is_deeply GlitchVape::Drive::seeks(
        { seconds => 60, activity => 0, seed => 9 }, 60
        ),
        [], 'and at nothing at all it only spins';
}

# ---------------------------------------------------------------------------
# A longer seek is a longer, lower chirp

# The other half of what makes it a drive rather than a click track. The head
# is a mass on a coil: a hop is a tick and a full stroke is a lower brrp, and
# seek time goes as roughly the square root of the distance because the
# actuator spends the move speeding up and then slowing down.
{

    my ( $hop_len,  $hop_pitch,  $hop_peak )  = one_seek( 0.02 );
    my ( $full_len, $full_pitch, $full_peak ) = one_seek( 1 );

    cmp_ok $full_len, '>', 2 * $hop_len,
        'a full stroke rings far longer than a hop';

    cmp_ok $full_pitch, '<', 0.75 * $hop_pitch,
        'and audibly lower, which is the actuator driven harder for longer'
        or diag sprintf 'hop %.0f Hz, full stroke %.0f Hz', $hop_pitch,
        $full_pitch;

    # Nothing anywhere near full scale, at any distance. An unnormalised
    # two-pole resonator has a gain of eighty at the ringiest end of the
    # range, and what came out was not loud, it was clipped.
    for my $distance ( 0, 0.25, 0.5, 0.75, 1 )
    {
        my ( undef, undef, $peak ) = one_seek( $distance );

        cmp_ok $peak, '<', 0.8,
            "a seek of $distance leaves headroom rather than clipping";
    }
}

# ---------------------------------------------------------------------------
# The whole thing comes out as audio, and stays inside the rails

{
    my $spec = {
        seconds  => 3,
        activity => 1,
        travel   => 1,
        fan      => 1,
        rpm      => 7200,
        gain     => 1,
        seed     => 2,
    };

    my $pcm = GlitchVape::Drive::pcm( $spec );

    is length( $pcm ) / 2, int( GlitchVape::Drive::RATE * 3 ),
        'three seconds of samples come out of a three second drive';

    # Every part of the sound at its loudest, at unity. What the generator
    # mixes for itself has to fit; gain above 1 is the caller asking for more
    # than fits, and quantise clamps that rather than wrapping it.
    my $clipped = grep { abs $_ >= 32_767 } unpack 's<*', $pcm;

    is $clipped, 0, 'and with every part of it at its loudest, nothing clips';

    is GlitchVape::Drive::pcm( { %$spec, seed => 2 } ), $pcm,
        'the same seed gives the same drive';

    isnt GlitchVape::Drive::pcm( { %$spec, seed => 3 } ), $pcm,
        'and a different one does not';

    my $fanless = GlitchVape::Drive::pcm( { %$spec, fan => 0, activity => 0 } );

    is $fanless, GlitchVape::Wav::silence( int( GlitchVape::Drive::RATE * 3 ) ),
        'no fan and no work is a drive that is switched off';
}

done_testing;
