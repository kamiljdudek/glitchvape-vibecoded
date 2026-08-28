package GlitchVape::Generator;

use strict;
use warnings;
use utf8;

use GlitchVape::DTMF   ();
use GlitchVape::Geiger ();
use GlitchVape::Heart  ();
use GlitchVape::Noise  ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Generator - soundtracks the machine makes up

=head1 DESCRIPTION

A soundtrack can be a file you cropped, or it can be synthesised. This is the
registry of the synthesised kinds, and it is a registry for the same reason
L<GlitchVape::Registry> is one: the declaration below is what produces the
command-line validation, the C<--list-generators> output and the widgets in
the interface, so a third kind is one C<register> call rather than three edits
in three files.

=head2 They stack

Unlike the file half, of which there is one, generated tracks are a list.
Adding two static beds and a dialled phrase is a reasonable thing to want, and
nothing here treats it as a special case: every track is rendered separately
and they are all summed.

=head2 Length

Each kind reports a natural length -- for a dialled phrase that is a
consequence of the words, for static it is simply a setting. When a mix has an
audio file in it the file overrules all of them, and each track is asked to
cover that length instead. What "cover" means is the kind's own business: see
L<GlitchVape::DTMF/render> for the one that has an opinion about it.

=cut

my %KIND;
my @ORDER;

=head2 register( %spec )

    kind     => 'static'
    label    => 'TV static'
    icon     => 'audio-speakers-symbolic'     what the interface shows
    summary  => one line
    doc      => paragraph
    params   => hashref in the L<GlitchVape::Registry> parameter shape
    order    => arrayref of parameter names, in display order
    resolve  => sub { my ( $spec ) = @_ }      validate and fill in defaults
    duration => sub { my ( $spec ) = @_ }      natural length in seconds
    ending   => bool                           whether that length is intrinsic
    render   => sub { my ( %arg ) = @_ }       spec, output, fill_to
    describe => sub { my ( $spec ) = @_ }      one line for a track row

=cut

sub register
{
    my ( $class, %spec ) = @_;

    my $kind = $spec{ kind }
        or die "GlitchVape::Generator: a kind needs a name\n";

    push @ORDER, $kind unless $KIND{ $kind };
    $KIND{ $kind } = \%spec;

    return $kind;
}

=head2 icon( $kind )

The icon name for a kind, from its declaration. Declared rather than mapped in
the interface, because a mapping keyed on kind is exactly the special case
C<register> exists to avoid -- and there were two copies of it, which had
begun to disagree.

=cut

sub icon
{
    my ( $kind ) = @_;
    $kind = $_[ 1 ] if ref $kind || ( $kind // q{} ) eq __PACKAGE__;

    my $declared = $KIND{ $kind // q{} } or return 'audio-speakers-symbolic';

    return $declared->{ icon } || 'audio-speakers-symbolic';
}

=head2 kinds() / get( $kind ) / all()

The registered kinds in declaration order, one declaration, and the lot.

=cut

=head2 has_ending( $kind )

Whether the kind's length is a consequence of its content rather than a
setting. A dialled phrase ends when the words run out and can therefore be cut
short of it; static has no ending to be cut short of, and asking for less of it
is simply asking for less of it.

The difference matters exactly once, in L<GlitchVape::Audio/truncated>, which
reports what a short file will cut off.

=cut

sub has_ending
{
    my ( $kind ) = @_;

    my $declared = get( $kind ) or return 0;
    return 0 unless $declared->{ ending };

    return 1;
}

sub kinds { return @ORDER }
sub get   { return $KIND{ $_[ 0 ] // q{} } }
sub all   { return { %KIND } }

=head2 resolve_params( $declared, $given )

Clamp and default a set of values against a parameter declaration. Exposed
because a kind's own C<resolve> usually wants it and then adds a check of its
own on top.

Numbers outside their range are clamped rather than refused -- a slider handing
back 1.0000000000002 is not a mistake worth a message -- but a value of
entirely the wrong shape, or an enum that is not one of the listed values, is
a typo and stops.

=cut

sub resolve_params
{
    my ( $declared, $given ) = @_;

    $given = {} unless ref $given eq 'HASH';

    my %out;

    for my $name ( sort keys %$declared )
    {
        my $field = $declared->{ $name };
        my $value = $given->{ $name };

        unless ( defined $value && length $value )
        {
            $out{ $name } = $field->{ default };
            next;
        }

        my $type = $field->{ type } // 'str';

        if ( $type eq 'enum' )
        {
            my @values = @{ $field->{ values } || [] };

            my $known = 0;
            for my $allowed ( @values )
            {
                $known = 1 if $allowed eq $value;
            }

            unless ( $known )
            {
                die "GlitchVape::Generator: '$name' must be one of "
                    . join( ', ', @values )
                    . ", got '$value'\n";
            }

            $out{ $name } = $value;
            next;
        }

        if ( $type eq 'num' || $type eq 'int' )
        {
            unless ( $value =~ /^-?\d+(?:[.]\d+)?$/ )
            {
                die "GlitchVape::Generator: '$name' takes a number, "
                    . "got '$value'\n";
            }

            $value += 0;
            $value = $field->{ min }
                if defined $field->{ min } && $value < $field->{ min };
            $value = $field->{ max }
                if defined $field->{ max } && $value > $field->{ max };
            $value = int $value if $type eq 'int';

            $out{ $name } = $value;
            next;
        }

        $out{ $name } = $value;
    }

    return \%out;
}

=head2 resolve( $spec )

Validate one generated track. Returns the resolved spec, C<kind> included, or
dies saying which kind or parameter was wrong.

=cut

sub resolve
{
    my ( $spec ) = @_;

    return undef unless ref $spec eq 'HASH';

    my $kind = $spec->{ kind };

    unless ( defined $kind && length $kind )
    {
        die "GlitchVape::Generator: a generated track needs a kind.\n"
            . '  Available: '
            . join( ', ', kinds() ) . "\n";
    }

    my $declared = get( $kind );

    unless ( $declared )
    {
        die "GlitchVape::Generator: no generator called '$kind'.\n"
            . '  Available: '
            . join( ', ', kinds() ) . "\n";
    }

    my $resolved = $declared->{ resolve }->( $spec ) or return undef;

    return { %$resolved, kind => $kind };
}

=head2 duration( $spec )

The track's natural length in seconds, or 0 if it has none.

=cut

sub duration
{
    my ( $spec ) = @_;

    my $declared = get( $spec->{ kind } // q{} ) or return 0;

    my $seconds = eval { $declared->{ duration }->( $spec ) };
    return 0 unless $seconds;

    return $seconds;
}

=head2 render( %arg )

    spec    => one generated track
    output  => path to write, .wav
    fill_to => seconds the result must cover, or undef for its natural length

=cut

sub render
{
    my ( %arg ) = @_;

    my $spec = resolve( $arg{ spec } )
        or die "GlitchVape::Generator: nothing to generate\n";

    my $declared = get( $spec->{ kind } );

    return $declared->{ render }->(
        spec    => $spec,
        output  => $arg{ output },
        fill_to => $arg{ fill_to },
    );
}

=head2 describe( $spec )

One line for a track row.

=cut

sub describe
{
    my ( $spec ) = @_;

    my $declared = get( $spec->{ kind } // q{} )
        or return 'unknown generator';

    my $line = eval { $declared->{ describe }->( $spec ) };
    return $declared->{ label } unless defined $line && length $line;

    return $line;
}

=head2 filename( $spec )

A filename stem for a track, without an extension: the kind and how long it
runs, as C<geiger-20s>.

Built from those two rather than from C<describe>, which is the obvious source
and the wrong one -- it is prose for a status bar, and squeezing it into a
filename gives C<static-static-muffled-0-10-0-hum-crackle>, which repeats the
kind and carries settings nobody is going to read off a directory listing. The
length is enough to tell two saved tracks apart, and the chooser lets anyone
who wants more type it.

=cut

sub filename
{
    my ( $spec ) = @_;

    my $kind = ( ref $spec eq 'HASH' ? $spec->{ kind } : undef ) // 'track';
    $kind =~ s/[^A-Za-z0-9]+/-/g;

    my $seconds = int( eval { duration( $spec ) } // 0 );
    return $kind unless $seconds > 0;

    return "$kind-${seconds}s";
}

=head2 label( $kind )

The kind's display name.

=cut

sub label
{
    my ( $kind ) = @_;

    my $declared = get( $kind ) or return $kind;
    return $declared->{ label };
}

=head2 spec_parts( $spec )

The pieces that determine the rendered audio, for a cache key.

=cut

sub spec_parts
{
    my ( $spec ) = @_;

    return () unless ref $spec eq 'HASH';

    my $kind = $spec->{ kind };
    return () unless defined $kind && length $kind;

    my @parts = ( 'gen', $kind );

    for my $name ( sort keys %$spec )
    {
        # The leading-underscore keys are what a resolve worked out rather
        # than what the user set, so they are derived from what is already
        # here and would only make the key longer.
        next if $name eq 'kind' || $name =~ /^_/;
        push @parts, $name, $spec->{ $name };
    }

    return @parts;
}

# ---------------------------------------------------------------------------
# The kinds

__PACKAGE__->register(
    kind    => 'dtmf',
    label   => 'Phone dial tones',
    icon    => 'call-start-symbolic',
    summary => 'A phrase spelled out in dialpad tones',
    doc     => <<'DOC',
Text dialled on a phone keypad, multi-tap style. Under a soundtrack it plays
once, stops, and after three seconds of silence the line opens again -- rather
than looping, which would turn a sentence into a stutter.
DOC
    ending   => 1,
    params   => GlitchVape::DTMF::params(),
    order    => [ GlitchVape::DTMF::param_order() ],
    resolve  => \&GlitchVape::DTMF::resolve,
    duration => \&GlitchVape::DTMF::duration,
    describe => \&GlitchVape::DTMF::describe,
    render   => sub {
        my ( %arg ) = @_;
        return GlitchVape::DTMF::render( %arg );
    },
    readout => sub {
        my ( $spec ) = @_;

        my $keys = GlitchVape::DTMF::keys_of( $spec );
        return q{} unless length $keys;

        return "dials: $keys";
    },
);

__PACKAGE__->register(
    kind    => 'static',
    label   => 'TV static',
    icon    => 'audio-speakers-symbolic',
    summary => 'The hiss of a set tuned to nothing',
    doc     => <<'DOC',
Analogue snow. Pink rather than white, and band-limited to a television's
audio path, so it is restful in the way rain is rather than fatiguing in the
way white noise is -- while still being unmistakably static. Mains hum and the
occasional crackle are what stop it sounding like a synthesiser.

It has no natural end, so under a soundtrack it simply carries on: there is no
seam to hide.
DOC
    params   => GlitchVape::Noise::params(),
    order    => [ GlitchVape::Noise::param_order() ],
    duration => \&GlitchVape::Noise::duration,
    describe => \&GlitchVape::Noise::describe,
    resolve  => sub {
        my ( $spec ) = @_;
        return resolve_params( GlitchVape::Noise::params(), $spec );
    },
    render => sub {
        my ( %arg ) = @_;
        return GlitchVape::Noise::render( %arg );
    },
);

__PACKAGE__->register(
    kind    => 'geiger',
    label   => 'Geiger counter',
    icon    => 'radio-symbolic',
    summary => 'Ticks, clumping as the source comes and goes',
    doc     => <<'DOC',
A Geiger-Müller tube ticking. The gaps between clicks are drawn from the
exponential distribution radioactive decay actually has, which is what makes
them clump into bursts and pauses rather than sounding like a metronome with a
fault -- and the tube's dead time is modelled too, so a strong source
saturates into a buzz instead of merely ticking faster.

The distance to the source wanders, so the rate rises and falls by the inverse
square law. It has no natural end: under a soundtrack it simply carries on
wandering.
DOC
    params   => GlitchVape::Geiger::params(),
    order    => [ GlitchVape::Geiger::param_order() ],
    duration => \&GlitchVape::Geiger::duration,
    describe => \&GlitchVape::Geiger::describe,
    resolve  => sub {
        my ( $spec ) = @_;
        return resolve_params( GlitchVape::Geiger::params(), $spec );
    },
    render => sub {
        my ( %arg ) = @_;
        return GlitchVape::Geiger::render( %arg );
    },
);

__PACKAGE__->register(
    kind    => 'heart',
    label   => 'Heartbeat',
    icon    => 'emote-love-symbolic',
    summary => 'Lub-dub, wandering the way a real one does',
    doc     => <<'DOC',
Two valve closures a beat, and the gap between them is shorter than the gap to
the next beat -- which is the difference between a heartbeat and a drum loop.
As the rate rises it is the pause that disappears rather than both gaps
shrinking together, which is why a fast one sounds urgent.

The rate wanders within a ceiling you set, at a pace you set, and stays
irregular at either extreme. It has no natural end.
DOC
    params   => GlitchVape::Heart::params(),
    order    => [ GlitchVape::Heart::param_order() ],
    duration => \&GlitchVape::Heart::duration,
    describe => \&GlitchVape::Heart::describe,
    resolve  => sub {
        my ( $spec ) = @_;
        return resolve_params( GlitchVape::Heart::params(), $spec );
    },
    render => sub {
        my ( %arg ) = @_;
        return GlitchVape::Heart::render( %arg );
    },
);

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Audio>, which mixes these under a cropped file, and
L<GlitchVape::Registry>, whose shape this borrows.

=cut
