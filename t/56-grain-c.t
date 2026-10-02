#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;

use GlitchVape::Grain  ();
use GlitchVape::Pixels ();
use GlitchVape::Random ();

# This file compares the two, so the switch that rules the C out is for the
# program and not for it.
delete $ENV{ GLITCHVAPE_PURE_PERL };

plan skip_all => 'the grain is not compiled here: '
    . GlitchVape::Grain::status()
    unless GlitchVape::Grain::compiled();

# The C in xs/grain.c is a second implementation of something whose whole
# promise is repeatability: a seed grains a picture the same way every time,
# on every machine. So it is held to the Perl it replaces not approximately
# but to the bit -- every gaussian, every byte -- and to where it leaves the
# generator afterwards, since the next thing to draw from that stream would
# otherwise diverge too, however right the picture looked.
#
# The Perl is called directly, as the reference, rather than through the
# switch: what is being compared is two implementations, not two settings.
## no critic (Subroutines::ProtectPrivateSubs)

# The tables are always there to step the generator with; GFNI only where the
# CPU has it, and refusing it otherwise is the glue's job -- an illegal
# instruction would not be a test failure but the end of the test.
my @paths = ( 'table' );
push @paths, 'gfni' if eval { GlitchVape::Grain::_use_path( 'gfni' ); 1 };
note 'generator paths: ', join ' ', @paths;

# Two generators, at the same point of the same stream.
sub pair
{
    my ( $seed ) = @_;
    return map { GlitchVape::Random->new( seed => $seed ) } 1 .. 2;
}

# Where a generator is: its state, and the spare it is holding to the bit.
sub where
{
    my ( $r ) = @_;
    my $spare = '-';
    $spare = unpack 'H*', pack 'd', $r->{ _spare } if defined $r->{ _spare };
    return "$r->{state} $spare";
}

# Every byte value in every channel, rows of black and white for the clamp to
# hold at both ends, and nothing that repeats on a vector's period.
sub picture
{
    my ( $w, $h ) = @_;
    my $bytes = '';

    for my $y ( 0 .. $h - 1 )
    {
        if ( $y % 7 == 3 )
        {
            $bytes .= "\0" x ( 3 * $w );
            next;
        }
        if ( $y % 7 == 5 )
        {
            $bytes .= "\xFF" x ( 3 * $w );
            next;
        }
        for my $x ( 0 .. $w - 1 )
        {
            my $base = $x * 3 + $y * 5 + ( $x * $y ) % 31;
            $bytes .= pack 'C3', map { ( $base + $_ * 85 ) % 256 } 0 .. 2;
        }
    }

    return GlitchVape::Pixels->from_bytes( $w, $h, $bytes );
}

# The gaussians themselves, before any byte truncates them: counts that stop
# inside the first batch and run through dozens, an odd count that leaves a
# spare behind, and a spare carried in from a draw before.
sub gaussians
{
    my ( $path ) = @_;

    for my $case (
        [ 1,       1 ],
        [ 2,       20.4 ],
        [ 3,       1 ],
        [ 1601,    12.75 ],
        [ 100_003, 255 ]
        )
    {
        my ( $n, $sd ) = @$case;

        for my $carried ( 0, 1 )
        {
            my ( $c, $p ) = pair( "gauss $n" );
            $_->gauss_list( $carried, 0, 1 ) for $c, $p;

            my $got  = GlitchVape::Grain::_gauss( $c, $n, $sd );
            my $want = pack 'd*', $p->gauss_list( $n, 0, $sd );

            ok $got eq $want,
                  "$path: "
                . ( $n == 1 ? 'one gaussian' : "$n gaussians" )
                . " at sd $sd, Perl's to the bit"
                . ( $carried ? ', with a spare carried in' : '' );
            is where( $c ), where( $p ),
                "$path: ... and leave the generator where Perl does";
        }
    }

    # Handed back and forth: what the C leaves is a generator the Perl can go
    # on drawing from, and the other way round, so a run of mixed calls is one
    # stream rather than three that happen to start alike.
    {
        my ( $c, $p ) = pair( 'relay' );

        my $got = GlitchVape::Grain::_gauss( $c, 5, 1 );
        $got .= pack 'd*', $c->gauss_list( 7, 0, 1 );
        $got .= GlitchVape::Grain::_gauss( $c, 1000, 1 );

        my $want = pack 'd*', $p->gauss_list( 1012, 0, 1 );

        ok $got eq $want,
            "$path: C, then Perl, then C again draw one unbroken stream";
        is where( $c ), where( $p ), "$path: ... ending where Perl's does";
    }

    # Random never holds a state of nought -- a seed of nought is rescued when
    # it is made -- but gauss_list would draw _RESCUE first if it did, and the
    # C starts from the state before that rather than from nought.
    {
        my ( $c, $p ) = pair( 'nought' );
        $_->{ state } = 0 for $c, $p;

        ok GlitchVape::Grain::_gauss( $c, 9, 1 ) eq
            pack( 'd*', $p->gauss_list( 9, 0, 1 ) ),
            "$path: a state of nought is rescued as Perl rescues it";
    }
    return;
}

# Pictures, through every arm of the loop: one value a pixel or three, with
# the shadow bias and without -- nought skips it in Perl and must give a scale
# of exactly one in C -- at sizes the vectors do not divide, down to a single
# pixel.
sub pictures
{
    my ( $path ) = @_;

    for my $size ( [ 1, 1 ], [ 2, 1 ], [ 5, 3 ], [ 257, 129 ] )
    {
        my ( $w, $h ) = @$size;

        for my $mono ( 0, 1 )
        {
            for my $bias ( 0, 0.6 )
            {
                my ( $c, $p ) = pair( "picture $w $mono $bias" );
                my $got  = picture( $w, $h );
                my $want = picture( $w, $h );

                GlitchVape::Grain::_pixels( $c, $got->{ data },
                    $w, $h, 0.08 * 255, $bias, $mono );
                GlitchVape::Grain::_perl_pixels( $p, $want, 0.08 * 255,
                    $bias, $mono );

                my $what = sprintf '%s: %dx%d, %s, bias %s', $path, $w, $h,
                    ( $mono ? 'mono' : 'colour' ), $bias;
                ok $got->data eq $want->data, "$what: the same bytes";
                is where( $c ), where( $p ), "$what: the generator left alike";
            }
        }
    }

    # Grain heavy enough that most of what it touches clamps, and a spare
    # carried into the picture from a draw before it.
    for my $mono ( 0, 1 )
    {
        my ( $c, $p ) = pair( "clamped $mono" );
        $_->gauss( 0, 1 ) for $c, $p;

        my $got  = picture( 64, 48 );
        my $want = picture( 64, 48 );

        GlitchVape::Grain::_pixels( $c, $got->{ data },
            64, 48, 255, 0.3, $mono );
        GlitchVape::Grain::_perl_pixels( $p, $want, 255, 0.3, $mono );

        ok $got->data eq $want->data && where( $c ) eq where( $p ),
            "$path: grain that clamps, after a spare, "
            . ( $mono ? 'mono' : 'colour' );
    }
    return;
}

# The coarse grain's cells, around mid-grey.
sub cells
{
    my ( $path ) = @_;

    for my $count ( 1, 2, 3, 1000, 4321 )
    {
        for my $mono ( 0, 1 )
        {
            for my $sd ( 0.03 * 255, 255 )
            {
                my ( $c, $p ) = pair( "cells $count" );

                my $got = GlitchVape::Grain::_cells( $c, $count, $sd, $mono );
                my $want =
                    GlitchVape::Grain::_perl_cells( $p, $count, $sd, $mono );

                ok $got eq $want && where( $c ) eq where( $p ),
                    sprintf '%s: %d %s cell%s at sd %g', $path, $count,
                    ( $mono ? 'mono' : 'colour' ), ( $count == 1 ? '' : 's' ),
                    $sd;
            }
        }
    }
    return;
}

for my $path ( @paths )
{
    GlitchVape::Grain::_use_path( $path );
    gaussians( $path );
    pictures( $path );
    cells( $path );
}

GlitchVape::Grain::_use_path( 'auto' );

# The way in that the effect uses, and the switch that turns the C off: both
# land on the same bytes, and the switch is reported as the reason.
{
    my ( $c, $p ) = pair( 'switch' );
    my $got  = picture( 40, 30 );
    my $want = picture( 40, 30 );

    GlitchVape::Grain::pixels( $c, $got, 20, 0.5, 1 );
    {
        local $ENV{ GLITCHVAPE_PURE_PERL } = 1;
        ok !GlitchVape::Grain::compiled(),
            'GLITCHVAPE_PURE_PERL turns the compiled grain off';
        like GlitchVape::Grain::status(), qr/GLITCHVAPE_PURE_PERL/,
            '... and the status says that is why';
        GlitchVape::Grain::pixels( $p, $want, 20, 0.5, 1 );
    }

    ok $got->data eq $want->data && where( $c ) eq where( $p ),
        'pixels() gives the same picture with the switch on and off';
    ok GlitchVape::Grain::compiled(), '... and the switch is read each time';
}

# What the glue refuses, rather than reading past the end of a string or
# treating anything with a hash in it as a generator.
{
    my ( $c ) = pair( 'refusals' );
    my $short = "\0" x 10;

    ok !eval { GlitchVape::Grain::_pixels( $c, $short, 2, 2, 1, 0, 0 ); 1 },
        'a picture shorter than its size says is refused';
    like $@, qr/needs 12 bytes, not 10/, '... saying how short';

    ok !eval { GlitchVape::Grain::_cells( [], 3, 1, 0 ); 1 },
        'something that is not a generator is refused';
    ok !eval { GlitchVape::Grain::_use_path( 'avx512' ); 1 },
        'a generator path that does not exist is refused';
}

# And the effect itself, end to end, where there is ImageMagick to run it:
# fine grain and coarse, both ways, the same picture.
SKIP:
{
    skip 'Image::Magick is not installed', 4
        unless eval { require Image::Magick; 1 };

    require GlitchVape;
    require GlitchVape::Context;
    require GlitchVape::Registry;

    my $grain = GlitchVape::Registry->get( 'grain' );

    for my $settings (
        { amount => 0.05, shadow_bias => 0.7,  mono => 1 },
        { amount => 0.12, shadow_bias => 0.2,  mono => 0 },
        { amount => 0.03, shadow_bias => 0.25, mono => 1, size => 2 },
        { amount => 0.05, shadow_bias => 0.35, mono => 0, size => 3 }
        )
    {
        my %out;
        for my $pure ( 0, 1 )
        {
            local $ENV{ GLITCHVAPE_PURE_PERL } = $pure;

            my $img = Image::Magick->new( size => '160x120' );
            $img->Read( 'gradient:#102050-#F0C080' );
            $img->Set( depth => 8 );

            my $ctx = GlitchVape::Context->new( image => $img, seed => 99 );
            my $p = GlitchVape::Registry->resolve_params( 'grain', $settings );
            $grain->{ apply }->( $ctx, $p );

            $out{ $pure } = GlitchVape::Pixels->from_image( $ctx->image )->data;
        }

        ok $out{ 0 } eq $out{ 1 },
            'the grain effect renders alike both ways: ' . join ', ',
            map { "$_ $settings->{$_}" } sort keys %$settings;
    }
}

done_testing;
