package GlitchVape::Assets;

use strict;
use warnings;

use File::Spec ();

use GlitchVape::Paths ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Assets - finding the files that ship alongside the code

=head1 DESCRIPTION

Fonts, colour lookup tables and artwork live in F<assets/> next to F<lib/>,
and every one of them has to be found from a module that could have been
loaded from anywhere. This is the one place that works out where "next to
F<lib/>" is, so the answer cannot drift between the things that need it.

=cut

=head2 root()

The F<assets> directory, or the relative path as a last resort -- a missing
asset is something the caller reports, not something that stops the program
loading.

Looked for in three places, most specific first: C<$GLITCHVAPE_ASSETS>, the
checkout the module was loaded from, and the directory the packaging installed
the data into.

=cut

sub root
{
    # An explicit override comes first so that a test, or someone trying a
    # different set of fonts, does not have to move anything on disk.
    my $override = $ENV{ GLITCHVAPE_ASSETS };
    return $override if defined $override && -d $override;

    # __FILE__ is this module's path however it was found, so walking up from
    # it locates the checkout without needing to know the working directory.
    my $here = __FILE__;
    $here =~ s{/lib/GlitchVape/Assets\.pm\z}{};

    my $bundled = File::Spec->catdir( $here, 'assets' );
    return $bundled if -d $bundled;

    # Installed, the walk-up above finds nothing: the modules are in
    # vendor_perl and the data is in the distribution's data directory.
    if ( my $data = GlitchVape::Paths::data_root() )
    {
        my $installed = File::Spec->catdir( $data, 'assets' );
        return $installed if -d $installed;
    }

    return 'assets';
}

=head2 dir( @parts )

A directory under L</root>.

=cut

sub dir
{
    my ( @parts ) = @_;
    return File::Spec->catdir( root(), @parts );
}

=head2 path( @parts )

A file under L</root>, whether or not it exists.

=cut

sub path
{
    my ( @parts ) = @_;
    return File::Spec->catfile( root(), @parts );
}

=head2 find( @parts )

The same, but undef when there is nothing there -- for the callers that would
rather degrade than explain a missing file.

=cut

sub find
{
    my ( @parts ) = @_;

    my $path = path( @parts );
    return undef unless -f $path;

    return $path;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Fonts>, which looks for bundled typefaces here.

=cut
