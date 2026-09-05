package GlitchVape::GUI::State;

use strict;
use warnings;

use GlitchVape::Config   ();
use GlitchVape::Registry ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::State - the edited configuration, and its undo history

=head1 WHY UNDO IS OVER THE CONFIGURATION

The obvious implementation of undo for an image editor is a stack of bitmaps:
apply an effect to what is on screen, keep the previous frame, restore it on
undo. That is wrong here, for two reasons that are properties of the pipeline
rather than of this module.

Effects declare a B<stage> and L<GlitchVape::Pipeline> sorts by it, because
order is not a free choice -- scanlines applied before a downsample are eaten
by the resample. Stacking renders would run each effect at the moment the user
enabled it, so enabling C<downsample> after C<scanlines> would resample the
scanlines away. The pipeline exists to prevent exactly that.

L<GlitchVape::Context/rng_for> also gives each effect a derived random stream
so that adding one effect does not disturb any other. Applying effects
incrementally would break that guarantee, and the same seed would stop
reproducing the same image -- so the preview would no longer agree with what
the command-line tool produces.

So an undo step here is a whole configuration, and every state renders from
the source. That costs a re-render, which is what
L<GlitchVape::GUI::Cache> exists to avoid paying twice: a state on the undo
stack has been rendered before, so stepping back through it is a file lookup.

=head1 SHAPE

    {
        source  => path to the input image,
        preset  => preset name or undef,
        seed    => scalar,
        effects => {
            scanlines => { enabled => 1, params => { opacity => 0.3, ... } },
            ...
        },
    }

C<params> is always complete: every parameter the effect declares, resolved
through the registry, so a widget can be built for each without consulting
defaults a second time.

=cut

=head2 new( %arg )

    source => path       the image being edited
    seed   => scalar     omit for a random one

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $seed = $arg{ seed };
    if ( !defined $seed )
    {
        $seed = int rand 2**31;
    }

    my $self = bless {
        current => {
            source  => $arg{ source },
            preset  => undef,
            seed    => $seed,
            effects => {},
        },
        undo => [],
        redo => [],
    }, $class;

    return $self;
}

# Read/write accessors on the current state. Called with an argument they set,
# called bare they read.
sub source
{
    my ( $self, $value ) = @_;

    if ( @_ > 1 )
    {
        $self->{ current }{ source } = $value;
    }

    return $self->{ current }{ source };
}

sub seed
{
    my ( $self, $value ) = @_;

    if ( @_ > 1 )
    {
        $self->{ current }{ seed } = $value;
    }

    return $self->{ current }{ seed };
}

sub preset
{
    my ( $self, $value ) = @_;

    if ( @_ > 1 )
    {
        $self->{ current }{ preset } = $value;
    }

    return $self->{ current }{ preset };
}

sub effects { $_[ 0 ]{ current }{ effects } }

=head2 effect_names()

Names of every effect in the state -- enabled or not -- in pipeline order, so
the interface lists them in the order they will actually run.

=cut

sub effect_names
{
    my ( $self ) = @_;

    my $effects = $self->{ current }{ effects };
    my @known   = grep { $effects->{ $_ } } GlitchVape::Registry->names;

    return @known;
}

=head2 enabled( $name, $value )

Read or set whether one effect runs.

=cut

sub enabled
{
    my ( $self, $name, $value ) = @_;

    my $entry = $self->{ current }{ effects }{ $name } or return 0;

    if ( @_ > 2 )
    {
        $entry->{ enabled } = 0;
        if ( $value )
        {
            $entry->{ enabled } = 1;
        }
    }

    return $entry->{ enabled };
}

=head2 animated( $name, $value )

Read or set whether one effect's animation settings are in force. On by
default, and only meaningful for an effect that declares any.

Off, the effect still runs and still looks as it is set: what goes is the
motion, because C<effect_params> hands the pipeline the declared value for
every animation parameter instead of the held one. The held values stay where
they are, so switching it back on restores the motion exactly -- which is the
whole difference between this and dragging four sliders to nought.

=cut

sub animated
{
    my ( $self, $name, $value ) = @_;

    my $entry = $self->{ current }{ effects }{ $name } or return 0;

    if ( @_ > 2 )
    {
        $entry->{ animated } = $value ? 1 : 0;
    }

    return $entry->{ animated } // 1;
}

=head2 effect_params( $name )

One effect's values as they will actually render -- which is what it holds,
unless its animation has been switched off, in which case every parameter that
only means anything in a loop comes back at its declared value.

Everything that turns the state into a render goes through here: the preview,
the export, the cache key, a saved preset and the copied command line. One
accessor rather than the flag being consulted in six places, because a picture
that differed from the command line printed beside it would be the one thing
the interface promises cannot happen.

=cut

sub effect_params
{
    my ( $self, $name ) = @_;

    my $entry  = $self->{ current }{ effects }{ $name } or return {};
    my $params = $entry->{ params } || {};

    return { %$params } if $entry->{ animated } // 1;

    return GlitchVape::Registry->without_animation( $name, $params );
}

=head2 param( $effect, $key, $value )

Read or set one parameter. Setting runs the value through the registry's
coercion, so a slider handing back C<0.30000000000000004> is stored as the
number the effect will actually see and the cache key stays stable.

=cut

sub param
{
    my ( $self, $effect, $key, $value ) = @_;

    my $entry = $self->{ current }{ effects }{ $effect } or return undef;

    if ( @_ > 3 )
    {
        my $resolved = GlitchVape::Registry->resolve_params( $effect,
            { %{ $entry->{ params } }, $key => $value } );
        $entry->{ params } = $resolved;
    }

    return $entry->{ params }{ $key };
}

=head2 add_effect( $name )

Put an effect into the state with its declared defaults, switched on. Adding
one that is already present just switches it on rather than discarding the
parameters the user had set.

=cut

sub add_effect
{
    my ( $self, $name ) = @_;

    GlitchVape::Registry->get( $name )
        or die "GlitchVape: unknown effect '$name'\n";

    my $effects = $self->{ current }{ effects };

    if ( $effects->{ $name } )
    {
        $effects->{ $name }{ enabled } = 1;
        return $effects->{ $name };
    }

    $effects->{ $name } = {
        enabled => 1,
        params  => GlitchVape::Registry->resolve_params( $name, {} ),
    };

    return $effects->{ $name };
}

=head2 remove_effect( $name )

Drop an effect from the state entirely, as distinct from switching it off.

=cut

sub remove_effect
{
    my ( $self, $name ) = @_;
    delete $self->{ current }{ effects }{ $name };
    return;
}

=head2 load_preset( $name )

Replace the effect set with a preset's, resolved through
L<GlitchVape::Config> so that C<extends> has already been applied. An effect
the preset switched off is kept in the state but disabled, which is what makes
it visible in the interface as something that can be switched back on.

=cut

sub load_preset
{
    my ( $self, $name ) = @_;

    my $config = GlitchVape::Config::load( preset => $name );

    my %effects;
    for my $ename ( keys %{ $config->{ effects } } )
    {
        my $given = $config->{ effects }{ $ename };
        $given = {} unless ref $given eq 'HASH';

        # An unknown effect in a hand-edited preset should not take the whole
        # interface down; report it and carry on with the rest.
        unless ( GlitchVape::Registry->get( $ename ) )
        {
            warn "GlitchVape: preset '$name' names unknown effect "
                . "'$ename' -- ignoring\n";
            next;
        }

        my $enabled = 1;
        if ( exists $given->{ enabled } && !_truthy( $given->{ enabled } ) )
        {
            $enabled = 0;
        }

        $effects{ $ename } = {
            enabled => $enabled,
            params  => GlitchVape::Registry->resolve_params( $ename, $given ),
        };
    }

    $self->{ current }{ effects } = \%effects;
    $self->{ current }{ preset }  = $name;

    if ( defined $config->{ seed } )
    {
        $self->{ current }{ seed } = $config->{ seed };
    }

    return $self;
}

=head1 HISTORY

=head2 clone()

A detached copy of the current configuration, with no history of its own.

Used by the effect wizard, which needs to render "the pipeline as it stands,
plus the effect being dialled in" without that half-finished effect ever
touching the state the window is editing. Because the copy renders through the
same C<cache_key>, a preview the wizard has already produced comes straight
back off disk.

=cut

sub clone
{
    my ( $self ) = @_;

    my $copy = ref( $self )->new(
        source => $self->{ current }{ source },
        seed   => $self->{ current }{ seed },
    );

    $copy->{ current } = _clone( $self->{ current } );

    return $copy;
}

=head2 commit()

Push the current state onto the undo stack. Called when the user applies a
change, so one undo step is one Apply rather than one slider movement --
otherwise dragging a slider would bury the previous look under fifty
indistinguishable entries.

Returns true when something was actually recorded. A commit identical to the
top of the stack is dropped, so pressing Apply twice does not produce an undo
step that appears to do nothing.

=cut

sub commit
{
    my ( $self ) = @_;

    my $snapshot = _clone( $self->{ current } );
    my $top      = $self->{ undo }[ -1 ];

    if ( $top && _digest( $top ) eq _digest( $snapshot ) )
    {
        return 0;
    }

    push @{ $self->{ undo } }, $snapshot;

    # A new edit invalidates the redo branch: there is no longer a coherent
    # "forward" from here.
    @{ $self->{ redo } } = ();

    return 1;
}

=head2 undo()

Step back one applied state. Returns true if it moved.

The stack holds committed states including the present one, so undoing means
moving the top entry across to the redo stack and adopting what is underneath.

=cut

sub undo
{
    my ( $self ) = @_;

    return 0 unless $self->can_undo;

    my $present = pop @{ $self->{ undo } };
    push @{ $self->{ redo } }, $present;

    $self->{ current } = _clone( $self->{ undo }[ -1 ] );

    return 1;
}

=head2 redo()

Step forward again. Returns true if it moved.

=cut

sub redo
{
    my ( $self ) = @_;

    return 0 unless $self->can_redo;

    my $next = pop @{ $self->{ redo } };
    push @{ $self->{ undo } }, $next;

    $self->{ current } = _clone( $next );

    return 1;
}

=head2 can_undo() / can_redo()

Whether the corresponding step would move. The interface uses these to set
button sensitivity.

=cut

sub can_undo { return @{ $_[ 0 ]{ undo } } > 1 }
sub can_redo { return scalar @{ $_[ 0 ]{ redo } } }

=head2 depth()

C<< ( undo_steps, redo_steps ) >>, for the status bar.

=cut

sub depth
{
    my ( $self ) = @_;
    my $back = @{ $self->{ undo } } - 1;
    $back = 0 if $back < 0;
    return ( $back, scalar @{ $self->{ redo } } );
}

=head1 RENDERING

=head2 render_args()

Arguments for L<GlitchVape/render>, in exactly the form the command-line tool
builds them: a preset name plus C<set>, C<enable> and C<disable> lists. Export
passes these straight to C<GlitchVape::render>, which is the same entry point
F<bin/glitchvape> uses -- so an exported file is not merely similar to what the
CLI would produce from the same settings, it goes through the same code.

=cut

sub render_args
{
    my ( $self, %extra ) = @_;

    my $effects = $self->{ current }{ effects };

    my @overrides;
    my @enable;
    my @disable;

    for my $name ( $self->effect_names )
    {
        unless ( $effects->{ $name }{ enabled } )
        {
            push @disable, $name;
            next;
        }

        push @enable, $name;

        my $params = $self->effect_params( $name );
        for my $key ( sort keys %$params )
        {
            push @overrides, "$name.$key=" . _flatten( $params->{ $key } );
        }
    }

    # An effect the preset defines but the state no longer holds was removed
    # outright, and saying nothing about it is not enough: the preset would
    # put it back. The preview drops it -- pipeline_config is built from what
    # the state has -- so without this the export renders something the
    # preview never showed.
    my %present = map { $_ => 1 } $self->effect_names;

    for my $name ( $self->_preset_effects )
    {
        push @disable, $name unless $present{ $name };
    }

    return (
        input   => $self->{ current }{ source },
        preset  => $self->{ current }{ preset },
        seed    => $self->{ current }{ seed },
        set     => \@overrides,
        enable  => \@enable,
        disable => \@disable,
        %extra,
    );
}

# Which effects the current preset names. Read from the file rather than
# remembered when it was loaded, so that it stays right across an undo -- the
# history holds configurations, not the provenance of each one.
sub _preset_effects
{
    my ( $self ) = @_;

    my $preset = $self->{ current }{ preset };
    return () unless defined $preset && length $preset;

    local $@;
    my $config = eval { GlitchVape::Config::load( preset => $preset ) };
    return () unless $config;

    my @names = sort keys %{ $config->{ effects } || {} };
    return @names;
}

=head2 pipeline_config()

The resolved C<< { effects, order, disable } >> for building a
L<GlitchVape::Pipeline> directly, which is what the preview path does: it
already holds concrete values, so it has no reason to round-trip them through
string overrides and back.

=cut

sub pipeline_config
{
    my ( $self ) = @_;

    my $effects = $self->{ current }{ effects };
    my %out;
    my @disable;

    for my $name ( $self->effect_names )
    {
        unless ( $effects->{ $name }{ enabled } )
        {
            push @disable, $name;
            next;
        }
        $out{ $name } = $self->effect_params( $name );
    }

    return { effects => \%out, order => undef, disable => \@disable };
}

=head2 cache_key( %arg )

    size    => N                      render dimension
    animate => { frames, fps, audio } when previewing a loop

A digest of everything that determines the resulting image. The source file's
size and modification time are folded in as well, so editing the input outside
the application does not serve a preview of its previous contents.

=cut

sub cache_key
{
    my ( $self, %arg ) = @_;

    require GlitchVape::GUI::Cache;

    my $source = $self->{ current }{ source };
    my @stat   = stat( $source // q{} );

    my @parts = (
        'glitchvape-preview-v1', $source,
        $stat[ 7 ],
        $stat[ 9 ],
        $self->{ current }{ seed },
        $arg{ size },
    );

    # Anything the caller says also changes the picture. The watermark is the
    # first of these: it is not part of the configuration, so nothing else
    # here would notice it, and a preview keyed without it hands back the
    # unmarked render.
    push @parts, @{ $arg{ extra } } if $arg{ extra };

    if ( my $spec = $arg{ animate } )
    {
        push @parts, 'animate', $spec->{ frames }, $spec->{ fps };

        # An added track changes the encoded file even though it changes no
        # frame, and it changes its length as well, so it has to be in the
        # key -- otherwise switching tracks serves the previous one back.
        if ( $spec->{ audio } )
        {
            require GlitchVape::Audio;
            push @parts, GlitchVape::Audio::spec_parts( $spec->{ audio } );
        }
    }

    my $effects = $self->{ current }{ effects };
    for my $name ( $self->effect_names )
    {
        next unless $effects->{ $name }{ enabled };
        push @parts, $name;

        my $params = $self->effect_params( $name );
        for my $key ( sort keys %$params )
        {
            push @parts, $key, _flatten( $params->{ $key } );
        }
    }

    return GlitchVape::GUI::Cache->key( @parts );
}

=head2 summary()

One line naming the enabled effects, for the status bar.

=cut

sub summary
{
    my ( $self ) = @_;

    my @on = grep { $self->{ current }{ effects }{ $_ }{ enabled } }
        $self->effect_names;

    return 'no effects' unless @on;
    return join ' > ', @on;
}

=head2 to_preset_yaml( %arg )

    name  => preset name
    title => one-line description

The current state as a preset file. Written by hand rather than through a YAML
dumper so the result reads like the presets in the repository -- one effect per
block, parameters sorted, disabled effects kept with C<enabled: 0> so the file
documents what was deliberately switched off.

=cut

sub to_preset_yaml
{
    my ( $self, %arg ) = @_;

    my $name  = $arg{ name }  // 'untitled';
    my $title = $arg{ title } // q{};

    my @lines = ( "name: $name" );
    push @lines, 'title: ' . _yaml_scalar( $title ) if length $title;
    push @lines, "seed: $self->{current}{seed}"
        if defined $self->{ current }{ seed } && $arg{ keep_seed };
    push @lines, q{}, 'effects:';

    my $effects = $self->{ current }{ effects };

    for my $ename ( $self->effect_names )
    {
        push @lines, "  $ename:";

        unless ( $effects->{ $ename }{ enabled } )
        {
            push @lines, '    enabled: 0';
            next;
        }

        # What it would render, not what it holds: a preset is a look, and
        # an effect whose motion is switched off looks like one that was
        # never given any.
        my $params = $self->effect_params( $ename );
        for my $key ( sort keys %$params )
        {
            push @lines,
                "    $key: " . _yaml_scalar( _flatten( $params->{ $key } ) );
        }
    }

    return join( "\n", @lines ) . "\n";
}

# ---------------------------------------------------------------------------

# List parameters travel as comma-separated text, which is the form
# Registry's 'list' coercion parses back.
sub _flatten
{
    my ( $v ) = @_;

    return q{} unless defined $v;
    return join ',', @$v if ref $v eq 'ARRAY';
    return $v;
}

# Quote anything YAML would otherwise reinterpret: a leading '#' or '#RRGGBB'
# colour, a value that looks like a number but is meant as text, the empty
# string, and anything carrying a character with structural meaning.
sub _yaml_scalar
{
    my ( $v ) = @_;

    $v = q{} unless defined $v;

    return "''" unless length $v;

    if ( $v =~ /^[A-Za-z0-9_.\/-]+$/ && $v !~ /^-/ )
    {
        return $v;
    }

    my $quoted = $v;
    $quoted =~ s/'/''/g;
    return "'$quoted'";
}

sub _truthy
{
    my ( $v ) = @_;

    return 0 unless defined $v;
    return 0 if $v =~ /^(0|no|off|false|)$/i;
    return 1;
}

# Deep copy of the two levels the state actually has. Written out rather than
# pulled from Storable because the structure is known and shallow, and because
# a snapshot must not carry blessed references into the history.
sub _clone
{
    my ( $state ) = @_;

    my %effects;
    for my $name ( keys %{ $state->{ effects } } )
    {
        my $entry  = $state->{ effects }{ $name };
        my %params = %{ $entry->{ params } };

        for my $key ( keys %params )
        {
            if ( ref $params{ $key } eq 'ARRAY' )
            {
                $params{ $key } = [ @{ $params{ $key } } ];
            }
        }

        $effects{ $name } = {
            enabled  => $entry->{ enabled },
            animated => $entry->{ animated } // 1,
            params   => \%params,
        };
    }

    return {
        source  => $state->{ source },
        preset  => $state->{ preset },
        seed    => $state->{ seed },
        effects => \%effects,
    };
}

# Snapshots are compared by content so that an Apply which changed nothing does
# not add a history step. Built the same way as the cache key, minus the
# render size, which is not part of the configuration.
sub _digest
{
    my ( $state ) = @_;

    my @parts = ( $state->{ source }, $state->{ preset }, $state->{ seed } );

    for my $name ( sort keys %{ $state->{ effects } } )
    {
        my $entry = $state->{ effects }{ $name };
        push @parts, $name, $entry->{ enabled }, $entry->{ animated } // 1;

        for my $key ( sort keys %{ $entry->{ params } } )
        {
            push @parts, $key, _flatten( $entry->{ params }{ $key } );
        }
    }

    require GlitchVape::GUI::Cache;
    return GlitchVape::GUI::Cache->key( @parts );
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Pipeline> for the stage ordering this design follows from, and
L<GlitchVape::GUI::Cache> for what makes stepping through the history cheap.

=cut
