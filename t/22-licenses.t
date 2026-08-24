#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Path ();
use File::Spec ();
use File::Temp ();

use Test::More;
use GlitchVape::Licenses ();

# Two of the bundled typefaces are under the SIL Open Font License, which asks
# that its text travel with the font. It does, on disk, and this module is the
# reason nothing has to restate it in Perl: it finds the licence files beside
# the fonts and reads them.
#
# What is worth asserting is that it finds them where fonts actually put them
# -- at the top of a release, and one per component in a release assembled
# from several projects -- and that it reads them rather than describing them.

sub font_tree
{
    my ( %file ) = @_;

    my $dir = File::Temp->newdir( 'gv_licenses_XXXXXX', TMPDIR => 1 );

    for my $relative ( sort keys %file )
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

my $OFL = <<'TEXT';
Copyright 2022 Nobody In Particular.

This Font Software is licensed under the SIL Open Font License, Version 1.1.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining a copy
of the Font Software, to use, study, copy, merge, embed, modify, redistribute.
TEXT

# ---------------------------------------------------------------------------
# A release unpacked whole

{
    my $dir = font_tree(
        'SomeFace-2.0/SomeFace-Regular.otf' => 'not really a font',
        'SomeFace-2.0/LICENSE'              => $OFL,
        'SomeFace-2.0/README.md'            => 'a readme',
    );

    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    my $bundled = GlitchVape::Licenses::bundled();
    my ( $entry ) = grep { $_->{ name } eq 'SomeFace-2.0' } @$bundled;

    ok $entry, 'the licence at the top of a release is found';
    is $entry->{ license }, 'SIL Open Font License 1.1',
        'and the licence it is under is named from its text';
    is_deeply $entry->{ fonts }, [ 'SomeFace-Regular.otf' ],
        'along with the font sitting beside it';

    like GlitchVape::Licenses::read_file( $entry->{ file } ),
        qr/Nobody In Particular/,
        'and the file is read rather than paraphrased';
}

# ---------------------------------------------------------------------------
# A release assembled from other projects
#
# Fusion Pixel is three fonts merged, and carries a licence for each of them
# under LICENSES/ as well as its own. Showing only the top one would credit
# one author and drop three.

{
    my $dir = font_tree(
        'Merged-1.0/Merged-Regular.otf'          => 'x',
        'Merged-1.0/OFL.txt'                     => $OFL,
        'Merged-1.0/LICENSES/upstream-a/OFL.txt' => $OFL,
        'Merged-1.0/LICENSES/upstream-b/LICENSE.txt' => $OFL,
    );

    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    my @names = map { $_->{ name } } @{ GlitchVape::Licenses::bundled() };

    ok scalar( grep { $_ eq 'Merged-1.0' } @names ), 'the release licence';
    ok scalar( grep { $_ eq 'Merged-1.0/LICENSES/upstream-a' } @names ),
        'and one for each project it was assembled from';
    ok scalar( grep { $_ eq 'Merged-1.0/LICENSES/upstream-b' } @names ),
        'however it named the file';
}

# ---------------------------------------------------------------------------
# What is not a licence

{
    my $dir = font_tree(
        'Bare-1.0/Bare-Regular.otf' => 'x',
        'Bare-1.0/README.md'        => 'no licence here',
        'Bare-1.0/CHANGELOG'        => 'nor here',
    );

    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    my @names = map { $_->{ name } } @{ GlitchVape::Licenses::bundled() };

    ok !scalar( grep { /Bare-1[.]0/ } @names ),
        'a release with no licence file contributes nothing to claim it has one';
}

# ---------------------------------------------------------------------------
# The notice

{
    my $dir = font_tree(
        'Quoted-1.0/Quoted-Regular.otf' => 'x',
        'Quoted-1.0/LICENSE'            => $OFL,
    );

    local $ENV{ GLITCHVAPE_FONTS } = "$dir";

    my $notice = GlitchVape::Licenses::notice();

    ok defined $notice, 'there is a notice to show';
    like $notice, qr/Nobody In Particular/,
        'containing the bundled licence as written';
    like $notice, qr/\QQuoted-1.0\E/, 'under a heading naming what it covers';
    like $notice, qr/\Q$dir\E/, 'and the file it was read from';

    # The program's own licence leads, so that the first thing in the about
    # window's licence page is the licence of the thing in the window.
    like $notice, qr/\A\QGlitchVape\E\n=+\n/,
        "the program's own licence comes first";
    like $notice, qr/MIT/, 'and it is the MIT text, read from LICENSE';
}

# ---------------------------------------------------------------------------
# The checkout and the install

{
    my $file = GlitchVape::Licenses::program_file();

    ok $file, 'the program licence is found from a checkout';
    ok -f $file, 'and it is a file';

    like GlitchVape::Licenses::read_file( $file ), qr/MIT License/,
        'containing the licence the project is under';
}

{
    # Installed, LICENSE sits beside the data rather than two levels above
    # the module -- the module is in vendor_perl by then. Same shape as the
    # DATADIR probe in 21-paths.t, and the same reason: a constant rewritten
    # by `make install` cannot be tested in this process.
    my $tmp  = File::Temp->newdir( 'gv_licinst_XXXXXX', TMPDIR => 1 );
    my $data = File::Spec->catdir( "$tmp", 'share', 'glitchvape' );
    my $lib  = File::Spec->catdir( "$tmp", 'vendor_perl' );

    File::Path::make_path( File::Spec->catdir( $data, 'assets', 'fonts' ),
        File::Spec->catdir( $lib, 'GlitchVape' ) );

    for my $mod ( qw(Paths Assets Fonts Tools Licenses) )
    {
        my $from =
            File::Spec->catfile( "$FindBin::Bin/../lib/GlitchVape", "$mod.pm" );
        my $to = File::Spec->catfile( $lib, 'GlitchVape', "$mod.pm" );

        open my $in,  '<', $from or die "read $from: $!";
        open my $out, '>', $to   or die "write $to: $!";
        while ( my $line = <$in> )
        {
            $line =~
                s/^use constant DATADIR => q\{\};/use constant DATADIR => '$data';/;
            print { $out } $line;
        }
        close $in;
        close $out;
    }

    open my $fh, '>', File::Spec->catfile( $data, 'LICENSE' ) or die $!;
    print { $fh } "MIT License\n\nthe installed copy\n";
    close $fh;

    my $release = File::Spec->catdir( $data, 'assets', 'fonts', 'Packaged-1.0' );
    File::Path::make_path( $release );

    open $fh, '>', File::Spec->catfile( $release, 'LICENSE' ) or die $!;
    print { $fh } $OFL;
    close $fh;

    open $fh, '>', File::Spec->catfile( $release, 'Packaged-Regular.otf' )
        or die $!;
    print { $fh } 'x';
    close $fh;

    my $probe = <<'PROBE';
use strict; use warnings;
use GlitchVape::Licenses ();
print "program=", GlitchVape::Licenses::program_file() // 'undef', "\n";
print "bundled=", join( ',', map { $_->{ name } }
    @{ GlitchVape::Licenses::bundled() } ), "\n";
print "notice=", length( GlitchVape::Licenses::notice() // q{} ), "\n";
PROBE

    my $out = _probe( "$tmp", $lib, $probe );
    my %got = map { /^(\w+)=(.*)$/ ? ( $1 => $2 ) : () } split /\n/, $out;

    is $got{ program }, File::Spec->catfile( $data, 'LICENSE' ),
        'installed, the licence is found beside the data' or diag $out;
    like $got{ bundled }, qr/Packaged-1[.]0/,
        'and so is the licence of a font installed with it';
    cmp_ok $got{ notice }, '>', 0, 'and there is a notice to print';
}

# The child chdirs and sets @INC for itself; nothing here is quoted for a
# shell, because none is involved.
sub _probe
{
    my ( $dir, $lib, $program ) = @_;

    my $pid = open my $fh, '-|';
    die "fork: $!" unless defined $pid;

    unless ( $pid )
    {
        open STDERR, '>&', \*STDOUT or exit 127;
        chdir $dir or exit 127;
        delete $ENV{ GLITCHVAPE_ASSETS };
        delete $ENV{ GLITCHVAPE_FONTS };

        # A real home would have a drop-in directory in it, and this is
        # asserting what the package installed rather than what is on the
        # machine running the tests.
        $ENV{ HOME }          = $dir;
        $ENV{ XDG_DATA_HOME } = File::Spec->catdir( $dir, 'no-such-data' );
        $ENV{ XDG_DATA_DIRS } = File::Spec->catdir( $dir, 'no-such-dirs' );

        exec { $^X } $^X, "-I$lib", '-e', $program or exit 127;
    }

    my $out = do { local $/ = undef; <$fh> };
    close $fh;

    return $out // q{};
}

done_testing;
