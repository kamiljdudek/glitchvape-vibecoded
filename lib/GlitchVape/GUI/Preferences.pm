package GlitchVape::GUI::Preferences;

use strict;
use warnings;
use utf8;

use Gtk3 ();

use GlitchVape::GUI::Prefs ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Preferences - the Preferences window

=head1 DESCRIPTION

A stack of pages over L<GlitchVape::GUI::Prefs>, in the shape the desktop
expects one: a header bar with a switcher, a page per subject, and no OK
button.

=head1 CHANGES APPLY AS THEY ARE MADE

There is a Close and nothing else. Preferences on this desktop take effect
when they are set, and a dialog with Apply and Cancel invites the question of
what the window has been doing in the meantime -- which for the mute switch
and the frame count is "already obeying you", because those are live.

So every control writes through on the spot and the caller is told, and Close
means the window is in the way rather than that anything is being committed.

=cut

=head2 run( %arg )

    parent    => Gtk3::Window
    prefs     => the live preferences hash, edited in place
    on_change => sub { my ( $prefs, $what ) = @_ }

C<on_change> fires after every edit, with the key that moved, so the caller
can save the file and act on the ones that are live.

=cut

sub run
{
    my ( $class, %arg ) = @_;

    my $self = bless {
        prefs     => $arg{ prefs },
        on_change => $arg{ on_change } || sub { },
    }, $class;

    my $dialog = Gtk3::Dialog->new;
    $dialog->set_transient_for( $arg{ parent } ) if $arg{ parent };
    $dialog->set_modal( 1 );
    $dialog->set_title( 'Preferences' );

    # Sized to its content rather than to a number picked here, like the
    # dependencies window: these pages are short and fixed, and there is
    # nothing a bigger one would show more of.
    $dialog->set_resizable( 0 );

    my $stack = Gtk3::Stack->new;
    $stack->set_transition_type( 'slide-left-right' );
    $stack->set_border_width( 18 );

    my $switcher = Gtk3::StackSwitcher->new;
    $switcher->set_stack( $stack );

    my $header = Gtk3::HeaderBar->new;
    $header->set_show_close_button( 1 );
    $header->set_custom_title( $switcher );
    $dialog->set_titlebar( $header );

    $self->{ dialog } = $dialog;
    $self->{ stack }  = $stack;

    $self->_build_pages;

    $dialog->get_content_area->pack_start( $stack, 1, 1, 0 );
    $dialog->show_all;
    $dialog->run;
    $dialog->destroy;

    return $self->{ prefs };
}

sub _build_pages
{
    my ( $self ) = @_;

    my $stack = $self->{ stack };

    for my $page (
        [ general   => 'General',      \&_page_general ],
        [ preview   => 'Preview',      \&_page_preview ],
        [ metadata  => 'Metadata',     \&_page_metadata ],
        [ watermark => 'Watermarking', \&_page_watermark ],
        )
    {
        my ( $name, $title, $builder ) = @$page;

        my $child = $builder->( $self );
        $stack->add_titled( $child, $name, $title );
    }

    return;
}

# ---------------------------------------------------------------------------

sub _page_general
{
    my ( $self ) = @_;

    my $box = _column();

    $box->pack_start(
        $self->_check(
            'clear_cache_on_exit',
            'Clear the preview cache when the program exits',
            'The cache only saves time. Kept, it grows for as long as the '
                . 'program is used; cleared, the first preview of the next '
                . 'session is a render rather than a lookup.'
        ),
        0, 0, 0
    );

    $box->pack_start( Gtk3::Separator->new( 'horizontal' ), 0, 0, 6 );

    $box->pack_start(
        $self->_check(
            'randomize_each_render',
            'Draw a new seed every time you press Apply',
            'Every effect that uses randomness -- the static, the dropouts, '
                . 'the block displacement, which phrase the text picks -- '
                . 'comes out differently each render, so Apply becomes a way '
                . 'of looking for a version you like. Off, pressing it twice '
                . 'gives the same picture twice, which is what makes it safe '
                . 'to press after moving one slider.'
        ),
        0, 0, 0
    );

    return $box;
}

sub _page_preview
{
    my ( $self ) = @_;

    my $box = _column();

    my $grid = _grid();
    my $row  = 0;

    for my $spin (
        [ 'frames', 'Frames in the loop', 2, 240 ],
        [ 'fps',    'Frames per second',  1, 60 ],
        )
    {
        my ( $key, $label, $low, $high ) = @$spin;

        my $control = Gtk3::SpinButton->new_with_range( $low, $high, 1 );
        $control->set_value( $self->{ prefs }{ $key } );
        $control->signal_connect(
            'value-changed' => sub {
                $self->_set( $key, $control->get_value_as_int );
                $self->_describe_length;
                return;
            }
        );

        $row = _pair( $grid, $row, $label, $control );
    }

    $box->pack_start( $grid, 0, 0, 0 );

    my $length = Gtk3::Label->new( q{} );
    $length->set_xalign( 0 );
    $length->get_style_context->add_class( 'dim-label' );
    $self->{ length } = $length;
    $box->pack_start( $length, 0, 0, 0 );
    $self->_describe_length;

    $box->pack_start( Gtk3::Separator->new( 'horizontal' ), 0, 0, 6 );

    $box->pack_start(
        $self->_switch(
            'muted',
            'Silent preview',
            'Plays the preview without sound while you work on it. The '
                . 'soundtrack is still rendered and still in the exported '
                . 'file; this only affects what you hear here.'
        ),
        0, 0, 0
    );

    return $box;
}

sub _page_metadata
{
    my ( $self ) = @_;

    my $box = _column();

    $box->pack_start(
        $self->_switch(
            'metadata_keep',
            'Keep metadata in exported files',
            'Off, an export loses what identifies you and the camera: where '
                . 'it was taken, what took it, when, and anything written '
                . 'into the comment fields. Orientation and colour space '
                . 'stay either way — those describe the pixels, and a file '
                . 'without them is a damaged file rather than a private one.'
        ),
        0, 0, 0
    );

    $box->pack_start( Gtk3::Separator->new( 'horizontal' ), 0, 0, 6 );

    $box->pack_start(
        $self->_switch(
            'metadata_credit',
            'Add GlitchVape information',
            'Records this program as what produced the file, in the '
                . 'Software and CreatorTool fields. Nothing about you and '
                . 'nothing about the original.'
        ),
        0, 0, 0
    );

    return $box;
}

sub _page_watermark
{
    my ( $self ) = @_;

    my $box = _column();

    my $first;
    for my $kind ( GlitchVape::GUI::Prefs::kinds() )
    {
        my ( $key, $label, $said ) = @$kind;

        my $radio =
            $first
            ? Gtk3::RadioButton->new_with_label_from_widget( $first, $label )
            : Gtk3::RadioButton->new_with_label( undef, $label );
        $first ||= $radio;

        $radio->set_active( 1 ) if $key eq $self->{ prefs }{ watermark };
        $radio->signal_connect(
            toggled => sub {
                return unless $radio->get_active;
                $self->_set( watermark => $key );
                return;
            }
        );

        $box->pack_start( $radio, 0, 0, 0 );

        my $note = _note( $said );
        $note->set_margin_start( 26 );
        $box->pack_start( $note, 0, 0, 0 );
    }

    $box->pack_start( Gtk3::Separator->new( 'horizontal' ), 0, 0, 6 );

    $box->pack_start(
        $self->_check(
            'watermark_preview',
            'Show the watermark in the preview',
            'The bar makes the picture taller, so seeing it while you work '
                . 'is the only way to know what the export will be shaped '
                . 'like. Off, the preview shows the picture alone and the '
                . 'mark appears only in the exported file.'
        ),
        0, 0, 0
    );

    return $box;
}

# ---------------------------------------------------------------------------

sub _set
{
    my ( $self, $key, $value ) = @_;

    return
        if defined $self->{ prefs }{ $key }
        && $self->{ prefs }{ $key } eq $value;

    $self->{ prefs }{ $key } = $value;
    $self->{ on_change }->( $self->{ prefs }, $key );

    return;
}

sub _describe_length
{
    my ( $self ) = @_;

    return unless $self->{ length };

    my $frames = $self->{ prefs }{ frames } || 1;
    my $fps    = $self->{ prefs }{ fps }    || 1;

    $self->{ length }
        ->set_text( sprintf 'One loop lasts %.1f seconds.', $frames / $fps );

    return;
}

# A switch with its name beside it and its explanation underneath, which is
# the shape every one of these has: the switch says what, the line under it
# says what happens either way.
sub _switch
{
    my ( $self, $key, $label, $said ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 4 );

    my $line = Gtk3::Box->new( 'horizontal', 12 );

    my $name = Gtk3::Label->new( $label );
    $name->set_xalign( 0 );

    my $switch = Gtk3::Switch->new;
    $switch->set_active( $self->{ prefs }{ $key } ? 1 : 0 );
    $switch->set_halign( 'end' );
    $switch->signal_connect(
        'notify::active' => sub {
            $self->_set( $key, $switch->get_active ? 1 : 0 );
            return;
        }
    );

    $line->pack_start( $name,   1, 1, 0 );
    $line->pack_start( $switch, 0, 0, 0 );

    $box->pack_start( $line,          0, 0, 0 );
    $box->pack_start( _note( $said ), 0, 0, 0 );

    return $box;
}

sub _check
{
    my ( $self, $key, $label, $said ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 4 );

    my $check = Gtk3::CheckButton->new_with_label( $label );
    $check->set_active( $self->{ prefs }{ $key } ? 1 : 0 );
    $check->signal_connect(
        toggled => sub {
            $self->_set( $key, $check->get_active ? 1 : 0 );
            return;
        }
    );

    my $note = _note( $said );
    $note->set_margin_start( 26 );

    $box->pack_start( $check, 0, 0, 0 );
    $box->pack_start( $note,  0, 0, 0 );

    return $box;
}

sub _column
{
    my $box = Gtk3::Box->new( 'vertical', 10 );
    $box->set_border_width( 4 );

    return $box;
}

sub _grid
{
    my $grid = Gtk3::Grid->new;
    $grid->set_row_spacing( 8 );
    $grid->set_column_spacing( 12 );

    return $grid;
}

sub _pair
{
    my ( $grid, $row, $text, $control ) = @_;

    my $label = Gtk3::Label->new( $text );
    $label->set_xalign( 0 );

    $grid->attach( $label,   0, $row, 1, 1 );
    $grid->attach( $control, 1, $row, 1, 1 );

    return $row + 1;
}

sub _note
{
    my ( $text ) = @_;

    my $label = Gtk3::Label->new( $text );
    $label->set_xalign( 0 );
    $label->set_line_wrap( 1 );
    $label->set_max_width_chars( 52 );
    $label->get_style_context->add_class( 'dim-label' );

    return $label;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Prefs> for the file and the defaults, and
L<GlitchVape::Watermark> for what the watermarking page chooses between.

=cut
