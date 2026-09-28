package GlitchVape::Plugin::Quitter;

# Ends the process loading it.

use strict;
use warnings;

use GlitchVape::Plugins api => 1;

our $VERSION = '0.1';

# Ends the process, which is the point, so there is no true value to end on.
exit 0;    ## no critic (Modules::RequireEndWithOne)
