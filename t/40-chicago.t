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
use GlitchVape::Fonts    ();
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

# The top-left of the caption bar, by its blue, which on a flat dark source is
# the only blue there is. Where the window put itself, in other words.
sub caption_corner
{
    my ( $img, $w, $h ) = @_;

    my @px = $img->GetPixels(
        map       => 'RGB',
        width     => $w,
        height    => $h,
        normalize => 1
    );

    for my $y ( 0 .. $h - 1 )
    {
        for my $x ( 0 .. $w - 1 )
        {
            my $i = ( $y * $w + $x ) * 3;

            next
                unless $px[ $i ] < 0.02
                && $px[ $i + 1 ] < 0.02
                && abs( $px[ $i + 2 ] - 168 / 255 ) < 0.02;

            return ( $x, $y );
        }
    }

    return ( undef, undef );
}

# One frame of a window with a jitter on it, and where it landed.
sub danced
{
    my ( %arg ) = @_;

    my $w = $arg{ width };
    my $h = $arg{ height };

    my $img = Image::Magick->new( size => "${w}x${h}" );
    $img->Read( 'xc:#101018' );

    my $ctx = GlitchVape::Context->new( image => $img, seed => 5 );
    $ctx->frames( $arg{ frames } );
    $ctx->frame( $arg{ frame } );

    GlitchVape::Pipeline->new( effects => { chicago => $arg{ set } } )
        ->run( $ctx );

    return ( caption_corner( $ctx->image, $w, $h ), $ctx->image );
}

# Coverage across the middle of an 'l', in pixels. Antialiasing on, because
# what is being measured is the outline and not the rasteriser's opinion of
# it: a stem that covers six tenths of one pixel and four tenths of the next
# is six tenths and four tenths, whatever a hard rasteriser would make of it.
sub stem_width
{
    my ( $font, $size ) = @_;

    my $probe = Image::Magick->new( size => '80x80' );
    $probe->Read( 'xc:none' );
    $probe->Annotate(
        text      => 'l',
        font      => $font,
        pointsize => $size,
        fill      => 'black',
        gravity   => 'NorthWest',
        x         => 20,
        y         => 20,
        antialias => 'true',
    );

    my @px = $probe->GetPixels(
        map       => 'A',
        width     => 80,
        height    => 80,
        normalize => 1
    );

    my @rows = grep {
        my $y = $_;
        grep { $px[ $y * 80 + $_ ] > 0 } 0 .. 79
    } 0 .. 79;
    return 0 unless @rows;

    my $mid = $rows[ $#rows / 2 ];
    my $sum = 0;
    $sum += $px[ $mid * 80 + $_ ] for 0 .. 79;

    return $sum;
}

# Every colour a finished render used, as a hash.
sub inks_used
{
    my ( $img, $w, $h ) = @_;

    my @px = $img->GetPixels( map => 'RGB', width => $w, height => $h );

    my %seen;
    for my $at ( 0 .. $w * $h - 1 )
    {
        my @c = map { int( $_ / 257 + 0.5 ) } @px[ $at * 3 .. $at * 3 + 2 ];
        $seen{ join ',', @c }++;
    }

    return \%seen;
}

# What type_size promises, asked of one font role: never below the size the
# interface wants, never above the bar it has to fit, and at the size it gives
# the stem reaches a whole pixel -- which is the property the whole
# measurement exists for. Returns whether there was a font to ask at all.
sub drawable
{
    my ( $role ) = @_;

    my $font = GlitchVape::Fonts::resolve( $role ) or return 0;
    my $size = GlitchVape::Chicago::type_size( $font );

    cmp_ok $size, '>=', 12, "$role is never drawn below the interface size";
    cmp_ok $size, '<=', 20, "$role is never talked up past the bar it fits";

    cmp_ok stem_width( $font, $size ), '>=', 1,
        "at $size the $role stem covers a whole pixel";

    # And it is the *smallest* such size, not merely a safe one -- which is
    # only a claim where the font needed talking up at all.
    return 1 unless $size > 12;

    cmp_ok stem_width( $font, $size - 1 ), '<', 1,
        "and one pixel smaller it would not, which is why $role was raised";

    return 1;
}

# One theme rendered, and the check that it is drawn only in the inks it
# declares. Returns the signature, so the caller can also say the themes
# differ from one another.
sub only_its_own_colours
{
    my ( $theme, $palette ) = @_;

    my %ink = map { $_ => 1 } @$palette;

    my $src = Image::Magick->new( size => '400x300' );
    $src->Read( 'xc:black' );

    my $ctx = GlitchVape::Context->new( image => $src, seed => 5 );
    GlitchVape::Pipeline->new(
        effects => {
            chicago =>
                { theme => $theme, zoom => 3, width => 0.9, height => 0.9 }
        }
    )->run( $ctx );

    my $seen  = inks_used( $ctx->image, 400, 300 );
    my @stray = grep { !$ink{ $_ } && $_ ne '0,0,0' } sort keys %$seen;

    is_deeply \@stray, [], "$theme is drawn only in its own colours"
        or diag "not in the $theme palette: @stray";

    return $ctx->image->Get( 'signature' );
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

    is_deeply art( $win, 422, 4, 20, 18 ),
        [
        'BBBBBBBBBBBBBBBBBBBB', 'BBBBBBBBBBBBBBBBBBBB',
        'BBWWWWWWWWWWWWWWWKWW', 'BBWFFFFFFFFFFFFFSKWF',
        'BBWFFFFFFFFFFFFFSKWF', 'BBWFFFFFFFFFFFFFSKWF',
        'BBWFFFFFFFFFFFFFSKWF', 'BBWFFFFFFFFFFFFFSKWF',
        'BBWFFFFFFFFFFFFFSKWF', 'BBWFFFFFFFFFFFFFSKWF',
        'BBWFFFFFFFFFFFFFSKWF', 'BBWFFFKKKKKKFFFFSKWF',
        'BBWFFFKKKKKKFFFFSKWF', 'BBWFFFFFFFFFFFFFSKWF',
        'BBWSSSSSSSSSSSSSSKWS', 'BBKKKKKKKKKKKKKKKKKK',
        'BBBBBBBBBBBBBBBBBBBB', 'BBBBBBBBBBBBBBBBBBBB',
        ],
        'the Minimise button, whose bar sits low and left rather than centred';

    is_deeply art( $win, 438, 4, 20, 18 ),
        [
        'BBBBBBBBBBBBBBBBBBBB', 'BBBBBBBBBBBBBBBBBBBB',
        'WKWWWWWWWWWWWWWWWKBB', 'SKWFFFFFFFFFFFFFSKBB',
        'SKWFFKKKKKKKKKFFSKBB', 'SKWFFKKKKKKKKKFFSKBB',
        'SKWFFKFFFFFFFKFFSKBB', 'SKWFFKFFFFFFFKFFSKBB',
        'SKWFFKFFFFFFFKFFSKBB', 'SKWFFKFFFFFFFKFFSKBB',
        'SKWFFKFFFFFFFKFFSKBB', 'SKWFFKFFFFFFFKFFSKBB',
        'SKWFFKKKKKKKKKFFSKBB', 'SKWFFFFFFFFFFFFFSKBB',
        'SKWSSSSSSSSSSSSSSKBB', 'KKKKKKKKKKKKKKKKKKBB',
        'BBBBBBBBBBBBBBBBBBBB', 'BBBBBBBBBBBBBBBBBBBB',
        ],
        'and Maximise, which does come out centred -- written down anyway, '
        . 'because a formula that agrees by coincidence is not a rule';

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

    my $seen = inks_used( $ctx->image, 400, 300 );

    my @unexpected =
        grep { !exists $CHAR{ $_ } && $_ ne '0,0,0' } sort keys %$seen;

    is_deeply \@unexpected, [],
        'a window enlarged four times is still only the colours it is drawn in'
        or diag "interpolated: @unexpected";
}

# ---------------------------------------------------------------------------
# The lettering is drawn at a size the font can actually be drawn at

# The bug this exists for: with antialiasing off a rasteriser inks a pixel
# when the pixel's *centre* falls inside the outline, so a stem narrower than
# one pixel lands between two centres for some of the positions it can be in
# and vanishes. Not for all of them, which is what made it look like a corrupt
# font rather than a size one pixel too small -- at twelve pixels W95FA writes
# 'File' as 'Fıle' and 'Help' intact.
#
# So the claim is exactly this: at the size type_size picks, the stem of an
# 'l' covers a whole pixel. Asked of the stem rather than of a word, because
# whether a particular word survives depends on where its glyphs happen to
# land and this does not.
{

    is GlitchVape::Chicago::type_size( undef ), 12,
        'with no font there is nothing to measure and the interface size stands';

    my $roles = 0;
    $roles += drawable( $_ ) for GlitchVape::Fonts::roles();

    ok $roles, 'there was at least one font to ask';
}

# ---------------------------------------------------------------------------
# And the caller can overrule the measurement

{
    my $font = GlitchVape::Fonts::resolve( 'ui' );

SKIP:
    {
        skip 'no ui font', 1 unless $font;

        my $big = GlitchVape::Chicago::render(
            width      => 480,
            height     => 321,
            caption    => 'Untitled',
            menu       => undef,
            font       => $font,
            type_size  => 18,
            scrollbars => 0,
            grip       => 0,
            scroll     => 0,
            thumb      => 0.5,
        );

        my $measured = GlitchVape::Chicago::render(
            width      => 480,
            height     => 321,
            caption    => 'Untitled',
            menu       => undef,
            font       => $font,
            scrollbars => 0,
            grip       => 0,
            scroll     => 0,
            thumb      => 0.5,
        );

        isnt $big->Get( 'signature' ), $measured->Get( 'signature' ),
            'an explicit type_size is used instead of the measured one';
    }

SKIP:
    {
        my $size = GlitchVape::Chicago::type_size( $font );
        skip 'no ui font',                                 2 unless $font;
        skip 'this font wanted the interface size anyway', 2 unless $size > 12;

        # That render() asks for the measurement rather than merely offering
        # it. Left unpinned, a window drawn at a flat twelve would still pass
        # every other test in this file and still be the bug.
        my $window = sub {
            my ( %arg ) = @_;

            return GlitchVape::Chicago::render(
                width      => 480,
                height     => 321,
                caption    => 'Untitled',
                menu       => undef,
                font       => $font,
                scrollbars => 0,
                grip       => 0,
                scroll     => 0,
                thumb      => 0.5,
                %arg,
            )->Get( 'signature' );
        };

        is $window->(), $window->( type_size => $size ),
            'a window drawn without a size is drawn at the measured one';

        isnt $window->(), $window->( type_size => 12 ),
            'and not at the size the interface would have asked for';
    }
}

# ---------------------------------------------------------------------------
# The jitter closes its loop, and leaves a still alone

# The two properties t/31-drift.t applies to every effect that declares a
# 'drift'. This one is not a drift -- it goes nowhere, it shakes in place --
# so it is outside that sweep and has to say them here instead.
#
# Closing matters for the ordinary reason: a video plays a loop end to end and
# then starts it over, so a last frame that does not come back to the first
# puts a jolt in at the join, once per repeat, for as long as the file plays.
# What makes it possible to close something this random is Context::rng_phase,
# which keys the roll on the frame's position around the loop rather than on
# its index -- see t/31-drift.t, where that stream is pinned.
#
# Leaving a still alone matters because presets carry the parameter: rendering
# one as a still has to give the picture it gave before the parameter existed,
# whatever it is set to.
{
    my $frames = 12;

    my $frame = sub {
        my ( $n, $at ) = @_;

        my ( undef, undef, $img ) = danced(
            width  => 240,
            height => 180,
            frames => $at,
            frame  => $n,
            set    => { jitter => 7, width => 0.7, height => 0.7 },
        );

        return $img->Get( 'signature' );
    };

    is $frame->( $frames, $frames ), $frame->( 0, $frames ),
        'the frame after the last one is the first one again';

    my $still = sub {
        my ( $jitter ) = @_;

        my ( undef, undef, $img ) = danced(
            width  => 240,
            height => 180,
            frames => 1,
            frame  => 0,
            set    => { jitter => $jitter, width => 0.7, height => 0.7 },
        );

        return $img->Get( 'signature' );
    };

    is $still->( 24 ), $still->( 0 ),
        'and a still is the picture it would have been without the setting';
}

# ---------------------------------------------------------------------------
# The window dances, and it is the same window that dances

# What the two checks above cannot say: that the window *moves rather than
# changes*. A jitter that redrew the window somewhere else, or redrew it
# differently, would satisfy both of them.
{
    my $frames = 12;
    my $most   = 3;

    # Small and flat, so the only blue in the picture is the caption bar and
    # finding it is finding the window.
    my $at = sub {
        my ( $n ) = @_;

        return danced(
            width  => 240,
            height => 180,
            frames => $frames,
            frame  => $n,
            set    => { jitter => $most, width => 0.7, height => 0.7 },
        );
    };

    my ( $x0, $y0, $frame0 ) = $at->( 0 );

    ok defined $x0, 'the window is findable by the blue of its caption';

SKIP:
    {
        skip 'no window found', 4 unless defined $x0;

        my ( %seen, @moves );
        for my $n ( 0 .. $frames - 1 )
        {
            my ( $x, $y ) = $at->( $n );
            next unless defined $x;

            $seen{ "$x,$y" }++;
            push @moves, [ $x - $x0, $y - $y0 ];
        }

        cmp_ok scalar keys %seen, '>', $frames / 2,
            'and it is somewhere different on most frames of the loop';

        # Within what was asked for. The picture is 180 tall, so the zoom is
        # one and a jitter of three is three image pixels either way -- but
        # from the *placed* position, which frame 0 has already moved off.
        my $worst = 0;
        for my $move ( @moves )
        {
            for my $axis ( @$move )
            {
                $worst = abs $axis if abs $axis > $worst;
            }
        }

        cmp_ok $worst, '<=', 2 * $most,
            'never further from its place than the jitter allows';

        cmp_ok $worst, '>', 0, 'and it does move at all';

        # The point of the whole thing: what arrives at the new position is
        # the same window, not a differently-drawn one. Cut the caption bar
        # out of two frames at wherever each of them put it, and the pixels
        # have to match to the last one.
        my $bar = sub {
            my ( $img, $x, $y ) = @_;

            my $cut = $img->Clone;
            $cut->Crop( geometry => sprintf '60x18+%d+%d', $x, $y );
            $cut->Set( page => '0x0+0+0' );

            return $cut->Get( 'signature' );
        };

        my ( $x5, $y5, $frame5 ) = $at->( 5 );

        is $bar->( $frame5, $x5, $y5 ), $bar->( $frame0, $x0, $y0 ),
            'and the window that arrives is the one that left';
    }
}

# ---------------------------------------------------------------------------
# The dance is measured in the window's own pixels

# So that it looks the same on a phone photograph and on a thumbnail. A jitter
# counted in image pixels would be a twitch on one and a lurch on the other.
{
    my $spread = sub {
        my ( $zoom ) = @_;

        my ( @x, @y );
        for my $n ( 0 .. 7 )
        {
            my ( $x, $y ) = danced(
                width  => 400,
                height => 300,
                frames => 8,
                frame  => $n,
                set    => {
                    jitter => 3,
                    zoom   => $zoom,
                    width  => 0.5,
                    height => 0.5
                },
            );

            next unless defined $x;

            push @x, $x;
            push @y, $y;
        }

        my @sx = sort { $a <=> $b } @x;
        my @sy = sort { $a <=> $b } @y;

        return ( $sx[ -1 ] - $sx[ 0 ], $sy[ -1 ] - $sy[ 0 ] );
    };

    my ( $one_x, $one_y ) = $spread->( 1 );
    my ( $two_x, $two_y ) = $spread->( 2 );

    is $two_x, 2 * $one_x, 'twice the zoom, twice the dance across';
    is $two_y, 2 * $one_y, 'and twice the dance down';
}

# ---------------------------------------------------------------------------
# Three palettes, and only three colours in each

# A theme is the whole palette and not a tint applied afterwards, so the test
# is the same one the zoom gets: every pixel of the window has to be one of
# the inks that theme is drawn in. A themed window with a stray #C0C7C8 in it
# is one that painted something before the theme was consulted.
{
    my %PALETTE = (
        default =>
            [ '255,255,255', '192,199,200', '135,136,143', '0,0,0', '0,0,168' ],
        rose => [ '255,255,255', '207,175,183', '159,96,112', '0,0,0' ],
        rain => [ '255,255,255', '131,153,177', '79,101,125', '0,0,0' ],
    );

    my @names = GlitchVape::Chicago::themes();
    is_deeply \@names, [ qw(default rose rain) ],
        'the themes are the three that are offered, in that order';

    my %signature;
    $signature{ $_ } = only_its_own_colours( $_, $PALETTE{ $_ } ) for @names;

    isnt $signature{ rose }, $signature{ default },
        'rose is not the default with a different name on it';
    isnt $signature{ rain }, $signature{ rose }, 'and rain is not rose';
}

# ---------------------------------------------------------------------------
# A theme nobody has heard of is the default, not a failure

# Presets are files, and a file can outlive the version that wrote it. Asked
# for a palette this build does not have, the window comes out ordinary rather
# than not coming out.
{
    my $painted = sub {
        my ( $theme ) = @_;

        return GlitchVape::Chicago::render(
            width      => 200,
            height     => 140,
            theme      => $theme,
            caption    => undef,
            menu       => undef,
            font       => undef,
            scrollbars => 1,
            grip       => 1,
            scroll     => 0,
            thumb      => 0.5,
        )->Get( 'signature' );
    };

    my $ordinary = $painted->( 'default' );

    is $painted->( 'chartreuse' ), $ordinary, 'an unknown theme is the default';
    is $painted->( undef ),        $ordinary, 'and so is no theme at all';
    is $painted->( q{} ),          $ordinary, 'and so is an empty one';
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
