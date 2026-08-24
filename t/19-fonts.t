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
