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
Darkened horizontal lines at a fixed pitch, multiplied over the image. Set
C<drift> and in an animation the pattern travels downward, which reads as a
monitor slightly out of sync with the camera filming it.

The travel is snapped to a whole number of line spacings so the loop closes.
Ask for ten rows at a spacing of six and you get twelve: seven-eighths of the
way round is not a loop, and the jolt where the last frame fails to meet the
first plays for as long as the video does.
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
            doc     =>
                'Rows the pattern travels per loop, snapped to whole spacings',
        },
    },
    apply => \&_scanlines,
);

sub _scanlines
{
    my ( $ctx, $p ) = @_;
    return if $p->{ opacity } <= 0;

    my ( $w, $h ) = $ctx->dims;

    # Snapped to whole spacings by travel(), so the last frame of a loop lands
    # exactly where the first one started.
    my $offset = int( $ctx->travel( $p->{ drift }, $p->{ spacing } ) + 0.5 );

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

C<drift> sweeps the band back and forth across the glass over a loop, as a
fraction of the frame. Back and forth rather than across and round, for the
same reason the echo in C<ghost> wanders: there is one band, so it has nothing
to hide a jump behind. It is also the honest motion -- the reflection moves
because whoever is holding the camera does.
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
        drift => {
            default => 0,
            type    => 'num',
            min     => -2,
            max     =>  2,
            doc     => 'Frame-widths the band sweeps either way over a loop',
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

    # Offset before the rotation, so the band travels along its own normal --
    # across the glass whatever angle it is set at, rather than always
    # vertically down the frame.
    $sheen->Composite(
        image   => $full->[ 0 ],
        compose => 'Over',
        gravity => 'Center',
        y       => int $ctx->excursion( $p->{ drift } * $diag ),
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

# ---------------------------------------------------------------------------

$R->register(
    name    => 'cmyk',
    title   => 'Four-Colour Halftone',
    stage   => 'optics',
    summary => 'Separate CMYK screens at print angles, with rosettes',
    doc     => <<'DOC',
The thing colour printing actually does, which C<halftone> does not: separate
the image into cyan, magenta, yellow and black, screen each one on its own
axis, and print the four on top of one another.

The angles are the whole point. Four screens on the same axis land their dots
in the same places and produce a flat, muddy grid -- which is what screening
every channel together gives you. Turned against each other, the dots
interleave into the rosette that a magazine page shows under a loupe, and the
eye reads the mixture as continuous colour instead of as a pattern.

Fifteen degrees apart is the classical answer, with yellow the odd one out.
Black at 45 is least visible to the eye and carries the detail; yellow at 0 is
the weakest ink, so its screen showing through matters least. Two inks less
than 15 degrees apart beat against each other into a coarse moire, which is
the failure mode this parameter exists to let you find on purpose.

Screens are built once per angle and reused, so an animation pays for them on
its first frame only.
DOC
    params => {
        pitch => {
            default => 8,
            type    => 'int',
            min     => 2,
            max     => 40,
            doc     => 'Screen ruling: the width of one dot cell in pixels',
        },
        angles => {
            default => '15,75,0,45',
            type    => 'str',
            doc     => 'Screen angle per ink, in the order C,M,Y,K',
        },
        paper => {
            default => '#FFFFFF',
            type    => 'str',
            doc     => 'Colour of the unprinted stock',
        },
        strength => {
            default => 1.0,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Blend back over the original',
        },
    },
    apply => \&_cmyk,
);

# The four ink planes ImageMagick's CMYK separation hands back, in order.
use constant _INKS => 4;

sub _cmyk
{
    my ( $ctx, $p ) = @_;
    return if $p->{ strength } <= 0;

    my @angles = grep { length } split m{\s*,\s*}, $p->{ angles } // q{};
    die "cmyk: angles needs four values, C,M,Y,K -- got '$p->{angles}'\n"
        unless @angles == _INKS;

    for my $a ( @angles )
    {
        die "cmyk: '$a' is not an angle\n" unless $a =~ /^-?[\d.]+$/;
    }

    my ( $w, $h ) = $ctx->dims;

    my $orig = undef;
    if ( $p->{ strength } < 1 )
    {
        $orig = $ctx->clone;
    }

    my @screens =
        map { _screen_file( $p->{ pitch }, $_, $w, $h, $ctx->tmpdir ) } @angles;

    # -layers composite pairs the images before null: with those after it, so
    # each separated plane meets its own screen in one pass. Compositing them
    # one at a time would mean four round trips through PNG for what is a
    # single decision per pixel.
    $ctx->magick(
        '-colorspace', 'CMYK', '-separate', 'null:', @screens,
        '-compose',    'Mathematics',

        # plane - screen + 0.5, thresholded at 0.5: ink wherever the plane is
        # darker than the screen's value at that pixel.
        '-define',    'compose:args=0,-1,1,0.5',
        '-layers',    'composite',
        '-threshold', '50%',
        '-set',       'colorspace', 'CMYK', '-combine', '-colorspace', 'sRGB',

        # Ink onto stock, so the paper colour reaches the inks as well as the
        # gaps between the dots. Newsprint is grey and absorbs, and a cyan dot
        # on it is not the cyan a proof on white card shows; compositing the
        # paper behind instead would leave the dots themselves impossibly
        # clean and read as a sticker rather than as a print.
        _paper_args( $p->{ paper }, $w, $h ),
    );

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

# Nothing at all for white stock, which is the default: the multiply would be
# a no-op costing a full-frame composite per frame.
sub _paper_args
{
    my ( $paper, $w, $h ) = @_;

    return () unless defined $paper && length $paper;
    return () if lc( $paper ) =~ /^(?:#f{3}|#f{6}|white)$/;

    return (
        '(', '-size',    "${w}x$h",  "xc:$paper",
        ')', '-compose', 'Multiply', '-composite',
    );
}

# One ink's screen, at image size, cached under the render's temporary
# directory. The cache is what makes this affordable in an animation: the
# screen depends on the pitch, the angle and the frame size, none of which
# move between frames.
sub _screen_file
{
    my ( $pitch, $angle, $w, $h, $dir ) = @_;
    require File::Spec;

    my $path =
        File::Spec->catfile( $dir, "screen_${pitch}_${angle}_${w}x$h.png" );
    return $path if -f $path;

    my $cell = _cell_file( $pitch, $dir );

    # Twice the diagonal, not once. The screen is tiled square and then
    # rotated, and the crop has to come from inside the rotated square rather
    # than off its corner -- catch the corner and the background counts as
    # "no ink there", which lightens that ink across the whole frame. At 45
    # degrees, the worst case, one diagonal leaves the black plane visibly
    # under-inked while every measurement of the cell still looks correct.
    my $side = int( 2 * sqrt( $w**2 + $h**2 ) / $pitch + 2 ) * $pitch;

    my @argv = GlitchVape::Tools::magick_argv(
        '-size', "${side}x$side", "tile:$cell",

        # Point, so rotation samples the cell's thresholds rather than
        # averaging neighbouring ones into values the cell never had.
        '-filter',  'Point',
        '-rotate',  $angle,
        '-gravity', 'center',
        '-crop',    "${w}x$h+0+0",
        '+repage',  $path,
    );

    system( @argv ) == 0
        or die "GlitchVape: could not build the $angle-degree screen\n";

    return $path;
}

# One dot cell: the thresholds of a clustered-dot screen, which is a ranking
# of the cell's pixels by distance from its centre. Ranking rather than a
# radial gradient because what matters is that the thresholds are spread
# evenly over 0..1 -- a gradient's are not, and screening against one shifts
# every ink's density by tens of percent while still looking like a dot.
sub _cell_file
{
    my ( $pitch, $dir ) = @_;
    require File::Spec;

    my $path = File::Spec->catfile( $dir, "cell_$pitch.png" );
    return $path if -f $path;

    my $cells = $pitch**2;
    my $mid   = ( $pitch - 1 ) / 2;

    my @offset;
    for my $i ( 0 .. $cells - 1 )
    {
        my ( $x, $y ) = ( $i % $pitch, int( $i / $pitch ) );
        push @offset, [ ( $x - $mid )**2 + ( $y - $mid )**2, $i ];
    }

    my @value;
    my $rank = 0;
    for my $cell ( sort { $a->[ 0 ] <=> $b->[ 0 ] } @offset )
    {
        $value[ $cell->[ 1 ] ] = int( ( $rank + 0.5 ) / $cells * 255 );
        $rank++;
    }

    my $raw = File::Spec->catfile( $dir, "cell_$pitch.gray" );
    open my $fh, '>:raw', $raw
        or die "GlitchVape: cannot write $raw: $!\n";
    print { $fh } join q{}, map { chr } @value;
    close $fh;

    my @argv = GlitchVape::Tools::magick_argv( '-size', "${pitch}x$pitch",
        '-depth', '8', "gray:$raw", $path );

    system( @argv ) == 0
        or die "GlitchVape: could not build the $pitch-pixel dot cell\n";

    return $path;
}

1;
