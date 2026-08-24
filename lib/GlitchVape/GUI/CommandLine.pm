package GlitchVape::GUI::CommandLine;

use strict;
use warnings;

# Loading the facade is what populates the effect registry, and the baseline
# below is meaningless without it.
use GlitchVape            ();
use GlitchVape::Audio     ();
use GlitchVape::Config    ();
use GlitchVape::Generator ();
use GlitchVape::Registry  ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::CommandLine - what you would have typed

=head1 DESCRIPTION

The interface claims to be a front end rather than a second implementation.
This is that claim made checkable: it turns the current state into the
F<glitchvape> invocation that produces the same render, which the menu copies
to the clipboard.

=head2 Only what differs

The state holds a concrete value for every parameter of every effect, because
a widget needs one. Emitting all of them would be correct and useless -- a
preset with nine effects is three hundred C<--set> flags, and nobody can read
that.

So the command is diffed against what C<-p PRESET> would produce on its own,
and only the differences are printed. That is shorter I<and> still exact:
C<--set> always wins over the file, so a parameter left out is a parameter the
preset already sets to that value.

The same goes for generated tracks, which are diffed against their declared
defaults.

=head2 What it cannot capture

The preview size, which is not a property of the render, and the mute button,
which is a property of the player. Both are deliberately absent: the command
is what produces the B<export>, and neither of those changes it.

=cut

=head2 format( %arg )

    state   => GlitchVape::GUI::State
    animate => { frames, fps, audio }   or undef
    output  => path                     or undef

One line of shell.

=cut

sub format
{
    my ( %arg ) = @_;

    my $state = $arg{ state } or return q{};

    my @argv = ( 'glitchvape' );

    my $preset = $state->preset;
    push @argv, '-p', $preset if defined $preset && length $preset;

    my $seed = $state->seed;
    push @argv, '-s', $seed if defined $seed && length $seed;

    push @argv, _effect_args( $state );
    push @argv, _animate_args( $arg{ animate } );

    push @argv, '-o', $arg{ output } if defined $arg{ output };
    push @argv, $state->source;

    return join q{ }, map { _quote( $_ ) } @argv;
}

# The effects, as the difference between the state and the preset it started
# from.
sub _effect_args
{
    my ( $state ) = @_;

    my $baseline = _baseline( $state->preset );
    my $effects  = $state->effects;

    my @argv;
    my %present;

    for my $name ( $state->effect_names )
    {
        $present{ $name } = 1;

        my $entry = $effects->{ $name };

        unless ( $entry->{ enabled } )
        {
            # Only worth switching off something the preset switched on.
            push @argv, '-d', $name if $baseline->{ $name };
            next;
        }

        # An effect the preset does not mention has to be enabled by hand,
        # which brings it in with its declared defaults -- so the parameters
        # to diff against are those defaults.
        my $from = $baseline->{ $name };

        unless ( $from )
        {
            push @argv, '-e', $name;
            $from = GlitchVape::Registry->resolve_params( $name, {} );
        }

        for my $key ( sort keys %{ $entry->{ params } } )
        {
            my $now = _flatten( $entry->{ params }{ $key } );
            my $was = _flatten( $from->{ $key } );

            next if $now eq $was;

            push @argv, '--set', "$name.$key=$now";
        }
    }

    # An effect the preset had and the user deleted outright is not in the
    # state at all, so it has to be found from the other side.
    for my $name ( sort keys %$baseline )
    {
        push @argv, '-d', $name unless $present{ $name };
    }

    return @argv;
}

# What -p PRESET alone would give, resolved through the registry so that it is
# comparable with the state -- which is resolved the same way when a preset is
# loaded.
sub _baseline
{
    my ( $preset ) = @_;

    return {} unless defined $preset && length $preset;

    local $@;
    my $config = eval { GlitchVape::Config::load( preset => $preset ) };
    return {} unless $config;

    my %out;

    for my $name ( keys %{ $config->{ effects } } )
    {
        my $given = $config->{ effects }{ $name };
        $given = {} unless ref $given eq 'HASH';

        next unless GlitchVape::Registry->get( $name );

        # An effect the preset switches off is not part of the baseline: the
        # command line would have to switch it on, not leave it alone.
        next if exists $given->{ enabled } && !_truthy( $given->{ enabled } );

        $out{ $name } = GlitchVape::Registry->resolve_params( $name, $given );
    }

    return \%out;
}

sub _animate_args
{
    my ( $spec ) = @_;

    return () unless $spec;

    my @argv = ( '--animate' );

    push @argv, '--frames', $spec->{ frames } if $spec->{ frames };
    push @argv, '--fps',    $spec->{ fps }    if $spec->{ fps };

    push @argv, _audio_args( $spec->{ audio } );

    return @argv;
}

sub _audio_args
{
    my ( $audio ) = @_;

    return () unless $audio;

    my @argv;

    if ( GlitchVape::Audio::has_file( $audio ) )
    {
        push @argv, '--audio', $audio->{ path };

        push @argv, '--audio-start', _number( $audio->{ start } )
            if $audio->{ start };
        push @argv, '--audio-end', _number( $audio->{ end } )
            if defined $audio->{ end };

        my $filters = $audio->{ filters } || {};
        for my $name ( GlitchVape::Audio::filter_names() )
        {
            next unless defined $filters->{ $name };
            push @argv, '--audio-filter',
                "$name=" . _number( $filters->{ $name } );
        }

        push @argv, '--audio-gain', _number( $audio->{ gain } )
            if defined $audio->{ gain } && $audio->{ gain } != 1;
    }

    for my $track ( GlitchVape::Audio::generated( $audio ) )
    {
        push @argv, _generated_args( $track );
    }

    return @argv;
}

# One generated track, diffed against its kind's declared defaults for the
# same reason the effects are diffed against the preset.
sub _generated_args
{
    my ( $track ) = @_;

    my $kind = $track->{ kind } or return ();

    my $declared = GlitchVape::Generator::get( $kind ) or return ();

    my @argv = ( '--generate', $kind );

    for my $name ( @{ $declared->{ order } } )
    {
        my $value = $track->{ $name };
        next unless defined $value && length $value;

        my $default = $declared->{ params }{ $name }{ default };
        next if defined $default && "$value" eq "$default";

        push @argv, '--gen', "$name=$value";
    }

    return @argv;
}

# ---------------------------------------------------------------------------

# Numbers come out of spin buttons as 12.000000; the command line should say
# 12. Trailing zeroes are noise, and a value that is not a number at all is
# passed through untouched.
sub _number
{
    my ( $value ) = @_;

    return $value unless defined $value;
    return $value unless $value =~ /^-?\d+(?:[.]\d+)?\z/;

    my $text = sprintf '%.6f', $value;
    $text =~ s/0+\z//;
    $text =~ s/[.]\z//;

    return $text;
}

sub _flatten
{
    my ( $value ) = @_;

    return q{} unless defined $value;
    return join ',', @$value if ref $value eq 'ARRAY';

    return "$value";
}

sub _truthy
{
    my ( $value ) = @_;

    return 0 unless defined $value;
    return 0 if $value =~ /^(?:0|no|off|false|)\z/i;

    return 1;
}

# Single quotes, because inside them a shell interprets nothing at all -- which
# is what a --set carrying Japanese, a '#' or a '$' needs. The only character
# that cannot appear inside them is the quote itself, and the usual dance ends
# the string, escapes one, and starts another.
sub _quote
{
    my ( $word ) = @_;

    $word = q{} unless defined $word;

    return $word if length $word && $word =~ m{\A[\w.,:=/+-]+\z};

    my $quoted = $word;
    $quoted =~ s/'/'\\''/g;

    return "'$quoted'";
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::State>, whose configuration this describes, and
L<glitchvape> for the flags it emits.

=cut
