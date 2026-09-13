#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use List::Util qw(max);
use Test::More;

use GlitchVape                  ();
use GlitchVape::Chicago         ();
use GlitchVape::Context         ();
use GlitchVape::Defrag          ();
use GlitchVape::Fonts           ();
use GlitchVape::Palette         ();
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

# What the eye makes of a colour, and how far apart two of them are to it.
# Both the same weighting nearest() matches by, because a claim about how far
# apart two states are has to be measured the way the thing that tells them
# apart measures.
sub luma
{
    my ( $rgb ) = @_;
    return 0.299 * $rgb->[ 0 ] + 0.587 * $rgb->[ 1 ] + 0.114 * $rgb->[ 2 ];
}

sub weighted
{
    my ( $a, $b ) = @_;

    return
        sqrt 2 * ( $a->[ 0 ] - $b->[ 0 ] )**2 +
        4 * ( $a->[ 1 ] - $b->[ 1 ] )**2 +
        3 * ( $a->[ 2 ] - $b->[ 2 ] )**2;
}

# The two states of a palette that are nearest to being the same state, and
# how far apart they are, as ( $distance, $one, $other ).
sub closest_states
{
    my ( $palette ) = @_;

    my @states = @{ GlitchVape::Defrag::map_for( $palette )->{ states } };

    my ( $closest, @pair ) = ( 1e9 );
    for my $i ( 0 .. $#states )
    {
        for my $j ( $i + 1 .. $#states )
        {
            my $d = weighted( $states[ $i ]{ avg }, $states[ $j ]{ avg } );
            next if $d >= $closest;

            ( $closest, @pair ) =
                ( $d, $states[ $i ]{ name }, $states[ $j ]{ name } );
        }
    }

    return ( $closest, @pair );
}

# The steps between one state's brightness and the next, sorted, so that the
# first is the two states a grey ramp would flatten together and the last is
# the widest hole in it.
sub brightness_steps
{
    my ( $palette ) = @_;

    my @lit = sort { $a <=> $b }
        map { luma( $_->{ avg } ) }
        @{ GlitchVape::Defrag::map_for( $palette )->{ states } };

    my @step =
        sort { $a <=> $b } map { $lit[ $_ ] - $lit[ $_ - 1 ] } 1 .. $#lit;

    return @step;
}

# That no two of a palette's states are near enough to be taken for one, which
# would leave whichever nearest() reaches second with nothing on the map.
sub no_two_alike
{
    my ( $palette ) = @_;

    my ( $closest, @pair ) = closest_states( $palette );

    cmp_ok $closest, '>', 89,
        "no two states in $palette are near enough to be one state"
        or diag sprintf '%s and %s are %.0f apart', @pair, $closest;

    return;
}

# That every scheme has a bright ground with an outline round its blocks, or
# is one of the two that are a monitor rather than a window -- and that the
# outline goes with the ground rather than being set beside it. On paper a
# block needs an edge to be a block, since the palest states sit a shade off
# the ground; on a screen the block is the lit thing and a rim is a hole in
# the glow. So the pairing is the claim, in both directions.
sub every_scheme_grounds_itself
{
    my %screen = map { $_ => 1 } qw(amber phos);

    for my $palette ( GlitchVape::Defrag::palettes() )
    {
        my $map = GlitchVape::Defrag::map_for( $palette );
        my $lit = luma( $map->{ paper } ) > 128;

        if ( $screen{ $palette } )
        {
            ok !$lit, "$palette is a screen, so its free space is unlit";
        }
        else
        {
            ok $lit, "$palette leaves free space bright, which is the goal";
        }

        is !!$map->{ edge }, !!$lit,
            "and $palette outlines its blocks exactly if it is on paper";
    }

    return;
}

# How many of a palette's states a picture actually reaches, and what share
# the commonest of them takes. Both, because they fail in opposite directions:
# a picture can touch a dozen states and still be nine tenths one of them.
sub reach
{
    my ( $grid, $spread ) = @_;

    my $states = GlitchVape::Defrag::map_for( 'defrag' )->{ states };

    my $at = GlitchVape::Defrag::match_grid(
        states => $states,
        grid   => $grid->{ cells },
        cols   => $grid->{ cols },
        rows   => $grid->{ rows },
        spread => $spread,
    );

    my %count;
    $count{ $_ }++ for @$at;

    return ( scalar keys %count, max( values %count ) / scalar @$at );
}

# A picture reduced to one colour per cell, which is what the effect matches
# against. A photograph rather than a ramp: a gradient touches every state by
# construction and would say nothing about the thing being measured.
sub grid_of
{
    my ( $what, $cols, $rows ) = @_;

    my $img = Image::Magick->new;
    $img->Read( source( 320, 240, $what ) );
    $img->Resize( geometry => "${cols}x$rows!", filter => 'Box' );

    my @v = $img->GetPixels(
        map       => 'RGB',
        normalize => 1,
        x         => 0,
        y         => 0,
        width     => $cols,
        height    => $rows
    );

    my @cells;
    for my $n ( 0 .. $cols * $rows - 1 )
    {
        push @cells, [ map { int( $v[ $n * 3 + $_ ] * 255 + 0.5 ) } 0 .. 2 ];
    }

    return { cells => \@cells, cols => $cols, rows => $rows };
}

# A flat disc on a flat ground: one edge, in a place this file knows. The
# disc is the bright thing, because that is the case the setting exists for --
# a dark subject is kept by the ranking anyway, and it is a bright one that
# gets emptied along with the sky behind it.
sub disc_source
{
    my ( $round ) = @_;

    my $path = "$dir/disc-$round.png";
    return $path if -e $path;

    my $img = Image::Magick->new( size => '320x240' );
    $img->Read( 'xc:gray70' );
    $img->Draw(
        primitive => 'circle',
        points    => "160,120 160,@{[ 120 - $round ]}",
        fill      => 'white'
    );

    my $err = $img->Write( $path );
    BAIL_OUT( "could not draw the test disc: $err" )
        if "$err" && "$err" =~ /^Exception \s+ (\d+)/x && $1 >= 400;

    return $path;
}

# What the effect makes of how much is going on in each cell, asked of the
# measurement itself rather than of what the ranking then did with it.
#
# Its own block, because this is the half that broke: the measurement was
# ImageMagick's edge detector, which came back at 26 of 255 here and at
# nothing at all on the ImageMagick in Fedora's container -- so the setting
# worked on one machine and silently did nothing on another, and the test
# that noticed could only say that no cells had moved.
sub detail_of
{
    my ( $src, $cols, $rows ) = @_;

    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new( image => $img, seed => 3 );

    ## no critic (Subroutines::ProtectPrivateSubs)
    return GlitchVape::Effect::Texture::_cluster_detail( $ctx, $cols, $rows );
    ## use critic
}

# Which cells of the disc picture come back with a block on them, as cell
# numbers across a 40 by 24 grid.
sub disc_cells
{
    my ( $src, $detail ) = @_;

    my $paper = GlitchVape::Defrag::map_for( 'defrag' )->{ paper };

    my ( $px, $w ) = pixels(
        render(
            $src,
            block   => 8,
            free    => 0.5,
            scatter => 0,
            dither  => 0,
            detail  => $detail
        )
    );

    my @on;
    for my $y ( 0 .. 23 )
    {
        for my $x ( 0 .. 39 )
        {
            push @on, $y * 40 + $x
                unless same( at( $px, $w, $x * 8, $y * 10 ), $paper );
        }
    }

    return \@on;
}

# That the measurement itself answers, and answers about the edge: one value
# per cell, not all the same, and the busiest cells on the circle.
sub detail_finds_the_edge
{
    my ( $src, $round ) = @_;

    my $detail = detail_of( $src, 40, 24 );

    is scalar @$detail, 40 * 24, 'the detail map has one value per cell';

    my %seen = map { $_ => 1 } @$detail;

    cmp_ok scalar keys %seen, '>', 1,
        'a picture with an edge in it does not measure as flat everywhere'
        or diag 'every cell came back as '
        . ( keys %seen )[ 0 ]
        . ' -- the measurement found nothing, which is what an edge '
        . 'detector did on another machine';

    # The busiest twenty cells, which on this picture can only be the circle.
    my @quiet   = sort { $detail->[ $a ] <=> $detail->[ $b ] } 0 .. $#$detail;
    my @busiest = ( reverse @quiet )[ 0 .. 19 ];

    is on_rim( \@busiest, $round ), scalar @busiest,
        'and the cells it finds busiest are the ones the circle runs through';

    return;
}

# How many of those cells the circle passes through. Measured in cells, and a
# row is ten pixels where a column is eight -- so both have to be put in the
# same units before either can be compared with a radius.
sub on_rim
{
    my ( $cells, $round ) = @_;

    return scalar grep {
        my $x = ( $_ % 40 + 0.5 ) * 8;
        my $y = ( int( $_ / 40 ) + 0.5 ) * 10;

        abs( sqrt( ( $x - 160 )**2 + ( $y - 120 )**2 ) - $round ) / 8 < 1
    } @$cells;
}

# That carrying the error reaches more of the palette and puts less of the
# grid on the one commonest state. Both, because they fail in opposite
# directions and either alone would pass on a picture that had got worse.
sub palette_widens
{
    my ( $grid ) = @_;

    my ( $alone,  $worst ) = reach( $grid, 0 );
    my ( $spread, $best )  = reach( $grid, 0.75 );

    cmp_ok $spread, '>', $alone,
        'carrying the error reaches more of the palette than rounding alone'
        or diag "$alone states alone, $spread with it";

    cmp_ok $best, '<', $worst,
        'and leaves less of the grid on the one commonest state'
        or diag sprintf 'largest share %.0f%% alone, %.0f%% with it',
        100 * $worst, 100 * $best;

    return;
}

# That the detail term spends the cells it takes on the picture's one edge,
# rather than merely shuffling which flat cell goes empty.
sub detail_moves_them_to_the_edge
{
    my ( $flat, $edgy, $round ) = @_;

    my %flat   = map  { $_ => 1 } @$flat;
    my @gained = grep { !$flat{ $_ } } @$edgy;

    cmp_ok scalar @gained, '>', 0, 'but it does change which cells those are';

    cmp_ok on_rim( $edgy, $round ), '>', on_rim( $flat, $round ),
        'and what it spends them on is the edge'
        or diag sprintf 'rim cells kept: %d without, %d with',
        on_rim( $flat, $round ), on_rim( $edgy, $round );

    return;
}

# That nought is not 'a little of it'. A setting whose bottom end is not the
# behaviour it replaces cannot be turned off, and every preset written before
# it existed is then rendering something nobody chose.
sub nought_is_plain_matching
{
    my ( $grid ) = @_;

    my $states = GlitchVape::Defrag::map_for( 'defrag' )->{ states };

    return is_deeply GlitchVape::Defrag::match_grid(
        states => $states,
        grid   => $grid->{ cells },
        cols   => $grid->{ cols },
        rows   => $grid->{ rows },
        spread => 0,
        ),
        [ map { GlitchVape::Defrag::nearest( $states, $_ ) }
            @{ $grid->{ cells } } ],
        'and at nought it is the nearest state to each cell, cell by cell';
}

# A disk with holes in it, in a shape this file can do arithmetic about: every
# third cluster free, and each of the rest a different state so that the order
# they come back in can be read off. Name a state and every cluster is that
# one instead, for the questions where what is on the disk would otherwise be
# mistaken for what the pass did to it.
#
# Returns the disk and the data on it.
sub holed_disk
{
    my ( $states, $one ) = @_;

    my ( $same ) =
        grep { $states->[ $_ ]{ name } eq ( $one // q{} ) } 0 .. $#$states;

    my @cells = map {
        $_ % 3 == 2 ? 0 : 1 + ( defined $same ? $same : $_ % scalar @$states )
    } 0 .. 89;

    return ( \@cells, [ grep { $_ } @cells ] );
}

# One disk, that far into being defragmented. No head, so that what comes back
# is the compaction alone -- the two lit clusters are asked about on their own.
sub swept
{
    my ( $cells, $states, $front ) = @_;

    return GlitchVape::Defrag::sweep(
        cells  => [ @$cells ],
        states => $states,
        front  => $front,
        head   => 0
    );
}

# What a compaction promises, asked at one point of the pass: that nothing is
# lost or invented, that the clusters are still in the order they were in, and
# that what is behind the front has no holes left in it.
sub compaction_holds
{
    my ( $before, $data, $states ) = @_;

    holds_at( $before, $data, $states, $_ ) for 0.25, 0.5, 0.75, 1;

    return;
}

sub holds_at
{
    my ( $before, $data, $states, $front ) = @_;

    my $after = swept( $before, $states, $front );

    is scalar( grep { $_ } @$after ), scalar @$data,
        "nothing is lost or invented at $front"
        or diag sprintf 'was %d clusters, now %d', scalar @$data,
        scalar( grep { $_ } @$after );

    is_deeply [ grep { $_ } @$after ], $data,
        "and the clusters are still in the order they were at $front";

    my $moved = int( $front * scalar @$data + 0.5 );

    is_deeply [ grep { !$after->[ $_ ] } 0 .. $moved - 1 ], [],
        "everything behind the front is packed solid at $front";

    return;
}

# That the end of a pass is the data in one run at the beginning with nothing
# after it, which is what a defragmented disk is -- and that a disk with
# hardly anything on it gets there at the same front as a full one, since the
# front counts clusters moved rather than cells crossed.
sub finished_is_one_run
{
    my ( $before, $data, $states ) = @_;

    my $done = swept( $before, $states, 1 );

    is_deeply [ @{ $done }[ 0 .. $#$data ] ], $data,
        'a finished pass leaves the data in one run at the beginning';

    is_deeply [ grep { $_ } @{ $done }[ scalar @$data .. $#$done ] ], [],
        'and nothing at all after it';

    my @sparse = map { $_ % 5 == 0 ? 1 : 0 } 0 .. 89;
    my $packed = swept( \@sparse, $states, 1 );

    is_deeply [ grep { $packed->[ $_ ] } 0 .. $#$packed ],
        [ 0 .. scalar( grep { $_ } @sparse ) - 1 ],
        'a disk with little on it is finished by the same front as a full one';

    return;
}

# That a pass under way lights the head at both ends -- writing at the packed
# end, reading out where the next clusters still lie -- and that a finished
# one lights neither, a head flashing over a job that is done being the one
# thing here that would be a lie about what the window did.
sub the_head_is_lit
{
    my ( $before, $states ) = @_;

    cmp_ok lit( $before, $states, 0.5, 'writing' ), '>', 0,
        'a pass under way is writing at the packed end';

    cmp_ok lit( $before, $states, 0.5, 'reading' ), '>', 0,
        'and reading out where the next clusters still lie';

    is lit( $before, $states, 1, 'writing' ), 0,
        'a finished pass is not still writing';

    is lit( $before, $states, 1, 'reading' ), 0, 'nor reading';

    return;
}

# How many clusters of one state a pass has lit, with the head left on.
sub lit
{
    my ( $cells, $states, $front, $name ) = @_;

    my $after = GlitchVape::Defrag::sweep(
        cells  => [ @$cells ],
        states => $states,
        front  => $front
    );

    my ( $want ) = grep { $states->[ $_ ]{ name } eq $name } 0 .. $#$states;

    return scalar grep { $_ == 1 + $want } @$after;
}

# The palettes the rest of the program has that this one does not offer.
sub not_offered
{
    my %offered = map { $_ => 1 } GlitchVape::Defrag::palettes();

    return grep { !$offered{ $_ } } GlitchVape::Palette::names();
}

# That defrag is spread in brightness as well as in colour, which is what
# every derived palette needs of it: two states of the same brightness there
# are the same colour in mono whatever their hues were here, and a hole in the
# ramp is a run of the picture with no cluster state to land on.
sub brightness_is_spread
{
    my @step = brightness_steps( 'defrag' );

    cmp_ok $step[ 0 ], '>', 10,
        'and no two of defrag are the same brightness, which mono would flatten'
        or diag sprintf 'closest are %.1f apart', $step[ 0 ];

    cmp_ok $step[ -1 ], '<', 45, 'and there is no hole in the ramp either'
        or diag sprintf 'widest gap is %.1f', $step[ -1 ];

    return;
}

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
# The two hand-written tables are spread out, and the reasons differ

# A state drawn in the same colour as another one is a state that never
# appears: nearest() reaches whichever comes first and the other is a legend
# entry with nothing on the map under it. Which is a thing to measure rather
# than to look at -- scandisk shipped with two of them, written as
# 'silver, grey' in one place and 'grey, silver' in the other.
{
    no_two_alike( 'defrag' );
    no_two_alike( 'scandisk' );

    # And defrag alone is spread in brightness too, because it is the one
    # every derived palette reads as a ramp position.
    brightness_is_spread();
}

# ---------------------------------------------------------------------------
# Every palette the rest of the program has is a palette for the map

# Borrowed rather than listed, so a palette added for gradient_map is a
# cluster map's palette the same day. What is pinned here is that the
# borrowing happens at all, and that what is borrowed is the clusters and
# never the ground: a scheme that took its own darkest colour for paper is a
# picture of a lit screen, and there was one window and nineteen of those.
{
    is_deeply [ not_offered() ], [],
        'every named palette is offered as a cluster map';

    # gameboy, because four colours is the shortest ramp there is and so the
    # one most likely to fall over.
    my $map = GlitchVape::Defrag::map_for( 'gameboy' );

    is_deeply $map->{ paper }, [ 255, 255, 255 ],
        'a borrowed palette is spent on the clusters, and the paper stays white';

    # Sorted rather than reversed, because a machine's whole palette is in the
    # order the hardware numbered its colours and that is no order at all: the
    # C64's second entry is white and its third a dark red.
    my @lit = map { luma( $_->{ avg } ) }
        @{ GlitchVape::Defrag::map_for( 'c64' )->{ states } };

    cmp_ok $lit[ 0 ], '<', $lit[ -1 ],
        'and the ramp still darkens as a cluster fills, whatever order the '
        . 'palette was written in';

    is_deeply [ map { $_->{ b } } @{ $map->{ states } } ],
        [ ( undef ) x scalar GlitchVape::Defrag::states() ],
        'the blocks are flat, a chequer being a sixteen-colour display\'s trick';

    every_scheme_grounds_itself();

    # A name this module already uses keeps its own meaning: 'amber' is the
    # screen here rather than the five-stop ramp of the same name there, or a
    # preset that asked for it before would render as something else now.
    isnt sprintf( '#%02X%02X%02X',
        @{ GlitchVape::Defrag::map_for( 'amber' )->{ paper } } ),
        GlitchVape::Palette::colors( 'amber' )->[ 0 ],
        'a name this module already had is not taken over by the borrowed one';
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
        icon       => 'defrag',
        menu       => undef,
        scrollbars => 0,
        progress   => 0.4,
    );

    is_deeply [ ( pixels( $framed ) )[ 0 ] ], [ ( pixels( $again ) )[ 0 ] ],
        'and the window is the one Chicago draws, not a copy of it';

    # And the icon in the caption is the defragmenter's own rather than the
    # document page the chrome was scavenged from, because what is in the
    # caption of a program is that program.
    my $paged = GlitchVape::Chicago::wrap(
        image      => $bare,
        theme      => 'default',
        caption    => 'Defragmenting Drive C',
        font       => GlitchVape::Fonts::resolve( 'ui' ),
        icon       => 'notepad',
        menu       => undef,
        scrollbars => 0,
        progress   => 0.4,
    );

    ok !eq_array( ( pixels( $framed ) )[ 0 ], ( pixels( $paged ) )[ 0 ] ),
        'and the icon it wears is its own and not the notepad page';

    # The caption is settable, since what the drive is called is not a fact
    # about defragmenting; the rest of the chrome is not, because it is.
    my $named = render( $src, window => 1, title => 'Checking Drive D' );

    ok !eq_array( ( pixels( $named ) )[ 0 ], ( pixels( $framed ) )[ 0 ] ),
        'the caption is settable';
}

# ---------------------------------------------------------------------------
# The band under the map says the window is doing something

# The one piece of chrome 'maximised' has no use for, which is why it is a
# setting here and not there: a window around a photograph is not doing
# anything and this one is. What has to hold is that the band comes out of the
# window rather than out of the map -- a band that ate ten rows of clusters
# would be a setting that quietly changed the picture.
{
    my $src = source( 320, 240 );

    my $doing = render( $src, window => 1 );
    my $idle  = render( $src, window => 1, status => 0 );

    is $doing->Get( 'width' ), $idle->Get( 'width' ),
        'the band does not change how wide the window is';

    # At this size the window is drawn one chrome pixel to one image pixel,
    # so the band is its own height and no arithmetic is needed here.
    is $doing->Get( 'height' ) - $idle->Get( 'height' ),
        GlitchVape::Chicago::metrics()->{ status },
        'and makes it taller by exactly the band';

    # The map itself is untouched either way: cut the two windows back to the
    # rows the clusters are in and they agree to the pixel.
    my ( $a ) = pixels( $doing );
    my ( $b ) = pixels( $idle );
    my $rows  = 240 * $idle->Get( 'width' );

    is_deeply [ @{ $a }[ 0 .. $rows - 1 ] ], [ @{ $b }[ 0 .. $rows - 1 ] ],
        'and the cluster map is the same map with it and without it';

    my $spec = GlitchVape::Registry->get( 'defrag' );

    is_deeply $spec->{ params }{ progress }{ needs },
        { window => 1, status => 1 },
        'how far along means nothing without a band to say it on';

    is_deeply $spec->{ params }{ status }{ needs }, { window => 1 },
        'and the band means nothing without a window to put it in';

    # Two settings rather than a share with a magic value below the bottom of
    # its own range, because nought is a gauge that has not started yet and
    # that is a picture somebody may well want.
    ok !eq_array(
        ( pixels( render( $src, window => 1, progress => 0 ) ) )[ 0 ],
        ( pixels( render( $src, window => 1, status   => 0 ) ) )[ 0 ]
        ),
        'a gauge at nought is not the same picture as no gauge at all';
}

# ---------------------------------------------------------------------------
# The error a cluster cannot say is carried into the ones beside it

# Fourteen states is a small palette and a photograph does not spread itself
# evenly through colour space, so rounding each cell on its own puts most of
# the picture on whichever state sits in the middle of it. That is the failure
# this is for, and it is a failure about the *distribution* rather than about
# any one cell -- so what is asked here is how many states a picture reaches
# and how big its largest share is.
{
    my $grid = grid_of( 'plasma:fractal', 96, 96 );

    palette_widens( $grid );

    nought_is_plain_matching( $grid );

    # Deterministic, because the map has to be the same on every frame of a
    # loop and on every machine: there is no randomness in a diffusion, and
    # the serpentine walk must not depend on anything but the picture.
    my ( $once )  = reach( $grid, 0.75 );
    my ( $twice ) = reach( $grid, 0.75 );

    is $twice, $once, 'and the same picture diffuses the same way twice';
}

# ---------------------------------------------------------------------------
# Which clusters survive can be asked of the picture's edges

# Emptying the palest cells deletes a bright subject as readily as the sky
# behind it, so the detail term asks a second question of every cell -- is
# there an edge in it -- and keeps the ones there is something in. Two things
# have to hold: that it changes which cells go and not how many, and that what
# it keeps really is the edges.
#
# Asked of a disc on a flat ground, so that the picture has exactly one edge
# and this file knows where it is. A ramp would not do: a gradient has a
# derivative everywhere and an edge nowhere, so nothing would be measured.
{
    my $round = 60;
    my $src   = disc_source( $round );

    detail_finds_the_edge( $src, $round );

    my $flat = disc_cells( $src, 0 );
    my $edgy = disc_cells( $src, 0.8 );

    is scalar @$edgy, scalar @$flat,
        'keeping the detail does not change how much of the disk is empty';

    detail_moves_them_to_the_edge( $flat, $edgy, $round );

    my $spec = GlitchVape::Registry->get( 'defrag' );

    is_deeply $spec->{ params }{ detail }{ needs }, { free => 1 },
        'and with none of the disk empty there is nothing for it to choose';
}

# ---------------------------------------------------------------------------
# The pass moves the data rather than redrawing it

# What the window did was not a bar with a picture beside it: the picture was
# the progress, and the arithmetic under it is a real compaction. So the
# things worth pinning are the things a compaction promises -- that nothing is
# lost, that what is behind the front is solid, that what is ahead of it has
# not been touched -- rather than what any one cell came out as.
{
    my $states = GlitchVape::Defrag::map_for( 'defrag' )->{ states };

    my ( $before, $data ) = holed_disk( $states );

    is_deeply swept( $before, $states, 0 ), $before,
        'a pass that has not started leaves the disk alone';

    compaction_holds( $before, $data, $states );

    finished_is_one_run( $before, $data, $states );
}

# ---------------------------------------------------------------------------
# The head is lit, and only while there is work at it

# Two or three clusters flashing at the head is most of what the window looked
# like in motion, and it is the part that can quietly stop happening -- the
# compaction above is still correct with nothing lit, and a still frame of it
# looks perfectly reasonable.
{
    my $states = GlitchVape::Defrag::map_for( 'defrag' )->{ states };

    # Every cluster the same state, and that state neither of the two the head
    # lights: a disk that already had a red cluster on it would answer this
    # question with the picture rather than with the pass.
    my ( $before ) = holed_disk( $states, 'optimised' );

    the_head_is_lit( $before, $states );
}

done_testing;
