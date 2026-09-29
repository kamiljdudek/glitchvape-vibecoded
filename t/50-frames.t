#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Digest::SHA ();
use File::Temp  ();
use Test::More;

use GlitchVape           ();
use GlitchVape::Animate  ();
use GlitchVape::Frames   ();
use GlitchVape::IO       ();
use GlitchVape::Pipeline ();
use GlitchVape::Tools    ();
use GlitchVape::Workers  ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };
plan skip_all => 'frames are only rendered in parallel where /proc says so'
    unless -d '/proc/self/task';

# A loop's frames are rendered by several processes at once, because nothing
# joins one frame to the next. What has to hold is that it makes no
# difference: the same frames, the same count reported, and a failure in any
# worker reported as the failure it was.
#
# Everything that forks comes first. Forking is only safe in a process that
# has not yet decoded anything -- which is the rule under test further down --
# and building the source picture decodes.

my $dir = File::Temp->newdir( 'gv_frames_XXXXXX', TMPDIR => 1 );

# Written by a child, so that this process stays one that may fork.
my $picture = "$dir/source.png";
{
    my $pid = fork // die "fork: $!";
    unless ( $pid )
    {
        my $img = Image::Magick->new( size => '200x150' );
        $img->Read( 'gradient:#102050-#F0C080' );
        $img->Draw(
            primitive => 'rectangle',
            points    => '40,30 120,100',
            fill      => '#E02070',
        );
        $img->Draw(
            primitive => 'ellipse',
            points    => '150,80 30,40 0,360',
            fill      => '#20D0C0',
        );
        $img->Write( $picture );
        require POSIX;
        POSIX::_exit( 0 );
    }
    waitpid $pid, 0;
}

BAIL_OUT( 'could not build the test picture' ) unless -s $picture;

ok GlitchVape::Workers::fork_safe(),
    'a process that has decoded nothing is one that may fork';

# One of everything that moves, redraws or caches: grain re-rolls, scanlines
# drift and cache a tile, the glare sweeps, cmyk caches four screens.
my $pipeline = GlitchVape::Pipeline->new(
    effects => {
        grain     => { amount => 0.1 },
        scanlines => { drift  => 3 },
        glare     => { drift  => 0.5 },
        cmyk      => { pitch  => 6 },
    }
);

sub frames
{
    my ( %arg ) = @_;

    my $out   = File::Temp->newdir( 'gv_frames_out_XXXXXX',   TMPDIR => 1 );
    my $cache = File::Temp->newdir( 'gv_frames_cache_XXXXXX', TMPDIR => 1 );

    my @progress;
    my $done = GlitchVape::Frames::render(
        load     => sub { GlitchVape::IO::load( $picture ) },
        pipeline => $arg{ pipeline } // $pipeline,
        seed     => 5,
        frames   => 6,
        dir      => "$out",
        cachedir => "$cache",
        jobs     => $arg{ jobs },
        on_frame => sub { push @progress, [ @_ ] },
    );

    my @sums =
        map { Digest::SHA->new( 256 )->addfile( $_ )->hexdigest }
        @{ $done->{ paths } };

    return {
        done     => $done,
        sums     => \@sums,
        progress => \@progress,
        keep     => [ $out, $cache ]
    };
}

# ---------------------------------------------------------------------------
# Several processes render the frames one process would, to the byte

my $parallel = frames( jobs => 3 );

is scalar @{ $parallel->{ sums } }, 6, 'every frame of the loop is written';

like $parallel->{ done }{ paths }[ 0 ], qr/\.ppm\z/,
    'and written as PPM, which is the pixels with a line of header';

is_deeply [ map { $_->[ 0 ] } @{ $parallel->{ progress } } ], [ 1 .. 6 ],
    'the count goes up by one for each frame finished, whatever order '
    . 'they finish in';

ok !( grep { $_->[ 1 ] != 6 } @{ $parallel->{ progress } } ),
    'and always against the same total';

is_deeply $parallel->{ done }{ dims }, [ 200, 150 ],
    'the size reported is the size of the frames';

ok scalar @{ $parallel->{ done }{ timings } },
    'frame 0 reports its timings from whichever process drew it';

# ---------------------------------------------------------------------------
# A worker that fails fails the render, with its own message

{
    my $broken = GlitchVape::Pipeline->new( effects => { grain => {} } );
    $broken->{ steps }[ 0 ]{ spec } = {
        %{ $broken->{ steps }[ 0 ]{ spec } },
        apply => sub {
            die "frame three is cursed\n" if $_[ 0 ]->frame == 3;
            return;
        },
    };

    my $err;
    eval { frames( pipeline => $broken, jobs => 3 ); 1 } or $err = $@;

    like $err, qr/frame three is cursed/,
        'a worker that dies stops the render with the message it died with';
}

ok GlitchVape::Workers::fork_safe(),
    'and nothing that happened in the workers changed this process';

# ---------------------------------------------------------------------------
# One process renders exactly the same frames

my $serial = frames( jobs => 1 );

is_deeply $serial->{ sums }, $parallel->{ sums },
    'the frames are byte for byte those one process renders';

ok !GlitchVape::Workers::fork_safe(),
    'a process that has decoded a picture is one that may not fork';

# Asked for workers now, it must not fork: ImageMagick's thread pool is
# running here, and a forked worker would inherit its locks and hang.
my $refused = frames( jobs => 3 );

is_deeply $refused->{ sums }, $parallel->{ sums },
    'asked for workers where forking is unsafe, it renders them itself';

# ---------------------------------------------------------------------------
# The helpers

cmp_ok GlitchVape::Workers::cpus(), '>=', 1, 'there is at least one CPU';

# ---------------------------------------------------------------------------
# A file in the shared cache is always a finished one

sub write_file
{
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!\n";
    print { $fh } $text;
    close $fh or die "cannot write $path: $!\n";
    return;
}

{
    my $cache = File::Temp->newdir( 'gv_cached_XXXXXX', TMPDIR => 1 );
    my $path  = "$cache/thing.png";

    my $err;
    eval {
        GlitchVape::Context::cached_file( $path,
            sub { write_file( $_[ 0 ], 'half' ); die "no\n" } );
        1;
    } or $err = $@;

    is $err, "no\n", 'a builder that dies has its error passed on';
    ok !-e $path, 'and leaves nothing under the name';

    opendir my $dh, "$cache";
    my @remaining = grep { !/^\.\.?\z/ } readdir $dh;
    is_deeply \@remaining, [], 'nor anything half-written beside it';

    my $built = 0;
    my $build = sub {
        $built++;
        like $_[ 0 ], qr/\.png\z/, 'the builder writes to a name with the '
            . 'same extension, which is how ImageMagick picks a format';
        isnt $_[ 0 ], $path, 'but not to the name itself';
        write_file( $_[ 0 ], 'done' );
    };

    GlitchVape::Context::cached_file( $path, $build ) for 1 .. 3;
    is $built, 1, 'and it is built once, then found';
}

# ---------------------------------------------------------------------------
# The encoder reads PPM frames

SKIP:
{
    skip 'ffmpeg is not installed', 1
        unless GlitchVape::Tools::have( 'ffmpeg' );

    my $out = "$dir/loop.mp4";
    GlitchVape::Animate::encode(
        frames => $serial->{ done }{ paths },
        output => $out,
        fps    => 6,
        fast   => 1,
    );

    my $count = GlitchVape::Tools::capture(
        GlitchVape::Tools::find( 'ffprobe' ) // 'ffprobe',
        '-v',
        'error',
        '-count_frames',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=nb_read_frames',
        '-of',
        'csv=p=0',
        $out,
    );

    like $count // '', qr/^6\b/, 'and ffmpeg encodes all six of them';
}

done_testing;
