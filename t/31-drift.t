#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape           ();
use GlitchVape::Context  ();
use GlitchVape::Pipeline ();
use GlitchVape::Tools    ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# Every drift closes its loop.
#
# The property is that the frame after the last one is the first one again. A
# video plays a loop end to end and then starts it over, so a drift that does
# not come back to where it began puts a jolt in at that join -- once per
# repeat, for as long as the file plays. It is the one defect in an animation
# that gets worse the longer somebody watches, and it is invisible in any
# single frame, which is why nothing else in the suite would catch it.
#
# GlitchVape::Context::travel snaps a periodic pattern's distance to whole
# repeats and ::excursion rocks a one-off feature out and back, so both close
# by construction. This checks the construction actually holds, at values
# chosen to be awkward: primes, non-multiples of every plausible period, and
# fractions.
#
# Driven off the registry rather than a list, so an effect that grows a drift
# parameter is covered the day it is declared and not the day somebody
# remembers this file.

my $dir = File::Temp->newdir( 'gv_drift_XXXXXX', TMPDIR => 1 );

# Structure rather than a flat wash: several of these move edges around, and
# an edge is the only thing that shows it.
my $src = "$dir/src.png";
{
    my $img = Image::Magick->new( size => '240x180' );
    $img->Read( 'gradient:#101040-#FFE0A0' );
    $img->Draw(
        primitive => 'rectangle',
        points    => '45,38 165,120',
        fill      => '#FF2090',
    );
    my $err = $img->Write( $src );
    BAIL_OUT( "could not build the test source image: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;
}

my $registry = 'GlitchVape::Registry';

my @drifters =
    sort grep { $registry->get( $_ )->{ params }{ drift } } $registry->names;

ok scalar @drifters, 'some effects declare a drift' or BAIL_OUT( 'none found' );
diag "drift is declared by: @drifters";

# One frame of one effect, as ImageMagick's signature of its pixels.
#
# The signature and not the written file: a PNG carries a creation time, so two
# encodings of one identical picture differ as bytes while being the same
# image. Comparing files here reported a jolt in effects that did not have one.
sub render_frame
{
    my ( $effect, $drift, $frame, $frames ) = @_;

    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new(
        image  => $img,
        source => $src,
        seed   => 99,
    );
    $ctx->frames( $frames );
    $ctx->frame( $frame );

    GlitchVape::Pipeline->new( effects => { $effect => { drift => $drift } } )
        ->run( $ctx );

    return $ctx->image->Get( 'signature' );
}

my $frames = 12;

# Deliberately unhelpful: none of these is a whole number of any period the
# effects use, which is the case that used to jolt.
my @awkward = ( 1, 3, 7, 10, 0.5 );

for my $effect ( @drifters )
{
    my $spec = $registry->get( $effect )->{ params }{ drift };

    for my $drift ( @awkward )
    {
        next if defined $spec->{ max } && $drift > $spec->{ max };

        my $first = render_frame( $effect, $drift, 0,       $frames );
        my $wrap  = render_frame( $effect, $drift, $frames, $frames );

        ok $first eq $wrap,
            "$effect at drift $drift comes back to the first frame";
    }
}

# A drift is an animation parameter and must leave a still alone, whatever it
# is set to: presets carry it, and rendering one as a still should give the
# same picture it gave before the parameter existed.
for my $effect ( @drifters )
{
    my $spec = $registry->get( $effect )->{ params }{ drift };

    # The largest this effect will take, so the test is asking the parameter
    # for everything it has rather than for a number that happens to be small.
    my $most = $spec->{ max };
    $most = 10 if !defined $most || $most > 10;

    my $off = render_frame( $effect, 0,     0, 1 );
    my $on  = render_frame( $effect, $most, 0, 1 );

    ok $off eq $on, "$effect ignores drift when there is only one frame";
}

done_testing;
