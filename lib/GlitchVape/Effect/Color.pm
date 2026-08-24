package GlitchVape::Effect::Color;

use strict;
use warnings;

use GlitchVape::Magick   ();
use GlitchVape::Pixels   ();
use GlitchVape::Registry ();
use GlitchVape::Palette  ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Effect::Color - colour separation, grading and palette effects

=cut

my $R  = 'GlitchVape::Registry';
my $PI = 3.14159265358979;

# ---------------------------------------------------------------------------

$R->register(
    name    => 'chroma_shift',
    title   => 'Chromatic Aberration',
    stage   => 'channels',
    summary => 'RGB channel separation (chromatic aberration)',
    doc     => <<'DOC',
Offsets the red and blue channels in opposite directions, leaving green in
place. Green carries most of the perceived luminance, so anchoring it keeps the
image sharp while the edges fringe cyan/magenta.
DOC
    params => {
        amount => {
            default => 6,
            type    => 'num',
            min     => 0,
            max     => 200,
            doc     => 'Separation in pixels between the red and blue channels',
        },
        angle => {
            default => 0,
            type    => 'num',
            min     => -360,
            max     =>  360,
            doc     => 'Direction of separation in degrees (0 = horizontal)',
        },
        jitter => {
            default => 0,
            type    => 'num',
            min     => 0,
            max     => 50,
            doc     => 'Random per-render variation added to amount',
        },
        anchor => {
            default => 'green',
            type    => 'enum',
            values  => [ qw(red green blue) ],
            doc     => 'Channel held stationary',
        },
    },
    apply => \&_chroma_shift,
);

sub _chroma_shift
{
    my ( $ctx, $p ) = @_;

    my $rng    = $ctx->rng_for( 'chroma_shift' );
    my $amount = $p->{ amount };
    $amount += $rng->between( -$p->{ jitter }, $p->{ jitter } )
        if $p->{ jitter };

    # Around an animation loop the fringe should breathe, not jump.
    if ( $ctx->frames > 1 )
    {
        $amount *= 1 + 0.35 * sin( 2 * $PI * $ctx->phase );
    }
    return if abs( $amount ) < 0.01;

    my $rad = $p->{ angle } * $PI / 180;
    my $dx  = $amount * cos( $rad );
    my $dy  = $amount * sin( $rad );

    my %move = (
        red   => [  1,  1 ],
        green => [  0,  0 ],
        blue  => [ -1, -1 ],
    );

    # Whichever channel is anchored stays put; the other two split around it.
    if ( $p->{ anchor } eq 'red' )
    {
        %move = ( red => [ 0, 0 ], green => [ 1, 1 ], blue => [ -1, -1 ] );
    }
    elsif ( $p->{ anchor } eq 'blue' )
    {
        %move = ( red => [ 1, 1 ], green => [ -1, -1 ], blue => [ 0, 0 ] );
    }

    # Every channel is sampled from the untouched original, since the image is
    # being rebuilt one channel at a time underneath us.
    my $orig = $ctx->image->Clone;

    for my $chan ( qw(red green blue) )
    {
        my ( $sx, $sy ) = @{ $move{ $chan } };
        next unless $sx || $sy;

        my $plane = $orig->Clone;
        $plane->Roll(
            x => int( $dx * $sx + 0.5 ),
            y => int( $dy * $sy + 0.5 ),
        );

        # CopyRed/CopyGreen/CopyBlue take one channel from the source and
        # leave the rest of the destination alone. This build's PerlMagick has
        # no Combine method, so channel-wise compositing is how planes get
        # reassembled.
        GlitchVape::Magick::check(
            $ctx->image->Composite(
                image   => $plane->[ 0 ],
                compose => 'Copy' . ucfirst $chan,
            ),
            "chroma_shift: could not composite the $chan channel"
        );
    }
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'chroma_bleed',
    title   => 'Chroma Bleed',
    stage   => 'channels',
    summary => 'VHS colour smear: blur chroma, keep luma sharp',
    doc     => <<'DOC',
The most physically accurate VHS artefact. Composite video allocates far less
bandwidth to colour than to brightness, so colour detail smears horizontally
while edges stay crisp. Reproduced by converting to YCbCr, blurring only Cb and
Cr along one axis, and converting back.
DOC
    params => {
        amount => {
            default => 8,
            type    => 'num',
            min     => 0,
            max     => 100,
            doc     => 'Horizontal chroma blur radius in pixels',
        },
        vertical => {
            default => 0,
            type    => 'num',
            min     => 0,
            max     => 100,
            doc     => 'Vertical chroma blur; real tape has almost none',
        },
        saturation => {
            default => 1.0,
            type    => 'num',
            min     => 0,
            max     => 4,
            doc     => 'Chroma gain applied after the bleed',
        },
    },
    apply => \&_chroma_bleed,
);

sub _chroma_bleed
{
    my ( $ctx, $p ) = @_;

    return
           if $p->{ amount } <= 0
        && $p->{ vertical } <= 0
        && $p->{ saturation } == 1;

    if ( $p->{ amount } > 0 || $p->{ vertical } > 0 )
    {

        # PerlMagick's Set(colorspace) only relabels the image, it does not
        # transform the pixels, so the conversion has to go through the CLI --
        # where the whole separate/blur/recombine cycle fits in one call
        # anyway.
        my @chroma;
        push @chroma, '-motion-blur', "0x$p->{amount}+90" if $p->{ amount } > 0;
        push @chroma, '-blur', "0x$p->{vertical}" if $p->{ vertical } > 0;

        $ctx->magick(
            '-colorspace', 'YCbCr',
            '-separate',
            '(',       '-clone', '0', ')',             # Y, untouched
            '(',       '-clone', '1', @chroma, ')',    # Cb
            '(',       '-clone', '2', @chroma, ')',    # Cr
            '-delete', '0-2',
            '-combine',
            '-set',        'colorspace', 'YCbCr',
            '-colorspace', 'sRGB',
        );
    }

    $ctx->image->Modulate( saturation => $p->{ saturation } * 100 )
        if $p->{ saturation } != 1;

    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'palette',
    title   => 'Fixed Palette',
    stage   => 'colour',
    summary => 'Force the image into a named colour palette',
    doc     => <<'DOC',
Remaps every pixel to its nearest entry in a fixed palette. At strength 1 this
is a hard remap; below that the result is blended back over the original, which
keeps detail while pulling the overall cast towards the palette.
DOC
    params => {
        name => {
            default => 'vapor',
            type    => 'str',
            doc     => 'Palette name, or inline "#FF71CE,#01CDFE,..."',
        },
        strength => {
            default => 1.0,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Blend back over the original (1 = full remap)',
        },
        dither => {
            default => 'floydsteinberg',
            type    => 'enum',
            values  => [ qw(none floydsteinberg riemersma) ],
            doc     => 'Error diffusion when remapping',
        },
    },
    apply => \&_palette,
);

sub _palette
{
    my ( $ctx, $p ) = @_;
    return if $p->{ strength } <= 0;

    my $remap = GlitchVape::Palette::remap_file( $p->{ name }, $ctx->tmpdir );

    # Below full strength the effect is blended back over the untouched
    # image, so a copy has to be kept before anything modifies it.
    my $orig = undef;
    if ( $p->{ strength } < 1 )
    {
        $orig = $ctx->clone;
    }

    my @args = ( '-dither', $p->{ dither }, '-remap', $remap );
    $ctx->magick( @args );

    _blend_with( $ctx, $orig, $p->{ strength } ) if $orig;
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'duotone',
    title   => 'Duotone',
    stage   => 'colour',
    summary => 'Map luminance onto a two-colour gradient',
    doc     => <<'DOC',
Collapses the image to greyscale, then maps dark-to-light onto a colour ramp.
The single most recognisable "aesthetic" grade: pink shadows, cyan highlights.
DOC
    params => {
        name => {
            default => 'pinkcyan',
            type    => 'str',
            doc     => 'Duotone or palette name, or "#RRGGBB,#RRGGBB"',
        },
        strength => {
            default => 0.85,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Blend back over the original',
        },
        contrast => {
            default => 0,
            type    => 'num',
            min     => -100,
            max     =>  100,
            doc     => 'Contrast applied to the luminance before mapping',
        },
    },
    apply => \&_duotone,
);

sub _duotone
{
    my ( $ctx, $p ) = @_;
    return if $p->{ strength } <= 0;

    my $stops = GlitchVape::Palette::duotone( $p->{ name } );
    my $clut  = GlitchVape::Palette::gradient_file( $stops, $ctx->tmpdir );

    # Below full strength the effect is blended back over the untouched
    # image, so a copy has to be kept before anything modifies it.
    my $orig = undef;
    if ( $p->{ strength } < 1 )
    {
        $orig = $ctx->clone;
    }

    my @args = qw(-colorspace Gray);
    push @args, ( '-brightness-contrast', "0x$p->{contrast}" )
        if $p->{ contrast };
    push @args, ( $clut, '-clut' );

    $ctx->magick( @args );
    _blend_with( $ctx, $orig, $p->{ strength } ) if $orig;
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'gradient_map',
    title   => 'Gradient Map',
    stage   => 'colour',
    summary => 'Map luminance onto a full multi-stop palette ramp',
    doc     => <<'DOC',
Like duotone but using every colour in a palette as a stop, giving a richer
graded look: deep purple shadows through magenta midtones to mint highlights.
DOC
    params => {
        name => {
            default => 'vapor',
            type    => 'str',
            doc     => 'Palette name or inline colour list',
        },
        strength => {
            default => 0.7,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Blend back over the original',
        },
    },
    apply => \&_gradient_map,
);

sub _gradient_map
{
    my ( $ctx, $p ) = @_;
    return if $p->{ strength } <= 0;

    my $clut = GlitchVape::Palette::gradient_file( $p->{ name }, $ctx->tmpdir );

    # Below full strength the effect is blended back over the untouched
    # image, so a copy has to be kept before anything modifies it.
    my $orig = undef;
    if ( $p->{ strength } < 1 )
    {
        $orig = $ctx->clone;
    }

    $ctx->magick( '-colorspace', 'Gray', $clut, '-clut' );
    _blend_with( $ctx, $orig, $p->{ strength } ) if $orig;
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'grade',
    title   => 'Colour Grade',
    stage   => 'colour',
    summary => 'Overall hue/saturation/brightness and colour cast',
    doc     => <<'DOC',
General colour grading. The default lift pushes shadows towards blue-magenta,
which is what gives cheap tape its characteristic cold, slightly bruised look.
DOC
    params => {
        hue => {
            default => 100,
            type    => 'num',
            min     => 0,
            max     => 200,
            doc     => 'Hue rotation, 100 = unchanged',
        },
        saturation => {
            default => 130,
            type    => 'num',
            min     => 0,
            max     => 400,
            doc     => 'Saturation percentage, 100 = unchanged',
        },
        brightness => {
            default => 100,
            type    => 'num',
            min     => 0,
            max     => 300,
            doc     => 'Brightness percentage, 100 = unchanged',
        },
        contrast => {
            default => 0,
            type    => 'num',
            min     => -100,
            max     =>  100,
            doc     => 'Contrast adjustment',
        },
        tint => {
            default => '',
            type    => 'str',
            doc     => 'Colour to wash over the image, e.g. "#FF71CE"',
        },
        tint_strength => {
            default => 0.15,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How strongly the tint is applied',
        },
        gamma => {
            default => 1.0,
            type    => 'num',
            min     => 0.1,
            max     => 4,
            doc     => 'Gamma correction',
        },
    },
    apply => \&_grade,
);

sub _grade
{
    my ( $ctx, $p ) = @_;
    my $img = $ctx->image;

    $img->Modulate(
        brightness => $p->{ brightness },
        saturation => $p->{ saturation },
        hue        => $p->{ hue },
        )
        if $p->{ brightness } != 100
        || $p->{ saturation } != 100
        || $p->{ hue } != 100;

    $img->Gamma( gamma => $p->{ gamma } ) if $p->{ gamma } != 1;

    $img->BrightnessContrast( brightness => 0, contrast => $p->{ contrast } )
        if $p->{ contrast };

    if ( length $p->{ tint } && $p->{ tint_strength } > 0 )
    {
        my $pct = int( $p->{ tint_strength } * 100 + 0.5 );
        $img->Colorize( fill => $p->{ tint }, blend => "$pct/$pct/$pct" );
    }
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'posterize',
    title   => 'Posterize',
    stage   => 'colour',
    summary => 'Reduce to N levels per channel',
    doc     => <<'DOC',
Hard colour banding. Low level counts with dithering give the look of an
8-bit-era framebuffer; without dithering you get flat poster-style blocks.
DOC
    params => {
        levels => {
            default => 6,
            type    => 'int',
            min     => 2,
            max     => 64,
            doc     => 'Levels per channel',
        },
        dither => {
            default => 'none',
            type    => 'enum',
            values  => [ qw(none floydsteinberg riemersma) ],
            doc     => 'Error diffusion',
        },
    },
    apply => sub {
        my ( $ctx, $p ) = @_;
        $ctx->magick( '-dither', $p->{ dither }, '-posterize', $p->{ levels } );
    },
);

# ---------------------------------------------------------------------------

$R->register(
    name    => 'deepfry',
    title   => 'Deep Fry',
    stage   => 'damage',
    summary => 'Generational JPEG loss ("deep fried")',
    doc     => <<'DOC',
Repeatedly re-encodes the image as a very low quality JPEG. Each pass compounds
the previous pass's blocking, so artefacts build on artefacts the way they do
in an image that has been screenshotted and reposted a dozen times.
DOC
    params => {
        quality => {
            default => 12,
            type    => 'int',
            min     => 1,
            max     => 100,
            doc     => 'JPEG quality per pass',
        },
        passes => {
            default => 3,
            type    => 'int',
            min     => 1,
            max     => 30,
            doc     => 'Number of encode/decode cycles',
        },
        scale => {
            default => 1.0,
            type    => 'num',
            min     => 0.1,
            max     => 1,
            doc     => 'Downscale between passes to amplify blocking',
        },
        saturate => {
            default => 1.0,
            type    => 'num',
            min     => 0,
            max     => 4,
            doc     => 'Saturation boost per pass; >1 is the classic look',
        },
    },
    apply => \&_deepfry,
);

sub _deepfry
{
    my ( $ctx, $p ) = @_;
    require Image::Magick;

    my ( $w, $h ) = $ctx->dims;

    for my $pass ( 1 .. $p->{ passes } )
    {
        my $img = $ctx->image;
        $img->Set( quality => $p->{ quality } );

        if ( $p->{ scale } < 1 )
        {
            my $sw = int( $w * $p->{ scale } ) || 1;
            my $sh = int( $h * $p->{ scale } ) || 1;
            $img->Resize( geometry => "${sw}x${sh}!" );
        }

        my $tmp = $ctx->tmpfile( '.jpg' );
        GlitchVape::Magick::check( $img->Write( $tmp ),
            "deepfry: JPEG write failed" );

        my $back = Image::Magick->new;
        $back->Read( $tmp );
        $back->Resize( geometry => "${w}x${h}!" ) if $p->{ scale } < 1;
        $back->Modulate( saturation => $p->{ saturate } * 100 )
            if $p->{ saturate } != 1;

        _replace( $ctx, $back );
        unlink $tmp;
    }
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'quantize',
    title   => 'Colour Quantize',
    stage   => 'colour',
    summary => 'Reduce the total colour count (lo-fi banding)',
    doc     => <<'DOC',
Cuts the image to a limited adaptive palette. Uses pngquant when available --
its dithering is noticeably better than ImageMagick's at low colour counts --
and falls back to ImageMagick otherwise.
DOC
    params => {
        colors => {
            default => 32,
            type    => 'int',
            min     => 2,
            max     => 256,
            doc     => 'Total colours in the output',
        },
        dither => {
            default => 1,
            type    => 'bool',
            doc     => 'Apply error diffusion',
        },
    },
    apply => \&_quantize,
);

sub _quantize
{
    my ( $ctx, $p ) = @_;
    require GlitchVape::Tools;
    require Image::Magick;

    my $pq = GlitchVape::Tools::find( 'pngquant' );

    # Without pngquant, fall back to ImageMagick's own quantiser. It bands
    # more visibly at low colour counts, which is a fair trade for not
    # requiring the tool.
    if ( !$pq )
    {
        my $dither_mode = 'None';
        if ( $p->{ dither } )
        {
            $dither_mode = 'FloydSteinberg';
        }

        $ctx->magick( '-dither', $dither_mode, '-colors', $p->{ colors }, );
        return;
    }

    # pngquant dithers by default, so the flag is only needed to switch it off.
    my @dither_flag = ( '--nofs' );
    if ( $p->{ dither } )
    {
        @dither_flag = ();
    }

    my $in  = $ctx->tmpfile( '.png' );
    my $out = $ctx->tmpfile( '.png' );
    $ctx->image->Write( $in );

    my @argv = (
        $pq,          '--force',      '--speed',  '1',
        @dither_flag, $p->{ colors }, '--output', $out,
        '--',         $in,
    );

    if ( system( @argv ) == 0 && -s $out )
    {
        my $back = Image::Magick->new;
        $back->Read( $out );
        $back->Set( alpha => 'off' );
        _replace( $ctx, $back );
    }
    else
    {
        # pngquant refuses when it cannot beat the target; not an error.
        $ctx->log( 'quantize: pngquant declined, leaving image unchanged' );
    }
    return;
}

# ---------------------------------------------------------------------------
# Helpers shared across this module.

# Swap the context's image for a new one, preserving the object identity that
# the pipeline holds.
sub _replace
{
    my ( $ctx, $new ) = @_;
    $ctx->image( $new );
    return;
}

# Composite the pre-effect image back over the result at (1-$strength).
sub _blend_with
{
    my ( $ctx, $orig, $strength ) = @_;
    return if !$orig || $strength >= 1;

    my $pct = int( ( 1 - $strength ) * 100 + 0.5 );
    $orig->Set( alpha => 'on' );
    $ctx->image->Composite(
        image   => $orig->[ 0 ],
        compose => 'Blend',
        args    => "$pct",
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'rgb_shift',
    title   => 'Anaglyph Shift',
    stage   => 'channels',
    summary => 'Anaglyph misregistration: red against cyan',
    doc     => <<'DOC',
The red/cyan doubling of a 3D comic read without the glasses. Where
chroma_shift splits two channels symmetrically around a third, this drives red
one way and the cyan half -- green and blue together -- the other, which is a
different artefact and cannot be expressed as a symmetric split.

The two sides jitter independently, so the fringe is not mirror-symmetric: a
misregistered plate was never off by the same amount in both directions. In an
animation that jitter is redrawn every frame, since each frame draws from its
own random stream, which gives the plate-flutter of a print run rather than one
frozen offset. Raise `pulse` to add a smooth cycle over the loop on top.

`edge` decides what fills the strip a moved channel vacates. `smear` repeats
the border pixel, which is what the analogue equivalent does; `wrap` brings it
round from the far side, which is cheaper-looking but never leaves a flat band.
DOC
    params => {
        amount => {
            default => 18,
            type    => 'num',
            min     => 0,
            max     => 300,
            doc     => 'Nominal separation in pixels between red and cyan',
        },
        mode => {
            default => 'red_cyan',
            type    => 'enum',
            values  => [ qw(red_cyan red_blue random) ],
            doc     => 'red_cyan moves green with blue; red_blue anchors '
                . 'green; random picks per frame',
        },
        jitter => {
            default => 0.4,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Independent variation of each side, as a fraction of '
                . 'the nominal amount',
        },
        angle => {
            default => 0,
            type    => 'num',
            min     => -360,
            max     =>  360,
            doc     => 'Direction of separation in degrees (0 = horizontal)',
        },
        pulse => {
            default => 0,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Smooth breathing of the separation across an '
                . 'animation loop; 0 leaves only the per-frame jitter',
        },
        edge => {
            default => 'smear',
            type    => 'enum',
            values  => [ qw(smear wrap) ],
            doc     => 'What fills the strip a displaced channel leaves behind',
        },
    },
    apply => \&_rgb_shift,
);

sub _rgb_shift
{
    my ( $ctx, $p ) = @_;

    my $rng    = $ctx->rng_for( 'rgb_shift' );
    my $amount = $p->{ amount };

    if ( $p->{ pulse } && $ctx->frames > 1 )
    {
        $amount *= 1 + $p->{ pulse } * sin( 2 * $PI * $ctx->phase );
    }

    # Each side gets its own draw. One shared draw would only rescale a
    # symmetric pair, which is the look this effect exists to avoid.
    my $red  = $amount * _jittered( $rng, $p->{ jitter } );
    my $cyan = $amount * _jittered( $rng, $p->{ jitter } );

    my $mode = $p->{ mode };
    if ( $mode eq 'random' )
    {
        $mode = 'red_blue';
        if ( $rng->chance( 0.5 ) )
        {
            $mode = 'red_cyan';
        }
    }

    # Red goes one way and the cyan half the other. In red_blue only blue
    # makes the trip, leaving green -- and so most of the luminance -- where
    # it was, which reads as a softer fringe on the same image.
    my $green = $cyan;
    if ( $mode eq 'red_blue' )
    {
        $green = 0;
    }

    my $rad = $p->{ angle } * $PI / 180;
    my $cos = cos( $rad );
    my $sin = sin( $rad );

    my @offset = (
        [ _round( -$red * $cos ),  _round( -$red * $sin ) ],
        [ _round( $green * $cos ), _round( $green * $sin ) ],
        [ _round( $cyan * $cos ),  _round( $cyan * $sin ) ],
    );

    # Nothing to do rather than a full buffer round trip for a no-op.
    my $moved = 0;
    for my $pair ( @offset )
    {
        $moved = 1 if $pair->[ 0 ] || $pair->[ 1 ];
    }
    return unless $moved;

    my $wrap = 0;
    if ( $p->{ edge } eq 'wrap' )
    {
        $wrap = 1;
    }

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            $px->{ data } =
                _combine( $px->data, $px->width, $px->height, \@offset, $wrap );
            return;
        }
    );

    return;
}

# int() truncates towards zero, so the usual int($v + 0.5) rounds a negative
# the wrong way: -1.5 becomes -1, and the red plane ends up a pixel short of
# where the cyan one is long. Every offset here is signed, so rounding has to
# be symmetric about zero.
sub _round
{
    my ( $v ) = @_;

    return int( $v + 0.5 ) if $v >= 0;
    return -int( -$v + 0.5 );
}

# A multiplier around 1 -- 0.6 to 1.4 at the default jitter, which is the
# range the shell script this came from used.
sub _jittered
{
    my ( $rng, $jitter ) = @_;

    return 1 unless $jitter;
    return 1 + $rng->between( -$jitter, $jitter );
}

# Displace each channel by its own offset and reassemble.
#
# The reassembly is three whole-buffer bitwise ANDs and two ORs rather than a
# loop over pixels. Perl's bitwise operators on strings work byte by byte in C,
# so masking one channel out of an eight-megabyte buffer costs a memcpy rather
# than eight million iterations of Perl -- which is the difference between this
# being usable on a twenty-four frame animation and not.
sub _combine
{
    my ( $data, $w, $h, $offset, $wrap ) = @_;

    # One byte per channel, repeated over the whole buffer. Written as a
    # scalar repetition of a plain scalar: parenthesising the left side would
    # make `x` repeat a *list* here, which silently yields $h short masks
    # instead of one long one.
    my @pattern = ( "\xFF\x00\x00", "\x00\xFF\x00", "\x00\x00\xFF" );
    my $pixels  = $w * $h;

    my $out;
    for my $c ( 0 .. 2 )
    {
        my ( $dx, $dy ) = @{ $offset->[ $c ] };

        my $plane = $data;
        if ( $dx || $dy )
        {
            $plane = _displace( $data, $w, $h, $dx, $dy, $wrap );
        }

        my $mask = $pattern[ $c ] x $pixels;
        my $part = $plane & $mask;

        if ( defined $out )
        {
            $out |= $part;
        }
        else
        {
            $out = $part;
        }
    }

    return $out;
}

# Move a whole buffer by ($dx, $dy). Vertical first, as whole rows, then
# horizontal one row at a time through Pixels::shift_row, which already knows
# how to smear a border pixel into the strip it vacates.
sub _displace
{
    my ( $data, $w, $h, $dx, $dy, $wrap ) = @_;

    my $stride = $w * 3;

    if ( $dy )
    {
        my @row = map { substr $data, $_ * $stride, $stride } 0 .. $h - 1;
        my @out;

        for my $y ( 0 .. $h - 1 )
        {
            my $from = $y - $dy;

            if ( $wrap )
            {
                $from %= $h;
            }
            elsif ( $from < 0 )
            {
                $from = 0;
            }
            elsif ( $from > $h - 1 )
            {
                $from = $h - 1;
            }

            push @out, $row[ $from ];
        }

        $data = join q{}, @out;
    }

    return $data unless $dx;

    my $out = q{};
    for my $y ( 0 .. $h - 1 )
    {
        $out .= GlitchVape::Pixels::shift_row(
            substr( $data, $y * $stride, $stride ),
            $w, $dx, $wrap );
    }

    return $out;
}

1;
