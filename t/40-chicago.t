#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;

use GlitchVape           ();
use GlitchVape::Chicago  ();
use GlitchVape::Context  ();
use GlitchVape::Pipeline ();
use GlitchVape::Registry ();
use GlitchVape::Tools    ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# The five colours the interface is drawn in, as the test reads them back.
my %INK = (
    F => '192,199,200',
    W => '255,255,255',
    S => '135,136,143',
    K => '0,0,0',
    B => '0,0,168',
    _ => 'clear',
);
my %CHAR = reverse %INK;

# One character per pixel, so that a failure prints a picture of the window
# rather than a list of coordinates.
sub art
{
    my ( $img, $x, $y, $w, $h ) = @_;

    my ( $iw, $ih ) = ( $img->Get( 'width' ), $img->Get( 'height' ) );
    my @px = $img->GetPixels(
        map    => 'RGBA',
        width  => $iw,
        height => $ih
    );

    my @rows;
    for my $row ( $y .. $y + $h - 1 )
    {
        my $line = q{};
        for my $col ( $x .. $x + $w - 1 )
        {
            my $at = ( $row * $iw + $col ) * 4;
            my @c  = map { int( $_ / 257 + 0.5 ) } @px[ $at .. $at + 3 ];

            my $key = $c[ 3 ] < 128 ? 'clear' : join ',', @c[ 0 .. 2 ];
            $line .= $CHAR{ $key } // '?';
        }
        push @rows, $line;
    }

    return \@rows;
}

sub window
{
    my ( %arg ) = @_;

    return GlitchVape::Chicago::render(
        width      => 480,
        height     => 321,
        caption    => undef,
        menu       => ' ',
        font       => undef,
        scrollbars => 1,
        grip       => 1,
        scroll     => 0,
        thumb      => 256 / 420,
        %arg,
    );
}

# ---------------------------------------------------------------------------
# The window it was read off comes back out of it

# The claim the whole module makes: it knows how a Windows 95 window is put
# together, rather than keeping a picture of one. So a window asked for at the
# size of the screenshot every measurement came from has to be that
# screenshot, pixel for pixel -- not close, not similar, the same.
#
# These are the parts that carry the claim. Not checked: the document area,
# which is a hole here and white there; the caption and menu strings, which
# are set in a font rather than scavenged; and the vertical scroll bar, which
# in the screenshot is a *disabled* one -- empty Notepad -- with embossed grey
# arrows and no thumb.
{
    my $win = window();

    is join( 'x', $win->Get( 'width' ), $win->Get( 'height' ) ), '480x321',
        'the window comes back at the size it was asked for';

    # The sizing border, at all four corners. Raised: face and white going in
    # at the top left, shadow and black coming out at the bottom right, with
    # two pixels of plain face between them.
    is_deeply art( $win, 0, 0, 6, 6 ),
        [ 'FFFFFF', 'FWWWWW', 'FWFFFF', 'FWFFFF', 'FWFFBB', 'FWFFBB', ],
        'the top left corner of the sizing border';

    is_deeply art( $win, 474, 315, 6, 6 ),
        [ 'FWFFSK', 'WWFFSK', 'FFFFSK', 'FFFFSK', 'SSSSSK', 'KKKKKK', ],
        'and the bottom right, which is the same edge turned over';

    # The caption's own furniture: the document icon against the blue, and the
    # three buttons at the other end. The gap before Close is two pixels and
    # there is none between the other two, which is Windows keeping the button
    # that closes the window away from the two that do not.
    is_deeply art( $win, 4, 4, 20, 18 ),
        [
        'BBBBBBBBBBBBBBBBBBBB', 'BBBBKBKBKBKBKBBBBBBB',
        'BBBKWSWSWSWSWKBBBBBB', 'BBSWKWKWKWKWKWKBBBBB',
        'BBSWWWWWWWWWWFKBBBBB', 'BBSWWWWWWWWWWFKBBBBB',
        'BBSWWKKKWKKWWFKBBBBB', 'BBSWWWWWWWWWWFKBBBBB',
        'BBSWWKKKKKKWWFKBBBBB', 'BBSWWWWWWWWWWFKBBBBB',
        'BBSWWKKKKKKWWFKBBBBB', 'BBSWWWWWWWWWWFKBBBBB',
        'BBSWWKKKKKKWWFKBBBBB', 'BBSWWWWWWWWWWFKBBBBB',
        'BBSWWWWWWWWWWFKBBBBB', 'BBSFFFFFFFFFFFKBBBBB',
        'BBBKKKKKKKKKKKBBBBBB', 'BBBBBBBBBBBBBBBBBBBB',
        ],
        'the document icon, sitting two pixels in and one down';

    is_deeply art( $win, 456, 4, 20, 18 ),
        [
        'BBBBBBBBBBBBBBBBBBBB', 'BBBBBBBBBBBBBBBBBBBB',
        'BBWWWWWWWWWWWWWWWKBB', 'BBWFFFFFFFFFFFFFSKBB',
        'BBWFFFFFFFFFFFFFSKBB', 'BBWFFFKKFFFFKKFFSKBB',
        'BBWFFFFKKFFKKFFFSKBB', 'BBWFFFFFKKKKFFFFSKBB',
        'BBWFFFFFFKKFFFFFSKBB', 'BBWFFFFFKKKKFFFFSKBB',
        'BBWFFFFKKFFKKFFFSKBB', 'BBWFFFKKFFFFKKFFSKBB',
        'BBWFFFFFFFFFFFFFSKBB', 'BBWFFFFFFFFFFFFFSKBB',
        'BBWSSSSSSSSSSSSSSKBB', 'BBKKKKKKKKKKKKKKKKBB',
        'BBBBBBBBBBBBBBBBBBBB', 'BBBBBBBBBBBBBBBBBBBB',
        ],
        'and the Close button, whose top edge is white and not face';
}

# ---------------------------------------------------------------------------
# A caption button and a scroll-bar button are lit differently

# Two pixels apart on the same window and they do not agree: the caption
# button's outer highlight is white, the scroll-bar button's is face, with the
# white a ring further in. It reads as one being softer than the other, and it
# is the sort of thing that gets flattened to one bevel by anybody redrawing
# this from memory.
{
    my $win = window();

    my $caption = art( $win, 458, 6,  4, 3 );
    my $scroll  = art( $win, 458, 44, 4, 3 );

    is $caption->[ 0 ], 'WWWW', 'a caption button is lit white on its top row';
    is $scroll->[ 0 ],  'FFFF', 'a scroll-bar button is lit face';
    is $scroll->[ 1 ],  'FWWW', 'and carries its white a ring further in';
}

# ---------------------------------------------------------------------------
# The scroll bar the screenshot has enabled, to the pixel

# Arrow buttons, the fifty-per-cent track and the thumb, all read off the
# bottom bar of the same screenshot. The dither is phased on the window's own
# corner rather than on the bar's, which is what makes the two bars agree
# about which square is which where they meet.
{
    my $win = window();

    is_deeply art( $win, 6, 299, 18, 16 ),
        [
        'FFFFFFFFFFFFFFFKFF', 'FWWWWWWWWWWWWWSKFW',
        'FWFFFFFFFFFFFFSKFW', 'FWFFFFFFFFFFFFSKFW',
        'FWFFFFFFKFFFFFSKFW', 'FWFFFFFKKFFFFFSKFW',
        'FWFFFFKKKFFFFFSKFW', 'FWFFFKKKKFFFFFSKFW',
        'FWFFFFKKKFFFFFSKFW', 'FWFFFFFKKFFFFFSKFW',
        'FWFFFFFFKFFFFFSKFW', 'FWFFFFFFFFFFFFSKFW',
        'FWFFFFFFFFFFFFSKFW', 'FWFFFFFFFFFFFFSKFW',
        'FSSSSSSSSSSSSSSKFS', 'KKKKKKKKKKKKKKKKKK',
        ],
        'the left arrow button, and the thumb starting immediately after it';

    is_deeply art( $win, 274, 299, 10, 4 ),
        [ 'FFFKWFWFWF', 'WWSKFWFWFW', 'FFSKWFWFWF', 'FFSKFWFWFW', ],
        'where the thumb ends and the dithered track begins';
}

# ---------------------------------------------------------------------------
# The sizing grip, in the square the two bars leave

{
    my $win = window();

    is_deeply art( $win, 466, 307, 8, 8 ),
        [
        'FFFWSSFW', 'FFWSSFWS', 'FWSSFWSS', 'WSSFWSSF',
        'SSFWSSFW', 'SFWSSFWS', 'FWSSFWSS', 'WSSFWSSF',
        ],
        'three ribs on a four-pixel diagonal';
}

# ---------------------------------------------------------------------------
# The hole is a hole

# The point of the effect. Everything inside the well and outside the scroll
# bars has to be transparent, or the window is an opaque grey box with a
# picture round it.
{
    my $win = window();

    my $rows  = art( $win, 6, 44, 452, 255 );
    my @solid = grep { !m{\A _+ \z}x } @$rows;

    is scalar @solid, 0, 'the document area is transparent to the last pixel';

    # And bounded: one pixel further out in each direction is the well's own
    # edge, which is not.
    is substr( art( $win, 5, 44, 1, 1 )->[ 0 ], 0, 1 ), 'K',
        'the well is still drawn on the left of it';
    is substr( art( $win, 6, 43, 1, 1 )->[ 0 ], 0, 1 ), 'K', 'and above it';
}

# ---------------------------------------------------------------------------
# Asked for a window too small to be one

# A caption with three buttons and an icon does not shrink, so there is a size
# below which the parts would overlap. render() clamps up to it rather than
# drawing them on top of each other.
{
    my ( $min_w, $min_h ) = GlitchVape::Chicago::minimum(
        scrollbars => 1,
        menu       => 'x'
    );

    ok $min_w > 0 && $min_h > 0, 'there is a smallest window';

    my $tiny = GlitchVape::Chicago::render(
        width      => 4,
        height     => 4,
        caption    => 'a caption far too long for it',
        menu       => 'x',
        font       => undef,
        scrollbars => 1,
        grip       => 1,
        scroll     => 0.5,
        thumb      => 0.4,
    );

    is join( 'x', $tiny->Get( 'width' ), $tiny->Get( 'height' ) ),
        "${min_w}x${min_h}",
        'and a window asked to be smaller comes back at it';

    # Its caption buttons are still whole, which is what the clamp is for.
    is substr( art( $tiny, $min_w - 4 - 2 - 16, 6, 16, 1 )->[ 0 ], 0, 16 ),
        'WWWWWWWWWWWWWWWK',
        'with the Close button drawn in full rather than cropped';
}

# ---------------------------------------------------------------------------
# The parts that can be left out, leave out

{
    my $bare = window( scrollbars => 0, menu => undef );

    # No menu bar means the well starts eighteen pixels higher, not that a
    # blank grey strip is drawn.
    is substr( art( $bare, 4, 22, 2, 1 )->[ 0 ], 0, 2 ), 'SS',
        'with no menu the well begins where the menu bar would have';

    # And with no scroll bars the hole runs to the well's own edge.
    my $rows = art( $bare, 6, 24, 468, 1 );
    like $rows->[ 0 ], qr/\A _+ \z/x,
        'and with no scroll bars the hole runs the whole width of the well';
}

# ---------------------------------------------------------------------------
# The effect puts it on the picture without changing the picture's size

{
    my $src = Image::Magick->new( size => '640x480' );
    $src->Read( 'xc:#204060' );

    my $ctx = GlitchVape::Context->new( image => $src, seed => 5 );
    GlitchVape::Pipeline->new( effects => { chicago => {} } )->run( $ctx );

    is join( 'x', $ctx->image->Get( 'width' ), $ctx->image->Get( 'height' ) ),
        '640x480', 'the picture comes out the size it went in';

    # The corners are outside a window 72% of the picture, so they are still
    # the picture. If they were not, the window would be painting its own
    # background over everything.
    my @corner = $ctx->image->GetPixels(
        map    => 'RGB',
        x      => 2,
        y      => 2,
        width  => 1,
        height => 1
    );

    is_deeply [ map { int( $_ / 257 + 0.5 ) } @corner ], [ 32, 64, 96 ],
        'and the picture is untouched outside the window';
}

# ---------------------------------------------------------------------------
# Zoom is replication, never interpolation

# The whole reason zoom is a whole number. Enlarged four times, every pixel of
# the window has to be a four-by-four square of exactly one of the five
# colours -- one grey that is none of them is an interpolated edge, and an
# interpolated one-pixel highlight is what stops a bevel reading as raised.
{
    my $src = Image::Magick->new( size => '400x300' );
    $src->Read( 'xc:black' );

    my $ctx = GlitchVape::Context->new( image => $src, seed => 5 );
    GlitchVape::Pipeline->new(
        effects => {
            chicago => { zoom => 4, width => 0.9, height => 0.9, title => q{} }
        }
    )->run( $ctx );

    my ( $w, $h ) = ( 400, 300 );
    my @px = $ctx->image->GetPixels(
        map    => 'RGB',
        width  => $w,
        height => $h
    );

    my %seen;
    for my $at ( 0 .. $w * $h - 1 )
    {
        my @c = map { int( $_ / 257 + 0.5 ) } @px[ $at * 3 .. $at * 3 + 2 ];
        $seen{ join ',', @c }++;
    }

    my @unexpected =
        grep { !exists $CHAR{ $_ } && $_ ne '0,0,0' } sort keys %seen;

    is_deeply \@unexpected, [],
        'a window enlarged four times is still only the colours it is drawn in'
        or diag "interpolated: @unexpected";
}

# ---------------------------------------------------------------------------
# The declaration says what the parameters are for

# Three of them only mean anything when there are scroll bars to mean it
# about, and saying so is what greys the controls in the window instead of
# leaving them live and inert.
{
    my $effect = GlitchVape::Registry->get( 'chicago' );

    ok $effect, 'the effect is registered';
    is $effect->{ stage }, 'overlay',
        'in the stage that draws on top of the picture';

    for my $key ( qw(grip thumb scroll) )
    {
        is_deeply $effect->{ params }{ $key }{ needs }, { scrollbars => 1 },
            "$key says it depends on there being scroll bars";
    }
}

done_testing;
