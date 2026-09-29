package GlitchVape::Workers;

use strict;
use warnings;

use POSIX ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Workers - how many processes a render may use, and when it may fork

=head1 DESCRIPTION

Three small facts that anything forking renders needs and that are easy to get
wrong: how many cores this process may actually use, whether forking it now is
safe, and how to stop a forked worker from starting as many threads as the
whole machine has.

=head2 Why forking is only sometimes safe

ImageMagick is built with OpenMP, and an OpenMP thread pool does not survive
C<fork>: the child inherits the pool's locks without the threads that would
release them, and its first parallel operation hangs for ever. The pool starts
with the first image operation, so a process that has decoded anything must
not fork renders. CLAUDE.md calls this the single most expensive mistake
available in this codebase, because it presents as an intermittent hang.

L</fork_safe()> asks the only question that answers it for any caller: does this
process have more than one thread. That is the same count
L<GlitchVape::Plugins> takes of a plug-in's child after loading it, and it is
conservative in the right direction -- a process with any threads at all,
OpenMP's or GLib's, is not forked, whatever the threads are for.

=head2 Why a worker limits its own threads

Four workers on four cores, each letting ImageMagick run a thread per core, is
sixteen threads fighting for four cores, and measured slower than the same
four workers holding one each. The limit has to be set inside the worker:
ImageMagick reads C<MAGICK_THREAD_LIMIT> once, when it starts, which in a
forked worker has already happened in the parent.

=cut

=head2 cpus()

How many CPUs this process may run on: the affinity mask where Linux reports
one, capped by a cgroup CPU quota where there is one, and C</proc/cpuinfo>
otherwise. At least 1.

The affinity mask rather than the count of processors, because a render run
under C<taskset> -- or in a container given two of a machine's cores -- that
forked one worker per processor would be as oversubscribed as one that forked
without limit.

=cut

sub cpus
{
    my $n = _allowed() || _processors() || 1;

    my $quota = _quota();
    $n = $quota if $quota && $quota < $n;

    return $n;
}

# The Cpus_allowed_list line of /proc/self/status: "0-3,8,10-11".
sub _allowed
{
    open my $fh, '<', '/proc/self/status' or return 0;
    my ( $list ) = map { /^Cpus_allowed_list:\s*(\S+)/ ? $1 : () } <$fh>;
    close $fh;

    return 0 unless defined $list;

    my $n = 0;
    for my $range ( split /,/, $list )
    {
        my ( $lo, $hi ) = $range =~ /^(\d+)(?:-(\d+))?$/ or next;
        $n += ( defined $hi ? $hi - $lo : 0 ) + 1;
    }

    return $n;
}

sub _processors
{
    open my $fh, '<', '/proc/cpuinfo' or return 0;
    my $n = grep { /^processor\s*:/ } <$fh>;
    close $fh;

    return $n;
}

# cgroup v2's cpu.max is "max 100000" with no quota, or "200000 100000" for
# two CPUs' worth of time -- which is what a container limited with --cpus
# sees, while its affinity mask still names every core of the host.
sub _quota
{
    open my $fh, '<', '/sys/fs/cgroup/cpu.max' or return 0;
    my $line = <$fh> // q{};
    close $fh;

    my ( $quota, $period ) = $line =~ /^(\d+)\s+(\d+)/ or return 0;
    return 0 unless $period;

    my $n = POSIX::ceil( $quota / $period );
    return $n < 1 ? 1 : $n;
}

=head2 fork_safe()

True when this process has exactly one thread, which is what makes forking a
render out of it safe -- see L</Why forking is only sometimes safe>. False
where that cannot be told, since the cost of guessing wrong is a hang and the
cost of guessing safe is only a render done in one process.

=cut

sub fork_safe
{
    opendir my $dh, '/proc/self/task' or return 0;
    my $threads = grep { /^\d+$/ } readdir $dh;
    closedir $dh;

    return $threads == 1 ? 1 : 0;
}

=head2 limit_threads( $n )

Hold ImageMagick to C<$n> threads in this process and in every C<magick> it
starts. For a forked worker, before its first image operation. See
L</Why a worker limits its own threads>.

=cut

sub limit_threads
{
    my ( $n ) = @_;
    $n = 1 unless $n && $n >= 1;

    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $ENV{ MAGICK_THREAD_LIMIT } = $n;
    ## use critic

    require Image::Magick;
    Image::Magick->new->Set( 'thread-limit' => $n );

    return $n;
}

1;
