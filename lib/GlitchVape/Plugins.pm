package GlitchVape::Plugins;

use strict;
use warnings;

use Config     qw(%Config);
use File::Spec ();
use POSIX      ();

use GlitchVape::Paths ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Plugins - finding, trying and loading plug-ins

=head1 SYNOPSIS

A plug-in is one module, installed anywhere Perl looks:

    package GlitchVape::Plugin::Muffins;

    use strict;
    use warnings;

    use GlitchVape::Plugins api => 1;
    use GlitchVape::Magick   ();
    use GlitchVape::Registry ();

    our $VERSION = '1.00';

    GlitchVape::Registry->register(
        name    => 'frosting',
        title   => 'Frosting',
        stage   => 'optics',
        summary => 'A sugary haze over everything',
        params  => {
            amount => {
                default => 0.4, type => 'num', min => 0, max => 1,
                doc     => 'How thick the haze is',
            },
        },
        apply => \&_frosting,
    );

    sub _frosting
    {
        my ( $ctx, $p ) = @_;

        GlitchVape::Magick::check(
            $ctx->image->Blur( sigma => 0.1 + 4 * $p->{ amount } ),
            'frosting: could not blur' );

        return;
    }

    1;

and from then on C<glitchvape --explain frosting>, C<--set frosting.amount=0.7>,
a C<frosting:> key in a preset and a slider in the window all exist, because
every one of them is made from the declaration.

=head1 DESCRIPTION

Everything the program offers is a declaration in a registry, and the front
ends are made from the registries rather than from lists of their own -- which
was already true before plug-ins existed, and is the whole reason they are
possible. A plug-in is therefore nothing but more declarations, made from a
module the program did not ship.

=head1 WHAT A PLUG-IN IS

A module called C<GlitchVape::Plugin::I<Name>>, in a file
F<GlitchVape/Plugin/I<Name>.pm> in any directory on C<@INC>. Only that top
level is loaded: C<GlitchVape::Plugin::Muffins::Frosting> is the plug-in's own
business, to C<use> from its main module or not.

Its own namespace rather than C<GlitchVape::Effect::*>, which is where the
program's effects live, for three reasons that each bit somebody somewhere:

=over 4

=item *

A module on C<@INC> earlier than another of the same name replaces it, and
F</usr/local> comes before F</usr/share> on every distribution. A plug-in that
happened to call a file F<GlitchVape/Effect/Color.pm> would silently replace
the packaged one, and ten effects with it.

=item *

Files left behind by an older install of the program would be found and
loaded as though they were plug-ins.

=item *

Nothing could tell a plug-in from the program, and they have to be told apart:
a broken effect that ships is a broken build and should stop everything, and a
broken plug-in should stop nothing but itself.

=back

=head1 WHAT A PLUG-IN MAY ADD

Each of these is a place with a C<register> of its own, which is also how the
program's own entries are made or listed:

    GlitchVape::Registry->register         an effect
    GlitchVape::Registry->register_source  a named list for suggest/choose
    GlitchVape::Generator->register        a kind of generated soundtrack
    GlitchVape::Tools->register            an external tool its effects need
    GlitchVape::Palette->register          a palette
    GlitchVape::Palette->register_duotone  a two-stop duotone ramp
    GlitchVape::Fonts->register_role       a font role
    GlitchVape::Fonts->add_dir             a directory of fonts, with licences
    GlitchVape::Config->add_preset_dir     a directory of presets

A plug-in may not take a name the program or another plug-in already has.
Every registry refuses a second registration of a name, and a plug-in whose
registration is refused is refused whole.

=head1 THE API VERSION

    use GlitchVape::Plugins api => 1;

is required, and comes before anything else the plug-in does. The number goes
up when something a plug-in could rely on changes incompatibly, and a plug-in
written for a different one is refused with a sentence saying which it wanted
and which this is -- rather than loading and then failing somewhere nobody can
connect to the cause. Additions do not change it: they are what a module's own
version is for, as in C<use GlitchVape::Registry 0.02>.

A plug-in that does not say which API it was written for is refused as well.
Being strict about it on the first day costs nothing; being strict about it
later would refuse every plug-in written in between.

=head1 HOW ONE IS LOADED

Loading L<GlitchVape> loads the plug-ins, after the program's own effects and
generators have registered, so that a collision over a name is always the
plug-in's. They are loaded in order of name.

Each one is tried first in a throwaway child process, and only loaded into
this one if the child came back clean. That is not caution for its own sake.
The one thing a plug-in could do at load time that nothing afterwards can undo
is start a thread pool -- which is what the first ImageMagick operation does,
because ImageMagick is built with OpenMP -- and a process holding one is a
process every forked render deadlocks in (see invariant 5 in F<CLAUDE.md>).
Checking afterwards would find the pool; it could not take it away. So the
child is where the pool gets started, if anybody starts one, and the child is
thrown away.

What the child checks:

=over 4

=item * that the module loads at all, and declares its API;

=item * that nothing it registers is refused;

=item * that it started no threads -- a fork keeps only the thread that called
it, so the child starts with exactly one, whatever the parent was doing;

=item * that nothing it loaded reaches for Gtk3 or Glib, which is
C<make check-split> applied to code the build never saw. A plug-in is
declarations; the window is made from them, so a plug-in never needs Gtk.

=item * that it neither ends the process nor takes more than
L</PROBE_SECONDS> to load.

=back

A plug-in that fails any of them is I<refused>: whatever it registered is taken
back, a warning names it and the reason, and C<--list-plugins> and the about
window list it with that reason. Nothing else stops.

The consequence for anybody writing one: B<a plug-in's module is loaded twice,
once in each process, and must do nothing while loading but declare things.>
Anything expensive or external belongs inside C<apply>, which runs in a render.

=head1 CHOOSING WHICH ARE LOADED

C<$GLITCHVAPE_PLUGINS>, beside the three variables that say where things are
found:

    unset or empty      every plug-in found
    none                none of them
    Muffins:Frosting    only these
    -Muffins            every plug-in but these

Names are the part after C<GlitchVape::Plugin::>. C<make test> sets it to
C<none>, so a plug-in installed on the machine running the suite cannot fail
the program's own tests.

=head1 WHERE THEY ARE LOOKED FOR

C<@INC>, which is to say wherever Perl modules go: the distribution's
directories for a packaged plug-in, the site directories for C<cpanm>, and
C<$PERL5LIB> for one installed with L<local::lib>.

One more, appended so that nothing in it can shadow a module of the
program's: F<$XDG_DATA_HOME/glitchvape/lib/perl5> -- by default
F<~/.local/share/glitchvape/lib/perl5>. It exists because C<$PERL5LIB> is set
by a login shell and not by a desktop session, so a plug-in installed with
C<cpanm -l ~/.local/share/glitchvape> would otherwise be there from a terminal
and missing from the menu.

=head1 WHAT A PLUG-IN MAY RELY ON

The registries above; the C<Context> an effect's C<apply> is handed -- its
C<image>, C<dims>, the three random streams C<rng_for>, C<rng_phase> and
C<rng_fixed>, C<frame>, C<frames>, C<phase>, the motions C<travel>,
C<excursion> and C<swell>, C<tmpdir>, C<cachedir>, C<magick> and C<pixels>;
and these modules: L<GlitchVape::Magick>, L<GlitchVape::Pixels>,
L<GlitchVape::Palette>, L<GlitchVape::Random>, L<GlitchVape::Tools>,
L<GlitchVape::Wav> for a kind of track to write what it made, and
L<GlitchVape::Fonts>'s C<resolve>.

Everything else is the program's own and may change without the API number
moving -- C<Chicago>, C<VGA>, C<Defrag> and C<Starfield> in particular, which
are the insides of particular effects.

=head1 TESTING ONE

L<GlitchVape::Test> holds the checks the program's own suite makes of every
effect it ships -- that a declaration is complete, that a drift closes its
loop, that every animation setting moves something -- so that a plug-in's
F<t/> can make them too:

    use Test::More;
    use GlitchVape       ();
    use GlitchVape::Test ();

    GlitchVape::Test::plugin_ok( 'Muffins' );
    done_testing;

Loaded through L<GlitchVape> rather than directly, so that it is found and
tried the way it will be when installed: C<prove -l> puts F<lib/> on C<@INC>,
which is all it takes.

=cut

=head1 FUNCTIONS

=head2 API / NAMESPACE / PROBE_SECONDS

The plug-in API this program speaks, the namespace plug-ins live in, and how
long the trial child is given before a plug-in is refused for hanging.

=cut

use constant API           => 1;
use constant NAMESPACE     => 'GlitchVape::Plugin';
use constant PROBE_SECONDS => 30;

# The places a plug-in can add to. Each answers contributions() and retract()
# for a plug-in's name, which is the whole of what this module needs to know
# about any of them.
my @PLACES = qw(
    GlitchVape::Registry
    GlitchVape::Generator
    GlitchVape::Tools
    GlitchVape::Palette
    GlitchVape::Fonts
    GlitchVape::Config
);

# The plug-in whose code is running, while it runs. A package variable only
# because `local` is what guarantees it is unset again however the loading
# ends, and `local` cannot be given a lexical.
our $LOADING;

# Module => the API it said it was written for.
my %DECLARED;

my @LOADED;
my @REFUSED;
my %FINGERPRINT;
my $STARTED;

=head2 import( api => $n )

What C<use GlitchVape::Plugins api =E<gt> 1> calls. Dies unless C<$n> is the
API this program speaks, so a plug-in written for another stops at its first
line with a sentence saying so.

=cut

sub import
{
    my ( $class, @arg ) = @_;
    return unless @arg;

    my $who = owner( scalar caller ) // scalar caller;

    die "GlitchVape::Plugins: '$who' should say 'use GlitchVape::Plugins "
        . 'api => '
        . API . "'\n"
        unless @arg == 2 && defined $arg[ 0 ] && $arg[ 0 ] eq 'api';

    my $want = $arg[ 1 ] // 'nothing';

    die "GlitchVape::Plugins: $who was written for plug-in API $want, and "
        . 'this GlitchVape speaks API '
        . API . "\n"
        unless $want =~ /\A[0-9]+\z/ && $want == API;

    $DECLARED{ $who } = $want;

    return;
}

=head2 owner( $package )

Which plug-in a registration made from C<$package> belongs to, or undef for
the program itself. Every registry stamps what it is given with this.

A package inside C<GlitchVape::Plugin::I<Name>> belongs to that plug-in,
whichever plug-in happened to be loading at the time -- so a plug-in that
loads another as a dependency does not end up owning the other's effects.
Anything else registered while a plug-in is loading is that plug-in's, which
covers helper modules it keeps outside its namespace.

=cut

sub owner
{
    my ( $package ) = @_;

    if ( defined $package
        && $package =~
        /\A(GlitchVape::Plugin::[A-Za-z_][A-Za-z0-9_]*)(?:::|\z)/ )
    {
        return $1;
    }

    return $LOADING;
}

=head2 load()

Load the program's own effects and generators, then every plug-in that
L</discover> finds and C<$GLITCHVAPE_PLUGINS> allows. Once per process; later
calls return at once. L<GlitchVape> calls it, so anything that loads the
program loads its plug-ins.

=cut

sub load
{
    return if $STARTED++;

    # The program's own first -- see HOW ONE IS LOADED. Each is required by
    # name rather than trusted to have been, because load() can be the first
    # thing a caller does.
    for my $module ( 'GlitchVape', @PLACES )
    {
        ( my $file = "$module.pm" ) =~ s{::}{/}g;
        require $file;
    }

    my $choice = selection( $ENV{ GLITCHVAPE_PLUGINS } );
    return if $choice->{ none };

    _widen_inc();

    for my $found ( discover() )
    {
        next unless chosen( $choice, $found->{ name } );
        _load_one( $found );
    }

    return;
}

=head2 discover()

Every plug-in on C<@INC>, as C<< { name, module, file, inc } >>, sorted by
name. Where two directories hold a plug-in of the same name, the one that
comes first on C<@INC> is the one listed, because it is the one C<require>
would load.

=cut

sub discover
{
    my %seen;
    my @found;

    for my $dir ( @INC )
    {
        # A hook rather than a directory, which has nothing to list.
        next if ref $dir || !defined $dir || !length $dir;

        my $space = File::Spec->catdir( $dir, split /::/, NAMESPACE );

        opendir my $dh, $space or next;
        my @entries = sort readdir $dh;
        closedir $dh;

        for my $entry ( @entries )
        {
            next unless $entry =~ /\A([A-Za-z_][A-Za-z0-9_]*)[.]pm\z/;
            my $name = $1;

            my $file = File::Spec->catfile( $space, $entry );
            next unless -f $file;
            next if $seen{ $name }++;

            push @found,
                {
                name   => $name,
                module => NAMESPACE . "::$name",
                file   => $file,
                inc    => join( '/', split( /::/, NAMESPACE ), $entry ),
                };
        }
    }

    my @sorted = sort { $a->{ name } cmp $b->{ name } } @found;
    return @sorted;
}

=head2 selection( $spec ) / chosen( $selection, $name )

C<$GLITCHVAPE_PLUGINS> taken apart, and whether one plug-in survives it. See
L</CHOOSING WHICH ARE LOADED>.

=cut

sub selection
{
    my ( $spec ) = @_;

    my %choice = ( only => {}, except => {} );
    return \%choice unless defined $spec && length $spec;

    for my $word ( grep { length } split /[\s:,]+/, $spec )
    {
        if ( lc $word eq 'none' )
        {
            $choice{ none } = 1;
            next;
        }

        my $list = $word =~ s/\A-// ? 'except' : 'only';
        $word =~ s/\A\Q${\ NAMESPACE}\E:://;

        $choice{ $list }{ $word } = 1;
    }

    return \%choice;
}

sub chosen
{
    my ( $choice, $name ) = @_;

    return 0 if $choice->{ none };
    return 0 if $choice->{ except }{ $name };
    return 1 unless %{ $choice->{ only } };
    return $choice->{ only }{ $name } ? 1 : 0;
}

=head2 lib_dir()

F<$XDG_DATA_HOME/glitchvape/lib/perl5>, whether or not it exists -- see
L</WHERE THEY ARE LOOKED FOR>.

=cut

sub lib_dir
{
    my $base = GlitchVape::Paths::data_home() or return undef;

    return File::Spec->catdir( $base, 'glitchvape', 'lib', 'perl5' );
}

=head2 loaded() / refused()

What happened, for C<--list-plugins> and the about window: the plug-ins that
loaded, as C<< { name, module, version, file, files, adds } >> where C<adds>
maps what kind of thing to the names added; and the ones that did not, as
C<< { name, module, file, reason } >>. Both sorted by name.

=cut

sub loaded
{
    my @copies = map { +{ %$_ } } @LOADED;
    return @copies;
}

sub refused
{
    my @copies = map { +{ %$_ } } @REFUSED;
    return @copies;
}

=head2 fingerprint( $module )

A string that changes whenever the code of a loaded plug-in does: its version,
and the size and modification time of every file its loading brought in.
Taken once, when it loads, because that is the code this process is running
whatever happens to the files afterwards.

The preview cache folds it into the key of anything a plug-in drew, which is
what stops an upgraded plug-in -- or one being worked on, where the version
never moves -- from being shown its own old pictures.

=cut

sub fingerprint
{
    my ( $module ) = @_;

    return undef unless defined $module;
    return $FINGERPRINT{ $module };
}

# ---------------------------------------------------------------------------

sub _load_one
{
    my ( $found ) = @_;

    # Already here: loaded by another plug-in that depends on it, or by hand
    # before the program got to it. Its code has run, so there is nothing
    # left to try -- only to take stock of.
    if ( exists $INC{ $found->{ inc } } )
    {
        return _refuse( $found, 'it failed to load earlier in this process' )
            unless defined $INC{ $found->{ inc } };

        my $why = _unannounced( $found );
        return _refuse( $found, $why ) if defined $why;

        return _accept( $found, {} );
    }

    my ( $probed, $why ) = _probe( $found );
    return _refuse( $found, $why ) if defined $why;

    my %before = %INC;

    # The child has already asked the questions that need a clean process.
    # Asked here instead they would be answered wrongly -- the window's own
    # threads are not the plug-in's -- so here they are asked only when there
    # was no child to ask them in.
    $why = _trial( $found, careful => !$probed );

    if ( defined $why )
    {
        _retract( $found->{ module } );
        return _refuse( $found, $why );
    }

    return _accept( $found, \%before );
}

# Try a plug-in in a child and report what the child saw. Returns whether
# there was a child at all, and the reason for refusing if there is one.
sub _probe
{
    my ( $found ) = @_;

    pipe my $hear, my $tell or return ( 0, undef );

    my $pid = fork;
    return ( 0, undef ) unless defined $pid;

    unless ( $pid )
    {
        close $hear;
        _as_trial_child( $found, $tell );
    }

    close $tell;

    my ( $said, $late ) = _listen( $hear, $pid );
    close $hear;

    return ( 1, $late ) if defined $late;

    return ( 1, undef ) if $said eq "ok\n";

    if ( $said =~ /\Arefused\n(.+)\z/s )
    {
        return ( 1, $1 );
    }

    # No answer at all: the child went away without writing one.
    my $signal = $? & 127;
    return ( 1, "it killed the process loading it (signal $signal)" )
        if $signal;

    return ( 1, 'it ended the process loading it before it had finished' );
}

# The child's side. Never returns: whatever happens, the child leaves through
# POSIX::_exit, which runs no END blocks and no destructors -- the parent's
# temporary directories and its window are the parent's to clean up.
sub _as_trial_child
{
    my ( $found, $tell ) = @_;

    my $answer = sub {
        my ( $text ) = @_;
        syswrite $tell, $text;
        close $tell;
        POSIX::_exit( 0 );
    };

    # Everything the plug-in says while loading is said again by the real
    # load in the parent. Saying it twice would be noise, and a plug-in that
    # reads standard input must not take the parent's.
    my $devnull = File::Spec->devnull;
    for my $std ( [ \*STDIN, '<' ], [ \*STDOUT, '>' ], [ \*STDERR, '>' ] )
    {
        open $std->[ 0 ], $std->[ 1 ], $devnull or next;
    }

    # Compiled after this point, a plug-in's `exit` comes here rather than
    # taking the child out through the parent's END blocks without an
    # answer.
    {
        # Replacing exit is the point, and it is named once because nothing
        # here calls it -- the plug-in about to be compiled does.
        no warnings qw(once redefine);    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        *CORE::GLOBAL::exit =
            sub { $answer->( "refused\nit calls exit while loading" ) };
    }

    my $why = _trial( $found, careful => 1 );

    $answer->( defined $why ? "refused\n$why" : "ok\n" );

    return;    # not reached
}

# Wait for the child's answer, for as long as PROBE_SECONDS allows.
sub _listen
{
    my ( $hear, $pid ) = @_;

    my $said  = q{};
    my $until = time + PROBE_SECONDS;

    while ( 1 )
    {
        my $remaining = $until - time;

        if ( $remaining <= 0 )
        {
            kill 'KILL', $pid;
            waitpid $pid, 0;

            return ( q{},
                'it took more than ' . PROBE_SECONDS . ' seconds to load' );
        }

        my $bits = q{};
        vec( $bits, fileno $hear, 1 ) = 1;

        my $ready = select $bits, undef, undef, $remaining;

        if ( $ready < 0 )
        {
            next if $!{ EINTR };
            last;
        }

        next unless $ready;

        my $got = sysread $hear, my $chunk, 4096;
        next if !defined $got && $!{ EINTR };
        last unless $got;

        $said .= $chunk;
    }

    waitpid $pid, 0;

    return ( $said, undef );
}

# Load one plug-in in this process and say what is wrong with it, or undef.
# `careful` adds the questions that need a clean process: threads, and Gtk.
sub _trial
{
    my ( $found, %arg ) = @_;

    my $threads = $arg{ careful } ? _threads() : undef;
    my %before  = %INC;

    my $ok;
    {
        # Dynamic scope is the point: whatever the plug-in registers while
        # this runs is stamped with its name, and nothing after it is.
        local $LOADING = $found->{ module };    ## no critic (Variables::ProhibitLocalVars)
        local $SIG{ __DIE__ };

        $ok = eval { require $found->{ inc }; 1 };
    }

    return _first_line( $@ ) unless $ok;

    my $why = _unannounced( $found );
    return $why if defined $why;

    if ( $arg{ careful } )
    {
        $why = _reaches_for_gtk( \%before );
        return $why if defined $why;

        my $now = _threads();
        if ( defined $threads && defined $now && $now > $threads )
        {
            my $more = $now - $threads;
            my $s    = $more == 1 ? q{} : 's';

            return
                  "it started $more thread$s while loading. ImageMagick does "
                . 'that on its first operation, and a process holding a '
                . 'thread pool is one every forked render deadlocks in -- '
                . 'image work belongs in apply, not at load time';
        }
    }

    return undef;
}

sub _unannounced
{
    my ( $found ) = @_;

    return undef if defined $DECLARED{ $found->{ module } };

    return
          "it does not say which plug-in API it was written for; the "
        . 'first thing it does should be: use GlitchVape::Plugins api => '
        . API;
}

# check-split, for what one plug-in brought in: any module it loaded that is
# Gtk3 or Glib, or whose source reaches for either. The source as well as the
# name, because in the window both are already loaded and a plug-in that uses
# them loads nothing new -- the check has to find the same answer there as on
# a machine with no display.
sub _reaches_for_gtk
{
    my ( $before ) = @_;

    for my $key ( sort keys %INC )
    {
        next if exists $before->{ $key };

        return "it loads $key, and nothing outside the window may -- a "
            . 'plug-in is declarations, and the window is made from them'
            if $key =~ m{\A(?:Gtk3|Glib)(?:[.]pm\z|/)};

        my $file = $INC{ $key };
        next if ref $file || !defined $file || !-f $file;

        open my $fh, '<', $file or next;

        while ( my $line = <$fh> )
        {
            last if $line =~ /\A__(?:END|DATA)__\b/;
            next unless $line =~ /\A *(?:use|require) +(?:Gtk3|Glib)\b/;

            close $fh;
            return
                  "$key reaches for Gtk3 or Glib, and nothing outside the "
                . 'window may -- a plug-in is declarations, and the window '
                . 'is made from them';
        }

        close $fh;
    }

    return undef;
}

# How many threads this process has, or undef where that cannot be asked.
sub _threads
{
    opendir my $dh, "/proc/$$/task" or return undef;
    my $count = grep { !/\A[.]/ } readdir $dh;
    closedir $dh;

    return $count;
}

sub _accept
{
    my ( $found, $before ) = @_;

    my $module = $found->{ module };

    my @files =
        map { $INC{ $_ } }
        grep {
              !exists $before->{ $_ }
            && defined $INC{ $_ }
            && !ref $INC{ $_ }
        } sort keys %INC;

    # Adopted rather than loaded, the diff is everything: take the one file
    # that is certainly the plug-in's instead.
    @files = ( $INC{ $found->{ inc } } ) unless %$before;

    my $version = eval { $module->VERSION };

    push @LOADED,
        {
        name    => $found->{ name },
        module  => $module,
        version => $version,
        file    => $INC{ $found->{ inc } } // $found->{ file },
        files   => \@files,
        adds    => _contributions( $module ),
        };

    $FINGERPRINT{ $module } = join "\0", $module, $version // q{},
        map { _stat_line( $_ ) } @files;

    return;
}

# One file, as its path, size and modification time.
sub _stat_line
{
    my ( $path ) = @_;

    my @stat = stat $path;
    return join ':', $path, $stat[ 7 ] // q{}, $stat[ 9 ] // q{};
}

sub _refuse
{
    my ( $found, $why ) = @_;

    push @REFUSED,
        {
        name   => $found->{ name },
        module => $found->{ module },
        file   => $found->{ file },
        reason => $why,
        };

    warn "GlitchVape: plug-in $found->{name} ($found->{file}) was not "
        . "loaded: $why\n";

    return;
}

sub _retract
{
    my ( $module ) = @_;

    for my $place ( @PLACES )
    {
        $place->retract( $module ) if $place->can( 'retract' );
    }

    return;
}

sub _contributions
{
    my ( $module ) = @_;

    my %adds;

    for my $place ( @PLACES )
    {
        next unless $place->can( 'contributions' );

        my $from = $place->contributions( $module );

        for my $what ( keys %$from )
        {
            $adds{ $what } = $from->{ $what } if @{ $from->{ $what } };
        }
    }

    return \%adds;
}

sub _first_line
{
    my ( $error ) = @_;

    $error = 'it failed to load, and said nothing about why'
        unless defined $error && length $error;

    my ( $line ) = split /\n/, $error;
    $line =~ s/\s+\z//;

    return $line;
}

# The drop-in directory, if there is one. Appended, not prepended, so that a
# module in it can add to the program but never replace a part of it.
sub _widen_inc
{
    my $lib = lib_dir() or return;
    return unless -d $lib;

    my %have = map { $_ => 1 } grep { !ref } @INC;

    for my $dir ( File::Spec->catdir( $lib, $Config{ archname } ), $lib )
    {
        next unless -d $dir;
        next if $have{ $dir }++;

        push @INC, $dir;
    }

    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Registry>, whose declarations are what a plug-in mostly makes;
L<GlitchVape::Test>, for the checks every effect owes; and C<glitchvape
--list-plugins>, for what this found and what it made of each.

=cut
