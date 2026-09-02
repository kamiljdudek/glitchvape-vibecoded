#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape           ();
use GlitchVape::Context  ();
use GlitchVape::Pipeline ();
use GlitchVape::Registry ();
use GlitchVape::Raster   ();
use GlitchVape::Tools    ();

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

# Every colour in a band down the left-hand margin of a letterboxed picture,
# which is border and bar all the way. A band rather than a column: 'dots'
# puts ink in two of its sixty-four cells, so a single column can miss the
# pattern entirely and report a flat colour.
sub margin_colours
{
    my ( $img ) = @_;

    my $h = $img->Get( 'height' );
    my $w = 16;

    my @px = $img->GetPixels(
        map    => 'RGB',
        x      => 0,
        y      => 0,
        width  => $w,
        height => $h
    );

    my %seen;
    for my $n ( 0 .. $w * $h - 1 )
    {
        $seen{
            join ',', map { int( $_ / 257 + 0.5 ) } @px[ $n * 3 .. $n * 3 + 2 ]
        }++;
    }

    return \%seen;
}

# One colour resolved to its three bytes, as a string a test can read.
sub colour_of
{
    my ( $spec ) = @_;

    return join ',', unpack 'C3',
        GlitchVape::Raster::colour_bytes( $spec, 9, 9, 9 );
}

# The two maxima a block's extent and shape work out to.
sub block_shape
{
    my ( $extent, $shape ) = @_;

    ## no critic (Subroutines::ProtectPrivateSubs)
    return [
        GlitchVape::Effect::Glitch::_block_shape(
            { extent => $extent, shape => $shape }
        )
    ];
    ## use critic
}

# That one pattern's ground is drawn in exactly the two colours it was given.
sub ground_is_two_colours
{
    my ( $render, $name ) = @_;

    my $seen = margin_colours( $render->( pattern => $name ) );

    my @unexpected =
        grep { $_ ne '42,27,78' && $_ ne '255,113,206' } sort keys %$seen;

    is_deeply \@unexpected, [], "the $name ground is the two it was given"
        or diag "and also: @unexpected";

    is scalar keys %$seen, 2,
        "with both of them down the whole margin, so $name is a pattern";

    return;
}

# ---------------------------------------------------------------------------
# The letterbox: a shape from a list, and a ground that can be a pattern

# 'native' is the name a closed list can offer for what an empty ratio has
# always meant, which is the setting three of the four presets that letterbox
# actually use: they want the border and nothing else.
{
    my $shaped = sub {
        my ( %how ) = @_;

        my $img = Image::Magick->new;
        $img->Read( $src );

        my $ctx = GlitchVape::Context->new( image => $img, seed => 3 );
        GlitchVape::Pipeline->new( effects => { letterbox => \%how } )
            ->run( $ctx );

        return $ctx->image;
    };

    is join( 'x', $shaped->( ratio => 'native' )->Get( 'width', 'height' ) ),
        join( 'x', $shaped->( ratio => q{} )->Get( 'width', 'height' ) ),
        'native leaves the shape alone, which is what an empty ratio did';

    is join( 'x',
        $shaped->( ratio => 'native', border => 0 )->Get( 'width', 'height' ) ),
        '480x360', 'and with no border either, the picture it was given';

    # The border is not nought by default, because 'native' with no border is
    # an effect that does nothing when it is switched on.
    isnt join( 'x', $shaped->()->Get( 'width', 'height' ) ), '480x360',
        'switched on with its defaults it draws something';

    isnt join( 'x',
        $shaped->( ratio => '1:1', border => 0 )->Get( 'width', 'height' ) ),
        '480x360', 'and a shape from the list crops the frame to it';

    my $spec = GlitchVape::Registry->get( 'letterbox' )->{ params }{ ratio };

    is $spec->{ choose }, 'ratio',
        'the ratio is a closed list rather than something to type';
    ok !$spec->{ suggest }, 'with nothing typeable left beside it';
}

# ---------------------------------------------------------------------------
# A patterned ground is two colours, and it does not restart at the border

# Built as one background the picture is laid on rather than as two extends,
# because a pattern has to line up across the join between the bars and the
# border -- extending twice would start it again at the second one.
{
    my $render = sub {
        my ( %how ) = @_;

        my $img = Image::Magick->new;
        $img->Read( $src );

        my $ctx = GlitchVape::Context->new( image => $img, seed => 3 );
        GlitchVape::Pipeline->new(
            effects => {
                letterbox => {
                    ratio         => '1:1',
                    border        => 0.05,
                    color         => '#2A1B4E',
                    ink           => '#FF71CE',
                    pattern_scale => 2,
                    %how,
                }
            }
        )->run( $ctx );

        return $ctx->image;
    };

    my $flat = margin_colours( $render->( pattern => 'solid' ) );

    is_deeply [ keys %$flat ], [ '42,27,78' ],
        'a solid ground is the colour it was given and nothing else';

    ground_is_two_colours( $render, $_ )
        for GlitchVape::Raster::desktop_names();
}

# ---------------------------------------------------------------------------
# A block's shape is one number and a word, not two numbers

# It was a maximum width and a maximum height, and they were always saying one
# thing between them: how big, and which way round. The default was eight by
# three and the only preset that set them was twelve by four -- both the short
# side at a third of the long one -- so the second number was never carrying
# information, only an opportunity to make the two disagree.
{
    my $spec = GlitchVape::Registry->get( 'blockshift' )->{ params };

    ok !$spec->{ width_blocks } && !$spec->{ height_blocks },
        'the two maxima are gone';

    ok $spec->{ extent }, 'and a block has an extent';
    is_deeply $spec->{ shape }{ values }, [ qw(wide square tall) ],
        'and a shape from three';

    # The two settings that existed, reproduced exactly -- which is why no
    # render moved when the parameters did.
    is_deeply block_shape( 8, 'wide' ), [ 8, 3 ], 'the old default, exactly';
    is_deeply block_shape( 12, 'wide' ), [ 12, 4 ],
        'and the old preset, exactly';

    is_deeply block_shape( 12, 'square' ), [ 12, 12 ], 'square is square';
    is_deeply block_shape( 12, 'tall' ), [ 4, 12 ], 'and tall is wide, turned';

    # Never nought, however small the extent: a block no macroblocks across
    # is not a block.
    is_deeply block_shape( 1, 'wide' ), [ 1, 1 ],
        'the smallest block is one cell';
}

# ---------------------------------------------------------------------------
# A colour is a colour whether it is spelled or numbered

# letterbox.color arrives as the word 'black' in three of the four presets
# that use it, so a pattern that only understood hex would draw them in
# whatever its fallback happened to be.
{
    is colour_of( '#FF71CE' ), '255,113,206', 'a hex triplet reads as itself';
    is colour_of( 'black' ),   '0,0,0',       'and so does a name';
    is colour_of( 'navy' ),    '0,0,128',     'including one worth naming';

    is colour_of( 'nonsense' ), '9,9,9',
        'a colour nobody can read falls back rather than stopping the render';
    is colour_of( q{} ), '9,9,9', 'and so does none at all';

    is GlitchVape::Raster::mixed( 'black', 'white', 0 ), '#000000',
        'mixing at nought is the first colour';
    is GlitchVape::Raster::mixed( 'black', 'white', 1 ), '#FFFFFF',
        'and at one the second';
    is GlitchVape::Raster::mixed( 'black', 'white', 0.5 ), '#808080',
        'with the halfway point between them';
}

# ---------------------------------------------------------------------------
# A duotone ramp is chosen, and 'custom' is what the two pickers are for

# The parameter used to be called 'name' and used to be typeable. A name that
# does not say what it names, on a list where a typo is a render that stops.
{
    my $mapped = sub {
        my ( %how ) = @_;

        my $img = Image::Magick->new;
        $img->Read( $src );

        my $ctx = GlitchVape::Context->new( image => $img, seed => 3 );
        GlitchVape::Pipeline->new( effects => { duotone => { %how } } )
            ->run( $ctx );

        return $ctx->image;
    };

    my $spec = GlitchVape::Registry->get( 'duotone' )->{ params };

    is $spec->{ ramp }{ choose }, 'duotone',
        'the ramp is a closed list rather than something to type';
    ok !$spec->{ ramp }{ suggest }, 'with nothing typeable left beside it';
    ok !exists $spec->{ name },     q{and it is no longer called 'name'};

    # The two pickers mean nothing until the ramp is custom, so they say so
    # and the window greys them: a colour that is ignored is worse than one
    # that is missing, because it looks as though it was taken.
    is_deeply $spec->{ $_ }{ needs }, { ramp => 'custom' },
        "$_ means nothing unless the ramp is custom"
        for qw( shadows highlights );

    my $named  = $mapped->( ramp => 'pinkcyan' );
    my $custom = $mapped->(
        ramp       => 'custom',
        shadows    => '#FF71CE',
        highlights => '#01CDFE'
    );

    is $named->Get( 'signature' ), $custom->Get( 'signature' ),
        'custom with pinkcyan\'s own two colours renders pinkcyan exactly';

    isnt $custom->Get( 'signature' ),
        $mapped->(
        ramp       => 'custom',
        shadows    => '#003300',
        highlights => '#CCFFCC'
        )->Get( 'signature' ),
        'and two other colours are two other colours';
}

done_testing;
