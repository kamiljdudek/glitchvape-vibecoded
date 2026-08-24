package GlitchVape::DTMF;

use strict;
use warnings;

use GlitchVape::Tools ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::DTMF - spell a phrase out in dialpad tones

=head1 DESCRIPTION

Text in, the sound of somebody dialling it out. Letters go in the multi-tap
way a phone keypad took them before predictive text -- C<c> is key 2 pressed
three times -- a space is a single 0, and digits, C<*> and C<#> are already
keys so they dial as one press each. Mixed input like C<call 5551234> works
without being told which half is which.

Everything here is arithmetic and C<pack>: no external synthesiser, no
temporary command lines, nothing to install. The only outside tool involved is
whatever eventually encodes the WAV this writes.

=head2 The grid

DTMF is two sine waves at once, one from the row the key is on and one from
its column. The high group is sent about 2 dB hotter than the low -- the
"twist" -- because the far end's filters lose more of it on the way.

The C<A>-C<D> column at 1633 Hz is not reachable from text, since as text
those are letters; C<digits> mode is how you get at it.

=head2 Why the tones are cached

A tone is a couple of thousand samples of C<sin>, and a sentence is a couple
of hundred presses -- but there are only sixteen possible keys, and two
presses of the same key are the same samples. So each distinct key is rendered
once and the track is assembled by joining byte strings, which turns the
sentence-length loop into a handful of concatenations.

=cut

# Classic dialpad: which key carries which letters, in press order.
my %KEYS = (
    2 => 'abc',
    3 => 'def',
    4 => 'ghi',
    5 => 'jkl',
    6 => 'mno',
    7 => 'pqrs',
    8 => 'tuv',
    9 => 'wxyz',
);

# letter => [ key, presses ]; 'c' is 2 pressed three times.
my %MULTITAP;
for my $key ( keys %KEYS )
{
    my @letters = split //, $KEYS{ $key };
    for my $n ( 0 .. $#letters )
    {
        $MULTITAP{ $letters[ $n ] } = [ $key, $n + 1 ];
    }
}

# Already keys, so they dial as a single press even in multi-tap mode.
my %DIRECT = map { $_ => 1 } split //, '0123456789*#';

my %ROW = (
    '1' => 697,
    '2' => 697,
    '3' => 697,
    'A' => 697,
    '4' => 770,
    '5' => 770,
    '6' => 770,
    'B' => 770,
    '7' => 852,
    '8' => 852,
    '9' => 852,
    'C' => 852,
    '*' => 941,
    '0' => 941,
    '#' => 941,
    'D' => 941,
);

my %COL = (
    '1' => 1209,
    '4' => 1209,
    '7' => 1209,
    '*' => 1209,
    '2' => 1336,
    '5' => 1336,
    '8' => 1336,
    '0' => 1336,
    '3' => 1477,
    '6' => 1477,
    '9' => 1477,
    '#' => 1477,
    'A' => 1633,
    'B' => 1633,
    'C' => 1633,
    'D' => 1633,
);

# Continuous dial tone -- an off-hook line waiting for digits. Which
# frequencies you hear depends on where the line is.
my %LINE = (
    eu => [ 425 ],         # ITU-T, most of continental Europe
    us => [ 350, 440 ],    # North American precise tone plan
    uk => [ 350, 450 ],    # BT
    jp => [ 400 ],         # NTT
);

use constant RATE => 44_100;

use constant LOW_AMP  => 0.35;
use constant HIGH_AMP => 0.44;     # the standard twist, ~2 dB
use constant RAMP     => 0.002;    # raised-cosine tone edges, stops clicks

use constant LINE_AMP  => 0.5;
use constant LINE_RAMP => 0.015;    # slower than a keypress: a line coming up

# What happens after the last digit when there is still soundtrack to cover:
# the dialling stops, three seconds go by, and the line opens again.
use constant TRAIL_SILENCE => 3;
use constant TRAIL_REGION  => 'eu';

# Hayes S11: one register sets both the tone length and the inter-digit pause
# during auto-dial, so the default cadence is 95 ms of each.
use constant DEFAULT_TONE_MS => 95;
use constant DEFAULT_GAP_MS  => 95;

my $PI = 3.14159265358979;

=head2 params()

The parameter declaration, in the same shape L<GlitchVape::Registry> uses for
an effect -- so C<--generate>'s validation and the interface's widgets are
both built from it rather than from three separate lists that drift apart.

=cut

my @PARAM = (
    text => {
        label   => 'Phrase',
        type    => 'str',
        default => q{},
        doc     => 'What to dial. Letters go in the multi-tap way a keypad '
            . "took them -- 'c' is key 2 pressed three times -- a space is a "
            . 'single 0, and digits, * and # are already keys.',
    },
    mode => {
        label   => 'Entry',
        type    => 'enum',
        values  => [ qw(text digits) ],
        default => 'text',
        doc     => "text spells words out on a keypad. digits takes the "
            . 'input literally instead, which is the only way to reach the '
            . 'A-D column at 1633 Hz.',
    },
    dial_tone => {
        label   => 'Dial tone',
        type    => 'enum',
        values  => [ qw(none eu us uk jp) ],
        default => 'none',
        doc     => 'Lift the handset first: the continuous tone an off-hook '
            . 'line makes. 425 Hz across most of Europe, 350+440 in North '
            . 'America, 350+450 on BT, 400 on NTT.',
    },
    dial_tone_sec => {
        label   => 'Tone for',
        type    => 'num',
        min     => 0,
        max     => 30,
        default => 2,
        doc     => 'How long the line is heard before dialling starts.',
    },
    tone_ms => {
        label   => 'Tone',
        type    => 'int',
        min     => 10,
        max     => 1000,
        default => 95,
        doc     => 'How long each key is held. The default is the Hayes S11 '
            . 'register, which on a real modem set both this and the pause '
            . 'below during auto-dial -- so the pair is one decision.',
    },
    gap_ms => {
        label   => 'Gap',
        type    => 'int',
        min     => 0,
        max     => 1000,
        default => 95,
        doc     => 'Pause between one key and the next.',
    },
    same_key_pause_ms => {
        label   => 'Same key',
        type    => 'int',
        min     => 0,
        max     => 2000,
        default => 0,
        doc     => 'Extra pause between two presses of the same key, which '
            . "real multi-tap entry needed to tell 'cc' from 'f'. Zero keeps "
            . 'the uniform auto-dial cadence.',
    },
    gain => {
        label   => 'Level',
        type    => 'num',
        min     => 0,
        max     => 2,
        default => 0.8,
        doc     => 'How loud the tones sit under a soundtrack.',
    },
);

sub params
{
    my %spec = @PARAM;
    return \%spec;
}

=head2 param_order()

The names in the order they are worth showing: what to dial first, then how
the line is answered, then cadence.

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

=head2 regions()

The dial-tone regions, sorted. C<none> is not one of them; it is the absence
of one.

=cut

sub regions
{
    my @names = sort keys %LINE;
    return @names;
}

=head2 region_hz( $name )

The frequencies a region's dial tone is made of, for a tooltip.

=cut

sub region_hz
{
    my ( $name ) = @_;

    my $freqs = $LINE{ $name || q{} } or return q{};
    return join ' + ', map { "$_ Hz" } @$freqs;
}

=head2 spell( $text )

Expand text into the presses a multi-tap keypad would need. Returns
C<< ( \@presses, \@dropped ) >>, the second being characters with no key at
all so the caller can say so rather than losing them quietly.

Note that this makes C<a> and C<2> identical -- one press of key 2. That
ambiguity is inherent to multi-tap, and is what C<same_key_pause_ms> exists to
resolve for anything meant to be read back.

=cut

sub spell
{
    my ( $text ) = @_;

    my ( @presses, @dropped );

    for my $ch ( split //, lc( $text // q{} ) )
    {
        if ( $ch eq ' ' )
        {
            push @presses, '0';
        }
        elsif ( $MULTITAP{ $ch } )
        {
            my ( $key, $taps ) = @{ $MULTITAP{ $ch } };
            push @presses, ( $key ) x $taps;
        }
        elsif ( $DIRECT{ $ch } )
        {
            push @presses, $ch;
        }
        else
        {
            push @dropped, $ch;
        }
    }

    return ( \@presses, \@dropped );
}

=head2 parse_dial( $text )

Read the text as a literal dial string instead: no multi-tap expansion, and
the C<A>-C<D> column becomes reachable. The separators people write in phone
numbers are ignored, so C<(555) 123-4567> works as typed.

=cut

sub parse_dial
{
    my ( $text ) = @_;

    my ( @presses, @dropped );

    for my $ch ( split //, uc( $text // q{} ) )
    {
        if ( $ROW{ $ch } )
        {
            push @presses, $ch;
        }
        elsif ( $ch =~ m{[\s\-.()/+]} )
        {
            next;
        }
        else
        {
            push @dropped, $ch;
        }
    }

    return ( \@presses, \@dropped );
}

=head2 presses( $spec )

The presses for a spec, dispatching on its C<mode>.

=cut

sub presses
{
    my ( $spec ) = @_;

    my $text = q{};
    if ( ref $spec eq 'HASH' && defined $spec->{ text } )
    {
        $text = $spec->{ text };
    }

    if ( ref $spec eq 'HASH' && ( $spec->{ mode } // q{} ) eq 'digits' )
    {
        return parse_dial( $text );
    }

    return spell( $text );
}

=head2 resolve( $spec )

Validate and clamp a spec, filling in the defaults. Dies on a mode or region
that does not exist, and on text with nothing dialable in it -- all three are
mistakes a caller can act on, and all three would otherwise produce silence
that looks like the feature not working.

=cut

sub resolve
{
    my ( $spec ) = @_;

    return undef unless ref $spec eq 'HASH';

    my $text = $spec->{ text };
    return undef unless defined $text && length $text;

    my $mode = $spec->{ mode } // 'text';
    unless ( $mode eq 'text' || $mode eq 'digits' )
    {
        die "GlitchVape::DTMF: mode must be 'text' or 'digits', got '$mode'\n";
    }

    my $region = $spec->{ dial_tone } // 'none';
    unless ( $region eq 'none' || $LINE{ $region } )
    {
        die "GlitchVape::DTMF: no dial tone for '$region'.\n"
            . '  Available: none, '
            . join( ', ', regions() ) . "\n";
    }

    # Every numeric range comes from the declaration above rather than being
    # repeated here, so a limit changed in one place is changed everywhere it
    # is enforced or displayed.
    my $declared = params();

    my %out = ( text => $text, mode => $mode, dial_tone => $region );

    for my $name ( param_order() )
    {
        next if exists $out{ $name };

        my $field = $declared->{ $name };

        $out{ $name } = _clamp(
            $spec->{ $name },
            $field->{ min },
            $field->{ max },
            $field->{ default }
        );
    }

    my ( $keys, $dropped ) = presses( \%out );

    unless ( @$keys )
    {
        die "GlitchVape::DTMF: nothing in '$text' can be dialled.\n";
    }

    $out{ _presses } = $keys;
    $out{ _dropped } = $dropped;

    return \%out;
}

sub _clamp
{
    my ( $value, $lo, $hi, $default ) = @_;

    return $default unless defined $value && length $value;

    unless ( $value =~ /^-?\d+(?:\.\d+)?$/ )
    {
        die "GlitchVape::DTMF: expected a number, got '$value'\n";
    }

    return $lo if $value < $lo;
    return $hi if $value > $hi;

    return $value + 0;
}

=head2 duration( $spec )

How long the dialling itself lasts, in seconds: the lead-in dial tone plus one
pass through the phrase. Exact rather than an estimate -- every part of it is
a sample count this module chooses.

=cut

sub duration
{
    my ( $spec ) = @_;

    my $resolved = $spec;
    unless ( $resolved && $resolved->{ _presses } )
    {
        $resolved = resolve( $spec ) or return 0;
    }

    return _samples( $resolved ) / RATE;
}

sub _samples
{
    my ( $spec ) = @_;

    my $tone = int( RATE * $spec->{ tone_ms } / 1000 );
    my $gap  = int( RATE * $spec->{ gap_ms } / 1000 );

    my $same = int( RATE * $spec->{ same_key_pause_ms } / 1000 );
    $same = $gap if $same < $gap;

    my $keys  = $spec->{ _presses };
    my $total = 0;

    for my $n ( 0 .. $#$keys )
    {
        $total += $tone;

        my $next = $keys->[ $n + 1 ];
        if ( defined $next && $next eq $keys->[ $n ] )
        {
            $total += $same;
        }
        else
        {
            $total += $gap;
        }
    }

    if ( $spec->{ dial_tone } ne 'none' )
    {
        $total += int( RATE * $spec->{ dial_tone_sec } ) + $gap;
    }

    return $total;
}

=head2 render( %arg )

    spec    => the DTMF spec
    output  => path to write, .wav
    fill_to => seconds the result must cover

Writes the track. Returns the output path.

C<fill_to> is what happens when there is also a soundtrack, and it is longer
than the dialling: rather than looping the phrase -- which would turn a
sentence into a stutter -- the dialling simply stops, three seconds go by, and
the line opens again on a continuous tone for as long as is left. That is what
a handset does, and it means the length is always the soundtrack's to decide.

=cut

sub render
{
    my ( %arg ) = @_;

    my $spec = resolve( $arg{ spec } )
        or die "GlitchVape::DTMF: no phrase to dial\n";

    my $output = $arg{ output }
        or die "GlitchVape::DTMF: no output given\n";

    my $pcm = pcm( $spec, $arg{ fill_to } );

    open my $fh, '>:raw', $output
        or die "GlitchVape::DTMF: cannot write $output: $!\n";
    print { $fh } wav( $pcm );
    close $fh
        or die "GlitchVape::DTMF: cannot write $output: $!\n";

    return $output;
}

=head2 pcm( $spec, $fill_to )

The samples themselves, as packed 16-bit little-endian mono. Split out from
L</render> so a caller that wants to measure or reuse them does not have to go
through a file.

=cut

sub pcm
{
    my ( $spec, $fill_to ) = @_;

    my $gain = $spec->{ gain };

    my $tone_n = int( RATE * $spec->{ tone_ms } / 1000 );
    my $gap_n  = int( RATE * $spec->{ gap_ms } / 1000 );

    my $same_n = int( RATE * $spec->{ same_key_pause_ms } / 1000 );
    $same_n = $gap_n if $same_n < $gap_n;

    my $gap  = _silence( $gap_n );
    my $same = _silence( $same_n );

    my @out;

    # Lift the handset first, then the usual inter-digit pause before the
    # first key goes down.
    if ( $spec->{ dial_tone } ne 'none' )
    {
        push @out,
            _continuous( $LINE{ $spec->{ dial_tone } },
            $spec->{ dial_tone_sec }, $gain );
        push @out, $gap;
    }

    my %cache;
    my $keys = $spec->{ _presses };

    for my $n ( 0 .. $#$keys )
    {
        my $key = $keys->[ $n ];

        $cache{ $key } = _tone( $key, $tone_n, $gain )
            unless exists $cache{ $key };

        push @out, $cache{ $key };

        my $next = $keys->[ $n + 1 ];
        if ( defined $next && $next eq $key )
        {
            push @out, $same;
        }
        else
        {
            push @out, $gap;
        }
    }

    my $pcm = join q{}, @out;

    return $pcm unless $fill_to;

    my $want = int( RATE * $fill_to ) * 2;

    # Longer than the soundtrack: the soundtrack decides, so the dialling is
    # cut where it runs out. Trimmed on a sample boundary, or the 16-bit
    # frames would be knocked out of step and the rest would be noise.
    if ( length( $pcm ) >= $want )
    {
        return substr $pcm, 0, $want;
    }

    my $remaining = $want - length $pcm;
    my $quiet     = int( RATE * TRAIL_SILENCE ) * 2;
    $quiet = $remaining if $quiet > $remaining;

    $pcm .= _silence( $quiet / 2 );
    $remaining -= $quiet;

    return $pcm unless $remaining > 0;

    $pcm .= _continuous( $LINE{ +TRAIL_REGION }, $remaining / 2 / RATE, $gain );

    return substr $pcm, 0, $want;
}

# One key's tone: the row and column sines together, with raised-cosine edges
# so a press does not start and end on a click.
sub _tone
{
    my ( $key, $count, $gain ) = @_;

    my $low  = $ROW{ $key };
    my $high = $COL{ $key };

    my $ramp = int( RATE * RAMP );
    $ramp = 1 if $ramp < 1;

    my @sample;

    for my $n ( 0 .. $count - 1 )
    {
        my $t = $n / RATE;
        my $v =
            $gain *
            ( LOW_AMP * sin( 2 * $PI * $low * $t ) +
                HIGH_AMP * sin( 2 * $PI * $high * $t ) );

        $v *= _envelope( $n, $count, $ramp );

        push @sample, _quantise( $v );
    }

    return pack 's<*', @sample;
}

# A continuous tone of one or more frequencies -- a dial tone rather than a
# keypress, so the edges are gentler and the level is split across whatever
# components the region uses.
sub _continuous
{
    my ( $freqs, $seconds, $gain ) = @_;

    my $count = int( RATE * $seconds );
    return q{} unless $count > 0;

    my $ramp = int( RATE * LINE_RAMP );
    $ramp = 1 if $ramp < 1;

    # Clamped so a very short request still fades in and out rather than
    # having its two ramps overlap.
    my $half = int( $count / 2 );
    $ramp = $half if $half > 0 && $ramp > $half;

    my $per = LINE_AMP / scalar @$freqs;

    my @sample;

    for my $n ( 0 .. $count - 1 )
    {
        my $t = $n / RATE;

        my $v = 0;
        $v += sin( 2 * $PI * $_ * $t ) for @$freqs;

        $v *= $gain * $per * _envelope( $n, $count, $ramp );

        push @sample, _quantise( $v );
    }

    return pack 's<*', @sample;
}

sub _envelope
{
    my ( $n, $count, $ramp ) = @_;

    return 0.5 - 0.5 * cos( $PI * $n / $ramp ) if $n < $ramp;

    my $from_end = $count - $n;
    return 0.5 - 0.5 * cos( $PI * $from_end / $ramp ) if $from_end < $ramp;

    return 1;
}

sub _quantise
{
    my ( $v ) = @_;

    my $s = int( $v * 32_767 );

    return -32_768 if $s < -32_768;
    return 32_767  if $s > 32_767;

    return $s;
}

sub _silence
{
    my ( $count ) = @_;

    return q{} unless $count > 0;
    return "\0" x ( int( $count ) * 2 );
}

=head2 wav( $pcm )

Wrap packed samples in a RIFF/WAVE container: C<fmt > and C<data>, nothing
else.

The absence of everything else is the point. A WAV can carry cue markers,
labels and broadcast metadata beside the audio, and ffmpeg surfaces those as a
second stream of type C<bin_data> -- which then travels through a filter graph
dragging the audio's timing with it. Building the header here rather than
letting a library decide means there is nothing in the file but samples.

=cut

sub wav
{
    my ( $pcm, $channels ) = @_;

    $channels = 1 unless $channels;

    my $block = $channels * 2;

    return
          'RIFF'
        . pack( 'V',      36 + length $pcm ) . 'WAVE' . 'fmt '
        . pack( 'V',      16 )
        . pack( 'vvVVvv', 1, $channels, RATE, RATE * $block, $block, 16 )
        . 'data'
        . pack( 'V', length $pcm )
        . $pcm;
}

=head2 describe( $spec )

One line for a status bar or a track row.

=cut

sub describe
{
    my ( $spec ) = @_;

    my $resolved = eval { resolve( $spec ) };
    return 'no dialling' unless $resolved;

    my $text = $resolved->{ text };
    if ( length( $text ) > 34 )
    {
        $text = substr( $text, 0, 31 ) . '...';
    }

    my $line = sprintf '"%s"  %d keys  %s',
        $text, scalar @{ $resolved->{ _presses } },
        _mmss( duration( $resolved ) );

    if ( $resolved->{ mode } eq 'digits' )
    {
        $line .= '  dial string';
    }

    if ( $resolved->{ dial_tone } ne 'none' )
    {
        $line .= sprintf '  %s tone', $resolved->{ dial_tone };
    }

    return $line;
}

sub _mmss
{
    my ( $seconds ) = @_;

    $seconds = 0 unless defined $seconds && $seconds > 0;

    my $minutes = int( $seconds / 60 );

    return sprintf '%d:%04.1f', $minutes, $seconds - $minutes * 60;
}

=head2 keys_of( $spec )

The keypress sequence as a string, for showing the user what will be dialled.

=cut

sub keys_of
{
    my ( $spec ) = @_;

    my $resolved = eval { resolve( $spec ) } or return q{};
    return join q{}, @{ $resolved->{ _presses } };
}

=head2 spec_parts( $spec )

The pieces that determine the rendered tones, for a cache key.

=cut

sub spec_parts
{
    my ( $spec ) = @_;

    return () unless ref $spec eq 'HASH' && defined $spec->{ text };

    return (
        'dtmf',
        map { $spec->{ $_ } }
            qw(text mode tone_ms gap_ms same_key_pause_ms dial_tone
            dial_tone_sec gain)
    );
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Audio>, which mixes what this renders under a soundtrack.

=cut
