package GlitchVape::Defrag;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Defrag - the cluster map from the 1995 disk defragmenter

=head1 DESCRIPTION

A grid of small blocks, each one a cluster of the disk, each painted in the
colour of what is in it. The colours and the anatomy of one block are here;
the effect that decides I<which> block goes where is C<defrag> in
L<GlitchVape::Effect::Texture>.

=head1 WHAT A BLOCK IS

Measured off a screenshot, and it is three things rather than one: a black
outline a pixel thick, an interior of two colours in a checkerboard, and a
pixel of paper along the right and the bottom that separates it from the next
one. At the size it was drawn -- eight pixels of pitch -- that leaves five
pixels of interior, which is where the checkerboard is visible at all.

The checkerboard is not decoration. A 1995 display had sixteen colours, and
every colour between them was made by dithering two of them at fifty per cent;
a solid fill of a colour that palette did not have was not available. So the
blocks that read as one colour in a screenshot are two, and rendering them
flat is the single change that makes this look drawn rather than remembered.

Below about seven pixels of pitch there is no interior left to dither and the
outline is most of the block, so both drop away by size rather than by
setting: an outline that is half the block is a black square.

=head1 EMPTY IS EMPTY

Free space is not a state with a colour. It is the paper, with nothing drawn
on it at all -- no block, no outline, no gap. That is what gives the real
thing its character: most of a freshly defragmented disk is a white field with
the data packed into one corner, and a map that filled every cell with
something would be a mosaic rather than a disk.

=head1 THE STATES

Nine of these were on the legend of the window this comes from. The rest are
invented, and are meant to be: a disk has more going on than nine colours can
say, and the point of the grid is that a glance at it tells you what kind of
mess the disk is in. They are named for what they would mean rather than for
what colour they are, so a palette can change every one of them without any of
the names going wrong.

=head1 THE PALETTES

C<defrag> and C<scandisk> are tables, because a sixteen-colour palette is a
list of sixteen colours and there is no rule to derive it from. The three
after them are one rule instead: a state's distance from the paper is how far
its colour in C<defrag> was from white. On white paper that gives a grey ramp
with free space still white; on black paper it gives a phosphor screen where
the more there is in a cluster the brighter it glows. The same sentence covers
both, which is why it is a rule and not three more tables.

Derived palettes are flat rather than dithered. A checkerboard of two colours
is what a sixteen-colour display did to make a seventeenth, and a phosphor
monitor had no such problem to solve.

=cut

# The sixteen, so that the tables below are a list of names rather than a list
# of hex and nobody has to take on trust that 0x008080 is the teal Windows
# actually used.
my %VGA = (
    black   => [ 0,   0,   0 ],
    navy    => [ 0,   0,   128 ],
    green   => [ 0,   128, 0 ],
    teal    => [ 0,   128, 128 ],
    maroon  => [ 128, 0,   0 ],
    purple  => [ 128, 0,   128 ],
    olive   => [ 128, 128, 0 ],
    silver  => [ 192, 192, 192 ],
    grey    => [ 128, 128, 128 ],
    blue    => [ 0,   0,   255 ],
    lime    => [ 0,   255, 0 ],
    cyan    => [ 0,   255, 255 ],
    red     => [ 255, 0,   0 ],
    magenta => [ 255, 0,   255 ],
    yellow  => [ 255, 255, 0 ],
    white   => [ 255, 255, 255 ],
);

# Each state as the one or two inks it is drawn in. Two means a fifty per cent
# checkerboard of them, which is how the display made a colour it did not
# have; one means the palette had it.
#
# The first eight were on the legend. The six after them were not, and say so.
my @STATE = (
    [ optimised => 'navy', 'blue' ],       # defragmented data
    [ start     => 'teal', 'cyan' ],       # belongs at the beginning
    [ middle    => 'teal' ],               # belongs in the middle
    [ finish    => 'grey',   'black' ],    # belongs at the end
    [ fixed     => 'silver', 'white' ],    # will not be moved
    [ bad       => 'maroon', 'grey' ],     # damaged
    [ reading   => 'lime' ],               # being read
    [ writing   => 'red' ],                # being written

    # Invented, in the same idiom: things a disk of the period did that the
    # legend had no room for.
    [ swap       => 'magenta', 'purple' ],    # the swap file
    [ system     => 'olive',   'yellow' ],    # system files
    [ hidden     => 'purple',  'navy' ],      # hidden files
    [ compressed => 'cyan',    'white' ],     # a compressed volume's clusters
    [ verifying  => 'yellow',  'white' ],     # written and being read back
    [ locked     => 'teal',    'black' ],     # held open by something else
);

# The two tables. 'edge' is the outline every block gets, or undef for a
# palette that should not have one -- see L</THE PALETTES>.
my %TABLE = (
    defrag => {
        paper => 'white',
        edge  => 'black',
        ink   => { map { $_->[ 0 ] => [ @{ $_ }[ 1 .. $#$_ ] ] } @STATE },
    },

    # What ScanDisk's surface scan looked like: the same grid with most of the
    # hue taken out of it, because what it was reporting was one question with
    # a yes and a no rather than eight kinds of file.
    scandisk => {
        paper => 'white',
        edge  => 'black',
        ink   => {
            optimised  => [ 'navy',   'blue' ],
            start      => [ 'silver', 'white' ],
            middle     => [ 'silver' ],
            finish     => [ 'grey' ],
            fixed      => [ 'silver', 'grey' ],
            bad        => [ 'red' ],
            reading    => [ 'navy',   'teal' ],
            writing    => [ 'blue',   'cyan' ],
            swap       => [ 'grey',   'silver' ],
            system     => [ 'navy',   'grey' ],
            hidden     => [ 'grey',   'black' ],
            compressed => [ 'silver', 'cyan' ],
            verifying  => [ 'cyan' ],
            locked     => [ 'maroon', 'grey' ],
        },
    },
);

# The rule the other three are. Paper first, then the ink a state is dragged
# towards in proportion to how dark it was in 'defrag'.
my %RAMP = (
    mono  => [ [ 255, 255, 255 ], [ 0,   0,   0 ] ],
    amber => [ [ 0,   0,   0 ],   [ 255, 176, 0 ] ],
    phos  => [ [ 0,   0,   0 ],   [ 65,  255, 110 ] ],
);

=head2 palettes()

The palette names, in the order they should be offered.

=cut

sub palettes { return ( qw(defrag scandisk), sort keys %RAMP ) }

=head2 states()

The state names, in the order they are declared -- which is the order the
legend had them in, with the invented ones after.

=cut

sub states
{
    return map { $_->[ 0 ] } @STATE;
}

=head2 map_for( $palette )

    {
        paper  => [ $r, $g, $b ],
        edge   => [ $r, $g, $b ] or undef,
        states => [ { name, a, b, avg }, ... ],
    }

One palette resolved to numbers. C<a> and C<b> are the two inks a block is
chequered from, C<b> undef where the palette had the colour outright, and
C<avg> is what the two come to at a distance -- which is the colour a picture
is matched against, since it is the one an eye sees.

An unknown name is C<defrag> rather than an error, because a preset is a file
and a file can outlive the version that wrote it.

=cut

sub map_for
{
    my ( $name ) = @_;

    $name = 'defrag' unless defined $name;

    return _table( $TABLE{ $name } )    if $TABLE{ $name };
    return _ramp( @{ $RAMP{ $name } } ) if $RAMP{ $name };

    return _table( $TABLE{ defrag } );
}

sub _table
{
    my ( $spec ) = @_;

    my @out;
    for my $state ( @STATE )
    {
        my $inks = $spec->{ ink }{ $state->[ 0 ] } or next;

        my $a = $VGA{ $inks->[ 0 ] };
        my $b = defined $inks->[ 1 ] ? $VGA{ $inks->[ 1 ] } : undef;

        push @out,
            {
            name => $state->[ 0 ],
            a    => $a,
            b    => $b,
            avg  => $b
            ? [ map { int( ( $a->[ $_ ] + $b->[ $_ ] ) / 2 ) } 0 .. 2 ]
            : [ @$a ],
            };
    }

    return {
        paper  => $VGA{ $spec->{ paper } },
        edge   => defined $spec->{ edge } ? $VGA{ $spec->{ edge } } : undef,
        states => \@out,
    };
}

sub _ramp
{
    my ( $paper, $ink ) = @_;

    my $table = _table( $TABLE{ defrag } );

    my @out;
    for my $state ( @{ $table->{ states } } )
    {
        # How far from white the same state was on a sixteen-colour display,
        # which is the only thing carried across: what a cluster is stays the
        # same, and only what the screen can say about it changes.
        my $t = 1 - _luma( $state->{ avg } ) / 255;

        my $rgb = [
            map {
                int( $paper->[ $_ ] + ( $ink->[ $_ ] - $paper->[ $_ ] ) * $t )
            } 0 .. 2
        ];

        push @out,
            {
            name => $state->{ name },
            a    => $rgb,
            b    => undef,
            avg  => [ @$rgb ]
            };
    }

    # No outline: a checkerboard and a black edge are both things a
    # sixteen-colour display did to make up for what it did not have.
    return { paper => [ @$paper ], edge => undef, states => \@out };
}

sub _luma
{
    my ( $rgb ) = @_;
    return 0.299 * $rgb->[ 0 ] + 0.587 * $rgb->[ 1 ] + 0.114 * $rgb->[ 2 ];
}

=head2 unit( $block )

The pixel the block is drawn in, at that pitch.

A pitch of eight is the size this came off a screen at, and there every part of
a block is one pixel: one of gap, one of outline, one square of the chequer.
Above that the whole design is replicated rather than redrawn -- a pitch of
sixteen is the same block with every pixel doubled, outline and chequer
included, not a bigger block with a hairline round it.

That is the same rule L<GlitchVape::Chicago> follows and for the same reason:
an interpolated one-pixel outline is a grey smear, and a chequer whose squares
have been averaged together is a flat fill of the colour it was supposed to be
making.

=cut

sub unit
{
    my ( $block ) = @_;

    my $unit = int( $block / 8 );
    return $unit > 1 ? $unit : 1;
}

=head2 stamp( %arg )

    state  => one entry from map_for's states, or undef for free space
    block  => the pitch, in pixels
    paper  => the palette's paper
    edge   => its outline, or undef

One cell, as C<$block> rows of C<$block * 3> bytes: the block itself, its
outline if there is room for one, and the paper that separates it from its
neighbours. Ready to be written straight into a L<GlitchVape::Pixels> buffer,
because a cluster map is tens of thousands of cells and drawing each one
through ImageMagick would be tens of thousands of subprocess-free but
still-per-call operations.

C<state> undef gives a cell of bare paper, which is what free space is.

=cut

# Both in the pixels the block is designed in rather than the ones it is drawn
# at, so a pitch that is an enlargement of the design keeps whatever the design
# had. Below seven there is no interior left to chequer once the outline has
# taken a pixel off each side; below five the outline is most of the block,
# which is a black square rather than a cluster.
use constant DITHER_MIN => 7;
use constant EDGE_MIN   => 5;

sub stamp
{
    my ( %arg ) = @_;

    my $n     = $arg{ block };
    my $paper = pack 'C3', @{ $arg{ paper } };

    return $paper x ( $n * $n ) unless $arg{ state };

    my $unit = unit( $n );
    my $size = $n - $unit;

    # How big the block is in its own pixels, which is what decides whether
    # there is room for each part of it.
    my $design = int( $size / $unit );

    my $edge  = $arg{ edge } && $design >= EDGE_MIN ? $arg{ edge } : undef;
    my $inner = $edge                               ? $unit        : 0;

    my $a = pack 'C3', @{ $arg{ state }{ a } };
    my $b =
        $arg{ state }{ b } && $design >= DITHER_MIN
        ? pack 'C3', @{ $arg{ state }{ b } }
        : $a;

    my $rim = $edge ? pack 'C3', @$edge : $a;

    my $out = q{};

    for my $y ( 0 .. $n - 1 )
    {
        for my $x ( 0 .. $n - 1 )
        {
            if ( $x >= $size || $y >= $size )
            {
                $out .= $paper;
            }
            elsif (
                $inner
                && (   $x < $inner
                    || $y < $inner
                    || $x >= $size - $inner
                    || $y >= $size - $inner )
                )
            {
                $out .= $rim;
            }
            else
            {
                # The chequer is squares of the design's pixel, not of the
                # image's, or enlarging the block turns the dither into a fine
                # grain that averages to one colour at any distance.
                $out .=
                    ( int( $x / $unit ) + int( $y / $unit ) ) % 2
                    ? $b
                    : $a;
            }
        }
    }

    return $out;
}

=head2 nearest( $states, $rgb )

Which state a colour is closest to, as an index into C<$states>.

Weighted the way the eye is rather than by plain distance in RGB, because the
grid is being asked to stand in for a photograph: green carries most of what a
picture looks like and blue carries least, so a match that treated the three
channels alike would send half a face to whichever colour happened to be
nearest it in arithmetic.

Two, four and three, which is the usual cheap approximation. Not two, four and
one: that is the same approximation with the blue taken further down, and on
this palette it makes the two blues -- which are the colours anyone looking at
a defragmenter is expecting -- nearly unreachable.

=cut

sub nearest
{
    my ( $states, $rgb ) = @_;

    my ( $best, $at ) = ( undef, 0 );

    for my $i ( 0 .. $#$states )
    {
        my $avg = $states->[ $i ]{ avg };

        my $d =
            2 * ( $rgb->[ 0 ] - $avg->[ 0 ] )**2 +
            4 * ( $rgb->[ 1 ] - $avg->[ 1 ] )**2 +
            3 * ( $rgb->[ 2 ] - $avg->[ 2 ] )**2;

        ( $best, $at ) = ( $d, $i ) if !defined $best || $d < $best;
    }

    return $at;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Effect::Texture> for the C<defrag> effect this draws for,
L<GlitchVape::Chicago> for the window the same screenshot's chrome came off,
and L<GlitchVape::Pixels> for the buffer the stamps are written into.

=cut
