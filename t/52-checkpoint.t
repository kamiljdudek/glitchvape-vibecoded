#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

use GlitchVape             ();
use GlitchVape::Checkpoint ();
use GlitchVape::Config     ();
use GlitchVape::Context    ();
use GlitchVape::IO         ();
use GlitchVape::Pipeline   ();
use GlitchVape::Tools      ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

# The window keeps the picture as it stood after each effect and starts the
# next preview from the last one its pipeline shares. That is only worth
# having if it is invisible: a preview reached by adjusting the ninth effect
# has to be, to the bit, the preview a render from the start would give, or
# what a setting looks like would depend on what was adjusted before it.
#
# Between effects the picture can hold sixteen-bit values under an eight-bit
# label, which is exactly what an ordinary file cannot keep -- so the question
# is asked from every step of presets chosen to pass through that state and
# every other one: grain leaves it, cmyk caches screens, letterbox changes the
# size, osd adds an alpha channel, palette makes few colours.

my $dir = File::Temp->newdir( 'gv_steps_XXXXXX', TMPDIR => 1 );

my $picture = "$dir/source.png";
{
    my $img = Image::Magick->new( size => '160x120' );
    $img->Read( 'gradient:#102050-#F0C080' );
    $img->Draw(
        primitive => 'rectangle',
        points    => '30,25 100,90',
        fill      => '#E02070',
    );
    $img->Write( $picture );
}

sub load { GlitchVape::IO::load( $picture ) }

# The pixels and the depth they are labelled with, since the label decides
# whether the preview is written at eight bits or sixteen.
sub picture_of
{
    my ( $img ) = @_;
    return $img->Get( 'signature' ) . ' depth=' . $img->Get( 'depth' );
}

for my $preset ( qw(vhs-decay crt-terminal newspaper gameboy hotline) )
{
    my $config   = GlitchVape::Config::load( preset => $preset );
    my $pipeline = GlitchVape::Pipeline->new(
        effects => $config->{ effects },
        order   => $config->{ order },
        disable => $config->{ disable },
    );

    my $layers  = File::Temp->newdir( 'gv_layers_XXXXXX', TMPDIR => 1 );
    my $context = sub {
        GlitchVape::Context->new(
            image    => $_[ 0 ],
            seed     => 11,
            cachedir => "$layers",
        );
    };

    my $straight = $context->( load() );
    $pipeline->run( $straight );
    my $want = picture_of( $straight->image );

    my $steps = File::Temp->newdir( 'gv_ck_XXXXXX', TMPDIR => 1 );
    my $store = GlitchVape::Checkpoint->new( dir => "$steps", budget => 1e9 );

    my %run = (
        pipeline => $pipeline,
        base     => "source-$preset",
        seed     => 11,
        load     => \&load,
        context  => $context,
    );

    my @keys = $store->chain( %run );
    is scalar @keys, $pipeline->steps + 1,
        "$preset: one key for the source and one after each step";

    is picture_of( $store->run( %run )->image ), $want,
        "$preset: rendered from the start, keeping every step, it is the "
        . 'same picture';

    # Now from each step in turn, latest first: the ones after it are
    # removed so that it is the last one there, and the source may not be
    # loaded, so a render that quietly started again from the top fails.
    my @wrong;
    for my $n ( reverse 0 .. $#keys )
    {
        unlink map { ( "$steps/$_.mpc", "$steps/$_.cache" ) }
            @keys[ $n + 1 .. $#keys ];

        my $ctx = $store->run( %run, load => sub { die "loaded\n" } );
        push @wrong, $n unless picture_of( $ctx->image ) eq $want;
    }

    is_deeply \@wrong, [],
        "$preset: and resumed from every one of its steps, it is the same "
        . 'picture';
}

# ---------------------------------------------------------------------------
# Only the latest history is kept

{
    my $steps = File::Temp->newdir( 'gv_ck_XXXXXX', TMPDIR => 1 );
    my $store = GlitchVape::Checkpoint->new( dir => "$steps", budget => 1e9 );

    my %run = (
        base    => 'source',
        seed    => 3,
        load    => \&load,
        context =>
            sub { GlitchVape::Context->new( image => $_[ 0 ], seed => 3 ) },
    );

    my $plain = GlitchVape::Pipeline->new(
        effects => { grade => { contrast => 20 }, vignette => {} } );
    my $wider = GlitchVape::Pipeline->new(
        effects => { grade => { contrast => 20 }, vignette => { size => 2 } } );

    $store->run( %run, pipeline => $plain );
    my @one = $store->chain( %run, pipeline => $plain );

    $store->run( %run, pipeline => $wider );
    my @two = $store->chain( %run, pipeline => $wider );

    is_deeply [ @one[ 0 .. 1 ] ], [ @two[ 0 .. 1 ] ],
        'two pipelines that begin alike share the keys they begin with';

    ok !-e "$steps/$one[ 2 ].mpc",
        'a render removes what the one before it kept beyond that';
    ok -e "$steps/$two[ 2 ].mpc", 'and keeps its own';
}

# ---------------------------------------------------------------------------
# A budget that allows nothing still renders

{
    my $steps = File::Temp->newdir( 'gv_ck_XXXXXX', TMPDIR => 1 );
    my $store = GlitchVape::Checkpoint->new( dir => "$steps", budget => 0 );

    my $pipeline = GlitchVape::Pipeline->new( effects => { grade => {} } );

    my $ctx = $store->run(
        pipeline => $pipeline,
        base     => 'source',
        seed     => 1,
        load     => \&load,
        context  =>
            sub { GlitchVape::Context->new( image => $_[ 0 ], seed => 1 ) },
    );

    my $plain = GlitchVape::Context->new( image => load(), seed => 1 );
    $pipeline->run( $plain );

    is picture_of( $ctx->image ), picture_of( $plain->image ),
        'with no room for checkpoints the render is the same';

    opendir my $dh, "$steps";
    is scalar( grep { /\.mpc\z/ } readdir $dh ), 0, 'and none are kept';
}

done_testing;
