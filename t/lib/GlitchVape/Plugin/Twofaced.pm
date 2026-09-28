package GlitchVape::Plugin::Twofaced;

# Loads cleanly where its standard error is /dev/null -- which is where the
# trial child puts it -- and dies anywhere else, after registering an effect
# and a palette. So it passes the trial and fails in the real load, which is
# the one way to reach the loader's other retraction: what it added in the
# parent has to be taken back there.

use strict;
use warnings;

use GlitchVape::Plugins api => 1;
use GlitchVape::Palette  ();
use GlitchVape::Registry ();

our $VERSION = '0.1';

GlitchVape::Registry->register(
    name    => 'twofaced',
    stage   => 'colour',
    summary => 'Only half here',
    apply   => sub { return },
);

GlitchVape::Palette->register(
    name   => 'twofaced',
    colors => [ '#000000', '#FFFFFF' ],
);

die "it behaves differently when it is watched\n" unless -c STDERR;

1;
