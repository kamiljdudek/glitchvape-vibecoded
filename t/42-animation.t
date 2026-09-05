#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape           ();
use GlitchVape::Context  ();
use GlitchVape::Pipeline ();
use GlitchVape::Registry ();
use GlitchVape::Tools    ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# Every animation parameter, asked whether it does anything at all.
#
# This is the sweep that would have caught four separate settings that had
# quietly stopped working, and it is driven off the registry so that the next
# one is covered the day it is declared. The failures were all of one kind: a
# control whose whole range is live in the code and dead on the screen, which
# no still and no single frame can show and which nobody notices because a
# slider that does nothing looks exactly like a slider set to a value that
# does nothing.
#
# The claim is deliberately weak -- that some frame of a loop differs from
# frame nought -- because what each setting does is its own business and is
# pinned in its own file. What is being caught here is nothing at all.

my $FRAMES = 12;

my $dir = File::Temp->newdir( 'gv_anim_XXXXXX' );
my $src = "$dir/src.png";

# Small and busy. Busy because a smooth ramp hides damage a detailed picture
# shows: databend on a gradient decodes back to something indistinguishable
# from what went in, and the sweep would read that as a broken setting. Small
# because this renders a few hundred frames -- but not so small that a JPEG of
# it has too few blocks for a corrupted byte to reach.
{
    my $img = Image::Magick->new( size => '192x144' );
    $img->Read( 'plasma:fractal' );
    $img->Write( $src );
}

my $cache = File::Temp->newdir( 'gv_anim_cache_XXXXXX' );

# One frame of a loop, as a signature.
sub frame_of
{
    my ( $effect, $params, $frame ) = @_;

    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new(
        image    => $img,
        seed     => 3,
        cachedir => "$cache",
    );
    $ctx->frames( $FRAMES );
    $ctx->frame( $frame );

    GlitchVape::Pipeline->new( effects => { $effect => $params } )->run( $ctx );

    return $ctx->image->Get( 'signature' );
}

# A setting turned up as far as it goes, with everything it says it depends on
# turned on beside it -- otherwise the sweep proves that a greyed control is
# greyed, which is not the question.
sub wound_up
{
    my ( $effect, $key ) = @_;

    my $params = GlitchVape::Registry->get( $effect )->{ params };
    my $spec   = $params->{ $key };

    my $most =
          defined $spec->{ max }    ? $spec->{ max }
        : $spec->{ type } eq 'bool' ? 1
        : $spec->{ values }         ? $spec->{ values }[ -1 ]
        :                             1;

    my %wound = ( $key => $most );

    for my $need ( sort keys %{ $spec->{ needs } || {} } )
    {
        my $want = $spec->{ needs }{ $need };
        $want = $want->[ 0 ] if ref $want eq 'ARRAY';

        $wound{ $need } =
            $want eq '1' ? ( $params->{ $need }{ max } // 1 ) : $want;
    }

    return \%wound;
}

# Which of a loop's frames differ from the one it opens on.
sub moves
{
    my ( $effect, $key ) = @_;

    my $wound = wound_up( $effect, $key );
    my $first = frame_of( $effect, $wound, 0 );

    for my $frame ( 1 .. $FRAMES - 1 )
    {
        return 1 if frame_of( $effect, $wound, $frame ) ne $first;
    }

    return 0;
}

# The four that cannot answer, and why. Each is a fact about the effect rather
# than a gap in the sweep, so each is named here instead of being left to fail.
my %EXCUSED = (

    # Sorting every line leaves nothing to choose between frames, and full
    # coverage is what it arrives at. Below one it re-rolls; the parameter's
    # own doc says so, and needs cannot express 'less than'.
    'pixelsort.reroll' => 'consults no randomness at full coverage',
);

my @asked;
my @dead;

for my $effect ( GlitchVape::Registry->names )
{
    my $params = GlitchVape::Registry->get( $effect )->{ params };

    for my $key ( sort keys %$params )
    {
        next unless $params->{ $key }{ animation };
        next if $EXCUSED{ "$effect.$key" };

        push @asked, "$effect.$key";
        push @dead,  "$effect.$key" unless moves( $effect, $key );
    }
}

diag "swept: " . scalar( @asked ) . ' animation settings';

cmp_ok scalar @asked, '>', 30, 'the sweep found the settings to ask about';

is_deeply \@dead, [], 'every animation setting changes some frame of a loop'
    or diag "these did nothing across a whole loop: @dead";

# The excuses are checked too, or one of them outliving its reason is a
# setting quietly exempted from the sweep for ever.
for my $named ( sort keys %EXCUSED )
{
    my ( $effect, $key ) = split /[.]/, $named;

    my $spec = GlitchVape::Registry->get( $effect );

    ok $spec, "$effect, which is excused the sweep, is still an effect";
    ok $spec->{ params }{ $key }, "and $named is still one of its parameters";
}

# ---------------------------------------------------------------------------
# A sweep that only asks "does anything move" cannot ask "does all of it"

# The weak claim above passes for a setting whose top half is dead, because
# something somewhere in the loop still moves. Glare was exactly that: the
# band was driven a whole diagonal either way, so past about a quarter of the
# slider it spent the middle of the loop off the picture and every setting
# above that looked the same. What is pinned here is that the band is still
# on the glass at the far end of its travel.
{
    my $lit = sub {
        my ( $frame, $drift ) = @_;

        return frame_of( 'glare',
            { drift => $drift, strength => 0.6, width => 0.35 }, $frame );
    };

    my $unlit = sub {
        my ( $frame ) = @_;
        return frame_of( 'glare', { strength => 0 }, $frame );
    };

    my $spec = GlitchVape::Registry->get( 'glare' )->{ params }{ drift };

    my @gone = grep { $lit->( $_, $spec->{ max } ) eq $unlit->( $_ ) }
        0 .. $FRAMES - 1;

    is_deeply \@gone, [],
        'at the far end of its travel the sheen is on the glass all the way round'
        or diag "the band had left the picture on frames: @gone";

    # And the whole range is distinguishable, which is the other half of the
    # same complaint: two settings that render alike are one setting.
    my %seen;
    $seen{ $lit->( 3, $_ ) }++ for 0.25, 0.5, 0.75, 1;

    is scalar keys %seen, 4, 'and four settings of it are four pictures';
}

# ---------------------------------------------------------------------------
# The three new motions close their loops and leave a still alone

# The two proofs CLAUDE.md asks of any moving parameter not called drift, and
# of these three because the sweep above only says they move.
#
# Tracking is asked with its noise turned off. The specks inside a band are
# drawn fresh every frame on purpose -- that is the medium, not the fault, and
# it is avowedly not periodic -- so what closes is where the bands are.
{
    my %CLOSES = (
        tracking  => { crawl => 2, bands => 4, noise => 0, brighten => 0 },
        halftone  => { drift => 2 },
        interlace => { drift => 2, offset => 6 },
    );

    for my $effect ( sort keys %CLOSES )
    {
        my $turned_up = $CLOSES{ $effect };
        my ( $key ) = grep {
            GlitchVape::Registry->get( $effect )->{ params }{ $_ }{ animation }
        } sort keys %$turned_up;

        is frame_of( $effect, $turned_up, $FRAMES ),
            frame_of( $effect, $turned_up, 0 ),
            "$effect.$key brings the frame after the last one back to the first";

        # A still has no loop to be at a point of, so the setting is not a
        # setting there: whatever it says, one frame renders as it would
        # without it.
        my $moving = Image::Magick->new;
        $moving->Read( $src );
        my $ctx = GlitchVape::Context->new(
            image    => $moving,
            seed     => 3,
            cachedir => "$cache"
        );
        GlitchVape::Pipeline->new( effects => { $effect => $turned_up } )
            ->run( $ctx );

        my $held = Image::Magick->new;
        $held->Read( $src );
        my $still = GlitchVape::Context->new(
            image    => $held,
            seed     => 3,
            cachedir => "$cache"
        );
        GlitchVape::Pipeline->new(
            effects => {
                $effect => GlitchVape::Registry->without_animation(
                    $effect, $turned_up
                )
            }
        )->run( $still );

        is $ctx->image->Get( 'signature' ), $still->image->Get( 'signature' ),
            "and leaves a still of $effect exactly as it was";
    }
}

done_testing;
