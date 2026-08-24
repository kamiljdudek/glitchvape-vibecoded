#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Spec ();
use File::Temp ();

use Test::More;
use GlitchVape::DTMF ();

# All of this is arithmetic and pack, so none of it needs anything installed.
# The one thing worth stating up front: these tones are a specification, not a
# taste. A test that only asserted "some samples came out" would pass just as
# happily on a sine at the wrong frequency, so the frequency itself is
# measured below.

# ---------------------------------------------------------------------------
# Multi-tap spelling

{
    my ( $keys ) = GlitchVape::DTMF::spell( 'a' );
    is_deeply $keys, [ '2' ], 'a is one press of key 2';

    ( $keys ) = GlitchVape::DTMF::spell( 'c' );
    is_deeply $keys, [ '2', '2', '2' ], 'c is key 2 three times';

    ( $keys ) = GlitchVape::DTMF::spell( 's' );
    is_deeply $keys, [ '7', '7', '7', '7' ], 's is the fourth letter on 7';

    ( $keys ) = GlitchVape::DTMF::spell( 'a b' );
    is_deeply $keys, [ '2', '0', '2', '2' ], 'a space is a single 0';

    # Digits, * and # are already keys, so mixed input needs no flag.
    ( $keys ) = GlitchVape::DTMF::spell( 'a5*#' );
    is_deeply $keys, [ '2', '5', '*', '#' ],
        'digits and symbols dial as one press each';

    # Upper case is folded, and A/B are letters here rather than the fourth
    # column: 'a' is one press of 2 and 'b' is two, so this is three presses
    # and not four.
    ( $keys ) = GlitchVape::DTMF::spell( 'AB' );
    is_deeply $keys, [ '2', '2', '2' ],
        'case is folded, and A/B spell rather than reaching the 1633 Hz column';

    my ( undef, $dropped ) = GlitchVape::DTMF::spell( 'hi!, there' );
    is_deeply $dropped, [ '!', ',' ],
        'characters with no key are reported rather than lost quietly';
}

# ---------------------------------------------------------------------------
# Literal dial strings

{
    my ( $keys ) = GlitchVape::DTMF::parse_dial( '(555) 123-4567' );
    is_deeply $keys, [ split //, '5551234567' ],
        'the separators people write in phone numbers are ignored';

    ( $keys ) = GlitchVape::DTMF::parse_dial( 'abcd' );
    is_deeply $keys, [ qw(A B C D) ],
        'the 1633 Hz column is reachable as a dial string';

    my ( undef, $dropped ) = GlitchVape::DTMF::parse_dial( '55z' );
    is_deeply $dropped, [ 'Z' ], 'a letter with no key is dropped';
}

# ---------------------------------------------------------------------------
# Validation

{
    my $spec = GlitchVape::DTMF::resolve( { text => 'hi' } );

    is $spec->{ tone_ms },   95,     'the Hayes S11 tone length is the default';
    is $spec->{ gap_ms },    95,     'and the same register sets the pause';
    is $spec->{ mode },      'text', 'multi-tap is the default mode';
    is $spec->{ dial_tone }, 'none', 'and no dial tone';

    is_deeply GlitchVape::DTMF::resolve( undef ), undef,
        'no spec resolves to nothing';
    is_deeply GlitchVape::DTMF::resolve( { text => q{} } ), undef,
        'empty text resolves to nothing';

    # Out of range is clamped; the wrong kind of thing entirely is not.
    my $fast = GlitchVape::DTMF::resolve( { text => 'hi', tone_ms => 1 } );
    is $fast->{ tone_ms }, 10, 'a too-short tone is clamped to the floor';

    local $@;
    ok !eval {
        GlitchVape::DTMF::resolve( { text => 'hi', mode => 'morse' } );
        1;
    }, 'an unknown mode dies';

    local $@;
    ok !eval {
        GlitchVape::DTMF::resolve( { text => 'hi', dial_tone => 'mars' } );
        1;
    }, 'an unknown dial-tone region dies';
    like $@, qr/no dial tone/, 'and says so';

    # Nothing dialable is the failure that would otherwise render silence and
    # look like the feature being broken.
    local $@;
    ok !eval { GlitchVape::DTMF::resolve( { text => '!!!' } ); 1 },
        'text with no keys in it at all dies';
}

# ---------------------------------------------------------------------------
# Duration

{
    # One press is one tone plus one gap, and the gap after the last key is
    # part of the cadence rather than trailing silence to be trimmed.
    my $one = GlitchVape::DTMF::duration(
        { text => '1', tone_ms => 100, gap_ms => 100 } );
    is sprintf( '%.3f', $one ), '0.200', 'one press is tone plus gap';

    my $three = GlitchVape::DTMF::duration(
        { text => '111', tone_ms => 100, gap_ms => 100 } );
    is sprintf( '%.3f', $three ), '0.600', 'three presses is three of those';

    # The same-key pause is what tells 'cc' from 'f' on a real keypad.
    my $same = GlitchVape::DTMF::duration(
        {
            text              => '11',
            tone_ms           => 100,
            gap_ms            => 100,
            same_key_pause_ms => 300,
        }
    );
    is sprintf( '%.3f', $same ), '0.600',
        'a repeated key gets the longer pause between the two presses';

    my $mixed = GlitchVape::DTMF::duration(
        {
            text              => '12',
            tone_ms           => 100,
            gap_ms            => 100,
            same_key_pause_ms => 300,
        }
    );
    is sprintf( '%.3f', $mixed ), '0.400',
        'two different keys keep the ordinary gap';

    my $lifted = GlitchVape::DTMF::duration(
        {
            text          => '1',
            tone_ms       => 100,
            gap_ms        => 100,
            dial_tone     => 'eu',
            dial_tone_sec => 2,
        }
    );
    is sprintf( '%.3f', $lifted ), '2.300',
        'a lead-in dial tone adds itself plus one gap before the first key';
}

# ---------------------------------------------------------------------------
# The samples themselves

sub samples_of
{
    my ( $pcm ) = @_;
    return unpack 's<*', $pcm;
}

# Goertzel: how much of one frequency is present in a run of samples. Enough
# to assert that key 5 really is 770 Hz against 1336 Hz rather than trusting
# the table was copied correctly.
sub power_at
{
    my ( $freq, @sample ) = @_;

    my $rate = GlitchVape::DTMF::RATE;
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
    my $spec = GlitchVape::DTMF::resolve(
        { text => '5', tone_ms => 200, gap_ms => 0, gain => 1 } );

    my @sample = samples_of( GlitchVape::DTMF::pcm( $spec ) );

    is scalar @sample, int( GlitchVape::DTMF::RATE * 0.2 ),
        'a 200 ms tone is 200 ms of samples';

    # Sampled away from the raised-cosine edges, which would otherwise damp
    # the very frequencies being measured.
    my @middle = @sample[ 2000 .. 6000 ];

    my $row = power_at( 770,  @middle );    # key 5's row
    my $col = power_at( 1336, @middle );    # key 5's column
    my $off = power_at( 1209, @middle );    # key 4's column: must be absent

    cmp_ok $row, '>', $off * 100, 'key 5 carries its 770 Hz row tone';
    cmp_ok $col, '>', $off * 100, 'and its 1336 Hz column tone';

    # The standard twist: the high group goes out a couple of dB hotter
    # because the far end's filters lose more of it.
    cmp_ok $col, '>', $row, 'the high group is the louder of the two';
}

{
    # Edges are ramped, so a press does not start on a click.
    my $spec = GlitchVape::DTMF::resolve(
        { text => '1', tone_ms => 100, gap_ms => 0, gain => 1 } );

    my @sample = samples_of( GlitchVape::DTMF::pcm( $spec ) );

    cmp_ok abs $sample[ 0 ],    '<', 100,  'a tone starts from near silence';
    cmp_ok abs $sample[ -1 ],   '<', 500,  'and ends near it';
    cmp_ok abs $sample[ 2205 ], '>', 3000, 'and is at level in between';
}

# ---------------------------------------------------------------------------
# Filling out to a soundtrack's length

{
    my $spec = GlitchVape::DTMF::resolve(
        { text => '1', tone_ms => 100, gap_ms => 100, gain => 1 } );

    my $rate = GlitchVape::DTMF::RATE;

    # Shorter than the fill: dialling, then three seconds of silence, then the
    # line comes back up for the rest. Never a repeat of the phrase.
    my @sample = samples_of( GlitchVape::DTMF::pcm( $spec, 8 ) );

    is scalar @sample, int( $rate * 8 ),
        'the result is exactly as long as asked';

    my $quiet = 0;
    $quiet += abs $sample[ $_ ] for map { int( $rate * $_ ) } ( 1, 2, 3 );
    is $quiet, 0, 'the three seconds after the last digit are silent';

    my @tail = @sample[ int( $rate * 6 ) .. int( $rate * 6.5 ) ];

    my $eu  = power_at( 425, @tail );
    my $off = power_at( 900, @tail );

    cmp_ok $eu, '>', $off * 100,
        'and the line reopens on the 425 Hz European tone';

    # Longer than the fill: the soundtrack decides, so the dialling is cut.
    my $long = GlitchVape::DTMF::pcm( $spec, 0.1 );
    is length( $long ), int( $rate * 0.1 ) * 2,
        'a phrase longer than the fill is cut to it';
    is length( $long ) % 2, 0,
        'and cut on a sample boundary, or the frames would be knocked out '
        . 'of step';
}

# ---------------------------------------------------------------------------
# The container

{
    my $wav = GlitchVape::DTMF::wav( "\0" x 400 );

    is substr( $wav, 0,  4 ), 'RIFF', 'a RIFF file';
    is substr( $wav, 8,  4 ), 'WAVE', 'of type WAVE';
    is substr( $wav, 12, 4 ), 'fmt ', 'starting with the format chunk';

    my ( $format, $channels, $rate ) = unpack 'vvV', substr( $wav, 20, 8 );
    is $format,   1,                      'PCM';
    is $channels, 1,                      'mono';
    is $rate,     GlitchVape::DTMF::RATE, 'at the working rate';

    # Nothing else in the file. Cue markers and broadcast metadata are what
    # ffmpeg surfaces as a second bin_data stream, which then drags the
    # audio's timing about downstream.
    is substr( $wav, 36, 4 ), 'data',
        'and then the samples, with no other ' . 'chunks in between';
    is length( $wav ), 44 + 400, 'so the file is its header plus its samples';
}

# ---------------------------------------------------------------------------
# Describing

{
    my $spec = {
        text      => 'call me',
        dial_tone => 'eu',
    };

    my $text = GlitchVape::DTMF::describe( $spec );
    like $text, qr/call me/,  'describe quotes the phrase';
    like $text, qr/\d+ keys/, 'and counts the presses';
    like $text, qr/eu tone/,  'and mentions the dial tone';

    is GlitchVape::DTMF::describe( undef ), 'no dialling',
        'nothing describes as nothing';
    is GlitchVape::DTMF::describe( { text => '!!!' } ), 'no dialling',
        'and so does something unspellable, rather than dying in a status bar';

    is GlitchVape::DTMF::keys_of( { text => 'cab' } ), '222' . '2' . '22',
        'the keypress sequence is available for showing the user';
}

# ---------------------------------------------------------------------------
# Cache key parts

{
    my @a = GlitchVape::DTMF::spec_parts( { text => 'hi', tone_ms => 95 } );
    my @b = GlitchVape::DTMF::spec_parts( { text => 'hi', tone_ms => 60 } );

    ok scalar @a, 'a spec contributes parts';
    isnt join( '|', map { $_ // q{} } @a ), join( '|', map { $_ // q{} } @b ),
        'changing the cadence changes them';

    is_deeply [ GlitchVape::DTMF::spec_parts( undef ) ], [],
        'no spec contributes nothing';
}

# ---------------------------------------------------------------------------
# Writing a file

{
    my $dir = File::Temp->newdir( 'gv_dtmf_XXXXXX', TMPDIR => 1 );
    my $out = File::Spec->catfile( "$dir", 'tones.wav' );

    GlitchVape::DTMF::render( spec => { text => 'hi' }, output => $out );

    ok -s $out, 'render writes a file';

    open my $fh, '<:raw', $out or die "cannot read $out: $!";
    my $head = do { local $/ = \12; <$fh> };
    close $fh;

    is substr( $head, 0, 4 ), 'RIFF', 'and it is a WAV';

    local $@;
    ok !eval {
        GlitchVape::DTMF::render( spec => { text => q{} }, output => $out );
        1;
    }, 'rendering nothing is refused rather than writing an empty file';
}

done_testing;
