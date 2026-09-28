package GlitchVape::Test;

use strict;
use warnings;

use File::Temp    ();
use Test::Builder ();

use GlitchVape            ();
use GlitchVape::Context   ();
use GlitchVape::Generator ();
use GlitchVape::Pipeline  ();
use GlitchVape::Plugins   ();
use GlitchVape::Registry  ();
use GlitchVape::Tools     ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Test - the checks every effect owes, whoever wrote it

=head1 SYNOPSIS

In a plug-in's F<t/>:

    use Test::More;
    use GlitchVape::Test ();

    GlitchVape::Test::plugin_ok( 'Muffins' );

    done_testing;

=head1 DESCRIPTION

The program's own suite asks a handful of questions of every effect it ships,
driven off the registry so that an effect is covered the day it is declared:
whether its declaration is complete, whether a C<drift> closes its loop and
leaves a still alone, whether C<reroll> does both of the things it claims, and
whether every animation setting moves anything at all. Each of those was
written after something had quietly stopped working, and none of them is
specific to the effects that happen to ship.

So they live here, installed, and the suite calls them from here -- which is
what lets a plug-in's own tests ask the same questions with one line, and
what keeps the two from becoming two slightly different sets of questions.

Loading this module loads L<GlitchVape>, and so the plug-ins: a plug-in is
tested as it will be used, found on C<@INC> and tried like any other. Run with
C<prove -l> and its F<lib/> is on C<@INC>, which is all that takes.

=head1 THE BENCHES

Each check renders on a picture chosen for what it has to show, and the
choices are the ones the checks were written with:

    drift    a gradient with a rectangle on it, 240x180 -- edges, because
             what a drift moves is edges, and a flat wash hides it
    reroll   plasma, 240x180 -- structure in both axes, because several
             damage effects move pixels along a row, and a row of a
             vertical gradient is a row of identical pixels
    motion   plasma, 192x144 -- busy, because a smooth ramp hides damage
             that a detailed picture shows; small, because the sweep
             renders a few hundred frames

The plasma is ImageMagick's, and ImageMagick seeds it from the clock -- so a
setting whose effect is faint can, on an unlucky plasma, round away. A single
failure naming one such setting is worth running again before believing.

=cut

my $TB = Test::Builder->new;

# The values a drift is asked about. Deliberately unhelpful: none of these is
# a whole number of any period an effect uses, which is the case that used to
# jolt at the seam.
my @AWKWARD = ( 1, 3, 7, 10, 0.5 );

my %BENCH = (
    drift => {
        picture => 'shapes',
        size    => '240x180',
        seed    => 99,
        frames  => 12,
        source  => 1,
    },
    reroll => {
        picture => 'plasma',
        size    => '240x180',
        seed    => 11,
        frames  => 5,
        source  => 1,
    },
    motion => {
        picture => 'plasma',
        size    => '192x144',
        seed    => 3,
        frames  => 12,
        cache   => 1,
    },
);

# Made once per process, removed when it ends.
my $DIR;
my $CACHE;
my %PICTURE;

=head1 FUNCTIONS

=head2 can_render()

Whether ImageMagick is here, as a program and as the Perl binding. Every check
that renders needs both; the declaration checks need neither.

=cut

sub can_render
{
    return 0 unless GlitchVape::Tools::have( 'magick' );
    return 0 unless eval { require Image::Magick; 1 };

    return 1;
}

=head2 frame( $bench, $effect, \%params, $frame, $frames )

One frame of one effect on one of L</THE BENCHES>, as ImageMagick's signature
of its pixels -- not as a written file, since a PNG carries a creation time
and two encodings of one identical picture differ as bytes while being the
same image. C<$frames> defaults to the bench's own; give 1 for a still.

=cut

sub frame
{
    my ( $bench, $effect, $params, $frame, $frames ) = @_;

    my $on = $BENCH{ $bench }
        or die "GlitchVape::Test: there is no bench called '$bench'\n";

    my $src = _picture( $on );

    require Image::Magick;
    my $img = Image::Magick->new;
    $img->Read( $src );

    my $ctx = GlitchVape::Context->new(
        image => $img,
        seed  => $on->{ seed },
        ( $on->{ source } ? ( source   => $src )        : () ),
        ( $on->{ cache }  ? ( cachedir => _cachedir() ) : () ),
    );
    $ctx->frames( $frames // $on->{ frames } );
    $ctx->frame( $frame   // 0 );

    GlitchVape::Pipeline->new(
        effects => { $effect => { %{ $params || {} } } } )->run( $ctx );

    return $ctx->image->Get( 'signature' );
}

=head2 distinct( $bench, $effect, \%params )

How many different pictures a loop of the bench's length draws.

=cut

sub distinct
{
    my ( $bench, $effect, $params ) = @_;

    my $frames = $BENCH{ $bench }{ frames };

    my %seen;
    $seen{ frame( $bench, $effect, $params, $_, $frames ) } = 1
        for 0 .. $frames - 1;

    return scalar keys %seen;
}

=head2 declared_ok( $effect )

That the declaration says everything the rest of the program reads from it: a
summary and a title, a stage that exists, and for every parameter a default
and a line of documentation -- which C<--explain> prints and the window shows
as a tooltip -- an enum's values with its default among them, and a default
inside its own range.

=cut

sub declared_ok
{
    my ( $name ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $spec = GlitchVape::Registry->get( $name );
    return $TB->ok( 0, "$name is a registered effect" ) unless $spec;

    $TB->ok( length $spec->{ summary }, "$name has a summary" );
    $TB->ok( length $spec->{ title },   "$name has a title" );
    $TB->ok( GlitchVape::Registry->stage_info( $spec->{ stage } ),
        "$name sits in a declared stage" );

    for my $p ( sort keys %{ $spec->{ params } } )
    {
        my $d = $spec->{ params }{ $p };

        $TB->ok( exists $d->{ default },      "$name.$p has a default" );
        $TB->ok( length( $d->{ doc } // '' ), "$name.$p is documented" );

        if ( $d->{ type } eq 'enum' )
        {
            $TB->ok(
                scalar @{ $d->{ values } || [] },
                "$name.$p lists its enum values"
            );
            $TB->ok(
                scalar( grep { $_ eq $d->{ default } } @{ $d->{ values } } ),
                "$name.$p default is one of its own enum values"
            );
        }

        if ( defined $d->{ min } && defined $d->{ max } )
        {
            $TB->cmp_ok(
                $d->{ default },
                '>=',
                $d->{ min },
                "$name.$p default is not below its minimum"
            );
            $TB->cmp_ok(
                $d->{ default },
                '<=',
                $d->{ max },
                "$name.$p default is not above its maximum"
            );
        }
    }

    return;
}

=head2 drift_ok( $effect )

For an effect that declares a C<drift>: that the frame after the last is the
first again, at every value in a set chosen to be awkward -- a drift that does
not come back puts a jolt in at the join, once per repeat, for as long as the
file plays -- and that a still ignores the setting, since presets carry it and
a still must render as it did before the parameter existed. Asks nothing of an
effect without one.

=cut

sub drift_ok
{
    my ( $effect ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $spec = _param( $effect, 'drift' ) or return;

    my $frames = $BENCH{ drift }{ frames };

    for my $drift ( @AWKWARD )
    {
        next if defined $spec->{ max } && $drift > $spec->{ max };

        my $first = frame( 'drift', $effect, { drift => $drift }, 0, $frames );
        my $wrap =
            frame( 'drift', $effect, { drift => $drift }, $frames, $frames );

        $TB->ok( $first eq $wrap,
            "$effect at drift $drift comes back to the first frame" );
    }

    # The largest this effect will take, so the check is asking the parameter
    # for everything it has rather than for a number that happens to be small.
    my $most = $spec->{ max };
    $most = 10 if !defined $most || $most > 10;

    my $off = frame( 'drift', $effect, { drift => 0 },     0, 1 );
    my $on  = frame( 'drift', $effect, { drift => $most }, 0, 1 );

    $TB->ok( $off eq $on,
        "$effect ignores drift when there is only one frame" );

    return;
}

=head2 reroll_ok( $effect, %nudge )

For an effect that declares a C<reroll>: that off really does hold the picture
still across a loop, that on really does not, that the declaration says which
of the two it arrives as, and that a still is the same either way. C<%nudge> is
whatever the effect needs set before the question means anything -- an effect
that consults no randomness at its defaults would pass the first half by
never having varied. Asks nothing of an effect without one.

=cut

sub reroll_ok
{
    my ( $effect, %nudge ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $spec = _param( $effect, 'reroll' ) or return;

    $TB->is_eq( distinct( 'reroll', $effect, { %nudge, reroll => 0 } ),
        1, "$effect with reroll off draws one picture for the whole loop" );

    $TB->cmp_ok( distinct( 'reroll', $effect, { %nudge, reroll => 1 } ),
        '>', 1,
        "$effect with reroll on draws a different picture on every frame" );

    $TB->ok( defined $spec->{ default },
        "$effect declares which of the two it is" );

    my $on  = frame( 'reroll', $effect, { %nudge, reroll => 1 }, 0, 1 );
    my $off = frame( 'reroll', $effect, { %nudge, reroll => 0 }, 0, 1 );

    $TB->is_eq( $on, $off, "$effect renders one still, whatever reroll says" );

    return;
}

=head2 animation_settings( $effect, except => \%excused )

The parameters of C<$effect> that declare C<animation>, less any named in
C<%excused> as C<'effect.param'>.

=head2 moves( $effect, $param )

Whether any frame of a loop differs from the first, with C<$param> turned up
as far as it goes and everything it C<needs> switched on beside it --
otherwise the question would only prove that a greyed control is greyed.

=head2 animation_ok( $effect, except => \%excused )

That every animation setting of C<$effect> L</moves>. The claim is weak on
purpose -- what each setting does is its own business -- because what it
catches is a setting that does nothing at all, and a slider that has stopped
working looks exactly like a slider set to a value that does nothing.

=cut

sub animation_settings
{
    my ( $effect, %opt ) = @_;

    my $params = GlitchVape::Registry->get( $effect )->{ params };
    my $except = $opt{ except } || {};

    my @keys =
        grep { $params->{ $_ }{ animation } && !$except->{ "$effect.$_" } }
        sort keys %$params;

    return @keys;
}

sub moves
{
    my ( $effect, $key ) = @_;

    my $wound  = _wound_up( $effect, $key );
    my $frames = $BENCH{ motion }{ frames };
    my $first  = frame( 'motion', $effect, $wound, 0, $frames );

    for my $n ( 1 .. $frames - 1 )
    {
        return 1 if frame( 'motion', $effect, $wound, $n, $frames ) ne $first;
    }

    return 0;
}

sub animation_ok
{
    my ( $effect, %opt ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my @dead =
        grep { !moves( $effect, $_ ) } animation_settings( $effect, %opt );

    my $ok = $TB->ok( !@dead,
        "every animation setting of $effect changes some frame of a loop" );

    $TB->diag( 'these did nothing across a whole loop: '
            . join( ' ', map { "$effect.$_" } @dead ) )
        unless $ok;

    return $ok;
}

=head2 generator_ok( $kind, %settings )

That a kind of generated track resolves with only C<%settings> given, has a
natural length and a line to describe it by, and renders to a WAV file.

=cut

sub generator_ok
{
    my ( $kind, %settings ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $declared = GlitchVape::Generator::get( $kind );
    return $TB->ok( 0, "$kind is a registered kind of track" )
        unless $declared;

    my $spec =
        eval { GlitchVape::Generator::resolve( { %settings, kind => $kind } ) };
    unless ( $TB->ok( $spec, "$kind resolves from its defaults" ) )
    {
        $TB->diag( $@ );
        return;
    }

    $TB->cmp_ok( GlitchVape::Generator::duration( $spec ),
        '>', 0, "$kind has a natural length" );

    my $line = GlitchVape::Generator::describe( $spec );
    $TB->ok( defined $line && length $line, "$kind describes itself" );

    $DIR ||= File::Temp->newdir( 'gv_test_XXXXXX', TMPDIR => 1 );
    my $out = "$DIR/$kind.wav";

    my $made = eval {
        GlitchVape::Generator::render( spec => $spec, output => $out );
        1;
    };

    my $head = q{};
    if ( $made && open my $fh, '<:raw', $out )
    {
        read $fh, $head, 12;
        close $fh;
    }

    $TB->ok( $head =~ /\ARIFF....WAVE\z/s, "$kind renders a WAV file" )
        or $TB->diag( $@ || "what came out does not start as a WAV does" );

    return;
}

=head2 plugin_ok( $name, %opt )

That the plug-in called C<$name> -- with or without the C<GlitchVape::Plugin::>
in front -- was loaded rather than refused, and that everything it added
passes the checks above: each effect's declaration, a still rendered at its
defaults, its drift, its reroll and its animation settings; and each kind of
track it added.

C<%opt> carries what L</reroll_ok> and L</animation_ok> take, per effect:

    nudge  => { effect => { param => value } }
    except => { 'effect.param' => 'why it cannot answer' }

The rendering checks are skipped, each saying so, where ImageMagick is not
installed.

=cut

sub plugin_ok
{
    my ( $name, %opt ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    ( my $short = $name ) =~ s/\A\QGlitchVape::Plugin::\E//;
    my $module = "GlitchVape::Plugin::$short";

    my ( $refused ) =
        grep { $_->{ module } eq $module } GlitchVape::Plugins::refused();

    if ( $refused )
    {
        $TB->ok( 0, "plug-in $short loads" );
        $TB->diag( "it was refused: $refused->{reason}" );
        return 0;
    }

    my ( $loaded ) =
        grep { $_->{ module } eq $module } GlitchVape::Plugins::loaded();

    unless ( $TB->ok( $loaded, "plug-in $short loads" ) )
    {
        $TB->diag("it was not found: is its lib/ on \@INC -- prove -l -- and "
                . 'is GLITCHVAPE_PLUGINS leaving it out?' );
        return 0;
    }

    my $adds = $loaded->{ adds };
    $TB->ok( scalar %$adds, "and it adds something" );

    for my $effect ( @{ $adds->{ effects } || [] } )
    {
        declared_ok( $effect );

        unless ( can_render() )
        {
            $TB->skip( 'ImageMagick is not installed' );
            next;
        }

        my $still = eval { frame( 'motion', $effect, {}, 0, 1 ) };
        $TB->ok( defined $still, "$effect renders a still at its defaults" )
            or $TB->diag( $@ );

        next unless defined $still;

        drift_ok( $effect );
        reroll_ok( $effect, %{ $opt{ nudge }{ $effect } || {} } );
        animation_ok( $effect, except => $opt{ except } );
    }

    generator_ok( $_ ) for @{ $adds->{ 'soundtrack kinds' } || [] };

    return 1;
}

# ---------------------------------------------------------------------------

sub _param
{
    my ( $effect, $key ) = @_;

    my $spec = GlitchVape::Registry->get( $effect ) or return undef;
    return $spec->{ params }{ $key };
}

# A setting turned up as far as it goes, with everything it says it depends on
# turned on beside it.
sub _wound_up
{
    my ( $effect, $key ) = @_;

    my $params = GlitchVape::Registry->get( $effect )->{ params };
    my $spec   = $params->{ $key };

    my $most =
          defined $spec->{ max }    ? $spec->{ max }
        : $spec->{ type } eq 'bool' ? 1
        : $spec->{ values }         ? $spec->{ values }[ -1 ]
        :                             1;

    my %wound = ( $key => $most );

    for my $need ( sort keys %{ $spec->{ needs } || {} } )
    {
        my $want = $spec->{ needs }{ $need };
        $want = $want->[ 0 ] if ref $want eq 'ARRAY';

        $wound{ $need } =
            $want eq '1' ? ( $params->{ $need }{ max } // 1 ) : $want;
    }

    return \%wound;
}

sub _picture
{
    my ( $on ) = @_;

    my $key = "$on->{picture} $on->{size}";
    return $PICTURE{ $key } if $PICTURE{ $key };

    require Image::Magick;

    $DIR ||= File::Temp->newdir( 'gv_test_XXXXXX', TMPDIR => 1 );
    my $path = sprintf '%s/%s-%s.png', $DIR, $on->{ picture }, $on->{ size };

    my $img = Image::Magick->new( size => $on->{ size } );

    if ( $on->{ picture } eq 'shapes' )
    {
        $img->Read( 'gradient:#101040-#FFE0A0' );
        $img->Draw(
            primitive => 'rectangle',
            points    => '45,38 165,120',
            fill      => '#FF2090',
        );
    }
    else
    {
        $img->Read( 'plasma:fractal' );
    }

    my $err = $img->Write( $path );
    $TB->BAIL_OUT( "could not build the test source image: $err" )
        if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;

    return $PICTURE{ $key } = $path;
}

# One for every frame of every loop, the way the animation loop hands one to
# every frame of a real render -- see GlitchVape::Context/cachedir().
sub _cachedir
{
    $CACHE ||= File::Temp->newdir( 'gv_test_cache_XXXXXX', TMPDIR => 1 );
    return "$CACHE";
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Plugins>, for what a plug-in is; and F<t/03-registry.t>,
F<t/31-drift.t>, F<t/38-reroll.t> and F<t/42-animation.t>, which ask these of
every effect the program ships.

=cut
