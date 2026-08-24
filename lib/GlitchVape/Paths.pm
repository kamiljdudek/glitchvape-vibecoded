package GlitchVape::Paths;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Paths - where the data files ended up

=head1 DESCRIPTION

In a checkout, F<assets/> and F<presets/> sit next to F<lib/>, and
L<GlitchVape::Assets> and L<GlitchVape::Config> find them by walking up from
their own C<__FILE__>. That stops working the moment the modules are installed
somewhere a distribution chooses -- Fedora puts them in C<vendor_perl>, which
is nowhere near the data.

So there is one constant, in one file, naming the directory the data was
installed into, and the packaging rewrites it. Everything else asks here.

=head1 THE EMPTY DEFAULT IS THE CHECKOUT

C<DATADIR> is empty in the source tree and that is not an oversight: an empty
value means "not installed", which sends both callers back to the walk-up they
already do. A checkout therefore behaves exactly as it did before this module
existed, and no test has to know whether it is running from a package.

C<make install> rewrites the line below to the real directory. It is written
plainly, on one line, so that the substitution is a grep away from being
checked rather than something to take on faith.

=cut

use constant DATADIR => q{};

=head2 data_root()

The installed data directory, or undef when running from a checkout -- or when
the packaging named a directory that is not there, which is a broken install
rather than something to paper over with a guess.

=cut

sub data_root
{
    my $dir = DATADIR;

    return undef unless length $dir;
    return undef unless -d $dir;

    return $dir;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Assets> and L<GlitchVape::Config>, the two callers.

=cut
