#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Spec ();
use File::Temp ();

use Test::More;
use GlitchVape::Generator ();
use GlitchVape::Noise     ();
use GlitchVape::Wav       ();

# The registry, and the one generator that is not tested anywhere else.
# Everything here is arithmetic and pack, so none of it needs anything
# installed.

# ---------------------------------------------------------------------------
# The registry

{
    my @kinds = GlitchVape::Generator::kinds();

    cmp_ok scalar @kinds, '>=', 2, 'there are generators registered';
    ok scalar( grep { $_ eq 'dtmf' } @kinds ),   'dtmf is one';
    ok scalar( grep { $_ eq 'static' } @kinds ), 'static is another';

    for my $kind ( @kinds )
    {
        my $declared = GlitchVape::Generator::get( $kind );

        ok length $declared->{ label },         "$kind has a label";
        ok length $declared->{ summary },       "$kind has a summary";
        ok ref $declared->{ params } eq 'HASH', "$kind declares parameters";

        # The order list is what the interface lays widgets out from, so a
        # name in one and not the other is a control that never appears or a
        # crash when it does.
        my @order = @{ $declared->{ order } };

        # Written with braces: "$kind's" is parsed as the package variable
        # $kind::s, which is empty and warns.
        is_deeply [ sort @order ], [ sort keys %{ $declared->{ params } } ],
            "${kind} lays out exactly the parameters it declares";

        for my $name ( @order )
        {
            ok defined $declared->{ params }{ $name }{ default },
                "$kind.$name has a default";
        }
    }

    is GlitchVape::Generator::get( 'nonesuch' ), undef,
        'an unregistered kind is simply not there';
}

# ---------------------------------------------------------------------------
# Validation

{
    my $ok = GlitchVape::Generator::resolve(
        { kind => 'static', tone => 0.5, seconds => 20 } );

    is $ok->{ kind }, 'static', 'the kind survives resolution';
    is $ok->{ tone }, 0.5,      'a given value is kept';
    is $ok->{ hum }, GlitchVape::Noise::params()->{ hum }{ default },
        'and an absent one takes its declared default';

    my $high =
        GlitchVape::Generator::resolve( { kind => 'static', tone => 40 } );
    is $high->{ tone }, 1, 'a value above the range is clamped, not refused';

    my $low =
        GlitchVape::Generator::resolve( { kind => 'static', drift => -8 } );
    is $low->{ drift }, 0, 'and below it';

    my $int = GlitchVape::Generator::resolve(
        { kind => 'static', seconds => '12.7' } );
    is $int->{ seconds }, 12, 'an int parameter is made whole';

    # A typo stops, because the alternative is a track that silently is not
    # the one that was asked for.
    local $@;
    ok !eval { GlitchVape::Generator::resolve( { kind => 'wobble' } ); 1 },
        'an unknown kind dies';
    like $@, qr/no generator called/, 'and says so';

    local $@;
    ok !eval { GlitchVape::Generator::resolve( { tone => 1 } ); 1 },
        'a track with no kind at all dies';

    local $@;
    ok !eval {
        GlitchVape::Generator::resolve( { kind => 'static', tone => 'loud' } );
        1;
    }, 'a number given as a word dies';

    local $@;
    ok !eval {
        GlitchVape::Generator::resolve(
            {
                kind => 'dtmf',
                text => 'hi',
                mode => 'morse'
            }
        );
        1;
    }, 'an enum given something not in its list dies';
}

# ---------------------------------------------------------------------------
# Length, and which kinds have an ending

{
    my $static =
        GlitchVape::Generator::resolve( { kind => 'static', seconds => 14 } );
    is GlitchVape::Generator::duration( $static ), 14,
        'static lasts as long as it was asked to';

    my $dtmf =
        GlitchVape::Generator::resolve( { kind => 'dtmf', text => 'hi' } );
    cmp_ok GlitchVape::Generator::duration( $dtmf ), '>', 0,
        'a phrase lasts as long as the words take';

    ok GlitchVape::Generator::has_ending( 'dtmf' ),
        'a phrase has an ending to be cut short of';
    ok !GlitchVape::Generator::has_ending( 'static' ), 'static does not';
    ok !GlitchVape::Generator::has_ending( 'nonesuch' ),
        'and neither does something that is not a generator';
}

# ---------------------------------------------------------------------------
# Cache key parts

{
    my $a = { kind => 'static', seconds => 5, tone => 0.3 };
    my $b = { kind => 'static', seconds => 5, tone => 0.9 };

    my $flat = sub {
        return join '|', map { $_ // q{} } @_;
    };

    ok scalar( GlitchVape::Generator::spec_parts( $a ) ),
        'a track contributes parts';
    isnt $flat->( GlitchVape::Generator::spec_parts( $a ) ),
        $flat->( GlitchVape::Generator::spec_parts( $b ) ),
        'changing a parameter changes them';

    isnt $flat->( GlitchVape::Generator::spec_parts( $a ) ),
        $flat->(
        GlitchVape::Generator::spec_parts(
            { %$a, kind => 'dtmf', text => 'hi' }
        )
        ),
        'and so does changing the kind';

    # Whatever a resolve worked out is derived from what is already in the
    # key, so it would only make the digest longer.
    my $resolved =
        GlitchVape::Generator::resolve( { kind => 'dtmf', text => 'hi' } );
    my @parts = GlitchVape::Generator::spec_parts( $resolved );
    is scalar( grep { /^_/ } @parts ), 0,
        'the derived keys are left out of the digest';

    is_deeply [ GlitchVape::Generator::spec_parts( undef ) ], [],
        'no track contributes nothing';
}

# ---------------------------------------------------------------------------
# Static, as sound

sub samples_of
{
    my ( $pcm ) = @_;
    return unpack 's<*', $pcm;
}

sub power_at
{
    my ( $freq, @sample ) = @_;

    my $rate = GlitchVape::Noise::RATE;
    my $w    = 2 * 3.14159265358979 * $freq / $rate;
    my $cosw = cos $w;

    my ( $s1, $s2 ) = ( 0, 0 );
    for my $v ( @sample )
    {
        my $s = $v + 2 * $cosw * $s1 - $s2;
        $s2 = $s1;
        $s1 = $s;
    }

    return $s1 * $s1 + $s2 * $s2 - 2 * $cosw * $s1 * $s2;
}

{
    my $spec = GlitchVape::Generator::resolve(
        { kind => 'static', seconds => 2, hum => 0, crackle => 0, drift => 0 }
    );

    my @sample = samples_of( GlitchVape::Noise::pcm( $spec ) );

    is scalar @sample, GlitchVape::Noise::RATE * 2,
        'two seconds of static is two seconds of samples';

    # The whole point of the thing: pink, not white. Power per octave falls
    # rather than staying flat, which is what makes it restful instead of
    # fatiguing. Measured well below the low-pass corner so this is the
    # source's own slope rather than the filter's.
    my @middle = @sample[ 4000 .. 20_000 ];

    my $low  = power_at( 200, @middle );
    my $high = power_at( 800, @middle );

    cmp_ok $high, '<', $low,
        'energy falls with frequency, so the noise is pink rather than white';

    # And it is noise rather than a tone: no single frequency dominates.
    my $near = power_at( 210, @middle );
    cmp_ok $near, '>', $low / 50,
        'neighbouring frequencies carry comparable energy, so it is '
        . 'broadband rather than tonal';
}

{
    # Tone opens the top end. A control that does not move is worse than no
    # control, so this asserts that it does.
    my @high;

    for my $tone ( 0, 1 )
    {
        my $spec = GlitchVape::Generator::resolve(
            {
                kind    => 'static',
                seconds => 2,
                tone    => $tone,
                hum     => 0,
                crackle => 0,
                drift   => 0,
            }
        );

        my @sample = samples_of( GlitchVape::Noise::pcm( $spec ) );
        push @high, power_at( 5000, @sample[ 4000 .. 20_000 ] );
    }

    cmp_ok $high[ 1 ], '>', $high[ 0 ] * 4,
        'tone at 1 passes far more of the top end than tone at 0';
}

{
    # Mains hum is the single most evocative component, so it is worth
    # knowing it is actually at mains frequency.
    my %power;

    for my $hum ( 0, 1 )
    {
        my $spec = GlitchVape::Generator::resolve(
            {
                kind    => 'static',
                seconds => 2,
                hum     => $hum,
                crackle => 0,
                drift   => 0,
            }
        );

        my @sample = samples_of( GlitchVape::Noise::pcm( $spec ) );
        $power{ $hum } = power_at( 50, @sample[ 4000 .. 20_000 ] );
    }

    cmp_ok $power{ 1 }, '>', $power{ 0 } * 4,
        'switching the hum on puts energy at 50 Hz';
}

{
    # The same seed has to give the same static, or a render stops being
    # reproducible once the preview cache has forgotten it.
    my %spec = ( kind => 'static', seconds => 1 );

    my $a = GlitchVape::Noise::pcm(
        GlitchVape::Generator::resolve( { %spec, seed => 7 } ) );
    my $b = GlitchVape::Noise::pcm(
        GlitchVape::Generator::resolve( { %spec, seed => 7 } ) );
    my $c = GlitchVape::Noise::pcm(
        GlitchVape::Generator::resolve( { %spec, seed => 8 } ) );

    is $a,   $b, 'the same seed gives the same samples';
    isnt $a, $c, 'a different one does not';
}

{
    # Static has no ending, so covering more time is simply more of it --
    # there is no seam and no repeat.
    my $spec =
        GlitchVape::Generator::resolve( { kind => 'static', seconds => 2 } );

    my $long = GlitchVape::Noise::pcm( $spec, 5 );
    is length( $long ), GlitchVape::Noise::RATE * 5 * 2,
        'fill_to overrides the requested length';

    my $short = GlitchVape::Noise::pcm( $spec );
    isnt substr( $long, 0, 200 ), substr( $long, -200 ),
        'and the end of it is not a repeat of the beginning';
    cmp_ok length( $long ), '>', length( $short ), 'and there is more of it';
}

{
    # Starting and stopping at full level clicks like any other cut.
    my $spec = GlitchVape::Generator::resolve(
        { kind => 'static', seconds => 1, gain => 1 } );

    my @sample = samples_of( GlitchVape::Noise::pcm( $spec ) );

    cmp_ok abs $sample[ 0 ],  '<', 200, 'static fades in from silence';
    cmp_ok abs $sample[ -1 ], '<', 200, 'and out to it';
}

# ---------------------------------------------------------------------------
# Writing

{
    my $dir = File::Temp->newdir( 'gv_gen_XXXXXX', TMPDIR => 1 );
    my $out = File::Spec->catfile( "$dir", 'static.wav' );

    GlitchVape::Generator::render(
        spec   => { kind => 'static', seconds => 1 },
        output => $out,
    );

    ok -s $out, 'render writes a file';

    open my $fh, '<:raw', $out or die "cannot read $out: $!";
    my $head = do { local $/ = \44; <$fh> };
    close $fh;

    is substr( $head, 0, 4 ), 'RIFF', 'and it is a WAV';

    my ( undef, undef, $rate ) = unpack 'vvV', substr( $head, 20, 8 );
    is $rate, GlitchVape::Noise::RATE,
        'written at the rate it was generated at, for ffmpeg to resample';
}

# ---------------------------------------------------------------------------
# The container

{
    is GlitchVape::Wav::quantise(  0 ),  0,      'silence quantises to zero';
    is GlitchVape::Wav::quantise(  1 ),  32_767, 'full scale to the top';
    is GlitchVape::Wav::quantise( -1 ), -32_767, 'and to near the bottom';

    # Without the clamp, pack would wrap a loud peak into a full-scale spike
    # of the opposite sign -- which is audible, and sounds like a fault.
    is GlitchVape::Wav::quantise(  4 ),  32_767, 'above full scale is clamped';
    is GlitchVape::Wav::quantise( -4 ), -32_768, 'and below it';

    is length( GlitchVape::Wav::silence( 10 ) ), 20,
        'silence is two bytes a sample';
    is GlitchVape::Wav::silence( 0 ), q{}, 'and none of it is none';

    my $wav = GlitchVape::Wav::bytes( "\0" x 100, rate => 8000, channels => 2 );
    my ( $format, $channels, $rate ) = unpack 'vvV', substr( $wav, 20, 8 );

    is $format,        1,        'PCM';
    is $channels,      2,        'the channel count is honoured';
    is $rate,          8000,     'and the rate';
    is length( $wav ), 44 + 100, 'header plus samples, and nothing else';
}

done_testing;
