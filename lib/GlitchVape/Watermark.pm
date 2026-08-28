package GlitchVape::Watermark;

use strict;
use warnings;
use utf8;

use Encode ();

use GlitchVape::Fonts  ();
use GlitchVape::Magick ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Watermark - the program signing its own output, when asked

=head1 DESCRIPTION

Two ways of marking an exported picture as having come from here, and a third
which is neither and is the default.

This is not the C<watermark> effect. That one is part of the look: a tiled
string the user chose, in a colour they chose, which they can put anywhere in
the pipeline. This is branding, it is the same on every render, and it is
applied after the pipeline has finished because it is not part of the
photograph.

=head1 THE BAR CHANGES THE PICTURE'S SIZE

C<logo> draws inside the frame. C<bar> adds a strip underneath it, so the
result is taller than what the pipeline produced.

That is deliberate -- a caption printed over the corner of a photograph covers
part of the photograph, and the whole point of the bar style is to sign the
image without touching it. It does mean an export at a chosen size comes out
that size plus the bar, and that the bar has to be applied to every frame of
an animation or the encoder is handed frames of two different shapes.

=head1 WHY THE APP NAME IS STROKED RATHER THAN SET IN A BOLD FACE

The bar sets its text in the C<cjk_serif> role, which resolves to whatever
fontconfig can find. There is no guarantee that a bold cut of it exists, and
asking for one that is absent gets a silent fallback to something else
entirely -- the name in a different face from the words around it, which looks
like a mistake rather than like emphasis.

Drawing it with a thin stroke of its own colour thickens the glyphs that are
there. It works with any face, and cannot fall back to the wrong one.

=cut

# The bar, as fractions of the picture's width. Proportional rather than fixed
# so that a bar on a 4000-pixel export is not a hairline.
use constant BAR_HEIGHT => 0.032;
use constant BAR_MIN    => 14;
use constant BAR_MAX    => 46;

# From the right edge, in bar heights. The line is set against that edge
# rather than centred: centred, it reads as a caption belonging to the
# picture, and this is a signature.
use constant BAR_INSET => 0.6;

use constant BAR_INK   => '#C77DFF';
use constant BAR_PAPER => '#000000';

use constant LOGO_TEXT    => 'VA';
use constant LOGO_HEIGHT  => 0.075;
use constant LOGO_OPACITY => 0.38;
use constant LOGO_MARGIN  => 0.025;

=head2 kinds()

The keys this module understands, in display order.

=cut

sub kinds { return qw(none logo bar) }

=head2 apply( $image, $kind )

Mark C<$image> in place. Anything other than C<logo> or C<bar> does nothing,
so an unknown value out of a preferences file is the same as none rather than
an error on the way to writing a file.

Returns the image, which for C<bar> may be a different one: appending changes
the geometry, and ImageMagick's append hands back a new sequence.

=cut

sub apply
{
    my ( $image, $kind ) = @_;

    return $image unless $image;

    $kind = q{} unless defined $kind;

    return _logo( $image ) if $kind eq 'logo';
    return _bar( $image )  if $kind eq 'bar';

    return $image;
}

# ---------------------------------------------------------------------------

sub _logo
{
    my ( $image ) = @_;
    require Image::Magick;

    my ( $w, $h ) = ( $image->Get( 'width' ), $image->Get( 'height' ) );
    return $image unless $w && $h;

    my $shape = _letterforms() or return $image;

    my $height = int( $h * LOGO_HEIGHT ) || 8;
    my $scale  = $height / ( $shape->Get( 'height' ) || 1 );
    my $width  = int( $shape->Get( 'width' ) * $scale ) || 8;

    my $mark = $shape->Clone;
    $mark->Resize( geometry => "${width}x$height!" );

    # The silhouette is white; the alpha is the shape. Multiplying the alpha
    # rather than setting it keeps the resize's own antialiasing, which is
    # what stops the letters looking notched at small sizes.
    $mark->Evaluate(
        operator => 'Multiply',
        value    => LOGO_OPACITY,
        channel  => 'Alpha',
    );

    my $margin = int( $h * LOGO_MARGIN ) || 4;

    $image->Composite(
        image   => $mark->[ 0 ],
        compose => 'Over',
        gravity => 'SouthEast',
        x       => $margin,
        y       => $margin,
    );

    return $image;
}

# The V and the A out of the program's own logo, as a white silhouette on
# transparency.
#
# Taken from the artwork rather than typeset, because the mark is a drawing
# and not a word: setting "VA" in whatever font a role resolves to gives two
# letters that are not these letters, and on a machine where the role falls
# back it gives two letters that are not anybody's.
#
# The extraction leans on the picture being flat colour. The V is pure white
# and the A pure black, and nothing else in the logo is within a hair of
# either -- the nearest is a light grey at 121 pixels out of forty thousand.
# So "exactly black or exactly white" is the letterforms plus the wires
# strung across the sky and the bar the letters stand on.
#
# The wires go with an opening: they are a pixel or two thick and the strokes
# are ten. The bar survives that, being solid, and goes on a shape argument
# instead -- it is a separate band of rows with a clear gap above it, and the
# letters are the taller of the two bands. Both of those are properties of
# the drawing rather than numbers measured off it once.
my $LETTERFORMS;

sub _letterforms
{
    return $LETTERFORMS if $LETTERFORMS;
    require Image::Magick;

    require GlitchVape::Assets;
    my $path = GlitchVape::Assets::find( 'artwork', 'logo.png' )
        or return undef;

    my $logo = Image::Magick->new;
    return undef if "" . ( $logo->Read( $path ) // q{} ) =~ /^Exception [45]/;

    my ( $w, $h ) = ( $logo->Get( 'width' ), $logo->Get( 'height' ) );
    return undef unless $w && $h;

    my @px = $logo->GetPixels(
        map       => 'RGB',
        width     => $w,
        height    => $h,
        normalize => 1
    );

    my @lit;
    for my $i ( 0 .. $w * $h - 1 )
    {
        my ( $r, $g, $b ) = @px[ $i * 3, $i * 3 + 1, $i * 3 + 2 ];

        my $dark  = $r < 0.02 && $g < 0.02 && $b < 0.02;
        my $light = $r > 0.98 && $g > 0.98 && $b > 0.98;

        $lit[ $i ] = ( $dark || $light ) ? 255 : 0;
    }

    # Through a file of raw bytes, not SetPixels. SetPixels reports no error
    # here and writes nothing at all -- an eight-by-eight probe with two
    # pixels set reads back with none -- so the buffer would have been
    # silently black and the extraction would have found no letters. Raw
    # greyscale bytes read back through gray: is the path the threshold
    # matrices in Effect/Texture and Effect/Screen already use, for the same
    # reason.
    require File::Temp;
    my ( $fh, $raw ) = File::Temp::tempfile(
        'gv_mark_XXXXXX',
        SUFFIX => '.gray',
        TMPDIR => 1
    );
    binmode $fh;
    print { $fh } join q{}, map { chr } @lit;
    close $fh;

    my $mask = Image::Magick->new;
    $mask->Set( size => "${w}x$h", depth => 8 );
    my $trouble = $mask->Read( "gray:$raw" );
    unlink $raw;

    return undef if "$trouble" && "$trouble" =~ /^Exception [45]/;

    $mask->Morphology( method => 'Open', kernel => 'Square:2' );

    my $box = _tallest_band( $mask ) or return undef;

    $mask->Crop( geometry => sprintf '%dx%d+%d+%d', @$box );
    $mask->Set( page => '0x0+0+0' );

    # White where the letters are, transparent everywhere else: the mask is
    # greyscale, so it becomes the alpha of a white rectangle.
    my $shape = Image::Magick->new(
        size => sprintf '%dx%d',
        $mask->Get( 'width' ), $mask->Get( 'height' )
    );
    $shape->Read( 'xc:white' );
    $shape->Set( alpha => 'on' );

    $mask->Set( alpha => 'copy' );
    $shape->Composite( image => $mask->[ 0 ], compose => 'CopyAlpha' );

    return $LETTERFORMS = $shape;
}

# The bounding box of the tallest run of consecutive lit rows.
#
# The letters occupy eighty rows and the bar underneath them six, with a gap
# between, so "tallest" picks the letters without knowing where either is.
sub _tallest_band
{
    my ( $mask ) = @_;

    my ( $w, $h ) = ( $mask->Get( 'width' ), $mask->Get( 'height' ) );

    my @px = $mask->GetPixels(
        map       => 'I',
        width     => $w,
        height    => $h,
        normalize => 1
    );

    my ( @bands, $open );
    for my $y ( 0 .. $h - 1 )
    {
        my $any = 0;
        for my $x ( 0 .. $w - 1 )
        {
            next if $px[ $y * $w + $x ] < 0.5;
            $any = 1;
            last;
        }

        if    ( $any )  { $open ||= { top => $y }; $open->{ bottom } = $y }
        elsif ( $open ) { push @bands, $open;      undef $open }
    }
    push @bands, $open if $open;
    return undef unless @bands;

    my ( $best ) = reverse sort {
        ( $a->{ bottom } - $a->{ top } ) <=> ( $b->{ bottom } - $b->{ top } )
    } @bands;

    # The horizontal extent of that band alone, so the crop is the letters
    # and not the full width of the drawing they sit in.
    my ( $from, $to );
    for my $y ( $best->{ top } .. $best->{ bottom } )
    {
        for my $x ( 0 .. $w - 1 )
        {
            next if $px[ $y * $w + $x ] < 0.5;
            $from = $x if !defined $from || $x < $from;
            $to   = $x if !defined $to   || $x > $to;
        }
    }

    return undef unless defined $from;

    return [
        $to - $from + 1,
        $best->{ bottom } - $best->{ top } + 1,
        $from, $best->{ top },
    ];
}

sub _bar
{
    my ( $image ) = @_;
    require Image::Magick;

    my ( $w, $h ) = ( $image->Get( 'width' ), $image->Get( 'height' ) );
    return $image unless $w && $h;

    my $bar = int( $h * BAR_HEIGHT );
    $bar = BAR_MIN if $bar < BAR_MIN;
    $bar = BAR_MAX if $bar > BAR_MAX;

    my $strip = Image::Magick->new( size => "${w}x$bar" );
    GlitchVape::Magick::check(
        $strip->Read( 'xc:' . BAR_PAPER ),
        'watermark: could not build the bar'
    );

    my $font = _font( 'cjk_serif' );
    my $size = int( $bar * 0.5 ) || 8;

    my $lead = Encode::encode( 'UTF-8', 'Created with ' );
    my $name = Encode::encode( 'UTF-8', 'GlitchVape' );

    # Measured so the two runs can be centred as one line. Drawn separately
    # because only the second is emphasised, and Annotate has one weight.
    my @lead_metrics = $strip->QueryFontMetrics(
        text      => $lead,
        pointsize => $size,
        encoding  => 'UTF-8',
        ( $font ? ( font => $font ) : () ),
    );
    my @name_metrics = $strip->QueryFontMetrics(
        text      => $name,
        pointsize => $size,
        encoding  => 'UTF-8',
        ( $font ? ( font => $font ) : () ),
    );

    my $lead_w = $lead_metrics[ 4 ] || 0;
    my $name_w = $name_metrics[ 4 ] || 0;

    my $inset = int( $bar * BAR_INSET );
    my $start = $w - $inset - ( $lead_w + $name_w );
    $start = 0 if $start < 0;

    my %common = (
        pointsize => $size,
        fill      => BAR_INK,
        gravity   => 'West',
        y         => 0,
        antialias => 'true',
        encoding  => 'UTF-8',
        ( $font ? ( font => $font ) : () ),
    );

    $strip->Annotate( %common, text => $lead, x => $start );

    # The stroke is the emphasis: see the POD above on why not a bold face.
    # Scaled with the type so it stays a weight rather than becoming an
    # outline on a large export.
    $strip->Annotate(
        %common,
        text        => $name,
        x           => $start + $lead_w,
        stroke      => BAR_INK,
        strokewidth => ( $size > 30 ? 1.2 : 0.6 ),
    );

    my $stack = Image::Magick->new;
    push @$stack, $image->[ 0 ], $strip->[ 0 ];

    my $joined = $stack->Append( stack => 1 );
    return $image unless $joined;

    return $joined;
}

# A role, or undef to let ImageMagick pick. Undef rather than dying: a
# watermark is decoration, and refusing to write somebody's export because a
# font role did not resolve would be the wrong trade.
sub _font
{
    my ( $role ) = @_;

    return eval { GlitchVape::Fonts::resolve( $role ) };
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Prefs> for where the choice is kept, and the C<watermark>
effect in L<GlitchVape::Effect::Overlay> for the other kind entirely.

=cut
