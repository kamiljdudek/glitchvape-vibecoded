#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

# No Gtk. Preferences, the watermark and the metadata rules are all things the
# window merely displays, and each is testable without a display.
use GlitchVape             ();
use GlitchVape::GUI::Prefs ();
use GlitchVape::Tools      ();
use GlitchVape::Watermark  ();

my $dir = File::Temp->newdir( 'gv_prefs_XXXXXX', TMPDIR => 1 );
local $ENV{ GLITCHVAPE_PROFILES } = "$dir";

my $P = 'GlitchVape::GUI::Prefs';

# ---------------------------------------------------------------------------
# The defaults are the list, and nothing is written to have them

{
    ok !-e $P->can( 'path' )->(), 'nothing on disk before anything is saved';

    my $prefs = $P->can( 'load' )->();

    ok $prefs->{ clear_cache_on_exit },
        'the cache is cleared on exit unless told otherwise';
    is $prefs->{ randomize_each_render }, 0,
        'and pressing Apply twice gives the same picture twice';
    is $prefs->{ watermark }, 'none',
        'and nothing signs the output until asked';
    is $prefs->{ metadata_keep }, 0,
        'and an export does not carry the camera and the coordinates';
}

# ---------------------------------------------------------------------------
# Saved, reloaded, and forgotten

{
    my $prefs = $P->can( 'load' )->();

    $prefs->{ watermark }     = 'bar';
    $prefs->{ metadata_keep } = 1;
    $prefs->{ fps }           = 30;

    ok $P->can( 'save' )->( $prefs ), 'preferences save';

    my $back = $P->can( 'load' )->();
    is $back->{ watermark },     'bar', 'and come back';
    is $back->{ metadata_keep }, 1,     'all of them';
    is $back->{ fps },           30,    'including the numbers';

    ok $P->can( 'forget' )->(), 'and can be forgotten';

    my $fresh = $P->can( 'load' )->();
    is $fresh->{ watermark }, 'none',
        'forgetting the file leaves the list in the module standing';
    is $fresh->{ fps }, 12, 'for every key at once';
}

# ---------------------------------------------------------------------------
# A file from another version, and a file from nowhere

# The saved file is merged onto the defaults rather than used as-is, which is
# what makes both of these harmless: a key that no longer exists is not
# carried, and one that did not exist when the file was written comes from the
# defaults instead of being missing.
{
    open my $fh, '>', $P->can( 'path' )->() or die $!;
    print { $fh } "watermark: logo\nabolished_setting: 3\n";
    close $fh;

    my $prefs = $P->can( 'load' )->();

    is $prefs->{ watermark }, 'logo', 'a key it still knows is honoured';
    ok !exists $prefs->{ abolished_setting },
        'one it does not is dropped rather than carried';
    is $prefs->{ fps }, 12, 'and one the file predates comes from the defaults';

    open my $bad, '>', $P->can( 'path' )->() or die $!;
    print { $bad } "this is: not\n  valid: [ yaml\n";
    close $bad;

    my $after = eval { $P->can( 'load' )->() };
    ok $after, 'a corrupt file still loads' or diag $@;
    is $after->{ watermark }, 'none', 'falling back to the defaults';

    $P->can( 'forget' )->();
}

# ---------------------------------------------------------------------------
# The watermark, and the one style that changes the picture's shape

SKIP:
{
    skip 'ImageMagick is not installed', 6
        unless GlitchVape::Tools::have( 'magick' )
        && eval { require Image::Magick; 1 };

    my $made = sub {
        my ( $w, $h ) = @_;
        $w ||= 320;
        $h ||= 240;

        my $img = Image::Magick->new( size => "${w}x$h" );
        $img->Read( 'xc:#203040' );
        return $img;
    };

    my $plain = GlitchVape::Watermark::apply( $made->(), 'none' );
    is join( 'x', $plain->Get( 'width' ), $plain->Get( 'height' ) ), '320x240',
        'none leaves the picture exactly as it was';

    my $logo = GlitchVape::Watermark::apply( $made->(), 'logo' );
    is join( 'x', $logo->Get( 'width' ), $logo->Get( 'height' ) ), '320x240',
        'the logo draws inside the frame';

    my $bar = GlitchVape::Watermark::apply( $made->(), 'bar' );
    is $bar->Get( 'width' ), 320, 'the bar keeps the width';
    cmp_ok $bar->Get( 'height' ), '>', 240,
        'and makes the result taller, which is the point of it';

    # The mark is letters and not a block, which is a thing only the pixels
    # can say.
    #
    # It is built by taking a greyscale silhouette of the V and the A and
    # moving it into the alpha of a white rectangle, and if that move is not
    # made the rectangle stays opaque -- so the picture is signed with a pale
    # square in the corner and every other check here still passes. That is
    # exactly what happened under ImageMagick 6, which does not know the newer
    # name for the composite that does the moving.
    #
    # So the question is the shape of what was drawn: find the pixels the mark
    # changed, take the box around them, and ask how much of that box is
    # filled. Letterforms leave the counters and the gap between the two
    # letters untouched and fill about half of it; a solid block fills all of
    # it. Drawn at twice the size of the others, since a mark of eighteen
    # pixels is mostly the antialiasing at its edges.
    my ( $w, $h ) = ( 640, 480 );

    my $pixels = sub {
        my ( $img ) = @_;
        return [
            $img->GetPixels(
                map       => 'I',
                width     => $w,
                height    => $h,
                normalize => 1
            )
        ];
    };

    my $before = $pixels->( $made->( $w, $h ) );
    my $after =
        $pixels->( GlitchVape::Watermark::apply( $made->( $w, $h ), 'logo' ) );

    my ( $x0, $y0, $x1, $y1 ) = ( $w, $h, -1, -1 );
    my $marked = 0;

    for my $y ( 0 .. $h - 1 )
    {
        for my $x ( 0 .. $w - 1 )
        {
            my $at = $y * $w + $x;
            next if abs( $before->[ $at ] - $after->[ $at ] ) <= 0.01;

            $marked++;
            $x0 = $x if $x < $x0;
            $x1 = $x if $x > $x1;
            $y0 = $y if $y < $y0;
            $y1 = $y if $y > $y1;
        }
    }

    cmp_ok $marked, '>', 0, 'the logo actually marks the picture';

    my $box = ( $x1 - $x0 + 1 ) * ( $y1 - $y0 + 1 );
    cmp_ok $marked / ( $box || 1 ), '<', 0.8,
        'and marks it with letters rather than with a solid block';
}

# ---------------------------------------------------------------------------
# Stripping metadata keeps the tags that describe the pixels

# The distinction the Metadata page promises: what identifies the photographer
# goes, what says how to read the file stays. ImageMagick's Strip cannot make
# it, which is why this does not use Strip.

SKIP:
{
    my $exiftool = GlitchVape::Tools::find( 'exiftool' );
    skip 'exiftool is not installed', 6 unless $exiftool;
    skip 'Image::Magick is not installed', 6
        unless eval { require Image::Magick; 1 };

    my $src = "$dir/tagged.jpg";
    {
        my $img = Image::Magick->new( size => '160x120' );
        $img->Read( 'xc:#806040' );
        $img->Write( $src );
    }

    system(
        $exiftool,              '-overwrite_original',
        '-q',                   '-q',
        '-GPSLatitude=51.5',    '-Make=Canon',
        '-UserComment=private', '-DateTimeOriginal=2019:04:01 10:00:00',
        '-Orientation#=1',      $src
    );

    my $tags = sub {
        my ( $path ) = @_;

        my $out = GlitchVape::Tools::capture(
            $exiftool,      '-s',
            '-s',           '-s',
            '-GPSLatitude', '-Make',
            '-UserComment', '-DateTimeOriginal',
            '-Orientation', '-Software',
            $path
        ) // q{};

        return $out;
    };

    like $tags->( $src ), qr/Canon/, 'the source carries what a camera writes';

    my $stripped = "$dir/stripped.jpg";
    {
        my $img = Image::Magick->new;
        $img->Read( $src );
        GlitchVape::IO::save( $img, $stripped, metadata => 'strip' );
    }

    my $after = $tags->( $stripped );
    unlike $after, qr/Canon/,   'stripping takes the camera out';
    unlike $after, qr/private/, 'and the comment';
    unlike $after, qr/2019/,    'and the date';
    like $after, qr/Horizontal/,
        'and leaves the orientation, which is structural';

    my $credited = "$dir/credited.jpg";
    {
        my $img = Image::Magick->new;
        $img->Read( $src );
        GlitchVape::IO::save(
            $img, $credited,
            metadata => 'strip',
            credit   => 1
        );
    }

    like $tags->( $credited ), qr/GlitchVape/,
        'and the credit is written when it is asked for';
}

done_testing;
