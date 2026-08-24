package GlitchVape::GUI::Cache;

use strict;
use warnings;

use Digest::SHA  ();
use Encode       ();
use File::Path   ();
use File::Spec   ();
use File::Temp   ();
use Scalar::Util ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Cache - on-disk store for rendered previews

=head1 DESCRIPTION

A preview render costs two to three seconds, so the interface would be
unusable if undo had to recompute one. Every render is therefore written under
a key derived from everything that determines its content -- source file,
effect parameters, seed and size -- which makes stepping back through the undo
stack a file lookup rather than a re-render.

=head2 Layout

    ~/.cache/glitchvape/
        previews/<key>.png       shared, kept between runs, LRU-capped
        session-<pid>/           transient working files, removed on exit

C<previews> survives the process because that is what makes undo and a
restarted session cheap. The per-session directory holds things with no reuse
value -- animation frame sequences, half-written output -- and is deleted when
the process ends.

=head2 Cleaning

Three mechanisms, because each covers a case the others cannot:

=over 4

=item *

L</cleanup> removes this session's directory on a normal exit, and is wired to
the fatal signals as well so a killed process does not leak one.

=item *

L</sweep_stale> runs at startup and removes session directories belonging to
processes that no longer exist -- the case a crash leaves behind.

=item *

L</trim> enforces a byte cap on C<previews> by discarding least-recently-used
entries, since that directory is deliberately never emptied.

=back

=cut

# 256 MB of previews is a few hundred renders: enough that a session's undo
# history stays warm, small enough to not be noticed.
use constant DEFAULT_MAX_BYTES => 256 * 1024 * 1024;

# A session directory whose pid is gone is stale. One whose pid has been
# recycled by an unrelated process would never be collected, so an age limit
# backs the pid check up.
use constant STALE_AGE_SECONDS => 24 * 60 * 60;

=head2 root()

The cache root: C<$XDG_CACHE_HOME/glitchvape> when that is set, otherwise
C<~/.cache/glitchvape>. Falls back to a temporary directory when neither
variable is available, so the interface still runs in a stripped environment
rather than dying at startup.

=cut

sub root
{
    my $base = $ENV{ XDG_CACHE_HOME };

    if ( !defined $base || !length $base )
    {
        my $home = $ENV{ HOME };
        if ( defined $home && length $home )
        {
            $base = File::Spec->catdir( $home, '.cache' );
        }
    }

    if ( !defined $base || !length $base )
    {
        $base = File::Spec->tmpdir;
    }

    return File::Spec->catdir( $base, 'glitchvape' );
}

=head2 new( %arg )

    root       => path    override the location (tests)
    max_bytes  => N       cap on the shared preview directory

Creates the directories and sweeps anything a previous run left behind.

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $root = $arg{ root };
    if ( !defined $root || !length $root )
    {
        $root = root();
    }

    my $max = $arg{ max_bytes };
    if ( !defined $max )
    {
        $max = DEFAULT_MAX_BYTES;
    }

    my $self = bless {
        root      => $root,
        previews  => File::Spec->catdir( $root, 'previews' ),
        session   => File::Spec->catdir( $root, "session-$$" ),
        max_bytes => $max,
        owner_pid => $$,
        seq       => 0,
    }, $class;

    File::Path::make_path( $self->{ previews }, $self->{ session } );

    $self->sweep_stale;
    $self->trim;

    return $self;
}

# Read-only accessors.
sub root_dir    { $_[ 0 ]{ root } }
sub preview_dir { $_[ 0 ]{ previews } }
sub session_dir { $_[ 0 ]{ session } }

=head2 key( @parts )

A short hex digest of everything passed. Callers hand in the source path, the
resolved parameter list, the seed and the render size; anything that changes
the resulting image must appear here, or a stale preview will be served for a
setting the user just changed.

=cut

sub key
{
    my ( $class, @parts ) = @_;

    my $sha = Digest::SHA->new( 256 );
    for my $part ( @parts )
    {
        my $text = q{};
        if ( defined $part )
        {
            $text = "$part";
        }

        # Digest::SHA hashes bytes and refuses a string with a character
        # above 255 in it outright -- and half the parts here are effect
        # parameters, which is where a preset's Japanese text ends up.
        # Without this, applying any preset carrying a text effect died
        # before it rendered.
        #
        # Only what it would refuse is encoded. Encoding unconditionally
        # would re-encode a string that already holds octets, changing every
        # key that works today and discarding a warm cache for nothing.
        my $bytes = $text;
        $bytes = Encode::encode_utf8( $bytes ) if $bytes =~ /[^\x00-\xFF]/;

        # Length-prefixed rather than joined with a separator: otherwise
        # ('a','bc') and ('ab','c') hash identically, and two different
        # parameter sets could collide onto one cached image.
        $sha->add( length( $bytes ) . ':' );
        $sha->add( $bytes );
    }

    return substr $sha->hexdigest, 0, 32;
}

=head2 preview_path( $key, $suffix )

Where the render for C<$key> lives. Does not create it.

=cut

sub preview_path
{
    my ( $self, $key, $suffix ) = @_;

    if ( !defined $suffix || !length $suffix )
    {
        $suffix = '.png';
    }

    return File::Spec->catfile( $self->{ previews }, "$key$suffix" );
}

=head2 has( $key, $suffix )

Whether a non-empty render is already cached. Reading it also refreshes its
access time, so an entry the undo stack keeps returning to is the last thing
L</trim> discards.

=cut

sub has
{
    my ( $self, $key, $suffix ) = @_;

    my $path = $self->preview_path( $key, $suffix );
    return 0 unless -s $path;

    my $now = time;
    utime $now, $now, $path;

    return 1;
}

=head2 scratch( $suffix )

Path to a fresh, not-yet-existing file in the session directory. For staging a
render before it is moved into place, and for animation frame sequences.

=cut

sub scratch
{
    my ( $self, $suffix ) = @_;

    if ( !defined $suffix || !length $suffix )
    {
        $suffix = '.png';
    }

    $self->{ seq }++;
    return File::Spec->catfile( $self->{ session },
        sprintf( 'work%05d%s', $self->{ seq }, $suffix ) );
}

=head2 scratch_dir( $name )

A subdirectory of the session directory, created. Animation renders need a
directory of numbered frames rather than a single file.

=cut

sub scratch_dir
{
    my ( $self, $name ) = @_;

    $self->{ seq }++;
    my $dir = File::Spec->catdir( $self->{ session },
        sprintf( '%s%05d', $name || 'frames', $self->{ seq } ) );

    File::Path::make_path( $dir );
    return $dir;
}

=head2 commit( $staged, $key, $suffix )

Move a finished render into the preview store and return its path. The render
is written to the session directory first and moved into place afterwards, so
a crash mid-write cannot leave a truncated file under a key that L</has> would
then report as a hit.

=cut

sub commit
{
    my ( $self, $staged, $key, $suffix ) = @_;

    my $final = $self->preview_path( $key, $suffix );

    if ( !rename $staged, $final )
    {
        # rename fails across filesystems, which happens when the cache root
        # and the session directory have been pointed somewhere different.
        require File::Copy;
        File::Copy::move( $staged, $final )
            or die "GlitchVape::GUI::Cache: cannot store $staged: $!\n";
    }

    return $final;
}

=head2 forget( $key, $suffix )

Drop one entry. Used when a render is found to be corrupt on load, so the next
attempt recomputes rather than failing identically forever.

=cut

sub forget
{
    my ( $self, $key, $suffix ) = @_;
    unlink $self->preview_path( $key, $suffix );
    return;
}

=head2 trim()

Discard least-recently-used previews until the directory is under the byte
cap. Called after every render, so the ceiling holds during a long session
rather than only at startup.

=cut

sub trim
{
    my ( $self ) = @_;

    opendir my $dh, $self->{ previews } or return 0;
    my @entries;
    my $total = 0;

    for my $file ( readdir $dh )
    {
        next if $file eq '.' || $file eq '..';
        my $path = File::Spec->catfile( $self->{ previews }, $file );

        my @st = stat $path;
        next unless @st && -f _;

        $total += $st[ 7 ];
        push @entries, { path => $path, size => $st[ 7 ], atime => $st[ 8 ] };
    }
    closedir $dh;

    return 0 if $total <= $self->{ max_bytes };

    my $removed = 0;
    for my $e ( sort { $a->{ atime } <=> $b->{ atime } } @entries )
    {
        last if $total <= $self->{ max_bytes };
        next unless unlink $e->{ path };
        $total -= $e->{ size };
        $removed++;
    }

    return $removed;
}

=head2 purge()

Remove every stored preview. Returns C<< ( count, bytes ) >>.

The store is capped rather than cleared in the ordinary course of things --
see L</trim> -- so this exists for the one case the cap does not cover: when
what is on disk is suspected of being wrong rather than merely old. Nothing is
lost by it except time, since every entry can be rendered again.

=cut

sub purge
{
    my ( $self ) = @_;

    opendir my $dh, $self->{ previews } or return ( 0, 0 );

    my $count = 0;
    my $bytes = 0;

    for my $file ( readdir $dh )
    {
        next if $file eq '.' || $file eq '..';

        my $path = File::Spec->catfile( $self->{ previews }, $file );

        my @stat = stat $path;
        next unless @stat && -f _;

        next unless unlink $path;

        $count++;
        $bytes += $stat[ 7 ];
    }

    closedir $dh;

    return ( $count, $bytes );
}

=head2 sweep_stale()

Remove session directories left by processes that are no longer running, and
any that are older than a day regardless. Returns how many were removed.

=cut

sub sweep_stale
{
    my ( $self ) = @_;

    opendir my $dh, $self->{ root } or return 0;
    my @names = readdir $dh;
    closedir $dh;

    my $removed = 0;
    my $now     = time;

    for my $name ( @names )
    {
        my ( $pid ) = $name =~ /^session-(\d+)$/;
        next unless defined $pid;
        next if $pid == $self->{ owner_pid };

        my $dir = File::Spec->catdir( $self->{ root }, $name );
        next unless -d $dir;

        my @st  = stat $dir;
        my $age = 0;
        if ( @st )
        {
            $age = $now - $st[ 9 ];
        }

        # kill 0 reports whether the process exists. A live pid with a young
        # directory is another instance running right now, and must be left
        # alone; anything else is debris.
        my $alive = kill 0, $pid;
        next if $alive && $age < STALE_AGE_SECONDS;

        File::Path::remove_tree( $dir, { safe => 1, error => \my $err } );
        $removed++;
    }

    return $removed;
}

=head2 cleanup()

Remove this session's directory. Safe to call more than once, and a no-op in a
forked child, which must not delete the directory its parent is still using.

=cut

sub cleanup
{
    my ( $self ) = @_;

    return 0 unless $$ == $self->{ owner_pid };
    return 0 if $self->{ cleaned };

    $self->{ cleaned } = 1;
    return 0 unless -d $self->{ session };

    File::Path::remove_tree( $self->{ session },
        { safe => 1, error => \my $err } );

    return 1;
}

=head2 install_signal_handlers()

Arrange for L</cleanup> to run on the signals that would otherwise skip
C<DESTROY>. The previous handler is called afterwards where one existed, so
this does not swallow a caller's own shutdown.

=cut

sub install_signal_handlers
{
    my ( $self ) = @_;

    # A weak reference, or the closures in %SIG would keep the cache -- and so
    # the session directory -- alive for the life of the program even after
    # the interface has dropped it.
    my $weak = $self;
    Scalar::Util::weaken( $weak );

    for my $sig ( qw(INT TERM HUP) )
    {
        my $previous = $SIG{ $sig };

        ## no critic (Variables::RequireLocalizedPunctuationVars)
        $SIG{ $sig } = sub {
            $weak->cleanup if $weak;

            if ( ref $previous eq 'CODE' )
            {
                return $previous->( @_ );
            }

            # Re-raise with the handler removed, so the exit status reports
            # the signal rather than a plain exit(0).
            $SIG{ $sig } = 'DEFAULT';
            kill $sig, $$;
            return;
        };
        ## use critic
    }

    return;
}

sub DESTROY
{
    my ( $self ) = @_;
    local $@;
    eval { $self->cleanup; 1 };
    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Render>, which computes the keys this stores under.

=cut
