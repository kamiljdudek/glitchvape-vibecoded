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

# A GUI module like this one, so loading it here costs nothing the interface
# was not going to pay anyway -- and loading it lazily instead would pull Gtk3
# in after INIT, which Glib's introspection complains about.
use GlitchVape::GUI::Export ();

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

=head2 Two shapes of the same command

C<format> returns one line, which is what goes on the clipboard. C<< wrap => 1
>> returns the same words broken across lines with a backslash at the end of
each, which is what a dialog can show without a horizontal scrollbar.

The break points are not a column count. Each line is one flag and the value
that belongs to it, so every line is a complete thought and the whole thing is
still one command -- pasting it into a shell runs it, and deleting a line from
the middle removes exactly one setting rather than corrupting the syntax.

=cut

# How a wrapped command is indented under its own first line. Four spaces:
# enough to see that the continuations belong to the line above, not so much
# that a long --set runs out of room.
use constant INDENT => '    ';

=head2 format( %arg )

    state   => GlitchVape::GUI::State
    animate => { frames, fps, audio }   or undef
    export  => GlitchVape::GUI::Export settings   or undef
    output  => path                     or undef
    wrap    => 1                        break across lines

One line of shell, or several joined by backslashes.

=cut

sub format
{
    my ( %arg ) = @_;

    my @groups = _groups( %arg ) or return q{};

    my @lines = map {
        join q{ },
            map { _quote( $_ ) }
            @$_
    } @groups;

    return join q{ }, @lines unless $arg{ wrap };

    my $first = shift @lines;

    return join " \\\n" . INDENT, $first, @lines;
}

# The command as a list of groups, one per line of the wrapped form. A group
# is a flag with its value, so that neither shape has to know how the other
# breaks: the one-line form joins them all with spaces and the wrapped form
# joins them with backslashes.
sub _groups
{
    my ( %arg ) = @_;

    my $state = $arg{ state } or return ();

    my @groups = ( [ 'glitchvape' ] );

    my $preset = $state->preset;
    push @groups, [ '-p', $preset ] if defined $preset && length $preset;

    my $seed = $state->seed;
    push @groups, [ '-s', $seed ] if defined $seed && length $seed;

    push @groups, _effect_args( $state );
    push @groups, _animate_args( $arg{ animate } );
    push @groups, _export_args( $arg{ export }, $arg{ animate } );

    push @groups, [ '-o', $arg{ output } ] if defined $arg{ output };

    # The source is a positional and has to be last, which is also why it is a
    # group of its own: appended to whatever came before, it would read as
    # that flag's argument.
    push @groups, [ $state->source ];

    return @groups;
}

# The effects, as the difference between the state and the preset it started
# from.
sub _effect_args
{
    my ( $state ) = @_;

    my $baseline = _baseline( $state->preset );
    my $effects  = $state->effects;

    my @groups;
    my %present;

    for my $name ( $state->effect_names )
    {
        $present{ $name } = 1;

        my $entry = $effects->{ $name };

        unless ( $entry->{ enabled } )
        {
            # Only worth switching off something the preset switched on.
            push @groups, [ '-d', $name ] if $baseline->{ $name };
            next;
        }

        # An effect the preset does not mention has to be enabled by hand,
        # which brings it in with its declared defaults -- so the parameters
        # to diff against are those defaults.
        my $from = $baseline->{ $name };

        unless ( $from )
        {
            push @groups, [ '-e', $name ];
            $from = GlitchVape::Registry->resolve_params( $name, {} );
        }

        for my $key ( sort keys %{ $entry->{ params } } )
        {
            my $now = _flatten( $entry->{ params }{ $key } );
            my $was = _flatten( $from->{ $key } );

            next if $now eq $was;

            push @groups, [ '--set', "$name.$key=$now" ];
        }
    }

    # An effect the preset had and the user deleted outright is not in the
    # state at all, so it has to be found from the other side.
    for my $name ( sort keys %$baseline )
    {
        push @groups, [ '-d', $name ] unless $present{ $name };
    }

    return @groups;
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

    my @groups = ( [ '--animate' ] );

    push @groups, [ '--frames', $spec->{ frames } ] if $spec->{ frames };
    push @groups, [ '--fps',    $spec->{ fps } ]    if $spec->{ fps };

    push @groups, _audio_args( $spec->{ audio } );

    return @groups;
}

# What the export settings add. Only the ones that apply to what is actually
# being written: a codec means nothing to a still and a palette means nothing
# to a video, and printing either where it does not belong would be a command
# that says more than it does.
#
# Native size prints no --max-dim at all, which is the honest spelling of it:
# the flag's absence is what leaves the preset's own limit standing.
sub _export_args
{
    my ( $settings, $animate ) = @_;

    return () unless $settings;

    my %opt = GlitchVape::GUI::Export::render_options( $settings, $animate );

    my @groups;

    push @groups, [ '--max-dim', $opt{ max_dim } ] if $opt{ max_dim };
    push @groups, [ '--colors',  $opt{ colors } ]  if $opt{ colors };
    push @groups, [ '--fit', join 'x', @{ $opt{ fit } } ] if $opt{ fit };

    # H.264 in an .mp4 is what the extension already says, so naming it would
    # be noise. The others are exactly what the extension cannot say.
    push @groups, [ '--codec', $opt{ codec } ]
        if $opt{ codec } && $opt{ codec } ne 'h264';

    return @groups;
}

sub _audio_args
{
    my ( $audio ) = @_;

    return () unless $audio;

    my @groups;

    if ( GlitchVape::Audio::has_file( $audio ) )
    {
        push @groups, [ '--audio', $audio->{ path } ];

        push @groups, [ '--audio-start', _number( $audio->{ start } ) ]
            if $audio->{ start };
        push @groups, [ '--audio-end', _number( $audio->{ end } ) ]
            if defined $audio->{ end };

        my $filters = $audio->{ filters } || {};
        for my $name ( GlitchVape::Audio::filter_names() )
        {
            next unless defined $filters->{ $name };
            push @groups,
                [ '--audio-filter', "$name=" . _number( $filters->{ $name } ) ];
        }

        push @groups, [ '--audio-gain', _number( $audio->{ gain } ) ]
            if defined $audio->{ gain } && $audio->{ gain } != 1;
    }

    for my $track ( GlitchVape::Audio::generated( $audio ) )
    {
        push @groups, _generated_args( $track );
    }

    return @groups;
}

# One generated track, diffed against its kind's declared defaults for the
# same reason the effects are diffed against the preset.
sub _generated_args
{
    my ( $track ) = @_;

    my $kind = $track->{ kind } or return ();

    my $declared = GlitchVape::Generator::get( $kind ) or return ();

    my @groups = ( [ '--generate', $kind ] );

    for my $name ( @{ $declared->{ order } } )
    {
        my $value = $track->{ $name };
        next unless defined $value && length $value;

        my $default = $declared->{ params }{ $name }{ default };
        next if defined $default && "$value" eq "$default";

        push @groups, [ '--gen', "$name=$value" ];
    }

    return @groups;
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
