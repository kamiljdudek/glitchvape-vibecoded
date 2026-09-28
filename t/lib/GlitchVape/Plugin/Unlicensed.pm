package GlitchVape::Plugin::Unlicensed;

# Ships a font with no licence beside it, which a font may not do.

use strict;
use warnings;

use GlitchVape::Plugins api => 1;

use File::Basename ();
use File::Spec     ();

use GlitchVape::Fonts ();

our $VERSION = '0.1';

GlitchVape::Fonts->add_dir(
    File::Spec->catdir(
        File::Basename::dirname( __FILE__ ),
        'Unlicensed', 'fonts'
    )
);

1;
