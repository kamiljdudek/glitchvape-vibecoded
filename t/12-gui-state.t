#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use GlitchVape           ();
use GlitchVape::Config   ();
use GlitchVape::Pipeline ();
use GlitchVape::Registry ();
use GlitchVape::Tools    ();
use GlitchVape::GUI::State;

local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

# The state model is the whole of the interface that can be tested without a
# display, and it is where the undo semantics live, so it is worth testing
# hard.

{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 7 );

    is $state->source, 'photo.png', 'source is held';
    is $state->seed,   7,           'seed is held';
    is_deeply [ $state->effect_names ], [], 'a new state has no effects';
}

{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'scanlines' );

    my $params = GlitchVape::Registry->get( 'scanlines' )->{ params };

    is_deeply [ sort keys %{ $state->effects->{ scanlines }{ params } } ],
        [ sort keys %$params ],
        'adding an effect fills in every declared parameter';

    ok $state->enabled( 'scanlines' ), 'a newly added effect is switched on';
}

# Effects are listed in pipeline order rather than the order they were added,
# because that is the order they will actually run in.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png' );
    $state->add_effect( $_ ) for qw(osd scanlines downsample chroma_shift);

    is_deeply [ $state->effect_names ],
        [ qw(downsample chroma_shift scanlines osd) ],
        'effects are listed in stage order';
}

# A slider hands back a float; the registry decides what the effect actually
# sees. Storing the coerced value is what keeps the cache key stable.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png' );
    $state->add_effect( 'tracking' );

    $state->param( 'tracking', 'bands', 6.4 );
    is $state->param( 'tracking', 'bands' ), 6,
        'an int parameter is rounded on the way in';

    my $err = do
    {
        local $@;
        eval { $state->param( 'scanlines', 'opacity', 99 ) };
        $@;
    };
    ok !$state->param( 'scanlines', 'opacity' ),
        'setting a parameter on an absent effect is a no-op';
}

{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png' );
    $state->load_preset( 'vhs-decay' );

    is $state->preset, 'vhs-decay', 'the preset name is recorded';
    ok $state->enabled( 'tracking' ), 'preset effects arrive enabled';
    is $state->param( 'tracking', 'bands' ), 6,
        'preset values are loaded, not defaults';
    ok $state->param( 'softness', 'radius' ),
        'effects inherited through extends are present too';
}

# An effect a preset switched off stays visible in the interface so it can be
# switched back on, which means it must survive loading as a disabled entry
# rather than being dropped.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png' );
    $state->load_preset( 'gameboy' );

    my $config = GlitchVape::Config::load( preset => 'gameboy' );
    my @off    = grep {
               ref $config->{ effects }{ $_ } eq 'HASH'
            && exists $config->{ effects }{ $_ }{ enabled }
            && !$config->{ effects }{ $_ }{ enabled }
    } keys %{ $config->{ effects } };

SKIP:
    {
        skip 'this preset disables nothing', 2 unless @off;

        ok exists $state->effects->{ $off[ 0 ] },
            'an effect the preset disabled is still in the state';
        ok !$state->enabled( $off[ 0 ] ), '...but switched off';
    }
}

# ---------------------------------------------------------------------------
# History

{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );

    ok !$state->can_undo, 'nothing to undo before the first commit';

    $state->add_effect( 'scanlines' );
    $state->commit;
    ok !$state->can_undo, 'the first commit is the baseline, not a step back';

    $state->param( 'scanlines', 'opacity', 0.8 );
    $state->commit;
    ok $state->can_undo, 'a second commit gives something to undo';

    ok $state->undo, 'undo moves';
    is $state->param( 'scanlines', 'opacity' ), 0.35,
        'undo restores the previous parameter value';

    ok $state->can_redo, 'redo is available after an undo';
    ok $state->redo,     'redo moves';
    is $state->param( 'scanlines', 'opacity' ), 0.8,
        'redo restores the newer value';
}

{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'scanlines' );
    $state->commit;

    is $state->commit, 0, 'committing an unchanged state records nothing';
    ok !$state->can_undo, 'so it does not add an empty history step';
}

# A new edit after an undo abandons the redo branch: there is no coherent
# "forward" from there any more.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'scanlines' );
    $state->commit;
    $state->param( 'scanlines', 'opacity', 0.8 );
    $state->commit;
    $state->undo;

    ok $state->can_redo, 'redo is pending';

    $state->param( 'scanlines', 'spacing', 9 );
    $state->commit;

    ok !$state->can_redo, 'a fresh commit discards the redo branch';
}

# The snapshot has to be a copy. Sharing the parameter hash would make undo
# restore a state that had been mutated underneath it.
{
    my $default =
        GlitchVape::Registry->get( 'grain' )->{ params }{ amount }{ default };

    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'grain' );
    $state->commit;

    $state->param( 'grain', 'amount', 0.5 );
    $state->commit;
    $state->param( 'grain', 'amount', 0.9 );

    $state->undo;
    is $state->param( 'grain', 'amount' ), $default,
        'history entries are independent copies';
}

{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'grain' );
    $state->commit;
    $state->param( 'grain', 'amount', 0.5 );
    $state->commit;

    my ( $back, $forward ) = $state->depth;
    is $back,    1, 'one step back available';
    is $forward, 0, 'none forward';
}

# ---------------------------------------------------------------------------
# Cache keys

{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'scanlines' );

    my $before = $state->cache_key( size => 720 );
    is $state->cache_key( size => 720 ), $before,
        'the same settings give the same key';

    isnt $state->cache_key( size => 512 ), $before,
        'render size is part of the key';

    $state->param( 'scanlines', 'opacity', 0.9 );
    isnt $state->cache_key( size => 720 ), $before,
        'a changed parameter changes the key';

    $state->param( 'scanlines', 'opacity', 0.35 );
    is $state->cache_key( size => 720 ), $before,
        'and changing it back returns the original key';
}

{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'scanlines' );

    my $still = $state->cache_key( size => 720 );
    my $loop  = $state->cache_key(
        size    => 720,
        animate => { frames => 24, fps => 12 }
    );

    isnt $loop, $still, 'a loop and a still do not share a key';

    isnt $state->cache_key(
        size    => 720,
        animate => { frames => 8, fps => 12 }
        ),
        $loop, 'frame count is part of the key';
}

# An added track changes the encoded preview without changing a single frame,
# so it has to be in the key as well -- otherwise cropping the music
# differently and pressing Apply serves back the loop with the old music on
# it, which looks exactly like the crop having been ignored.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'scanlines' );

    my %loop = ( size => 720, animate => { frames => 24, fps => 12 } );

    my $silent = $state->cache_key( %loop );

    my $with = $state->cache_key(
        size    => 720,
        animate => {
            frames => 24,
            fps    => 12,
            audio  => {
                path    => 'track.mp3',
                start   => 0,
                end     => 10,
                filters => {},
            },
        },
    );

    isnt $with, $silent, 'adding a track changes the key';

    my $moved = $state->cache_key(
        size    => 720,
        animate => {
            frames => 24,
            fps    => 12,
            audio  => {
                path    => 'track.mp3',
                start   => 4,
                end     => 14,
                filters => {},
            },
        },
    );

    isnt $moved, $with, 'moving the crop changes the key';

    my $filtered = $state->cache_key(
        size    => 720,
        animate => {
            frames => 24,
            fps    => 12,
            audio  => {
                path    => 'track.mp3',
                start   => 0,
                end     => 10,
                filters => { slowed => 0.8 },
            },
        },
    );

    isnt $filtered, $with, 'switching a filter on changes the key';
}

# A disabled effect must not contribute to the key, or switching one off and
# on again would miss the cache it just populated.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'scanlines' );
    my $alone = $state->cache_key( size => 720 );

    $state->add_effect( 'grain' );
    $state->enabled( 'grain', 0 );

    is $state->cache_key( size => 720 ), $alone,
        'a disabled effect does not affect the key';

    $state->enabled( 'grain', 1 );
    isnt $state->cache_key( size => 720 ), $alone, 'enabling it does';
}

{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'scanlines' );
    my $one = $state->cache_key( size => 720 );

    $state->seed( 2 );
    isnt $state->cache_key( size => 720 ), $one, 'the seed is part of the key';
}

# ---------------------------------------------------------------------------
# Handing settings back to the library

{
    my $state =
        GlitchVape::GUI::State->new( source => 'photo.png', seed => 42 );
    $state->load_preset( 'vhs-decay' );
    $state->enabled( 'vignette', 0 );

    my %args = $state->render_args( output => 'out.png' );

    is $args{ input },  'photo.png', 'render_args carries the input';
    is $args{ output }, 'out.png',   'and the output';
    is $args{ seed },   42,          'and the seed';

    ok scalar( grep { $_ eq 'vignette' } @{ $args{ disable } } ),
        'a switched-off effect is passed as a disable';
    ok !scalar( grep { $_ eq 'vignette' } @{ $args{ enable } } ),
        'and not as an enable';
    ok scalar( grep { /^tracking\.bands=6$/ } @{ $args{ set } } ),
        'parameters are passed as dotted overrides';
}

# The pipeline built from the state must be the one the CLI would build from
# the same settings: this is the check that the interface has not quietly
# grown a second interpretation of a preset.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->load_preset( 'vhs-decay' );

    my $from_state = GlitchVape::Pipeline->new( %{ $state->pipeline_config } );

    my $config   = GlitchVape::Config::load( preset => 'vhs-decay' );
    my $from_cli = GlitchVape::Pipeline->new(
        effects => $config->{ effects },
        order   => $config->{ order },
        disable => $config->{ disable },
    );

    is_deeply [ map { $_->{ name } } $from_state->steps ],
        [ map { $_->{ name } } $from_cli->steps ],
        'the state builds the same pipeline the CLI does';

    is_deeply [ map { $_->{ params } } $from_state->steps ],
        [ map { $_->{ params } } $from_cli->steps ],
        'with the same resolved parameters';
}

# ---------------------------------------------------------------------------
# Saving a preset

{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 3 );
    $state->load_preset( 'hotline' );
    $state->param( 'grain', 'amount', 0.25 ) if $state->effects->{ grain };

    my $yaml = $state->to_preset_yaml( name => 'saved', title => 'A test' );

    like $yaml, qr/^name: saved$/m,     'the preset carries its name';
    like $yaml, qr/^title: 'A test'$/m, 'and its title';
    like $yaml, qr/^effects:$/m,        'and an effects block';

    require File::Temp;
    my $dir  = File::Temp->newdir;
    my $path = "$dir/saved.yml";

    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    require Encode;
    print { $fh } Encode::encode( 'UTF-8', $yaml );
    close $fh;

    local $ENV{ GLITCHVAPE_PRESETS } = "$dir";

    my $reloaded = eval { GlitchVape::Config::load( preset => 'saved' ) };
    ok $reloaded, 'a saved preset loads back' or diag $@;

    my $pipeline = eval {
        GlitchVape::Pipeline->new(
            effects => $reloaded->{ effects },
            order   => $reloaded->{ order },
        );
    };
    ok $pipeline, 'and builds a pipeline' or diag $@;
}

# Text effects carry Japanese by default, and a preset written with the wrong
# quoting or the wrong encoding would fail to load rather than fail visibly.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( 'watermark' );
    $state->add_effect( 'grid' );

    my $yaml = $state->to_preset_yaml( name => 'unicode' );

    require File::Temp;
    my $dir  = File::Temp->newdir;
    my $path = "$dir/unicode.yml";

    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    require Encode;
    print { $fh } Encode::encode( 'UTF-8', $yaml );
    close $fh;

    local $ENV{ GLITCHVAPE_PRESETS } = "$dir";

    my $reloaded = eval { GlitchVape::Config::load( preset => 'unicode' ) };
    ok $reloaded, 'a preset containing non-ASCII text loads back' or diag $@;

    is $reloaded->{ effects }{ watermark }{ string },
        $state->param( 'watermark', 'string' ),
        'the non-ASCII value survives the round trip';

    # '#FF00AA' at the start of a YAML scalar is a comment unless it is
    # quoted, which would silently turn a colour into an empty value.
    is $reloaded->{ effects }{ grid }{ color },
        $state->param( 'grid', 'color' ),
        'a hex colour is quoted rather than read as a comment';
}

# ---------------------------------------------------------------------------
# End to end: the interface must not be able to produce a render the command
# line cannot reproduce. The state builds the same pipeline (checked above),
# so this confirms the whole path -- state, overrides, seed, encoder -- lands
# on the same bytes.

SKIP:
{
    skip 'ImageMagick is not installed', 2
        unless GlitchVape::Tools::have( 'magick' );
    skip 'Image::Magick is not installed', 2
        unless eval { require Image::Magick; 1 };

    require File::Temp;
    my $dir = File::Temp->newdir( 'gv_gui_XXXXXX', TMPDIR => 1 );

    my $src = "$dir/src.png";
    {
        my $img = Image::Magick->new( size => '160x120' );
        $img->Read( 'gradient:#101040-#FFE0A0' );
        $img->Draw(
            primitive => 'rectangle',
            points    => '30,25 110,80',
            fill      => '#FF2090',
        );
        my $err = $img->Write( $src );
        skip 'could not build a source image', 2
            if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;
    }

    my $state = GlitchVape::GUI::State->new( source => $src, seed => 4242 );
    $state->load_preset( 'vhs-decay' );
    $state->param( 'scanlines', 'opacity', 0.9 );
    $state->enabled( 'vignette', 0 );
    $state->add_effect( 'bloom' );

    # What Export does.
    my %args = $state->render_args( output => "$dir/gui.png", max_dim => 160 );
    my $exported = eval { GlitchVape::render( %args ); 1 };

    skip 'the render could not be run here', 2 unless $exported;

    # What the command line does, given the overrides the state hands out.
    my $cli = eval {
        GlitchVape::render(
            input   => $src,
            output  => "$dir/cli.png",
            preset  => 'vhs-decay',
            seed    => 4242,
            max_dim => 160,
            set     => $args{ set },
            enable  => $args{ enable },
            disable => $args{ disable },
        );
        1;
    };

    ok $cli, 'the same settings render from the command-line entry point'
        or diag $@;

    my $a = _slurp( "$dir/gui.png" );
    my $b = _slurp( "$dir/cli.png" );

    ok length $a && $a eq $b,
        'an export is byte-identical to the command-line render';
}

sub _slurp
{
    my ( $path ) = @_;
    open my $fh, '<:raw', $path or return q{};
    my $bytes = do { local $/ = undef; <$fh> };
    close $fh;
    return $bytes;
}

# An effect removed from the state is gone from the preview, because
# pipeline_config is built from what the state holds. It has to be gone from
# the export too, and that takes saying so: render_args names a preset, and a
# preset that mentions the effect would otherwise put it straight back.
#
# This is the preview and the export disagreeing about a preset, which is the
# exact thing this file exists to catch.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->load_preset( 'hotline' );

    ok $state->effects->{ grille }, 'hotline has a grille to remove';

    $state->remove_effect( 'grille' );

    my %args = $state->render_args;

    ok !( grep { $_ eq 'grille' } @{ $args{ enable } } ),
        'a removed effect is not enabled';
    ok scalar( grep { $_ eq 'grille' } @{ $args{ disable } } ),
        'and is explicitly disabled, so the preset cannot reinstate it';

    my $config = $state->pipeline_config;
    ok !$config->{ effects }{ grille }, 'which is what the preview already did';
}

# Switching one off and removing it outright reach the same conclusion by
# different routes, and both have to.
{
    my $off = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $off->load_preset( 'hotline' );
    $off->enabled( 'grille', 0 );

    my $gone = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $gone->load_preset( 'hotline' );
    $gone->remove_effect( 'grille' );

    my %a = $off->render_args;
    my %b = $gone->render_args;

    is_deeply [ sort @{ $a{ disable } } ], [ sort @{ $b{ disable } } ],
        'disabling and removing switch off the same things';
}

# An effect the preset never mentioned is not worth a -d: there is nothing to
# switch off, and the flag would only make the command longer.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->load_preset( 'hotline' );
    $state->add_effect( 'vgatext' );
    $state->remove_effect( 'vgatext' );

    my %args = $state->render_args;

    ok !( grep { $_ eq 'vgatext' } @{ $args{ disable } } ),
        'removing something the preset never had says nothing about it';
}

# ---------------------------------------------------------------------------
# An effect held still is still in the pipeline

# The camera on the row, from underneath. The point of it is that it is not
# the tick: the effect runs, looks as it is set, and does not move -- and the
# values it was given are still there when it is let go again.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );

    $state->add_effect( 'static' );
    $state->param( 'static', 'surge',   0.8 );
    $state->param( 'static', 'density', 0.09 );

    ok $state->animated( 'static' ), 'an effect arrives with its motion on';

    $state->animated( 'static', 0 );

    ok !$state->animated( 'static' ), 'and can be held still';
    ok $state->enabled( 'static' ),   'without leaving the pipeline';

    my $held = $state->effect_params( 'static' );

    is $held->{ surge }, 0, 'what renders is the declared value for the motion';
    is $held->{ density }, 0.09, 'and the settings it was given for the rest';

    is $state->param( 'static', 'surge' ), 0.8,
        'while the value itself is still held, not zeroed';

    $state->animated( 'static', 1 );

    is $state->effect_params( 'static' )->{ surge }, 0.8,
        'so letting it go again gives back exactly the motion it had';

    # The picture, the cache key, an exported file, a saved preset and the
    # copied command line all read the same accessor, which is what stops the
    # window showing one thing and printing another.
    $state->animated( 'static', 0 );

    my $config = $state->pipeline_config;

    is $config->{ effects }{ static }{ surge }, 0,
        'the preview is built from the held-still values';

    my %args = $state->render_args;

    ok scalar( grep { $_ eq 'static.surge=0' } @{ $args{ set } } ),
        'and so is an export';

    like $state->to_preset_yaml( name => 'held' ), qr/surge:\s*0/,
        'a preset saves the look as it renders rather than as it is held';
}

# Holding an effect still is a change to the configuration, so it steps.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );

    $state->add_effect( 'static' );
    $state->param( 'static', 'surge', 0.8 );
    $state->commit;

    my $before = $state->cache_key( size => 320 );

    $state->animated( 'static', 0 );

    isnt $state->cache_key( size => 320 ), $before,
        'the preview cache can tell a held effect from a moving one';

    ok $state->commit, 'and the history takes it as a step';

    $state->undo;

    ok $state->animated( 'static' ),
        'which undo puts back, because a snapshot carries the camera too';
}

done_testing;
