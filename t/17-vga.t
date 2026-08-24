#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use GlitchVape::VGA ();

# The font is data rather than code, so what is worth testing is that the data
# is the shape the effect assumes and that the glyphs are actually glyphs --
# a table of the right size full of blanks would satisfy anything weaker.

# ---------------------------------------------------------------------------
# The cell

{
    is GlitchVape::VGA::CELL_W, 8,  'a cell is eight pixels wide';
    is GlitchVape::VGA::CELL_H, 16, 'and sixteen tall';
}

# ---------------------------------------------------------------------------
# Coverage

{
    my @missing;

    for my $code ( 32 .. 126 )
    {
        push @missing, $code unless GlitchVape::VGA::glyph( chr $code );
    }

    is_deeply \@missing, [], 'every printable ASCII character has a glyph';

    for my $block ( "\x{2591}", "\x{2592}", "\x{2593}", "\x{2588}" )
    {
        ok GlitchVape::VGA::glyph( $block ),
            sprintf( 'the CP437 shade block U+%04X is there', ord $block );
    }

    is GlitchVape::VGA::glyph( "\x{263A}" ), undef,
        'and a character the font does not have is undef rather than blank';
    is GlitchVape::VGA::glyph( undef ), undef, 'as is nothing at all';
}

# ---------------------------------------------------------------------------
# Shape

{
    for my $char ( 'A', 'g', '0', "\x{2588}" )
    {
        my $rows = GlitchVape::VGA::glyph( $char );

        is scalar @$rows, 16, "'$char' is sixteen rows";

        my @wide = grep { $_ < 0 || $_ > 255 } @$rows;
        is scalar @wide, 0, "'$char' is one byte a row";
    }

    # Space is the only thing in the font that is allowed to be empty. A
    # blank anywhere else means a glyph failed to extract, which would show
    # up as a hole in the corruption rather than as an error.
    my @blank;

    for my $code ( 33 .. 126 )
    {
        my $rows = GlitchVape::VGA::glyph( chr $code ) or next;

        my $lit = 0;
        $lit += $_ for @$rows;

        push @blank, sprintf( 'U+%04X', $code ) unless $lit;
    }

    is_deeply \@blank, [], 'no printable character is accidentally blank';

    my $space = GlitchVape::VGA::glyph( ' ' );
    my $lit   = 0;
    $lit += $_ for @$space;
    is $lit, 0, 'and space is deliberately blank';
}

{
    # The cell has one blank row of leading top and bottom, which is what
    # stops lines of text merging into each other.
    my @touching;

    for my $code ( 32 .. 126 )
    {
        my $rows = GlitchVape::VGA::glyph( chr $code ) or next;
        push @touching, sprintf( 'U+%04X', $code )
            if $rows->[ 0 ] || $rows->[ 15 ];
    }

    is_deeply \@touching, [],
        'no ASCII glyph touches the top or bottom of its cell';

    # The full block is the exception, and has to be: it is the character
    # that fills the cell.
    my $full = GlitchVape::VGA::glyph( "\x{2588}" );
    is $full->[ 0 ],  255, 'the full block fills its top row';
    is $full->[ 15 ], 255, 'and its bottom one';
}

{
    # The shade blocks are dither patterns, so alternate rows must differ --
    # a solid grey would mean the pattern was lost somewhere.
    my $half = GlitchVape::VGA::glyph( "\x{2592}" );

    isnt $half->[ 0 ], $half->[ 1 ],
        'the 50% shade block alternates between rows';
    is $half->[ 0 ], $half->[ 2 ], 'and repeats every two';
}

{
    # A letter and its mirror. '/' and '\\' are the same glyph reflected, and
    # getting one of them backwards is the kind of thing nobody notices by
    # eye in a field of corruption.
    my $slash = GlitchVape::VGA::glyph( '/' );
    my $back  = GlitchVape::VGA::glyph( "\\" );

    my @mirrored;

    for my $byte ( @$slash )
    {
        my $out = 0;

        for my $bit ( 0 .. 7 )
        {
            $out |= 1 << ( 7 - $bit ) if $byte & ( 1 << $bit );
        }

        push @mirrored, $out;
    }

    is_deeply $back, \@mirrored, 'backslash is slash reflected';
}

# ---------------------------------------------------------------------------
# The palette

{
    is GlitchVape::VGA::colour_count(), 16, 'CGA had sixteen colours';

    my @colours = GlitchVape::VGA::colours();
    is scalar @colours, 16, 'and there are sixteen of them';

    my @wrong = grep { length != 3 } @colours;
    is scalar @wrong, 0, 'each is three packed bytes, ready for the buffer';

    # Hardware order matters: a preset naming a number means what the number
    # meant on the card.
    is unpack( 'H*', $colours[ 0 ] ),  '000000', 'index 0 is black';
    is unpack( 'H*', $colours[ 4 ] ),  'aa0000', 'index 4 is red';
    is unpack( 'H*', $colours[ 15 ] ), 'ffffff', 'index 15 is white';

    is GlitchVape::VGA::colour_name( 6 ), 'brown',
        'index 6 is brown, the one the hardware faked';
    is GlitchVape::VGA::colour_name( 99 ), 'unknown',
        'and an index off the end says so rather than dying';

    # Every colour distinct, or the effect could pick a foreground equal to
    # its background and draw nothing.
    my %seen;
    $seen{ $_ }++ for @colours;
    is scalar( keys %seen ), 16, 'no two CGA colours are the same';
}

# ---------------------------------------------------------------------------
# Character sets

{
    my @names = GlitchVape::VGA::charset_names();
    cmp_ok scalar @names, '>=', 4, 'there are several named subsets';

    for my $name ( @names )
    {
        my @chars = GlitchVape::VGA::charset( $name );
        cmp_ok scalar @chars, '>', 0, "$name has characters in it";

        my @absent = grep { !GlitchVape::VGA::glyph( $_ ) } @chars;
        is scalar @absent, 0,
            "every character in $name has a glyph to draw it with";
    }

    my @letters = GlitchVape::VGA::charset( 'letters' );
    is scalar @letters, 26, 'letters is the alphabet';

    # An unknown name falls back rather than returning nothing: the effect
    # would otherwise draw an empty frame for a typo in a preset.
    my @fallback = GlitchVape::VGA::charset( 'nonesuch' );
    cmp_ok scalar @fallback, '>', 0,
        'an unknown subset falls back to one ' . 'that exists';
}

done_testing;
