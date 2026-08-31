#!/usr/bin/perl

use strict;
use warnings;

# The ramp is CP437 rather than ASCII.
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use List::Util qw(any);
use Test::More;

use GlitchVape            ();
use GlitchVape::Random    ();
use GlitchVape::Registry  ();
use GlitchVape::Starfield ();
use GlitchVape::Tools     ();
use GlitchVape::VGA       ();

# The sky is pure arithmetic and needs nothing installed. Only the blocks that
# draw it want ImageMagick, and they skip themselves.
my $HAVE_MAGICK = eval { require Image::Magick; 1 };

sub sky
{
    my ( %arg ) = @_;

    return GlitchVape::Starfield::sky(
        rng => GlitchVape::Random->new( seed => $arg{ seed } || 11 )
            ->derive( 'stars' ),
        columns => 60,
        rows    => 22,
        stars   => 24,
        flare   => 0.6,
        %arg,
    );
}

# Where the stars are, and how bright each one is.
sub cells
{
    my ( $sky ) = @_;

    my %at;
    $at{ $_->[ 0 ] . ',' . $_->[ 1 ] } = $_->[ 2 ] for @$sky;

    return \%at;
}

# ---------------------------------------------------------------------------
# The ramp is a ramp

# Six characters that have to read as one star getting brighter rather than as
# a star changing character, which means each has to be plainly more lit than
# the one before it. Counted rather than eyeballed, because they are hex in a
# table and a typo in one of them is invisible until it is enormous.
{
    my @ramp = GlitchVape::Starfield::ramp();

    is scalar @ramp, 6, 'the ramp is the six the screensaver used';

    my @lit;
    for my $char ( @ramp )
    {
        my $glyph = GlitchVape::VGA::glyph( $char );

        ok $glyph, sprintf( 'the font has U+%04X', ord $char ) or next;

        my $on = 0;
        $on += sprintf( '%b', $_ ) =~ tr/1// for @$glyph;
        push @lit, $on;
    }

SKIP:
    {
        skip 'the font is missing one of them', 1 unless @lit == 6;

        my @backwards =
            grep { $lit[ $_ ] < $lit[ $_ - 1 ] } 1 .. $#lit;

        is_deeply \@backwards, [],
            'and every one of them is at least as lit as the one before'
            or diag "lit pixels along the ramp: @lit";
    }
}

# ---------------------------------------------------------------------------
# The animation is the same sky later

# The property the whole module exists for. Rolling a new sky every frame is
# the obvious implementation and the wrong one: what reads as twinkling is
# that the stars stay where they are between the moments they do not, and a
# sky re-rolled per frame has no continuity to twinkle against.
{
    my $before = cells( sky( step => 3 ) );
    my $after  = cells( sky( step => 4 ) );

    my $kept = grep { exists $after->{ $_ } } keys %$before;

    cmp_ok $kept, '>=', 0.8 * scalar keys %$before,
        'nearly every star is where it was on the step before';

    # And a star part way through a flare is one step further through it,
    # rather than a different star being alight somewhere else.
    my @carried = grep {
               $before->{ $_ }
            && exists $after->{ $_ }
            && $after->{ $_ } == $before->{ $_ } + 1
    } keys %$before;

    my @flaring = grep { $before->{ $_ } } keys %$before;

SKIP:
    {
        skip 'nothing was mid-flare at that step', 1 unless scalar @flaring;

        cmp_ok scalar @carried, '>', 0,
            'and a star mid-flare is one step brighter, not replaced';
    }
}

# ---------------------------------------------------------------------------
# A still is the sky part way through its life

# Not a fresh one. A sky nobody has stepped yet is a grid of identical dots:
# every star at rest, nothing having happened. Over a spread of seeds some of
# them have to be alight at step nought, which is what "settled" means.
{
    my $alight = 0;
    for my $seed ( 1 .. 40 )
    {
        $alight++ if any { $_->[ 2 ] } @{ sky( seed => $seed, step => 0 ) };
    }

    cmp_ok $alight, '>', 20,
        'most seeds have a flare in progress before the first frame is drawn';
}

# ---------------------------------------------------------------------------
# The same seed is the same sky, in a different process

# The trap this is here for: the flaring stars live in a hash, and walking its
# keys unsorted draws from the random stream in whatever order perl happened
# to hash them in. That order is deliberately different in every process, so
# the same seed would give a different sky on every run -- which is the one
# promise this program makes about seeds. Sorted, it does not.
#
# It cannot be caught in one process, because the order is fixed for the life
# of one. So this asks two.
SKIP:
{
    my $perl = $^X;
    skip 'no perl to run', 1 unless -x $perl;

    my $dir  = File::Temp->newdir( 'gv_sky_XXXXXX', TMPDIR => 1 );
    my $prog = "$dir/sky.pl";

    open my $fh, '>', $prog or die $!;
    print { $fh } <<'SCRIPT';
use strict;
use warnings;
use lib shift;
use GlitchVape ();
use GlitchVape::Random ();
use GlitchVape::Starfield ();
use GlitchVape::Tools     ();

my $rng = GlitchVape::Random->new( seed => 4242 )->derive( 'stars' );
my $sky = GlitchVape::Starfield::sky(
    rng => $rng, columns => 60, rows => 22,
    stars => 24, flare => 2, step => 6 );

print join ' ', map { join ',', @$_ } @$sky;
SCRIPT
    close $fh;

    my %seen;
    for my $run ( 1 .. 4 )
    {
        local $ENV{ PERL_HASH_SEED }    = $run * 7919;
        local $ENV{ PERL_PERTURB_KEYS } = 1;

        my $out =
            GlitchVape::Tools::capture( $perl, $prog, "$FindBin::Bin/../lib" );
        $seen{ $out // q{} }++;
    }

    is scalar keys %seen, 1,
        'four processes hashing differently draw the same sky';
}

# ---------------------------------------------------------------------------
# Stars move, which is why the loop cannot close

# Stated rather than worked around. A sky that ended a loop where it began
# would be a sky whose stars never move, and moving is what they do -- so this
# is one of the effects, with grain and static, whose seam is invisible
# because every frame is already unlike the one before it.
{
    my $start = cells( sky( step => 0,  flare => 2 ) );
    my $end   = cells( sky( step => 24, flare => 2 ) );

    my $moved = grep { !exists $end->{ $_ } } keys %$start;

    cmp_ok $moved, '>', 0, 'a loop leaves stars somewhere other than they were';
}

# ---------------------------------------------------------------------------
# Nothing to draw is not a crash

{
    is_deeply GlitchVape::Starfield::sky(
        rng     => GlitchVape::Random->new( seed => 1 )->derive( 'x' ),
        columns => 0,
        rows    => 22,
        stars   => 24,
        flare   => 1,
        step    => 3,
        ),
        [], 'a sky with no room in it is empty rather than fatal';

    my $still = sky( flare => 0, step => 5 );

    is_deeply [ sort map { $_->[ 2 ] } @$still ], [ ( 0 ) x 24 ],
        'and at a pace of nothing per step, nothing ever flares';
}

# ---------------------------------------------------------------------------
# The effect draws it

SKIP:
{
    skip 'Image::Magick is not installed', 5 unless $HAVE_MAGICK;

    require GlitchVape::Context;
    require GlitchVape::Pipeline;

    my $render = sub {
        my ( %how ) = @_;

        my $img = Image::Magick->new( size => '320x240' );
        $img->Read( 'xc:#804060' );

        my $ctx = GlitchVape::Context->new( image => $img, seed => 5 );
        $ctx->frames( $how{ _frames } || 1 );
        $ctx->frame( $how{ _frame }   || 0 );
        delete @how{ qw(_frames _frame) };

        GlitchVape::Pipeline->new( effects => { stars => \%how } )->run( $ctx );

        return $ctx->image;
    };

    my $plain = $render->();

    is join( 'x', $plain->Get( 'width' ), $plain->Get( 'height' ) ), '320x240',
        'the picture comes out the size it went in';

    isnt $plain->Get( 'signature' ),
        $render->( density => 8 )->Get( 'signature' ),
        'and a denser sky is a different picture';

    # dim 1 is the screen blanking, which is what the screensaver does before
    # it draws anything: nothing of the photograph is left behind the stars.
    my @px = $render->( dim => 1, density => 0.1 )->GetPixels(
        map    => 'RGB',
        x      => 4,
        y      => 4,
        width  => 1,
        height => 1
    );

    is_deeply [ map { int( $_ / 257 + 0.5 ) } @px ], [ 0, 0, 0 ],
        'at dim 1 the picture behind the sky is gone, even with no stars in it';

    # The frames of a loop are the same sky at different moments, so they
    # differ -- and differ from the still, which is the moment before them.
    my $first = $render->( _frames => 12, _frame => 0, flare => 3 );
    my $later = $render->( _frames => 12, _frame => 5, flare => 3 );

    isnt $first->Get( 'signature' ), $later->Get( 'signature' ),
        'and the sky has moved on by the sixth frame of a loop';

    # Which stream a star's colour comes from is its own, so that turning the
    # switch on does not shift the sky underneath it: same places, new inks.
    my $teal   = $render->( density => 6 );
    my $varied = $render->( density => 6, random => 1 );

    isnt $teal->Get( 'signature' ), $varied->Get( 'signature' ),
        'random star colours are a different picture from one colour';
}

done_testing;
