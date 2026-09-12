#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Digest::SHA ();
use File::Temp  ();
use Test::More;

use GlitchVape                 ();
use GlitchVape::Context        ();
use GlitchVape::Effect::Glitch ();
use GlitchVape::Pipeline       ();
use GlitchVape::Registry       ();
use GlitchVape::Tools          ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

# How long a smear may be is a share of the line it is drawn along, and it has
# to be, because it used to be a count of pixels and that meant a different
# thing at every output size.
#
# min_run defaulted to 12 and ran to 4000; max_run defaulted to 0, meaning no
# limit, and ran to 8000. On a 720-pixel preview that left most of both
# sliders inert -- every max_run above 720 did nothing at all, and so did
# every one below min_run, which is eleven values at the bottom and seven
# thousand at the top. The values in between did something, but not the same
# something as on the export: the preview and the file disagreed about a
# setting neither of them named.
#
# So the questions here are the two halves of that. Does the same setting give
# the same picture at two sizes, and does every position on the slider do
# something.

my $dir = File::Temp->newdir( 'gv_psort_XXXXXX', TMPDIR => 1 );

# Nothing but noise, and sorted with the band wide open, so that every row is
# one eligible run from edge to edge and what comes back is decided entirely
# by where the run was broken. Noise also has no ascending stretch longer than
# a pixel or two of its own, which is what makes a long one afterwards
# unambiguously the sort's doing.
sub source
{
    my ( $w, $h ) = @_;

    my $path = "$dir/noise-${w}x$h.png";
    return $path if -e $path;

    # 'Random', not 'Uniform'. Uniform noise is a small perturbation of
    # whatever was there, so a grey canvas comes back as grey with a wobble
    # on it -- and a band from 0.45 to 0.55 then catches nearly every pixel
    # instead of the scattered few this needs.
    #
    # And grey afterwards, because Random draws each channel separately. The
    # sort compares luma and everything below reads intensity back, and on a
    # picture whose three channels disagree those are two different numbers --
    # so a perfectly sorted row would come back looking unsorted.
    my $img = Image::Magick->new( size => "${w}x$h" );
    $img->Read( 'xc:black' );
    $img->AddNoise( noise => 'Random' );
    $img->Separate( channel => 'Red' );

    my $err = $img->Write( $path );
    BAIL_OUT( "could not build the test source image: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;

    return $path;
}

sub sorted
{
    my ( $w, $h, %given ) = @_;

    my $src = source( $w, $h );

    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new(
        image  => $img,
        source => $src,
        seed   => 5,
    );

    GlitchVape::Pipeline->new(
        effects => {
            pixelsort => { lower => 0, upper => 1, coverage => 1, %given }
        }
    )->run( $ctx );

    return $ctx->image;
}

# How many times brightness falls from one pixel to the next along one row.
# Inside a sorted chunk it never does, so this counts the breaks between
# chunks -- one fewer than the number of chunks the row was cut into.
sub breaks
{
    my ( $img, $row ) = @_;

    my ( $w, $h ) = $img->Get( 'width', 'height' );

    my @px = $img->GetPixels(
        map       => 'I',
        normalize => 1,
        x         => 0,
        y         => $row // int( $h / 2 ),
        width     => $w,
        height    => 1
    );

    my $falls = 0;
    for my $n ( 1 .. $#px )
    {
        $falls++ if $px[ $n ] < $px[ $n - 1 ];
    }

    return $falls;
}

# ---------------------------------------------------------------------------
# The old pixel counts are gone rather than renamed in place

# Renamed rather than reinterpreted, so that a preset carrying the old keys
# stops with the list of the new ones instead of silently clamping 260 to 1
# and rendering something nobody asked for.
{
    my $params = GlitchVape::Registry->get( 'pixelsort' )->{ params };

    ok !$params->{ min_run }, 'min_run is gone';
    ok !$params->{ max_run }, 'and so is max_run';

    for my $name ( qw(min_smear max_smear) )
    {
        my $p = $params->{ $name };

        ok $p, "$name is declared";
        is $p->{ type }, 'num', "and $name is a fraction rather than a count";
        cmp_ok $p->{ max }, '<=', 1, "and no more than the whole line";
    }

    is $params->{ max_smear }{ default }, 1,
          'the longest smear defaults to the whole line, which is no limit at '
        . 'all -- and it says so at the top of its own range rather than at a '
        . 'magic zero below the bottom of it';
}

# ---------------------------------------------------------------------------
# The same setting gives the same picture at two sizes

# The half that was actually broken. Chosen so the arithmetic is exact: a
# quarter of 800 is 200 and a quarter of 400 is 100, so both come back cut
# into four.
{
    for my $share ( 0.25, 0.5 )
    {
        my $wide   = breaks( sorted( 800, 40, max_smear => $share ) );
        my $narrow = breaks( sorted( 400, 40, max_smear => $share ) );

        is $narrow, $wide,
            "a longest smear of $share cuts a line into the same number of "
            . 'pieces whatever the line is'
            or diag "800 wide gave $wide, 400 gave $narrow";

        is $wide, 1 / $share - 1, "and into the number the fraction asks for";
    }
}

# ---------------------------------------------------------------------------
# Every position on the slider does something

# The other half. Turning the longest smear down has to give more pieces,
# every time, all the way -- a slider with a plateau on it looks exactly like
# a slider set to a value that does nothing.
{
    my @share = ( 0.05, 0.1, 0.2, 0.4, 0.8, 1 );
    my @cut   = map { breaks( sorted( 800, 40, max_smear => $_ ) ) } @share;

    for my $n ( 1 .. $#share )
    {
        cmp_ok $cut[ $n ], '<', $cut[ $n - 1 ],
            "a longest smear of $share[$n] gives fewer pieces than "
            . $share[ $n - 1 ]
            or diag "@cut for @share";
    }

    is $cut[ -1 ], 0, 'and at 1 the line is not cut at all';
}

# ---------------------------------------------------------------------------
# Asking for a smear shorter than the shortest gives the shortest

# The dead zone the old pair had at the bottom of one slider: a max_run under
# min_run meant every chunk was thrown away for being too short, so the whole
# effect vanished. It is clamped now, which is the only reading of "longest"
# that is not a contradiction.
{
    my $under =
        breaks( sorted( 800, 40, min_smear => 0.05, max_smear => 0.005 ) );
    my $at = breaks( sorted( 800, 40, min_smear => 0.05, max_smear => 0.05 ) );

    cmp_ok $under, '>', 0,
        'a longest smear below the shortest one still sorts something';

    is $under, $at, 'namely exactly what the shortest one would have given';
}

# ---------------------------------------------------------------------------
# And the shortest smear is what keeps the grit out

# The other end of the same measurement, and it takes a different picture to
# ask about: with the band wide open every row is one run from edge to edge,
# and a floor has nothing short to be a floor over. A narrow band across noise
# is the opposite -- every eligible run is a pixel or two -- so what the floor
# does there is the whole of what it does.
{
    my %narrow = ( lower => 0.45, upper => 0.55 );

    # A band with nothing in it -- no pixel is both at least white and at
    # most black -- which is a no-op that has still been through every step
    # the other two have. Compared against that rather than against the file
    # on disk, so what is being asked about is the floor and not whatever
    # reading and writing a PNG does on the way past.
    my $nothing = _pixels( sorted( 800, 40, lower => 1, upper => 0 ) );

    my $grit  = _pixels( sorted( 800, 40, %narrow, min_smear => 0 ) );
    my $clean = _pixels( sorted( 800, 40, %narrow, min_smear => 0.25 ) );

    isnt $grit, $nothing, 'with no floor, even a two-pixel run is sorted';
    is $clean, $nothing,
        'and with the floor up, a line of short runs comes back as it went in';
}

# A digest of the pixels rather than the pixels themselves: two pictures that
# differ are not worth printing at thirty-two thousand numbers each. A written
# file would not do either -- a PNG carries the time it was made, so two
# identical pictures encoded a second apart are different files.
sub _pixels
{
    my ( $img ) = @_;

    my ( $w, $h ) = $img->Get( 'width', 'height' );

    return Digest::SHA::sha256_hex(
        join q{,},
        $img->GetPixels(
            map    => 'RGB',
            x      => 0,
            y      => 0,
            width  => $w,
            height => $h
        )
    );
}

done_testing;
