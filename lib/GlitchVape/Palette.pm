package GlitchVape::Palette;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Palette - named colour palettes and gradient/LUT construction

=head1 DESCRIPTION

Palettes are ordered dark-to-light. That ordering is what makes
L</gradient_stops> usable as a luminance map without any extra metadata: index
0 is what shadows become, the last entry is what highlights become.

=cut

my %PALETTE = (

    # The canonical five. Everything else is a variation on this mood.
    vapor => {
        title  => 'Classic vaporwave',
        colors => [ '#2B0F54', '#B967FF', '#FF71CE', '#01CDFE', '#05FFA1' ],
    },

    hotline => {
        title  => 'Hotline Miami neon-noir',
        colors => [ '#0D0221', '#261447', '#F6019D', '#FF3864', '#2DE2E6' ],
    },

    mallsoft => {
        title  => 'Muted dead-mall pastels',
        colors => [ '#6B5B73', '#A8998C', '#C9ADA7', '#D4C5B9', '#F1E9E1' ],
    },

    laserwave => {
        title  => 'Synthwave laser grid',
        colors => [ '#2E2A5C', '#3B35A5', '#EB64B9', '#40B4C4', '#FFE261' ],
    },

    sunset => {
        title  => 'Retro-80s horizon',
        colors => [ '#2B1055', '#6C5B7B', '#C44569', '#FF6B9D', '#F8B500' ],
    },

    neontokyo => {
        title  => 'Night-city signage',
        colors => [ '#12002B', '#7B2FFF', '#FF0080', '#00FFFF', '#FFEA00' ],
    },

    crt => {
        title  => 'Green phosphor monitor',
        colors => [ '#0A1A0A', '#0F3D0F', '#1FA51F', '#39FF14', '#A8FFA0' ],
    },

    amber => {
        title  => 'Amber phosphor terminal',
        colors => [ '#1A0F00', '#3D2600', '#B87400', '#FFB000', '#FFD980' ],
    },

    gameboy => {
        title  => 'DMG-01 four-tone',
        colors => [ '#0F380F', '#306230', '#8BAC0F', '#9BBC0F' ],
    },

    broadcast => {
        title  => 'SMPTE colour bars',
        colors => [
            '#000000', '#0000C0', '#C00000', '#C000C0',
            '#00C000', '#00C0C0', '#C0C000', '#FFFFFF'
        ],
    },

    seapunk => {
        title  => 'Aquatic cyan/teal drift',
        colors => [ '#04263A', '#0A6E80', '#2DD6C4', '#7FFFD4', '#D8FFF5' ],
    },

    fax => {
        title  => 'Degraded thermal-paper monochrome',
        colors => [ '#1C1A17', '#4A453D', '#8A8175', '#C4BCAC', '#EFE8D8' ],
    },
);

# Two-stop ramps for duotone. Kept separate from the 5-stop palettes because a
# duotone wants maximum separation between its ends, not an even spread.
my %DUOTONE = (
    vapor    => [ '#2B0F54', '#05FFA1' ],
    hotline  => [ '#0D0221', '#2DE2E6' ],
    pinkcyan => [ '#FF71CE', '#01CDFE' ],
    magenta  => [ '#1A0033', '#FF00AA' ],
    sunset   => [ '#2B1055', '#F8B500' ],
    crt      => [ '#000000', '#39FF14' ],
    amber    => [ '#0A0500', '#FFB000' ],
    bluepink => [ '#1B2A6B', '#FF6EC7' ],
    seapunk  => [ '#04263A', '#7FFFD4' ],
);

=head2 names()

Sorted palette names.

=cut

sub names
{
    my @names = sort keys %PALETTE;
    return @names;
}

=head2 duotone_names()

Sorted duotone ramp names.

=cut

sub duotone_names
{
    my @names = sort keys %DUOTONE;
    return @names;
}

=head2 known( $name )

Whether C<$name> is a registered palette.

=cut

sub known { defined $PALETTE{ lc( $_[ 0 ] // '' ) } }

=head2 colors( $spec )

Resolve a palette spec to an arrayref of C<#RRGGBB> strings. C<$spec> is either
a registered name or a comma/slash-separated list of literal colours, so a
preset can inline a one-off palette without registering it.

=cut

sub colors
{
    my ( $spec ) = @_;
    die "GlitchVape::Palette: no palette specified\n"
        unless defined $spec && length $spec;

    if ( my $p = $PALETTE{ lc $spec } )
    {
        return [ @{ $p->{ colors } } ];
    }

    # Inline: "#FF71CE,#01CDFE", "#FF71CE/#01CDFE", or a single "#abc".
    # A leading # or a separator means the caller clearly intended literal
    # colours, so let _normalise_hex report a bad one as a malformed colour
    # rather than misleadingly calling it an unknown palette name.
    if (   $spec =~ /^#/
        || $spec =~ m{[,/]}
        || $spec =~ /^(?:[0-9a-f]{3}|[0-9a-f]{6})$/i )
    {
        my @c = grep { length } split m{\s*[,/]\s*}, $spec;
        @c = map { _normalise_hex( $_ ) } @c;
        return \@c if @c;
    }

    die "GlitchVape::Palette: unknown palette '$spec'. Known: "
        . join( ', ', names() ) . "\n";
}

=head2 duotone( $spec )

Two-colour ramp as C<[$shadow, $highlight]>. Accepts a registered duotone name,
a registered palette name (uses its darkest and lightest), or two inline
colours.

=cut

sub duotone
{
    my ( $spec ) = @_;
    die "GlitchVape::Palette: no duotone specified\n"
        unless defined $spec && length $spec;

    if ( my $d = $DUOTONE{ lc $spec } )
    {
        return [ @$d ];
    }

    my $c = colors( $spec );
    return [ $c->[ 0 ], $c->[ -1 ] ];
}

=head2 title( $name )

Human-readable description, for C<--list-palettes>.

=cut

sub title
{
    my ( $name ) = @_;
    my $p = $PALETTE{ lc( $name // '' ) } or return '';
    return $p->{ title };
}

=head2 gradient_stops( $spec, $steps )

Expand a palette into C<$steps> evenly-spaced C<#RRGGBB> values by linear
interpolation between adjacent entries. This is the luminance map used by the
duotone/gradient-map effect and by HALD CLUT generation.

=cut

sub gradient_stops
{
    my ( $spec, $steps ) = @_;
    $steps ||= 256;

    my $stops = _resolve_colors( $spec );
    my @rgb   = map { [ _hex_to_rgb( $_ ) ] } @$stops;

    # A single-colour palette has no segment to interpolate along, so the ramp
    # is that colour repeated. Falling through would divide by zero below.
    if ( @rgb == 1 )
    {
        return [ ( _rgb_to_hex( @{ $rgb[ 0 ] } ) ) x $steps ];
    }

    my @out;
    my $segments = @rgb - 1;
    for my $i ( 0 .. $steps - 1 )
    {

        # Position along the whole ramp, 0 at the first stop and 1 at the
        # last. A one-step ramp has no span to divide by.
        my $t = 0;
        if ( $steps > 1 )
        {
            $t = $i / ( $steps - 1 );
        }

        my $pos = $t * $segments;
        my $seg = int $pos;
        $seg = $segments - 1 if $seg >= $segments;
        my $f = $pos - $seg;

        my ( $a, $b ) = ( $rgb[ $seg ], $rgb[ $seg + 1 ] );
        push @out,
            _rgb_to_hex(
            map { int( $a->[ $_ ] + ( $b->[ $_ ] - $a->[ $_ ] ) * $f + 0.5 ) }
                0 .. 2 );
    }
    return \@out;
}

=head2 remap_file( $spec, $dir )

Write a 1-pixel-per-colour PNG usable as ImageMagick's C<-remap> argument, and
return its path. Remapping to an explicit swatch image is how we force an
image into a palette exactly, rather than letting C<-colors> pick its own.

=cut

sub remap_file
{
    my ( $spec, $dir ) = @_;
    require GlitchVape::Tools;
    require File::Spec;

    my $colors = _resolve_colors( $spec );
    my $key    = join '_', map { s/^#//r } @$colors;
    my $path   = File::Spec->catfile( $dir, "remap_$key.png" );
    return $path if -f $path;

    my @argv = GlitchVape::Tools::magick_argv( ( map { "xc:$_" } @$colors ),
        '+append', $path, );

    system( @argv ) == 0
        or die "GlitchVape::Palette: failed to build remap image at $path\n";
    return $path;
}

=head2 gradient_file( $spec, $dir, %opt )

Write a 256x1 horizontal gradient PNG for use with C<-clut> (gradient mapping).
Returns its path.

=cut

sub gradient_file
{
    my ( $spec, $dir, %opt ) = @_;
    require GlitchVape::Tools;
    require File::Spec;

    my $steps = $opt{ steps } || 256;
    my $stops = gradient_stops( $spec, $steps );

    # The cache key names every stop plus the step count, so two ramps over the
    # same colours at different resolutions do not collide.
    my $key = join '_', ( map { s/^#//r } @{ _resolve_colors( $spec ) } ),
        $steps;
    my $path = File::Spec->catfile( $dir, "clut_$key.png" );
    return $path if -f $path;

    # Build from the interpolated stops directly: one pixel per step, appended.
    # Writing a PPM by hand avoids a 256-operand command line.
    my $ppm = File::Spec->catfile( $dir, "clut_$key.ppm" );
    open my $fh, '>:raw', $ppm
        or die "GlitchVape::Palette: cannot write $ppm: $!\n";
    print { $fh } "P6\n$steps 1\n255\n";
    print { $fh } pack 'C*', map { _hex_to_rgb( $_ ) } @$stops;

    # A failing close means buffered pixel data never reached the disk, which
    # would leave a silently truncated gradient for ImageMagick to read.
    close $fh or die "GlitchVape::Palette: cannot finish writing $ppm: $!\n";

    system( GlitchVape::Tools::magick_argv( $ppm, $path ) ) == 0
        or die "GlitchVape::Palette: failed to build CLUT at $path\n";
    unlink $ppm;
    return $path;
}

sub _normalise_hex
{
    my ( $c ) = @_;
    $c =~ s/^\s+|\s+$//g;
    $c = "#$c" unless $c =~ /^#/;
    if ( $c =~ /^#([0-9a-f])([0-9a-f])([0-9a-f])$/i )
    {    # #abc -> #aabbcc
        return uc "#$1$1$2$2$3$3";
    }
    die "GlitchVape::Palette: '$c' is not a #RRGGBB colour\n"
        unless $c =~ /^#[0-9a-f]{6}$/i;
    return uc $c;
}

sub _hex_to_rgb
{
    my ( $hex ) = @_;
    $hex = _normalise_hex( $hex );
    return map { hex } $hex =~ /^#(..)(..)(..)$/;
}

sub _rgb_to_hex
{
    my ( $r, $g, $b ) = @_;

    # Interpolation can overshoot either end by a fraction, so clamp each
    # channel back into range before formatting.
    my @clamped;
    for my $channel ( $r, $g, $b )
    {
        if ( $channel < 0 )
        {
            push @clamped, 0;
        }
        elsif ( $channel > 255 )
        {
            push @clamped, 255;
        }
        else
        {
            push @clamped, $channel;
        }
    }

    return sprintf '#%02X%02X%02X', @clamped;
}

# A palette spec is either an arrayref of literal colours or a name to look up.
# Three callers need that distinction, so it lives in one place.
sub _resolve_colors
{
    my ( $spec ) = @_;

    if ( ref $spec eq 'ARRAY' )
    {
        return $spec;
    }

    return colors( $spec );
}

1;
