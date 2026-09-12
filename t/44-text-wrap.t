#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Encode      ();
use File::Temp  ();
use Test::More;

use GlitchVape                  ();
use GlitchVape::Context         ();
use GlitchVape::Effect::Overlay ();
use GlitchVape::Fonts           ();
use GlitchVape::Pipeline        ();
use GlitchVape::Tools           ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# Where the lines of a wrapped phrase fall.
#
# The question is asked of the layout rather than of the render because it is a
# question about breaks: how many lines there are, which character starts each
# of them, and whether the phrase survived being broken. A picture of the text
# answers none of those without reading it back off the pixels, and the two
# failures that matter here -- a phrase that comes out one letter per line and
# a line beginning with a full stop -- are both perfectly legible mistakes.
#
# The width is measured with the same font metrics the layout uses, so what is
# being checked is that the limit was obeyed and not that the two agree about
# how wide a word is. That they agree is the point of measuring at all: a
# character count against an average advance wraps proportional type wrongly,
# and wrongly in the direction that looks deliberate.

my $dir = File::Temp->newdir( 'gv_wrap_XXXXXX', TMPDIR => 1 );

my $src = "$dir/src.png";
{
    my $img = Image::Magick->new( size => '640x480' );
    $img->Read( 'xc:#202040' );
    my $err = $img->Write( $src );
    BAIL_OUT( "could not build the test source image: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;
}

my $ctx = GlitchVape::Context->new(
    image  => do { my $i = Image::Magick->new; $i->Read( $src ); $i },
    source => $src,
    seed   => 3,
);

# A face that can draw both halves of the suite: the Japanese phrases the
# effect picks from by default, and the English one a typed string is likely to
# be. Which file that is depends on the machine, which is the whole point of
# asking fontconfig rather than naming one.
my $font = GlitchVape::Fonts::resolve( 'cjk' )
    || GlitchVape::Fonts::resolve( 'sans' );
plan skip_all => 'no font resolved to lay text out with' unless $font;

my $SIZE = 36;

sub lay_out
{
    my ( $string, %p ) = @_;

    my %params = ( wrap => 0, spacing => 0, %p );

    return GlitchVape::Effect::Overlay::_lay_out( $ctx, $string, \%params,
        $font, $SIZE, 640 );
}

sub lines_of { return split /\n/, lay_out( @_ ), -1 }

sub width_of
{
    my ( $line ) = @_;

    my @metrics = $ctx->image->QueryFontMetrics(
        text      => Encode::encode( 'UTF-8', $line ),
        font      => $font,
        pointsize => $SIZE,
        encoding  => 'UTF-8',
        antialias => 'true',
    );

    return $metrics[ 4 ] // 0;
}

# ---------------------------------------------------------------------------
# A phrase in a script with spaces breaks at them and nowhere else

my $english = 'The quick brown fox jumps over the lazy dog';

{
    my @lines = lines_of( $english, wrap => 0.5 );

    cmp_ok scalar @lines, '>', 1, 'a long phrase is broken into lines';

    my $over = grep { width_of( $_ ) > 640 * 0.5 } @lines;
    is $over, 0, 'and no line is wider than the width it was given';

    is join( ' ', @lines ), $english,
        'and the words are all there, in order, with nothing cut';

    my $split_word = grep { !/\A(?:\w+\s*)+\z/ } @lines;
    is $split_word, 0, 'no line ends mid-word';
}

# The width is a fraction of the picture and not a count of characters, so
# halving it has to produce more lines of the same phrase.
{
    my @wide   = lines_of( $english, wrap => 0.8 );
    my @narrow = lines_of( $english, wrap => 0.3 );

    cmp_ok scalar @narrow, '>', scalar @wide,
        'a narrower width breaks the same phrase into more lines';
}

# ---------------------------------------------------------------------------
# A phrase in a script without spaces breaks between characters

my $japanese = 'ヴェイパーウェイブ、現実を超えて。無限の夢';

{
    my @lines = lines_of( $japanese, wrap => 0.45 );

    cmp_ok scalar @lines, '>', 1,
        'Japanese wraps although it contains no spaces at all';

    is join( q{}, @lines ), $japanese,
        'and every character survives the break';

    # Kinsoku shori, the half of it that matters: a line may not begin with a
    # full stop, a closing bracket, a long vowel mark or a small kana, because
    # each of those belongs to the character before it. The rule is what makes
    # a line run one character over its width on purpose, so a wrap that
    # obeyed the width exactly would be the bug.
    my $no_start = qr/\A[、。・？！」』ーぁぃぅぇぉっゃゅょァィゥェォッャュョ]/;
    my @bad = grep { /$no_start/ } @lines;

    is scalar @bad, 0, 'and no line begins with one that cannot start a line'
        or diag 'offending lines: ' . join ' | ', @bad;
}

# ---------------------------------------------------------------------------
# What the settings mean at their edges

is scalar( () = lines_of( $english, wrap => 0 ) ), 1,
    'a wrap of 0 leaves the phrase on one line however long it is';

{
    # The only newline a one-line entry can produce, and the reason the escape
    # is honoured at all: the window has no multi-line box to type into.
    my @lines = lines_of( 'LINE ONE\nLINE TWO' );

    is scalar @lines, 2, 'a typed \n breaks a line with no wrap width set';
    is $lines[ 0 ], 'LINE ONE', 'before the escape';
    is $lines[ 1 ], 'LINE TWO', 'and after it';
}

{
    # Tracking inserts spaces between every character, so a phrase tracked
    # before it was wrapped would offer a break opportunity between every pair
    # of letters -- one letter per line, which is what this pins against.
    my @lines = lines_of( 'AA BB CC DD EE FF', wrap => 0.5, spacing => 24 );

    my $single = grep { /\A\S\z/ } @lines;
    is $single, 0,
        'tracking does not turn a wrapped phrase into one letter per line';

    my $over = grep { width_of( $_ ) > 640 * 0.5 } @lines;
    is $over, 0, 'and the width that is obeyed is the width once tracked';
}

# A word too wide for the limit is still drawn: a wrap narrower than one word
# is a setting to survive rather than to obey to the letter.
{
    my @lines = lines_of( 'Unconscionable', wrap => 0.05 );

    is scalar @lines, 1, 'a single word wider than the wrap is left whole';
}

# ---------------------------------------------------------------------------
# The effect itself

# Wrapping is layout and not content: the same phrase, drawn on more lines, is
# still the same phrase. What this asks is that the parameters reach the
# render at all -- the pipeline resolves them, the annotation accepts a
# multi-line string, and leading changes what comes out.
{
    my %common = (
        invent  => 0,
        string  => $english,
        font    => 'sans',
        size    => 8,
        gravity => 'Center',
        x       => 0,
        y       => 0,
    );

    my %rendered;
    for my $case (
        [ 'flat',    { wrap => 0 } ],
        [ 'wrapped', { wrap => 0.5 } ],
        [ 'leaded',  { wrap => 0.5, leading => 0.6 } ],
        )
    {
        my ( $label, $set ) = @$case;

        my $img = Image::Magick->new;
        $img->Read( $src );

        my $one = GlitchVape::Context->new(
            image  => $img,
            source => $src,
            seed   => 3,
        );

        GlitchVape::Pipeline->new( effects => { text => { %common, %$set } } )
            ->run( $one );

        $rendered{ $label } = $one->image->Get( 'signature' );
    }

    isnt $rendered{ flat }, $rendered{ wrapped },
        'a wrapped phrase renders differently from the same one on a line';
    isnt $rendered{ wrapped }, $rendered{ leaded },
        'and line spacing changes where the lines sit';
}

done_testing;
