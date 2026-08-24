package GlitchVape::Pipeline;

use strict;
use warnings;

use List::Util qw(any);

use GlitchVape::Registry ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Pipeline - ordered execution of a set of effects

=head1 DESCRIPTION

A pipeline is a resolved, validated, ordered list of effects with concrete
parameters. Construction does all the checking, so a render either fails
immediately with a useful message or runs to completion -- it never dies
forty seconds in because a preset had a typo in it.

=cut

=head2 new( %arg )

    effects => { name => \%params, ... }   what to run
    order   => [ names ]                   explicit override of stage order
    disable => [ names ]                   drop these regardless of the preset

An effect whose params include C<< enabled => 0 >> is skipped. That is how a
preset built on another can switch off something it inherited without having
to restate the whole chain.

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $effects = $arg{ effects } || {};
    my %disable = map { $_ => 1 } @{ $arg{ disable } || [] };

    my @steps;
    for my $name ( sort keys %$effects )
    {
        my $given = $effects->{ $name };
        $given = {} unless ref $given eq 'HASH';

        next if $disable{ $name };
        next if exists $given->{ enabled } && !_truthy( $given->{ enabled } );

        my $spec = GlitchVape::Registry->get( $name )
            or die "GlitchVape: unknown effect '$name'.\n"
            . "  Run with --list-effects to see what is available.\n";

        _check_requirements( $name, $spec );

        push @steps,
            {
            name   => $name,
            spec   => $spec,
            params => GlitchVape::Registry->resolve_params( $name, $given ),
            order  => _step_order( $given, $spec ),
            };
    }

    if ( my $explicit = $arg{ order } )
    {
        my %rank;
        $rank{ $explicit->[ $_ ] } = $_ for 0 .. $#$explicit;

        for my $s ( @steps )
        {
            # Effects absent from an explicit order keep their stage position,
            # offset past the listed ones so they still run last.
            $s->{ order } =
                exists $rank{ $s->{ name } }
                ? $rank{ $s->{ name } }
                : 1000 + $s->{ order };
        }

        for my $n ( @$explicit )
        {
            warn
                "GlitchVape: order mentions '$n', which is not enabled -- ignoring\n"
                unless any { $_->{ name } eq $n } @steps;
        }
    }

    @steps = sort {
               $a->{ order } <=> $b->{ order }
            || $a->{ name } cmp $b->{ name }
    } @steps;

    return bless { steps => \@steps }, $class;
}

=head2 run( $ctx )

Apply every step to the context's image, in order. Returns the context.

=cut

sub run
{
    my ( $self, $ctx ) = @_;

    for my $step ( @{ $self->{ steps } } )
    {
        $ctx->log( '%-16s %s', $step->{ name },
            _describe( $step->{ params } ) );

        $ctx->time_effect(
            $step->{ name },
            sub {
                local $@;
                my $ok = eval {
                    $step->{ spec }{ apply }->( $ctx, $step->{ params } );
                    1;
                };
                unless ( $ok )
                {
                    my $err = $@ || 'unknown error';
                    $err =~ s/\s+\z//;
                    die "GlitchVape: effect '$step->{name}' failed: $err\n";
                }
            }
        );
    }

    return $ctx;
}

=head2 steps()

The resolved step list, for C<--dry-run> and diagnostics.

=cut

sub steps { @{ $_[ 0 ]{ steps } } }

=head2 describe()

Multi-line human-readable rendering of the pipeline.

=cut

sub describe
{
    my $self = shift;
    my @out;
    for my $s ( $self->steps )
    {
        push @out,
            sprintf(
            '%2d. %-9s %-16s %s',
            scalar( @out ) + 1,
            $s->{ spec }{ stage },
            $s->{ name },
            _describe( $s->{ params } )
            );
    }
    return join "\n", @out;
}

# An effect normally runs at its declared stage. A preset may pin one to an
# explicit position by giving it an `order:` of its own, which wins.
sub _step_order
{
    my ( $given, $spec ) = @_;

    if ( defined $given->{ order } )
    {
        return $given->{ order };
    }

    return $spec->{ order };
}

sub _describe
{
    my ( $params ) = @_;
    return '-' unless $params && %$params;
    return join ' ', map { "$_=" . _flatten( $params->{ $_ } ) }
        sort keys %$params;
}

# List parameters print as a comma-separated value so one step fits on a line.
sub _flatten
{
    my ( $v ) = @_;
    return '' unless defined $v;
    return join ',', @$v if ref $v eq 'ARRAY';
    return $v;
}

sub _check_requirements
{
    my ( $name, $spec ) = @_;
    require GlitchVape::Tools;

    for my $tool ( @{ $spec->{ requires } } )
    {
        next if GlitchVape::Tools::have( $tool );
        GlitchVape::Tools::require_tool( $tool, "by effect '$name'" );
    }
    return;
}

sub _truthy
{
    my ( $v ) = @_;
    return 0 unless defined $v;
    return 0 if $v =~ /^(0|no|off|false|)$/i;
    return 1;
}

1;
