#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Path ();
use File::Spec ();
use File::Temp ();

use Test::More;
use GlitchVape::GUI::Cache;

# Everything here runs against a temporary root: a test that swept the real
# ~/.cache/glitchvape would delete a running session's working directory.

sub temp_root
{
    my $dir = File::Temp->newdir( 'gv_cache_XXXXXX', TMPDIR => 1 );
    return $dir;
}

sub write_file
{
    my ( $path, $bytes ) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print { $fh } $bytes;
    close $fh;
    return $path;
}

{
    local $ENV{ XDG_CACHE_HOME } = '/xdg';
    is GlitchVape::GUI::Cache::root(), '/xdg/glitchvape',
        'XDG_CACHE_HOME is honoured';
}

{
    local $ENV{ XDG_CACHE_HOME } = q{};
    local $ENV{ HOME }           = '/home/someone';
    is GlitchVape::GUI::Cache::root(), '/home/someone/.cache/glitchvape',
        'falling back to ~/.cache';
}

{
    my $dir   = temp_root();
    my $cache = GlitchVape::GUI::Cache->new( root => "$dir" );

    ok -d $cache->preview_dir, 'the preview directory is created';
    ok -d $cache->session_dir, 'the session directory is created';
    like $cache->session_dir, qr/session-$$\z/,
        'the session directory is named for this process';
}

# The key has to distinguish parameter lists that concatenate to the same
# string, or two different pipelines would share one cached image.
{
    my $a = GlitchVape::GUI::Cache->key( 'a',  'bc' );
    my $b = GlitchVape::GUI::Cache->key( 'ab', 'c' );

    isnt $a, $b, 'keys are not confused by where the boundaries fall';

    is( GlitchVape::GUI::Cache->key( 'a', 'bc' ), $a, 'keys are stable' );

    is( length $a, 32, 'a key is short enough to be a filename' );
    like $a, qr/^[0-9a-f]+\z/, 'and safe to use as one';

    isnt( GlitchVape::GUI::Cache->key( 'a' ),
        $a, 'dropping a part changes the key' );
}

{
    my $dir   = temp_root();
    my $cache = GlitchVape::GUI::Cache->new( root => "$dir" );

    ok !$cache->has( 'nothing' ), 'an absent key is a miss';

    my $staged = $cache->scratch( '.png' );
    write_file( $staged, 'x' x 100 );

    my $final = $cache->commit( $staged, 'abc', '.png' );

    ok -f $final,            'a committed render exists';
    ok !-e $staged,          'and is no longer in the session directory';
    ok $cache->has( 'abc' ), 'and is now a hit';

    is $final, $cache->preview_path( 'abc', '.png' ),
        'commit returns the path preview_path predicts';

    $cache->forget( 'abc', '.png' );
    ok !$cache->has( 'abc' ), 'forget removes an entry';
}

# An empty file must not count as a hit: it would be served as a preview
# forever, and every re-render would produce the same empty file.
{
    my $dir   = temp_root();
    my $cache = GlitchVape::GUI::Cache->new( root => "$dir" );

    write_file( $cache->preview_path( 'empty', '.png' ), q{} );
    ok !$cache->has( 'empty' ), 'a zero-length entry is not a hit';
}

{
    my $dir   = temp_root();
    my $cache = GlitchVape::GUI::Cache->new( root => "$dir" );

    ok $cache->scratch( '.png' ) ne $cache->scratch( '.png' ),
        'scratch paths are unique';

    my $frames = $cache->scratch_dir( 'frames' );
    ok -d $frames, 'a scratch directory is created';
    like $frames, qr/\Q@{[ $cache->session_dir ]}\E/,
        'inside the session directory';
}

# ---------------------------------------------------------------------------
# Cleaning

{
    my $dir = temp_root();

    # 1 KB cap, then write four 400-byte entries: the oldest by access time
    # must go.
    my $cache =
        GlitchVape::GUI::Cache->new( root => "$dir", max_bytes => 1000 );

    my $now = time;
    for my $n ( 1 .. 4 )
    {
        my $path = $cache->preview_path( "entry$n", '.png' );
        write_file( $path, 'x' x 400 );

        # Spread the access times so the eviction order is unambiguous.
        utime $now - ( 100 - $n ), $now - ( 100 - $n ), $path;
    }

    my $removed = $cache->trim;

    cmp_ok $removed, '>=', 2, 'trim removes enough to get under the cap';
    ok !-e $cache->preview_path( 'entry1', '.png' ),
        'the least recently used entry goes first';
    ok -e $cache->preview_path( 'entry4', '.png' ),
        'the most recently used entry survives';

    my $total = 0;
    opendir my $dh, $cache->preview_dir or die $!;
    for my $f ( readdir $dh )
    {
        my $p = File::Spec->catfile( $cache->preview_dir, $f );
        $total += -s $p if -f $p;
    }
    closedir $dh;

    cmp_ok $total, '<=', 1000, 'the directory ends up under the cap';
}

{
    my $dir = temp_root();

    # A pid that cannot be running: the highest pid is well below this on
    # every system this targets.
    my $dead = File::Spec->catdir( "$dir", 'session-4194303' );
    File::Path::make_path( $dead );
    write_file( File::Spec->catfile( $dead, 'leftover.png' ), 'x' );

    my $cache = GlitchVape::GUI::Cache->new( root => "$dir" );

    ok !-d $dead, 'a session directory from a dead process is swept at startup';
    ok -d $cache->session_dir, 'and this session survives its own sweep';
}

{
    my $dir = temp_root();

    # Another live process's session directory must be left alone, or two
    # windows open at once would delete each other's working files.
    my $live = File::Spec->catdir( "$dir", "session-$$" . '0' );
    File::Path::make_path( $live );

    my $cache = GlitchVape::GUI::Cache->new( root => "$dir" );

    my ( $pid ) = $live =~ /session-(\d+)/;

SKIP:
    {
        skip 'the constructed pid happens not to be running', 1
            unless kill 0, $pid;

        ok -d $live, "a live process's session directory is left alone";
    }
}

{
    my $dir     = temp_root();
    my $cache   = GlitchVape::GUI::Cache->new( root => "$dir" );
    my $session = $cache->session_dir;

    write_file( File::Spec->catfile( $session, 'work.png' ), 'x' );

    ok $cache->cleanup, 'cleanup reports having done something';
    ok !-d $session,    'the session directory is gone';
    is $cache->cleanup, 0, 'a second cleanup is a no-op';
}

# The preview store is the point of the cache and must outlive the session
# that filled it.
{
    my $dir = temp_root();

    my $key;
    {
        my $cache  = GlitchVape::GUI::Cache->new( root => "$dir" );
        my $staged = $cache->scratch( '.png' );
        write_file( $staged, 'x' x 10 );
        $cache->commit( $staged, 'keeper', '.png' );
        $key = $cache->preview_path( 'keeper', '.png' );
        $cache->cleanup;
    }

    ok -f $key, 'committed previews survive the session that made them';
}

{
    my $dir   = temp_root();
    my $cache = GlitchVape::GUI::Cache->new( root => "$dir" );

    # A forked child must never delete the directory its parent is using.
    # Simulated by moving the recorded owner pid aside, which is what the
    # guard actually tests.
    $cache->{ owner_pid } = $$ + 1;

    is $cache->cleanup, 0, 'cleanup in a child process does nothing';
    ok -d $cache->session_dir, 'and the session directory survives';

    $cache->{ owner_pid } = $$;
    $cache->cleanup;
}

# Digest::SHA hashes bytes and refuses a string carrying a character above
# 255 outright. Half of what goes into a key is effect parameters, and that is
# where a preset's Japanese text ends up -- so without encoding first, applying
# any preset with a text effect in it died before it rendered.
#
# The calls below are parenthesised: `is Class->method(...)` is read as an
# indirect object call and looks for an `is` method on the class.
{
    my $key = eval { GlitchVape::GUI::Cache->key( "\x{7ACB}\x{4F53}" ) };

    ok $key, 'a key can be made from text outside ASCII';
    like $key, qr/\A[0-9a-f]{32}\z/, 'and it is a digest like any other';

    is( GlitchVape::GUI::Cache->key( "\x{7ACB}\x{4F53}" ),
        $key, 'the same characters give the same key' );
    isnt( GlitchVape::GUI::Cache->key( "\x{4F53}\x{7ACB}" ),
        $key, 'and different ones do not' );

    # The length prefix counts octets now rather than characters. For ASCII
    # those are the same number, so every key made before this stays valid and
    # a warm cache is not silently thrown away.
    is(
        GlitchVape::GUI::Cache->key( 'abc' ),
        GlitchVape::GUI::Cache->key( 'abc' ),
        'ASCII keys are unchanged by the encoding'
    );

    # An existing key must not change. The digest below is what the original
    # algorithm produced for this part, so a cache warmed before the encoding
    # was added is still a cache afterwards.
    is(
        GlitchVape::GUI::Cache->key( 'abc' ),
        'aab5f9ae99b2e38fb462025c8f72f570',
        'an ASCII key is byte-for-byte what it always was'
    );

    # Only what Digest::SHA would refuse gets encoded, so a part that already
    # holds octets is hashed as it stands rather than encoded a second time.
    my $octets = "\xE7\xAB\x8B";
    ok( GlitchVape::GUI::Cache->key( $octets ), 'octets hash without dying' );
}

done_testing;
