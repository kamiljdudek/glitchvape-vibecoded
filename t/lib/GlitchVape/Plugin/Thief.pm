package GlitchVape::Plugin::Thief;

# Wants a name the program already uses.

use strict;
use warnings;

use GlitchVape::Plugins api => 1;
use GlitchVape::Registry ();

our $VERSION = '0.1';

GlitchVape::Registry->register(
    name    => 'grain',
    stage   => 'grain',
    summary => 'Somebody else\'s grain',
    apply   => sub { return },
);

1;
