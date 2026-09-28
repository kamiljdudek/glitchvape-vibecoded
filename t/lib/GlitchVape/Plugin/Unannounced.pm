package GlitchVape::Plugin::Unannounced;

# Perfectly good apart from not saying which plug-in API it was written for.

use strict;
use warnings;

use GlitchVape::Registry ();

our $VERSION = '0.1';

GlitchVape::Registry->register(
    name    => 'unannounced',
    stage   => 'colour',
    summary => 'Says nothing about its API',
    apply   => sub { return },
);

1;
