package GlitchVape::Registry;

use strict;
use warnings;

use List::Util   qw(any);
use Scalar::Util qw(looks_like_number);

use GlitchVape::Plugins ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Registry - effect declaration, lookup and parameter validation

=head1 DESCRIPTION

Effects declare themselves at load time. Everything the CLI needs -- flag
names, defaults, help text, validation ranges -- comes from that one
declaration, so adding an effect never means editing the option parser.

=head1 STAGES

Order is not a free choice: scanlines applied before a downsample get eaten by
the resample, and a vignette applied before a chroma split gets its dark edges
smeared into colour fringes. Effects therefore declare a numeric stage and the
pipeline sorts by it. Presets may override with an explicit C<order:> list.

    10  format     resolution reduction, crop, aspect
    20  colour     grading, palette, duotone, depth reduction
    30  channels   channel separation and bleed
    40  damage     pixel sorting, databending, compression damage
    50  signal     transport artefacts: wobble, roll, ghost, snow
    60  grain      film grain and ordered dither
    70  optics     scanlines, phosphor, bloom, glass, lens
    80  overlay    text, grid, furniture
    90  framing    final crop, border, letterbox

A stage is two things at once: the point in the chain where an effect runs,
and the heading a person browses it under. The names above are chosen to be
honest about both. C<colour> rather than C<grade>, because only one of the
seven effects there is grading; C<damage> rather than C<destroy>, because the
latter said how it felt rather than what it did; C<optics> rather than
C<screen>, because a lens is not a screen but belongs in the same late pass.

=head2 STAGE_INFO

Each stage carries its running order, a presentable title, a line of
description and a line saying why it runs where it does. The interface reads
all four; nothing else needs the last three.

C<because> is the one that is easy to leave out and the one people actually
want. Somebody looking at a pipeline they cannot reorder is owed a reason, and
"the chain has an order" is not one -- so each stage says what would go wrong
if its effects ran elsewhere, in a sentence short enough to sit under a
heading.

=cut

use constant STAGE_INFO => {
    format => {
        order => 10,
        title => 'Resolution & Format',
        blurb =>
            'Throw away resolution or change the shape of the frame. Runs '
            . 'first, because everything after it works on what is left.',
        because => 'Everything after it works on what is left, so a frame '
            . 'shrunk late throws away detail the effects before it drew.',
    },
    colour => {
        order   => 20,
        title   => 'Colour',
        blurb   => 'Grade it, reduce it, or force it into a fixed palette.',
        because => 'Grade before the picture is damaged and the damage is '
            . 'graded too; after it, the damage keeps the colours it was '
            . 'given.',
    },
    channels => {
        order => 30,
        title => 'Channel Separation',
        blurb =>
            'Pull red, green and blue apart, or let colour bleed sideways '
            . 'the way composite video does.',
        because => 'The channels have to come apart before anything smears '
            . 'or scans them, or the smear happens once to a picture '
            . 'instead of separately to each channel.',
    },
    damage => {
        order => 40,
        title => 'Data Damage',
        blurb =>
            'Corrupt the picture as data rather than as an image: sorted, '
            . 'displaced, compressed past recovery.',
        because => 'Damage is done to the picture, not to the furniture: after '
            . 'the overlays it would corrupt the text and the timestamp '
            . 'rather than what they sit on.',
    },
    signal => {
        order => 50,
        title => 'Signal & Tape',
        blurb => 'What the picture picked up in transport: wobble, tracking, '
            . 'ghosting, snow.',
        because => 'A tape artefact belongs to the transport, so it happens '
            . 'once the picture exists and before the screen showing it '
            . 'adds anything of its own.',
    },
    grain => {
        order => 60,
        title => 'Grain & Dither',
        blurb =>
            'The texture of the medium: film grain, and the patterns left '
            . 'by a reduced bit depth.',
        because => 'Grain is in the medium, so it goes on before the glass. '
            . 'Dithered afterwards and the scanlines would be drawn over a '
            . 'pattern that should have been under them.',
    },
    optics => {
        order => 70,
        title => 'Screen & Optics',
        blurb => 'What it looks like through the glass: scanlines, phosphor, '
            . 'bloom, curvature, lens softness.',
        because => 'This is the screen and the lens, which see everything '
            . 'else. Scanlines applied before a downsample are eaten by '
            . 'the resample, and a vignette applied before a chroma split '
            . 'has its dark edges smeared into colour fringes.',
    },
    overlay => {
        order   => 80,
        title   => 'Overlays',
        blurb   => 'Text and furniture drawn on top of the finished picture.',
        because => 'Text is meant to be read, and anything running after it '
            . 'damages it -- so the furniture goes on once the picture '
            . 'has finished being ruined.',
    },
    framing => {
        order   => 90,
        title   => 'Framing',
        blurb   => 'The last word on the edges: bars, borders, aspect.',
        because => 'The edges are the last word. Bars and borders added '
            . 'earlier would be scanned, bled and damaged like picture, '
            . 'when they are the frame around it.',
    },
};

=head2 STAGES

Stage name to running order, which is all the pipeline itself needs.

=cut

use constant STAGES =>
    { map { $_ => STAGE_INFO->{ $_ }{ order } } keys %{ +STAGE_INFO } };

my %EFFECT;

# What a name may look like, for an effect and for each of its parameters. It
# is spelled on the command line, in preset files and in cache keys, and
# `--set effect.param=value` splits on the first dot -- so a dot in either
# would make a setting nobody could reach.
use constant NAME => qr/\A[a-z][a-z0-9_]*\z/;

# Everything a declaration may say. A key outside these is a typo, and a typo
# in a declaration is ignored in silence by everything that reads it: `mn => 0`
# is a slider with no bottom, and nobody would ever find out why.
my %EFFECT_KEY =
    map { $_ => 1 } qw(name title stage summary doc params apply requires);

my %PARAM_KEY = map { $_ => 1 } qw(
    type default min max values doc label order needs placeholder
    suggest choose stops animation
);

# The types _coerce knows. Anything else would be passed through as a string
# while the interface guessed at a widget for it.
my %TYPE = map { $_ => 1 } qw(num int bool enum str list);

# Named lists a parameter can offer with `suggest` or `choose` -- see
# L</SUGGESTION LISTS>. Each is { values => code, plugin => owner }.
my %SOURCE;

=head2 register( %spec )

    GlitchVape::Registry->register(
        name    => 'scanlines',
        title   => 'Scanlines',
        stage   => 'optics',
        summary => 'CRT horizontal scanline overlay',
        params  => {
            opacity => { default => 0.35, type => 'num', min => 0, max => 1,
                         doc => 'Darkness of each line' },
            spacing => { default => 3, type => 'int', min => 1, max => 64,
                         doc => 'Pixels between line centres' },
        },
        apply   => \&_scanlines,
    );

C<name> is the identifier -- the CLI flag, the preset key, the cache key --
and never changes. C<title> is what a person is shown. An effect that omits
one gets a title derived from its name, so the two never drift apart by
accident, only on purpose.

=head2 WHAT A PARAMETER MAY DECLARE

Beyond C<type>, C<default>, C<min>, C<max> and C<doc>, three keys exist purely
so that an effect can say how it wants to be presented without anything
outside it learning the effect's name:

    order   where it sits among its siblings; see L</sorted_params>
    label   what to call it, when the key is not the clearest English
    needs   which other parameters have to hold for this one to mean anything

C<needs> is a hash of C<< parameter => wanted >>, and all of it must hold:

    needs => { timestamp => 1, invent => 0 }

A wanted 0 or 1 asks about truth -- a switch that is on, a string that is not
empty. Anything else is compared as a string, so C<< { mode => 'frame' } >>
reads as it looks. An arrayref is any one of them, which is how an enum whose
off position is a word rather than a falsehood is asked about:

    needs => { sway => [ qw(hue saturation brightness contrast) ] } A parameter whose C<needs> are not met is still passed to
the effect and still validated; what changes is that the interface greys its
control, because a value that cannot matter yet should say so rather than
inviting somebody to set it and wonder why nothing moved.

Naming a parameter the effect does not declare is fatal at load time. Left
unchecked it would produce a control greyed out for ever, which looks exactly
like a bug in the widget rather than a typo in the declaration.

=head2 A DECLARATION IS CHECKED WHEN IT IS MADE

Everything that reads a declaration -- the option parser, C<--explain>, the
preset loader, the window -- trusts it, and each would fail in its own way at
its own moment if it were wrong: an C<enum> with no values made C<--explain>
die and could never resolve its own default, a stage left out quietly became
C<optics>, and a name with a dot in it could not be set from the command line
at all. So it is checked once, here, and a declaration that would break one of
them is refused with a sentence saying which rule it broke.

Which also means C<register> dies rather than warns. For an effect that ships
with the program that is a broken build; for one from a plug-in,
L<GlitchVape::Plugins> catches it and refuses the plug-in instead.

C<requires> names external tools, and each must be one L<GlitchVape::Tools>
knows about. A tool it has never heard of could only ever be reported missing,
installed or not -- so a plug-in that needs one registers it there first.

=cut

sub register
{
    my ( $class, %spec ) = @_;
    $class = ref $class || $class;

    my $name = $spec{ name } // q{};

    die "GlitchVape::Registry: effect registered without a name\n"
        unless length $name;

    die "GlitchVape::Registry: effect name '$name' must be lower case "
        . "letters, digits and underscores, starting with a letter\n"
        unless $name =~ NAME;

    if ( my $had = $EFFECT{ $name } )
    {
        die "GlitchVape::Registry: effect '$name' registered twice -- "
            . _whose( $had->{ plugin } )
            . " already has it\n";
    }

    _check_keys( "effect '$name'", \%spec, \%EFFECT_KEY );

    die "GlitchVape::Registry: effect '$name' has no apply coderef\n"
        unless ref $spec{ apply } eq 'CODE';

    # No default. Every effect that ships says where it runs, and one that
    # does not has not decided -- landing it in optics would be deciding for
    # it, somewhere it would never think to look.
    my $stage = $spec{ stage };
    die "GlitchVape::Registry: effect '$name' does not say which stage it "
        . 'runs at. One of: '
        . join( ', ', stages() ) . "\n"
        unless defined $stage && length $stage;

    my $order = STAGES->{ $stage }
        or die
        "GlitchVape::Registry: effect '$name' has unknown stage '$stage'\n";

    my $params = $spec{ params } || {};
    check_params( 'GlitchVape::Registry', $name, $params );

    _check_needs( $name, $params );

    my $requires = $spec{ requires } || [];
    _check_requires( $name, $requires );

    $EFFECT{ $name } = {
        name     => $name,
        title    => $spec{ title } // _titlecase( $name ),
        stage    => $stage,
        order    => $order,
        summary  => $spec{ summary } // '',
        params   => $params,
        apply    => $spec{ apply },
        requires => $requires,
        doc      => $spec{ doc } // '',

        # Which plug-in said so, or undef for the program itself. Read by the
        # listings, and by the preview cache, which has to know whose code
        # drew a picture before it can say the picture is still current.
        plugin => GlitchVape::Plugins::owner( scalar caller ),
    };

    return $EFFECT{ $name };
}

=head2 check_params( $who, $name, $params )

Validate a parameter hash in place, filling in inferred types -- the checks
C<register> makes of each parameter, for the other registry that uses the same
shape. C<$who> and C<$name> are only for the message: they are how a refusal
says which declaration it came from.

=cut

sub check_params
{
    my ( $who, $name, $params ) = @_;

    die "$who: '$name' declares its parameters as something other than "
        . "a hash\n"
        unless ref $params eq 'HASH';

    for my $p ( sort keys %$params )
    {
        my $d = $params->{ $p };

        die "$who: $name.$p must be a hash of what the parameter is\n"
            unless ref $d eq 'HASH';

        die "$who: parameter name '$name.$p' must be lower case letters, "
            . "digits and underscores, starting with a letter\n"
            unless $p =~ NAME;

        _check_keys( "$name.$p", $d, \%PARAM_KEY, $who );

        die "$who: $name.$p has no default\n"
            unless exists $d->{ default };

        # A parameter that omits its type is inferred from the shape of its
        # default: anything numeric is treated as a number, everything else
        # as a free string.
        if ( !$d->{ type } )
        {
            if ( looks_like_number( $d->{ default } ) )
            {
                $d->{ type } = 'num';
            }
            else
            {
                $d->{ type } = 'str';
            }
        }

        die "$who: $name.$p has unknown type '$d->{type}'. One of: "
            . join( ', ', sort keys %TYPE ) . "\n"
            unless $TYPE{ $d->{ type } };

        _check_shape( $who, $name, $p, $d );
    }

    return $params;
}

# The parts of a parameter that depend on its type, and the one question that
# covers all of them: whether the parameter accepts its own default. A default
# the parameter would refuse is an effect nobody can use without first
# overriding it, and the refusal would arrive at render time naming a value
# the user never typed.
sub _check_shape
{
    my ( $who, $name, $p, $d ) = @_;

    my $label = "$name.$p";

    if ( $d->{ type } eq 'enum' )
    {
        die "$who: $label is an enum and lists no values\n"
            unless ref $d->{ values } eq 'ARRAY' && @{ $d->{ values } };
    }

    _check_range( $who, $label, $d );
    _check_offers( $who, $label, $d );
    _check_stops( $who, $label, $d->{ stops } );

    die "$who: $label.order must be a number\n"
        if defined $d->{ order } && !looks_like_number( $d->{ order } );

    my $ok = eval { _coerce( $name, $p, $d->{ default }, $d ); 1 };
    unless ( $ok )
    {
        my $why = $@;
        $why =~ s/\AGlitchVape: //;
        $why =~ s/\s+\z//;

        die "$who: $label refuses its own default ($why)\n";
    }

    return;
}

sub _check_range
{
    my ( $who, $label, $d ) = @_;

    for my $bound ( qw(min max) )
    {
        next unless defined $d->{ $bound };

        die "$who: $label.$bound must be a number, got '$d->{$bound}'\n"
            unless looks_like_number( $d->{ $bound } );
    }

    return unless defined $d->{ min } && defined $d->{ max };

    die "$who: $label runs from $d->{min} to $d->{max}, which is backwards\n"
        if $d->{ min } > $d->{ max };

    return;
}

sub _check_offers
{
    my ( $who, $label, $d ) = @_;

    # Both would be two answers to one question -- the combo either takes
    # what you type or it does not.
    die "$who: $label says both suggest and choose; it is one or the "
        . "other\n"
        if defined $d->{ suggest } && defined $d->{ choose };

    for my $offer ( qw(suggest choose) )
    {
        my $from = $d->{ $offer };
        next unless defined $from;
        next if ref $from eq 'ARRAY';

        die "$who: $label.$offer names '$from', which is not a list the "
            . 'program knows. One of: '
            . join( ', ', sources() ) . "\n"
            unless $SOURCE{ $from };
    }

    return;
}

sub _check_stops
{
    my ( $who, $label, $stops ) = @_;

    return unless defined $stops;

    my @range = ref $stops eq 'ARRAY' ? @$stops : ( $stops, $stops );

    my $counts = @range == 2
        && !any { !defined || !/\A[1-9][0-9]*\z/ } @range;

    die "$who: $label.stops must be a count, or a [least, most] pair\n"
        unless $counts && $range[ 0 ] <= $range[ 1 ];

    return;
}

sub _check_keys
{
    my ( $what, $spec, $known, $who ) = @_;
    $who //= 'GlitchVape::Registry';

    my @odd = grep { !$known->{ $_ } } sort keys %$spec;
    return unless @odd;

    die "$who: $what declares "
        . join( ', ', map { "'$_'" } @odd )
        . ', which means nothing here. Known: '
        . join( ', ', sort keys %$known ) . "\n";
}

sub _check_requires
{
    my ( $name, $requires ) = @_;

    die "GlitchVape::Registry: effect '$name' lists its requirements as "
        . "something other than a list\n"
        unless ref $requires eq 'ARRAY';

    return unless @$requires;

    require GlitchVape::Tools;

    for my $tool ( @$requires )
    {
        next if GlitchVape::Tools::known( $tool );

        die "GlitchVape::Registry: effect '$name' requires '$tool', which "
            . "GlitchVape::Tools has never heard of -- register it there "
            . "first, or it can only ever be reported missing\n";
    }

    return;
}

# Who holds a name, for a message about a collision over it.
sub _whose
{
    my ( $plugin ) = @_;

    return 'the program itself' unless defined $plugin;
    return "plug-in $plugin";
}

sub _check_needs
{
    my ( $name, $params ) = @_;

    for my $p ( sort keys %$params )
    {
        my $needs = $params->{ $p }{ needs } or next;

        for my $key ( sort keys %$needs )
        {
            next if $params->{ $key };
            die "GlitchVape::Registry: $name.$p needs '$key', "
                . "which '$name' does not declare\n";
        }
    }

    return;
}

# 'chroma_shift' -> 'Chroma Shift'. Only a fallback: every shipped effect
# declares a title, because the derived form cannot know that 'osd' wants to
# be 'Camcorder OSD'.
sub _titlecase
{
    my ( $name ) = @_;

    my @words = split /_/, $name;
    return join q{ }, map { ucfirst } @words;
}

=head2 get( $name )

Effect spec hashref, or undef.

=cut

sub get
{
    my ( $class, $name ) = @_;
    $name = $class unless ref $class || $class eq __PACKAGE__;
    return $EFFECT{ $name };
}

=head2 names()

All registered effect names, in pipeline order then alphabetically.

=cut

sub names
{
    # Materialised rather than returned straight from sort: the behaviour of a
    # sort evaluated in scalar context is undefined.
    my @names =
        sort { $EFFECT{ $a }{ order } <=> $EFFECT{ $b }{ order } || $a cmp $b }
        keys %EFFECT;
    return @names;
}

=head2 all()

The full registry as a hashref, keyed by name.

=cut

sub all { \%EFFECT }

=head2 retract( $plugin ) / contributions( $plugin )

Everything one plug-in registered here -- effects and suggestion lists --
taken back, or listed as C<< { effects => [...], 'suggestion lists' => [...] } >>.
L<GlitchVape::Plugins> asks every registry both questions, the first when a
plug-in fails half way through loading and the second for C<--list-plugins>.

=cut

sub retract
{
    my ( $class, $plugin ) = @_;
    $plugin = $class unless ref $class || $class eq __PACKAGE__;

    for my $table ( \%EFFECT, \%SOURCE )
    {
        delete @$table{ _from( $table, $plugin ) };
    }

    return;
}

sub contributions
{
    my ( $class, $plugin ) = @_;
    $plugin = $class unless ref $class || $class eq __PACKAGE__;

    return {
        effects            => [ _from( \%EFFECT, $plugin ) ],
        'suggestion lists' => [ _from( \%SOURCE, $plugin ) ],
    };
}

sub _from
{
    my ( $table, $plugin ) = @_;

    my @names = sort grep { ( $table->{ $_ }{ plugin } // q{} ) eq $plugin }
        keys %$table;

    return @names;
}

=head2 SUGGESTION LISTS

A parameter can offer values with C<suggest> (typeable) or C<choose> (closed),
and either can be an inline list or the name of one of these. The named ones
are program-wide facts -- every registered palette, every duotone ramp -- and
the inline form is for everything else: three tape speeds are nobody else's
business, and requiring a named list for them would mean an effect that wants
to offer three strings has to edit somewhere else to do it.

They live here rather than in the window, where they started, because which
lists exist is a fact about the declarations: C<register> refuses a parameter
that names a list nobody has, which used to be a combo that quietly offered
nothing.

=cut

%SOURCE = (

    # A parameter opts in by declaring `suggest => 'palette'`, and the combo
    # then offers these while the entry still takes anything -- a palette
    # parameter also accepts an inline '#FF71CE,#01CDFE' list, so the values
    # are an offer, not a set.
    palette => {
        values => sub {
            require GlitchVape::Palette;
            return GlitchVape::Palette::names();
        },
    },

    # 'custom' first, because it is the one that is not a name -- it is the
    # answer for when none of the names is what you meant.
    duotone => {
        values => sub {
            require GlitchVape::Palette;
            return ( 'custom', GlitchVape::Palette::duotone_names() );
        },
    },

    # 'native' first, because leaving the shape alone is what most renders
    # want: three of the four presets that letterbox do it for the border
    # and nothing else.
    ratio => { values => sub { return qw(native 16:9 2.35:1 4:3 1:1 9:16) } },

    # The same names again with 'custom' in front of them, for the two effects
    # that can be handed colours instead of a name. A second list rather than
    # 'custom' added to the first, because offering it is a claim the effect
    # has somewhere to put the colours: bitmap.palette has not, and a
    # drop-down offering an answer the render cannot use is the ambiguity this
    # whole arrangement exists to remove.
    palette_custom => {
        values => sub {
            require GlitchVape::Palette;
            return ( 'custom', GlitchVape::Palette::names() );
        },
    },
);

=head2 register_source( name => $name, values => sub { ... } )

A named list for C<suggest> and C<choose> to point at. C<values> is called
each time the list is shown, so a list of things that can change -- palettes
that plug-ins add, say -- is never stale. An array reference is taken as a
fixed list.

=cut

sub register_source
{
    my ( $class, %arg ) = @_;

    my $name = $arg{ name } // q{};

    die "GlitchVape::Registry: a suggestion list needs a name made of "
        . "lower case letters, digits and underscores\n"
        unless $name =~ NAME;

    if ( my $had = $SOURCE{ $name } )
    {
        die "GlitchVape::Registry: suggestion list '$name' registered twice "
            . '-- '
            . _whose( $had->{ plugin } )
            . " already has it\n";
    }

    my $values = $arg{ values };
    if ( ref $values eq 'ARRAY' )
    {
        my @fixed = @$values;
        $values = sub { return @fixed };
    }

    die "GlitchVape::Registry: suggestion list '$name' has no values\n"
        unless ref $values eq 'CODE';

    $SOURCE{ $name } = {
        values => $values,
        plugin => GlitchVape::Plugins::owner( scalar caller ),
    };

    return $name;
}

=head2 sources()

The names of every suggestion list, sorted.

=cut

sub sources
{
    my @names = sort keys %SOURCE;
    return @names;
}

=head2 offered( $spec, $key )

What one parameter offers under C<suggest> or C<choose> (C<$key>), as an array
reference, or undef if it offers nothing. Two spellings, and the difference is
what typing something else would mean:

    suggest => ...   these, or anything else you can think of
    choose  => ...   these, and there is nothing else to say

Which of the two a parameter wants is a fact about the parameter and not about
the widget, so it is declared rather than decided by the window. bitmap.palette
chooses: five settings make a bitmap look like a machine, and the palette is
which machine, so a list is the whole question. palette.name suggests: that
effect is I<about> the colours, so an inline '#FF71CE,#01CDFE' that no list
could enumerate is exactly what somebody might mean.

=cut

sub offered
{
    my ( $spec, $key ) = @_;

    my $offer = $spec->{ $key };
    return undef unless defined $offer;

    return [ @$offer ] if ref $offer eq 'ARRAY';

    my $source = $SOURCE{ $offer } or return undef;
    return [ $source->{ values }->() ];
}

=head2 by_stage()

Effect names grouped as C<< { stage => [ names ] } >>.

=cut

sub by_stage
{
    my %out;
    push @{ $out{ $EFFECT{ $_ }{ stage } } }, $_ for names();
    return \%out;
}

=head2 stages()

Stage names in running order.

=cut

sub stages
{
    my @stages =
        sort { STAGES->{ $a } <=> STAGES->{ $b } } keys %{ +STAGES };
    return @stages;
}

=head2 stage_info( $stage )

    { name, order, title, blurb }

for one stage, or undef. The interface groups the effect chooser by this;
nothing in the render path reads past C<order>.

=cut

sub stage_info
{
    my ( $class, $stage ) = @_;
    $stage = $class unless ref $class || $class eq __PACKAGE__;

    my $info = STAGE_INFO->{ $stage } or return undef;
    return { name => $stage, %$info };
}

=head2 sorted_params( $params )

One effect's parameter names, in the order they should be presented: declared
C<order> first, then alphabetically among the ones that share it or declare
none.

A plain function taking the parameter hash rather than a method taking an
effect name, because both callers already hold the hash -- and because it has
to be reachable from C<bin/glitchvape>, which cannot see the GUI.

Alphabetical was the old answer everywhere, and it is the right default: it is
stable, and it needs no decision from an effect that has none to make. What it
cannot do is group. C<osd> has a colour, a font and a size that are about how
the display looks, and a timestamp that is switched on before any of the four
settings under it mean anything -- an order that comes from the effect, so it
is declared by the effect.

=cut

# Where a parameter with nothing to say about its position sorts. Comfortably
# past anything an effect is likely to number, so declaring an order on some
# parameters and not others puts the numbered ones first rather than
# interleaving them by accident.
use constant DEFAULT_ORDER => 1_000;

sub sorted_params
{
    my ( $params ) = @_;
    $params ||= {};

    my @names = sort {
        ( $params->{ $a }{ order } // DEFAULT_ORDER )
            <=> ( $params->{ $b }{ order } // DEFAULT_ORDER )
            || $a cmp $b
    } keys %$params;

    return @names;
}

=head2 without_animation( $name, $params )

A copy of one effect's values with every parameter it declares as C<animation>
put back to what the effect declares. What is left is the same look holding
still: nothing about the effect is switched off, and a render of one frame is
unaffected, because a still was already what those parameters do nothing to.

Here rather than in the interface because which parameters those are is a fact
about the declaration, and because the pipeline has to be handed the same
values the command line would print.

=cut

sub without_animation
{
    my ( $class, $name, $params ) = @_;

    my $spec = $class->get( $name ) or return { %{ $params || {} } };

    my %held = %{ $params || {} };

    for my $key ( sort keys %{ $spec->{ params } } )
    {
        next unless $spec->{ params }{ $key }{ animation };
        $held{ $key } = $spec->{ params }{ $key }{ default };
    }

    return \%held;
}

=head2 animated( $name )

Whether an effect declares anything that only means something in a loop.

=cut

sub animated
{
    my ( $class, $name ) = @_;

    my $spec = $class->get( $name ) or return 0;

    return any { $_->{ animation } } values %{ $spec->{ params } };
}

=head2 needs_met( $spec, $values )

Whether one parameter's declared C<needs> hold, given the effect's current
values. True for a parameter that declares none.

A wanted value is one to match, C<0> or C<1> to ask about truth, or an
arrayref of any of those meaning any one of them.

Pure logic, and here rather than in the interface for the usual reason: the
question "does this setting mean anything yet" is a fact about the
declaration, not about Gtk.

=cut

sub needs_met
{
    my ( $spec, $values ) = @_;

    my $needs = $spec->{ needs } or return 1;
    $values ||= {};

    for my $key ( sort keys %$needs )
    {
        my $want = $needs->{ $key };
        my $have = $values->{ $key };

        # A list is any one of them. An enum whose off position is a word
        # rather than a falsehood -- 'none' -- cannot be asked about as a
        # truth, and naming the four values that are not it says what is
        # meant where "not none" would need a grammar.
        my @want = ref $want eq 'ARRAY' ? @$want : ( $want );

        return 0 unless any { _wanted( $_, $have ) } @want;
    }

    return 1;
}

sub _wanted
{
    my ( $want, $have ) = @_;

    # A wanted 0 or 1 is a question about truth, which is what makes one
    # spelling serve both a bool that is off and a string that is empty.
    if ( $want eq '0' || $want eq '1' )
    {
        my $got = ( defined $have && length $have && $have ne '0' ) ? 1 : 0;
        return $got == $want ? 1 : 0;
    }

    return 0 unless defined $have;
    return lc "$have" eq lc $want ? 1 : 0;
}

=head2 resolve_params( $name, $given )

Merge user-supplied values over defaults, coercing and range-checking each.
Dies on an unknown parameter -- a silently ignored typo in a preset is the
difference between "the effect did nothing" and half an hour of confusion.

=cut

sub resolve_params
{
    my ( $class, $name, $given ) = @_;
    $given ||= {};

    my $spec = $EFFECT{ $name }
        or die "GlitchVape: unknown effect '$name'. Try --list-effects.\n";

    my %out;
    my $params = $spec->{ params };

    for my $key ( keys %$given )
    {
        next if $key eq 'enabled' || $key eq 'order';
        if ( !$params->{ $key } )
        {
            my @known = sort keys %$params;

            # Listing what *is* accepted turns a typo from a dead end into a
            # one-line fix. An effect with no parameters at all says so.
            my $hint = "  It takes no parameters.\n";
            if ( @known )
            {
                $hint = '  Valid: ' . join( ', ', @known ) . "\n";
            }

            die "GlitchVape: effect '$name' has no parameter '$key'.\n" . $hint;
        }
    }

    for my $key ( sort keys %$params )
    {
        my $d = $params->{ $key };

        # A key the caller did not mention falls back to the declared
        # default; note that an explicitly-supplied undef is honoured rather
        # than being replaced.
        my $val = $d->{ default };
        if ( exists $given->{ $key } )
        {
            $val = $given->{ $key };
        }
        $out{ $key } = _coerce( $name, $key, $val, $d );
    }

    return \%out;
}

=head2 at_defaults( $name, $params )

Whether C<$params> is what the effect would have been given had nobody
touched it. True for an effect that is not registered, and for an empty hash.

Compared against a freshly resolved set rather than against the raw
declaration, so both sides have been through the same coercion -- otherwise a
slider handing back C<0.35> would compare unequal to a declared C<'0.35'>.

Here rather than in the interface because two front ends ask it -- the Add
Effect wizard and the settings popover -- and because whether a hash matches a
declaration is a question about the declaration.

=cut

sub at_defaults
{
    my ( $class, $name, $params ) = @_;

    my $spec = get( $class, $name ) or return 1;

    my $defaults = eval { resolve_params( $class, $name, {} ) } or return 1;

    for my $key ( keys %$defaults )
    {
        my $type = $spec->{ params }{ $key }{ type } // 'str';

        # A key that is not there is a key nobody set, and an effect renders
        # an unset parameter at its default -- so an empty hash is at its
        # defaults, which is what makes clearing one a way of resetting it.
        next unless exists $params->{ $key };

        my $now = $params->{ $key };
        my $was = $defaults->{ $key };

        return 0 if defined $now xor defined $was;
        next unless defined $now;

        if ( $type eq 'list' )
        {
            return 0 if join( ',', @$now ) ne join( ',', @$was );
        }
        elsif ( $type eq 'num' || $type eq 'int' )
        {
            return 0 if $now != $was;
        }
        else
        {
            return 0 if $now ne $was;
        }
    }

    return 1;
}

sub _coerce
{
    my ( $effect, $key, $val, $d ) = @_;
    my $type = $d->{ type };

    if ( $type eq 'bool' )
    {
        return 0 if !defined $val;
        return 0 if $val =~ /^(0|no|off|false|)$/i;
        return 1;
    }

    if ( $type eq 'num' || $type eq 'int' )
    {
        die "GlitchVape: $effect.$key expects a number, got '$val'\n"
            unless looks_like_number( $val );
        if ( $type eq 'int' )
        {

            # Round to nearest rather than truncating, and round away from
            # zero on negatives so that -2.5 becomes -3, not -2.
            my $bias = 0.5;
            if ( $val < 0 )
            {
                $bias = -0.5;
            }
            $val = int( $val + $bias );
        }
        else
        {
            # Force numeric context so that a string from the CLI compares
            # numerically against min/max below.
            $val = $val + 0;
        }

        if ( defined $d->{ min } && $val < $d->{ min } )
        {
            die "GlitchVape: $effect.$key must be >= $d->{min}, got $val\n";
        }
        if ( defined $d->{ max } && $val > $d->{ max } )
        {
            die "GlitchVape: $effect.$key must be <= $d->{max}, got $val\n";
        }
        return $val;
    }

    if ( $type eq 'enum' )
    {
        my @ok = @{ $d->{ values } || [] };
        return $val if any { lc $_ eq lc( $val // '' ) } @ok;
        die "GlitchVape: $effect.$key must be one of: "
            . join( ', ', @ok )
            . " (got '"
            . ( $val // '' ) . "')\n";
    }

    if ( $type eq 'list' )
    {
        return $val if ref $val eq 'ARRAY';
        return [ grep { length } split /\s*,\s*/, ( $val // '' ) ];
    }

    return $val;
}

1;
