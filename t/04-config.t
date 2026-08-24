#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use GlitchVape ();
use GlitchVape::Config;
use GlitchVape::Pipeline;

# Run against the shipped presets rather than fixtures: a preset that stops
# loading is a real breakage, and this is the only place it would surface.
local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

{
    my $presets = GlitchVape::Config::list_presets();
    cmp_ok scalar @$presets, '>=', 8, 'the preset library is discovered';

    ok length $_->{ title }, "preset $_->{name} has a title" for @$presets;
}

# Presets carrying Japanese text once failed to load at all, because YAML::XS
# needs UTF-8 bytes and was being handed decoded characters.
{
    for my $name ( qw(sunset hotline dreamcore) )
    {
        my $config = GlitchVape::Config::load( preset => $name );
        ok $config->{ effects } && %{ $config->{ effects } },
            "preset with non-ASCII text loads ($name)";
    }

    my $sunset = GlitchVape::Config::load( preset => 'sunset' );
    is $sunset->{ effects }{ text }{ string }, '新世紀',
        'non-ASCII values survive loading as characters';
}

{
    my $config = GlitchVape::Config::load( preset => 'vhs-decay' );

    # vhs-decay extends base-vhs and does not mention softness itself.
    ok $config->{ effects }{ softness }, 'inherited effects come through';
    is $config->{ effects }{ tracking }{ bands }, 6,
        'child values override the parent';
    ok $config->{ effects }{ chroma_bleed }{ saturation },
        'parent parameters survive a partial child override';
}

{
    my $config = GlitchVape::Config::load(
        preset => 'vhs-decay',
        set    => [ 'scanlines.opacity=0.9', 'tracking.bands=1' ],
    );
    is $config->{ effects }{ scanlines }{ opacity }, '0.9',
        'overrides are applied';
    is $config->{ effects }{ tracking }{ bands }, '1',
        'multiple overrides apply';
}

{
    my $config = GlitchVape::Config::load(
        preset => 'vhs-decay',
        enable => [ 'bloom' ],
    );
    ok exists $config->{ effects }{ bloom }, 'enable adds an effect';

    my $pipeline = GlitchVape::Pipeline->new( effects => $config->{ effects } );
    ok scalar( grep { $_->{ name } eq 'bloom' } $pipeline->steps ),
        'the enabled effect reaches the pipeline';
}

{
    my $config = GlitchVape::Config::load(
        preset  => 'vhs-decay',
        disable => [ 'scanlines' ],
    );
    my $pipeline = GlitchVape::Pipeline->new(
        effects => $config->{ effects },
        disable => $config->{ disable },
    );
    ok !scalar( grep { $_->{ name } eq 'scanlines' } $pipeline->steps ),
        'disable removes an effect from the pipeline';
}

{
    my $err = do
    {
        local $@;
        eval { GlitchVape::Config::load( preset => 'nope' ) };
        $@;
    };
    like $err, qr/no preset named 'nope'/, 'unknown preset is reported';
    like $err, qr/Available:/,             'the error lists what does exist';
}

{
    my $err = do
    {
        local $@;
        eval {
            GlitchVape::Config::load(
                preset => 'vhs-decay',
                set    => [ 'bogus' ]
            );
        };
        $@;
    };
    like $err, qr/effect\.param=value/, 'malformed override is reported';
}

# Stage order is what keeps a preset coherent regardless of the order its
# effects happen to be written in.
{
    my $pipeline = GlitchVape::Pipeline->new(
        effects => {
            scanlines    => {},
            downsample   => {},
            chroma_shift => {},
            osd          => {},
        }
    );

    my @order = map { $_->{ name } } $pipeline->steps;
    is_deeply \@order, [ qw(downsample chroma_shift scanlines osd) ],
        'effects sort into stage order, not declaration order';
}

{
    my $pipeline = GlitchVape::Pipeline->new(
        effects => { scanlines => {}, downsample => {} },
        order   => [ qw(scanlines downsample) ],
    );
    my @order = map { $_->{ name } } $pipeline->steps;
    is_deeply \@order, [ qw(scanlines downsample) ],
        'an explicit order overrides stage order';
}

{
    my $pipeline = GlitchVape::Pipeline->new(
        effects => { scanlines => { enabled => 0 }, downsample => {} }, );
    my @order = map { $_->{ name } } $pipeline->steps;
    is_deeply \@order, [ 'downsample' ], 'enabled:0 drops an inherited effect';
}

{
    my $err = do
    {
        local $@;
        eval { GlitchVape::Pipeline->new( effects => { nonesuch => {} } ) };
        $@;
    };
    like $err, qr/unknown effect 'nonesuch'/,
        'unknown effect fails at build time';
}

# Every shipped preset must resolve completely. This catches a parameter
# renamed in code but not in the YAML, which would otherwise only appear when
# someone happened to run that preset.
{
    for my $entry ( @{ GlitchVape::Config::list_presets() } )
    {
        my $name = $entry->{ name };
        my $ok   = eval {
            my $config = GlitchVape::Config::load( preset => $name );
            GlitchVape::Pipeline->new(
                effects => $config->{ effects },
                order   => $config->{ order },
            );
            1;
        };
        ok $ok, "preset '$name' builds a valid pipeline"
            or diag $@;
    }
}

done_testing;
