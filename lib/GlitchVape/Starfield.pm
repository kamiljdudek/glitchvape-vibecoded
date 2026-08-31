package GlitchVape::Starfield;

use strict;
use warnings;

# The ramp below is CP437 rather than ASCII.
use utf8;

our $VERSION = '0.01';

=encoding UTF-8

=head1 NAME

GlitchVape::Starfield - the Norton Commander screensaver, as a function of time

=head1 DESCRIPTION

Norton Commander's Starry Night: a text-mode sky where most stars sit as a dim
C<·> and, every so often, one flares up through a ramp of larger characters,
burns out, and comes back somewhere else. L<GlitchVape::Effect::Overlay>'s
C<stars> effect draws what this works out.

This is the working out and nothing else -- no image, no ImageMagick, no
colours. What comes back is a list of cells and how bright each one is, which
is a thing that can be tested by reading it.

=head1 THE ANIMATION IS THE SAME SKY, LATER

The obvious way to animate a starfield is to roll a new one every frame. That
is not what a screensaver does and it does not look like one: the sky would
have no continuity at all, and what reads as twinkling is precisely that the
stars stay where they are between the moments they do not.

So there is one sky and it is stepped. Frame twelve is the sky after twelve
steps of frame eleven's, and the still is the sky after L</SETTLE> steps --
mid-life rather than freshly seeded, because a sky where nothing has flared
yet is a grid of identical dots.

None of that needs memory between frames, which is just as well, because a
render has none: each frame is drawn on its own and the animated ones may be
drawn in separate processes. The sequence is a I<function> instead. One
stream, drawn from in a fixed order, stepped forward from the beginning every
time -- so the sky at step N is the same sky at step N whoever asks, and
asking for step N+1 gives the sky that follows it.

=head1 WHY THE LOOP DOES NOT CLOSE

It cannot, and it should not pretend to. A star that flares moves, so the sky
at the end of a loop is not the sky at the start; making it so would mean
stars that never move, which is the one thing the screensaver is about.

It joins C<grain>, C<static> and C<dropout> in that -- the effects whose seam
is invisible because every frame is already unlike the one before it. Here it
is invisible for a slightly better reason: a handful of stars are somewhere
else at the join, and a handful of stars are somewhere else at every other
frame too.

=cut

# The six characters the screensaver twinkled through, dimmest first. Kept
# here rather than in GlitchVape::VGA's charsets because this is a ramp and
# not a set: index 0 is a resting star and the rest are one flare, in order.
my @RAMP = ( '·', '∙', '•', '◆', '■', '☼' );

=head2 ramp()

The characters, dimmest first.

=cut

sub ramp { return @RAMP }

=head2 SETTLE

How many steps a sky is run through before anybody sees it. Two hundred is
enough that the flares are in progress rather than about to begin, at every
pace the effect offers.

=cut

use constant SETTLE => 200;

=head2 sky( %arg )

    rng      => a GlitchVape::Random stream
    columns  => cells across
    rows     => cells down
    stars    => how many stars there are
    flare    => how many begin to flare per step, on average
    step     => which step to return, counted from the settled sky

Returns C<< [ [ $column, $row, $brightness ], ... ] >>, where C<$brightness>
indexes L</ramp()>: 0 for a star at rest and 1 upwards for one part way
through a flare.

=cut

sub sky
{
    my ( %arg ) = @_;

    my $rng     = $arg{ rng };
    my $columns = $arg{ columns };
    my $rows    = $arg{ rows };
    my $stars   = $arg{ stars };

    return [] unless $rng && $columns > 0 && $rows > 0 && $stars > 0;

    my @x = map { $rng->int_between( 0, $columns - 1 ) } 1 .. $stars;
    my @y = map { $rng->int_between( 0, $rows - 1 ) } 1 .. $stars;

    # Only the stars actually flaring, so a step costs what is happening
    # rather than what exists: a sky of two thousand stars with three of them
    # alight is three stars' worth of work, and frame two hundred is two
    # hundred of those.
    my %flaring;

    for my $step ( 1 .. SETTLE + ( $arg{ step } || 0 ) )
    {
        # Sorted, and it matters. Hash order is randomised per process, so
        # walking the keys unsorted would draw from the stream in a different
        # order in every run and the same seed would give a different sky.
        for my $star ( sort { $a <=> $b } keys %flaring )
        {
            my $at = ++$flaring{ $star }[ 0 ];
            next if $at <= $flaring{ $star }[ 1 ];

            # Burnt out. Back as a resting star, somewhere else -- which is
            # the whole of why this cannot be made to loop.
            delete $flaring{ $star };
            $x[ $star ] = $rng->int_between( 0, $columns - 1 );
            $y[ $star ] = $rng->int_between( 0, $rows - 1 );
        }

        _ignite( $rng, \%flaring, $stars, $arg{ flare } );
    }

    return [
        map { [ $x[ $_ ], $y[ $_ ], $flaring{ $_ } ? $flaring{ $_ }[ 0 ] : 0 ] }
            0 .. $stars - 1
    ];
}

# However many stars begin to flare this step. A fractional rate is a whole
# number most steps and one more on some of them, which is what lets the pace
# be slower than one a step -- and slower than one a step is the pace the
# thing is actually set at.
sub _ignite
{
    my ( $rng, $flaring, $stars, $rate ) = @_;

    $rate = 0 unless $rate && $rate > 0;

    my $whole = int $rate;
    my $count = $whole + ( $rng->chance( $rate - $whole ) ? 1 : 0 );

    for my $again ( 1 .. $count )
    {
        my $star = $rng->int_between( 0, $stars - 1 );

        # Already alight. Left alone rather than restarted, which is what
        # keeps two flares from being one long one and holds the number
        # burning at once down to something a sky can be read through.
        next if $flaring->{ $star };

        $flaring->{ $star } = [ 1, $rng->int_between( 1, $#RAMP ) ];
    }

    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::VGA>, whose font the sky is drawn in, and
L<GlitchVape::Effect::Overlay> for the effect that draws it.

The algorithm is an artist's impression of Norton Commander 4 and 5's Starry
Night screensaver, following the Go implementation at
L<https://github.com/ivanmilov/ncscr> -- the same ramp, the same idea of a
star flaring for a random part of it and coming back elsewhere.

=cut
