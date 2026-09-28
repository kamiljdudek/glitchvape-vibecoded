package GlitchVape::Fonts;

use strict;
use warnings;

use File::Spec ();

use GlitchVape::Assets ();
use GlitchVape::Paths  ();

use GlitchVape::Tools ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Fonts - resolve logical font roles to real font files

=head1 DESCRIPTION

Presets ask for a I<role> -- C<vcr>, C<cjk>, C<pixel> -- not a font name, so
they keep working on a machine that has a different subset installed. Each role
lists candidates best-first; the first one present wins.

Files found in the font directories take priority over anything installed
system-wide, which is how the fonts nobody packages (VCR OSD Mono in
particular) get picked up without needing to be installed at all.

=head1 WHERE FONTS ARE LOOKED FOR

More than one directory, because an installed package owns F<assets/fonts>
and nobody should be dropping files into a directory that the next C<rpm -U>
will rewrite. In order:

=over 4

=item * C<$GLITCHVAPE_FONTS>, colon-separated, for pointing at a set of fonts
without moving anything.

=item * C<$XDG_DATA_HOME/glitchvape/fonts> -- F<~/.local/share/glitchvape/fonts>
by default. B<This is the drop-in directory>: it needs no root, it survives
upgrades, and it is what L</resolve_or_die> names when a role cannot be
satisfied.

=item * F<glitchvape/fonts> under each C<$XDG_DATA_DIRS> entry, which on a
standard system means F</usr/local/share/glitchvape/fonts> and
F</usr/share/glitchvape/fonts> -- the system-wide equivalent, for a font
every account should see.

=item * The bundled F<assets/fonts>, which is the checkout in a checkout and
the installed data directory in a package.

=item * F<assets/fonts-nonfree> beside it, which holds the typefaces this
project may not hand on in its base package -- see L</TWO BUNDLED
DIRECTORIES>. After the drop-in directories, so that anything dropped in above
shadows a bundled font of the same name rather than fighting it.

=item * The directories plug-ins added, in the order they loaded -- see
L</WHAT A PLUG-IN CAN ADD>.

=back

=head1 TWO BUNDLED DIRECTORIES

Whether a font can be found and whether it can be redistributed are different
questions, and answering them with one directory meant answering them the
same way. F<assets/fonts-nonfree> is the second answer: a font whose terms are
narrower than the base package's licence, or not established at all, lives
there and is packaged separately as C<glitchvape-fonts-extra>.

The search path does not care about the distinction -- both directories are on
it, and a font in either is a font -- so a checkout behaves as though the
split were not there. What the split buys is that the base package can state
one honest licence and mean it, while the font is still one C<apt install>
away for anyone who wants it.

Nothing is there today but W95FA, whose licence arrived as a font
aggregator's summary rather than as a document. VCR OSD Mono was there until
its author was asked directly and said it was free for any purpose.

Subdirectories are searched too, so an upstream release can be unpacked whole
-- licence, README and all -- rather than having its font files picked out of
it. That is not only convenience: the licence travelling with the font is what
lets the about window and C<--licenses> quote it from the file rather than
from a copy pasted into the source. Within one directory the top level is
searched first, so a loose file still wins over one in a folder beneath it.

Only formats FreeType can actually load are considered: C<ttf>, C<otf>,
C<ttc>, C<pcf> and C<bdf>. The C<woff> and C<woff2> files that font releases
carry for the web are ignored, because ImageMagick cannot render from them.

=head1 WHAT A PLUG-IN CAN ADD

A role, and a directory to find fonts in. A role is the whole point of the
indirection -- a plug-in whose effect wants "a font that looks like a till
receipt" names one, lists the faces that would do best-first, and a machine
without any of them renders with whatever comes last rather than failing.

A directory is how a plug-in ships the face itself. It is searched after
everything else, so nothing a plug-in brings can shadow a font the program or
its user already chose. It is refused if any font in it has no licence file
beside it or above it, which is the rule C<make check-licenses> holds the
bundled fonts to, read at load time instead because nobody's build ever saw
the plug-in -- and it is what lets the about window quote the licence rather
than claim one.

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

# Each search directory walked once, keyed by path. See _files_under.
my %SCANNED;

# What plug-ins added: roles as { plugin, hint } beside their %ROLE entry, and
# font directories as { dir, plugin } in the order they arrived.
my %ROLE_FROM;
my @DIR;

=head2 roles()

Sorted list of known role names.

=cut

sub roles
{
    my @roles = sort keys %ROLE;
    return @roles;
}

=head2 register_role( name => $role, fonts => [ ... ], hint => $text )

C<fonts> is the candidate list, best first, as font names or file names.
C<hint> is the advice L</resolve_or_die> gives when none of them is found; it
is optional, and without it the advice is the generic one.

=cut

sub register_role
{
    my ( $class, %arg ) = @_;

    my $name = $arg{ name } // q{};

    die "GlitchVape::Fonts: a font role needs a name made of lower case "
        . "letters, digits and underscores\n"
        unless $name =~ /\A[a-z][a-z0-9_]*\z/;

    if ( $ROLE{ $name } )
    {
        my $whose = 'the program itself';
        $whose = "plug-in $ROLE_FROM{$name}{plugin}"
            if $ROLE_FROM{ $name } && defined $ROLE_FROM{ $name }{ plugin };

        die "GlitchVape::Fonts: font role '$name' registered twice -- "
            . "$whose already has it\n";
    }

    my @fonts = grep { defined && length } @{ $arg{ fonts } || [] };

    die "GlitchVape::Fonts: font role '$name' lists no fonts\n"
        unless @fonts;

    require GlitchVape::Plugins;

    $ROLE{ $name }      = \@fonts;
    $ROLE_FROM{ $name } = {
        plugin => GlitchVape::Plugins::owner( scalar caller ),
        hint   => $arg{ hint },
    };

    # A spec that resolved to nothing before may name this role now.
    %CACHE = ();

    return $name;
}

=head2 add_dir( $dir )

Search C<$dir> for fonts, after everything else. Dies if the directory is not
there, or if any font under it has no licence -- see L</WHAT A PLUG-IN CAN
ADD>.

=cut

sub add_dir
{
    my ( $class, $dir ) = @_;

    die "GlitchVape::Fonts: no font directory given\n"
        unless defined $dir && length $dir;
    die "GlitchVape::Fonts: font directory $dir is not there\n"
        unless -d $dir;

    require GlitchVape::Licenses;
    require GlitchVape::Plugins;

    if ( my @bare = GlitchVape::Licenses::unlicensed( $dir ) )
    {
        my $more = @bare > 1 ? sprintf( ' and %d more', @bare - 1 ) : q{};

        die "GlitchVape::Fonts: $bare[0]$more has no licence file beside "
            . "it or above it, and a font ships only with its licence\n";
    }

    push @DIR,
        {
        dir    => $dir,
        plugin => GlitchVape::Plugins::owner( scalar caller ),
        };

    %CACHE = ();

    return $dir;
}

=head2 retract( $plugin ) / contributions( $plugin )

A plug-in's roles and directories, taken back or listed -- the two questions
L<GlitchVape::Plugins> asks every place a plug-in can add to.

=cut

sub retract
{
    my ( $class, $plugin ) = @_;

    for my $role ( _roles_from( $plugin ) )
    {
        delete $ROLE{ $role };
        delete $ROLE_FROM{ $role };
    }

    @DIR   = grep { ( $_->{ plugin } // q{} ) ne $plugin } @DIR;
    %CACHE = ();

    return;
}

sub contributions
{
    my ( $class, $plugin ) = @_;

    return {
        'font roles'       => [ _roles_from( $plugin ) ],
        'font directories' => [
            map  { $_->{ dir } }
            grep { ( $_->{ plugin } // q{} ) eq $plugin } @DIR
        ],
    };
}

sub _roles_from
{
    my ( $plugin ) = @_;

    my @roles = sort grep {
        defined $ROLE_FROM{ $_ }{ plugin }
            && $ROLE_FROM{ $_ }{ plugin } eq $plugin
    } keys %ROLE_FROM;

    return @roles;
}

=head2 asset_dir()

The bundled font directory: the checkout's F<assets/fonts>, or the one the
packaging installed. Owned by whoever installed it, so it is the one place on
the search path that is not yours to drop files into.

=cut

sub asset_dir
{
    return GlitchVape::Assets::dir( 'fonts' );
}

=head2 extra_dir()

The bundled directory for typefaces that are not the base package's to hand
on. Present in a checkout and in an install of C<glitchvape-fonts-extra>;
absent otherwise, which L</search_dirs> treats as an empty directory rather
than as a problem. See L</TWO BUNDLED DIRECTORIES>.

=cut

sub extra_dir
{
    return GlitchVape::Assets::dir( 'fonts-nonfree' );
}

=head2 user_dir()

F<$XDG_DATA_HOME/glitchvape/fonts>, whether or not it exists yet -- the
directory to tell somebody to create. undef only when there is no home
directory to hang it off, which is a system account rather than a person.

=cut

sub user_dir
{
    my $base = GlitchVape::Paths::data_home() or return undef;

    return File::Spec->catdir( $base, 'glitchvape', 'fonts' );
}

=head2 search_dirs()

Every directory that exists on the search path, in the order it is searched.
See L</WHERE FONTS ARE LOOKED FOR>.

=cut

sub search_dirs
{
    my @dirs;

    push @dirs, grep { length } split /:/, $ENV{ GLITCHVAPE_FONTS }
        if defined $ENV{ GLITCHVAPE_FONTS };

    if ( my $user = user_dir() )
    {
        push @dirs, $user;
    }

    push @dirs,
        map { File::Spec->catdir( $_, 'glitchvape', 'fonts' ) }
        GlitchVape::Paths::data_dirs();

    push @dirs, asset_dir(), extra_dir();

    # A plug-in's own fonts come last of all, so that nothing it ships can
    # shadow a face the program or its user already chose.
    push @dirs, map { $_->{ dir } } @DIR;

    my %seen;
    return grep { -d && !$seen{ $_ }++ } @dirs;
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
    # The directory to name is the one they can actually write to. Installed
    # from a package, assets/fonts belongs to rpm; ~/.local/share does not.
    my $assets = user_dir() || asset_dir();

    my %hint_for = (
        cjk       => "  sudo apt install fonts-noto-cjk fonts-ipafont\n",
        cjk_serif => "  sudo apt install fonts-noto-cjk fonts-ipafont\n",
        pixel     => "  sudo apt install fonts-misaki fonts-terminus\n",
        mono      => "  sudo apt install fonts-cascadia-code fonts-hack\n",
        sans      => "  sudo apt install fonts-dejavu\n",

        # Neither of these is packaged anywhere, so the only real answer is to
        # download the file and drop it into the bundled font directory.
        vcr => "  Download VCR OSD Mono and drop the .ttf into\n"
            . "  $assets  (mkdir -p it first)\n"
            . "  https://www.dafont.com/vcr-osd-mono.font\n"
            . "  Or:  sudo apt install fonts-cascadia-code\n",

        ui => "  Download W95FA and drop the .otf into\n"
            . "  $assets  (mkdir -p it first)\n"
            . "  https://www.dafont.com/w95fa.font\n"
            . "  Or:  sudo apt install fonts-dejavu\n",
    );

    my $hint = $hint_for{ lc $spec };

    # A role a plug-in registered says for itself what would satisfy it.
    if ( !defined $hint && $ROLE_FROM{ lc $spec } )
    {
        my $said = $ROLE_FROM{ lc $spec }{ hint };
        $hint = "  $said\n" if defined $said && length $said;
    }

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

# Every font file on the search path: each directory in turn, and within a
# directory the whole top level before any subdirectory, each level sorted.
#
# Breadth-first within a directory rather than depth-first because the
# ordering is the documented behaviour -- a file dropped straight in wins --
# and the recursion extends it rather than changing it. An unpacked release in
# a versioned subdirectory becomes a fallback instead of being invisible.
sub _asset_files
{
    return map { _files_under( $_ ) } search_dirs();
}

# One directory, cached: resolving a single role asks after as many as eight
# candidate names, and each of those would otherwise walk the tree again.
#
# Symbolic links to directories are not followed: a font directory is somebody
# else's release tree, and walking into a link is how a loop becomes a hang.
sub _files_under
{
    my ( $dir ) = @_;

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
