#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use List::Util ();
use Test::More;

# Gtk, because the render child is reaped by a Glib child watch.
BEGIN
{
    eval { require Gtk3; Gtk3->import; 1 }
        or plan skip_all => 'Gtk3 is not available';
    Gtk3::init_check()
        or plan skip_all => 'no display';
}

use GlitchVape              ();
use GlitchVape::GUI         ();
use GlitchVape::GUI::Cache  ();
use GlitchVape::GUI::Render ();
use GlitchVape::GUI::State  ();
use GlitchVape::IO          ();
use GlitchVape::Pipeline    ();
use GlitchVape::Context     ();
use GlitchVape::Tools       ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );

local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

# The window's previews, rendered for real: a child forked from a process
# running a Gtk main loop, as the window does it.
#
# What is asked is that the ways a preview is now made faster are invisible.
# A still preview starts from the last effect its pipeline shares with the
# render before it, and has to come out as the picture a render from the top
# would give. A loop's frames are shared out between workers of the child's,
# and cancelling has to take those with it.

my $root = File::Temp->newdir( 'gv_guirender_XXXXXX', TMPDIR => 1 );

# Written by a child, so that this process never decodes an image: that is
# the rule the window keeps, and the one the render child relies on.
my $picture = "$root/photo.png";
{
    my $pid = fork // die "fork: $!";
    unless ( $pid )
    {
        require Image::Magick;
        my $img = Image::Magick->new( size => '320x240' );
        $img->Read( 'gradient:#102050-#F0C080' );
        $img->Draw(
            primitive => 'rectangle',
            points    => '60,50 200,180',
            fill      => '#E02070',
        );
        $img->Write( $picture );
        require POSIX;
        POSIX::_exit( 0 );
    }
    waitpid $pid, 0;
}

BAIL_OUT( 'could not build the test picture' ) unless -s $picture;

my $cache  = GlitchVape::GUI::Cache->new( root => "$root/cache" );
my $render = GlitchVape::GUI::Render->new( cache => $cache );
$render->source( $picture );

my $state = GlitchVape::GUI::State->new( source => $picture, seed => 21 );
$state->load_preset( 'vhs-decay' );

sub pump_until
{
    my ( $done, $limit ) = @_;
    $limit ||= 60_000;

    my $expired = 0;
    my ( $timer, $poll );

    $timer = Glib::Timeout->add(
        $limit,
        sub {
            $expired = 1;
            $timer   = undef;
            Gtk3->main_quit;
            return 0;
        }
    );

    $poll = Glib::Timeout->add(
        20,
        sub {
            return 1 unless $done->();
            $poll = undef;
            Gtk3->main_quit;
            return 0;
        }
    );

    Gtk3->main;

    Glib::Source->remove( $_ ) for grep { defined } ( $timer, $poll );

    return !$expired;
}

sub preview
{
    my ( %arg ) = @_;

    my ( $path, $error );
    $render->preview(
        state    => $state,
        size     => 200,
        on_done  => sub { $path  = $_[ 0 ] },
        on_error => sub { $error = $_[ 0 ] },
        %arg,
    );

    ok pump_until( sub { defined $path || defined $error } ),
        'the preview finished';
    is $error, undef, 'without an error';

    return $path;
}

# What a render from the top gives, done in a child for the same reason.
sub straight
{
    my $config = $state->pipeline_config;
    my $out    = "$root/straight.png";
    unlink $out;

    my $pid = fork // die "fork: $!";
    unless ( $pid )
    {
        # In a block of its own, so that the context -- and its scratch
        # directory -- is gone before _exit, which destroys nothing.
        {
            my $pipeline = GlitchVape::Pipeline->new(
                effects => $config->{ effects },
                order   => $config->{ order },
                disable => $config->{ disable },
            );
            my $ctx = GlitchVape::Context->new(
                image  => GlitchVape::IO::load( $picture, max_dim => 200 ),
                source => $picture,
                seed   => $state->seed,
            );
            $pipeline->run( $ctx );
            GlitchVape::IO::save( $ctx->image, $out, quality => 92 );
        }
        require POSIX;
        POSIX::_exit( 0 );
    }
    waitpid $pid, 0;

    return $out;
}

sub same_picture
{
    my ( $a, $b ) = @_;
    my $ae = GlitchVape::Tools::capture(
        GlitchVape::Tools::magick_argv(
            $a,         $b,        '-metric',       'AE',
            '-compare', '-format', '%[distortion]', 'info:'
        )
    );
    return ( $ae // '' ) =~ /^0(?:\s|$)/ ? 1 : 0;
}

sub kept_steps
{
    opendir my $dh, $cache->steps_dir or return 0;
    return scalar grep { /\.mpc\z/ } readdir $dh;
}

# ---------------------------------------------------------------------------
# The first preview keeps every step, and is the picture a straight render is

my $first = preview();
ok same_picture( $first, straight() ),
    'a preview is the picture a render from the start gives';

# The preview is handed to the window as BMP rather than as the PNG it used to
# be, for speed. What has to hold is what the window is shown: GdkPixbuf
# decodes an opaque PNG to three channels and a BMP to as many as it has, so
# both are read out as four, an opaque pixel's fourth being 255.
{
    my $rgba = sub {
        my $pb = Gtk3::Gdk::Pixbuf->new_from_file( $_[ 0 ] );
        my ( $w, $h, $n, $stride ) = (
            $pb->get_width,      $pb->get_height,
            $pb->get_n_channels, $pb->get_rowstride,
        );
        my $data = $pb->get_pixels;
        my $out  = "${w}x$h:";
        for my $y ( 0 .. $h - 1 )
        {
            my $row = substr $data, $y * $stride, $w * $n;
            $out .=
                  $n == 4
                ? $row
                : join q{},
                map { substr( $row, $_ * 3, 3 ) . "\xFF" } 0 .. $w - 1;
        }
        return $out;
    };

    like $first, qr/\.bmp\z/, 'a still preview is handed over as BMP';
    ok $rgba->( $first ) eq $rgba->( straight() ),
        'and the window decodes it to the pixels it decoded from the PNG';
}
is kept_steps(), scalar( $state->effect_names ) + 1,
    'and the source and the picture after each effect are kept';

# ---------------------------------------------------------------------------
# Adjusting a late effect starts after the ones before it

# The render child is a fork of this process, so replacing the loader here
# replaces it there: a preview that decoded the photograph again, rather than
# starting from what was kept, would fail.
{
    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'redefine';
    local *GlitchVape::IO::load = sub { die "decoded the photograph again\n" };
    ## use critic

    $state->param( 'vignette', 'strength', 0.8 );
    my $adjusted = preview();

    ok defined $adjusted, 'adjusting the vignette renders without decoding';
}

ok same_picture(
    $render->{ cache }->preview_path(
        $state->cache_key( size => 200, extra => [ 'watermark', 'none' ] ),
        GlitchVape::GUI::Render::STILL
    ),
    straight()
    ),
    'and the picture it gives is the one a render from the start gives';

# ---------------------------------------------------------------------------
# A loop is rendered by workers, and cancelled with them

SKIP:
{
    skip 'ffmpeg is not installed', 4
        unless GlitchVape::Tools::have( 'ffmpeg' );

    my @progress;
    my $loop = preview(
        animate     => { frames => 6, fps => 6 },
        on_progress => sub { push @progress, $_[ 0 ] },
    );

    like $loop // '', qr/\.mp4\z/, 'a loop is previewed as a video';
    is_deeply \@progress, [ 1 .. 6 ],
        'and its frames are counted as they are finished';

    # Cancelled once the workers are under way, with a loop long enough that
    # they are still busy when it lands.
    $state->param( 'vignette', 'strength', 0.3 );

    my $started = 0;
    $render->preview(
        state       => $state,
        size        => 200,
        animate     => { frames => 48, fps => 6 },
        on_progress => sub { $started = 1 },
        on_done     => sub { },
        on_error    => sub { },
    );

    my $child = $render->{ job }{ pid };
    pump_until( sub { $started }, 60_000 );

    my @workers = children_of( $child );
    $render->cancel;

    pump_until( sub { !List::Util::any { kill 0, $_ } $child, @workers },
        10_000 );

    ok scalar @workers, 'the loop was being drawn by workers of the child';
    is scalar( grep { kill 0, $_ } $child, @workers ), 0,
        'and cancelling it stopped the child and every one of them';
}

sub children_of
{
    my ( $parent ) = @_;

    my @found;
    opendir my $dh, '/proc' or return;
    for my $pid ( grep { /^\d+\z/ } readdir $dh )
    {
        open my $fh, '<', "/proc/$pid/stat" or next;
        my $stat = <$fh> // '';
        close $fh;

        my ( $ppid ) = $stat =~ /\)\s+\S+\s+(\d+)/;
        push @found, $pid if defined $ppid && $ppid == $parent;
    }

    return @found;
}

$cache->cleanup;

done_testing;
