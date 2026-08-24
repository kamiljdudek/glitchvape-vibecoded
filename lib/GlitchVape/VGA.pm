package GlitchVape::VGA;

use strict;
use warnings;

# The glyph table below is keyed by literal characters, and four of them are
# the CP437 shade blocks rather than ASCII.
use utf8;

our $VERSION = '0.01';

=head1 NAME

GlitchVape::VGA - an 8x16 text-mode font and the CGA palette

=head1 DESCRIPTION

What a PC drew with before anything had a graphics driver: a 16-colour palette
burnt into the card and a character cell eight pixels wide by sixteen tall,
each glyph one bit per pixel. L<GlitchVape::Effect::Glitch>'s C<vgatext> paints
with it.

=head2 Why the bitmaps are in the file

The obvious way to draw a letter is to hand ImageMagick a TrueType font, and
it is the wrong way here. A TrueType renderer hints and antialiases: it
produces grey edge pixels and moves stems to land on the pixel grid, and both
of those are precisely what a text-mode display could not do. Scaled up four
times for a glitch block, an antialiased glyph looks like a photograph of a
letter rather than like a letter a graphics card drew.

So the glyphs are ones and zeroes, and scaling is pixel replication. A cell
enlarged eight times is eight-pixel squares with hard edges, which is what the
real thing looked like on a CRT.

Keeping them here also means the effect needs no font installed, which matters
more than it sounds: L<GlitchVape::Fonts> exists because the rest of the
program cannot assume any particular typeface is present, and an effect whose
whole subject is one specific 1980s ROM font would be the worst possible thing
to leave to fontconfig.

=head2 Where they came from

Extracted from Terminus at its native pixel size, which is a console font
drawn on the same 8x16 grid for the same reason, and then baked in. Terminus
is under the SIL Open Font License; the sixteen bytes per glyph below are a
bitmap of it rather than the font itself.

=cut

use constant CELL_W => 8;
use constant CELL_H => 16;

# Sixteen bytes a glyph, most significant bit leftmost, top row first. Blank
# rows top and bottom are the cell's own leading, exactly as on the hardware:
# glyphs never touch the edge of their cell, which is what lets lines of text
# sit against each other without merging.
my %GLYPH = (
    ' '  => '00000000000000000000000000000000',
    '!'  => '00001010101010101000101000000000',
    '"'  => '00242424000000000000000000000000',
    '#'  => '00002424247E24247E24242400000000',
    '$'  => '0010107C9290907C1212927C10100000',
    '%'  => '0000649468081010202C524C00000000',
    '&'  => '000018242418304A4444443A00000000',
    '\'' => '00101010000000000000000000000000',
    '('  => '00000810202020202020100800000000',
    ')'  => '00002010080808080808102000000000',
    '*'  => '000000000024187E1824000000000000',
    '+'  => '000000000010107C1010000000000000',
    ','  => '00000000000000000000101020000000',
    '-'  => '000000000000007E0000000000000000',
    '.'  => '00000000000000000000101000000000',
    '/'  => '00000404080810102020404000000000',
    '0'  => '00003C4242464A526242423C00000000',
    '1'  => '00000818280808080808083E00000000',
    '2'  => '00003C42420204081020407E00000000',
    '3'  => '00003C4242021C020242423C00000000',
    '4'  => '000002060A1222427E02020200000000',
    '5'  => '00007E4040407C020202423C00000000',
    '6'  => '00001C2040407C424242423C00000000',
    '7'  => '00007E02020404080810101000000000',
    '8'  => '00003C4242423C424242423C00000000',
    '9'  => '00003C424242423E0202043800000000',
    ':'  => '00000000001010000000101000000000',
    ';'  => '00000000001010000000101020000000',
    '<'  => '00000004081020402010080400000000',
    '='  => '00000000007E00007E00000000000000',
    '>'  => '00000040201008040810204000000000',
    '?'  => '00003C42424204080800080800000000',
    '@'  => '00007C829EA2A2A2A69A807E00000000',
    'A'  => '00003C424242427E4242424200000000',
    'B'  => '00007C4242427C424242427C00000000',
    'C'  => '00003C42424040404042423C00000000',
    'D'  => '00007844424242424242447800000000',
    'E'  => '00007E40404078404040407E00000000',
    'F'  => '00007E40404078404040404000000000',
    'G'  => '00003C424240404E4242423C00000000',
    'H'  => '0000424242427E424242424200000000',
    'I'  => '00003810101010101010103800000000',
    'J'  => '00000E04040404040444443800000000',
    'K'  => '00004244485060605048444200000000',
    'L'  => '00004040404040404040407E00000000',
    'M'  => '000082C6AA9292828282828200000000',
    'N'  => '000042424262524A4642424200000000',
    'O'  => '00003C42424242424242423C00000000',
    'P'  => '00007C424242427C4040404000000000',
    'Q'  => '00003C424242424242424A3C02000000',
    'R'  => '00007C424242427C5048444200000000',
    'S'  => '00003C4240403C020242423C00000000',
    'T'  => '0000FE10101010101010101000000000',
    'U'  => '00004242424242424242423C00000000',
    'V'  => '00004242424242242424181800000000',
    'W'  => '000082828282829292AAC68200000000',
    'X'  => '00004242242418182424424200000000',
    'Y'  => '00008282444428101010101000000000',
    'Z'  => '00007E02020408102040407E00000000',
    '['  => '00003820202020202020203800000000',

    # ImageMagick's -annotate treats a backslash as an escape, so this one
    # could not be extracted like the rest. It is '/' mirrored, which is
    # what a backslash is.
    '\\' => '00002020101008080404020200000000',
    ']'  => '00003808080808080808083800000000',
    '^'  => '00102844000000000000000000000000',
    '_'  => '000000000000000000000000007E0000',

    # Terminus puts the grave accent in the cell's top leading row,
    # where it merges with whatever is above it. Dropped two rows to
    # cap height, as with the tilde below.
    '`' => '00001008000000000000000000000000',
    'a' => '00000000003C023E4242423E00000000',
    'b' => '00004040407C42424242427C00000000',
    'c' => '00000000003C42404040423C00000000',
    'd' => '00000202023E42424242423E00000000',
    'e' => '00000000003C42427E40403C00000000',
    'f' => '00000E10107C10101010101000000000',
    'g' => '00000000003E42424242423E02023C00',
    'h' => '00004040407C42424242424200000000',
    'i' => '00001010003010101010103800000000',
    'j' => '00000404000C04040404040444443800',
    'k' => '00004040404244487048444200000000',
    'l' => '00003010101010101010103800000000',
    'm' => '0000000000FC92929292929200000000',
    'n' => '00000000007C42424242424200000000',
    'o' => '00000000003C42424242423C00000000',
    'p' => '00000000007C42424242427C40404000',
    'q' => '00000000003E42424242423E02020200',
    'r' => '00000000005E60404040404000000000',
    's' => '00000000003E40403C02027C00000000',
    't' => '00001010107C10101010100E00000000',
    'u' => '00000000004242424242423E00000000',
    'v' => '00000000004242422424181800000000',
    'w' => '00000000008282929292927C00000000',
    'x' => '00000000004242241824424200000000',
    'y' => '00000000004242424242423E02023C00',
    'z' => '00000000007E04081020407E00000000',
    '{' => '00000C10101020101010100C00000000',
    '|' => '00001010101010101010101000000000',
    '}' => '00003008080804080808083000000000',

    # Terminus draws the tilde up at ascender height. Dropped four rows to
    # sit at mid-cell, where CP437 has it and where it stops looking like
    # a glyph that failed to land.
    '~' => '000000000062928C0000000000000000',
    '░' => '88228822882288228822882288228822',
    '▒' => 'AA55AA55AA55AA55AA55AA55AA55AA55',
    '▓' => 'EEBBEEBBEEBBEEBBEEBBEEBBEEBBEEBB',
    '█' => 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
);

# The palette a CGA card had and an EGA or VGA card kept for compatibility:
# eight colours at two intensities, with brown standing in for the dark yellow
# that the hardware's dim-yellow would otherwise have been.
my @CGA = (
    [ 'black',         '#000000' ],
    [ 'blue',          '#0000AA' ],
    [ 'green',         '#00AA00' ],
    [ 'cyan',          '#00AAAA' ],
    [ 'red',           '#AA0000' ],
    [ 'magenta',       '#AA00AA' ],
    [ 'brown',         '#AA5500' ],
    [ 'light grey',    '#AAAAAA' ],
    [ 'dark grey',     '#555555' ],
    [ 'light blue',    '#5555FF' ],
    [ 'light green',   '#55FF55' ],
    [ 'light cyan',    '#55FFFF' ],
    [ 'light red',     '#FF5555' ],
    [ 'light magenta', '#FF55FF' ],
    [ 'yellow',        '#FFFF55' ],
    [ 'white',         '#FFFFFF' ],
);

# Packed once: the effect writes these into a raw RGB buffer thousands of
# times per render and has no use for the hex.
my @PACKED = map { pack 'H*', substr $_->[ 1 ], 1 } @CGA;

=head2 colours()

The sixteen CGA colours as packed three-byte RGB strings, in hardware order --
so index 4 really is the card's red, and a preset naming a number means what
the number meant.

=cut

sub colours { return @PACKED }

=head2 colour_count()

How many there are.

=cut

sub colour_count { return scalar @PACKED }

=head2 colour_name( $index )

What to call one, for documentation and error messages.

=cut

sub colour_name
{
    my ( $index ) = @_;

    return 'unknown' unless $CGA[ $index ];
    return $CGA[ $index ][ 0 ];
}

=head2 glyph( $char )

Sixteen bytes, one per row of the cell, or undef for a character the font does
not have.

=cut

my %ROWS;

sub glyph
{
    my ( $char ) = @_;

    return undef unless defined $char;
    return $ROWS{ $char } if exists $ROWS{ $char };

    my $hex = $GLYPH{ $char };
    return $ROWS{ $char } = undef unless defined $hex;

    return $ROWS{ $char } = [ unpack 'C*', pack 'H*', $hex ];
}

=head2 charset( $name )

The characters one of the named subsets covers, as a list. Fewer than the font
has, deliberately: a corruption made of every printable character including
the ones that are mostly whitespace reads as noise, while one made of capitals
and digits reads as a machine trying to tell you something.

=cut

my %CHARSET = (
    letters => [ 'A' .. 'Z' ],
    digits  => [ 0 .. 9,     'A' .. 'F' ],
    blocks  => [ "\x{2591}", "\x{2592}", "\x{2593}", "\x{2588}" ],

    # By codepoint rather than as a literal string: the punctuation ranges
    # are full of sigils, and a quoted '!"#$%&*' reads like an interpolation
    # somebody forgot to write.
    symbols => [ map { chr } 33 .. 47, 58 .. 64, 91 .. 96, 123 .. 126 ],
);

$CHARSET{ ascii } = [ map { chr } 33 .. 126 ];

$CHARSET{ mixed } = [
    @{ $CHARSET{ letters } },
    @{ $CHARSET{ digits } },
    @{ $CHARSET{ blocks } },
    @{ $CHARSET{ symbols } },
];

sub charset
{
    my ( $name ) = @_;

    my $chars = $CHARSET{ $name // q{} } || $CHARSET{ mixed };
    return @$chars;
}

=head2 charset_names()

The subsets on offer, for the effect's C<enum> declaration.

=cut

sub charset_names
{
    my @names = sort keys %CHARSET;
    return @names;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Effect::Glitch>, which paints with this, and
L<GlitchVape::Fonts> for the TrueType roles the text effects use instead.

=cut
