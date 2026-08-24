#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Path ();
use File::Spec ();
use File::Temp ();

use Test::More;
use GlitchVape::Assets ();
use GlitchVape::Config ();
use GlitchVape::Paths  ();

# Where the data files are is the one thing that differs between a checkout
# and an installed package, and it is invisible until someone installs it.
# These are the two shapes: next to lib/, and wherever the packaging put it.

{
    is GlitchVape::Paths::DATADIR, q{},
        'the shipped DATADIR is empty, meaning "not installed"';

    is GlitchVape::Paths::data_root(), undef,
        'an empty DATADIR reports no installed root';
}

# In a checkout the walk-up from __FILE__ finds assets/ and presets/ beside
# lib/, exactly as it did before GlitchVape::Paths existed.
{
    my $root = GlitchVape::Assets::root();

    ok -d $root, 'the checkout resolves assets to a real directory';
    like $root, qr{assets\z}, 'and it is the assets directory';

    ok GlitchVape::Assets::find( 'artwork', 'logo.png' ),
        'a bundled asset is found from the checkout';

    my @dirs = GlitchVape::Config::preset_dirs();
    ok scalar @dirs, 'presets are found from the checkout';
}

# An explicit override wins over both, which is what makes the above testable
# and lets someone point at a different asset set without moving anything.
{
    my $tmp = File::Temp->newdir( 'gv_assets_XXXXXX', TMPDIR => 1 );

    local $ENV{ GLITCHVAPE_ASSETS } = "$tmp";
    is GlitchVape::Assets::root(), "$tmp",
        'GLITCHVAPE_ASSETS overrides the checkout';

    local $ENV{ GLITCHVAPE_ASSETS } = '/no/such/directory/anywhere';
    isnt GlitchVape::Assets::root(), '/no/such/directory/anywhere',
        'an override naming nothing is ignored rather than obeyed';
}

# The installed shape. DATADIR is a constant, so this runs a child with it
# rewritten -- which is also exactly what `make install` does to it, and the
# reason the constant is on a line of its own.
{
    my $tmp  = File::Temp->newdir( 'gv_install_XXXXXX', TMPDIR => 1 );
    my $data = File::Spec->catdir( "$tmp", 'share', 'glitchvape' );
    my $lib  = File::Spec->catdir( "$tmp", 'vendor_perl' );

    File::Path::make_path(
        File::Spec->catdir( $data, 'assets', 'artwork' ),
        File::Spec->catdir( $data, 'presets' ),
        File::Spec->catdir( $lib,  'GlitchVape' ),
    );

    # Only the three modules the resolution actually goes through, so a
    # failure here is about paths rather than about loading the whole program.
    for my $mod ( qw(Paths Assets Config) )
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

    # Something to find at the far end.
    open my $fh, '>', File::Spec->catfile( $data, 'presets', 'packaged.yml' )
        or die $!;
    print { $fh }
        "name: packaged\ntitle: from the installed tree\neffects: {}\n";
    close $fh;

    open $fh, '>', File::Spec->catfile( $data, 'assets', 'artwork', 'logo.png' )
        or die $!;
    print { $fh } 'not really a png';
    close $fh;

    my $probe = <<'PROBE';
use strict; use warnings;
use GlitchVape::Assets (); use GlitchVape::Config (); use GlitchVape::Paths ();
print "root=",   GlitchVape::Paths::data_root() // 'undef', "\n";
print "assets=", GlitchVape::Assets::root(), "\n";
print "logo=",   GlitchVape::Assets::find('artwork','logo.png') // 'undef', "\n";
print "presets=", join(',', GlitchVape::Config::preset_dirs()), "\n";
PROBE

    # Run from a directory with no assets/ or presets/ under it, so a pass
    # cannot come from the relative fallbacks. Through a list-form piped open
    # rather than backticks: a temporary directory's path is not guaranteed
    # to be free of anything a shell would take an interest in.
    my $out = _probe( "$tmp", $lib, $probe );

    my %got = map { /^(\w+)=(.*)$/ ? ( $1 => $2 ) : () } split /\n/, $out;

    is $got{ root }, $data, 'an installed DATADIR reports itself'
        or diag $out;
    is $got{ assets }, File::Spec->catdir( $data, 'assets' ),
        'assets resolve into the installed data directory';
    is $got{ logo },
        File::Spec->catfile( $data, 'assets', 'artwork', 'logo.png' ),
        'and a file under it is found';
    like $got{ presets }, qr/\Q$data\E/,
        'presets are searched in the installed data directory';
}

# The child chdirs and sets @INC for itself, so nothing here has to be quoted
# for a shell that is never involved.
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
        delete $ENV{ GLITCHVAPE_PRESETS };
        exec { $^X } $^X, "-I$lib", '-e', $program or exit 127;
    }

    my $out = do { local $/ = undef; <$fh> };
    close $fh;

    return $out // q{};
}

done_testing;
