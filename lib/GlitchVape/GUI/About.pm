package GlitchVape::GUI::About;

use strict;
use warnings;

# Literal '·' and '—' in the comment line.
use utf8;

use Gtk3 ();

use GlitchVape           ();
use GlitchVape::Assets   ();
use GlitchVape::Config   ();
use GlitchVape::Registry ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::About - the about window

=head1 DESCRIPTION

C<Gtk3::AboutDialog> rather than a window built by hand, because the platform
already has opinions about where the licence goes and what the credits button
does, and an application that disagrees with them about its about box is
disagreeing about nothing worth disagreeing about.

The one thing added to it is a count of what this copy can actually see:
effects registered and presets found. Both are discovered at run time rather
than compiled in -- a preset dropped into F<presets/> is a preset, and an
effect is whatever called C<register> -- so the numbers are worth stating
rather than assuming.

=cut

# The logo is 215x185, which is about right for the dialog unscaled. Asking
# Gtk to scale it would soften a picture whose whole character is that its
# pixels are square.
use constant LOGO => 'logo.png';

=head2 show( $parent )

Run the dialog. Returns when it is closed.

=cut

sub show
{
    my ( $class, $parent ) = @_;

    my $about = Gtk3::AboutDialog->new;

    $about->set_transient_for( $parent ) if $parent;
    $about->set_modal( 1 );

    $about->set_program_name( 'GlitchVape' );
    $about->set_version( $GlitchVape::VERSION );
    $about->set_comments( _comments() );
    $about->set_copyright(
        'Vaporwave and glitch-art transformations for ' . 'photographs' );

    $about->set_license_type( 'mit-x11' );
    $about->set_website( 'https://github.com/' );
    $about->set_website_label( 'Source' );

    if ( my $logo = _logo() )
    {
        $about->set_logo( $logo );
    }

    # The two bundled things whose licences are not the program's own, named
    # where somebody looking for them would look.
    $about->add_credit_section( 'Bundled artwork and fonts',
        [ 'Terminus, VCR OSD Mono, Departure Mono, Fusion Pixel, W95FA' ] );

    $about->run;
    $about->destroy;

    return;
}

# What this copy can see, rather than what the release notes claim.
sub _comments
{
    my $effects = scalar GlitchVape::Registry->names;

    my $presets = 0;
    local $@;
    if ( my $found = eval { GlitchVape::Config::list_presets() } )
    {
        $presets = scalar @$found;
    }

    return sprintf "%d effects · %d presets", $effects, $presets;
}

sub _logo
{
    my $path = GlitchVape::Assets::find( 'artwork', LOGO ) or return undef;

    local $@;
    my $pixbuf = eval { Gtk3::Gdk::Pixbuf->new_from_file( $path ) };

    # A logo that will not load is not a reason to withhold the about box.
    return undef unless $pixbuf;

    return $pixbuf;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI>, whose menu opens this.

=cut
