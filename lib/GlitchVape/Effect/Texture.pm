package GlitchVape::Effect::Texture;

use strict;
use warnings;

use GlitchVape::Registry ();
use GlitchVape::Pixels   ();
use GlitchVape::Palette  ();
use GlitchVape::Defrag   ();
use GlitchVape::Magick   ();
use GlitchVape::Chicago  ();
use GlitchVape::Fonts    ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Effect::Texture - resolution, grain and surface noise

=cut

my $R = 'GlitchVape::Registry';

# ---------------------------------------------------------------------------

# The shapes worth cropping to, as width over height, named by what they are
# rather than by where they get posted: a platform renames its formats and a
# ratio does not. The generic name is also the one that still means something
# to somebody reading a preset five years from now.
my %SHAPE = (
    square   => [ 1,   1 ],
    classic  => [ 4,   3 ],
    wide     => [ 16,  9 ],
    cinema   => [ 239, 100 ],
    portrait => [ 4,   5 ],
    tall     => [ 9,   16 ],
);

$R->register(
    name    => 'crop',
    title   => 'Crop & Zoom',
    stage   => 'format',
    summary => 'Reframe to a shape, and choose what is inside it',
    doc     => <<'DOC',
Takes a rectangle out of the picture: its shape from C<shape>, how much of the
picture it covers from C<zoom>, and where it sits from C<x> and C<y>.

C<zoom> magnifies rather than shrinks. The frame that comes out is the same
size whatever the zoom is -- the largest rectangle of the chosen shape that the
source could hold -- so turning it up moves in on the subject instead of
handing the rest of the chain a smaller picture to work on. Past 1 that is a
real enlargement and it looks like one, which is what zooming into a
photograph has always looked like.

C<x> and C<y> only bite where the crop has room to slide. A wide crop out of
an ordinary photograph already spans the full width at zoom 1, so C<x> has
nowhere to go until the zoom gives it somewhere; C<y> is what chooses between
the sky and the ground. That is the geometry rather than a limitation, and
turning the zoom up is what frees both.

With C<shape> at C<none> the frame keeps the source's own proportions, which
makes this a plain zoom -- still worth having, because C<x> and C<y> then both
have slack at any zoom above 1. At C<none> and a zoom of 1 the effect is
exactly nothing, which is the one setting here that is meant to be.

Runs at C<format>, so everything after it works on what is left. That is the
point of cropping first: grain, scanlines and vignettes belong to the frame
that survives, not to the one that was thrown away.
DOC
    params => {
        shape => {
            label => 'Shape',
            order => 10,

            # Not 'none'. An effect switched on and doing nothing is an
            # effect nobody can tell they have added, and this is the one
            # here whose neutral setting is a real option rather than an
            # omission -- so the neutral one is offered and something else is
            # where it starts. Sixteen by nine, because reframing a
            # photograph to it is the commonest reason to reach for a crop.
            default => 'wide',
            type    => 'enum',
            values  => [ qw(none square classic wide cinema portrait tall) ],
            doc     => 'The proportions of the frame. none keeps the '
                . "picture's own; square is 1:1, classic 4:3, wide 16:9, "
                . 'cinema 2.39:1, portrait 4:5 and tall 9:16',
        },
        zoom => {
            label   => 'Zoom',
            order   => 20,
            default => 1,
            type    => 'num',
            min     => 1,
            max     => 8,
            doc     => 'How far into the picture the frame goes. 1 is as '
                . 'much of it as the shape allows; 2 is half the width and '
                . 'half the height of that, enlarged back to fill it',
        },
        x => {
            label   => 'Across',
            order   => 30,
            default => 0.5,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Where the frame sits between the left edge and the '
                . 'right one. Does nothing while the frame already spans the '
                . 'full width, which is what the zoom is for',
        },
        y => {
            label   => 'Down',
            order   => 40,
            default => 0.5,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Where the frame sits between the top edge and the '
                . 'bottom one. Does nothing while the frame already spans '
                . 'the full height',
        },
    },
    apply => \&_crop,
);

sub _crop
{
    my ( $ctx, $p ) = @_;

    my ( $w, $h ) = $ctx->dims;
    return unless $w > 0 && $h > 0;

    my ( $fw, $fh ) = _frame( $w, $h, $p->{ shape } );

    # Nothing to do: the whole picture, in its own shape.
    return if $fw >= $w && $fh >= $h && $p->{ zoom } <= 1;

    my $zoom = $p->{ zoom } > 1 ? $p->{ zoom } : 1;

    my $cw = int( $fw / $zoom ) || 1;
    my $ch = int( $fh / $zoom ) || 1;

    # Whatever the shape and zoom left over, shared out by x and y. Both are
    # measured across the slack rather than across the picture, so 0 is
    # against one edge and 1 against the other however much room there is --
    # which is what makes the control mean the same thing at every zoom.
    my $ox = int( ( $w - $cw ) * $p->{ x } );
    my $oy = int( ( $h - $ch ) * $p->{ y } );

    my $img = $ctx->image;

    $img->Crop( geometry => sprintf '%dx%d+%d+%d', $cw, $ch, $ox, $oy );

    # ImageMagick remembers where a crop came from: the image keeps the page
    # geometry it was cut out of, '600x400+100+50' and not '300x200+0+0', and
    # that travels all the way into the written file. A picture that claims to
    # be a tile of a larger canvas is a different thing from a picture, and
    # everything that honours the claim -- GIF assembly, -layers, a viewer
    # placing it on its page -- then puts it somewhere nobody asked for.
    $img->Set( page => '0x0+0+0' );

    # Back to the frame the shape asked for. Not doing this would make zoom
    # mean "shrink the picture", which is the opposite of what the word says
    # and would hand every later effect a smaller canvas at every setting.
    $img->Resize( geometry => "${fw}x${fh}!", filter => 'Lanczos' )
        if $cw != $fw || $ch != $fh;

    return;
}

# The largest rectangle of the wanted shape that fits inside the picture. At
# shape 'none' that is the picture itself, which is what makes the zoom work
# on its own.
sub _frame
{
    my ( $w, $h, $shape ) = @_;

    my $want  = $SHAPE{ $shape // 'none' } or return ( $w, $h );
    my $ratio = $want->[ 0 ] / $want->[ 1 ];

    # Whichever edge runs out first is the one the frame keeps. A shape wider
    # than the picture is limited by its width, a narrower one by its height;
    # getting that the wrong way round asks for a frame bigger than the thing
    # it is cut out of.
    return ( $w, int( $w / $ratio ) || 1 ) if $ratio >= $w / $h;
    return ( int( $h * $ratio ) || 1, $h );
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'defrag',
    title   => 'Disk Defragmenter',
    stage   => 'format',
    summary => 'Redraw the picture as a 1995 disk cluster map',
    doc     => <<'DOC',
The picture as the cluster map from the disk defragmenter that shipped with
Windows 95: a grid of small blocks, each one drawn in the colour of what is
supposed to be in it.

Each cell of the grid takes the average colour of the picture under it and is
painted as whichever cluster state is nearest. Fourteen states, eight of them
from the window's own legend and six invented, which is what gives the grid
enough colours to be a picture of something. C<palette> says which set they
are painted in: the two sixteen-colour tables, the three one-ink screens, and
every palette the rest of the program has -- so the map can be drawn in the
Game Boy's four greens or the C64's sixteen. See L<GlitchVape::Defrag> for
what each does with them.

C<free> is the half of it that makes it read as a disk rather than as a
mosaic. Most of the map was always empty: white paper, no block, no outline,
nothing. So that share of the cells is left blank, and which ones is decided
by the picture -- the brightest go first, because paper is the brightest thing
on the grid and a photograph's highlights are where the eye already expects
nothing much. At 0 every cell is a block and the picture is a mosaic; at 0.8
there is a scattering of data on an empty disk.

C<scatter> is what keeps that from looking like a threshold. Free and used
sorted strictly by brightness gives smooth continents of white, which is a
posterised photograph; a disk frays at that boundary and has odd clusters
stranded out on their own. Turning it up fringes the edges and strands them.

C<detail> is the other thing that disturbs that ranking, and it disturbs it
with the picture rather than with the dice. Emptying the palest cells deletes
a bright subject as readily as the sky behind it, so this asks a second
question of every cell -- is there an edge in it -- and keeps the ones there
is something in. The share of the disk that ends up empty is untouched,
because what changes is the order and not the count.

C<dither> is what stops the palette collapsing. Rounded on its own, most of a
photograph lands on whichever state sits in the middle of it: five of the
fourteen on an ordinary picture, one of them taking two thirds of the grid.
Carrying what each cluster could not say into the ones beside it brings the
rest back, and the shuffling it produces is what a fragmented disk looks
like -- see L<GlitchVape::Defrag/WHY THE ERROR IS CARRIED>.

C<block> is the pitch of one cluster in pixels. At the eight it was drawn at
there is an outline and a chequer inside it; below seven the chequer goes and
below five the outline does too, because at that size an outline is most of
the block.

C<window> puts the defragmenter's own window round the map, built around it
the way a maximised one is built around whatever it is showing -- the same
window C<maximised> draws, because there is one implementation of it. Turned
off, what comes out is the bare cluster map, which is what to use to frame it
with C<maximised> or C<chicago> yourself.

C<status> is the band under the map, and it is what says this window is doing
something rather than merely showing something: a sunken trough with the work
so far lit along it in blocks, and the share as a percentage beside it.
C<progress> is how far along. It is a setting rather than a thing worked out
from the picture because there is nothing in a photograph that means "the
disk is a third done".

C<advance> is the same job in motion, and it is the only setting here that
means anything in a loop and nothing in a still. One pass over the disk,
starting at the beginning of it and getting that far through: the clusters
behind the head are packed down to the front and what they came from goes
empty, and a dozen at the head flash as written and read. The gauge adds what
the pass has done to C<progress>, because the pass is one sweep and the gauge
is the whole job.

Starting at the beginning is the point of it. Opening the loop part of the way
in -- with the head already down the map and everything above it packed -- puts
the dullest part of the pass at the front of the loop and hides that much of
the photograph for all of it. Started at the top, the loop opens on the
picture and the pass eats into it.

The loop does not close and does not pretend to; the frame after the last one
is the job starting again.


It runs at C<format>, first in the chain, for the reason C<downsample> does:
everything after it then happens to the grid rather than to the photograph,
which is what makes scanlines over this look like scanlines over a screen
showing it. The window goes on at the same point and for the same reason: it
is part of what is being photographed rather than a mount around the
photograph, so the grain belongs on it too.
DOC
    params => {
        block => {
            label   => 'Cluster size',
            order   => 10,
            default => 8,
            type    => 'int',
            min     => 3,
            max     => 48,
            doc     => 'How many pixels across one cluster block is, gap '
                . 'included. Eight is what it was drawn at',
        },
        palette => {
            label   => 'Palette',
            order   => 20,
            default => 'defrag',
            type    => 'enum',
            values  => [ GlitchVape::Defrag::palettes() ],
            doc     => 'Which colours the states are painted in. defrag and '
                . 'scandisk are sixteen-colour tables with chequered blocks; '
                . 'mono, amber and phos are one ink on one paper, where a '
                . 'cluster glows in proportion to how dark it was. The rest '
                . 'are the program\'s own palettes spent on the blocks, on '
                . 'the white paper the window had -- amber and phos are the '
                . 'exceptions, being a monitor rather than a window',
        },
        dither => {
            label   => 'Colour diffusion',
            order   => 25,
            default => 0.75,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How much of what a cluster could not say is carried '
                . 'into the ones beside it. At 0 every cluster is rounded on '
                . 'its own and most of a photograph lands on whichever state '
                . 'sits in the middle of it; turning it up brings the rest of '
                . 'the palette back, and reads as a disk shuffled together '
                . 'rather than sorted into continents',
        },
        free => {
            label   => 'Free space',
            order   => 30,
            default => 0.35,
            type    => 'num',
            min     => 0,
            max     => 0.9,
            doc     => 'What share of the disk is empty. Empty means bare '
                . 'paper rather than a pale block, which is what most of the '
                . 'window always was',
        },
        scatter => {
            label   => 'Fragmentation',
            order   => 40,
            default => 0.3,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How ragged the edge between used and free is. At 0 '
                . 'it follows the picture exactly, which reads as posterised '
                . 'rather than as a disk; turning it up strands clusters out '
                . 'on their own the way a fragmented one does',
        },
        detail => {
            label   => 'Keep detail',
            order   => 45,
            default => 0.4,
            type    => 'num',
            min     => 0,
            max     => 1,
            needs   => { free => 1 },
            doc     => 'How much the picture\'s own edges decide which '
                . 'clusters survive. At 0 the emptiest cells are simply the '
                . 'palest ones, which deletes a bright subject along with the '
                . 'sky behind it; turning it up keeps whatever sits on an '
                . 'edge and empties the flat ground instead',
        },
        window => {
            label   => 'Window',
            order   => 60,
            default => 1,
            type    => 'bool',
            doc     => 'Put the defragmenter\'s own window round it, built '
                . 'around the map the way a maximised one is built around '
                . 'what it is showing',
        },
        title => {
            label       => 'Caption',
            order       => 70,
            default     => 'Defragmenting Drive C',
            type        => 'str',
            placeholder => 'no caption text',
            needs       => { window => 1 },
            doc         => 'What the title bar says',
        },
        theme => {
            label   => 'Window colours',
            order   => 80,
            default => 'default',
            type    => 'enum',
            values  => [ GlitchVape::Chicago::themes() ],
            needs   => { window => 1 },
            doc     => 'Which of the schemes from the Appearance tab the '
                . 'window is painted in',
        },
        status => {
            label   => 'Progress bar',
            order   => 90,
            default => 1,
            type    => 'bool',
            needs   => { window => 1 },
            doc     => 'The band under the map: a gauge and how far along it '
                . 'says the disk is. Turned off, the map runs to the bottom '
                . 'of the window',
        },
        progress => {
            label   => 'Progress',
            order   => 100,
            default => 0.4,
            type    => 'num',
            min     => 0,
            max     => 1,
            needs   => { window => 1, status => 1 },
            doc     => 'How far along the whole job is, which is what the '
                . 'gauge reads: a pass adds what it has done to this as it '
                . 'runs, since one sweep over the disk is a part of the work '
                . 'rather than all of it. The percentage beside the bar is '
                . 'this and not a setting of its own, because a gauge and a '
                . 'number that disagreed would be a bug only the picture '
                . 'could show',
        },
        advance => {
            label     => 'Pass',
            order     => 55,
            default   => 0,
            type      => 'num',
            min       => 0,
            max       => 1,
            animation => 1,
            doc       => 'How much of the disk the defragmenter works '
                . 'through over one loop. The pass starts at the beginning '
                . 'of the disk each time round: the clusters behind the head '
                . 'are packed down to the front and what they came from goes '
                . 'empty, which is what that window actually did, and the '
                . 'gauge adds what the pass has done to Progress. Nothing on '
                . 'a still, where there is no pass to be part of the way '
                . 'through',
        },
        seed => {
            label   => 'Layout seed',
            order   => 50,
            default => 0,
            type    => 'int',
            min     => 0,
            max     => 9999,
            needs   => { scatter => 1 },
            doc     => 'Which scattering. The same number gives the same '
                . 'disk, and the map is held still for a whole animation '
                . 'either way -- a cluster map that re-rolled every frame '
                . 'would strobe rather than move',
        },
    },
    apply => \&_defrag,
);

# Where the edge scale is read off. The busiest twentieth of the grid is
# taken as 'as much detail as this picture has', so the control means the same
# thing on a portrait against a wall as on a photograph of a forest.
use constant DETAIL_TOP => 0.95;

sub _defrag
{
    my ( $ctx, $p ) = @_;
    require Image::Magick;

    my ( $w, $h ) = $ctx->dims;
    return unless $w && $h;

    # Across and down are different numbers: the grid is eight pixels wide
    # and ten tall, which is what the real one was and the first thing the eye
    # picks up about it.
    my ( $cw, $ch ) = GlitchVape::Defrag::cell( $p->{ block } );

    my $cols = int( $w / $cw );
    my $rows = int( $h / $ch );

    # Nothing to draw a grid on. Two cells across is not a cluster map, and
    # what it would be instead is four coloured rectangles.
    return if $cols < 2 || $rows < 2;

    my $map = GlitchVape::Defrag::map_for( $p->{ palette } );

    my $avg = _cluster_colours( $ctx, $cols, $rows );

    # Held still rather than re-rolled: which clusters are empty is a fact
    # about the disk, and a map that redrew itself every frame would strobe
    # where the picture underneath it had not moved.
    my $rng = $ctx->rng_fixed( 'defrag' . ( $p->{ seed } || 0 ) );

    # Only when it is asked for: the edges are a second pass over the whole
    # picture, and a setting at nought should not cost a render anything.
    my $detail =
        $p->{ detail } > 0 ? _cluster_detail( $ctx, $cols, $rows ) : undef;

    my $pass = _pass( $ctx, $p );

    my $used = _used_cells(
        states => $map->{ states },
        avg    => $avg,
        detail => $detail,
        cols   => $cols,
        rows   => $rows,
        params => $p,
        rng    => $rng,
        front  => $pass,
    );

    # One stamp per state, built once and written straight into the buffer.
    # A cluster map is tens of thousands of cells, and the alternative is
    # tens of thousands of draw operations to produce a picture made of
    # fourteen distinct rectangles.
    my @stamp = map {
        GlitchVape::Defrag::stamp(
            state => $_,
            block => $p->{ block },
            paper => $map->{ paper },
            edge  => $map->{ edge },
        )
    } ( undef, @{ $map->{ states } } );

    # Centred, so the remainder of a picture that is not a whole number of
    # clusters across shows as paper on both sides rather than as a margin
    # down one.
    my $ox = int( ( $w - $cols * $cw ) / 2 );
    my $oy = int( ( $h - $rows * $ch ) / 2 );

    my $paper = pack 'C3', @{ $map->{ paper } };

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;

            $px->set_row( $_, $paper x $w ) for 0 .. $h - 1;

            for my $y ( 0 .. $rows - 1 )
            {
                for my $x ( 0 .. $cols - 1 )
                {
                    my $n = $y * $cols + $x;

                    # Free space is paper, which the whole canvas already is.
                    next unless $used->[ $n ];

                    $px->set_rect(
                        $ox + $x * $cw,
                        $oy + $y * $ch,
                        $cw, $ch, $stamp[ $used->[ $n ] ]
                    );
                }
            }
        }
    );

    _put_in_a_window( $ctx, $p, $pass ) if $p->{ window };

    return;
}

# How much of the disk this pass has worked through by this frame, or undef
# where there is no pass.
#
# It starts at the beginning of the disk every time round, because that is
# where a pass starts. Beginning it at C<progress> instead was tried and is
# wrong twice over: the head is then already a third of the way down the map
# with a slab of packed clusters over everything above it, so the loop opens
# on the least interesting part of the pass and on the most of the photograph
# already covered. What C<progress> counts is the job, and a job is more than
# one pass -- see L</_gauge>.
#
# Nought on a still, and that is what makes this an animation setting rather
# than a second progress control: a defragmenter caught at one instant is a
# cluster map, which is what the rest of the effect already draws.
sub _pass
{
    my ( $ctx, $p ) = @_;

    return unless $ctx->frames > 1 && $p->{ advance } > 0;

    return $p->{ advance } * $ctx->phase;
}

# What the gauge under the map reads.
#
# The job rather than the pass, which is why the two numbers are added rather
# than being one number: the map is one sweep over the disk and the gauge is
# the whole of the work, of which a sweep is a part. So C<progress> is what
# had been done before this loop started, and it still moves the bar while an
# animation is running -- a control that went dead the moment Animate was
# switched on would be the worst of both.
sub _gauge
{
    my ( $p, $pass ) = @_;

    my $done = $p->{ progress } + ( $pass || 0 );

    return $done > 1 ? 1 : $done;
}

# The defragmenter's own window, built around the map the way a maximised one
# is built around whatever it is showing.
#
# Drawn from here rather than left to the 'maximised' effect, which would be
# the tidier place for it, because this window is not furniture the picture
# happens to be sitting in -- it is the other half of the thing being drawn,
# and a cluster map without it is a mosaic.
#
# What that costs is worth saying rather than hiding: the window is in place
# before the rest of the chain runs, so scanlines and grain land on the chrome
# as well as on the grid. Which is what is wanted here, since what is being
# imitated is a photograph of a screen rather than a screenshot.
#
# It is GlitchVape::Chicago::wrap, the same call 'maximised' makes. A second
# window-drawing implementation would be a second place for a bevel to go
# wrong.
sub _put_in_a_window
{
    my ( $ctx, $p, $pass ) = @_;

    $ctx->image(
        GlitchVape::Chicago::wrap(
            image   => $ctx->image,
            theme   => $p->{ theme },
            caption => $p->{ title },
            font    => GlitchVape::Fonts::resolve( 'ui' ),

            # The band under the map, which is the one piece of chrome
            # 'maximised' has no use for: a window around a photograph is not
            # doing anything, and this one is.
            # What the pass has done is added to it rather than replacing
            # it, so the bar advances with the disk: a gauge that sat still
            # while the map packed itself would be the plainest possible way
            # of saying the two had come apart.
            progress => $p->{ status } ? _gauge( $p, $pass ) : undef,

            # Not settings. The defragmenter had no menu bar and no scroll
            # bars -- the map was however big the window was -- and the icon
            # is its own rather than the document page the chrome was
            # scavenged from, because what is in the caption of a program is
            # that program. Anyone who wants a window they can dress
            # differently already has 'maximised'.
            icon       => 'defrag',
            menu       => undef,
            scrollbars => 0,
        )
    );

    return;
}

# The average colour under every cell, as one RGB triple each.
#
# Done by asking ImageMagick to resize the picture to the size of the grid,
# which is exactly the average this wants and is the one operation it does
# faster than anything written here could. Box rather than a filter with a
# wider support: a cluster is the picture under it and nothing of its
# neighbours.
sub _cluster_colours
{
    my ( $ctx, $cols, $rows ) = @_;

    my $small = $ctx->image->Clone;

    GlitchVape::Magick::check(
        $small->Resize( geometry => "${cols}x$rows!", filter => 'Box' ),
        'defrag: could not reduce the picture to the cluster grid'
    );

    my $px = GlitchVape::Pixels->from_image( $small );
    my @v  = unpack 'C*', $px->data;

    return [ map { [ @v[ $_ * 3 .. $_ * 3 + 2 ] ] } 0 .. $cols * $rows - 1 ];
}

# How much is going on inside each cell, as 0..1.
#
# The picture's own edges, averaged down to the grid: a cell that a contour
# runs through comes back near one and a cell of flat sky comes back near
# nought. That is the question 'is there anything here worth a cluster', and
# it is asked of the picture at full size rather than of the grid, because by
# the time the picture is one pixel per cell the edge has been averaged into
# the very flatness being looked for.
#
# Normalised against a high percentile and not the maximum: one specular
# highlight -- a chrome fitting, a reflection off water -- is a cell an order
# of magnitude above everything else, and dividing by it would flatten the
# rest of the picture to nothing and leave the setting looking broken.
sub _cluster_detail
{
    my ( $ctx, $cols, $rows ) = @_;

    my $edge = $ctx->image->Clone;
    $edge->Set( colorspace => 'Gray' );

    GlitchVape::Magick::check( $edge->Edge( radius => 1 ),
        'defrag: could not find the picture\'s edges' );

    GlitchVape::Magick::check(
        $edge->Resize( geometry => "${cols}x$rows!", filter => 'Box' ),
        'defrag: could not reduce the edges to the cluster grid'
    );

    my $px = GlitchVape::Pixels->from_image( $edge );
    my @v  = unpack 'C*', $px->data;

    my @found = map { $v[ $_ * 3 ] } 0 .. $cols * $rows - 1;

    my @sorted = sort { $a <=> $b } @found;
    my $top    = $sorted[ int( $#sorted * DETAIL_TOP ) ] || 1;

    return [ map { $_ > $top ? 1 : $_ / $top } @found ];
}

# Which cells carry a block, and which state each of them is.
#
# Returns one number per cell: 0 for free space, otherwise the state's place
# in the palette plus one -- which is also its index into the stamps, since
# free space is the stamp before the first state.
sub _used_cells
{
    my ( %arg ) = @_;

    my ( $states, $avg, $detail ) = @arg{ qw(states avg detail) };
    my ( $cols, $rows ) = @arg{ qw(cols rows) };
    my ( $p,    $rng )  = @arg{ qw(params rng) };

    # How bright each cell is, with the scattering and the detail already
    # mixed in. Doing it here rather than after the threshold is what frays
    # the boundary instead of speckling the whole grid: a cell near the edge
    # of being empty is the one a nudge moves, and one in the middle of the
    # data stays put. The detail is the same kind of nudge with the picture
    # doing the nudging instead of the dice.
    my @lit;
    for my $n ( 0 .. $#$avg )
    {
        my $l =
            0.299 * $avg->[ $n ][ 0 ] +
            0.587 * $avg->[ $n ][ 1 ] +
            0.114 * $avg->[ $n ][ 2 ];

        $l += ( $rng->rand( 2 ) - 1 ) * $p->{ scatter } * 110;

        # Towards the dark end, which is the end that survives. A whole range
        # at full strength, so a cell on an edge outranks a flat cell of any
        # brightness rather than merely being helped along -- half of it and
        # the setting would do nothing at all on a light photograph.
        $l -= $detail->[ $n ] * $p->{ detail } * 255 if $detail;

        push @lit, $l;
    }

    # Chosen by rank rather than by a brightness to be above, so that asking
    # for a third of the disk to be empty gives a third of it whatever the
    # photograph is: a threshold in brightness would give a dark picture a
    # full disk and a bright one an empty disk from the same setting, and a
    # picture of one flat colour -- which is every sky and every studio
    # backdrop -- has no threshold that divides it at all.
    #
    # Darkest first, so the brightest cells are the ones left over at the end
    # and those are the ones that go empty. Ties by position, which puts the
    # free space of a picture with no variation in it at the far end of the
    # disk -- where a defragmenter leaves it.
    my @order = sort { $lit[ $a ] <=> $lit[ $b ] || $a <=> $b } 0 .. $#lit;

    my $empty = int( @order * $p->{ free } + 0.5 );

    my @out = ( 0 ) x scalar @order;

    # Matched over the whole grid rather than a cell at a time, because the
    # error one cell could not say is carried into the ones after it and a
    # cell left out of the walk is a hole in that. Which cells are free is a
    # question about space and this is a question about colour; the free ones
    # are blanked below, after both have been answered.
    my $state = GlitchVape::Defrag::match_grid(
        states => $states,
        grid   => $avg,
        cols   => $cols,
        rows   => $rows,
        spread => $p->{ dither },
    );

    for my $at ( 0 .. $#order - $empty )
    {
        my $n = $order[ $at ];
        $out[ $n ] = 1 + $state->[ $n ];
    }

    # And then the pass over the top of it, which moves clusters rather than
    # choosing them: what is on the disk was settled above, and this is the
    # defragmenter finding it there.
    return GlitchVape::Defrag::sweep(
        cells  => \@out,
        states => $states,
        front  => $arg{ front },
    );
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'downsample',
    title   => 'Pixelize',
    stage   => 'format',
    summary => 'Throw away resolution, then scale back up',
    doc     => <<'DOC',
Shrinks the image and enlarges it again with nearest-neighbour interpolation,
so the lost detail stays lost and the pixels stay square. Running this first
matters: every later effect then operates on the reduced detail, which is what
makes the result look genuinely low-resolution instead of looking like a sharp
photograph with a soft filter over it.

The classic tape resolution is 333x480 for NTSC VHS, which C<preset: vhs>
selects; C<factor> is the free-form alternative.
DOC
    params => {
        factor => {
            default => 2.0,
            type    => 'num',
            min     => 1,
            max     => 64,
            doc     => 'Divide resolution by this before scaling back',
        },
        preset => {
            default => 'none',
            type    => 'enum',
            values  => [ qw(none vhs vhs-pal video8 svhs ld cga) ],
            doc     => 'Use a real format resolution instead of factor',
        },
        filter => {
            default => 'point',
            type    => 'enum',
            values  => [ qw(point box triangle lanczos) ],
            doc     => 'Interpolation on the way back up',
        },
        aspect => {
            default => 0,
            type    => 'bool',
            doc     => 'Squash to 4:3 on the way down and stretch back',
        },
    },
    apply => \&_downsample,
);

# Horizontal luminance resolution of formats worth imitating. Vertical comes
# from the line standard, so only width is meaningful here.
my %FORMAT = (
    vhs       => [ 333, 480 ],
    'vhs-pal' => [ 335, 576 ],
    video8    => [ 300, 480 ],
    svhs      => [ 560, 480 ],
    ld        => [ 567, 480 ],
    cga       => [ 320, 200 ],
);

sub _downsample
{
    my ( $ctx, $p ) = @_;

    my ( $w, $h ) = $ctx->dims;
    my ( $sw, $sh );

    if ( $p->{ preset } ne 'none' )
    {
        my $f = $FORMAT{ $p->{ preset } }
            or die "downsample: unknown preset '$p->{preset}'\n";

        # Match the format's pixel count to this image's aspect rather than
        # forcing 4:3, so a portrait photo does not come back stretched.
        my $target = $f->[ 0 ] * $f->[ 1 ];
        my $ratio  = $w / $h;
        $sw = int( sqrt( $target * $ratio ) );
        $sh = int( $sw / $ratio );
    }
    else
    {
        return if $p->{ factor } <= 1;
        $sw = int( $w / $p->{ factor } );
        $sh = int( $h / $p->{ factor } );
    }

    $sw = 1 if $sw < 1;
    $sh = 1 if $sh < 1;

    $sw = int( $sw * 0.75 ) || 1 if $p->{ aspect };

    my $img = $ctx->image;
    $img->Set( filter => 'Point' );
    $img->Resize( geometry => "${sw}x${sh}!", filter => 'Point' );
    $img->Resize( geometry => "${w}x${h}!", filter => ucfirst $p->{ filter } );

    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'bitmap',
    title   => '8-Bit Bitmap Mode',
    stage   => 'format',
    summary => 'Low resolution, fixed palette and ordered dither, together',
    doc     => <<'DOC',
What a home computer's bitmap mode actually did: a small number of chunky
pixels, each one an index into a palette of fixed colours, with a threshold
matrix faking the shades the hardware did not have.

This exists as one effect rather than as C<downsample> plus C<palette> plus
C<dither> because the order those three run in is the whole difference between
an 8-bit picture and a photograph with a pattern over it. The palette lookup
and the dither have to happen while the image is still small, so that one dithered
cell is one chunky pixel. Run separately they cannot: C<downsample> is a
C<format> effect and C<dither> a C<grain> one, so the dither lands after the
image has been scaled back up and its checkerboard is drawn in pixels far
smaller than the blocks it is supposed to be shading. The blocks disappear.

So the chain here is down, dither, remap, up -- in one pass, at the small size,
which is a thing no ordering of the three separate effects can express.

The dither is applied as an offset rather than as a quantisation: the threshold
matrix nudges each pixel up or down before the palette lookup, so neighbouring
pixels round to different entries and the eye mixes them. Quantising first and
remapping afterwards -- which is what chaining the existing two effects does --
puts colours in that the palette then has to snap somewhere arbitrary, and the
result is speckle rather than shading.

Being a C<format> effect, this commits to its palette before any C<colour>
effect runs, so a grade or a tint after it will move pixels back off the
palette. That is the right way round -- the blocks have to exist before
anything shapes them, and a bloom or a scanline blending two neighbouring
entries is what a screen showing an 8-bit image did anyway -- but it does mean
the palette is a look here rather than a guarantee.

C<reroll> moves the matrix to a different cell on every frame of a loop, which
is what an indexed-colour display did with a picture it could not hold: the
dither pattern crawls and the eye reads the shades between the palette
entries. It is off by default, because a shimmer nobody asked for would change
what every preset using this already renders, and because at a large C<factor>
the cells are big enough that the crawl is the loudest thing in the frame.
DOC
    params => {
        factor => {
            default => 6,
            type    => 'num',
            min     => 1,

            # Sixteen is already a 1920-pixel photograph reduced to 120
            # blocks across, which is coarser than any machine this is
            # imitating. It was 64, where the whole of the usable range sat
            # in the first quarter of the slider.
            max => 16,
            doc => 'Divide resolution by this before the palette lookup',
        },
        palette => {
            default => 'laserwave',
            type    => 'str',

            # Chosen rather than suggested: five settings here make a picture
            # look like a machine, and the palette is which machine. The
            # inline form still works from the command line, and a preset
            # that uses one still shows it -- see
            # GlitchVape::GUI::Params/_combo_of -- but it is not what this
            # control is for, and an entry beside a list of the machines
            # invites typing where picking is the whole question.
            choose => 'palette',
            doc    => 'Palette name, or inline "#FF71CE,#01CDFE,..."',
        },
        matrix => {
            default => 'o4x4',
            type    => 'enum',
            values  => [ qw(none o2x2 o4x4 o8x8) ],
            doc     => 'Bayer matrix the dither offset comes from',
        },
        reroll => {
            animation => 1,

            # Nothing to move the picture under with no matrix, and nothing
            # for the matrix to do at nought amount.
            needs   => { matrix => [ qw(o2x2 o4x4 o8x8) ], amount => 1 },
            default => 0,
            type    => 'bool',
            doc     => 'Meet the matrix at a different cell on every frame, '
                . 'so the dither pattern crawls as an indexed display did',
        },
        amount => {
            default => 0.25,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How far the matrix nudges a pixel before the lookup',
        },
        filter => {
            default => 'point',
            type    => 'enum',
            values  => [ qw(point box triangle) ],
            doc     => 'Interpolation on the way back up',
        },
    },
    apply => \&_bitmap,
);

# How far the picture is rolled under the Bayer tile on this frame.
#
# Shares its argument, and its table of periods, with the dither below: both
# lay a repeating matrix over the picture, and rolling by a whole period would
# be no roll at all. Rolled at the small size, because that is where the tile
# is and one cell there is one chunky pixel.
sub _bitmap_offset
{
    my ( $ctx, $p ) = @_;

    return ( 0, 0 ) unless $p->{ reroll } && $p->{ matrix } ne 'none';

    return _dither_offset( $ctx, { reroll => 1, map => $p->{ matrix } } );
}

sub _bitmap
{
    my ( $ctx, $p ) = @_;

    my ( $w, $h ) = $ctx->dims;

    my $sw = int( $w / $p->{ factor } ) || 1;
    my $sh = int( $h / $p->{ factor } ) || 1;

    my $remap =
        GlitchVape::Palette::remap_file( $p->{ palette }, $ctx->cachedir );

    my @args = ( '-filter', 'Point', '-resize', "${sw}x${sh}!" );

    if ( $p->{ matrix } ne 'none' && $p->{ amount } > 0 )
    {
        my $tile = _bayer_file( $p->{ matrix }, $ctx->cachedir );
        my ( $dx, $dy ) = _bitmap_offset( $ctx, $p );

        push @args, '-roll', sprintf '%+d%+d', $dx, $dy if $dx || $dy;

        # result = amount*tile + image - amount/2, so the matrix is centred on
        # zero and shifts a pixel either way rather than only brightening it.
        push @args,
            '(', '-size', "${sw}x${sh}", "tile:$tile", ')',
            '-compose', 'Mathematics', '-define',
            sprintf(
            'compose:args=0,%.4f,1,%.4f',
            $p->{ amount },
            -$p->{ amount } / 2
            ),
            '-composite';

        push @args, '-roll', sprintf '%+d%+d', -$dx, -$dy if $dx || $dy;
    }

    # -dither before -remap: it is a setting that the remap reads, not an
    # operation, so after it the remap has already diffused its own error and
    # torn the matrix pattern up.
    push @args,
        '-dither', 'None', '-remap', $remap,
        '-filter', ucfirst $p->{ filter }, '-resize', "${w}x${h}!";

    $ctx->magick( @args );

    return;
}

# The threshold matrix, written once per size into the render's temporary
# directory and reused. Built rather than shipped: it is defined by a
# recurrence, and four lines of it are easier to check than a binary asset.
#
#   M(2n) = [ 4*M(n)+0  4*M(n)+2 ]
#           [ 4*M(n)+3  4*M(n)+1 ]
sub _bayer_file
{
    my ( $name, $dir ) = @_;
    require File::Spec;
    require GlitchVape::Tools;

    my ( $n ) = $name =~ /(\d+)/;
    $n ||= 4;

    my $path = File::Spec->catfile( $dir, "bayer_$n.png" );
    return $path if -f $path;

    my $m    = [ [ 0 ] ];
    my $size = 1;
    while ( $size < $n )
    {
        my @next;
        for my $y ( 0 .. $size * 2 - 1 )
        {
            for my $x ( 0 .. $size * 2 - 1 )
            {
                my $base = 4 * $m->[ $y % $size ][ $x % $size ];
                my $quad = ( $y < $size ? 0 : 2 ) + ( $x < $size ? 0 : 1 );
                $next[ $y ][ $x ] =
                    $base + ( 0, 2, 3, 1 )[ $quad ];
            }
        }
        $m = \@next;
        $size *= 2;
    }

    # Raw single-channel bytes rather than ImageMagick's txt: enumeration.
    # That format needs a full (r,g,b) tuple per line and silently reads a
    # bare gray(n) as black, which produces a uniform tile -- a dither that
    # does nothing, and looks exactly like one that is switched off.
    my $cells = $n * $n;
    my $raw   = File::Spec->catfile( $dir, "bayer_$n.gray" );

    open my $fh, '>:raw', $raw
        or die "GlitchVape: cannot write $raw: $!\n";
    for my $y ( 0 .. $n - 1 )
    {
        for my $x ( 0 .. $n - 1 )
        {
            print { $fh } chr int( $m->[ $y ][ $x ] / $cells * 255 + 0.5 );
        }
    }
    close $fh;

    my @argv = GlitchVape::Tools::magick_argv( '-size', "${n}x$n", '-depth',
        '8', "gray:$raw", $path );
    system( @argv ) == 0
        or die "GlitchVape: could not build the $name threshold matrix\n";

    return $path;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'grain',
    title   => 'Film Grain',
    stage   => 'grain',
    summary => 'Film / sensor grain',
    doc     => <<'DOC',
Additive noise with a Gaussian distribution, which is what real grain and
sensor noise look like -- uniform noise reads as digital and wrong.

C<shadow_bias> concentrates the grain in dark areas. That is how both film and
cheap video sensors actually behave: the noise floor is constant, so it is only
visible where the signal is weak. Applying grain evenly is the single most
common thing that makes an imitation look fake.
DOC
    params => {
        amount => {
            default => 0.08,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Noise standard deviation as a fraction of full scale',
        },
        mono => {
            default => 0,
            type    => 'bool',
            doc     => 'One noise value per pixel instead of per channel',
        },
        shadow_bias => {
            default => 0.6,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Concentrate grain in dark areas',
        },
        size => {
            default => 1,
            type    => 'int',
            min     => 1,
            max     => 16,
            doc     => 'Grain cluster size in pixels',
        },
    },
    apply => \&_grain,
);

sub _grain
{
    my ( $ctx, $p ) = @_;
    return if $p->{ amount } <= 0;

    # Coarse grain is generated at reduced size and scaled up, which is both
    # faster and closer to how clumped film grain actually looks.
    return _coarse_grain( $ctx, $p ) if $p->{ size } > 1;

    my $rng  = $ctx->rng_for( 'grain' );
    my $sd   = $p->{ amount } * 255;
    my $bias = $p->{ shadow_bias };
    my $mono = $p->{ mono };

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;

            $px->each_row(
                sub {
                    my ( undef, $row ) = @_;
                    my @v = unpack 'C*', $row;

                    for ( my $i = 0 ; $i < @v ; $i += 3 )
                    {
                        my $scale = 1;
                        if ( $bias )
                        {
                            my $luma =
                                GlitchVape::Pixels::luma( @v[ $i .. $i + 2 ] )
                                / 255;
                            $scale = 1 - $bias * $luma;
                        }

                        if ( $mono )
                        {
                            my $n = $rng->gauss( 0, $sd ) * $scale;
                            $v[ $_ ] =
                                GlitchVape::Pixels::clamp( $v[ $_ ] + $n )
                                for $i .. $i + 2;
                        }
                        else
                        {
                            $v[ $_ ] = GlitchVape::Pixels::clamp(
                                $v[ $_ ] + $rng->gauss( 0, $sd ) * $scale )
                                for $i .. $i + 2;
                        }
                    }

                    return pack 'C*', @v;
                }
            );
        }
    );
    return;
}

sub _coarse_grain
{
    my ( $ctx, $p ) = @_;
    require Image::Magick;
    require GlitchVape::Raster;

    my ( $w, $h ) = $ctx->dims;
    my $rng = $ctx->rng_for( 'grain' );

    my $gw = int( $w / $p->{ size } ) || 1;
    my $gh = int( $h / $p->{ size } ) || 1;

    my $sd    = $p->{ amount } * 255;
    my $bytes = '';

    # Mid-grey is the identity for the HardLight composite below, so the noise
    # is generated around 128 rather than around zero.
    for ( 1 .. $gw * $gh )
    {
        if ( $p->{ mono } )
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

    my $noise = $ctx->tmpfile( '.ppm' );
    GlitchVape::Raster::write_ppm( $noise, $gw, $gh, $bytes );

    my $layer = Image::Magick->new;
    $layer->Read( $noise );
    $layer->Resize( geometry => "${w}x${h}!", filter => 'Point' );

    # Mid-grey is the identity for HardLight, so the noise adds and subtracts
    # around the existing pixel rather than lifting the whole image.
    $ctx->image->Composite(
        image   => $layer->[ 0 ],
        compose => 'HardLight',
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'static',
    title   => 'RF Static',
    stage   => 'signal',
    summary => 'Broadcast snow / RF static',
    doc     => <<'DOC',
Sparse bright and dark specks scattered over the picture, as distinct from
C<grain>'s continuous noise floor. This is the look of an aerial picking up a
weak signal.

The specks are redrawn every frame of a loop from the frame's own stream, which
is what snow does and needs no setting. C<surge> is the setting: how far the
snow rises over the loop and falls back, so the signal comes and goes instead
of sitting at one strength. It is measured towards a picture that is nothing
but snow, so 1 means the aerial loses it completely half way round and has it
back by the end.

C<spread> is how far a speck may fall short of black or white. Snow is not
two-valued -- an aerial's noise is a level that varies, and a picture built
from only the two extremes reads as salt and pepper laid over the frame rather
than as a signal underneath it. At 0 every speck is at its pole, which is what
this did before the setting existed; at 1 they are scattered evenly from the
pole to mid grey.
DOC
    params => {
        density => {
            order   => 1,
            default => 0.02,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Fraction of pixels affected',
        },
        intensity => {
            order   => 2,
            default => 0.8,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How far affected pixels go towards their level',
        },
        spread => {
            order   => 3,
            default => 0.35,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How far a speck may fall back from black or white '
                . 'towards grey; 0 is two-valued snow',
        },
        streak => {
            order   => 4,
            default => 3,
            type    => 'int',
            min     => 1,
            max     => 200,
            doc     => 'Maximum horizontal run length of a speck',
        },
        surge => {
            animation => 1,

            # Snow that rises from none is still none: the effect is off at
            # density 0 and says so, rather than leaving a live control that
            # does nothing.
            needs   => { density => 1 },
            order   => 5,
            default => 0,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How far the snow rises over the loop and falls '
                . 'back, towards a picture that is nothing else. Nothing '
                . 'on a still',
        },
    },
    apply => \&_static,
);

# How much of the picture is snow on this frame.
#
# Measured towards 1 rather than as a multiple of what was asked for, so the
# setting has an end: at a whole surge the frame half way round the loop is
# nothing but snow, and no value of it can ask for a density that does not
# exist. It rides swell rather than excursion because there is no such thing
# as less snow than none, and because a signal that fails belongs at the
# middle of the loop, furthest from the seam.
sub _static_density
{
    my ( $ctx, $p ) = @_;

    my $surge = $ctx->swell( $p->{ surge } );
    return $p->{ density } unless $surge;

    return $p->{ density } + ( 1 - $p->{ density } ) * $surge;
}

# Where one speck lands. Half go towards white and half towards black; how
# close either gets is uniform across the band spread allows, because the
# height of a noise peak is not a property the peak inherits from its sign.
sub _speck_level
{
    my ( $rng, $spread ) = @_;

    my $pole = $rng->chance( 0.5 ) ? 255 : 0;
    return $pole unless $spread;

    my $back = $rng->rand( $spread ) * 127.5;

    return $pole ? $pole - $back : $pole + $back;
}

sub _static
{
    my ( $ctx, $p ) = @_;
    return if $p->{ density } <= 0;

    my $density = _static_density( $ctx, $p );
    my $rng     = $ctx->rng_for( 'static' );

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my ( $w, $h ) = ( $px->width, $px->height );

            # Each speck averages streak/2 pixels wide, so scale the draw count
            # to hit the requested density regardless of streak length.
            my $mean_len = ( $p->{ streak } + 1 ) / 2;
            my $draws    = int( $w * $h * $density / $mean_len );
            return unless $draws > 0;

            # Group by row first: touching each affected row once beats
            # unpacking it again for every speck that lands on it.
            my %rows;
            for ( 1 .. $draws )
            {
                my $y = $rng->int_between( 0, $h - 1 );

                my $target = _speck_level( $rng, $p->{ spread } );

                push @{ $rows{ $y } },
                    [
                    $rng->int_between( 0, $w - 1 ),
                    $rng->int_between( 1, $p->{ streak } ),
                    $target,
                    ];
            }

            for my $y ( sort { $a <=> $b } keys %rows )
            {
                my @v = unpack 'C*', $px->row( $y );

                for my $spec ( @{ $rows{ $y } } )
                {
                    my ( $x, $len, $target ) = @$spec;
                    my $end = $x + $len - 1;
                    $end = $w - 1 if $end > $w - 1;

                    for my $i ( $x .. $end )
                    {
                        my $base = $i * 3;
                        $v[ $_ ] =
                            int( $v[ $_ ] +
                                ( $target - $v[ $_ ] ) * $p->{ intensity } )
                            for $base .. $base + 2;
                    }
                }

                $px->set_row( $y, pack 'C*', @v );
            }
        }
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'softness',
    title   => 'Lens Softness',
    stage   => 'optics',
    summary => 'Lens softness with an oversharpened edge',
    doc     => <<'DOC',
Blurs, then sharpens harder than the blur removed. The combination gives the
haloed, slightly mushy look of a picture that has been through a cheap lens and
then had edge enhancement applied to compensate -- which is exactly what
consumer camcorders did.
DOC
    params => {
        blur => {
            default => 0.8,
            type    => 'num',
            min     => 0,
            max     => 40,
            doc     => 'Blur sigma',
        },
        sharpen => {
            default => 1.6,
            type    => 'num',
            min     => 0,
            max     => 20,
            doc     => 'Unsharp mask amount applied afterwards',
        },
        radius => {
            default => 2,
            type    => 'num',
            min     => 0.1,
            max     => 40,
            doc     => 'Unsharp mask radius; larger gives wider halos',
        },
        pulse => {
            default   => 0,
            type      => 'num',
            min       => 0,
            max       => 1,
            animation => 1,
            doc => 'Breathing of the blur across a loop, as a fraction of it',
        },
    },
    apply => sub {
        my ( $ctx, $p ) = @_;
        my $img = $ctx->image;

        # A focus that drifts in and out. An excursion rather than a travel:
        # a lens has nowhere to go, it wanders either side of where it is set,
        # and that closes the loop at any value -- see GlitchVape::Context.
        my $blur = $p->{ blur } * ( 1 + $ctx->excursion( $p->{ pulse } ) );
        $blur = 0 if $blur < 0;

        $img->Blur( radius => 0, sigma => $blur ) if $blur > 0;

        $img->UnsharpMask(
            radius    => $p->{ radius },
            sigma     => $p->{ radius } / 2,
            amount    => $p->{ sharpen },
            threshold => 0,
        ) if $p->{ sharpen } > 0;

        return;
    },
);

# ---------------------------------------------------------------------------

$R->register(
    name    => 'dither',
    title   => 'Ordered Dither',
    stage   => 'grain',
    summary => 'Ordered dithering to a reduced bit depth',
    doc     => <<'DOC',
Quantises each channel to a small number of levels using a threshold matrix,
producing the regular cross-hatch of an early graphics adapter rather than the
random speckle of error diffusion.

C<reroll> moves the matrix to a different cell on every frame of a loop, which
is temporal dithering: the pattern stops being a texture printed on the
picture and starts shimmering, the way a display faking colours it does not
have actually looks. It is off by default, because a still cannot show it and
because the fixed cross-hatch is the thing most renders are after.
DOC
    params => {
        map => {
            default => 'o8x8',
            type    => 'enum',
            values  => [ qw(threshold checks o2x2 o3x3 o4x4 o8x8) ],
            doc     => 'ImageMagick threshold map',
        },
        levels => {
            default => 3,
            type    => 'int',
            min     => 2,
            max     => 32,
            doc     => 'Levels per channel',
        },
        reroll => {
            label     => 'Varying pattern',
            animation => 1,
            default   => 0,
            type      => 'bool',
            doc       => 'Move the matrix each frame, so flat areas shimmer '
                . 'rather than holding one cross-hatch',
        },
    },
    apply => \&_dither,
);

# How wide the threshold map repeats. Rolling by a whole period would be no
# roll at all, so the offset is drawn from within one -- and 'threshold' has
# no period to speak of, which is why it cannot shimmer.
my %DITHER_PERIOD = (
    threshold => 1,
    checks    => 2,
    o2x2      => 2,
    o3x3      => 3,
    o4x4      => 4,
    o8x8      => 8,
);

sub _dither
{
    my ( $ctx, $p ) = @_;

    my ( $dx, $dy ) = _dither_offset( $ctx, $p );

    # ImageMagick's ordered dither has no offset of its own, so the picture is
    # moved under the matrix instead and moved back afterwards. -roll is a
    # circular shift, so nothing is lost at the edges and the second roll
    # returns every pixel to where it started -- only which cell of the matrix
    # it met has changed.
    if ( $dx || $dy )
    {
        $ctx->magick( '-roll', sprintf( '%+d%+d', $dx, $dy ) );
    }

    $ctx->magick( '-ordered-dither', "$p->{map},$p->{levels}" );

    if ( $dx || $dy )
    {
        $ctx->magick( '-roll', sprintf( '%+d%+d', -$dx, -$dy ) );
    }

    return;
}

sub _dither_offset
{
    my ( $ctx, $p ) = @_;

    return ( 0, 0 ) unless $p->{ reroll };
    return ( 0, 0 ) if $ctx->frames <= 1;

    my $period = $DITHER_PERIOD{ $p->{ map } } // 1;
    return ( 0, 0 ) if $period < 2;

    my $rng = $ctx->rng_for( 'dither' );

    return (
        $rng->int_between( 0, $period - 1 ),
        $rng->int_between( 0, $period - 1 )
    );
}

1;
