#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Path ();
use File::Spec ();
use File::Temp ();

use Test::More;
use GlitchVape::Fonts ();

# The asset search is what lets a font that Debian does not package be used by
# dropping it in a directory, and it grew a recursion so that an upstream
# release can be unpacked whole rather than picked apart. Both the ordering
# and the format filter are load-bearing, and neither is visible from
# anywhere else.

# resolve() caches by spec for the life of the process, so every scenario
# below asks after a name of its own rather than reusing one.

sub asset_tree
{
    my ( %file ) = @_;

    my $dir = File::Temp->newdir( 'gv_fonts_XXXXXX', TMPDIR => 1 );

    for my $relative ( keys %file )
    {
        my $path = File::Spec->catfile( "$dir", split m{/}, $relative );

        my ( undef, $parent ) = File::Spec->splitpath( $path );
        File::Path::make_path( $parent ) if length $parent;

        open my $fh, '>', $path or die "cannot write $path: $!";
        print { $fh } $file{ $relative };
        close $fh;
    }

    return $dir;
}

# ---------------------------------------------------------------------------
# The top level

{
    my $dir = asset_tree( 'AlphaOne-Regular.ttf' => 'x' );
    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    like GlitchVape::Fonts::resolve( 'AlphaOne-Regular' ),
        qr/AlphaOne-Regular[.]ttf\z/,
        'a font dropped into the asset directory is found';

    # Matching ignores everything but alphanumerics, so a release filename
    # with a version in it still answers to the font's name.
    like GlitchVape::Fonts::resolve( 'Alpha One' ),
        qr/AlphaOne-Regular[.]ttf\z/,
        'and the name need not match the filename punctuation for punctuation';
}

# ---------------------------------------------------------------------------
# Subdirectories

{
    my $dir = asset_tree(
        'some-release-v9/BravoTwo-Regular.otf' => 'x',
        'some-release-v9/README.md'            => 'not a font',
        'some-release-v9/LICENSES/OFL.txt'     => 'not a font',
    );
    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    like GlitchVape::Fonts::resolve( 'BravoTwo-Regular' ),
        qr/some-release-v9.BravoTwo-Regular[.]otf\z/,
        'a font inside an unpacked release is found';
}

{
    # Deeper than one level, since releases nest.
    my $dir = asset_tree( 'a/b/c/CharlieThree-Regular.ttf' => 'x' );
    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    ok GlitchVape::Fonts::resolve( 'CharlieThree-Regular' ),
        'and however deep it is buried';
}

# ---------------------------------------------------------------------------
# Ordering

{
    # The documented promise is that a file dropped straight into the asset
    # directory wins. Adding the recursion must not quietly reverse that.
    my $dir = asset_tree(
        'DeltaFour-Regular.ttf'               => 'top',
        'older-release/DeltaFour-Regular.ttf' => 'nested',
    );
    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    my $found = GlitchVape::Fonts::resolve( 'DeltaFour-Regular' );

    unlike $found, qr/older-release/,
        'the top level still beats a subdirectory';
}

# ---------------------------------------------------------------------------
# Formats

{
    # Font releases ship web formats beside the real ones. FreeType cannot
    # load either, so offering one to ImageMagick would be a render that fails
    # rather than a font that works.
    my $dir = asset_tree(
        'EchoFive-Regular.otf.woff2' => 'x',
        'EchoFive-Regular.woff'      => 'x',
    );
    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    is GlitchVape::Fonts::resolve( 'EchoFive-Regular' ), undef,
        'woff and woff2 are not offered as fonts';
}

{
    my $dir = asset_tree( 'FoxtrotSix-Regular.otf' => 'x' );
    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    ok GlitchVape::Fonts::resolve( 'FoxtrotSix-Regular' ),
        'while the otf beside them is';
}

# ---------------------------------------------------------------------------
# The search path
#
# More than one directory since fonts started being installed by a package:
# assets/fonts belongs to rpm, so a font someone adds has to have somewhere
# else to go. The order is the whole of the promise -- what you drop in wins
# over what shipped -- so it is asserted rather than described.

{
    my $home   = File::Temp->newdir( 'gv_home_XXXXXX',   TMPDIR => 1 );
    my $system = File::Temp->newdir( 'gv_system_XXXXXX', TMPDIR => 1 );
    my $env    = File::Temp->newdir( 'gv_env_XXXXXX',    TMPDIR => 1 );

    my $user_fonts =
        File::Spec->catdir( "$home", '.local', 'share', 'glitchvape', 'fonts' );
    my $system_fonts = File::Spec->catdir( "$system", 'glitchvape', 'fonts' );

    File::Path::make_path( $user_fonts, $system_fonts );

    local $ENV{ HOME }             = "$home";
    local $ENV{ XDG_DATA_DIRS }    = "$system";
    local $ENV{ GLITCHVAPE_FONTS } = "$env";
    delete local $ENV{ XDG_DATA_HOME };

    is GlitchVape::Fonts::user_dir(), $user_fonts,
        'the drop-in directory is XDG_DATA_HOME, defaulted from $HOME';

    my @dirs = GlitchVape::Fonts::search_dirs();

    is $dirs[ 0 ], "$env",        'GLITCHVAPE_FONTS is searched first';
    is $dirs[ 1 ], $user_fonts,   'then the per-user drop-in directory';
    is $dirs[ 2 ], $system_fonts, 'then glitchvape/fonts under XDG_DATA_DIRS';

    # The bundled directories are last, so that a font dropped into any of
    # the above shadows one that shipped rather than losing to it. There are
    # two of them -- the fonts this project may hand on and the ones it may
    # not, packaged separately -- and both are behind everything a user
    # controls.
    like $dirs[ -2 ], qr/assets.fonts\z/,
        'the bundled directory is searched after everything droppable-into';
    like $dirs[ -1 ], qr/assets.fonts-nonfree\z/,
        'and the separately-packaged one last of all';

    # A directory that is not there is not searched, but naming it is not an
    # error either: the per-user one does not exist until somebody creates it.
    ok !( grep { !-d } @dirs ), 'only directories that exist are searched';
}

{
    # XDG_DATA_HOME set explicitly, and the defaults still present in
    # XDG_DATA_DIRS -- a session that sets it to a narrower list must not
    # silently stop searching the documented system directory.
    my $data  = File::Temp->newdir( 'gv_xdg_XXXXXX', TMPDIR => 1 );
    my $fonts = File::Spec->catdir( "$data", 'glitchvape', 'fonts' );
    File::Path::make_path( $fonts );

    local $ENV{ XDG_DATA_HOME } = "$data";
    delete local $ENV{ GLITCHVAPE_FONTS };

    is GlitchVape::Fonts::user_dir(), $fonts,
        'an explicit XDG_DATA_HOME is used as it stands';

    my @dirs = GlitchVape::Fonts::search_dirs();
    is $dirs[ 0 ], $fonts, 'and comes first once GLITCHVAPE_FONTS is unset';
}

{
    # A drop-in font beats a bundled one of the same name, which is the point
    # of the ordering and the answer to "where do I put VCR OSD Mono".
    my $drop = asset_tree( 'HotelEight-Regular.otf' => 'dropped in' );

    # A stand-in for the packaged tree: Assets::root() is what asset_dir()
    # hangs 'fonts' off, so the bundled copy has to sit under one.
    my $ship = asset_tree( 'fonts/HotelEight-Regular.otf' => 'shipped' );

    local $ENV{ GLITCHVAPE_FONTS }  = "$drop";
    local $ENV{ GLITCHVAPE_ASSETS } = "$ship";

    like GlitchVape::Fonts::resolve( 'HotelEight-Regular' ), qr/\Q$drop\E/,
        'a dropped-in font shadows a bundled one of the same name';
}

{
    # Several directories at once, since GLITCHVAPE_FONTS is a path now.
    my $one = asset_tree( 'IndiaNine-Regular.otf' => 'x' );
    my $two = asset_tree( 'JulietTen-Regular.otf' => 'x' );

    local $ENV{ GLITCHVAPE_FONTS } = "$one:$two";

    ok GlitchVape::Fonts::resolve( 'IndiaNine-Regular' ),
        'GLITCHVAPE_FONTS is a colon-separated path: the first entry';
    ok GlitchVape::Fonts::resolve( 'JulietTen-Regular' ), 'and the second';
}

# ---------------------------------------------------------------------------
# Roles

{
    my @roles = GlitchVape::Fonts::roles();

    ok scalar( grep { $_ eq 'pixel' } @roles ), 'the pixel role exists';
    ok scalar( grep { $_ eq 'vcr' } @roles ),   'and the vcr role';

    # available() is what --check-fonts prints, so every role has to appear in
    # it whether or not anything satisfies it.
    my $available = GlitchVape::Fonts::available();
    is scalar @$available, scalar @roles,
        'every role is reported, satisfied or not';
}

{
    my $dir = asset_tree( 'nothing-here.txt' => 'x' );
    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    local $@;
    ok !eval { GlitchVape::Fonts::resolve_or_die( 'GolfSeven' ); 1 },
        'a name nothing satisfies dies';
    like $@, qr/no font found/, 'saying so';
}

done_testing;
