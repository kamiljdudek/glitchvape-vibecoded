package GlitchVape::Chicago;

use strict;
use warnings;

use GlitchVape::Magick ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Chicago - a 1995 window, drawn rather than stretched

=head1 DESCRIPTION

Everything needed to draw a Windows 95 window at any size: the metrics, the
two bevel rules, and the ten glyphs that are pictures rather than rules.
L<GlitchVape::Effect::Overlay>'s C<chicago> effect composites what comes out
over the photograph, with the middle left transparent.

=head1 WHY IT IS DRAWN AND NOT SCALED

The obvious way to put a window over a picture is to keep a screenshot and
stretch it. It does not survive the first resize. A window's furniture is a
fixed number of pixels -- a four-pixel sizing border, an eighteen-pixel title
bar, sixteen-pixel scroll bars -- and none of it scales with the window: a
window twice as wide has the same border and one more of nothing else. Stretch
the screenshot and the border becomes a soft grey smear, the caption buttons
become lozenges, and the one-pixel bevels that make the whole thing read as
raised turn into gradients.

So this knows how the window is made. Given a size it lays the parts out where
they belong and draws each at its own size, and the picture that comes out is
the picture Windows would have drawn.

=head1 THE TWO BEVELS

Almost every edge in the interface is one of two three-dimensional edges, each
two pixels deep, each four colours. Written as the ink along the top and left
followed by the ink along the bottom and right, outer ring then inner:

              outer   inner
    raised     FK      WS       face over dark, then white over shadow
    sunken     SW      KF       the same edge turned over
    soft       WK      FS       raised, but lit white on its outermost ring

Raised is the sizing border, the scroll-bar buttons and the thumb. Sunken is
the well the document sits in. Soft is the caption buttons and nothing else,
and it is a real difference rather than a rounding: two pixels apart on the
same window, a caption button has a white top edge and the scroll-bar button
below it has a face one, with its white a ring further in.

Getting one of the four inks wrong turns a raised edge into a sunken one,
which is why they are written here once and nowhere else.

=head1 THE THREE PALETTES

Five inks draw the whole interface, and the letters above are their I<roles>
rather than their colours: face, highlight, shadow, dark shadow, caption. A
theme is a complete set of the five, so nothing has to know which theme is in
force -- every drawing primitive here is handed the buffer, and the palette
rides on the buffer.

C<default> is what the screenshot came in and what Windows arrived in: a
neutral grey window under a navy caption, which is the odd one out, because
its caption is a colour that appears nowhere else in the chrome.

C<rose> and C<rain> are two of the schemes from the Appearance tab, and each
is really two colours: a dark that is both the caption bar and every shadowed
edge, and a light that is every face. The highlight stays white and the dark
shadow stays black in all three. That is not laziness -- a raised edge reads
as raised because its lit side is brighter than anything else on the screen,
and tinting the highlight flattens the window into a coloured rectangle.

A name this build does not know is the default rather than an error, because a
preset is a file and a file can outlive the version that wrote it.

=head1 WHY THE GLYPHS ARE IN THE FILE

The same argument L<GlitchVape::VGA> makes about its font, for the same
reason. What is left once the rules have drawn everything they can is ten
small pictures, none bigger than sixteen pixels square, most of them two
colours. Held as PNGs they would be ten files to install, ten files to
package, and ten files that could go missing at run time; held here they are
legible in a diff, and the effect cannot half-render.

They are scaled by pixel replication and never by interpolation, so a window
drawn at four times size is four-pixel squares with hard edges -- a screenshot
enlarged, which is what it is meant to look like.

=head2 Where they came from

Read off a 480x321 screenshot of Windows 95 Notepad, at the coordinates each
one names. The whole interface came from there: every measurement in this file
was taken off that image, and nothing reads it at run time -- a set of numbers
and nine bitmaps is a smaller thing to ship than a screenshot nobody may
redistribute. F<t/40-chicago.t> holds what it looked like, region by region,
which is what makes this a description of that window rather than of a window.

The arrows, the caption glyphs and the sizing grip are geometry -- triangles,
a bar, a box, a cross, three diagonal ribs. The document icon is the one piece
that is somebody else's artwork rather than a shape, and it is no longer what
a window arrives with: the caption holds this program's own icon unless asked
for the other one.

That icon is the tenth bitmap and the only one that did not come off the
screenshot. It is F<assets/artwork/icon-256.png> squeezed into the sixteen
pixels Windows gives a system menu -- a redraw rather than a resize, because
an outline scaled to sixteen pixels is mush and the two letterforms are the
whole of what has to survive. It comes out exact, which is luck worth writing
down: the V and the A there are both drawn on a seven-by-eleven pixel grid,
eight cells wide and ten tall, so the pair is exactly sixteen cells across and
one cell becomes one pixel with nothing rounded. Its purple and its pink are
in C<%ARTWORK> rather than in a theme, because an application's icon did not
change colour with the desktop scheme.

=head1 WHAT SIZE THE LETTERING IS

The interface sets everything in one font at one size, and that size is twelve
pixels. That is a floor rather than the answer, because whether a font can be
drawn at twelve pixels is a fact about the font.

With antialiasing off -- which this wants, for the reason above -- a rasteriser
inks a pixel when the pixel's I<centre> falls inside the outline. A vertical
stem narrower than one pixel therefore lands between two centres for some of
the positions it can be at, and disappears. Not always: it depends where the
glyph's own advance happens to put it, so the same letter survives in one word
and vanishes in the next. In W95FA at twelve pixels 'File' loses the dot off
its i, and 'Help' comes out intact, which reads as a corrupt font rather than
as a size that is one pixel too small.

The rule that fixes it is exact. A stem of width I<w> pixels covers a pixel
centre at every offset if and only if I<w> is at least one, so the smallest
size a font can be drawn at is the one where its stem reaches a whole pixel:

    smallest size = ceil( 1 / stem, measured as a fraction of the em )

C<smallest_type> measures the stem by drawing an C<l> at a five-hundred-pixel
em and reading its width, which is a measurement rather than a table, so a
font nobody here has seen gets the same answer. The two that ship give:

    pixel role   stem 0.084 em   ->  12   its design size, unchanged
    ui   (W95FA) stem 0.080 em   ->  13   one pixel up, and legible

That is a I<floor> and not the size. The size is C<type_size>'s own argument,
twelve by default because twelve is what the interface used, and the floor
only ever raises it. Which is the whole reason it is a floor rather than a
value the caller has to ask for: it used to be that nought meant "measure it"
and anything else was taken literally, so a slider went from ordinary
lettering at nought to one-pixel lettering at one and back to ordinary at
thirteen. Nothing about dragging it said so.

Nothing is scaled to compensate. Thirteen-pixel lettering in an eighteen-pixel
caption bar is what Windows would have done with a font that size, and the
lettering is centred in its bar rather than set at an offset from the top, so
a font one pixel taller than the last one still sits where it should.
Eighteen points is as large as that bar will hold.

=cut

# The five colours the whole interface is drawn in, which is genuinely all of
# them: a screenshot of it quantises to these and nothing else. Named for what
# they do rather than what they look like, because 'face' stays the right name
# if the palette is ever themed and '#C0C7C8' does not.
my %THEME = (

    # What the screenshot every measurement came off was set to, and what
    # Windows arrived in: a neutral grey window under a navy caption. The odd
    # one out below, because its caption is a colour that appears nowhere else
    # in the chrome -- the two after it tint the whole window from one dark.
    default => {
        F => [ 192, 199, 200 ],    # face: every flat surface
        W => [ 255, 255, 255 ],    # highlight: the lit edge of a raised thing
        S => [ 135, 136, 143 ],    # shadow: the shaded edge
        K => [ 0,   0,   0 ],      # dark shadow, and text
        B => [ 0,   0,   168 ],    # the active caption
    },

    # Two of the schemes that shipped in the Appearance tab, each two colours:
    # a dark that is both the caption bar and every shadowed edge, and a light
    # that is every face. The highlight stays white and the dark shadow stays
    # black, as they did there -- a raised edge reads as raised because its lit
    # side is brighter than anything else on the screen, and tinting that
    # flattens the whole window.
    rose => {
        F => [ 207, 175, 183 ],
        W => [ 255, 255, 255 ],
        S => [ 159, 96,  112 ],
        K => [ 0,   0,   0 ],
        B => [ 159, 96,  112 ],
    },
    rain => {
        F => [ 131, 153, 177 ],
        W => [ 255, 255, 255 ],
        S => [ 79,  101, 125 ],
        K => [ 0,   0,   0 ],
        B => [ 79,  101, 125 ],
    },
);

# Colours that belong to a picture rather than to the interface, merged into
# whichever theme is in force. An application's icon did not change colour
# with the desktop scheme then and does not here: a logo is a logo.
my %ARTWORK = (
    P => [ 154, 118, 216 ],    # the icon's sky, above the horizon
    Q => [ 217, 162, 227 ],    # and below it
);

=head2 themes()

The theme names, in the order they should be offered.

=cut

sub themes { return qw(default rose rain) }

# Every measurement, in the pixels the interface is drawn in. None of these is
# a proportion of anything: that is the whole point of the file.
use constant {
    FRAME   => 4,     # the sizing border
    CAPTION => 18,    # the title bar
    MENU    => 20,    # the menu bar
    SUNKEN  => 2,     # the well the document sits in
    BAR     => 16,    # a scroll bar's breadth, and its buttons
};

use constant {
    BUTTON_W   => 16,   # a caption button
    BUTTON_H   => 14,
    BUTTON_IN  => 2,    # its inset from the top and right of the caption
    BUTTON_GAP => 2,    # the space Windows leaves before Close and nowhere else
    ICON_X     => 2,    # the document icon, from the caption's own corner
    ICON_Y     => 1,
};

# The smallest thumb that still reads as a thumb rather than as a chip of
# bevel: below this the two-pixel edges meet in the middle and it is a blob.
use constant THUMB_MIN => 8;

# The size the interface itself wants. Windows had one UI font at one size and
# every caption in the system was that size, so this is a fact about the
# interface rather than a setting. Twelve because that is the design size of
# the 'pixel' font role, at which one glyph pixel lands on one image pixel.
#
# It is a floor rather than the answer: see L</WHAT SIZE THE LETTERING IS>.
use constant TEXT_SIZE => 12;

# And the largest a font may be talked up to. Past this the caption bar it has
# to fit stops being wishful and starts being wrong.
use constant TEXT_MAX => 20;

# The em a stem is measured at. A stem is a small fraction of an em -- around
# a twelfth -- so reading one off in whole pixels needs an em big enough that
# a pixel of error is a fraction of a per cent.
use constant PROBE_SIZE => 500;

# Where the two strings start across the bar they sit in, measured off the
# screenshot: the caption three pixels after the icon, the menu seven pixels
# in from the frame. There is no matching pair for down the bar, because there
# is nothing to measure -- both strings are centred in their own bar, and the
# screenshot agrees to the pixel.
use constant {
    CAPTION_GAP => 3,
    MENU_X      => 7,
};

# Nine bitmaps, one character per pixel, keyed by the ink table above with '.'
# for the pixels the glyph does not claim. Each says where it was read from.
my %GLYPH = (

    # The document icon, at (6,5). Sixteen tall like every small icon of the
    # period, thirteen wide because the page it draws is not square.
    notepad => [
        '..K.K.K.K.K..', '.KWSWSWSWSWK.', 'SWKWKWKWKWKWK', 'SWWWWWWWWWWFK',
        'SWWWWWWWWWWFK', 'SWWKKKWKKWWFK', 'SWWWWWWWWWWFK', 'SWWKKKKKKWWFK',
        'SWWWWWWWWWWFK', 'SWWKKKKKKWWFK', 'SWWWWWWWWWWFK', 'SWWKKKKKKWWFK',
        'SWWWWWWWWWWFK', 'SWWWWWWWWWWFK', 'SFFFFFFFFFFFK', '.KKKKKKKKKKK.',
    ],

    # This program's own icon, squeezed into the sixteen pixels Windows gives
    # a system menu. It is a scaling rather than a redrawing, and it comes out
    # exact, which is luck worth writing down: the V and the A in
    # F<assets/artwork/icon-256.png> are both drawn on a seven-by-eleven pixel
    # grid, eight cells wide and ten tall each -- so the pair is exactly
    # sixteen cells across, one cell to one pixel, with nothing rounded.
    #
    # The two letters are the same shape. Turn the V upside down and it is the
    # A, but for one row: where the V has three rows of open stem the A has
    # two and then a crossbar, which is the whole of what makes an A an A.
    #
    # The white band under the V and the black one under the A are the
    # horizon, and they are that way round in the original too.
    glitchvape => [
        'PPPPPPPPPPPPPPPP', 'PPPPPPPPPPPPPPPP',
        'PPPPPPPPPPPPPPPP', 'WWPPPPWWPPPKKPPP',
        'WWPPPPWWPPPKKPPP', 'PWWPPWWPPPKKKKPP',
        'PWWPPWWPPPKKKKPP', 'PWWPPWWPPPKPPKPP',
        'PPWPPWPPPKKPPKKP', 'PPWWWWPPPKKPPKKP',
        'PPWWWWPPPKKKKKKP', 'PPPWWPPPKKPPPPKK',
        'PPPWWPPPKKPPPPKK', 'QQQQQQQQQQQQQQQQ',
        'WWWWWWWWKKKKKKKK', 'QQQQQQQQQQQQQQQQ',
    ],

    # The three caption glyphs, at (428,15), (443,8) and (462,9). Minimise is
    # a bar along the bottom rather than through the middle, which is the
    # detail everybody redrawing this from memory gets wrong.
    minimise => [ 'KKKKKK', 'KKKKKK', ],
    maximise => [
        'KKKKKKKKK', 'KKKKKKKKK', 'K.......K', 'K.......K',
        'K.......K', 'K.......K', 'K.......K', 'K.......K',
        'KKKKKKKKK',
    ],

    # What Maximise turns into once the window is. Two windows overlapping,
    # the front one down and left -- the same nine pixels square as the box
    # it replaces, so it sits at the same offset.
    restore => [
        '..KKKKKKK', '..KKKKKKK', '..K.....K', 'KKKKKKK.K',
        'KKKKKKK.K', 'K.....K.K', 'K.....KKK', 'K.....K..',
        'KKKKKKK..',
    ],
    close => [
        'KK....KK', '.KK..KK.', '..KKKK..', '...KK...',
        '..KKKK..', '.KK..KK.', 'KK....KK',
    ],

    # The scroll-bar arrows, at (462,50), (462,289), (11,303) and (448,303).
    # Seven by four lying down and four by seven standing up -- not one shape
    # rotated, because a triangle seven wide is four tall and a triangle seven
    # tall is four wide, and Windows drew both rather than turning one.
    up    => [ '...K...', '..KKK..', '.KKKKK.', 'KKKKKKK', ],
    down  => [ 'KKKKKKK', '.KKKKK.', '..KKK..', '...K...', ],
    left  => [ '...K',    '..KK',    '.KKK', 'KKKK', '.KKK', '..KK', '...K', ],
    right => [ 'K...',    'KK..',    'KKK.', 'KKKK', 'KKK.', 'KK..', 'K...', ],

    # The sizing grip, at (458,299): three ribs across the corner square
    # between the two scroll bars, each a white pixel and two shadow ones, on
    # a four-pixel diagonal.
    grip => [
        '................', '................',
        '................', '................',
        '...............W', '..............WS',
        '.............WSS', '............WSS.',
        '...........WSS.W', '..........WSS.WS',
        '.........WSS.WSS', '........WSS.WSS.',
        '.......WSS.WSS.W', '......WSS.WSS.WS',
        '.....WSS.WSS.WSS', '....WSS.WSS.WSS.',
    ],
);

# Where every glyph sits inside the button it is drawn on, measured off the
# screenshot rather than worked out.
#
# Centring them arithmetically is wrong, and wrong in a way that reads as a
# rendering fault rather than as a decision. Minimise is not a centred bar, it
# is an *underscore*: it sits on the button's baseline at the left, because
# the picture it is of is a window collapsed to the bottom of the screen.
# Centred it floats three pixels too high and one too far right, and the three
# buttons stop looking like a set.
#
# Maximise and Close do come out centred, and the arrows do not -- left and
# right sit at different insets, which shows where the two bars meet at the
# corner. All of them are written down anyway: a number that agrees with a
# formula by coincidence is not a reason to keep the formula.
my %GLYPH_AT = (
    minimise => [ 4, 9 ],
    maximise => [ 3, 2 ],
    restore  => [ 3, 2 ],
    close    => [ 4, 3 ],
    up       => [ 4, 6 ],
    down     => [ 4, 6 ],
    left     => [ 5, 4 ],
    right    => [ 6, 4 ],
);

=head2 icons()

The icon names the caption can be given, in the order they should be offered.

=cut

sub icons { return qw(glitchvape notepad) }

my %IS_ICON = map { $_ => 1 } icons();

# Guarded rather than trusted, and not only against a name from a later
# version: every glyph in this file lives in one table, so an icon named
# 'grip' would otherwise draw three diagonal ribs in the caption.
sub _icon_for
{
    my ( $name ) = @_;

    return $IS_ICON{ $name // q{} } ? $name : ( icons() )[ 0 ];
}

# How wide the chosen one is. The notepad page is thirteen pixels and the logo
# is sixteen, so everything to the right of the icon -- the caption text, and
# the width below which the caption's own contents stop fitting -- has to ask
# rather than assume.
sub _icon_width
{
    my ( $name ) = @_;

    return length $GLYPH{ _icon_for( $name ) }[ 0 ];
}

=head2 metrics()

The measurements above, as a hash, for callers that would rather ask than
restate them.

=cut

sub metrics
{
    return {
        frame   => FRAME,
        caption => CAPTION,
        menu    => MENU,
        sunken  => SUNKEN,
        bar     => BAR,
    };
}

=head2 ink( $theme, $role )

One of a theme's five inks as C<#RRGGBB>, for a caller that has to paint
something beside the window in a colour that belongs with it.

=cut

sub ink
{
    my ( $theme, $role ) = @_;

    my $palette = $THEME{ $theme    // q{} } || $THEME{ default };
    my $rgb     = $palette->{ $role // q{} } || $palette->{ F };

    return sprintf '#%02X%02X%02X', @$rgb;
}

=head2 around( %arg )

    client     => [ $width, $height ]
    menu       => the menu string, or undef
    scrollbars => whether there are any

The window size that puts a client area of that size inside it, as
C<< ( $width, $height ) >>. The inverse of the layout in L</render( %arg )>,
and what a window built I<around> a picture needs rather than a window built
to a size with a hole in it.

=cut

sub around
{
    my ( %arg ) = @_;

    my ( $cw, $ch ) = @{ $arg{ client } };

    my $bars = $arg{ scrollbars }                          ? BAR  : 0;
    my $menu = defined $arg{ menu } && length $arg{ menu } ? MENU : 0;

    return (
        $cw + 2 * SUNKEN + $bars + 2 * FRAME,
        $ch + 2 * SUNKEN + $bars + 2 * FRAME + CAPTION + $menu,
    );
}

=head2 client_origin( %arg )

Where that client area's top left corner lands inside the window, as
C<< ( $x, $y ) >>. Takes the same C<menu>.

=cut

sub client_origin
{
    my ( %arg ) = @_;

    my $menu = defined $arg{ menu } && length $arg{ menu } ? MENU : 0;

    return ( FRAME + SUNKEN, FRAME + CAPTION + $menu + SUNKEN );
}

=head2 minimum( %arg )

The smallest window that can hold the parts C<%arg> asks for, as
C<< ( $width, $height ) >>. Takes the same C<menu> and C<scrollbars> as
L</render( %arg )>.

Below this the parts would overlap rather than merely be cramped, so
L</render( %arg )> clamps to it instead of drawing something incoherent.

=cut

sub minimum
{
    my ( %arg ) = @_;

    # Wide enough for the caption's own contents, which is what actually binds:
    # the icon, the three buttons and their gap do not shrink.
    my $caption =
        ICON_X +
        _icon_width( $arg{ icon } ) +
        BUTTON_IN +
        3 * BUTTON_W +
        BUTTON_GAP +
        BUTTON_IN;

    my $bars = $arg{ scrollbars } ? BAR : 0;

    my $width = 2 * FRAME + $caption;
    my $inner = 2 * SUNKEN + $bars + 4;
    $width = 2 * FRAME + $inner if 2 * FRAME + $inner > $width;

    my $height =
        2 * FRAME +
        CAPTION +
        ( defined $arg{ menu } && length $arg{ menu } ? MENU : 0 ) +
        2 * SUNKEN +
        $bars + 4;

    return ( $width, $height );
}

=head2 render( %arg )

    width       => the window's width, in the pixels it is drawn in
    height      => its height
    theme       => which palette, from L</themes()>
    icon        => which system-menu icon, from L</icons()>
    client      => [ $w, $h ] in place of width and height: size it to fit
    maximised   => Restore in place of Maximise, and no sizing grip
    caption     => the title string, or undef for a bare caption bar
    menu        => the menu string, or undef for no menu bar at all
    font        => a font file for both, from GlitchVape::Fonts
    type_size   => the size to set them at; see L</type_size( $font, $wanted )>
    scrollbars  => draw a scroll bar down the right and along the bottom
    grip        => draw the sizing grip in the corner between them
    scroll      => 0..1, where along its bar each thumb sits
    thumb       => 0..1, how much of its bar each thumb covers

An L<Image::Magick> object of exactly that size, with the document area
transparent so the picture underneath shows through it.

Drawn at one chrome pixel to one image pixel. Enlarging is the caller's to do,
and to do by replication -- see L</WHY THE GLYPHS ARE IN THE FILE>.

=cut

sub render
{
    my ( %arg ) = @_;

    my $menu =
        defined $arg{ menu } && length $arg{ menu } ? $arg{ menu } : undef;

    my ( $min_w, $min_h ) = minimum( %arg, menu => $menu );

    my $w = $arg{ width };
    my $h = $arg{ height };

    # A window asked for by what has to go inside it rather than by how big it
    # is, which is what a maximised one is: the picture is the given and the
    # chrome is however much the chrome is.
    ( $w, $h ) = around( %arg, menu => $menu ) if $arg{ client };

    $w = $min_w if !$w || $w < $min_w;
    $h = $min_h if !$h || $h < $min_h;

    my $buf = _canvas( $w, $h, $arg{ theme } );

    # Outside in, because that is the order the parts are nested and because
    # each one is then drawn over the face the one before it left behind. The
    # face goes down first and whole: the sizing border is four pixels of
    # which only the outer two are bevelled, and the two behind them are
    # nothing but face -- there is no ring to draw for them.
    _fill( $buf, 0, 0, $w, $h, 'F' );
    _raised( $buf, 0, 0, $w, $h );

    my $x  = FRAME;
    my $y  = FRAME;
    my $iw = $w - 2 * FRAME;

    _caption( $buf, $x, $y, $iw, $arg{ icon }, $arg{ maximised } );
    $y += CAPTION;

    if ( defined $menu )
    {
        $y += MENU;
    }

    my $ih = $h - FRAME - $y;

    _well( $buf, $x, $y, $iw, $ih, \%arg );

    my $img = _image( $buf );

    _text(
        $img,
        {
            font    => $arg{ font },
            size    => type_size( $arg{ font }, $arg{ type_size } ),
            caption => $arg{ caption },
            menu    => $menu,
        },
        $w,
        _icon_width( $arg{ icon } )
    );

    return $img;
}

# ---------------------------------------------------------------------------
# The caption

sub _caption
{
    my ( $buf, $x, $y, $w, $icon, $maximised ) = @_;

    _fill( $buf, $x, $y, $w, CAPTION, 'B' );
    _glyph( $buf, $x + ICON_X, $y + ICON_Y, _icon_for( $icon ) );

    # From the right, because that is where they are anchored: Windows leaves
    # a gap before Close and none between the other two, so that the button
    # that loses the work is the one that is hard to hit by accident.
    my $at = $x + $w - BUTTON_IN - BUTTON_W;

    # Maximise is Restore once the window is maximised, which is the one
    # thing on the caption that says which of the two it is.
    my $middle = $maximised ? 'restore' : 'maximise';

    for my $button ( [ close => BUTTON_GAP ], [ $middle => 0 ],
        [ minimise => 0 ] )
    {
        my ( $glyph, $gap ) = @$button;

        _button( $buf, $at, $y + BUTTON_IN, $glyph );
        $at -= BUTTON_W + $gap;
    }

    return;
}

sub _button
{
    my ( $buf, $x, $y, $glyph ) = @_;

    _fill( $buf, $x, $y, BUTTON_W, BUTTON_H, 'F' );
    _soft_raised( $buf, $x, $y, BUTTON_W, BUTTON_H );

    _at( $buf, $x, $y, $glyph );

    return;
}

# ---------------------------------------------------------------------------
# The well, and whatever is inside it

sub _well
{
    my ( $buf, $x, $y, $w, $h, $arg ) = @_;

    _sunken( $buf, $x, $y, $w, $h );

    my $ix = $x + SUNKEN;
    my $iy = $y + SUNKEN;
    my $iw = $w - 2 * SUNKEN;
    my $ih = $h - 2 * SUNKEN;

    unless ( $arg->{ scrollbars } )
    {
        _hollow( $buf, $ix, $iy, $iw, $ih );
        return;
    }

    # Both bars, so both lose the corner square to the other.
    my $dw = $iw - BAR;
    my $dh = $ih - BAR;

    _hollow( $buf, $ix, $iy, $dw, $dh );

    _scrollbar( $buf, $arg, vertical => [ $ix + $dw, $iy, BAR, $dh ] );
    _scrollbar( $buf, $arg, horizontal => [ $ix, $iy + $dh, $dw, BAR ] );

    _fill( $buf, $ix + $dw, $iy + $dh, BAR, BAR, 'F' );

    # A maximised window cannot be resized, so it does not offer a handle for
    # doing it -- whatever the setting says.
    _glyph( $buf, $ix + $dw, $iy + $dh, 'grip' )
        if $arg->{ grip } && !$arg->{ maximised };

    return;
}

sub _scrollbar
{
    my ( $buf, $arg, $way, $box ) = @_;

    my ( $x, $y, $w, $h ) = @$box;

    my $vertical = $way eq 'vertical';
    my $length   = $vertical ? $h : $w;

    # A bar shorter than its own two buttons is a raised strip and nothing
    # else, which is what Windows leaves when a window is dragged down to
    # nothing. Everything below is then guaranteed room to be drawn in.
    if ( $length < 2 * BAR )
    {
        _fill( $buf, $x, $y, $w, $h, 'F' );
        _raised( $buf, $x, $y, $w, $h );
        return;
    }

    # The button at the near end of the bar and the one at the far end, which
    # for a vertical bar are the top and the bottom and for a horizontal one
    # the left and the right.
    my @arrows = $vertical ? qw(up down) : qw(left right);

    _arrow( $buf, $x, $y, $arrows[ 0 ] );
    _arrow(
        $buf,
        $vertical ? $x            : $x + $w - BAR,
        $vertical ? $y + $h - BAR : $y,
        $arrows[ 1 ]
    );

    my $tx = $vertical ? $x           : $x + BAR;
    my $ty = $vertical ? $y + BAR     : $y;
    my $tw = $vertical ? $w           : $w - 2 * BAR;
    my $th = $vertical ? $h - 2 * BAR : $h;

    my $track = $vertical ? $th : $tw;
    return if $track < 1;

    _dither( $buf, $tx, $ty, $tw, $th );

    # A track with no room for a thumb keeps its arrows and goes without one,
    # rather than growing a thumb that covers an arrow.
    return if $track < THUMB_MIN;

    my $size = int( $track * _clamp( $arg->{ thumb }, 0.05, 1 ) + 0.5 );
    $size = THUMB_MIN if $size < THUMB_MIN;
    $size = $track    if $size > $track;

    my $at = int( ( $track - $size ) * _clamp( $arg->{ scroll }, 0, 1 ) + 0.5 );

    my ( $bx, $by, $bw, $bh ) =
        $vertical
        ? ( $tx, $ty + $at, $tw, $size )
        : ( $tx + $at, $ty, $size, $th );

    _fill( $buf, $bx, $by, $bw, $bh, 'F' );
    _raised( $buf, $bx, $by, $bw, $bh );

    return;
}

sub _arrow
{
    my ( $buf, $x, $y, $which ) = @_;

    _fill( $buf, $x, $y, BAR, BAR, 'F' );
    _raised( $buf, $x, $y, BAR, BAR );

    _at( $buf, $x, $y, $which );

    return;
}

# A glyph at its own offset inside the button it belongs to.
sub _at
{
    my ( $buf, $x, $y, $which ) = @_;

    my ( $dx, $dy ) = @{ $GLYPH_AT{ $which } };
    _glyph( $buf, $x + $dx, $y + $dy, $which );

    return;
}

# ---------------------------------------------------------------------------
# The two and a half bevels

# Face outside, white inside, over dark and shadow: the sizing border, the
# scroll-bar buttons and the thumb.
sub _raised
{
    my ( $buf, $x, $y, $w, $h ) = @_;

    _edge( $buf, $x,     $y,     $w,     $h,     'FK' );
    _edge( $buf, $x + 1, $y + 1, $w - 2, $h - 2, 'WS' );

    return;
}

# The caption buttons alone, whose outer highlight is white. Side by side with
# a scroll-bar button the difference is a whole shade on the top edge, so it
# is a rule of its own rather than a rounding of the one above.
sub _soft_raised
{
    my ( $buf, $x, $y, $w, $h ) = @_;

    _edge( $buf, $x,     $y,     $w,     $h,     'WK' );
    _edge( $buf, $x + 1, $y + 1, $w - 2, $h - 2, 'FS' );

    return;
}

# The well the document sits in: the raise, upside down.
sub _sunken
{
    my ( $buf, $x, $y, $w, $h ) = @_;

    _edge( $buf, $x,     $y,     $w,     $h,     'SW' );
    _edge( $buf, $x + 1, $y + 1, $w - 2, $h - 2, 'KF' );

    return;
}

# One ring of a three-dimensional edge. $bevel is the two inks of the table in
# the POD above, lit first: along the top and left, then along the bottom and
# right, with each corner going to whichever of the two the next pixel along
# would have been.
sub _edge
{
    my ( $buf, $x, $y, $w, $h, $bevel ) = @_;

    return if $w < 1 || $h < 1;

    my ( $lit, $dim ) = split //, $bevel;

    _fill( $buf, $x,          $y,          $w - 1, 1,      $lit );
    _fill( $buf, $x,          $y,          1,      $h - 1, $lit );
    _fill( $buf, $x + $w - 1, $y,          1,      $h,     $dim );
    _fill( $buf, $x,          $y + $h - 1, $w,     1,      $dim );

    return;
}

# The scroll-bar track: face and white on alternate pixels, phased on the
# window's own corner so that two bars meeting at a corner agree about which
# square is which.
sub _dither
{
    my ( $buf, $x, $y, $w, $h ) = @_;

    for my $row ( 0 .. $h - 1 )
    {
        for my $col ( 0 .. $w - 1 )
        {
            _fill( $buf, $x + $col, $y + $row, 1, 1,
                ( $x + $col + $y + $row ) % 2 ? 'W' : 'F' );
        }
    }

    return;
}

# ---------------------------------------------------------------------------
# The buffer

# The palette rides on the buffer rather than on a package variable, because
# every drawing primitive here is handed the buffer already: a theme is then
# one argument at the top and nothing to thread through the twenty calls that
# put ink down.
sub _canvas
{
    my ( $w, $h, $theme ) = @_;

    $theme = 'default' unless defined $theme && length $theme;

    return {
        w => $w,
        h => $h,

        # A name nobody here knows is the default rather than an error. A
        # preset written against a later version should come out looking
        # ordinary, not fail to draw.
        ink  => { %ARTWORK, %{ $THEME{ $theme } || $THEME{ default } } },
        data => "\0" x ( $w * $h * 4 ),
    };
}

sub _fill
{
    my ( $buf, $x, $y, $w, $h, $ink ) = @_;

    my $rgb = $buf->{ ink }{ $ink }
        or die "GlitchVape::Chicago: no ink '$ink'\n";
    my $run = pack( 'C4', @$rgb, 255 );

    for my $row ( $y .. $y + $h - 1 )
    {
        next if $row < 0 || $row >= $buf->{ h };

        my $from = $x < 0 ? 0 : $x;
        my $to   = $x + $w - 1;
        $to = $buf->{ w } - 1 if $to >= $buf->{ w };
        next if $to < $from;

        substr $buf->{ data }, ( $row * $buf->{ w } + $from ) * 4,
            ( $to - $from + 1 ) * 4, $run x ( $to - $from + 1 );
    }

    return;
}

# The hole. Not a colour: the alpha goes to zero and the picture underneath is
# what is seen there, which is the whole point of the effect.
sub _hollow
{
    my ( $buf, $x, $y, $w, $h ) = @_;

    for my $row ( $y .. $y + $h - 1 )
    {
        next if $row < 0 || $row >= $buf->{ h };

        substr $buf->{ data }, ( $row * $buf->{ w } + $x ) * 4, $w * 4,
            "\0" x ( $w * 4 );
    }

    return;
}

sub _glyph
{
    my ( $buf, $x, $y, $which ) = @_;

    my $art = $GLYPH{ $which } or die "GlitchVape::Chicago: no '$which'\n";

    my $row = 0;
    for my $line ( @$art )
    {
        my @ink = split //, $line;
        for my $col ( 0 .. $#ink )
        {
            next if $ink[ $col ] eq '.';
            _fill( $buf, $x + $col, $y + $row, 1, 1, $ink[ $col ] );
        }
        $row++;
    }

    return;
}

sub _image
{
    my ( $buf ) = @_;
    require Image::Magick;

    my $img = Image::Magick->new(
        size   => "$buf->{w}x$buf->{h}",
        magick => 'RGBA',
        depth  => 8,
    );

    GlitchVape::Magick::check(
        $img->BlobToImage( $buf->{ data } ),
        'chicago: could not build the window'
    );

    $img->Set( magick => 'PNG', colorspace => 'sRGB' );

    return $img;
}

# ---------------------------------------------------------------------------
# The two strings

# Drawn at the size the window is drawn at, and enlarged with everything else
# rather than rendered at the final size. A caption set in crisp outline type
# over four-pixel bevels is a photograph of a window with a caption pasted on;
# the whole illusion is that this is a small picture somebody has zoomed into.

=head2 type_size( $font, $wanted )

The pointsize to set the window's lettering at: C<$wanted>, or the twelve the
interface itself used if that is not given -- but never smaller than C<$font>
can be drawn at without losing strokes.

The floor is what makes this a plain size rather than a setting with a trick
in it. Asking for less than a font can manage is always a mistake, so it is
quietly not done, and the number can be read as the size it is: a bigger one
never gives smaller lettering, and there is no value that means something
other than a size.

Measured rather than looked up -- see L</WHAT SIZE THE LETTERING IS> for why
the floor is a property of the font rather than of this program.

=cut

sub type_size
{
    my ( $font, $wanted ) = @_;

    $wanted = TEXT_SIZE unless $wanted && $wanted > 0;

    my $floor = smallest_type( $font );

    return $wanted > $floor ? $wanted : $floor;
}

=head2 smallest_type( $font )

The floor on its own: the smallest whole pointsize C<$font> can be drawn at
without losing strokes, never below the twelve the interface wants and never
above C<TEXT_MAX>.

=cut

# Cached on the font's path. A loop pays for the measurement once, and the
# render child is a fresh process each time anyway.
my %SIZE_FOR;

sub smallest_type
{
    my ( $font ) = @_;

    return TEXT_SIZE unless defined $font && length $font;

    $SIZE_FOR{ $font } = _measure( $font )
        unless exists $SIZE_FOR{ $font };

    return $SIZE_FOR{ $font };
}

sub _measure
{
    my ( $font ) = @_;
    require Image::Magick;

    my $probe = Image::Magick->new( size => '400x900' );
    $probe->Read( 'xc:none' );

    # An 'l' because it is a bare vertical stem with nothing else in it. With
    # antialiasing on, so that the thing being measured is the outline and not
    # the rasteriser's opinion of it.
    my $trouble = $probe->Annotate(
        text      => 'l',
        font      => $font,
        pointsize => PROBE_SIZE,
        fill      => 'black',
        gravity   => 'NorthWest',
        x         => 100,
        y         => 100,
        antialias => 'true',
    );

    # A font that will not load is not an error here. Something else is going
    # to report it, and guessing the size it would have wanted is no worse
    # than refusing to draw the window.
    return TEXT_SIZE if "$trouble" && "$trouble" =~ /\A Exception \s+ [45]/x;

    $probe->Trim;
    $probe->Set( page => '0x0+0+0' );

    my ( $w, $h ) = ( $probe->Get( 'width' ), $probe->Get( 'height' ) );
    return TEXT_SIZE unless $w && $h;

    # Across the middle of the stem rather than the widest row, which on a
    # face with a serif or a tail would be the serif.
    my @row = $probe->GetPixels(
        map       => 'A',
        x         => 0,
        y         => int( $h / 2 ),
        width     => $w,
        height    => 1,
        normalize => 1,
    );

    my $stem = grep { $_ > 0.5 } @row;
    return TEXT_SIZE unless $stem;

    # int() plus one is ceil for a value that is never a whole number in
    # practice, and one size too generous when it is -- which is the safe way
    # to be wrong.
    my $smallest = int( PROBE_SIZE / $stem ) + 1;

    return TEXT_SIZE if $smallest < TEXT_SIZE;
    return TEXT_MAX  if $smallest > TEXT_MAX;

    return $smallest;
}

sub _text
{
    my ( $img, $bar, $w, $icon ) = @_;

    my ( $font, $size, $caption, $menu ) =
        @{ $bar }{ qw(font size caption menu) };

    return unless $font;

    if ( defined $caption && length $caption )
    {
        # Up to the first caption button and no further. A caption too long
        # for its bar is cut off, as it is on the real thing -- letting it run
        # under the buttons turns Minimise into a letterform.
        my $from = FRAME + ICON_X + $icon + CAPTION_GAP;
        my $to   = $w - FRAME - BUTTON_IN - 3 * BUTTON_W - BUTTON_GAP;

        _annotate( $img, $font, $size, $caption, '#FFFFFF',
            [ $from, FRAME, $to - $from, CAPTION ] );
    }

    if ( defined $menu && length $menu )
    {
        my $from = FRAME + MENU_X;

        _annotate( $img, $font, $size, $menu, '#000000',
            [ $from, FRAME + CAPTION, $w - FRAME - $from, MENU ] );
    }

    return;
}

# Onto a layer the size of the whole bar the string is allowed, and composited
# in. Two things come out of that shape and neither is worth doing by hand.
#
# The layer clips: a bar is as wide as it is and the text in it is whatever
# fits, and measuring the string to decide where to cut it would mean knowing
# the font's metrics for a question the layer answers by itself.
#
# And West centres it down the bar, which is where a caption goes and, more to
# the point, is the only placement that survives a change of font. A fixed
# offset from the top of the bar is an offset to some particular font's
# ascender, and the next font hangs its letters somewhere else.
sub _annotate
{
    my ( $img, $font, $size, $string, $colour, $box ) = @_;
    require Encode;
    require Image::Magick;

    my ( $x, $y, $w, $h ) = @$box;
    return if $w < 1 || $h < 1;

    my $layer = Image::Magick->new( size => "${w}x${h}" );
    $layer->Read( 'xc:transparent' );

    # Antialiasing off, for the reason the whole file exists: a grey edge
    # pixel is a thing this display could not produce, and four times size it
    # is four grey pixels.
    $layer->Annotate(
        text      => Encode::encode( 'UTF-8', $string ),
        font      => $font,
        pointsize => $size,
        fill      => $colour,
        gravity   => 'West',
        x         => 0,
        y         => 0,
        encoding  => 'UTF-8',
        antialias => 'false',
    );

    $img->Composite(
        image   => $layer->[ 0 ],
        compose => 'Over',
        x       => $x,
        y       => $y
    );

    return;
}

sub _clamp
{
    my ( $value, $low, $high ) = @_;

    $value = $low unless defined $value;
    $value = $low  if $value < $low;
    $value = $high if $value > $high;

    return $value;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::VGA>, which keeps its font in the file for the same reasons, and
L<GlitchVape::Effect::Overlay> for the effect that puts this over a photograph.

=cut
