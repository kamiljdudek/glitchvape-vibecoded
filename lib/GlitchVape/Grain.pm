package GlitchVape::Grain;

use strict;
use warnings;

use File::Spec ();

use GlitchVape::Paths  ();
use GlitchVape::Pixels ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Grain - film grain's arithmetic, in Perl and in C

=head1 SYNOPSIS

    GlitchVape::Grain::pixels( $rng, $px, $sd, $bias, $mono );
    my $bytes = GlitchVape::Grain::cells( $rng, $count, $sd, $mono );

    print GlitchVape::Grain::status(), "\n";

=head1 DESCRIPTION

C<grain> is the one effect that does arithmetic on every pixel of a full-size
picture in Perl: a gaussian per pixel or per channel -- eight million of them
at 1920 pixels -- each drawn by the polar method from L<GlitchVape::Random>'s
xorshift, scaled for the shadows and added. Everything else that touches every
pixel hands the work to ImageMagick.

So it is written twice. Once in Perl, below, which is the reference: what a
seed means is decided here. And once in C, in F<xs/grain.c>, which has to give
the same bytes from the same seed and leave the generator exactly where the
Perl would have left it -- not a faster grain but the same one, two to three
hundred times sooner on one core: a 720-pixel preview in one or two
milliseconds rather than a third to a half of a second. This module decides
which one runs, call by call, and nothing calling it can tell them apart
except by the clock.

=head1 THE SAME NUMBERS

"The same" is meant to the bit, and F<t/56-grain-c.t> holds the C to it: every
gaussian compared as a double, every byte of grained pictures in both modes,
with and without a shadow bias, at sizes that leave a ragged last vector, with
a spare carried in, and the generator's state and spare compared after each.

That rules out most of what makes floating-point code fast, and F<xs/grain.c>
says what and why. The short form: no fused multiply-add, nothing from
C<-ffast-math>, and glibc's scalar C<log> -- the one Perl calls -- rather than
a vector one, because a vector C<log> rounds differently and one bit of
difference in a draw near the polar method's boundary changes every number
after it. What is left to go faster with is doing the same arithmetic many at
a time, which is what the C is.

=head1 WHEN THE PERL RUNS

=over

=item * When nothing was compiled. Only an x86-64 build makes the library
-- C<make xs>, which C<make test> and both packagings run -- and a checkout
uses only what was built in its own F<build/>, never an installed copy.

=item * When the CPU predates x86-64-v3: AVX2, BMI2 and FMA, which is Intel's
Haswell (2013) and AMD's Excavator (2015) onwards, though Pentium, Celeron and
Atom parts went without AVX2 for years after that. The library is built for
nothing older, and asks the CPU before anything that needs it runs.

=item * When C<GLITCHVAPE_PURE_PERL> is set to something true. That is for
ruling the C out -- a bug report that names a seed can be rendered both ways
in two commands -- and for timing one against the other.

=back

C<glitchvape --check-deps> says which of the two is in use, and why.

=cut

# Resolved once, at load, because __FILE__ is relative when the module was
# found through a relative -I, and the test suite chdirs afterwards.
my $FILE = File::Spec->rel2abs( __FILE__ );

# Where `make xs` leaves the library in a checkout: build/, because nothing a
# build makes goes anywhere else.
( my $CHECKOUT = $FILE ) =~ s{/lib/GlitchVape/Grain\.pm\z}{};
my $BUILT = File::Spec->catdir( $CHECKOUT, 'build', 'xs' );

my $loaded;    # undef until tried
my $why;       # why not, once it has been tried and failed

sub _load
{
    return $loaded if defined $loaded;
    $loaded = 0;

    # A checkout loads its own build or nothing. Falling through to @INC
    # would find an installed package's copy whenever this one had not been
    # built, and run C that this tree's Perl is not the reference for.
    my $checkout = !length GlitchVape::Paths::DATADIR;
    if ( $checkout
        && !-f File::Spec->catfile( $BUILT, qw(auto GlitchVape Grain Grain.so) )
        )
    {
        $why = 'nothing was compiled in this checkout';
        return 0;
    }

    my $ok = do
    {
        local $@;
        my $done = eval {
            require XSLoader;
            local @INC = ( ( $checkout ? $BUILT : () ), @INC );
            XSLoader::load( __PACKAGE__, $VERSION );
            1;
        };
        $why = $@ unless $done;
        $done;
    };

    if ( !$ok )
    {
        # The first line says it; the rest is @INC.
        ( $why ) = split /\n/, $why || 'it would not load';
        $why = 'nothing was compiled for this machine'
            if $why =~ /\ACan't locate loadable object/;
        return 0;
    }

    if ( !_cpu_ok() )
    {
        $why = 'this CPU predates x86-64-v3 (AVX2, BMI2, FMA)';
        return 0;
    }

    return $loaded = 1;
}

sub _switched_off
{
    return $ENV{ GLITCHVAPE_PURE_PERL };
}

=head2 compiled()

True when the next call will run the C.

=cut

sub compiled
{
    return 0 if _switched_off();
    return _load();
}

=head2 status()

One line on which of the two runs here, and why: what C<--check-deps> prints.

=cut

sub status
{
    return 'Perl, because GLITCHVAPE_PURE_PERL is set' if _switched_off();

    if ( _load() )
    {
        my $how = _path() eq 'gfni' ? 'GFNI' : 'lookup tables';
        return "compiled for x86-64-v3, its generator stepped by $how";
    }

    return "Perl, because $why";
}

=head2 pixels( $rng, $px, $sd, $bias, $mono )

Grains a L<GlitchVape::Pixels> buffer in place, drawing from C<$rng>: one
gaussian of standard deviation C<$sd> per channel, or per pixel with C<$mono>,
each scaled down by C<$bias> times the pixel's luma before it is added.

=cut

sub pixels
{
    my ( $rng, $px, $sd, $bias, $mono ) = @_;

    if ( compiled() )
    {
        _pixels( $rng, $px->{ data },
            $px->width, $px->height, $sd, $bias, $mono );
        return;
    }

    _perl_pixels( $rng, $px, $sd, $bias, $mono );
    return;
}

=head2 cells( $rng, $count, $sd, $mono )

C<$count> cells of grain around mid-grey, three bytes a cell -- the noise
C<grain> lays over the picture when its grains are bigger than a pixel.

=cut

sub cells
{
    my ( $rng, $count, $sd, $mono ) = @_;

    return _cells( $rng, $count, $sd, $mono ) if compiled();
    return _perl_cells( $rng, $count, $sd, $mono );
}

# ---------------------------------------------------------------------------
# The reference
#
# Written for the one loop in the program that runs once per pixel of a
# full-size picture: a row's noise drawn in one call rather than a method call
# per value, and the luma and the clamp spelled out rather than called. Each
# is the same arithmetic in the same order as GlitchVape::Pixels::luma and
# ::clamp, so a seed grains exactly as it always has.

sub _perl_pixels
{
    my ( $rng, $px, $sd, $bias, $mono ) = @_;

    $px->each_row(
        sub {
            my ( undef, $row ) = @_;
            my @v = unpack 'C*', $row;

            my @noise = $rng->gauss_list( $mono ? @v / 3 : scalar @v, 0, $sd );
            my $k     = 0;

            for ( my $i = 0 ; $i < @v ; $i += 3 )
            {
                my $scale = 1;
                if ( $bias )
                {
                    my $luma =
                        ( 0.299 * $v[ $i ] +
                            0.587 * $v[ $i + 1 ] +
                            0.114 * $v[ $i + 2 ] ) / 255;
                    $scale = 1 - $bias * $luma;
                }

                if ( $mono )
                {
                    my $n = $noise[ $k++ ] * $scale;
                    for my $j ( $i .. $i + 2 )
                    {
                        my $t = $v[ $j ] + $n;
                        $v[ $j ] =
                              $t < 0   ? 0
                            : $t > 255 ? 255
                            :            int $t;
                    }
                }
                else
                {
                    for my $j ( $i .. $i + 2 )
                    {
                        my $t = $v[ $j ] + $noise[ $k++ ] * $scale;
                        $v[ $j ] =
                              $t < 0   ? 0
                            : $t > 255 ? 255
                            :            int $t;
                    }
                }
            }

            return pack 'C*', @v;
        }
    );
    return;
}

# Mid-grey is the identity for the HardLight composite the cells go under, so
# the noise is generated around 128 rather than around zero.
sub _perl_cells
{
    my ( $rng, $count, $sd, $mono ) = @_;
    my $bytes = '';

    for ( 1 .. $count )
    {
        if ( $mono )
        {
            my $v = GlitchVape::Pixels::clamp( 128 + $rng->gauss( 0, $sd ) );
            $bytes .= pack 'C3', $v, $v, $v;
        }
        else
        {
            $bytes .= pack 'C3',
                map { GlitchVape::Pixels::clamp( 128 + $rng->gauss( 0, $sd ) ) }
                1 .. 3;
        }
    }

    return $bytes;
}

1;

__END__

=head1 THE BUILD

F<xs/grain.c> is C23 for GCC 14 or later, compiled at C<-O3> for
C<-march=x86-64-v3> with every flag that does not change a value;
F<xs/Grain.xs> is the glue, compiled with perl's own flags for the baseline
every x86-64 machine runs, since it is what asks the CPU. C<make xs> builds
both into F<build/xs>, and C<make xs PGO=1> builds the kernel twice, training
it on F<xs/train.c> in between. The Makefile says which flags and why.

=head1 SEE ALSO

L<GlitchVape::Random>, whose C<gauss_list> the C draws as; F<xs/grain.c>;
F<t/56-grain-c.t>.

=cut
