package GlitchVape::Effect::Texture;

use strict;
use warnings;

use GlitchVape::Registry ();
use GlitchVape::Pixels   ();
use GlitchVape::Palette  ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Effect::Texture - resolution, grain and surface noise

=cut

my $R = 'GlitchVape::Registry';

# ---------------------------------------------------------------------------

$R->register(
    name    => 'downsample',
    title   => 'Pixelize',
    stage   => 'format',
    summary => 'Throw away resolution, then scale back up',
    doc     => <<'DOC',
Shrinks the image and enlarges it again with nearest-neighbour interpolation,
so the lost detail stays lost and the pixels stay square. Running this first
matters: every later effect then operates on the reduced detail, which is what
makes the result look genuinely low-resolution instead of looking like a sharp
photograph with a soft filter over it.

The classic tape resolution is 333x480 for NTSC VHS, which C<preset: vhs>
selects; C<factor> is the free-form alternative.
DOC
    params => {
        factor => {
            default => 2.0,
            type    => 'num',
            min     => 1,
            max     => 64,
            doc     => 'Divide resolution by this before scaling back',
        },
        preset => {
            default => 'none',
            type    => 'enum',
            values  => [ qw(none vhs vhs-pal video8 svhs ld cga) ],
            doc     => 'Use a real format resolution instead of factor',
        },
        filter => {
            default => 'point',
            type    => 'enum',
            values  => [ qw(point box triangle lanczos) ],
            doc     => 'Interpolation on the way back up',
        },
        aspect => {
            default => 0,
            type    => 'bool',
            doc     => 'Squash to 4:3 on the way down and stretch back',
        },
    },
    apply => \&_downsample,
);

# Horizontal luminance resolution of formats worth imitating. Vertical comes
# from the line standard, so only width is meaningful here.
my %FORMAT = (
    vhs       => [ 333, 480 ],
    'vhs-pal' => [ 335, 576 ],
    video8    => [ 300, 480 ],
    svhs      => [ 560, 480 ],
    ld        => [ 567, 480 ],
    cga       => [ 320, 200 ],
);

sub _downsample
{
    my ( $ctx, $p ) = @_;

    my ( $w, $h ) = $ctx->dims;
    my ( $sw, $sh );

    if ( $p->{ preset } ne 'none' )
    {
        my $f = $FORMAT{ $p->{ preset } }
            or die "downsample: unknown preset '$p->{preset}'\n";

        # Match the format's pixel count to this image's aspect rather than
        # forcing 4:3, so a portrait photo does not come back stretched.
        my $target = $f->[ 0 ] * $f->[ 1 ];
        my $ratio  = $w / $h;
        $sw = int( sqrt( $target * $ratio ) );
        $sh = int( $sw / $ratio );
    }
    else
    {
        return if $p->{ factor } <= 1;
        $sw = int( $w / $p->{ factor } );
        $sh = int( $h / $p->{ factor } );
    }

    $sw = 1 if $sw < 1;
    $sh = 1 if $sh < 1;

    $sw = int( $sw * 0.75 ) || 1 if $p->{ aspect };

    my $img = $ctx->image;
    $img->Set( filter => 'Point' );
    $img->Resize( geometry => "${sw}x${sh}!", filter => 'Point' );
    $img->Resize( geometry => "${w}x${h}!", filter => ucfirst $p->{ filter } );

    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'bitmap',
    title   => '8-Bit Bitmap Mode',
    stage   => 'format',
    summary => 'Low resolution, fixed palette and ordered dither, together',
    doc     => <<'DOC',
What a home computer's bitmap mode actually did: a small number of chunky
pixels, each one an index into a palette of fixed colours, with a threshold
matrix faking the shades the hardware did not have.

This exists as one effect rather than as C<downsample> plus C<palette> plus
C<dither> because the order those three run in is the whole difference between
an 8-bit picture and a photograph with a pattern over it. The palette lookup
and the dither have to happen while the image is still small, so that one dithered
cell is one chunky pixel. Run separately they cannot: C<downsample> is a
C<format> effect and C<dither> a C<grain> one, so the dither lands after the
image has been scaled back up and its checkerboard is drawn in pixels far
smaller than the blocks it is supposed to be shading. The blocks disappear.

So the chain here is down, dither, remap, up -- in one pass, at the small size,
which is a thing no ordering of the three separate effects can express.

The dither is applied as an offset rather than as a quantisation: the threshold
matrix nudges each pixel up or down before the palette lookup, so neighbouring
pixels round to different entries and the eye mixes them. Quantising first and
remapping afterwards -- which is what chaining the existing two effects does --
puts colours in that the palette then has to snap somewhere arbitrary, and the
result is speckle rather than shading.

Being a C<format> effect, this commits to its palette before any C<colour>
effect runs, so a grade or a tint after it will move pixels back off the
palette. That is the right way round -- the blocks have to exist before
anything shapes them, and a bloom or a scanline blending two neighbouring
entries is what a screen showing an 8-bit image did anyway -- but it does mean
the palette is a look here rather than a guarantee.
DOC
    params => {
        factor => {
            default => 6,
            type    => 'num',
            min     => 1,
            max     => 64,
            doc     => 'Divide resolution by this before the palette lookup',
        },
        palette => {
            default => 'laserwave',
            type    => 'str',
            suggest => 'palette',
            doc     => 'Palette name, or inline "#FF71CE,#01CDFE,..."',
        },
        matrix => {
            default => 'o4x4',
            type    => 'enum',
            values  => [ qw(none o2x2 o4x4 o8x8) ],
            doc     => 'Bayer matrix the dither offset comes from',
        },
        amount => {
            default => 0.25,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How far the matrix nudges a pixel before the lookup',
        },
        filter => {
            default => 'point',
            type    => 'enum',
            values  => [ qw(point box triangle) ],
            doc     => 'Interpolation on the way back up',
        },
    },
    apply => \&_bitmap,
);

sub _bitmap
{
    my ( $ctx, $p ) = @_;

    my ( $w, $h ) = $ctx->dims;

    my $sw = int( $w / $p->{ factor } ) || 1;
    my $sh = int( $h / $p->{ factor } ) || 1;

    my $remap =
        GlitchVape::Palette::remap_file( $p->{ palette }, $ctx->tmpdir );

    my @args = ( '-filter', 'Point', '-resize', "${sw}x${sh}!" );

    if ( $p->{ matrix } ne 'none' && $p->{ amount } > 0 )
    {
        my $tile = _bayer_file( $p->{ matrix }, $ctx->tmpdir );

        # result = amount*tile + image - amount/2, so the matrix is centred on
        # zero and shifts a pixel either way rather than only brightening it.
        push @args,
            '(', '-size', "${sw}x${sh}", "tile:$tile", ')',
            '-compose', 'Mathematics', '-define',
            sprintf(
            'compose:args=0,%.4f,1,%.4f',
            $p->{ amount },
            -$p->{ amount } / 2
            ),
            '-composite';
    }

    # -dither before -remap: it is a setting that the remap reads, not an
    # operation, so after it the remap has already diffused its own error and
    # torn the matrix pattern up.
    push @args,
        '-dither', 'None', '-remap', $remap,
        '-filter', ucfirst $p->{ filter }, '-resize', "${w}x${h}!";

    $ctx->magick( @args );

    return;
}

# The threshold matrix, written once per size into the render's temporary
# directory and reused. Built rather than shipped: it is defined by a
# recurrence, and four lines of it are easier to check than a binary asset.
#
#   M(2n) = [ 4*M(n)+0  4*M(n)+2 ]
#           [ 4*M(n)+3  4*M(n)+1 ]
sub _bayer_file
{
    my ( $name, $dir ) = @_;
    require File::Spec;
    require GlitchVape::Tools;

    my ( $n ) = $name =~ /(\d+)/;
    $n ||= 4;

    my $path = File::Spec->catfile( $dir, "bayer_$n.png" );
    return $path if -f $path;

    my $m    = [ [ 0 ] ];
    my $size = 1;
    while ( $size < $n )
    {
        my @next;
        for my $y ( 0 .. $size * 2 - 1 )
        {
            for my $x ( 0 .. $size * 2 - 1 )
            {
                my $base = 4 * $m->[ $y % $size ][ $x % $size ];
                my $quad = ( $y < $size ? 0 : 2 ) + ( $x < $size ? 0 : 1 );
                $next[ $y ][ $x ] =
                    $base + ( 0, 2, 3, 1 )[ $quad ];
            }
        }
        $m = \@next;
        $size *= 2;
    }

    # Raw single-channel bytes rather than ImageMagick's txt: enumeration.
    # That format needs a full (r,g,b) tuple per line and silently reads a
    # bare gray(n) as black, which produces a uniform tile -- a dither that
    # does nothing, and looks exactly like one that is switched off.
    my $cells = $n * $n;
    my $raw   = File::Spec->catfile( $dir, "bayer_$n.gray" );

    open my $fh, '>:raw', $raw
        or die "GlitchVape: cannot write $raw: $!\n";
    for my $y ( 0 .. $n - 1 )
    {
        for my $x ( 0 .. $n - 1 )
        {
            print { $fh } chr int( $m->[ $y ][ $x ] / $cells * 255 + 0.5 );
        }
    }
    close $fh;

    my @argv = GlitchVape::Tools::magick_argv( '-size', "${n}x$n", '-depth',
        '8', "gray:$raw", $path );
    system( @argv ) == 0
        or die "GlitchVape: could not build the $name threshold matrix\n";

    return $path;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'grain',
    title   => 'Film Grain',
    stage   => 'grain',
    summary => 'Film / sensor grain',
    doc     => <<'DOC',
Additive noise with a Gaussian distribution, which is what real grain and
sensor noise look like -- uniform noise reads as digital and wrong.

C<shadow_bias> concentrates the grain in dark areas. That is how both film and
cheap video sensors actually behave: the noise floor is constant, so it is only
visible where the signal is weak. Applying grain evenly is the single most
common thing that makes an imitation look fake.
DOC
    params => {
        amount => {
            default => 0.08,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Noise standard deviation as a fraction of full scale',
        },
        mono => {
            default => 0,
            type    => 'bool',
            doc     => 'One noise value per pixel instead of per channel',
        },
        shadow_bias => {
            default => 0.6,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Concentrate grain in dark areas',
        },
        size => {
            default => 1,
            type    => 'int',
            min     => 1,
            max     => 16,
            doc     => 'Grain cluster size in pixels',
        },
    },
    apply => \&_grain,
);

sub _grain
{
    my ( $ctx, $p ) = @_;
    return if $p->{ amount } <= 0;

    # Coarse grain is generated at reduced size and scaled up, which is both
    # faster and closer to how clumped film grain actually looks.
    return _coarse_grain( $ctx, $p ) if $p->{ size } > 1;

    my $rng  = $ctx->rng_for( 'grain' );
    my $sd   = $p->{ amount } * 255;
    my $bias = $p->{ shadow_bias };
    my $mono = $p->{ mono };

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;

            $px->each_row(
                sub {
                    my ( undef, $row ) = @_;
                    my @v = unpack 'C*', $row;

                    for ( my $i = 0 ; $i < @v ; $i += 3 )
                    {
                        my $scale = 1;
                        if ( $bias )
                        {
                            my $luma =
                                GlitchVape::Pixels::luma( @v[ $i .. $i + 2 ] )
                                / 255;
                            $scale = 1 - $bias * $luma;
                        }

                        if ( $mono )
                        {
                            my $n = $rng->gauss( 0, $sd ) * $scale;
                            $v[ $_ ] =
                                GlitchVape::Pixels::clamp( $v[ $_ ] + $n )
                                for $i .. $i + 2;
                        }
                        else
                        {
                            $v[ $_ ] = GlitchVape::Pixels::clamp(
                                $v[ $_ ] + $rng->gauss( 0, $sd ) * $scale )
                                for $i .. $i + 2;
                        }
                    }

                    return pack 'C*', @v;
                }
            );
        }
    );
    return;
}

sub _coarse_grain
{
    my ( $ctx, $p ) = @_;
    require Image::Magick;
    require GlitchVape::Raster;

    my ( $w, $h ) = $ctx->dims;
    my $rng = $ctx->rng_for( 'grain' );

    my $gw = int( $w / $p->{ size } ) || 1;
    my $gh = int( $h / $p->{ size } ) || 1;

    my $sd    = $p->{ amount } * 255;
    my $bytes = '';

    # Mid-grey is the identity for the HardLight composite below, so the noise
    # is generated around 128 rather than around zero.
    for ( 1 .. $gw * $gh )
    {
        if ( $p->{ mono } )
        {
            my $v = GlitchVape::Pixels::clamp( 128 + $rng->gauss( 0, $sd ) );
            $bytes .= pack 'C3', $v, $v, $v;
        }
        else
        {
            $bytes .= pack 'C3',
                map { GlitchVape::Pixels::clamp( 128 + $rng->gauss( 0, $sd ) ) }
                1 .. 3;
        }
    }

    my $noise = $ctx->tmpfile( '.ppm' );
    GlitchVape::Raster::write_ppm( $noise, $gw, $gh, $bytes );

    my $layer = Image::Magick->new;
    $layer->Read( $noise );
    $layer->Resize( geometry => "${w}x${h}!", filter => 'Point' );

    # Mid-grey is the identity for HardLight, so the noise adds and subtracts
    # around the existing pixel rather than lifting the whole image.
    $ctx->image->Composite(
        image   => $layer->[ 0 ],
        compose => 'HardLight',
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'static',
    title   => 'RF Static',
    stage   => 'signal',
    summary => 'Broadcast snow / RF static',
    doc     => <<'DOC',
Sparse bright and dark specks scattered over the picture, as distinct from
C<grain>'s continuous noise floor. This is the look of an aerial picking up a
weak signal.
DOC
    params => {
        density => {
            default => 0.02,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Fraction of pixels affected',
        },
        intensity => {
            default => 0.8,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How far affected pixels go towards black or white',
        },
        streak => {
            default => 3,
            type    => 'int',
            min     => 1,
            max     => 200,
            doc     => 'Maximum horizontal run length of a speck',
        },
    },
    apply => \&_static,
);

sub _static
{
    my ( $ctx, $p ) = @_;
    return if $p->{ density } <= 0;

    my $rng = $ctx->rng_for( 'static' );

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my ( $w, $h ) = ( $px->width, $px->height );

            # Each speck averages streak/2 pixels wide, so scale the draw count
            # to hit the requested density regardless of streak length.
            my $mean_len = ( $p->{ streak } + 1 ) / 2;
            my $draws    = int( $w * $h * $p->{ density } / $mean_len );
            return unless $draws > 0;

            # Group by row first: touching each affected row once beats
            # unpacking it again for every speck that lands on it.
            my %rows;
            for ( 1 .. $draws )
            {
                my $y = $rng->int_between( 0, $h - 1 );

                # Each speck goes fully white or fully black; snow is not
                # grey.
                my $target = 0;
                if ( $rng->chance( 0.5 ) )
                {
                    $target = 255;
                }

                push @{ $rows{ $y } },
                    [
                    $rng->int_between( 0, $w - 1 ),
                    $rng->int_between( 1, $p->{ streak } ),
                    $target,
                    ];
            }

            for my $y ( sort { $a <=> $b } keys %rows )
            {
                my @v = unpack 'C*', $px->row( $y );

                for my $spec ( @{ $rows{ $y } } )
                {
                    my ( $x, $len, $target ) = @$spec;
                    my $end = $x + $len - 1;
                    $end = $w - 1 if $end > $w - 1;

                    for my $i ( $x .. $end )
                    {
                        my $base = $i * 3;
                        $v[ $_ ] =
                            int( $v[ $_ ] +
                                ( $target - $v[ $_ ] ) * $p->{ intensity } )
                            for $base .. $base + 2;
                    }
                }

                $px->set_row( $y, pack 'C*', @v );
            }
        }
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'softness',
    title   => 'Lens Softness',
    stage   => 'optics',
    summary => 'Lens softness with an oversharpened edge',
    doc     => <<'DOC',
Blurs, then sharpens harder than the blur removed. The combination gives the
haloed, slightly mushy look of a picture that has been through a cheap lens and
then had edge enhancement applied to compensate -- which is exactly what
consumer camcorders did.
DOC
    params => {
        blur => {
            default => 0.8,
            type    => 'num',
            min     => 0,
            max     => 40,
            doc     => 'Blur sigma',
        },
        sharpen => {
            default => 1.6,
            type    => 'num',
            min     => 0,
            max     => 20,
            doc     => 'Unsharp mask amount applied afterwards',
        },
        radius => {
            default => 2,
            type    => 'num',
            min     => 0.1,
            max     => 40,
            doc     => 'Unsharp mask radius; larger gives wider halos',
        },
    },
    apply => sub {
        my ( $ctx, $p ) = @_;
        my $img = $ctx->image;

        $img->Blur( radius => 0, sigma => $p->{ blur } ) if $p->{ blur } > 0;

        $img->UnsharpMask(
            radius    => $p->{ radius },
            sigma     => $p->{ radius } / 2,
            amount    => $p->{ sharpen },
            threshold => 0,
        ) if $p->{ sharpen } > 0;

        return;
    },
);

# ---------------------------------------------------------------------------

$R->register(
    name    => 'dither',
    title   => 'Ordered Dither',
    stage   => 'grain',
    summary => 'Ordered dithering to a reduced bit depth',
    doc     => <<'DOC',
Quantises each channel to a small number of levels using a threshold matrix,
producing the regular cross-hatch of an early graphics adapter rather than the
random speckle of error diffusion.
DOC
    params => {
        map => {
            default => 'o8x8',
            type    => 'enum',
            values  => [ qw(threshold checks o2x2 o3x3 o4x4 o8x8) ],
            doc     => 'ImageMagick threshold map',
        },
        levels => {
            default => 3,
            type    => 'int',
            min     => 2,
            max     => 32,
            doc     => 'Levels per channel',
        },
    },
    apply => sub {
        my ( $ctx, $p ) = @_;
        $ctx->magick( '-ordered-dither', "$p->{map},$p->{levels}" );
    },
);

1;
