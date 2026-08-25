#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape          ();
use GlitchVape::Animate ();
use GlitchVape::IO      ();
use GlitchVape::Tools   ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

my $dir = File::Temp->newdir( 'gv_out_XXXXXX', TMPDIR => 1 );

# What Export writes, and how big it is. These are the two things the export
# settings dialog decides, and both of them are promises about a file on disk
# rather than about an intermediate -- so they are checked on the file.

sub source
{
    my ( $name, $geometry ) = @_;

    my $path = "$dir/$name.png";

    my $img = Image::Magick->new( size => $geometry );
    $img->Read( 'gradient:#101040-#FFE0A0' );

    # Something with an edge in it, so a quantiser has more than a smooth ramp
    # to find colours in.
    $img->Draw(
        primitive => 'rectangle',
        points    => '10,10 60,60',
        fill      => '#FF2090',
    );

    my $err = $img->Write( $path );
    BAIL_OUT( "could not build $path: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;

    return $path;
}

sub dims_of
{
    my ( $path ) = @_;

    my $img = Image::Magick->new;
    $img->Read( $path );

    return $img->Get( 'width', 'height' );
}

# ---------------------------------------------------------------------------
# The fit box turns with the picture

{
    my %case = (
        landscape => [ '1200x900', [ 640, 480 ] ],
        portrait  => [ '900x1200', [ 480, 640 ] ],
        wide      => [ '1600x900', [ 640, 360 ] ],

        # A 9:16 source is measured against the turned box, 480 by 640, so it
        # keeps its full height rather than being held to 480 of it.
        tall   => [ '900x1600',  [ 360, 640 ] ],
        square => [ '1000x1000', [ 480, 480 ] ],
    );

    for my $name ( sort keys %case )
    {
        my ( $geometry, $want ) = @{ $case{ $name } };

        my $img = GlitchVape::IO::load( source( $name, $geometry ),
            fit => [ 640, 480 ] );

        is_deeply [ $img->Get( 'width', 'height' ) ], $want,
            "a $geometry source fits 640x480 as $want->[0]x$want->[1]";
    }
}

# A box is a ceiling, never a floor: nothing here invents pixels.
{
    my $img = GlitchVape::IO::load( source( 'tiny', '320x240' ),
        fit => [ 640, 480 ] );

    is_deeply [ $img->Get( 'width', 'height' ) ], [ 320, 240 ],
        'a source already inside the box is left exactly as it was';
}

# max_dim and fit are independent, and giving both applies both.
{
    my $img = GlitchVape::IO::load(
        source( 'both', '2000x1500' ),
        max_dim => 1000,
        fit     => [ 640, 480 ],
    );

    is_deeply [ $img->Get( 'width', 'height' ) ], [ 640, 480 ],
        'max_dim and fit together leave the more restrictive of the two';
}

# ---------------------------------------------------------------------------
# save() is where the promise is actually kept

# The pipeline can hand back something larger than it was given -- letterbox
# and border both do -- so fitting the source is not enough on its own.
{
    my $img = Image::Magick->new( size => '700x520' );
    $img->Read( 'gradient:#000000-#FFFFFF' );

    my $path = "$dir/grown.png";
    GlitchVape::IO::save( $img, $path, fit => [ 640, 480 ] );

    is_deeply [ dims_of( $path ) ], [ 640, 475 ],
        'save fits the box too, so a picture that grew is still inside it';
}

# ---------------------------------------------------------------------------
# 256 colours means 256 colours

{
    my $path = "$dir/palette.bmp";

    my $img = Image::Magick->new;
    $img->Read( source( 'quant', '400x300' ) );

    GlitchVape::IO::save( $img, $path, colors => 256 );

    ok -s $path, 'a quantised bitmap was written';

    my $back = Image::Magick->new;
    $back->Read( $path );

    cmp_ok $back->Get( 'colors' ), '<=', 256,
        'and holds no more than 256 colours';

    # An 8-bit file rather than a 24-bit one that happens to use few colours:
    # the point of asking for 256 is the file, not the histogram.
    is $back->Get( 'depth' ), 8, 'written at 8 bits';
}

# A gradient without quantising has far more than 256 colours, which is what
# makes the check above mean something.
{
    my $img = Image::Magick->new;
    $img->Read( source( 'unquant', '400x300' ) );

    cmp_ok $img->Get( 'colors' ), '>', 256,
        'the unquantised source is well over 256 colours';
}

# ---------------------------------------------------------------------------
# Codecs

{
    is_deeply [ GlitchVape::Animate::codecs() ], [ qw(h264 vp9 av1) ],
        'three codecs are offered, in the order a chooser should show them';

    ok !GlitchVape::Animate::codec_available( 'no-such-codec' ),
        'an unknown codec is never available';

    local $@;
    eval { GlitchVape::Animate::require_codec( 'no-such-codec' ); 1 };
    like $@, qr/unknown codec/, 'and asking for it says so';

    eval { GlitchVape::Animate::require_codec( undef ); 1 };
    like $@, qr/unknown codec/, 'as does asking for nothing at all';
}

# The extension decides when nothing else does, and .webm is the one that
# needs an explicit codec to mean AV1.
{
    my $for = \&GlitchVape::Animate::codec_for;

    is $for->( 'x.mp4',  undef ), 'h264', '.mp4 is H.264';
    is $for->( 'x.webm', undef ), 'vp9',  '.webm is VP9 unless told otherwise';
    is $for->( 'x.webm', 'av1' ), 'av1',  'and AV1 when it is';
    is $for->( 'x.mov',  undef ), 'h264', '.mov is H.264';
    is $for->( 'x.wat',  undef ), 'h264', 'an unknown extension falls back';
    is $for->( 'x.webm', 'AV1' ), 'av1',  'the name is case-insensitive';
}

# ---------------------------------------------------------------------------
# End to end: the flags the interface emits produce the file it promised

SKIP:
{
    my $src = source( 'render', '1400x1050' );
    my $out = "$dir/retro.bmp";

    GlitchVape::render(
        input  => $src,
        output => $out,
        seed   => 1,
        fit    => [ 640, 480 ],
        colors => 256,
    );

    is_deeply [ dims_of( $out ) ], [ 640, 480 ],
        'a render with --fit lands inside the box';

    my $back = Image::Magick->new;
    $back->Read( $out );

    cmp_ok $back->Get( 'colors' ), '<=', 256,
        'and a render with --colors comes back quantised';
}

done_testing;
