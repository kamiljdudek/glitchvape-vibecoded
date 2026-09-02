#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;

use GlitchVape                  ();
use GlitchVape::Chicago         ();
use GlitchVape::Context         ();
use GlitchVape::Effect::Overlay ();
use GlitchVape::Fonts           ();
use GlitchVape::Pipeline        ();
use GlitchVape::Registry        ();
use GlitchVape::Tools           ();

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

# The two the application's own icon brings with it, which are not interface
# colours and do not change with the theme.
my @ARTWORK = ( '154,118,216', '217,162,227' );
my %CHAR    = reverse %INK;

$CHAR{ $ARTWORK[ 0 ] } = 'P';    # the icon's sky
$CHAR{ $ARTWORK[ 1 ] } = 'Q';    # and its ground

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
# How many of the roles fontconfig could find a face for. Nought means the
# claim above went unexercised rather than that it held.
sub drawable_roles
{
    my $drawn = 0;

    $drawn += drawable( $_ ) for GlitchVape::Fonts::roles();

    return $drawn;
}

sub drawable
{
    my ( $role ) = @_;

    my $font = GlitchVape::Fonts::resolve( $role ) or return 0;
    my $size = GlitchVape::Chicago::smallest_type( $font );

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

    my %ink = map { $_ => 1 } @$palette, @ARTWORK;

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

# The sixteen pixels of the system menu icon, as a picture.
sub icon_block
{
    my ( %arg ) = @_;

    return join "\n", @{ art( window( %arg ), 6, 5, 16, 16 ) };
}

# Where the caption's first letter is, for an icon of a given width. The first
# white pixel right of where even the wider icon ends.
sub caption_starts_at
{
    my ( $icon ) = @_;

    my $win = GlitchVape::Chicago::render(
        width      => 480,
        height     => 321,
        icon       => $icon,
        caption    => 'Untitled',
        menu       => undef,
        font       => GlitchVape::Fonts::resolve( 'ui' ),
        scrollbars => 0,
        grip       => 0,
        scroll     => 0,
        thumb      => 0.5,
    );

    my @px = $win->GetPixels(
        map       => 'RGB',
        y         => 12,
        width     => 480,
        height    => 1,
        normalize => 1
    );

    for my $x ( 22 .. 400 )
    {
        return $x if $px[ $x * 3 ] > 0.9 && $px[ $x * 3 + 2 ] > 0.9;
    }

    return undef;
}

# That the second letter of the icon is the first one upside down, but for the
# one row that makes it an A.
sub turned_over
{
    my ( $block ) = @_;

    my $shape = sub {
        my ( $row, $ink ) = @_;

        $row =~ s/[$ink]/#/g;
        $row =~ s/[^#]/./g;

        return $row;
    };

    my @upside_down =
        map { $shape->( substr( $_, 0, 8 ), 'W' ) }
        reverse @{ $block }[ 3 .. 12 ];

    my @letter_a =
        map { $shape->( substr( $_, 8, 8 ), 'K' ) } @{ $block }[ 3 .. 12 ];

    my @differ = grep { $upside_down[ $_ ] ne $letter_a[ $_ ] } 0 .. 9;

    is scalar @differ, 1, 'the A is the V turned over, but for one row';

    return unless @differ == 1;

    is $letter_a[ $differ[ 0 ] ], '.######.', 'and that row is the crossbar';

    return;
}

# How far the window wandered across a loop, at a given zoom.
sub spread_at
{
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
}

# Every place the window landed over a loop, and the furthest it got from
# where the first frame put it.
sub wandering
{
    my ( $at, $frames, $x0, $y0 ) = @_;

    my ( %seen, $worst );
    $worst = 0;

    for my $n ( 0 .. $frames - 1 )
    {
        my ( $x, $y ) = $at->( $n );
        next unless defined $x;

        $seen{ "$x,$y" }++;

        for my $axis ( $x - $x0, $y - $y0 )
        {
            $worst = abs $axis if abs $axis > $worst;
        }
    }

    return ( scalar keys %seen, $worst );
}

# That around() and client_origin() describe the window render() actually
# builds: the hole is the client area asked for, exactly, where they said.
sub fits_around
{
    my ( $menu, $bars ) = @_;

    my ( $cw, $ch ) = ( 90, 70 );

    my ( $ww, $wh ) = GlitchVape::Chicago::around(
        client     => [ $cw, $ch ],
        menu       => $menu,
        scrollbars => $bars
    );

    my ( $hx, $hy ) = GlitchVape::Chicago::client_origin( menu => $menu );

    my $win = GlitchVape::Chicago::render(
        client     => [ $cw, $ch ],
        menu       => $menu,
        maximised  => 1,
        caption    => undef,
        font       => undef,
        scrollbars => $bars,
        grip       => 1,
        scroll     => 0,
        thumb      => 0.5,
    );

    my $said = sprintf 'menu %s, bars %d', defined $menu ? 'on' : 'off', $bars;

    is join( 'x', $win->Get( 'width' ), $win->Get( 'height' ) ), "${ww}x${wh}",
        "around() says how big the window is ($said)";

    my $rows  = art( $win, $hx, $hy, $cw, $ch );
    my @solid = grep { !m{\A _+ \z}x } @$rows;

    is scalar @solid, 0, "and the hole is the client area ($said)";

    is substr( art( $win, $hx - 1, $hy, 1, 1 )->[ 0 ], 0, 1 ), 'K',
        "with the well drawn right up to its edge ($said)";

    return;
}

# What zoom 0 works out to for a picture of a given height.
# One parameter's declared dependence on the scroll bars being there.
sub needs_scrollbars
{
    my ( $effect, $key ) = @_;

    return is_deeply $effect->{ params }{ $key }{ needs }, { scrollbars => 1 },
        "$key says it depends on there being scroll bars";
}

sub auto_zoom
{
    my ( $height ) = @_;

    ## no critic (Subroutines::ProtectPrivateSubs)
    return GlitchVape::Effect::Overlay::_chicago_zoom( $height );
    ## use critic
}

# That the parameter says what zoom 0 does, because a control whose top half
# is the same as its second notch is one somebody reports as broken.
sub zoom_docs_state_the_rule
{
    for my $effect ( @_ )
    {
        my $doc =
            GlitchVape::Registry->get( $effect )->{ params }{ zoom }{ doc };

        like $doc, qr/480/, "$effect.zoom says what it reads the picture as";
        like $doc, qr/720/, "and where $effect.zoom 0 stops agreeing with 1";
    }

    return;
}

sub window
{
    my ( %arg ) = @_;

    return GlitchVape::Chicago::render(
        width      => 480,
        height     => 321,
        icon       => 'notepad',
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

    my %allowed = map { $_ => 1 } keys %CHAR, @ARTWORK;

    my @unexpected =
        grep { !$allowed{ $_ } && $_ ne '0,0,0' } sort keys %$seen;

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

    is GlitchVape::Chicago::smallest_type( undef ), 12,
        'with no font there is nothing to measure and the interface size stands';

    ok drawable_roles(), 'there was at least one font to ask';
}

# ---------------------------------------------------------------------------
# The size is a plain size, with a floor the font decides

# It used to be nought-means-measure-it, which put a cliff in the middle of a
# slider: nought drew ordinary lettering, one drew lettering a pixel tall, and
# thirteen drew ordinary lettering again. Nothing about dragging it told you
# that, and the one value that behaved sanely was the one that did not look
# like a size.
#
# So the number is now the size, and asking for less than the font can manage
# is quietly not done. Two properties fall out and both are worth pinning:
# bigger never means smaller, and no value means anything other than a size.
{
    my $font = GlitchVape::Fonts::resolve( 'ui' );

SKIP:
    {
        skip 'no ui font', 5 unless $font;

        my $floor = GlitchVape::Chicago::smallest_type( $font );

        my $at = sub {
            my ( $size ) = @_;

            return GlitchVape::Chicago::render(
                width      => 480,
                height     => 321,
                caption    => 'Untitled',
                menu       => undef,
                font       => $font,
                type_size  => $size,
                scrollbars => 0,
                grip       => 0,
                scroll     => 0,
                thumb      => 0.5,
            )->Get( 'signature' );
        };

        my $ordinary = $at->( undef );

        is $at->( $floor ), $ordinary,
            'asked for the size it can manage, that is what it draws';

        # The cliff, from both sides of where it used to be.
        is $at->( 1 ), $ordinary, 'asked for one, it draws that same size';
        is $at->( 0 ), $ordinary, 'and nought is not a special number either';

        isnt $at->( 18 ), $ordinary, 'asked for more, it draws more';

        # And nothing between the floor and the top of the range is smaller
        # than the floor, which is the whole of "bigger never means smaller".
        my @shrunk = grep { $at->( $_ ) eq $at->( $_ - 1 ) && $_ > $floor + 1 }
            $floor + 1 .. 18;

        is_deeply \@shrunk, [], 'and every size above the floor is its own'
            or diag "these drew the same as one size smaller: @shrunk";
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

        my ( $places, $worst ) = wandering( $at, $frames, $x0, $y0 );

        cmp_ok $places, '>', $frames / 2,
            'and it is somewhere different on most frames of the loop';

        # Within what was asked for. The picture is 180 tall, so the zoom is
        # one and a jitter of three is three image pixels either way -- but
        # from the *placed* position, which frame 0 has already moved off.
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

    my ( $one_x, $one_y ) = spread_at( 1 );
    my ( $two_x, $two_y ) = spread_at( 2 );

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
# The application's own icon, in the sixteen pixels Windows gives one

# Squeezing a 256-pixel icon into sixteen is a redraw, not a resize, and this
# is the redraw. It is here rather than derived at run time for the reason
# every other bitmap in that file is: an outline scaled to sixteen pixels is
# mush, and the two letterforms are the whole of what has to survive.
#
# It comes out exact rather than approximate because the V and the A in
# assets/artwork/icon-256.png are both drawn on a seven-by-eleven pixel grid,
# eight cells wide and ten tall, so the pair is exactly sixteen cells across
# and one cell becomes one pixel with nothing rounded.
{
    my $win = window( icon => 'glitchvape' );

    is_deeply art( $win, 6, 5, 16, 16 ),
        [
        'PPPPPPPPPPPPPPPP', 'PPPPPPPPPPPPPPPP',
        'PPPPPPPPPPPPPPPP', 'WWPPPPWWPPPKKPPP',
        'WWPPPPWWPPPKKPPP', 'PWWPPWWPPPKKKKPP',
        'PWWPPWWPPPKKKKPP', 'PWWPPWWPPPKPPKPP',
        'PPWPPWPPPKKPPKKP', 'PPWWWWPPPKKPPKKP',
        'PPWWWWPPPKKKKKKP', 'PPPWWPPPKKPPPPKK',
        'PPPWWPPPKKPPPPKK', 'QQQQQQQQQQQQQQQQ',
        'WWWWWWWWKKKKKKKK', 'QQQQQQQQQQQQQQQQ',
        ],
        'a white V and a black A on the purple, over their own horizon';

    # The A is the V upside down with one row filled in, which is the whole
    # of what makes an A an A. Asked of the bitmap, because if it stops being
    # true the table has been edited by hand and one of them has drifted.
    turned_over( art( $win, 6, 5, 16, 16 ) );
}

# ---------------------------------------------------------------------------
# A logo does not change colour with the desktop scheme

# The window is themed and the icon is not, which is how it was: an
# application shipped its icon and the Appearance tab did not repaint it.
{
    my %block;
    $block{ $_ } = icon_block( theme => $_, icon => 'glitchvape' )
        for GlitchVape::Chicago::themes();

    is $block{ rose }, $block{ default }, 'the icon is the same under rose';
    is $block{ rain }, $block{ default }, 'and the same under rain';
}

# ---------------------------------------------------------------------------
# Which icon it is moves the caption text, and nothing else

# The page is thirteen pixels and the logo is sixteen, so the width is a
# question rather than a constant -- it used to be written down as 13 in two
# places, which the wider icon would have run straight over.
{

    my $wide   = caption_starts_at( 'glitchvape' );
    my $narrow = caption_starts_at( 'notepad' );

SKIP:
    {
        skip 'no font to set a caption in', 1
            unless defined $wide && defined $narrow;

        is $wide - $narrow, 3,
            'the caption starts three pixels further right behind the wider icon';
    }
}

# ---------------------------------------------------------------------------
# An icon nobody has heard of, and one that is not an icon at all

# Every glyph in the module lives in one table, so an unguarded name would let
# 'grip' put three diagonal ribs in the caption.
{
    my $ordinary = icon_block( icon => 'glitchvape' );

    is icon_block( icon => $_ ), $ordinary,
        "'$_' is not an icon, so the usual one is drawn"
        for 'chartreuse', 'grip', 'close', q{};
}

# ---------------------------------------------------------------------------
# A window built around something, rather than to a size with a hole in it

# What the maximised effect needs and the floating one does not: given what
# has to go inside, how big is the window and where does the inside start.
# It is the layout in render() read backwards, so the two can disagree -- and
# the way to catch that is to build a window from around() and then measure
# the hole render() actually left.
{
    fits_around( $_->[ 0 ], $_->[ 1 ] )
        for [ undef, 0 ], [ undef, 1 ], [ 'File', 0 ], [ 'File', 1 ];
}

# ---------------------------------------------------------------------------
# A maximised window says it is one

# Two things follow from being maximised rather than floating, and a window
# that showed neither would be a floating window drawn very large. Maximise
# becomes Restore -- the one thing on a caption that says which of the two it
# is -- and the sizing grip goes, because a maximised window cannot be
# resized and a handle for doing it would be a lie.
{
    my $box = sub {
        my ( %arg ) = @_;

        return GlitchVape::Chicago::render(
            width      => 480,
            height     => 321,
            menu       => ' ',
            caption    => undef,
            font       => undef,
            scrollbars => 1,
            grip       => 1,
            scroll     => 0,
            thumb      => 0.5,
            %arg,
        );
    };

    my $floating = $box->();
    my $flat     = $box->( maximised => 1 );

    # The middle caption button, at the offset the measured table gives it.
    # The glyph's own blanks read as the button face they are drawn on.
    is_deeply art( $flat, 443, 8, 9, 9 ),
        [
        'FFKKKKKKK', 'FFKKKKKKK', 'FFKFFFFFK', 'KKKKKKKFK',
        'KKKKKKKFK', 'KFFFFFKFK', 'KFFFFFKKK', 'KFFFFFKFF',
        'KKKKKKKFF',
        ],
        'Maximise has become Restore: two windows, the front one down and left';

    isnt join( q{}, @{ art( $flat, 443, 8, 9, 9 ) } ),
        join( q{}, @{ art( $floating, 443, 8, 9, 9 ) } ),
        'which is not what a floating window has there';

    # And the corner between the two scroll bars is bare.
    my $corner = join q{}, @{ art( $flat, 466, 307, 8, 8 ) };

    unlike $corner, qr/W/, 'and there is no sizing grip to take hold of';
}

# ---------------------------------------------------------------------------
# The effect puts the picture inside, without touching it

SKIP:
{
    require GlitchVape::Registry;

    my $effect = GlitchVape::Registry->get( 'maximised' );
    skip 'the maximised effect is not registered', 6 unless $effect;

    is $effect->{ stage }, 'framing',
        'a window built around the picture runs where letterbox does';

    # The settings that mean something for a window laid over the picture and
    # nothing for one built around it. A maximised window has no size, no
    # place, nothing to shake against and nothing behind it to show through.
    my @gone = grep { $effect->{ params }{ $_ } }
        qw(width height gravity x y jitter opacity grip);

    is_deeply \@gone, [],
        'and carries none of the settings that would not mean anything'
        or diag "still declared: @gone";

    # A zoom of three and a picture that is not a multiple of three, so the
    # client area has to be rounded and the direction of the rounding shows.
    # Rounded down the picture would not fit its own frame and would be
    # cropped by it, which is the one thing a frame must not do.
    my ( $pw, $ph, $zoom ) = ( 160, 121, 3 );

    my $src = Image::Magick->new( size => "${pw}x${ph}" );
    $src->Read( 'gradient:#204060-#E0A0C0' );
    my $before = $src->Get( 'signature' );

    my $ctx = GlitchVape::Context->new( image => $src->Clone, seed => 5 );
    GlitchVape::Pipeline->new( effects =>
            { maximised => { zoom => $zoom, menu => q{}, title => q{} } } )
        ->run( $ctx );

    my $cw = int( ( $pw + $zoom - 1 ) / $zoom );
    my $ch = int( ( $ph + $zoom - 1 ) / $zoom );

    my ( $ww, $wh ) = GlitchVape::Chicago::around(
        client     => [ $cw, $ch ],
        menu       => undef,
        scrollbars => 1
    );

    is join( 'x', $ctx->image->Get( 'width' ), $ctx->image->Get( 'height' ) ),
        join( 'x', $ww * $zoom, $wh * $zoom ),
        'the picture comes out bigger by exactly the chrome';

    # The picture itself is placed, not resampled: cut it back out of the
    # window and it is the picture that went in, to the last pixel.
    my ( $hx, $hy ) = GlitchVape::Chicago::client_origin( menu => undef );

    my $back = $ctx->image->Clone;
    $back->Crop(
        geometry => sprintf '%dx%d+%d+%d',
        $pw, $ph,
        $hx * $zoom + int( ( $cw * $zoom - $pw ) / 2 ),
        $hy * $zoom + int( ( $ch * $zoom - $ph ) / 2 )
    );
    $back->Set( page => '0x0+0+0' );

    is $back->Get( 'signature' ), $before,
        'and the picture inside is the picture that went in, untouched';
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

    needs_scrollbars( $effect, $_ ) for qw(grip thumb scroll);
}

# ---------------------------------------------------------------------------
# What the automatic zoom works out, and where it agrees with 1

# It reads the picture as a screen 480 pixels tall, so under 720 it says 1 and
# 0 and 1 draw the same window -- which looks like a setting that does nothing
# until you know the rule. The rule is in the parameter's own doc for that
# reason, and pinned here so the doc cannot drift from it.
{
    is auto_zoom( 360 ),  1, 'a small picture is drawn at one to one';
    is auto_zoom( 719 ),  1, 'and so is anything short of 720';
    is auto_zoom( 720 ),  2, 'which is where it first doubles';
    is auto_zoom( 1080 ), 2, 'a 1080-line photograph gets 2';
    is auto_zoom( 2160 ), 5, 'and a 2160-line one gets 5';

    cmp_ok auto_zoom( 1 ), '>=', 1, 'never nought, however small the picture';

    # The doc says all of that, because a control whose top half is the same
    # as its second notch is one somebody will report as broken otherwise.
    zoom_docs_state_the_rule( qw(chicago maximised) );
}

done_testing;
