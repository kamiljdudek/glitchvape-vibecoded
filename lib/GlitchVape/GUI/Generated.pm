package GlitchVape::GUI::Generated;

use strict;
use warnings;

# Literal '·' in the readout. See the note in GlitchVape::GUI.
use utf8;

use POSIX ();

use Glib ();
use Gtk3 ();

use GlitchVape::Audio       ();
use GlitchVape::Generator   ();
use GlitchVape::GUI::Params ();
use GlitchVape::GUI::Player ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Generated - the add-a-generated-track dialog

=head1 DESCRIPTION

One dialog for every kind of generated track, because it does not know what
any of them are. It is told which kind it is -- by the popover for a new
track, by the track itself for an existing one -- and the controls are then
built by L<GlitchVape::GUI::Params> from that kind's parameter declaration,
the same declaration that produces C<--gen>'s validation and
C<--list-generators>' output.

So a third generator is one C<register> call and appears here without this
file being touched, in exactly the way an effect added to
L<GlitchVape::Registry> appears in the left pane.

=head2 Why the kind is chosen before the window opens

A combo at the top of this dialog would be the wrong place for it: the kind
decides what every other control in the window is, so changing it would
rebuild the whole dialog underneath the pointer. Asking first and configuring
afterwards means the window that opens is already the right one, and its title
says which.

=head2 Auditioning

Synthesis is pure Perl and fast -- a sentence dialled out takes about thirty
milliseconds -- so Play renders and plays without needing a child process to
stay off the main loop.

The exception is length: static will happily generate ten minutes, and ten
minutes is several seconds of arithmetic. So an audition is capped, and a
track longer than the cap is heard from the beginning rather than in full.
Nothing is lost by that -- it is a preview of a texture, not of an
arrangement.

=cut

# Long enough to judge a texture by, short enough that no plausible generator
# takes a noticeable time to produce it.
use constant AUDITION_CAP => 20;

=head2 run( %arg )

    parent  => Gtk3::Window
    cache   => GlitchVape::GUI::Cache
    kind    => which generator to configure
    spec    => an existing generated track to reopen, or undef
    on_done => sub { my ( $spec ) = @_ }

Runs the dialog. Calls C<on_done> with a track spec if the user accepted.

=cut

sub run
{
    my ( $class, %arg ) = @_;

    my $spec = $arg{ spec } || {};

    my $self = bless {
        parent   => $arg{ parent },
        cache    => $arg{ cache },
        on_done  => $arg{ on_done },
        on_error => $arg{ on_error },
        kind     => $arg{ kind } || $spec->{ kind },
        values   => { %$spec },
        controls => {},
        loading  => 0,
    }, $class;

    # Nothing should reach here without a kind, but falling back to the first
    # registered one is a better answer than a window with no controls in it.
    $self->{ kind } = ( GlitchVape::Generator::kinds() )[ 0 ]
        unless GlitchVape::Generator::get( $self->{ kind } );

    $self->{ player } = GlitchVape::GUI::Player->new(
        on_error => sub {
            $self->_report( $_[ 0 ] );
            return;
        },
        on_state => sub {
            my ( $on ) = @_;

            my $label = GlitchVape::GUI::Player::PLAY_LABEL;
            $label = GlitchVape::GUI::Player::STOP_LABEL if $on;

            $self->{ play }->set_label( $label );
            return;
        },
    );

    $self->_build;

    my $response = $self->{ dialog }->run;

    # However this ends the pipeline has to come down: a playbin left playing
    # holds the audio device for the life of the process.
    $self->{ player }->stop;

    my $result;
    $result = $self->spec if $response eq 'accept';

    $self->{ dialog }->destroy;

    return unless $result;

    $self->{ on_done }->( $result ) if $self->{ on_done };

    return $result;
}

# ---------------------------------------------------------------------------

sub _build
{
    my ( $self ) = @_;

    my $declared = GlitchVape::Generator::get( $self->{ kind } );

    my $dialog = Gtk3::Dialog->new_with_buttons(
        $declared->{ label },
        $self->{ parent },
        'modal', 'Cancel', 'cancel', 'Add', 'accept'
    );
    $dialog->set_default_size( 580, -1 );
    $dialog->set_default_response( 'accept' );

    $self->{ dialog } = $dialog;

    my $box = Gtk3::Box->new( 'vertical', 10 );
    $box->set_border_width( 14 );

    $box->pack_start( $self->_build_header,  0, 0, 0 );
    $box->pack_start( $self->_build_grid,    1, 1, 0 );
    $box->pack_start( $self->_build_readout, 0, 0, 0 );
    $box->pack_start( $self->_build_bottom,  0, 0, 0 );

    $dialog->get_content_area->add( $box );

    $self->_reload;
    $dialog->show_all;
    $self->_refresh;

    return;
}

# The kind, stated rather than chosen: it was settled before this window
# existed, and the summary is the one line worth repeating here.
sub _build_header
{
    my ( $self ) = @_;

    my $declared = GlitchVape::Generator::get( $self->{ kind } );

    my $summary = Gtk3::Label->new( $declared->{ summary } );
    $summary->set_xalign( 0 );
    $summary->set_line_wrap( 1 );
    $summary->get_style_context->add_class( 'dim-label' );

    return $summary;
}

sub _build_grid
{
    my ( $self ) = @_;

    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 6 );
    $grid->set_column_spacing( 10 );

    $self->{ grid } = $grid;

    return $grid;
}

sub _build_readout
{
    my ( $self ) = @_;

    my $label = Gtk3::Label->new( q{} );
    $label->set_xalign( 0 );

    my $detail = Gtk3::Label->new( q{} );
    $detail->set_xalign( 0 );
    $detail->set_ellipsize( 'end' );
    $detail->set_max_width_chars( 58 );
    $detail->get_style_context->add_class( 'dim-label' );

    my $box = Gtk3::Box->new( 'vertical', 2 );
    $box->pack_start( $label,  0, 0, 0 );
    $box->pack_start( $detail, 0, 0, 0 );

    $self->{ summary } = $label;
    $self->{ detail }  = $detail;

    return $box;
}

sub _build_bottom
{
    my ( $self ) = @_;

    my $row = Gtk3::Box->new( 'horizontal', 8 );

    my $play =
        Gtk3::Button->new_with_label( GlitchVape::GUI::Player::PLAY_LABEL );

    # Pinned to the wider of the two words, measured rather than guessed, so
    # the button does not change size when it changes meaning.
    my $widest = 0;
    for my $text (
        GlitchVape::GUI::Player::PLAY_LABEL,
        GlitchVape::GUI::Player::STOP_LABEL
        )
    {
        $play->set_label( $text );
        my ( undef, $natural ) = $play->get_preferred_width;
        $widest = $natural if $natural > $widest;
    }
    $play->set_label( GlitchVape::GUI::Player::PLAY_LABEL );
    $play->set_size_request( $widest, -1 );

    $play->signal_connect(
        clicked => sub {
            $self->_toggle_play;
            return;
        }
    );

    my $hint = Gtk3::Label->new( q{} );
    $hint->get_style_context->add_class( 'dim-label' );

    $row->pack_start( $play, 0, 0, 0 );
    $row->pack_start( $hint, 0, 0, 0 );

    $self->{ play } = $play;
    $self->{ hint } = $hint;

    return $row;
}

# Throw the controls away and build the chosen kind's instead. Cheap enough to
# do on every change of kind, and much less to go wrong than keeping one set
# of widgets per kind alive and swapping which is visible.
sub _reload
{
    my ( $self ) = @_;

    $self->{ loading }++;

    $_->destroy for $self->{ grid }->get_children;
    $self->{ controls } = {};

    my $declared = GlitchVape::Generator::get( $self->{ kind } );

    my $params = $declared->{ params };
    my $row    = 0;

    for my $name ( @{ $declared->{ order } } )
    {
        my $field = $params->{ $name };

        my $value = $self->{ values }{ $name };
        $value = $field->{ default } unless defined $value;

        my $built = GlitchVape::GUI::Params->build(
            effect    => $self->{ kind },
            name      => $name,
            spec      => $field,
            value     => $value,
            on_change => sub {
                return if $self->{ loading };

                $self->{ values }{ $name } = $_[ 0 ];
                $self->_refresh;
                return;
            },
        );

        # The declaration's own label reads better than the parameter name,
        # which is what the effect pane has to make do with.
        $built->{ label }->set_text( $field->{ label } // $name );

        $self->{ controls }{ $name } = $built;

        $self->{ grid }->attach( $built->{ label },   0, $row, 1, 1 );
        $self->{ grid }->attach( $built->{ control }, 1, $row, 1, 1 );
        $row++;
    }

    $self->{ grid }->show_all;

    $self->{ loading }--;

    return;
}

=head2 spec()

The track as the dialog currently stands.

=cut

sub spec
{
    my ( $self ) = @_;

    my %out = ( kind => $self->{ kind } );

    for my $name ( keys %{ $self->{ controls } } )
    {
        $out{ $name } = $self->{ controls }{ $name }{ get }->();
    }

    return \%out;
}

# What the controls currently amount to, recomputed on every change. Working
# it out is arithmetic over the parameters rather than synthesising anything,
# so it is affordable on every keystroke.
sub _refresh
{
    my ( $self ) = @_;

    return if $self->{ loading };

    my $spec = $self->spec;

    my $resolved = eval { GlitchVape::Generator::resolve( $spec ) };

    unless ( $resolved )
    {
        # resolve() returns undef without dying when there is simply nothing
        # to work with yet -- an empty phrase, most often -- so $@ is empty
        # and the fallback has to read as a whole sentence on its own.
        my $why = $@ || 'Nothing to generate yet';
        $why =~ s/^GlitchVape::\w+:\s*//;
        $why =~ s/\n.*\z//s;
        $why =~ s/\s+\z//;

        $self->{ summary }->set_markup(
            sprintf "<span alpha='75%%'>%s</span>",
            Glib::Markup::escape_text( $why )
        );
        $self->{ detail }->set_text( q{} );
        $self->_allow( 0 );
        return;
    }

    my $seconds = GlitchVape::Generator::duration( $resolved );

    # Just the description: every kind's already carries its own length, and
    # printing that twice on one line reads as a bug rather than as emphasis.
    $self->{ summary }->set_markup(
        sprintf '<b>%s</b>',
        Glib::Markup::escape_text(
            GlitchVape::Generator::describe( $resolved )
        )
    );

    # A kind with something more to say says it on the second line -- for a
    # dialled phrase that is the keypress sequence, which is the thing that
    # makes multi-tap legible rather than mysterious.
    my $declared = GlitchVape::Generator::get( $self->{ kind } );
    my $detail   = q{};

    if ( my $readout = $declared->{ readout } )
    {
        $detail = eval { $readout->( $resolved ) } // q{};
    }

    $self->{ detail }->set_text( $detail );

    my $capped = q{};
    $capped = sprintf ' (the first %ds of it)', AUDITION_CAP
        if $seconds > AUDITION_CAP;

    $self->{ hint }->set_text( "Hear it$capped" );

    $self->_allow( 1 );

    return;
}

sub _allow
{
    my ( $self, $ok ) = @_;

    $self->{ dialog }->set_response_sensitive( 'accept', $ok );
    $self->{ play }->set_sensitive( $ok );

    return;
}

sub _toggle_play
{
    my ( $self ) = @_;

    if ( $self->{ player }->playing )
    {
        $self->{ player }->stop;
        return;
    }

    my $spec = $self->spec;
    my $out  = $self->{ cache }->scratch( '.wav' );

    # undef means the track's own length; a number both fills and truncates,
    # so it is only passed when there is actually too much to listen to.
    my $fill;
    $fill = AUDITION_CAP
        if GlitchVape::Generator::duration( $spec ) > AUDITION_CAP;

    local $@;
    my $ok = eval {
        GlitchVape::Generator::render(
            spec    => $spec,
            output  => $out,
            fill_to => $fill,
        );
        1;
    };

    unless ( $ok )
    {
        $self->_report( $@ || 'the track could not be rendered' );
        return;
    }

    $self->{ player }->play( path => $out );

    return;
}

sub _report
{
    my ( $self, $message ) = @_;

    $message = 'unknown error' unless defined $message && length $message;
    $message =~ s/\s+\z//;

    $self->{ on_error }->( $message ) if $self->{ on_error };

    return;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Generator> for the registry this reads, and
L<GlitchVape::GUI::Audio> for the wizard the file half gets.

=cut
