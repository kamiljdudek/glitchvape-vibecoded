package GlitchVape::Registry;

use strict;
use warnings;

use List::Util   qw(any);
use Scalar::Util qw(looks_like_number);

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
reads as it looks. A parameter whose C<needs> are not met is still passed to
the effect and still validated; what changes is that the interface greys its
control, because a value that cannot matter yet should say so rather than
inviting somebody to set it and wonder why nothing moved.

Naming a parameter the effect does not declare is fatal at load time. Left
unchecked it would produce a control greyed out for ever, which looks exactly
like a bug in the widget rather than a typo in the declaration.

=cut

sub register
{
    my ( $class, %spec ) = @_;
    $class = ref $class || $class;

    my $name = $spec{ name }
        or die "GlitchVape::Registry: effect registered without a name\n";

    die "GlitchVape::Registry: effect '$name' registered twice\n"
        if $EFFECT{ $name };

    die "GlitchVape::Registry: effect '$name' has no apply coderef\n"
        unless ref $spec{ apply } eq 'CODE';

    my $stage = $spec{ stage } // 'optics';
    my $order = STAGES->{ $stage }
        or die
        "GlitchVape::Registry: effect '$name' has unknown stage '$stage'\n";

    my $params = $spec{ params } || {};
    for my $p ( sort keys %$params )
    {
        my $d = $params->{ $p };

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
        die "GlitchVape::Registry: $name.$p has no default\n"
            unless exists $d->{ default };
    }

    _check_needs( $name, $params );

    $EFFECT{ $name } = {
        name     => $name,
        title    => $spec{ title } // _titlecase( $name ),
        stage    => $stage,
        order    => $order,
        summary  => $spec{ summary } // '',
        params   => $params,
        apply    => $spec{ apply },
        requires => $spec{ requires } || [],
        doc      => $spec{ doc } // '',
    };

    return $EFFECT{ $name };
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

=head2 needs_met( $spec, $values )

Whether one parameter's declared C<needs> hold, given the effect's current
values. True for a parameter that declares none.

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

        # A wanted 0 or 1 is a question about truth, which is what makes one
        # spelling serve both a bool that is off and a string that is empty.
        if ( $want eq '0' || $want eq '1' )
        {
            my $got = ( defined $have && length $have && $have ne '0' ) ? 1 : 0;
            return 0 if $got != $want;
        }
        else
        {
            return 0 unless defined $have;
            return 0 unless lc "$have" eq lc $want;
        }
    }

    return 1;
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
