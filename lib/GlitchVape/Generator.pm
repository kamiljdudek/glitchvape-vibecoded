package GlitchVape::Generator;

use strict;
use warnings;

use GlitchVape::Plugins  ();
use GlitchVape::Registry ();

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

# How many kinds have registered, so that ties in the order below go to
# whichever came first.
my $SEQ = 0;

# The kinds that ship with the program, as the modules that declare them, in
# the order the interface offers them. Each module registers its own kind as
# it loads -- the end of this file loads them -- so this list is what gets
# loaded as well as where each goes.
#
# The order cannot simply be the order of registration, which is what it used
# to be. Loading one of these modules first loads this one, which loads the
# other four, which register before the one that started it all -- so the
# order would depend on which module somebody happened to mention first.
my @BUILTIN = qw(
    GlitchVape::DTMF
    GlitchVape::Noise
    GlitchVape::Geiger
    GlitchVape::Heart
    GlitchVape::Drive
);

# Everything a kind may declare; a key outside these is a typo, refused for
# the reason GlitchVape::Registry refuses one in an effect.
my %KIND_KEY = map { $_ => 1 } qw(
    kind label icon summary doc ending params order
    resolve duration describe render readout
);

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
    readout  => sub { my ( $spec ) = @_ }      what the dialog shows it will do

C<kind>, C<label>, C<params>, C<duration> and C<render> are required.
C<resolve> defaults to L</resolve_params> over C<params>, which is what four of
the five kinds that ship would otherwise write out by hand. C<order> defaults
to L<GlitchVape::Registry/sorted_params>, and when given has to name every
parameter exactly once -- one it leaves out gets no control in the dialog,
which is how a declaration missing a key used to become a window with no
controls in it and no error anywhere.

A kind registered twice is refused, as an effect is: the second registration
used to replace the first in silence.

=cut

sub register
{
    my ( $class, %spec ) = @_;

    my $kind = $spec{ kind } // q{};

    die "GlitchVape::Generator: a kind needs a name\n" unless length $kind;

    die "GlitchVape::Generator: kind '$kind' must be lower case letters, "
        . "digits and underscores, starting with a letter\n"
        unless $kind =~ GlitchVape::Registry::NAME;

    if ( my $had = $KIND{ $kind } )
    {
        my $whose = 'the program itself';
        $whose = "plug-in $had->{plugin}" if defined $had->{ plugin };

        die "GlitchVape::Generator: kind '$kind' registered twice -- $whose "
            . "already has it\n";
    }

    my @odd = grep { !$KIND_KEY{ $_ } } sort keys %spec;
    die "GlitchVape::Generator: kind '$kind' declares "
        . join( ', ', map { "'$_'" } @odd )
        . ', which means nothing here. Known: '
        . join( ', ', sort keys %KIND_KEY ) . "\n"
        if @odd;

    die "GlitchVape::Generator: kind '$kind' has no label\n"
        unless defined $spec{ label } && length $spec{ label };

    for my $code ( qw(duration render) )
    {
        die "GlitchVape::Generator: kind '$kind' has no $code coderef\n"
            unless ref $spec{ $code } eq 'CODE';
    }

    for my $code ( qw(resolve describe readout) )
    {
        die "GlitchVape::Generator: kind '$kind' declares a $code that is "
            . "not a coderef\n"
            if defined $spec{ $code } && ref $spec{ $code } ne 'CODE';
    }

    my $params = $spec{ params };
    die "GlitchVape::Generator: kind '$kind' declares no params\n"
        unless defined $params;

    GlitchVape::Registry::check_params( 'GlitchVape::Generator', $kind,
        $params );

    $spec{ order } = _checked_order( $kind, $params, $spec{ order } );

    $spec{ resolve } //= sub {
        my ( $given ) = @_;
        return resolve_params( $params, $given );
    };

    $spec{ plugin } = GlitchVape::Plugins::owner( scalar caller );
    $spec{ module } = scalar caller;
    $spec{ seq }    = $SEQ++;

    $KIND{ $kind } = \%spec;

    return $kind;
}

sub _checked_order
{
    my ( $kind, $params, $order ) = @_;

    return [ GlitchVape::Registry::sorted_params( $params ) ]
        unless defined $order;

    die "GlitchVape::Generator: kind '$kind' gives its order as something "
        . "other than a list\n"
        unless ref $order eq 'ARRAY';

    my %count;
    $count{ $_ }++ for @$order;

    my @unknown = grep { !$params->{ $_ } } sort keys %count;
    my @twice   = grep { $count{ $_ } > 1 } sort keys %count;
    my @missing = grep { !$count{ $_ } } sort keys %$params;

    my @wrong;
    push @wrong,
        'names ' . join( ', ', @unknown ) . ', which it does not declare'
        if @unknown;
    push @wrong, 'names ' . join( ', ', @twice ) . ' more than once' if @twice;
    push @wrong, 'leaves out ' . join( ', ', @missing ) if @missing;

    die "GlitchVape::Generator: kind '$kind' has an order that "
        . join( '; ', @wrong ) . "\n"
        if @wrong;

    return [ @$order ];
}

=head2 retract( $plugin ) / contributions( $plugin )

A plug-in's kinds, taken back or listed -- the two questions
L<GlitchVape::Plugins> asks every place a plug-in can add to.

=cut

sub retract
{
    my ( $class, $plugin ) = @_;

    delete @KIND{ _from( $plugin ) };

    return;
}

sub contributions
{
    my ( $class, $plugin ) = @_;

    return { 'soundtrack kinds' => [ _from( $plugin ) ] };
}

sub _from
{
    my ( $plugin ) = @_;

    my @kinds = sort grep {
        defined $KIND{ $_ }{ plugin } && $KIND{ $_ }{ plugin } eq $plugin
    } keys %KIND;

    return @kinds;
}

=head2 plugin( $kind )

The plug-in a kind came from, or undef for one of the program's own.

=cut

sub plugin
{
    my ( $kind ) = @_;
    $kind = $_[ 1 ] if ( $kind // q{} ) eq __PACKAGE__;

    my $declared = get( $kind ) or return undef;
    return $declared->{ plugin };
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

The registered kinds -- the program's own in a fixed order, then each
plug-in's -- one declaration, and the lot.

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

sub kinds
{
    my %rank;
    @rank{ @BUILTIN } = 0 .. $#BUILTIN;

    # The program's own in the order @BUILTIN gives, then each plug-in's in
    # the order it registered them, plug-ins sorted by name.
    my %by;
    for my $kind ( keys %KIND )
    {
        my $declared = $KIND{ $kind };

        $by{ $kind } = [
            $rank{ $declared->{ module } } // scalar @BUILTIN,
            $declared->{ plugin } // q{},
            $declared->{ seq },
        ];
    }

    my @kinds = sort {
               $by{ $a }[ 0 ] <=> $by{ $b }[ 0 ]
            || $by{ $a }[ 1 ] cmp $by{ $b }[ 1 ]
            || $by{ $a }[ 2 ] <=> $by{ $b }[ 2 ]
    } keys %KIND;

    return @kinds;
}

sub get { return $KIND{ $_[ 0 ] // q{} } }
sub all { return { %KIND } }

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

    # A plug-in's kind is its code as well as its settings: an upgraded
    # plug-in makes a different sound from the same values, and a key that
    # did not say so would serve the old one back. The program's own add
    # nothing here, so no key that worked before this changes.
    if ( my $plugin = plugin( $kind ) )
    {
        push @parts, GlitchVape::Plugins::fingerprint( $plugin ) // $plugin;
    }

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
# The kinds that ship. Each registers itself as it loads; @BUILTIN says why
# the list is here rather than whatever happened to load first.

for my $module ( @BUILTIN )
{
    ( my $file = "$module.pm" ) =~ s{::}{/}g;
    require $file;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Audio>, which mixes these under a cropped file, and
L<GlitchVape::Registry>, whose shape this borrows.

=cut
