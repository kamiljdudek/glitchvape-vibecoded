#!/usr/bin/perl

use strict;
use warnings;

# Before anything loads the program: the pure parts below are asked in this
# process, and a plug-in that happens to be installed on the machine running
# the suite has no business answering them. The end-to-end parts run the real
# command in children, each told exactly which plug-ins to load.
BEGIN
{
    # For the whole file, which local in a BEGIN block would not be.
    $ENV{ GLITCHVAPE_PLUGINS } = 'none';    ## no critic (Variables::RequireLocalizedPunctuationVars)
}

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Path ();
use File::Spec ();
use File::Temp ();
use Test::More;

use GlitchVape            ();
use GlitchVape::Config    ();
use GlitchVape::Fonts     ();
use GlitchVape::Generator ();
use GlitchVape::Palette   ();
use GlitchVape::Plugins   ();
use GlitchVape::Registry  ();
use GlitchVape::Tools     ();

# Plug-ins are declarations from modules the program did not ship. What is
# pinned here is the loader's side of that bargain: it finds them where Perl
# keeps modules, tries each in a throwaway child before letting it into the
# process, refuses one that breaks a rule -- taking back whatever it had
# registered -- and lets everything else carry on. The fixtures in t/lib each
# break one rule, apart from Sprinkles, which breaks none and uses every place
# a plug-in can add to.

my $LIB      = File::Spec->rel2abs( "$FindBin::Bin/../lib" );
my $FIXTURES = File::Spec->rel2abs( "$FindBin::Bin/lib" );
my $CLI      = File::Spec->rel2abs( "$FindBin::Bin/../bin/glitchvape" );

my $TMP = File::Temp->newdir( 'gv_plugins_XXXXXX', TMPDIR => 1 );

# Run perl with the program and the fixtures on @INC. Standard error comes
# back with standard output, through a pipe -- which is what Twofaced needs to
# see to misbehave, and where the loader's warnings go.
sub run
{
    my ( $env, @argv ) = @_;
    return run_with( $env, [ $LIB, $FIXTURES ], @argv );
}

# The same, with @INC given: the program's lib first, then whatever else.
sub run_with
{
    my ( $env, $inc, @argv ) = @_;

    my $pid = open my $fh, '-|';
    die "fork: $!" unless defined $pid;

    unless ( $pid )
    {
        open STDERR, '>&', \*STDOUT or exit 127;
        chdir "$TMP" or exit 127;

        # Nothing the machine's own drop-in directory holds, unless a test
        # says otherwise.
        local $ENV{ XDG_DATA_HOME } = "$TMP/no-such-home";
        delete local $ENV{ GLITCHVAPE_PLUGINS };
        local @ENV{ keys %$env } = values %$env;

        exec { $^X } $^X, ( map { "-I$_" } @$inc ), @argv or exit 127;
    }

    my $out = do { local $/ = undef; <$fh> };
    close $fh;

    return ( $? >> 8, $out // q{} );
}

sub cli
{
    my ( $plugins, @args ) = @_;
    return run( { GLITCHVAPE_PLUGINS => $plugins }, $CLI, @args );
}

# By hand rather than with File::Copy, which Fedora packages separately and
# which nothing else in the suite needs.
sub copy_file
{
    my ( $from, $to ) = @_;

    open my $in,  '<:raw', $from or die "read $from: $!";
    open my $out, '>:raw', $to   or die "write $to: $!";
    print { $out } do { local $/ = undef; <$in> };
    close $out or die "write $to: $!";
    close $in;

    return;
}

# ---------------------------------------------------------------------------
# Finding them

# Every GlitchVape/Plugin/*.pm on @INC, one level deep, in order of name --
# and where two directories hold the same name, the one require would load,
# which is the one earlier on @INC. A plug-in's sub-modules and data sit in a
# directory beside it and are its own business, not plug-ins of their own.
{
    # Only the fixtures, so that a plug-in installed on the machine running
    # the suite is not part of the answer.
    local @INC = ( $FIXTURES );

    my @names = map { $_->{ name } } GlitchVape::Plugins::discover();

    is_deeply \@names, [
        qw(Broken Future Quitter Sprinkles Thief Threadbare Twofaced
            Unannounced Unlicensed Windowed)
        ],
        'every fixture is found, sorted by name, and nothing beside them';

    my $shadow = File::Spec->catdir( "$TMP", 'shadow', 'GlitchVape', 'Plugin' );
    File::Path::make_path( $shadow );
    copy_file( "$FIXTURES/GlitchVape/Plugin/Sprinkles.pm",
        "$shadow/Sprinkles.pm" );

    local @INC = ( $FIXTURES, "$TMP/shadow" );

    my @found =
        grep { $_->{ name } eq 'Sprinkles' } GlitchVape::Plugins::discover();

    is scalar @found, 1, "a plug-in found twice on \@INC is listed once";
    like $found[ 0 ]{ file }, qr/\A\Q$FIXTURES\E/,
        "and it is the copy require would load, the first on \@INC";
    is $found[ 0 ]{ inc }, 'GlitchVape/Plugin/Sprinkles.pm',
        "required by its path under \@INC, as a use would be";
}

# ---------------------------------------------------------------------------
# Choosing them

# none, an allow-list, and an exclusion, which is everything the variable has
# to say. A name may carry the namespace or not.
{
    my $pick = sub {
        my ( $spec, $name ) = @_;
        return GlitchVape::Plugins::chosen(
            GlitchVape::Plugins::selection( $spec ), $name );
    };

    ok $pick->( undef,   'Sprinkles' ), 'unset, every plug-in is loaded';
    ok $pick->( q{},     'Sprinkles' ), 'and empty says the same';
    ok !$pick->( 'none', 'Sprinkles' ), 'none loads none';

    ok $pick->( 'Sprinkles:Thief',  'Thief' ),  'a list loads what it names';
    ok !$pick->( 'Sprinkles:Thief', 'Broken' ), 'and nothing it does not';

    ok !$pick->( '-Broken', 'Broken' ),    'a leading minus leaves one out';
    ok $pick->( '-Broken',  'Sprinkles' ), 'and leaves the rest in';

    ok $pick->( 'GlitchVape::Plugin::Thief', 'Thief' ),
        'a name may be given whole';
}

# ---------------------------------------------------------------------------
# Whose a registration is

# A package inside a plug-in's namespace is that plug-in's, whoever was
# loading at the time -- so a plug-in that loads another as a dependency does
# not end up owning the other's effects. Anything else is whoever is loading,
# which covers helpers a plug-in keeps elsewhere; and outside a load, the
# program's own.
{
    is GlitchVape::Plugins::owner( 'GlitchVape::Plugin::Muffins' ),
        'GlitchVape::Plugin::Muffins', 'a plug-in owns its own package';
    is GlitchVape::Plugins::owner( 'GlitchVape::Plugin::Muffins::Frosting' ),
        'GlitchVape::Plugin::Muffins', 'and everything under it';
    is GlitchVape::Plugins::owner( 'GlitchVape::Effect::Color' ), undef,
        'the program owns its own effects';

    local $GlitchVape::Plugins::LOADING = 'GlitchVape::Plugin::Muffins';

    is GlitchVape::Plugins::owner( 'Muffins::Helpers' ),
        'GlitchVape::Plugin::Muffins',
        'a helper outside the namespace belongs to whoever is loading';
    is GlitchVape::Plugins::owner( 'GlitchVape::Plugin::Scones' ),
        'GlitchVape::Plugin::Scones',
        'but a second plug-in loaded along the way keeps its own';
}

# ---------------------------------------------------------------------------
# Taking back what a plug-in added

# Every place a plug-in can add to answers two questions for it: what did it
# add, and take it back. Asked here of each in turn, because a place that
# answered the first and not the second would leave a refused plug-in's
# effects in every listing.
{
    my $plugin = 'GlitchVape::Plugin::Retracted';

    {
        local $GlitchVape::Plugins::LOADING = $plugin;

        GlitchVape::Registry->register(
            name    => 'retracted',
            stage   => 'colour',
            summary => 'Here for a moment',
            apply   => sub { return },
        );
        GlitchVape::Registry->register_source(
            name   => 'retracted',
            values => [ qw(a b) ]
        );
        GlitchVape::Generator->register(
            kind     => 'retracted',
            label    => 'Retracted',
            params   => {},
            duration => sub { 1 },
            render   => sub { return },
        );
        GlitchVape::Tools->register( name => 'retracted', bins => [ 'perl' ] );
        GlitchVape::Palette->register(
            name   => 'retracted',
            colors => [ '#000', '#fff' ]
        );
        GlitchVape::Palette->register_duotone(
            name   => 'retracted',
            colors => [ '#000', '#fff' ]
        );
        GlitchVape::Fonts->register_role(
            name  => 'retracted',
            fonts => [ 'DejaVu Sans' ]
        );
        GlitchVape::Fonts->add_dir( "$TMP" );
        GlitchVape::Config->add_preset_dir( "$TMP" );
    }

    my %added;
    for my $place (
        qw(GlitchVape::Registry GlitchVape::Generator GlitchVape::Tools
        GlitchVape::Palette GlitchVape::Fonts GlitchVape::Config)
        )
    {
        my $from = $place->contributions( $plugin );
        $added{ $_ } = $from->{ $_ } for keys %$from;
    }

    is_deeply \%added,
        {
        effects              => [ 'retracted' ],
        'suggestion lists'   => [ 'retracted' ],
        'soundtrack kinds'   => [ 'retracted' ],
        tools                => [ 'retracted' ],
        palettes             => [ 'retracted' ],
        'duotone ramps'      => [ 'retracted' ],
        'font roles'         => [ 'retracted' ],
        'font directories'   => [ "$TMP" ],
        'preset directories' => [ "$TMP" ],
        },
        'every place says what a plug-in added to it';

    $_->retract( $plugin )
        for qw(GlitchVape::Registry GlitchVape::Generator GlitchVape::Tools
        GlitchVape::Palette GlitchVape::Fonts GlitchVape::Config);

    ok !GlitchVape::Registry->get( 'retracted' ), 'the effect is taken back';
    ok !grep( { $_ eq 'retracted' } GlitchVape::Registry::sources() ),
        'and the suggestion list';
    ok !GlitchVape::Generator::get( 'retracted' ), 'and the kind of track';
    ok !GlitchVape::Tools::known( 'retracted' ),   'and the tool';
    ok !GlitchVape::Palette::known( 'retracted' ), 'and the palette';
    ok !grep( { $_ eq 'retracted' } GlitchVape::Palette::duotone_names() ),
        'and the duotone ramp';
    ok !grep( { $_ eq 'retracted' } GlitchVape::Fonts::roles() ),
        'and the font role';
    ok !grep( { $_ eq "$TMP" } GlitchVape::Fonts::search_dirs() ),
        'and the font directory';
    ok !grep( { $_ eq "$TMP" } GlitchVape::Config::preset_dirs() ),
        'and the preset directory';
}

# ---------------------------------------------------------------------------
# A plug-in that breaks no rule

# Everything it added is listed, and each is used exactly as the program's own
# is: named in the listings, explained, offered.
{
    my ( $status, $out ) = cli( 'Sprinkles', '--list-plugins' );

    is $status, 0, 'a plug-in that loads leaves --list-plugins content';
    like $out, qr/^Sprinkles 1[.]00$/m, 'which names it and its version';

    for my $line (
        [ 'effects',            'sprinkles' ],
        [ 'suggestion lists',   'toppings' ],
        [ 'soundtrack kinds',   'hum' ],
        [ 'tools',              'sprinkler' ],
        [ 'palettes',           'sprinkles' ],
        [ 'duotone ramps',      'sprinkles' ],
        [ 'font roles',         'sprinkle_face' ],
        [ 'font directories',   'Sprinkles/fonts' ],
        [ 'preset directories', 'Sprinkles/presets' ],
        )
    {
        my ( $what, $name ) = @$line;
        like $out, qr/^\s+\Q$what\E\s+.*\Q$name\E/m, "and the $what it adds";
    }

    ( undef, $out ) = cli( 'Sprinkles', '--list-effects' );
    like $out, qr/^\s+sprinkles\s+Coloured specks.*\(from Sprinkles\)$/m,
        'its effect is listed with the program\'s, saying where it came from';
    unlike $out, qr/^\s+grain\b.*\(from/m,
        'and the program\'s own say nothing of the kind';

    ( undef, $out ) = cli( 'Sprinkles', '--explain', 'sprinkles' );
    like $out, qr/^From plug-in GlitchVape::Plugin::Sprinkles 1[.]00$/m,
        '--explain says which plug-in an effect is from';
    like $out, qr/^\s+topping\s/m, 'and explains its parameters';

    ( undef, $out ) = cli( 'Sprinkles', '--list-generators' );
    my @kinds = $out =~ /^(\w+)  --  /mg;
    is_deeply \@kinds, [ qw(dtmf static geiger heart drive hum) ],
        'a plug-in\'s kind of track comes after the program\'s own';

    ( undef, $out ) = cli( 'Sprinkles', '--list-palettes' );
    like $out, qr/^\s+sprinkles\s+#2B1B3D/m, 'its palette is a palette';

    ( undef, $out ) = cli( 'Sprinkles', '--list-presets' );
    like $out, qr/^\s+sprinkled\s/m, 'its presets are presets';

    ( undef, $out ) = cli( 'Sprinkles', '--licenses' );
    like $out, qr{Sprinkles/fonts/SprinkleSans/LICENSE},
        'and the licence beside its font is quoted with the rest';
}

# ---------------------------------------------------------------------------
# One rule broken each

# A refused plug-in is named, with its reason, in a warning and in
# --list-plugins, which then exits 1 -- and nothing it registered is left
# behind.
my %REFUSAL = (
    Broken   => qr/the oven is on fire/,
    Future   => qr/written for plug-in API 2, and this GlitchVape speaks API 1/,
    Quitter  => qr/calls exit while loading/,
    Thief    => qr/effect 'grain' registered twice -- the program itself/,
    Twofaced => qr/behaves differently when it is watched/,
    Unannounced => qr/does not say which plug-in API it was written for/,
    Unlicensed  => qr/Bare[.]ttf has no licence file beside it or above it/,
    Windowed    => qr/reaches for Gtk3 or Glib/,
);

for my $name ( sort keys %REFUSAL )
{
    my ( $status, $out ) = cli( $name, '--list-plugins' );

    is $status, 1, "$name is refused, and --list-plugins says so by its status";
    like $out, qr/^\Q$name\E -- not loaded$/m, 'and by name';
    like $out, $REFUSAL{ $name },              'and why';
    like $out, qr/^GlitchVape: plug-in \Q$name\E .* was not loaded: /m,
        'with a warning that names it';
}

# What the refused ones had registered before failing: Broken failed in the
# trial child, so this process never ran it; Twofaced passed the trial and
# failed here, after registering, which is the retraction that matters.
{
    my ( undef, $out ) = cli( 'Broken:Twofaced', '--list-effects' );
    unlike $out, qr/^\s+burnt\s/m,
        'an effect a refused plug-in registered is not offered';
    unlike $out, qr/^\s+twofaced\s/m,
        'nor one registered in this process before the plug-in failed';

    ( undef, $out ) = cli( 'Twofaced', '--list-palettes' );
    unlike $out, qr/^\s+twofaced\s/m, 'and nor is its palette';

    ( undef, $out ) = cli( 'Thief', '--explain', 'grain' );
    unlike $out, qr/^From plug-in/m, 'grain is still the program\'s own';
}

# One refusal stops nothing but itself.
{
    my ( $status, $out ) = cli( 'Sprinkles:Broken:Thief', '--list-plugins' );

    like $out, qr/^Sprinkles 1[.]00$/m, 'a good plug-in loads beside bad ones';
    is scalar( () = $out =~ /-- not loaded$/mg ), 2,
        'and the bad ones are refused';
    is $status, 1, 'which the status still reports';

    ( $status, $out ) = cli( 'Sprinkles:Broken:-Broken', '--list-plugins' );
    unlike $out, qr/Broken/, 'a name can be left out of a list that named it';
}

# ---------------------------------------------------------------------------
# The one thing a trial child is for

# ImageMagick starts OpenMP's thread pool on its first operation, and a
# process that holds one deadlocks in every render it forks. Refusing the
# plug-in after the fact would find the pool and could not remove it; tried in
# a child first, the pool dies with the child and this process never starts
# one.
SKIP:
{
    skip 'Image::Magick is not installed', 3
        unless eval { require Image::Magick; 1 };

    my $version =
        GlitchVape::Tools::capture( GlitchVape::Tools::find( 'magick' )
            // 'magick', '-version' ) // q{};
    skip 'this ImageMagick is not built with OpenMP', 3
        unless $version =~ /OpenMP/;

    my ( $status, $out ) = cli( 'Threadbare', '--list-plugins' );

    is $status, 1, 'a plug-in that does image work while loading is refused';
    like $out, qr/started \d+ threads? while loading/,
        'for starting threads, which is what the image work did';

    my $probe = <<'PROBE';
use GlitchVape ();
opendir my $dh, "/proc/$$/task" or die "no /proc: $!";
my $threads = grep { !/^\./ } readdir $dh;
print "threads=$threads\n";
PROBE

    ( undef, $out ) =
        run( { GLITCHVAPE_PLUGINS => 'Threadbare' }, '-e', $probe );
    like $out, qr/^threads=1$/m,
        'and the process that refused it is still running on one thread';
}

# ---------------------------------------------------------------------------
# Rendering with one

SKIP:
{
    skip 'ImageMagick is not installed', 2
        unless GlitchVape::Tools::have( 'magick' )
        && eval { require Image::Magick; 1 };

    my $src = "$TMP/src.png";
    my $img = Image::Magick->new( size => '160x120' );
    $img->Read( 'gradient:#202060-#E0C080' );
    $img->Write( $src );

    my $dst = "$TMP/sprinkled.png";
    my ( $status, $out ) =
        cli( 'Sprinkles', '-p', 'sprinkled', '-s', 7, '-o', $dst, $src );

    is $status, 0, 'a preset a plug-in ships renders' or diag $out;
    ok -s $dst, 'and writes the picture';
}

# The checks every effect owes, asked of a plug-in by its own tests the way
# the program's suite asks them of its own.
SKIP:
{
    skip 'ImageMagick is not installed', 1
        unless GlitchVape::Tools::have( 'magick' )
        && eval { require Image::Magick; 1 };

    my $test = <<'TEST';
use Test::More;
use GlitchVape::Test ();
GlitchVape::Test::plugin_ok( 'Sprinkles' );
done_testing;
TEST

    my ( $status, $out ) =
        run( { GLITCHVAPE_PLUGINS => 'Sprinkles' }, '-e', $test );

    is $status, 0,
        'GlitchVape::Test::plugin_ok passes a plug-in that breaks no rule'
        or diag $out;
}

# ---------------------------------------------------------------------------
# The drop-in directory

# $XDG_DATA_HOME/glitchvape/lib/perl5, for a plug-in installed where a desktop
# session will see it -- appended to @INC, so that it can add to the program
# and never replace a part of it.
{
    my $home = "$TMP/xdg";
    my $lib  = "$home/glitchvape/lib/perl5";

    File::Path::make_path( "$lib/GlitchVape/Plugin" );

    open my $fh, '>', "$lib/GlitchVape/Plugin/Dropped.pm" or die $!;
    print { $fh } <<'PLUGIN';
package GlitchVape::Plugin::Dropped;
use strict;
use warnings;
use GlitchVape::Plugins api => 1;
our $VERSION = '0.2';
1;
PLUGIN
    close $fh;

    # A module of the program's own, dropped in beside it. Appended, so the
    # real one is found first and this one is never read.
    File::Path::make_path( "$lib/GlitchVape" );
    open $fh, '>', "$lib/GlitchVape/Registry.pm" or die $!;
    print { $fh }
        "die 'the drop-in directory replaced a module of the program';\n";
    close $fh;

    my ( $status, $out ) =
        run( { GLITCHVAPE_PLUGINS => 'Dropped', XDG_DATA_HOME => $home },
        $CLI, '--list-plugins' );

    is $status, 0, 'a plug-in in the drop-in directory loads' or diag $out;
    like $out, qr/^Dropped 0[.]2$/m, 'and is listed';
    unlike $out, qr/replaced a module of the program/,
        'and nothing there can take the place of a module the program has';
}

# ---------------------------------------------------------------------------
# A range with one end

# A plug-in may declare a count with a floor and no ceiling -- the window
# gives it a spin button -- and --explain used to print "0.." followed by a
# warning about an undefined value, because every effect that shipped had
# both ends.
{
    my $lib = "$TMP/halfway";
    File::Path::make_path( "$lib/GlitchVape/Plugin" );

    open my $fh, '>', "$lib/GlitchVape/Plugin/Halfway.pm" or die $!;
    print { $fh } <<'PLUGIN';
package GlitchVape::Plugin::Halfway;
use strict;
use warnings;
use GlitchVape::Plugins api => 1;
use GlitchVape::Registry ();
our $VERSION = '0.1';
GlitchVape::Registry->register(
    name    => 'halfway',
    stage   => 'colour',
    summary => 'A parameter with a floor and no ceiling',
    params  => {
        count => { default => 3, type => 'int', min => 0, doc => 'How many' },
        depth => { default => 1, type => 'num', max => 9, doc => 'How deep' },
    },
    apply => sub { return },
);
1;
PLUGIN
    close $fh;

    my ( $status, $out ) = run_with(
        { GLITCHVAPE_PLUGINS => 'Halfway' },
        [ $LIB, $lib ],
        $CLI, '--explain', 'halfway'
    );

    is $status, 0, '--explain explains a parameter with one end to its range';
    like $out,   qr/^\s+count\s+>= 0\s/m, 'writing a floor as a floor';
    like $out,   qr/^\s+depth\s+<= 9\s/m, 'and a ceiling as a ceiling';
    unlike $out, qr/uninitialized/, 'without a warning about the missing end';
}

# ---------------------------------------------------------------------------
# The preview cache knows whose code drew a picture

# An upgraded plug-in -- or one being worked on, where the version never
# moves -- draws differently from the same settings, and a cache keyed on the
# settings alone would show it its own old pictures. The plug-in's files are
# part of the key of anything it drew, and of nothing else.
{
    my $copy = "$TMP/copy";
    File::Path::make_path( "$copy/GlitchVape/Plugin" );
    copy_file(
        "$FIXTURES/GlitchVape/Plugin/Sprinkles.pm",
        "$copy/GlitchVape/Plugin/Sprinkles.pm"
    );

    # The copy's data lives beside the original; point at it.
    symlink "$FIXTURES/GlitchVape/Plugin/Sprinkles",
        "$copy/GlitchVape/Plugin/Sprinkles"
        or die "symlink: $!";

    my $keys = <<'KEYS';
use GlitchVape             ();
use GlitchVape::GUI::State ();
for my $name ( 'sprinkles', 'grain' )
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );
    $state->add_effect( $name );
    print "$name=", $state->cache_key( size => 720 ), "\n";
}
KEYS

    my $keys_now = sub {
        my ( undef, $out ) = run_with(
            { GLITCHVAPE_PLUGINS => 'Sprinkles' },
            [ $LIB, $copy ],
            '-e', $keys
        );
        return { $out =~ /^(\w+)=(\w+)$/mg };
    };

    my $first = $keys_now->();
    ok $first->{ sprinkles }, 'a plug-in effect has a preview key';

    is_deeply $keys_now->(), $first,
        'which the same plug-in gives again in another process';

    my $file = "$copy/GlitchVape/Plugin/Sprinkles.pm";
    my $then = ( stat $file )[ 9 ];
    utime $then + 60, $then + 60, $file or die "utime: $!";

    my $after = $keys_now->();

    isnt $after->{ sprinkles }, $first->{ sprinkles },
        'and a changed plug-in does not, even at the same version';
    is $after->{ grain }, $first->{ grain },
        'while a picture it had no part in keeps its key';
}

done_testing;
