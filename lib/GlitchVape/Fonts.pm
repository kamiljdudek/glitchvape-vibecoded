package GlitchVape::Fonts;

use strict;
use warnings;

use File::Spec ();

use GlitchVape::Assets ();

use GlitchVape::Tools ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Fonts - resolve logical font roles to real font files

=head1 DESCRIPTION

Presets ask for a I<role> -- C<vcr>, C<cjk>, C<pixel> -- not a font name, so
they keep working on a machine that has a different subset installed. Each role
lists candidates best-first; the first one present wins.

Files dropped into F<assets/fonts> take priority over anything installed
system-wide, which is how the fonts that Debian does not package (VCR OSD Mono
in particular) get picked up without needing to be installed at all.

Subdirectories are searched too, so an upstream release can be unpacked whole
-- licence, README and all -- rather than having its font files picked out of
it. The top level is still searched first, so a file dropped straight into
F<assets/fonts> continues to win over anything in a folder beneath it.

Only formats FreeType can actually load are considered: C<ttf>, C<otf>,
C<ttc>, C<pcf> and C<bdf>. The C<woff> and C<woff2> files that font releases
carry for the web are ignored, because ImageMagick cannot render from them.

=cut

my %ROLE = (

    # The camcorder timestamp face. Nothing in Debian is a close match, so the
    # fallbacks aim for "narrow pixel-ish mono" rather than anything similar.
    vcr => [
        'VCR OSD Mono',
        'VCROSDMono',
        'Departure Mono',
        'VT323',
        'Cascadia Mono',
        'Terminus',
        'DejaVu Sans Mono',
    ],

    # Japanese. Gothic (sans) reads as signage, Mincho (serif) as print.
    cjk => [
        'Noto Sans CJK JP',
        'Noto Sans CJK JP Regular',
        'IPAGothic',
        'IPAPGothic', 'VL Gothic', 'M+ 1c', 'Noto Sans JP', 'Unifont',
    ],

    cjk_serif =>
        [ 'Noto Serif CJK JP', 'IPAMincho', 'IPAPMincho', 'Noto Sans CJK JP', ],

    # Bitmap / low-resolution. Misaki is an 8x8 Japanese pixel font and is by
    # far the best fit here when it is installed. The Japanese cut of Fusion
    # Pixel is preferred over the Chinese ones: it carries kana, which is what
    # the text effects actually draw.
    pixel => [
        'Misaki Gothic',
        'misaki_gothic',
        'fusion-pixel-12px-monospaced-ja',
        'fusion-pixel-12px-monospaced-zh_hans',
        'Departure Mono',
        'Terminus',
        'Unifont',
        'DejaVu Sans Mono',
    ],

    # The Windows 95 interface face, for the desktop-furniture look.
    ui => [
        'W95FA',         'W95F',
        'MS Sans Serif', 'Tahoma',
        'DejaVu Sans',   'Liberation Sans',
    ],

    mono => [
        'Cascadia Mono',
        'Cascadia Code',
        'JetBrains Mono',
        'Hack',
        'DejaVu Sans Mono',
        'Liberation Mono',
    ],

    sans => [ 'DejaVu Sans', 'Liberation Sans', 'Noto Sans', ],
);

my %CACHE;

# The asset directory walked once per location, since resolving one role
# asks after as many as eight candidate names.
my %SCANNED;

=head2 roles()

Sorted list of known role names.

=cut

sub roles
{
    my @roles = sort keys %ROLE;
    return @roles;
}

=head2 asset_dir()

Directory searched for bundled font files.

=cut

sub asset_dir
{
    return $ENV{ GLITCHVAPE_FONTS } if $ENV{ GLITCHVAPE_FONTS };

    return GlitchVape::Assets::dir( 'fonts' );
}

=head2 resolve( $spec )

C<$spec> is a role name, a literal font name, or a path to a font file.
Returns a path, or undef if nothing matched.

=cut

sub resolve
{
    my ( $spec ) = @_;
    return undef unless defined $spec && length $spec;
    return $CACHE{ $spec } if exists $CACHE{ $spec };

    # An explicit path is taken at face value.
    return $CACHE{ $spec } = $spec if -f $spec;

    # A known role expands to its ordered candidate list; anything else is
    # treated as a literal font name to look up directly.
    my @candidates;
    if ( $ROLE{ lc $spec } )
    {
        @candidates = @{ $ROLE{ lc $spec } };
    }
    else
    {
        @candidates = ( $spec );
    }

    for my $name ( @candidates )
    {
        if ( my $file = _find_in_assets( $name ) )
        {
            return $CACHE{ $spec } = $file;
        }
    }

    if ( my $file = GlitchVape::Tools::font_path( @candidates ) )
    {
        return $CACHE{ $spec } = $file;
    }

    return $CACHE{ $spec } = undef;
}

=head2 resolve_or_die( $spec, $why )

As L</resolve>, but dies with guidance naming the packages that would satisfy
the role.

=cut

sub resolve_or_die
{
    my ( $spec, $why ) = @_;

    my $path = resolve( $spec );
    return $path if $path;

    # Point at whatever would actually satisfy this particular role. A generic
    # "install some fonts" message is useless when the role needs Japanese
    # glyphs specifically, or a face that Debian does not package at all.
    #
    # A lookup table rather than a chain of branches: the roles are unrelated
    # to one another, so there is no ordering worth expressing, and adding a
    # role is one more entry instead of one more elsif.
    my $assets = asset_dir();

    my %hint_for = (
        cjk       => "  sudo apt install fonts-noto-cjk fonts-ipafont\n",
        cjk_serif => "  sudo apt install fonts-noto-cjk fonts-ipafont\n",
        pixel     => "  sudo apt install fonts-misaki fonts-terminus\n",
        mono      => "  sudo apt install fonts-cascadia-code fonts-hack\n",
        sans      => "  sudo apt install fonts-dejavu\n",

        # Neither of these is packaged anywhere, so the only real answer is to
        # download the file and drop it into the bundled font directory.
        vcr => "  Download VCR OSD Mono and drop the .ttf into $assets\n"
            . "  https://www.dafont.com/vcr-osd-mono.font\n"
            . "  Or:  sudo apt install fonts-cascadia-code\n",

        ui => "  Download W95FA and drop the .otf into $assets\n"
            . "  https://www.dafont.com/w95fa.font\n"
            . "  Or:  sudo apt install fonts-dejavu\n",
    );

    my $hint = $hint_for{ lc $spec };

    # An unrecognised spec is a literal font name rather than a role, so there
    # is nothing role-specific to suggest.
    if ( !defined $hint )
    {
        $hint = "  sudo apt install fonts-dejavu fonts-noto-cjk\n";
    }

    # Name the effect that wanted the font, when the caller said, so the
    # message points at the preset line to change.
    my $reason = q{};
    if ( $why )
    {
        $reason = " ($why)";
    }

    die "GlitchVape: no font found for '$spec'$reason.\n" . $hint;
}

=head2 available()

C<< [ [ role, resolved_path_or_undef ], ... ] >> for C<--check-fonts>.

=cut

sub available
{
    return [ map { [ $_, resolve( $_ ) ] } roles() ];
}

# Every font file under the asset directory, nearest first: the whole top
# level before any subdirectory, and each level in sorted order.
#
# Breadth-first rather than depth-first because the ordering is the documented
# behaviour -- a file dropped straight into assets/fonts wins -- and this
# extends it rather than changing it. An unpacked release in a versioned
# subdirectory becomes a fallback instead of being invisible.
#
# Symbolic links to directories are not followed: a font directory is somebody
# else's release tree, and walking into a link is how a loop becomes a hang.
sub _asset_files
{
    my $dir = asset_dir();

    return @{ $SCANNED{ $dir } } if $SCANNED{ $dir };

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

            push @found, $path if $entry =~ /[.](?:ttf|otf|ttc|pcf|bdf)\z/i;
        }

        push @queue, @deeper;
    }

    $SCANNED{ $dir } = \@found;

    return @found;
}

sub _find_in_assets
{
    my ( $name ) = @_;

    # Compare on alphanumerics only, so "VCR OSD Mono" matches
    # "VCR_OSD_MONO_1.001.ttf".
    my $want = lc $name;
    $want =~ s/[^a-z0-9]//g;
    return undef unless length $want;

    for my $path ( _asset_files() )
    {
        my ( undef, undef, $file ) = File::Spec->splitpath( $path );

        my $base = lc $file;
        $base =~ s/[.][^.]+\z//;
        $base =~ s/[^a-z0-9]//g;

        return $path if $base eq $want || index( $base, $want ) == 0;
    }

    return undef;
}

1;
