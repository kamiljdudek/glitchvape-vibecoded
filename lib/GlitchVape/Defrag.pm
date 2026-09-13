package GlitchVape::Defrag;

use strict;
use warnings;

use GlitchVape::Palette ();

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
one.

And it is a I<rectangle>, not a square. The grid is eight pixels across and
ten down, which leaves a block of seven by nine and an interior of five by
seven. That is the first thing the eye picks up about the real window and the
easiest thing to get wrong, because square is what "a grid of small blocks"
sounds like -- so the proportion is kept whatever C<block> is set to rather
than being a size anyone can get wrong.

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
list of sixteen colours and there is no rule to derive it from. Everything
after them is one rule instead: a state's distance from the paper is how far
its colour in C<defrag> was from white, and the colour it lands on is that far
along a ramp. On white paper going to black that gives a grey wash with free
space still white; on black paper going to green it gives a phosphor screen
where the more there is in a cluster the brighter it glows. The same sentence
covers both, which is why it is a rule and not a table each.

Which means any ramp will do, and the program already has twenty of them --
so C<palettes()> ends with everything L<GlitchVape::Palette> has, and a
cluster map can be drawn in the Game Boy's four greens or the C64's sixteen
without a line here naming either. What a borrowed palette does I<not> bring
is its paper: see below.

Derived palettes are flat rather than dithered. A checkerboard of two colours
is what a sixteen-colour display did to make a seventeenth, and a ramp has
every colour it wants.

=head1 PAPER IS WHITE, AND WHY THAT IS THE GOAL

Free space is the paper and most of that window always was free space, so the
paper is not one colour among fifteen -- it is the ground the whole picture is
read against, and getting it wrong costs more than getting any block wrong.
White is what it was, and white is what makes a scattering of blocks read as a
disk rather than as a mosaic on a coloured tile.

So a borrowed palette is spent on the clusters and not on the ground. Its
colours are somebody's choice of five or sixteen for something else, and
handing the darkest of them to the paper turns every scheme into a picture of
a lit screen -- which is a good-looking thing and the wrong thing, because
there were nineteen of them and one window. Sorted brightest first, the same
palette instead gives the window in that scheme's colours, and the ramp still
runs the way both tables do: the more there is in a cluster, the darker it is.

The exceptions are C<amber> and C<phos>, and they earn it by not being
windows. Each is a phosphor monitor -- an ink and the dark it glows out of --
where free space is the screen with nothing lit on it, and a white ground
would be the one thing such a display could not do. That is why the three
written down here carry their own paper as their first stop and the borrowed
ones do not: naming your paper is what it takes to have one.

The outline follows from the paper rather than being a choice beside it. On
paper a block needs an edge to be a block: the palest states sit a shade off
the ground and without a rim they are free space with a tint. On a screen the
block is the lit thing and a black ring round it is a hole in the glow. So
C<map_for> gives an outline to every scheme whose paper is lit and none to the
schemes whose paper is dark, and no scheme has to say which it is.

=head1 WHY THE TABLES ARE SPREAD OUT

Both tables are doing two jobs at once, and each one constrains them.

A cluster's colour is chosen by matching the picture under it, so two states
close together in colour are one state as far as the picture is concerned:
whichever L</nearest( $states, $rgb )> reaches first wins every time and the
other is a legend entry that never appears. That is a thing to check rather
than to eyeball -- C<scandisk> shipped with two states drawn in exactly the
same grey, written as C<silver, grey> in one place and C<grey, silver> in the
other, and nothing about the picture said so.

And every derived palette reads C<defrag> -- only that one -- as a I<ramp
position>, so two states close together in brightness there come out the same
colour in every one of them whatever their hue was here. C<writing> and
C<swap> were a bright red and a bright magenta, as far apart as that palette
goes, and two and a half levels apart in brightness: in C<mono> they were the
same grey.

So C<defrag>'s fourteen are spread twice over -- no two within ninety of each
other in the weighted distance L</nearest( $states, $rgb )> measures, and no
two within ten levels of brightness -- and C<scandisk>'s only once, since
nothing reads it as a ramp.

What is I<not> free either way is the hue. C<optimised> is the deep blue that
half of that window always was, the three C<belongs at> states are three tones
of one teal because they are three answers to one question, and the two that
mean something is happening now are the bright red and the bright green. The
spreading happens in what is left over, which is why the six invented states
carry most of it.

=head1 WHY THE ERROR IS CARRIED

Fourteen states is a small palette and a photograph is not spread evenly
through colour space, so matching each cell on its own puts most of the
picture on whichever state happens to sit in the middle of it: measured on an
ordinary photograph, five of the fourteen appeared at all and one of them took
sixty-four per cent of the grid. That is not a palette of fourteen. It is a
palette of three with a legend of fourteen, and no amount of choosing better
colours fixes it, because the problem is that each cell is rounded in
ignorance of the one beside it.

Carrying the error is the ordinary answer and it is the right one here twice
over. At three quarters the same photograph reaches nine states with the
largest under a half, and a second one goes from eight states with one at
eighty-four per cent to eleven with the largest at forty-six -- so the picture
comes back. And what it looks like is a disk whose clusters are shuffled
together rather than sorted into continents, which is the thing the window is
actually about. A dithered cluster map reads as a I<fragmented> one.

It is done here rather than by handing ImageMagick a swatch and asking for a
remap, because ImageMagick would diffuse in its own idea of colour distance
and this program has its own -- two, four and three, weighted the way the eye
is. A dither that walked towards a different palette entry than the matcher
would afterwards choose is a dither that fights its own result.

The scan is serpentine: every other row is read backwards, so the error walks
left on one row and right on the next instead of always drifting the same way.
Straight scanning leaves a diagonal grain that is plainly a rendering
artefact rather than anything about the disk.

=head1 WHAT DEFRAGMENTING LOOKED LIKE

The window was not a progress bar with a picture beside it. The picture I<was>
the progress: a band of blocks somewhere out in the disk would go white, the
same number of blocks would appear at the packed end, and the two or three at
the head would flash while it happened. Everything else sat still. That is the
whole of the animation, and it is why this is a sweep over the map rather than
a wobble applied to it.

The arithmetic is the algorithm, and it is short because the algorithm is:
walk the disk from the beginning, and wherever there is a hole, pull the next
data along to fill it. So once I<k> clusters have been moved, the first I<k>
cells hold those clusters in the order they were already in, and everything
after them is still where it was. Nothing has to be tracked between frames --
the disk at any point of the pass is a function of how far the pass has got,
which is what lets a frame be rendered on its own.

C<front> counts I<clusters moved> rather than cells walked over, which matters
because it is the difference between a control that works and one whose top
end is dead. A disk that is two thirds empty holds all its data in the first
third once it is packed, so a pass measured across the cells would finish a
third of the way along and every setting above that would do the same nothing
-- and which nothing it was would depend on C<free>. Counted in data, one is
one: the job is done, wherever that leaves the front sitting.

Two things fall out of that and both are worth having. Data is conserved: the
same number of clusters are on the disk at the end as at the beginning, so the
share C<free> asked for stays true all the way through. And the picture
survives: a cluster keeps the colour it had when it moves, so what packs into
the front of the disk is the photograph with its gaps closed up rather than a
slab of one colour. The real thing recoloured consolidated data, and doing
that here would erase the picture from the top down -- so what carries the
recolouring is the head alone, which is where the eye was looking anyway.

The pass does not close its loop and does not pretend to, which puts it beside
C<stars> rather than beside the drifts: a disk that has been defragmented is
not the disk that was, and the frame after the last is the job starting again.
That is what a defragmenter left running overnight actually did.

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
    [ finish    => 'teal',   'grey' ],     # belongs at the end
    [ fixed     => 'silver', 'white' ],    # will not be moved
    [ bad       => 'maroon', 'red' ],      # damaged
    [ reading   => 'lime' ],               # being read
    [ writing   => 'red' ],                # being written

    # Invented, in the same idiom: things a disk of the period did that the
    # legend had no room for.
    [ swap       => 'purple', 'silver' ],    # the swap file
    [ system     => 'olive',  'yellow' ],    # system files
    [ hidden     => 'purple', 'navy' ],      # hidden files
    [ compressed => 'cyan',   'silver' ],    # a compressed volume's clusters
    [ verifying  => 'yellow', 'white' ],     # written and being read back
    [ locked     => 'teal',   'black' ],     # held open by something else
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
            swap       => [ 'olive',  'grey' ],
            system     => [ 'navy',   'grey' ],
            hidden     => [ 'grey',   'black' ],
            compressed => [ 'silver', 'cyan' ],
            verifying  => [ 'cyan' ],
            locked     => [ 'maroon', 'grey' ],
        },
    },
);

# The three schemes that are nobody else's palette: a screen with one ink on
# it. Paper first, then what the ink reaches at full darkness -- which is all
# a two-stop ramp is, and is why they are written the same way as the ones
# borrowed below rather than as a rule of their own.
my %RAMP = (
    mono  => [ '#FFFFFF', '#000000' ],
    amber => [ '#000000', '#FFB000' ],
    phos  => [ '#000000', '#41FF6E' ],
);

# Free space, for every scheme that does not say otherwise. White because
# that is what the window was: see L</PAPER IS WHITE, AND WHY THAT IS THE GOAL>.
use constant PAPER => '#FFFFFF';

# Above this the paper is paper and below it the paper is a screen, which is
# the one question an outline turns on. Halfway, because there is nothing to
# measure here -- a paper either reads as lit or as printed, and the schemes
# that are one or the other are nowhere near the middle.
use constant PAPER_IS_LIT => 128;

# How finely a ramp is sampled before a state is read off it. Two hundred and
# fifty-six because that is one step per level of the darkness being looked
# up, so the sampling is never what loses a distinction between two states.
use constant RAMP_STEPS => 256;

=head2 palettes()

The palette names, in the order they should be offered: the two tables, the
three screens, and then every palette L<GlitchVape::Palette> has.

Borrowed rather than listed, so a palette added for C<gradient_map> or
C<bitmap> is a cluster map's palette the same day. A name this module already
uses keeps its own meaning -- C<amber> is the screen above rather than the
five-stop ramp of the same name, because a preset that asked for it before
should still get it.

=cut

sub palettes
{
    return ( qw(defrag scandisk), sort( keys %RAMP ), _borrowed() );
}

sub _borrowed
{
    return grep { !$TABLE{ $_ } && !$RAMP{ $_ } } GlitchVape::Palette::names();
}

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

    return _table( $TABLE{ $name } ) if $TABLE{ $name };

    # A screen says what its paper is, because that is the whole of what it
    # is: an ink and the dark it glows out of.
    return _ramp( $RAMP{ $name }[ 0 ], $RAMP{ $name } ) if $RAMP{ $name };

    # A borrowed palette does not. It is a set of colours somebody chose for
    # something else, and what this needs of it is the clusters -- so the
    # paper stays the white it always was and the palette is spent on the
    # blocks, brightest first so that a cluster still darkens as it fills.
    return _ramp( PAPER, _brightest_first( $name ) )
        if GlitchVape::Palette::known( $name );

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
    my ( $paper, $stops ) = @_;

    # One implementation of a ramp, and it is the one the palette effects
    # already use: two stops or five, the arithmetic between them is the same
    # and a second copy of it is a second place for a rounding to drift.
    my $ramp = GlitchVape::Palette::gradient_stops( $stops, RAMP_STEPS );

    my $table = _table( $TABLE{ defrag } );

    my @out;
    for my $state ( @{ $table->{ states } } )
    {
        # How far from white the same state was on a sixteen-colour display,
        # which is the only thing carried across: what a cluster is stays the
        # same, and only what the screen can say about it changes.
        my $t = 1 - _luma( $state->{ avg } ) / 255;

        my $rgb =
            _rgb( $ramp->[ int( $t * ( RAMP_STEPS - 1 ) + 0.5 ) ] );

        push @out,
            {
            name => $state->{ name },
            a    => $rgb,
            b    => undef,
            avg  => [ @$rgb ]
            };
    }

    # Flat, always: a checkerboard is what a sixteen-colour display did to
    # make a seventeenth colour, and a ramp has every colour it wants.
    #
    # The outline is not the same question, and the answer is the paper's. On
    # paper a block needs an edge to be a block -- the palest states are a
    # shade off the paper they sit on and without one they are free space. On
    # a screen the block is the lit thing and a black ring round it would be a
    # hole in the glow.
    my $ground = _rgb( $paper );

    return {
        paper  => $ground,
        edge   => _luma( $ground ) > PAPER_IS_LIT ? [ 0, 0, 0 ] : undef,
        states => \@out
    };
}

# A borrowed palette's colours, lightest first, so that the ramp runs the way
# the two tables do: a cluster with more in it is darker.
#
# Sorted rather than reversed, because the palettes that are a machine's whole
# set -- EGA, the C64, the NES -- are in the order the hardware numbered them
# and that is not an order of brightness at all. The hex is the tiebreak so
# that two colours of equal brightness cannot swap places between builds.
sub _brightest_first
{
    my ( $name ) = @_;

    my $colors = GlitchVape::Palette::colors( $name );

    my @order = map { $_->[ 0 ] }
        sort { $a->[ 1 ] <=> $b->[ 1 ] || $a->[ 0 ] cmp $b->[ 0 ] }
        map { [ $_, _luma( _rgb( $_ ) ) ] } @$colors;

    return [ reverse @order ];
}

sub _rgb
{
    my ( $hex ) = @_;
    return [ map { hex } $hex =~ /\A\#(..)(..)(..)\z/x ];
}

sub _luma
{
    my ( $rgb ) = @_;
    return 0.299 * $rgb->[ 0 ] + 0.587 * $rgb->[ 1 ] + 0.114 * $rgb->[ 2 ];
}

# The cell as it was drawn: eight across, ten down, gap included.
use constant {
    CELL_W => 8,
    CELL_H => 10,
};

=head2 cell( $block )

The whole cell at that pitch, as C<< ( $width, $height ) >>. C<$block> is the
width, because that is what anyone setting it means by the size of a block;
the height follows from the proportion and is never anyone's to get wrong.

=cut

sub cell
{
    my ( $block ) = @_;

    my $h = int( $block * CELL_H / CELL_W + 0.5 );
    return ( $block, $h > 2 ? $h : 2 );
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

    my $unit = int( $block / CELL_W );
    return $unit > 1 ? $unit : 1;
}

=head2 stamp( %arg )

    state  => one entry from map_for's states, or undef for free space
    block  => the pitch across, in pixels
    paper  => the palette's paper
    edge   => its outline, or undef

One cell, at the size L</cell( $block )> gives: the block itself, its outline
if there is room for one, and the paper along its right and bottom that
separates it from its neighbours. Ready to be written straight into a L<GlitchVape::Pixels> buffer,
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

    my ( $cw, $ch ) = cell( $arg{ block } );
    my $paper = pack 'C3', @{ $arg{ paper } };

    return $paper x ( $cw * $ch ) unless $arg{ state };

    my $unit = unit( $arg{ block } );

    my $wide = $cw - $unit;
    my $tall = $ch - $unit;

    # How big the block is in its own pixels, across -- the narrower way, and
    # so the one that decides whether there is room for each part of it.
    my $design = int( $wide / $unit );

    my $edge  = $arg{ edge } && $design >= EDGE_MIN ? $arg{ edge } : undef;
    my $inner = $edge                               ? $unit        : 0;

    my $a = pack 'C3', @{ $arg{ state }{ a } };
    my $b =
        $arg{ state }{ b } && $design >= DITHER_MIN
        ? pack 'C3', @{ $arg{ state }{ b } }
        : $a;

    my $rim = $edge ? pack 'C3', @$edge : $a;

    my $out = q{};

    for my $y ( 0 .. $ch - 1 )
    {
        for my $x ( 0 .. $cw - 1 )
        {
            if ( $x >= $wide || $y >= $tall )
            {
                $out .= $paper;
            }
            elsif (
                $inner
                && (   $x < $inner
                    || $y < $inner
                    || $x >= $wide - $inner
                    || $y >= $tall - $inner )
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

=head2 match_grid( %arg )

    states => the palette's states, from L</map_for( $palette )>
    grid   => one [ $r, $g, $b ] per cell, in reading order
    cols   => how many cells across
    rows   => and down
    spread => 0..1, how much of a cell's error its neighbours take

Which state every cell of the grid is, as one index each.

At C<spread> nought that is L</nearest( $states, $rgb )> asked once per cell,
which is the whole of what this used to be. Above it the cells are matched in
one pass that carries what each one could not say into the cells it has not
reached yet -- Floyd and Steinberg's, in the weighting L</nearest( $states,
$rgb )> measures by, so the diffusion and the matching cannot disagree about
what "near" means.

=cut

# Floyd and Steinberg's, in sixteenths: seven to the cell ahead, then three,
# five and one to the row below. The fractions are theirs and are not anyone's
# to tune -- they are what makes the four weights sum to one, which is what
# makes the error conserved rather than amplified.
my @CARRY = (
    [  1, 0, 7 / 16 ],
    [ -1, 1, 3 / 16 ],
    [  0, 1, 5 / 16 ],
    [  1, 1, 1 / 16 ],
);

sub match_grid
{
    my ( %arg ) = @_;

    my ( $states, $grid ) = @arg{ qw(states grid) };
    my ( $cols,   $rows ) = @arg{ qw(cols rows) };

    my $spread = $arg{ spread } || 0;

    return [ map { nearest( $states, $_ ) } @$grid ] unless $spread > 0;

    # A working copy, because what is being carried is the picture itself:
    # each cell is matched against what is left of it once its neighbours have
    # had their share, and the original has to survive for nothing.
    my @cell = map { [ @$_ ] } @$grid;

    my @out;

    for my $y ( 0 .. $rows - 1 )
    {
        # Every other row backwards. The cell "ahead" is then to the left, and
        # so is the diagonal the carry table calls +1.
        my $back = $y % 2;
        my $way  = $back ? -1 : 1;

        for my $step ( 0 .. $cols - 1 )
        {
            my $x = $back ? $cols - 1 - $step : $step;
            my $n = $y * $cols + $x;

            # Clamped before matching and the error taken from the clamped
            # value, so a run of saturated cells cannot walk the working
            # picture off the end of the range and stay there.
            my $want = [ map { _clamp( $cell[ $n ][ $_ ] ) } 0 .. 2 ];

            my $at = nearest( $states, $want );
            $out[ $n ] = $at;

            my $got = $states->[ $at ]{ avg };
            my @err = map { ( $want->[ $_ ] - $got->[ $_ ] ) * $spread } 0 .. 2;

            for my $carry ( @CARRY )
            {
                my ( $dx, $dy, $share ) = @$carry;

                my $tx = $x + $dx * $way;
                my $ty = $y + $dy;

                next if $tx < 0 || $tx >= $cols || $ty >= $rows;

                my $to = $cell[ $ty * $cols + $tx ];
                $to->[ $_ ] += $err[ $_ ] * $share for 0 .. 2;
            }
        }
    }

    return \@out;
}

sub _clamp
{
    my ( $v ) = @_;

    return 0   if $v < 0;
    return 255 if $v > 255;
    return $v;
}

=head2 sweep( %arg )

    cells  => one entry per cell: 0 for free space, otherwise the state's
              place in the palette plus one, in reading order
    states => the palette's states, from L</map_for( $palette )>
    front  => 0..1, how much of the data has been packed
    head   => how many clusters it is moving at once: 0 for none at all,
              or leave it out for the dozen the map is drawn with

The same disk, that far into being defragmented.

Everything before the front is packed solid: the clusters that were scattered
through it have been moved down to the beginning, in the order they were in,
and what they came from is empty now. Everything after it is untouched. The
few clusters either side of the front are lit as being written and read,
because they are.

=cut

# How many clusters the head has hold of. A real one moved a cluster at a time
# and lit two or three; at this grid a run that short is a speck, and the eye
# reads a dozen as 'something is happening here' at any size the map is drawn.
use constant HEAD => 12;

sub sweep
{
    my ( %arg ) = @_;

    my ( $cells, $states ) = @arg{ qw(cells states) };

    my $front = $arg{ front };
    return $cells unless defined $front && $front > 0;

    # Nought is none, which is a real answer rather than a way of spelling
    # the default: the compaction is the whole of what this does and the two
    # lit clusters are the decoration on it, so asking for it without them
    # has to be possible.
    my $head = defined $arg{ head } ? $arg{ head } : HEAD;

    # Where the data is now, in the order it is in. The index into this is a
    # cluster's number on the disk, which is what the pass moves it to.
    my @data = grep { $cells->[ $_ ] } 0 .. $#$cells;

    # Of the data, and not of the disk. A disk that is two thirds empty is
    # finished once the front has crossed a third of it, so a front measured
    # in cells would be a slider whose top two thirds all did the same
    # nothing -- and which nothing that was would depend on 'free'.
    my $k = int( $front * scalar @data + 0.5 );
    $k = scalar @data if $k > scalar @data;

    my @out = ( 0 ) x scalar @$cells;

    for my $n ( 0 .. $#data )
    {
        # Below the front it has been moved down to its own number; above it,
        # it has not been reached yet and is where it always was. The two
        # cannot collide, because a cluster numbered n was never below n.
        $out[ $n < $k ? $n : $data[ $n ] ] = $cells->[ $data[ $n ] ];
    }

    _light_the_head( \@out, \@data, $states, $k, $head );

    return \@out;
}

# The clusters at the head, in the two colours the window had for them: what
# has just been written, at the packed end, and what is about to be read, out
# where it still lies.
#
# Nothing is lit once the pass has run out of disk or out of data. A head
# flashing over a finished job is the one thing here that would be a lie about
# what the window did.
sub _light_the_head
{
    my ( $out, $data, $states, $k, $head ) = @_;

    return if $k >= scalar @$out || $k >= scalar @$data;

    my %at;
    my $i = 0;
    for my $state ( @$states )
    {
        $at{ $state->{ name } } = $i++;
    }

    for my $n ( 1 .. $head )
    {
        # Just written: the last few clusters to land at the packed end.
        my $wrote = $k - $n;
        $out->[ $wrote ] = 1 + $at{ writing }
            if $wrote >= 0 && $out->[ $wrote ];

        # About to be read: the next few, still out where they lie.
        my $read = $k + $n - 1;
        $out->[ $data->[ $read ] ] = 1 + $at{ reading }
            if $read <= $#$data;
    }

    return;
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
