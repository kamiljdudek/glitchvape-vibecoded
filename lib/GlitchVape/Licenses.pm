package GlitchVape::Licenses;

use strict;
use warnings;

use File::Spec ();

use GlitchVape::Fonts ();
use GlitchVape::Paths ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Licenses - the licence texts that shipped, read from where they shipped

=head1 DESCRIPTION

Two of the bundled typefaces are under the SIL Open Font License, which asks
that its text travel with the font. It does: every font release is installed
unpacked, F<LICENSE> and F<README> and all, exactly as its author published it.

So this module quotes rather than restates. Nothing here contains licence
text; it finds the files on disk -- the project's own F<LICENSE> beside the
data, and every licence that came with a font on
L<GlitchVape::Fonts/search_dirs> -- and reads them. A font added by dropping a
release into F<~/.local/share/glitchvape/fonts> therefore shows up in the about
window and in C<glitchvape --licenses> without anyone editing a source file,
and a licence file can never drift out of step with a copy of it, because
there is no copy.

=head1 WHAT COUNTS AS A LICENCE FILE

F<LICENSE>, F<LICENCE>, F<COPYING> or F<OFL>, with or without a C<.txt> or
C<.md> extension, anywhere under a font directory. Font projects put them at
the top of a release and, when they are assembled from other projects, one per
component underneath -- Fusion Pixel carries three of those -- and both are
worth showing.

=cut

# Enough to name the licence in a one-line summary. A file that matches none
# of these is still shown in full; only the label is unavailable, and a wrong
# label would be worse than none.
my @SNIFF = (
    [
        qr/SIL\s+Open\s+Font\s+License,?\s+Version\s+1[.]1/i =>
            'SIL Open Font License 1.1'
    ],
    [ qr/SIL\s+Open\s+Font\s+License/i         => 'SIL Open Font License' ],
    [ qr/\bMIT\s+License\b/i                   => 'MIT' ],
    [ qr/Apache\s+License,\s+Version\s+2[.]0/i => 'Apache License 2.0' ],
    [ qr/GNU\s+GENERAL\s+PUBLIC\s+LICENSE/i    => 'GNU GPL' ],
);

# Resolved once, at load, because __FILE__ is relative when the module was
# found through a relative -I and this has to survive the caller chdir-ing
# afterwards -- which the test suite does.
my $FILE = File::Spec->rel2abs( __FILE__ );

my $LICENCE_FILE = qr{
    \A
    (?: licen[cs]e | copying | ofl )
    (?: [-_.] [\w.-]* )?
    \z
}xi;

=head2 program_file()

Path to GlitchVape's own F<LICENSE>, or undef.

Looked for where the data is -- the installed data directory, or the checkout
this module was loaded from. C<make install> puts it there precisely so that
this lookup has one answer in both shapes.

=cut

sub program_file
{
    my @candidates;

    if ( my $data = GlitchVape::Paths::data_root() )
    {
        push @candidates, File::Spec->catfile( $data, 'LICENSE' );
    }

    # The checkout: LICENSE sits at the top, two levels above this file.
    my $here = $FILE;
    if ( $here =~ s{[/\\]lib[/\\]GlitchVape[/\\]Licenses\.pm\z}{} )
    {
        push @candidates, File::Spec->catfile( $here, 'LICENSE' );
    }

    for my $path ( @candidates )
    {
        return $path if -f $path;
    }

    return undef;
}

=head2 bundled()

C<< [ { name, file, license, fonts }, ... ] >> -- one entry per licence file
found on the font search path, in search order.

C<name> is the release directory the licence was found in, C<file> its path,
C<license> the licence's name when it could be told from the text, and
C<fonts> the font files sitting beside it.

=cut

sub bundled
{
    my @found;
    my %seen;

    for my $dir ( GlitchVape::Fonts::search_dirs() )
    {
        for my $file ( _licence_files( $dir ) )
        {
            # The same directory can be reached twice -- a checkout whose
            # assets/fonts is also named by $GLITCHVAPE_FONTS, say -- and one
            # licence listed twice reads as two fonts.
            next if $seen{ $file }++;

            push @found, _entry( $dir, $file );
        }
    }

    return \@found;
}

=head2 read_file( $path )

The contents of a licence file, or undef. Decoded as UTF-8: licence files
carry names, and a name is not ASCII often enough to matter.

=cut

sub read_file
{
    my ( $path ) = @_;

    return undef unless defined $path && -f $path;

    open my $fh, '<:encoding(UTF-8)', $path or return undef;
    my $text = do { local $/ = undef; <$fh> };
    close $fh;

    return $text;
}

=head2 notice()

Everything above as one block of text: the program's licence, then each
bundled licence under a heading naming what it covers and the file it was read
from. This is what the about window shows and what C<--licenses> prints.

Returns undef when nothing at all could be read, which is a broken install
rather than an unlicensed program -- the caller says so rather than inventing
a licence to show in its place.

=cut

sub notice
{
    my @parts;

    if ( my $text = read_file( program_file() ) )
    {
        push @parts, _section( 'GlitchVape', program_file(), $text );
    }

    for my $entry ( @{ bundled() } )
    {
        my $text = read_file( $entry->{ file } );
        next unless defined $text;

        my $heading = "Bundled font: $entry->{ name }";

        my $fonts = $entry->{ fonts };
        if ( @$fonts )
        {
            $heading .= ' (' . join( ', ', @$fonts ) . ')';
        }

        push @parts, _section( $heading, $entry->{ file }, $text );
    }

    return undef unless @parts;

    return join "\n", @parts;
}

sub _section
{
    my ( $heading, $path, $text ) = @_;

    $text =~ s/\s+\z//;

    return sprintf "%s\n%s\n%s\n\n%s\n", $heading, '=' x length $heading,
        $path, $text;
}

sub _entry
{
    my ( $dir, $file ) = @_;

    my ( undef, $parent, $base ) = File::Spec->splitpath( $file );
    $parent =~ s{/\z}{};

    # Named by where it sits relative to the directory it was found in, so
    # that "DepartureMono-1.500" and "fusion-pixel.../LICENSES/galmuri" both
    # say something, and a licence at the top of a search directory still has
    # a name to be listed under.
    my $name = File::Spec->abs2rel( $parent, $dir );
    $name = $base if !length $name || $name eq File::Spec->curdir;

    my $text = read_file( $file );

    return {
        name    => $name,
        file    => $file,
        license => defined $text ? _sniff( $text ) : undef,
        fonts   => [ _fonts_beside( $parent ) ],
    };
}

sub _sniff
{
    my ( $text ) = @_;

    # The head of the file: the body of the OFL mentions other licences by
    # name in its FAQ, and matching those would label a font by whatever it
    # was compared against.
    my $head = substr $text, 0, 4000;

    for my $rule ( @SNIFF )
    {
        my ( $pattern, $name ) = @$rule;
        return $name if $head =~ $pattern;
    }

    return undef;
}

# The font files in one directory, not below it: a licence sits with the
# fonts it covers, and a release with per-component licences underneath has
# already listed those separately.
sub _fonts_beside
{
    my ( $dir ) = @_;

    opendir my $dh, $dir or return ();
    my @fonts = sort grep { /[.](?:ttf|otf|ttc|pcf|bdf)\z/i } readdir $dh;
    closedir $dh;

    return @fonts;
}

# Breadth-first, like the font walk it parallels, and for the same reason: a
# licence at the top of a search directory is more likely to be the one that
# matters than one several levels down. Directory symlinks are not followed.
sub _licence_files
{
    my ( $dir ) = @_;

    my @found;
    my @queue = ( $dir );

    while ( @queue )
    {
        my $current = shift @queue;

        opendir my $dh, $current or next;
        my @entries = sort readdir $dh;
        closedir $dh;

        my @deeper;

        for my $entry ( @entries )
        {
            next if $entry eq '.' || $entry eq '..';

            my $path = File::Spec->catfile( $current, $entry );

            if ( -d $path )
            {
                push @deeper, $path unless -l $path;
                next;
            }

            push @found, $path if $entry =~ $LICENCE_FILE;
        }

        push @queue, @deeper;
    }

    return @found;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Fonts>, which owns the search path this walks, and
L<GlitchVape::GUI::About>, which puts the result in the about window.

=cut
