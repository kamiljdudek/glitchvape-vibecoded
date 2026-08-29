#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape        ();
use GlitchVape::Tools ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

my $dir = File::Temp->newdir( 'gv_test_XXXXXX', TMPDIR => 1 );

# A synthetic source with real structure: flat colour would hide effects that
# depend on edges or on a luminance range, such as pixelsort and bloom. It also
# has to be big enough that a JPEG of it exceeds databend's header guard --
# below a couple of kilobytes that effect correctly refuses to run.
my $src = "$dir/src.png";
{
    my $img = Image::Magick->new( size => '480x360' );
    $img->Read( 'gradient:#101040-#FFE0A0' );
    $img->Draw(
        primitive => 'rectangle',
        points    => '90,75 330,240',
        fill      => '#FF2090',
    );
    $img->Draw(
        primitive => 'circle',
        points    => '360,285 420,285',
        fill      => '#20FFC0',
    );
    my $err = $img->Write( $src );
    BAIL_OUT( "could not build the test source image: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;
}

ok -s $src, 'built a test source image';

# The same split GlitchVape::GUI::Params::split makes, done here rather than
# imported: that module needs Gtk3, and this file has to run on a build machine
# with no display.
sub ordinary_params
{
    my ( $params ) = @_;

    my @ordinary = grep { !$params->{ $_ }{ animation } } sort keys %$params;

    return ( \@ordinary );
}

sub dims_of
{
    my ( $path ) = @_;
    my $i = Image::Magick->new;
    $i->Read( $path );
    return $i->Get( 'width', 'height' );
}

# Normalised RMSE between two files, computed directly from the pixel buffers.
# Shelling out to `magick compare` would mean quoting temp-directory paths
# through a shell for no benefit.
sub differs
{
    my ( $a, $b ) = @_;
    require GlitchVape::Pixels;

    my @buf;
    for my $path ( $a, $b )
    {
        my $img = Image::Magick->new;
        $img->Read( $path );
        push @buf, GlitchVape::Pixels->from_image( $img );
    }

    return 1 if $buf[ 0 ]->width != $buf[ 1 ]->width;
    return 1 if $buf[ 0 ]->height != $buf[ 1 ]->height;

    my @x = unpack 'C*', $buf[ 0 ]->data;
    my @y = unpack 'C*', $buf[ 1 ]->data;

    my $sum = 0;
    $sum += ( $x[ $_ ] - $y[ $_ ] )**2 for 0 .. $#x;

    return sqrt( $sum / @x ) / 255;
}

# Every effect must actually change the image. This is the check that would
# have caught PerlMagick's SetPixels quietly doing nothing.
{
    my $all = GlitchVape::Registry->all;

    for my $name ( GlitchVape::Registry->names )
    {
        my $out = "$dir/eff_$name.png";

        my $ok = eval {
            GlitchVape::render(
                input   => $src,
                output  => $out,
                enable  => [ $name ],
                seed    => 4242,
                max_dim => 0,
            );
            1;
        };

        unless ( $ok )
        {
            my $err = $@;

            # Overlay effects need fonts, which may not be installed.
            if ( $err =~ /no font found/ )
            {
                pass "effect '$name' skipped: no suitable font installed";
                next;
            }
            fail "effect '$name' renders";
            diag $err;
            next;
        }

        ok -s $out, "effect '$name' produced output";

        # An effect every one of whose parameters is an animation parameter
        # cannot touch a still, and must not: a ripple needs time to happen
        # in, and one frame has none. Worked out from the registry rather
        # than from a list of names here, so the next one like it is handled
        # by declaring it rather than by remembering this file.
        my $params = GlitchVape::Registry->get( $name )->{ params };
        my ( $ordinary ) = ordinary_params( $params );

        if ( keys %$params && !@$ordinary )
        {
            cmp_ok differs( $src, $out ), '<', 0.0005,
                "effect '$name' is animation-only and leaves a still alone";
            next;
        }

        cmp_ok differs( $src, $out ), '>', 0.0005,
            "effect '$name' actually changes the image";
    }
}

# Same seed, same result. Without this, --seed is decorative.
{
    my $a = "$dir/seed_a.png";
    my $b = "$dir/seed_b.png";

    GlitchVape::render(
        input   => $src,
        output  => $a,
        preset  => 'vhs-decay',
        seed    => 99,
        max_dim => 0,
    );
    GlitchVape::render(
        input   => $src,
        output  => $b,
        preset  => 'vhs-decay',
        seed    => 99,
        max_dim => 0,
    );

    is differs( $a, $b ), 0, 'the same seed reproduces the render exactly';

    my $c = "$dir/seed_c.png";
    GlitchVape::render(
        input   => $src,
        output  => $c,
        preset  => 'vhs-decay',
        seed    => 100,
        max_dim => 0,
    );
    cmp_ok differs( $a, $c ), '>', 0,
        'a different seed gives a different render';
}

# Adding an effect must not disturb the randomness of the others, or tuning a
# preset one knob at a time never converges.
{
    my $base = "$dir/iso_base.png";
    my $more = "$dir/iso_more.png";

    GlitchVape::render(
        input   => $src,
        output  => $base,
        seed    => 5,
        max_dim => 0,
        enable  => [ 'tracking' ],
    );
    GlitchVape::render(
        input   => $src,
        output  => $more,
        seed    => 5,
        max_dim => 0,
        enable  => [ 'tracking', 'text' ],
        disable => [ 'text' ],
    );

    is differs( $base, $more ), 0,
        'a disabled effect leaves the rest of the render untouched';
}

{
    my $out = "$dir/scaled.png";
    GlitchVape::render(
        input   => $src,
        output  => $out,
        preset  => 'mallsoft',
        max_dim => 64,
    );
    my ( $w, $h ) = dims_of( $out );
    cmp_ok $w, '<=', 64, 'max_dim constrains width';
    cmp_ok $h, '<=', 64, 'max_dim constrains height';
}

{
    for my $preset ( qw(vhs-decay mallsoft hotline gameboy photocopy) )
    {
        my $out = "$dir/preset_$preset.png";
        my $ok  = eval {
            GlitchVape::render(
                input   => $src,
                output  => $out,
                preset  => $preset,
                seed    => 1,
                max_dim => 0,
            );
            1;
        };
        if ( !$ok && $@ =~ /no font found/ )
        {
            pass "preset '$preset' skipped: no suitable font installed";
            next;
        }
        ok( ( $ok && -s $out ), "preset '$preset' renders" ) or diag $@;
    }
}

{
    my $res = GlitchVape::render(
        input   => $src,
        output  => "$dir/dry.png",
        preset  => 'vhs-decay',
        dry_run => 1,
    );
    ok $res->{ dry_run },                   'dry run reports itself';
    ok !-e "$dir/dry.png",                  'dry run writes nothing';
    ok length $res->{ pipeline }->describe, 'dry run describes the pipeline';
}

{
    my $err = do
    {
        local $@;
        eval {
            GlitchVape::render(
                input  => "$dir/missing.png",
                output => "$dir/x.png"
            );
        };
        $@;
    };
    like $err, qr/no such file/, 'a missing input is reported clearly';
}

SKIP:
{
    skip 'ffmpeg is not installed', 3
        unless GlitchVape::Tools::have( 'ffmpeg' );

    my $out = "$dir/loop.mp4";
    my $res = GlitchVape::render(
        input   => $src,
        output  => $out,
        preset  => 'vhs-decay',
        seed    => 2,
        max_dim => 0,
        animate => { frames => 4, fps => 8 },
    );

    ok -s $out, 'animation renders to MP4';
    is $res->{ frames }, 4, 'the requested frame count is reported';

    my $probe = GlitchVape::Tools::capture( 'ffprobe', '-v', 'error',
        '-show_entries', 'stream=nb_frames', '-of', 'csv=p=0', $out, );
    like $probe, qr/^4/, 'the encoded file holds every frame';
}

done_testing;
