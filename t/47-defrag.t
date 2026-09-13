#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape                  ();
use GlitchVape::Chicago         ();
use GlitchVape::Context         ();
use GlitchVape::Defrag          ();
use GlitchVape::Fonts           ();
use GlitchVape::Effect::Texture ();
use GlitchVape::Pipeline        ();
use GlitchVape::Registry        ();
use GlitchVape::Tools           ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# A cluster map is a grid of blocks on paper, and almost everything that could
# go wrong with it is invisible in a thumbnail: an outline a pixel out, a
# chequer that averaged itself away when the block was enlarged, a free-space
# setting that gave a third of the disk on one photograph and none on another.
#
# So the questions below are asked of the pixels rather than of the look.

my $dir = File::Temp->newdir( 'gv_defrag_XXXXXX', TMPDIR => 1 );

sub source
{
    my ( $w, $h, $what ) = @_;

    $what ||= 'gradient:black-white';

    my $path = "$dir/src-${w}x$h-" . ( $what =~ s/\W+/_/gr ) . '.png';
    return $path if -e $path;

    my $img = Image::Magick->new( size => "${w}x$h" );
    $img->Read( $what );

    my $err = $img->Write( $path );
    BAIL_OUT( "could not build the test source image: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;

    return $path;
}

sub render
{
    my ( $src, %given ) = @_;

    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new(
        image  => $img,
        source => $src,
        seed   => 11,
    );

    # Bare, unless the caller says otherwise: a window round the map moves
    # every cell of it, and all but one of the blocks below is reading pixels
    # off the grid at a known offset.
    GlitchVape::Pipeline->new(
        effects => { defrag => { window => 0, %given } } )->run( $ctx );

    return $ctx->image;
}

# Every pixel of a render, as a list of [r,g,b].
sub pixels
{
    my ( $img ) = @_;

    my ( $w, $h ) = $img->Get( 'width', 'height' );

    # Normalised, so what comes back is 0..1 whatever quantum depth this
    # ImageMagick was built with, and scaled to the bytes the module deals in.
    my @v = $img->GetPixels(
        map       => 'RGB',
        normalize => 1,
        x         => 0,
        y         => 0,
        width     => $w,
        height    => $h
    );

    my @out;
    for my $n ( 0 .. $w * $h - 1 )
    {
        push @out, [ map { int( $v[ $n * 3 + $_ ] * 255 + 0.5 ) } 0 .. 2 ];
    }

    return ( \@out, $w, $h );
}

sub at
{
    my ( $px, $w, $x, $y ) = @_;
    return $px->[ $y * $w + $x ];
}

sub same { return "@{ $_[ 0 ] }" eq "@{ $_[ 1 ] }" }

# ---------------------------------------------------------------------------
# The palettes are complete, and every state is in every one of them

# The tables are hand-written and the derived ones are not, so the way this
# rots is a state added to the list and left out of scandisk -- which shows up
# as that state simply never appearing, in one palette, at one setting.
{
    my @states = GlitchVape::Defrag::states();

    cmp_ok scalar @states, '>=', 9,
        'there are at least as many states as the legend had';

    for my $palette ( GlitchVape::Defrag::palettes() )
    {
        my $map = GlitchVape::Defrag::map_for( $palette );

        is scalar @{ $map->{ states } }, scalar @states,
            "$palette has a colour for every state";

        is_deeply [ map { $_->{ name } } @{ $map->{ states } } ], \@states,
            "and in the same order, so a state means the same thing in each";

        # Free space is the paper and nothing else, so a state the same colour
        # as the paper is a block nobody can see.
        my $paper = $map->{ paper };
        my @invisible =
            grep { same( $_->{ avg }, $paper ) } @{ $map->{ states } };

        is_deeply [ map { $_->{ name } } @invisible ], [],
            "and no state in $palette is the colour of its own paper";
    }

    is_deeply GlitchVape::Defrag::map_for( 'no such palette' ),
        GlitchVape::Defrag::map_for( 'defrag' ),
        'and answered with the default, since a preset can outlive a build';
}

# ---------------------------------------------------------------------------
# A cell is a rectangle

# The first thing the eye picks up about the real window, and the easiest
# thing to get wrong: 'a grid of small blocks' sounds square and this one is
# not. Eight across and ten down, and the proportion holds at every pitch
# because the height is worked out rather than set.
{
    is_deeply [ GlitchVape::Defrag::cell( 8 ) ], [ 8, 10 ],
        'the cell is the size it was drawn at: eight across, ten down';

    for my $block ( 4, 8, 12, 16, 24, 48 )
    {
        my ( $w, $h ) = GlitchVape::Defrag::cell( $block );

        is $w, $block, "a pitch of $block is $block across";

        cmp_ok $h, '>', $w, "and taller than it is wide";

        cmp_ok abs( $h / $w - 10 / 8 ), '<', 0.13,
            'in about the proportion the real one was'
            or diag "got ${w}x$h";
    }
}

# ---------------------------------------------------------------------------
# A block is an outline, a chequer and a gap

# The three things measured off the screenshot. Asked at the pitch it was
# drawn at, where each of them is exactly one pixel.
{
    my $map = GlitchVape::Defrag::map_for( 'defrag' );

    my ( $state ) =
        grep { $_->{ name } eq 'optimised' } @{ $map->{ states } };

    ok $state->{ b }, 'the optimised state is two inks, as the display was';

    my $stamp = GlitchVape::Defrag::stamp(
        state => $state,
        block => 8,
        paper => $map->{ paper },
        edge  => $map->{ edge },
    );

    is length $stamp, 8 * 10 * 3, 'a stamp is exactly one cell of pixels';

    my @px   = map { [ unpack 'C3', substr $stamp, $_ * 3, 3 ] } 0 .. 79;
    my $cell = sub { return $px[ $_[ 1 ] * 8 + $_[ 0 ] ] };

    is_deeply $cell->( 7, 0 ), $map->{ paper },
        'the last column is paper, which is the gap to the next block';
    is_deeply $cell->( 0, 9 ), $map->{ paper }, 'and so is the last row';

    is_deeply $cell->( 0, 8 ), $map->{ edge },
        'the row above that one is the block, which is nine deep and not seven';

    is_deeply $cell->( 0, 0 ), $map->{ edge }, 'the block has an outline';
    is_deeply $cell->( 6, 8 ), $map->{ edge }, 'on all four sides';

    # The interior is the two inks in a checkerboard, which is what a
    # sixteen-colour display did to make a colour it did not have.
    is_deeply $cell->( 1, 1 ), $state->{ a }, 'the interior starts on one ink';
    is_deeply $cell->( 2, 1 ), $state->{ b }, 'and alternates to the other';
    is_deeply $cell->( 1, 2 ), $state->{ b }, 'down as well as across';
    is_deeply $cell->( 2, 2 ), $state->{ a }, 'so it is a chequer, not stripes';
}

# ---------------------------------------------------------------------------
# Enlarging replicates the design rather than redrawing it bigger

# The rule GlitchVape::Chicago follows, for the same reason: a one-pixel
# outline that has been interpolated is a grey smear, and a chequer whose
# squares have been averaged together is a flat fill of the colour it was
# supposed to be making.
{
    my $map = GlitchVape::Defrag::map_for( 'defrag' );
    my ( $state ) =
        grep { $_->{ name } eq 'optimised' } @{ $map->{ states } };

    is GlitchVape::Defrag::unit( 8 ),  1, 'eight is the size it was drawn at';
    is GlitchVape::Defrag::unit( 16 ), 2, 'sixteen is that doubled';
    is GlitchVape::Defrag::unit( 24 ), 3, 'and twenty-four trebled';
    is GlitchVape::Defrag::unit( 3 ),  1, 'below eight it stays at one';

    my $big = GlitchVape::Defrag::stamp(
        state => $state,
        block => 16,
        paper => $map->{ paper },
        edge  => $map->{ edge },
    );

    my @px   = map { [ unpack 'C3', substr $big, $_ * 3, 3 ] } 0 .. 16 * 20 - 1;
    my $cell = sub { return $px[ $_[ 1 ] * 16 + $_[ 0 ] ] };

    is_deeply $cell->( 14, 0 ),  $map->{ paper }, 'the gap is two pixels wide';
    is_deeply $cell->( 15, 0 ),  $map->{ paper }, 'not one';
    is_deeply $cell->( 0,  18 ), $map->{ paper }, 'and two deep at the bottom';

    is_deeply $cell->( 1, 1 ), $map->{ edge }, 'and the outline two deep';

    # Two by two squares of each ink, which is the eight-pixel design with
    # every pixel doubled.
    is_deeply $cell->( 2, 2 ), $state->{ a }, 'a chequer square starts here';
    is_deeply $cell->( 3, 3 ), $state->{ a }, 'and is two pixels across';
    is_deeply $cell->( 4, 2 ), $state->{ b }, 'before the other ink begins';
}

# ---------------------------------------------------------------------------
# Free space is paper, and there is the share of it that was asked for

# The half that makes this read as a disk rather than as a mosaic, and the
# half most likely to stop working quietly: a threshold in brightness would
# give a dark photograph a full disk and a bright one an empty disk from the
# same setting, which is a slider that does nothing on most pictures.
{
    my $map   = GlitchVape::Defrag::map_for( 'defrag' );
    my $paper = $map->{ paper };

    # Counted a cell at a time, at the corner of each one, which is the
    # outline on a block and paper on free space.
    my $empty = sub {
        my ( $img, $block ) = @_;

        my ( $px, $w, $h ) = pixels( $img );
        my ( $cw, $ch ) = GlitchVape::Defrag::cell( $block );

        my ( $cols, $rows ) = ( int( $w / $cw ), int( $h / $ch ) );

        my $ox = int( ( $w - $cols * $cw ) / 2 );
        my $oy = int( ( $h - $rows * $ch ) / 2 );

        my $free = 0;
        for my $y ( 0 .. $rows - 1 )
        {
            for my $x ( 0 .. $cols - 1 )
            {
                $free++
                    if same( at( $px, $w, $ox + $x * $cw, $oy + $y * $ch ),
                    $paper );
            }
        }

        return $free / ( $cols * $rows );
    };

    for my $what ( 'gradient:black-white', 'xc:gray20', 'xc:gray85' )
    {
        my $src = source( 320, 240, $what );

        for my $want ( 0, 0.25, 0.6 )
        {
            my $got = $empty->(
                render( $src, block => 8, free => $want, scatter => 0 ), 8
            );

            cmp_ok abs( $got - $want ), '<', 0.06,
                "free $want leaves about that much of $what empty"
                or diag sprintf 'got %.2f', $got;
        }
    }
}

# ---------------------------------------------------------------------------
# Fragmentation frays the edge rather than moving it

# Without it the used and free halves sort strictly by brightness, which on a
# gradient is one straight line across the picture -- a posterised photograph
# rather than a disk. What scatter has to do is disturb that boundary while
# leaving about as much of the disk empty as was asked for.
{
    my $src   = source( 320, 240 );
    my $map   = GlitchVape::Defrag::map_for( 'defrag' );
    my $paper = $map->{ paper };

    # How many cells have a neighbour in the other state. On a clean split
    # that is one row of them; fraying the boundary makes many more.
    my $ragged = sub {
        my ( $scatter ) = @_;

        my ( $px, $w ) = pixels(
            render(
                $src,
                block   => 8,
                free    => 0.5,
                scatter => $scatter
            )
        );

        # 320 by 240 at a cell of 8 by 10, which divides exactly both ways.
        my ( $cols, $rows ) = ( 40, 24 );

        my @free;
        for my $y ( 0 .. $rows - 1 )
        {
            for my $x ( 0 .. $cols - 1 )
            {
                $free[ $y ][ $x ] =
                    same( at( $px, $w, $x * 8, $y * 10 ), $paper ) ? 1 : 0;
            }
        }

        my $edges = 0;
        for my $y ( 0 .. $rows - 2 )
        {
            for my $x ( 0 .. $cols - 2 )
            {
                $edges++ if $free[ $y ][ $x ] != $free[ $y ][ $x + 1 ];
                $edges++ if $free[ $y ][ $x ] != $free[ $y + 1 ][ $x ];
            }
        }

        return $edges;
    };

    my $clean  = $ragged->( 0 );
    my $frayed = $ragged->( 0.6 );

    cmp_ok $frayed, '>', 3 * $clean,
        'fragmentation puts many more cells on a boundary'
        or diag "clean $clean, frayed $frayed";
}

# ---------------------------------------------------------------------------
# The same seed gives the same disk

# Which clusters are empty is a fact about the disk rather than about the
# moment, so it is drawn from the fixed stream: a still has to render the same
# way twice, and a frame of an animation has to render the same way as the one
# before it or the map strobes under a picture that has not moved.
{
    my $src = source( 320, 240 );

    my ( $a ) = pixels( render( $src, seed => 7 ) );
    my ( $b ) = pixels( render( $src, seed => 7 ) );
    my ( $c ) = pixels( render( $src, seed => 8 ) );

    is_deeply $a, $b, 'the same layout seed gives the same map';
    ok !eq_array( $a, $c ), 'and a different one gives a different map';
}

# ---------------------------------------------------------------------------
# It is registered where the rest of the chain can work on what it leaves

{
    my $spec = GlitchVape::Registry->get( 'defrag' );

    ok $spec, 'defrag is registered';
    is $spec->{ stage }, 'format',
        'at format, so everything after it happens to the grid';

    is_deeply $spec->{ params }{ palette }{ values },
        [ GlitchVape::Defrag::palettes() ],
        'and it offers exactly the palettes the module has';

    # A picture too small to hold a grid is left alone rather than turned into
    # four coloured rectangles.
    my $tiny = source( 10, 10 );
    my ( $before ) = pixels(
        do
        {
            my $i = Image::Magick->new;
            $i->Read( $tiny );
            $i;
        }
    );
    my ( $after ) = pixels( render( $tiny, block => 8 ) );

    is_deeply $after, $before,
        'a picture with no room for a grid comes back untouched';
}

# ---------------------------------------------------------------------------
# The window comes with the map

# A cluster map without the window round it is a mosaic, so the window is part
# of the effect rather than something to remember to add afterwards -- and it
# is GlitchVape::Chicago::wrap, the same call 'maximised' makes, because a
# second window-drawing implementation would be a second place for a bevel to
# go wrong.
{
    my $src = source( 320, 240 );

    my $bare = render( $src, window => 0 );
    my ( $bw, $bh ) = $bare->Get( 'width', 'height' );

    is $bw . 'x' . $bh, '320x240',
        'without the window the map is the size of the picture';

    my $framed = render( $src, window => 1 );
    my ( $fw, $fh ) = $framed->Get( 'width', 'height' );

    cmp_ok $fw, '>', $bw, 'with it the picture grows by the frame';
    cmp_ok $fh, '>', $fw - $bw + $bh,
        'and by more down than across, which is the caption bar';

    # Whatever 'maximised' would have made of the same map, to the pixel. The
    # claim is not that the two look alike but that there is one of them.
    my $again = GlitchVape::Chicago::wrap(
        image      => $bare,
        theme      => 'default',
        caption    => 'Defragmenting Drive C',
        font       => GlitchVape::Fonts::resolve( 'ui' ),
        icon       => 'notepad',
        menu       => undef,
        scrollbars => 0,
    );

    is_deeply [ ( pixels( $framed ) )[ 0 ] ], [ ( pixels( $again ) )[ 0 ] ],
        'and the window is the one Chicago draws, not a copy of it';

    # The caption is settable, since what the drive is called is not a fact
    # about defragmenting; the rest of the chrome is not, because it is.
    my $named = render( $src, window => 1, title => 'Checking Drive D' );

    ok !eq_array( ( pixels( $named ) )[ 0 ], ( pixels( $framed ) )[ 0 ] ),
        'the caption is settable';
}

done_testing;
