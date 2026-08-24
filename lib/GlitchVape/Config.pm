package GlitchVape::Config;

use strict;
use warnings;

use File::Basename qw(basename);
use File::Spec     ();

use GlitchVape::Paths ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Config - preset loading and CLI override merging

=head1 PRESET FORMAT

    name: vhs-decay
    title: Third-generation tape dub
    extends: base-vhs          # optional; merged under this file
    output:
      max_dim: 1440
      format: png
    effects:
      downsample: { factor: 2.5 }
      scanlines:  { opacity: 0.35, spacing: 3 }
      chroma_shift: { amount: 6, angle: 0 }
      vignette:   { enabled: 0 }     # switch off something inherited
    order: [downsample, chroma_shift, scanlines]   # optional

=head1 OVERRIDES

CLI overrides are dotted: C<--set scanlines.opacity=0.5>. An effect can also be
switched on with defaults (C<--enable bloom>) or off (C<--disable vignette>).
Overrides always win over the preset, and are applied after C<extends>
resolution so they cannot be clobbered by inheritance.

=cut

my $MAX_EXTEND_DEPTH = 8;

=head2 preset_dirs()

Search path for presets: C<$GLITCHVAPE_PRESETS>, then C<./presets>, then the
checkout the module was loaded from, then the directory the packaging
installed the data into. Every one that exists is searched, so a preset of
your own shadows one that shipped without replacing it.

=cut

sub preset_dirs
{
    my @dirs;
    push @dirs, split /:/, $ENV{ GLITCHVAPE_PRESETS }
        if $ENV{ GLITCHVAPE_PRESETS };
    push @dirs, 'presets';

    my $here = __FILE__;
    $here =~ s{/lib/GlitchVape/Config\.pm$}{};
    push @dirs, File::Spec->catdir( $here, 'presets' );

    # Installed, the walk-up above lands in vendor_perl, which has no presets
    # under it. See GlitchVape::Paths.
    if ( my $data = GlitchVape::Paths::data_root() )
    {
        push @dirs, File::Spec->catdir( $data, 'presets' );
    }

    my %seen;
    return grep { -d && !$seen{ $_ }++ } @dirs;
}

=head2 list_presets()

C<< [ { name, title, path }, ... ] >> for every preset found on the path.

=cut

sub list_presets
{
    my @out;
    my %seen;

    for my $dir ( preset_dirs() )
    {
        opendir my $dh, $dir or next;
        for my $file ( sort readdir $dh )
        {
            next unless $file =~ /\.(ya?ml)$/;
            my $name = $file;
            $name =~ s/\.ya?ml$//;
            next if $seen{ $name }++;

            my $path = File::Spec->catfile( $dir, $file );
            my $data = eval { _read_yaml( $path ) } || {};
            push @out, {
                name => $name,

                # A preset saved from the interface may have no title: the
                # save dialog treats it as optional, and an untitled preset
                # is still a perfectly good preset. Falling back to the name
                # keeps the listing's second column from being blank.
                title => _title_of( $data, $name ),
                path  => $path,
            };
        }
        closedir $dh;
    }
    return [ sort { $a->{ name } cmp $b->{ name } } @out ];
}

=head2 find_preset( $name )

Path to a named preset, or undef. A name containing a slash or ending in
C<.yml> is treated as a literal path.

=cut

sub find_preset
{
    my ( $name ) = @_;
    return undef unless defined $name && length $name;

    # A name that looks like a path is taken literally rather than searched
    # for, so a preset can live outside the preset directories.
    if ( $name =~ m{/} || $name =~ /\.ya?ml$/ )
    {
        if ( -f $name )
        {
            return $name;
        }
        return undef;
    }

    for my $dir ( preset_dirs() )
    {
        for my $ext ( qw(yml yaml) )
        {
            my $path = File::Spec->catfile( $dir, "$name.$ext" );
            return $path if -f $path;
        }
    }
    return undef;
}

=head2 load( %arg )

    preset   => 'vhs-decay'      preset name or path (optional)
    set      => [ 'a.b=c', ... ] dotted overrides
    enable   => [ names ]        turn on with defaults
    disable  => [ names ]        turn off

Returns C<< { effects => {...}, order => [...], output => {...}, name => ... } >>.

=cut

sub load
{
    my ( %arg ) = @_;

    my $config = { effects => {}, output => {}, order => undef, name => undef };

    if ( defined $arg{ preset } && length $arg{ preset } )
    {
        my $path = find_preset( $arg{ preset } )
            or die _preset_not_found( $arg{ preset } );
        $config = _load_with_inheritance( $path, 0 );
        $config->{ name } //= _basename_name( $arg{ preset } );
    }

    for my $name ( @{ $arg{ enable } || [] } )
    {
        $config->{ effects }{ $name } ||= {};
        delete $config->{ effects }{ $name }{ enabled };
    }

    for my $spec ( @{ $arg{ set } || [] } )
    {
        _apply_override( $config, $spec );
    }

    for my $name ( @{ $arg{ disable } || [] } )
    {
        $config->{ effects }{ $name }{ enabled } = 0
            if exists $config->{ effects }{ $name };
    }
    $config->{ disable } = [ @{ $arg{ disable } || [] } ];

    return $config;
}

sub _load_with_inheritance
{
    my ( $path, $depth, $seen ) = @_;
    $seen ||= {};

    die
        "GlitchVape: preset inheritance too deep (>$MAX_EXTEND_DEPTH) at $path\n"
        if $depth > $MAX_EXTEND_DEPTH;

    die "GlitchVape: circular preset inheritance involving $path\n"
        if $seen->{ $path }++;

    my $data = _read_yaml( $path );
    die "GlitchVape: preset $path is not a mapping\n"
        unless ref $data eq 'HASH';

    my $config = {
        effects => $data->{ effects } || {},
        output  => $data->{ output }  || {},
        order   => $data->{ order },
        name    => $data->{ name },
        title   => $data->{ title },
        seed    => $data->{ seed },
    };

    if ( my $parent = $data->{ extends } )
    {
        my $ppath = find_preset( $parent )
            or die
            "GlitchVape: preset $path extends '$parent', which was not found\n";

        my $base = _load_with_inheritance( $ppath, $depth + 1, $seen );

        $config->{ effects } =
            _merge_effects( $base->{ effects }, $config->{ effects } );
        $config->{ output } =
            { %{ $base->{ output } }, %{ $config->{ output } } };
        $config->{ order } //= $base->{ order };
        $config->{ seed }  //= $base->{ seed };
    }

    return $config;
}

# Per-effect shallow merge: a child that names an effect overrides only the
# parameters it mentions, leaving the parent's other values intact.
sub _merge_effects
{
    my ( $base, $over ) = @_;
    my %out = map { $_ => { %{ $base->{ $_ } || {} } } } keys %$base;

    for my $name ( keys %$over )
    {
        my $v = $over->{ $name };
        $v = {} unless ref $v eq 'HASH';
        $out{ $name } = { %{ $out{ $name } || {} }, %$v };
    }
    return \%out;
}

sub _apply_override
{
    my ( $config, $spec ) = @_;

    my ( $lhs, $value ) = split /=/, $spec, 2;
    die "GlitchVape: --set expects effect.param=value, got '$spec'\n"
        unless defined $lhs && defined $value && length $lhs;

    my ( $effect, $param ) = split /\./, $lhs, 2;
    die "GlitchVape: --set expects effect.param=value, got '$spec'\n"
        unless defined $effect && defined $param && length $param;

    $config->{ effects }{ $effect } ||= {};
    $config->{ effects }{ $effect }{ $param } = $value;

    # Setting a parameter on an effect the preset disabled is a clear
    # intent to use it.
    delete $config->{ effects }{ $effect }{ enabled }
        if exists $config->{ effects }{ $effect }{ enabled }
        && !$config->{ effects }{ $effect }{ enabled }
        && $param ne 'enabled';

    return;
}

sub _read_yaml
{
    my ( $path ) = @_;

    # Read as bytes, not characters. YAML::XS decodes UTF-8 itself and chokes
    # on an already-decoded string -- which only shows up once a preset
    # contains non-ASCII, i.e. as soon as any of them carry Japanese text.
    open my $fh, '<:raw', $path
        or die "GlitchVape: cannot read preset $path: $!\n";
    my $bytes = do { local $/; <$fh> };
    close $fh;

    if ( eval { require YAML::XS; 1 } )
    {
        my $data = eval { YAML::XS::Load( $bytes ) };
        die "GlitchVape: preset $path is not valid YAML: $@\n" if $@;
        return $data;
    }

    if ( eval { require YAML::PP; 1 } )
    {
        require Encode;
        return YAML::PP->new->load_string( Encode::decode( 'UTF-8', $bytes ) );
    }

    die "GlitchVape: no YAML parser available for $path.\n"
        . "  Install one with:  sudo apt install libyaml-libyaml-perl\n";
}

sub _basename_name
{
    my ( $n ) = @_;
    $n = basename( $n );
    $n =~ s/\.ya?ml$//;
    return $n;
}

sub _preset_not_found
{
    my ( $name ) = @_;
    my @known = map { $_->{ name } } @{ list_presets() };

    # If presets were found, name them. If none were, the problem is more
    # likely the search path than the spelling, so show that instead.
    my $hint;
    if ( @known )
    {
        $hint = '  Available: ' . join( ', ', @known ) . "\n";
    }
    else
    {
        $hint = '  No presets found on: ' . join( ', ', preset_dirs() ) . "\n";
    }

    return "GlitchVape: no preset named '$name'.\n" . $hint;
}

sub _title_of
{
    my ( $data, $name ) = @_;

    my $title = $data->{ title };
    return $title if defined $title && length $title;

    return $name;
}

1;
