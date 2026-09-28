package GlitchVape::Plugin::Windowed;

# Reaches for Gtk3, which nothing outside the window may. Only in a sub that
# is never called, so that the rule is caught by reading the source, as
# `make check-split` does, rather than by the machine happening to lack Gtk3.

use strict;
use warnings;

use GlitchVape::Plugins api => 1;

our $VERSION = '0.1';

## no critic (Subroutines::ProhibitUnusedPrivateSubroutines)
sub _never_called
{
    require Gtk3;
    return;
}
## use critic

1;
