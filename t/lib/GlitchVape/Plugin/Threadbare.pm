package GlitchVape::Plugin::Threadbare;

# Does ImageMagick work while loading, which starts OpenMP's thread pool: the
# one thing a plug-in can do at load time that nothing can undo afterwards,
# and that a forked render deadlocks on. The loader has to catch it in the
# trial child, before this process ever runs it.

use strict;
use warnings;

use GlitchVape::Plugins api => 1;

use Image::Magick ();

our $VERSION = '0.1';

my $warm = Image::Magick->new( size => '800x800' );
$warm->Read( 'xc:gray50' );
$warm->Blur( radius => 4, sigma => 3 );

1;
