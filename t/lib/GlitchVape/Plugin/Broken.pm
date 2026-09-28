package GlitchVape::Plugin::Broken;

# Registers an effect and then dies. The child it is tried in sees the death,
# so the loader refuses it without the parent ever running it -- and the
# effect it registered first must be nowhere afterwards.

use strict;
use warnings;

use GlitchVape::Plugins api => 1;
use GlitchVape::Registry ();

our $VERSION = '0.1';

GlitchVape::Registry->register(
    name    => 'burnt',
    stage   => 'colour',
    summary => 'Never gets this far',
    apply   => sub { return },
);

# Never returns, which is the point, so there is no true value to end on.
die "the oven is on fire\n";    ## no critic (Modules::RequireEndWithOne)
