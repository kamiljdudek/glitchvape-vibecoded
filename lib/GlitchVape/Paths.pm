package GlitchVape::Paths;

use strict;
use warnings;

use File::Spec ();

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

=head1 THE DROP-IN DIRECTORIES

Three kinds of thing can be added without touching an installed package --
fonts, presets and plug-ins -- and all three are looked for in the same two
places the XDG base directory specification names, so that there is one
answer to "where do I put it" rather than three.

=head2 data_home()

F<$XDG_DATA_HOME>, or F<~/.local/share> when that is unset. undef only when
there is no home directory to hang it off, which is a system account rather
than a person.

A relative C<$XDG_DATA_HOME> is ignored rather than resolved, as the
specification says it should be -- and it is right: relative to what?

=cut

sub data_home
{
    my $base = $ENV{ XDG_DATA_HOME };

    if ( !defined $base || !length $base || $base !~ m{\A/} )
    {
        my $home = $ENV{ HOME };
        return undef unless defined $home && length $home;

        $base = File::Spec->catdir( $home, '.local', 'share' );
    }

    return $base;
}

=head2 data_dirs()

The system data directories: C<$XDG_DATA_DIRS> unioned with the defaults
rather than replaced by them. The specification says a set variable replaces
the default, but desktop sessions routinely set it to a list that has dropped
F</usr/local/share>, and a documented drop-in directory that silently stops
being searched depending on which session started the program is worse than
searching two directories that are usually empty.

=cut

sub data_dirs
{
    my @dirs;

    push @dirs, grep { length } split /:/, $ENV{ XDG_DATA_DIRS }
        if defined $ENV{ XDG_DATA_DIRS };

    push @dirs, File::Spec->catdir( q{}, 'usr', 'local', 'share' ),
        File::Spec->catdir( q{}, 'usr', 'share' );

    my %seen;
    return grep { !$seen{ $_ }++ } @dirs;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Assets> and L<GlitchVape::Config>, the two callers of
L</data_root>; L<GlitchVape::Fonts>, L<GlitchVape::Config> and
L<GlitchVape::Plugins> for the drop-in directories.

=cut
