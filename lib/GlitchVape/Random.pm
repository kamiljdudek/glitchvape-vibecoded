package GlitchVape::Random;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Random - seeded, portable PRNG for reproducible glitches

=head1 DESCRIPTION

Every effect draws its randomness from one of these. Perl's builtin C<rand> is
process-global and its sequence is not guaranteed stable across perl builds,
which would make C<--seed> a lie. This is a plain xorshift32: same seed, same
image, on any machine.

=cut

# Distinct non-zero constant used whenever the state would otherwise collapse.
use constant _RESCUE => 0x1D872B41;
use constant _2POW32 => 4_294_967_296;

sub new
{
    my ( $class, %arg ) = @_;

    my $seed = $arg{ seed };
    $seed = int( rand( 2**31 ) ) unless defined $seed && length $seed;

    # Accept arbitrary strings as seeds so `--seed mallsoft` works.
    $seed = _hash_string( $seed ) if $seed =~ /\D/;

    my $self = bless {
        seed  => $seed,
        state => ( $seed & 0xFFFFFFFF ) || _RESCUE,
    }, $class;

    # xorshift is poor for the first few draws from a small seed.
    $self->_next32 for 1 .. 8;

    return $self;
}

sub seed { $_[ 0 ]{ seed } }

# A child stream derived from this one. Lets an effect take its own
# independent sequence without disturbing the caller's, so adding an effect
# to a preset does not reshuffle every effect after it.
sub derive
{
    my ( $self, $label ) = @_;
    return
        ref( $self )
        ->new( seed => $self->{ seed } ^ _hash_string( $label // '' ) );
}

sub _hash_string
{
    my ( $str ) = @_;

    # FNV-1a, 32-bit. Both constants are written exactly as the specification
    # gives them so they can be checked against it by eye; splitting the prime
    # into 0x0100_0193 would make it harder to verify, not easier.
    my $h = 0x811C9DC5;    # offset basis
    for my $c ( unpack 'C*', $str )
    {
        $h ^= $c;
        $h = ( $h * 0x01000193 ) & 0xFFFFFFFF;    ## no critic (RequireNumberSeparators)
    }
    return $h;
}

sub _next32
{
    my $self = shift;
    my $x    = $self->{ state };
    $x ^= ( $x << 13 ) & 0xFFFFFFFF;
    $x ^= ( $x >> 17 );
    $x ^= ( $x << 5 ) & 0xFFFFFFFF;
    $x &= 0xFFFFFFFF;
    $x ||= _RESCUE;
    return $self->{ state } = $x;
}

=head2 rand( [$max] )

Float in C<[0, $max)>, defaulting to C<[0,1)>.

=cut

sub rand
{
    my ( $self, $max ) = @_;
    $max = 1 unless defined $max;
    return $self->_next32 / _2POW32 * $max;
}

=head2 between( $lo, $hi )

Float in C<[$lo, $hi)>.

=cut

sub between
{
    my ( $self, $lo, $hi ) = @_;
    return $lo + $self->rand( $hi - $lo );
}

=head2 int_between( $lo, $hi )

Integer in C<[$lo, $hi]>, inclusive at both ends.

=cut

sub int_between
{
    my ( $self, $lo, $hi ) = @_;
    return $lo if $hi <= $lo;
    return $lo + int( $self->rand( $hi - $lo + 1 ) );
}

=head2 chance( $p )

True with probability C<$p>.

=cut

sub chance
{
    my ( $self, $p ) = @_;
    return $self->rand < $p;
}

=head2 pick( @list )

One element, uniformly.

=cut

sub pick
{
    my ( $self, @list ) = @_;
    return unless @list;
    return $list[ int( $self->rand( scalar @list ) ) ];
}

=head2 shuffle( @list )

Fisher-Yates, using this stream.

=cut

sub shuffle
{
    my ( $self, @list ) = @_;
    for ( my $i = @list - 1 ; $i > 0 ; $i-- )
    {
        my $j = int( $self->rand( $i + 1 ) );
        @list[ $i, $j ] = @list[ $j, $i ];
    }
    return @list;
}

=head2 gauss( [$mean], [$sd] )

Normal deviate via Box-Muller. Grain looks wrong with uniform noise.

=cut

sub gauss
{
    my ( $self, $mean, $sd ) = @_;
    $mean = 0 unless defined $mean;
    $sd   = 1 unless defined $sd;

    if ( defined $self->{ _spare } )
    {
        my $s = delete $self->{ _spare };
        return $mean + $sd * $s;
    }

    my ( $u, $v, $s );
    do
    {
        $u = $self->rand( 2 ) - 1;
        $v = $self->rand( 2 ) - 1;
        $s = $u * $u + $v * $v;
    } while ( $s >= 1 || $s == 0 );

    my $f = sqrt( -2 * log( $s ) / $s );
    $self->{ _spare } = $v * $f;
    return $mean + $sd * $u * $f;
}

=head2 walk( $n, %opt )

C<$n> values of a bounded random walk in C<[min,max]>, starting at C<start>.
Used for tape wobble and per-frame drift, where independent draws would just
look like noise -- real tape error is correlated frame to frame.

=cut

sub walk
{
    my ( $self, $n, %opt ) = @_;
    my $step = $opt{ step }  // 0.1;
    my $min  = $opt{ min }   // -1;
    my $max  = $opt{ max }   // 1;
    my $cur  = $opt{ start } // 0;

    my @out;
    for ( 1 .. $n )
    {
        $cur += $self->gauss( 0, $step );
        $cur = $min if $cur < $min;
        $cur = $max if $cur > $max;
        push @out, $cur;
    }
    return @out;
}

1;
