package GlitchVape::GUI::Deps;

use strict;
use warnings;
use utf8;

use Gtk3 ();

use GlitchVape::Fonts ();
use GlitchVape::Tools ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Deps - what this machine can do, with the reasons

=head1 DESCRIPTION

The window over L<GlitchVape::Tools/capabilities>. It asks nothing itself: the
probing is command-line logic and C<--check-deps> asks exactly the same
questions, so the two cannot disagree about whether something is installed.

=head1 WHY THREE GROUPS AND NOT ONE LIST

C<--check-deps> prints a list of binaries, which answers "is ffmpeg
installed". The question somebody opens this dialog to ask is "can I export a
video", and those are only the same question if you already know what ffmpeg
is for.

So the features come first and say what is possible. Backends and formats are
underneath for when the answer is no and the next question is why.

=head1 MISSING IS NOT ALWAYS WRONG

Most of what can be absent here is optional: no exiftool means an export
without its EXIF, not a broken program. A dialog that painted those red would
be reporting a fault that is not one, and would teach people to ignore the
red. Optional and absent is amber and says so; required and absent is red.

=cut

# Icon and style class per state. The class is what colours it: Gtk's themes
# define success, warning and error for exactly this, so the colours track the
# desktop rather than being three hexadecimals chosen here that go wrong in a
# high-contrast theme.
my %STATE = (
    ok       => [ 'object-select-symbolic',  'gv-ok',       'working' ],
    optional => [ 'dialog-warning-symbolic', 'gv-optional', 'not installed' ],
    missing  => [ 'dialog-error-symbolic', 'gv-missing', 'required, missing' ],
);

# Our own classes and our own colours, rather than Gtk's success/warning/error.
# Those exist, but themes define them for buttons and entries and several
# leave a plain GtkImage exactly the colour it already was -- which is how the
# first version of this dialog came out with three columns of invisible
# lights. Named gv- so nothing here can collide with a theme's own rules.
my $CSS = <<'STYLE';
.gv-ok       { color: #26a269; }
.gv-optional { color: #e5a50a; }
.gv-missing  { color: #c01c28; }
STYLE

my $STYLED = 0;

# Once per process. Adding the same provider to the screen twice would stack
# two identical rules for every widget to walk.
sub _install_style
{
    return if $STYLED++;

    my $provider = Gtk3::CssProvider->new;
    return unless eval { $provider->load_from_data( $CSS ); 1 };

    Gtk3::StyleContext::add_provider_for_screen(
        Gtk3::Gdk::Screen::get_default(),
        $provider, Gtk3::STYLE_PROVIDER_PRIORITY_APPLICATION() );

    return;
}

=head2 run( %arg )

    parent => Gtk3::Window

Modal, and closes on its own button. Nothing is returned: this dialog only
reports.

=cut

sub run
{
    my ( $class, %arg ) = @_;

    my $dialog = Gtk3::Dialog->new_with_buttons( 'Dependencies', $arg{ parent },
        'modal', 'Close', 'close' );

    # No size of its own, and not resizable. This is a fixed list that is read
    # once: there is nothing in it a wider window would show more of, and a
    # default size picked here is a promise about how long the list is that
    # goes wrong the moment a format is added. It takes the height its content
    # asks for, up to the cap below.
    $dialog->set_resizable( 0 );

    _install_style();

    my $box = Gtk3::Box->new( 'vertical', 18 );
    $box->set_border_width( 16 );

    $box->pack_start( _summary(), 0, 0, 0 );

    for my $group ( GlitchVape::Tools::capabilities() )
    {
        $box->pack_start( _group( $group->{ group }, $group->{ rows } ),
            0, 0, 0 );
    }

    # Fonts stay a plain list. A font role is never missing -- it falls
    # through its candidates to whatever fontconfig can see -- so there is no
    # red or amber to report, only which one it landed on. See
    # GlitchVape::Fonts.
    $box->pack_start( _fonts(), 0, 0, 0 );

    my $scroll = Gtk3::ScrolledWindow->new;
    $scroll->set_policy( 'never', 'automatic' );

    # Ask for the height the list actually wants rather than an arbitrary one,
    # and scroll only past the point where the dialog would be taller than a
    # small screen. Without the first of these a ScrolledWindow asks for
    # almost nothing and the list ends up in a strip at the top of whatever
    # height the window happened to get.
    $scroll->set_propagate_natural_height( 1 );
    $scroll->set_max_content_height( 620 );
    $scroll->add( $box );

    # pack_start, not add: gtk_container_add on a GtkBox packs with expand
    # false, which is the other half of why the content sat in a strip at the
    # top with the rest of the dialog empty underneath it.
    $dialog->get_content_area->pack_start( $scroll, 1, 1, 0 );
    $dialog->show_all;
    $dialog->run;
    $dialog->destroy;

    return;
}

# One line at the top, because the answer to "is anything wrong" should not
# need reading three lists to find.
sub _summary
{
    my ( $required, $optional ) = ( 0, 0 );

    for my $group ( GlitchVape::Tools::capabilities() )
    {
        for my $row ( @{ $group->{ rows } } )
        {
            next if $row->{ ok };
            if   ( $row->{ need } eq 'required' ) { $required++ }
            else                                  { $optional++ }
        }
    }

    my $text  = 'Everything GlitchVape needs is here.';
    my $state = 'ok';

    if ( $required )
    {
        $text = "$required required things are missing. "
            . 'Some of what follows will not work.';
        $state = 'missing';
    }
    elsif ( $optional )
    {
        $text = "Everything required is here. $optional optional things "
            . 'are not installed, and only widen what is possible.';
        $state = 'optional';
    }

    return _row( $state, $text, q{}, 1 );
}

sub _group
{
    my ( $title, $rows ) = @_;

    my $box = Gtk3::Box->new( 'vertical', 4 );

    my $heading = Gtk3::Label->new( $title );
    $heading->set_xalign( 0 );
    $heading->set_markup( "<b>$title</b>" );
    $heading->set_margin_bottom( 4 );
    $box->pack_start( $heading, 0, 0, 0 );

    for my $row ( @$rows )
    {
        my $state =
              $row->{ ok }                 ? 'ok'
            : $row->{ need } eq 'required' ? 'missing'
            :                                'optional';

        $box->pack_start( _row( $state, $row->{ name }, $row->{ detail } ),
            0, 0, 0 );
    }

    return $box;
}

# A light, a name, and where it came from. The third column is the one that
# turns "missing" into something actionable: a path for what is installed, a
# package name for what is not.
sub _row
{
    my ( $state, $name, $detail, $wrap ) = @_;

    my ( $icon, $class, undef ) = @{ $STATE{ $state } };

    my $line = Gtk3::Box->new( 'horizontal', 10 );

    my $light = Gtk3::Image->new_from_icon_name( $icon, 'button' );
    $light->get_style_context->add_class( $class );
    $light->set_valign( 'start' );
    $line->pack_start( $light, 0, 0, 0 );

    my $label = Gtk3::Label->new( $name );
    $label->set_xalign( 0 );

    if ( $wrap )
    {
        $label->set_line_wrap( 1 );
        $label->set_max_width_chars( 52 );
        $line->pack_start( $label, 1, 1, 0 );
        return $line;
    }

    # A fixed width, so the "provided by" column lines up down the dialog
    # rather than stepping in and out with the length of each name.
    $label->set_width_chars( 26 );
    $line->pack_start( $label, 0, 0, 0 );

    my $said = Gtk3::Label->new( $detail );
    $said->set_xalign( 0 );

    # A width of its own, or the dialog sizes itself to the names alone and
    # every path in this column ellipsizes away to nothing. Ellipsizing is
    # still wanted -- a font path is longer than any sensible dialog -- but it
    # has to shorten something the window made room for.
    $said->set_width_chars( 30 );
    $said->set_max_width_chars( 46 );
    $said->set_ellipsize( 'middle' );
    $said->set_tooltip_text( $detail );
    $said->get_style_context->add_class( 'dim-label' );
    $line->pack_start( $said, 1, 1, 0 );

    return $line;
}

sub _fonts
{
    my $box = Gtk3::Box->new( 'vertical', 4 );

    my $heading = Gtk3::Label->new( q{} );
    $heading->set_xalign( 0 );
    $heading->set_markup( '<b>Fonts</b>' );
    $heading->set_margin_bottom( 4 );
    $box->pack_start( $heading, 0, 0, 0 );

    for my $entry ( @{ GlitchVape::Fonts::available() } )
    {
        my ( $role, $path ) = @$entry;

        $box->pack_start( _row( 'ok', $role, $path // 'falling back' ),
            0, 0, 0 );
    }

    return $box;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Tools/capabilities> for the questions, and L<glitchvape> for the
command-line answer to the same ones.

=cut
