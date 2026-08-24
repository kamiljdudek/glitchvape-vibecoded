package GlitchVape::Effect::Screen;

use strict;
use warnings;

use GlitchVape::Magick   ();
use GlitchVape::Registry ();
use GlitchVape::Raster   ();
use GlitchVape::Tools    ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Effect::Screen - display-surface artefacts

=head1 DESCRIPTION

Everything in this module models the screen the image is imagined to be shown
on rather than the signal reaching it: scanlines, phosphor structure, glass
curvature, lens bloom and vignetting. These run late in the pipeline, after the
signal damage, because a real CRT applies them to whatever it is fed.

=cut

my $R = 'GlitchVape::Registry';

# ---------------------------------------------------------------------------

$R->register(
    name    => 'scanlines',
    title   => 'Scanlines',
    stage   => 'optics',
    summary => 'Horizontal CRT/TV scanlines',
    doc     => <<'DOC',
Darkened horizontal lines at a fixed pitch, multiplied over the image. In an
animation the pattern drifts slowly downward, which reads as a monitor slightly
out of sync with the camera filming it.
DOC
    params => {
        opacity => {
            default => 0.35,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How dark each line is',
        },
        spacing => {
            default => 3,
            type    => 'int',
            min     => 1,
            max     => 64,
            doc     => 'Pixels between line centres',
        },
        thickness => {
            default => 1,
            type    => 'int',
            min     => 1,
            max     => 32,
            doc     => 'Rows darkened per line',
        },
        softness => {
            default => 0,
            type    => 'int',
            min     => 0,
            max     => 8,
            doc     => 'Rows over which the line fades out',
        },
        drift => {
            default => 0,
            type    => 'num',
            min     => -64,
            max     =>  64,
            doc     => 'Rows the pattern travels over one animation loop',
        },
    },
    apply => \&_scanlines,
);

sub _scanlines
{
    my ( $ctx, $p ) = @_;
    return if $p->{ opacity } <= 0;

    my ( $w, $h ) = $ctx->dims;

    my $offset = 0;
    $offset = int( $p->{ drift } * $ctx->phase + 0.5 ) if $p->{ drift };

    my $tile = GlitchVape::Raster::scanline_tile(
        $ctx->tmpdir,
        spacing   => $p->{ spacing },
        thickness => $p->{ thickness },
        opacity   => $p->{ opacity },
        softness  => $p->{ softness },
        offset    => $offset,
    );

    my $mask = GlitchVape::Raster::tiled( $ctx, $tile, $w, $h );
    $ctx->magick( $mask, '-compose', 'Multiply', '-composite' );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'grille',
    title   => 'Aperture Grille',
    stage   => 'optics',
    summary => 'RGB phosphor aperture grille',
    doc     => <<'DOC',
Vertical red/green/blue stripes, as on a Trinitron. Only visible at small
stripe widths if the output is viewed at full size, so widths of 2-3 read
better on a downscaled image.
DOC
    params => {
        width => {
            default => 1,
            type    => 'int',
            min     => 1,
            max     => 16,
            doc     => 'Pixels per phosphor stripe',
        },
        strength => {
            default => 0.25,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Stripe saturation',
        },
        brighten => {
            default => 1.15,
            type    => 'num',
            min     => 0.5,
            max     => 3,
            doc     => 'Gain to offset the darkening the mask causes',
        },
    },
    apply => \&_grille,
);

sub _grille
{
    my ( $ctx, $p ) = @_;
    return if $p->{ strength } <= 0;

    my ( $w, $h ) = $ctx->dims;

    my $tile = GlitchVape::Raster::grille_tile(
        $ctx->tmpdir,
        width    => $p->{ width },
        strength => $p->{ strength },
    );

    my $mask = GlitchVape::Raster::tiled( $ctx, $tile, $w, $h );
    $ctx->magick( $mask, '-compose', 'Multiply', '-composite' );

    $ctx->image->Modulate( brightness => $p->{ brighten } * 100 )
        if $p->{ brighten } != 1;
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'bloom',
    title   => 'Bloom',
    stage   => 'optics',
    summary => 'Highlight glow / halation',
    doc     => <<'DOC',
Isolates the brightest parts of the image, blurs them heavily, and screens the
result back over the original. This is what makes neon read as neon: the glow
has to spill past the edges of the thing emitting it.
DOC
    params => {
        threshold => {
            default => 65,
            type    => 'num',
            min     => 0,
            max     => 100,
            doc     => 'Luminance percentage above which pixels glow',
        },
        radius => {
            default => 24,
            type    => 'num',
            min     => 0.5,
            max     => 200,
            doc     => 'Blur sigma of the glow',
        },
        strength => {
            default => 0.6,
            type    => 'num',
            min     => 0,
            max     => 2,
            doc     => 'Intensity of the glow added back',
        },
        tint => {
            default => '',
            type    => 'str',
            doc     => 'Optional colour for the glow, e.g. "#FF71CE"',
        },
    },
    apply => \&_bloom,
);

sub _bloom
{
    my ( $ctx, $p ) = @_;
    return if $p->{ strength } <= 0;

    my $glow = $ctx->clone;

    # Everything below the threshold goes to black so it contributes nothing
    # when screened back on.
    $glow->BlackThreshold( threshold => "$p->{threshold}%" );
    $glow->Blur( radius => 0, sigma => $p->{ radius } );

    if ( length $p->{ tint } )
    {
        $glow->Colorize( fill => $p->{ tint }, blend => '60/60/60' );
    }

    if ( $p->{ strength } != 1 )
    {
        $glow->Evaluate( operator => 'Multiply', value => $p->{ strength } );
    }

    $ctx->image->Composite(
        image   => $glow->[ 0 ],
        compose => 'Screen',
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'vignette',
    title   => 'Vignette',
    stage   => 'optics',
    summary => 'Darkened edges',
    doc     => <<'DOC',
Radial falloff towards the corners. Sells the "photographed off a screen" idea
more than almost anything else, because a camera pointed at a monitor always
has one.
DOC
    params => {
        strength => {
            default => 0.5,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How dark the corners get',
        },
        size => {
            default => 1.4,
            type    => 'num',
            min     => 0.2,
            max     => 4,
            doc     => 'Radius of the clear centre; larger = subtler',
        },
        softness => {
            default => 0.6,
            type    => 'num',
            min     => 0,
            max     => 4,
            doc     => 'Blur applied to the falloff edge',
        },
    },
    apply => \&_vignette,
);

sub _vignette
{
    my ( $ctx, $p ) = @_;
    return if $p->{ strength } <= 0;
    require Image::Magick;

    my ( $w, $h ) = $ctx->dims;

    # radial-gradient is white in the centre, black at the edge. Scaling it up
    # and cropping back moves the black further out, widening the clear area.
    my $gw = int( $w * $p->{ size } ) || $w;
    my $gh = int( $h * $p->{ size } ) || $h;

    # Build the falloff with its darkest point already correct, rather than
    # generating white-to-black and rescaling afterwards: Evaluate's Add takes
    # quantum units, not a 0..1 fraction, which makes "multiply then lift"
    # silently crush the whole image instead of only its corners.
    my $floor = sprintf 'gray(%d%%)',
        int( ( 1 - $p->{ strength } ) * 100 + 0.5 );

    my $grad = Image::Magick->new( size => "${gw}x${gh}" );
    GlitchVape::Magick::check(
        $grad->Read( "radial-gradient:white-$floor" ),
        "vignette: could not build gradient"
    );

    $grad->Set( gravity => 'Center' );
    $grad->Crop( geometry => "${w}x${h}+0+0", gravity => 'Center' );
    $grad->Set( page => '0x0+0+0' );

    $grad->Blur( radius => 0, sigma => $p->{ softness } * 20 )
        if $p->{ softness } > 0;

    $ctx->image->Composite(
        image   => $grad->[ 0 ],
        compose => 'Multiply',
        gravity => 'Center',
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'curvature',
    title   => 'Screen Curvature',
    stage   => 'optics',
    summary => 'CRT glass bulge (barrel distortion)',
    doc     => <<'DOC',
Bows the image outward as if it were painted on the inside of a curved tube
face. Small amounts (0.02-0.08) are convincing; larger amounts read as a
fisheye lens instead.
DOC
    params => {
        amount => {
            default => 0.05,
            type    => 'num',
            min     => -0.5,
            max     =>  0.5,
            doc     => 'Positive bulges outward, negative pinches inward',
        },
        background => {
            default => 'black',
            type    => 'str',
            doc     => 'Colour revealed at the corners',
        },
        zoom => {
            default => 1.0,
            type    => 'num',
            min     => 0.5,
            max     => 2,
            doc     => 'Scale up afterwards to hide the revealed corners',
        },
    },
    apply => \&_curvature,
);

sub _curvature
{
    my ( $ctx, $p ) = @_;
    return if abs( $p->{ amount } ) < 0.001;

    my ( $w, $h ) = $ctx->dims;

    # Barrel coefficients are A B C (D is derived as 1-A-B-C). Driving C alone
    # gives a clean single-parameter bulge.
    $ctx->magick(
        '-virtual-pixel', 'background', '-background', $p->{ background },
        '-distort',       'Barrel', sprintf( '0.0 0.0 %.5f', $p->{ amount } ),
    );

    if ( $p->{ zoom } != 1 )
    {
        my $zw = int( $w * $p->{ zoom } );
        my $zh = int( $h * $p->{ zoom } );
        $ctx->magick(
            '-resize', "${zw}x${zh}!", '-gravity', 'Center',
            '-extent', "${w}x${h}",
        );
    }
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'halftone',
    title   => 'Halftone Screen',
    stage   => 'optics',
    summary => 'Ordered-dither dot screen (print / newsprint)',
    doc     => <<'DOC',
Ordered dithering with a fixed threshold map, giving the regular dot texture of
cheap colour printing. Applied per channel it produces the CMYK-ish rosette
look of a scanned magazine page.
DOC
    params => {
        map => {
            default => 'o4x4',
            type    => 'enum',
            values => [ qw(o2x2 o3x3 o4x4 o8x8 h4x4a h6x6a h8x8a c5x5b c7x7b) ],
            doc    =>
                'ImageMagick threshold map: o* ordered, h* halftone, c* circles',
        },
        levels => {
            default => 4,
            type    => 'int',
            min     => 2,
            max     => 16,
            doc     => 'Intensity levels per channel',
        },
        strength => {
            default => 1.0,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Blend back over the original',
        },
    },
    apply => \&_halftone,
);

sub _halftone
{
    my ( $ctx, $p ) = @_;
    return if $p->{ strength } <= 0;

    # Below full strength the effect is blended back over the untouched
    # image, so a copy has to be kept before anything modifies it.
    my $orig = undef;
    if ( $p->{ strength } < 1 )
    {
        $orig = $ctx->clone;
    }

    $ctx->magick( '-ordered-dither', "$p->{map},$p->{levels}" );

    if ( $orig )
    {
        my $pct = int( ( 1 - $p->{ strength } ) * 100 + 0.5 );
        $ctx->image->Composite(
            image   => $orig->[ 0 ],
            compose => 'Blend',
            args    => "$pct",
        );
    }
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'glare',
    title   => 'Screen Glare',
    stage   => 'optics',
    summary => 'Diagonal reflection sheen across the glass',
    doc     => <<'DOC',
A soft diagonal band of light, as if a window were reflecting off the screen.
Cheap but very effective at making a flat render feel like a photograph of a
physical object.
DOC
    params => {
        strength => {
            default => 0.18,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Brightness of the sheen',
        },
        angle => {
            default => 35,
            type    => 'num',
            min     => -90,
            max     =>  90,
            doc     => 'Tilt of the band in degrees',
        },
        width => {
            default => 0.35,
            type    => 'num',
            min     => 0.05,
            max     => 2,
            doc     => 'Band width as a fraction of the image',
        },
    },
    apply => \&_glare,
);

sub _glare
{
    my ( $ctx, $p ) = @_;
    return if $p->{ strength } <= 0;
    require Image::Magick;

    my ( $w, $h ) = $ctx->dims;
    my $diag = int( sqrt( $w * $w + $h * $h ) ) + 2;
    my $band = int( $diag * $p->{ width } ) || 1;

    # Build the band as a vertical gradient on an oversized canvas, rotate it,
    # then crop back: rotating a gradient is far cheaper than computing a
    # rotated one per pixel.
    my $strip = Image::Magick->new( size => "16x$diag" );
    GlitchVape::Magick::check(
        $strip->Read( 'gradient:black-white' ),
        "glare: could not build gradient"
    );

    my $sheen = Image::Magick->new( size => "${diag}x${diag}" );
    $sheen->Read( 'xc:black' );
    $strip->Resize( geometry => "${diag}x${band}!" );

    # Mirror the ramp so the band is bright in the middle and dark at both
    # edges, rather than a hard-edged wedge.
    my $mirror = $strip->Clone;
    $mirror->Flip;
    my $pair = Image::Magick->new;
    push @$pair, $strip->[ 0 ], $mirror->[ 0 ];
    my $full = $pair->Append( stack => 1 );

    $sheen->Composite(
        image   => $full->[ 0 ],
        compose => 'Over',
        gravity => 'Center',
    );
    $sheen->Rotate( degrees => $p->{ angle }, background => 'black' );
    $sheen->Set( gravity => 'Center' );
    $sheen->Crop( geometry => "${w}x${h}+0+0", gravity => 'Center' );
    $sheen->Set( page => '0x0+0+0' );
    $sheen->Blur( radius => 0, sigma => $band / 6 ) if $band > 12;
    $sheen->Evaluate( operator => 'Multiply', value => $p->{ strength } );

    $ctx->image->Composite(
        image   => $sheen->[ 0 ],
        compose => 'Screen',
        gravity => 'Center',
    );
    return;
}

1;
