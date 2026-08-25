package GlitchVape::GUI::About;

use strict;
use warnings;

# Literal '·' and '—' in the comment line.
use utf8;

use Gtk3 ();

use GlitchVape           ();
use GlitchVape::Assets   ();
use GlitchVape::Config   ();
use GlitchVape::Licenses ();
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

=head1 THE LICENCE PAGE IS READ OFF DISK

The dialog's licence page is not C<set_license_type( 'mit-x11' )> and a list
of fonts typed out here. It is the project's F<LICENSE> followed by every
licence file that came with a bundled font, read at the moment the window
opens -- see L<GlitchVape::Licenses>.

Two of the bundled faces are under the SIL Open Font License, which asks that
its text travel with the font, and the honest way to satisfy that is to show
the file the font's author wrote rather than a paraphrase of it that this
program's author maintains. It also means a font added by dropping a release
into F<~/.local/share/glitchvape/fonts> is credited here without anyone
editing this file.

The built-in licence type is still the fallback, for the install so broken
that not even F<LICENSE> is there: the program is MIT-licensed whether or not
its licence file survived packaging.

=head1 THE PAGES DO NOT NEGOTIATE THE SIZE

The pages of this dialog are content of unknown length -- the licence is every
F<LICENSE> and F<OFL.txt> on the machine concatenated, and the credits list
grows with every font dropped into the search path -- and the amount of it is
not known until the window opens. Left to itself a page like that asks for the
room it wants and the dialog is obliged to find it, which is how an about box
ends up a different shape depending on which button was last pressed.

The licence page is the one with real potential to do it, because it is shown
unwrapped -- see L</_set_license> for why it has to be -- so its width request
is the length of the longest line in the SIL Open Font License rather than
anything the dialog chose.

So the size is settled here instead: the dialog is given one, and every
scrolled window inside it is told to scroll in both directions, which drops
its minimum request to something a page cannot exceed. Text longer or wider
than the frame then scrolls, which is the behaviour asked for, and no page can
push the frame outwards to avoid scrolling.

How much difference this makes depends on the GTK build. On GTK 3.24.43 the
pages already hold one size between them, and this only replaces a cramped
504x461 with a readable window; on a build where the licence page does get to
state its width, this is what stops it. Either way the dialog's size is a
decision made here rather than an outcome of what is on a page.

Done by walking the widget tree rather than by building the dialog by hand,
because everything else about C<Gtk3::AboutDialog> is worth keeping.

=cut

# The logo is 215x185, which is about right for the dialog unscaled. Asking
# Gtk to scale it would soften a picture whose whole character is that its
# pixels are square.
use constant LOGO => 'logo.png';

# Room for the logo and the comment line on the first page, and for a licence
# wrapped at 72 columns on the second without it having to scroll sideways to
# be read. Every page then lives inside this rather than negotiating for it.
use constant {
    DIALOG_WIDTH  => 600,
    DIALOG_HEIGHT => 520,
};

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
    $about->set_copyright( 'Copyright © 2026 Kamil Dudek' );

    _set_license( $about );

    $about->set_website( 'https://github.com/' );
    $about->set_website_label( 'Source' );

    if ( my $logo = _logo() )
    {
        $about->set_logo( $logo );
    }

    _add_credits( $about );

    # After the pages exist and before the window is on screen: the credits
    # page is only built by add_credit_section, so a walk done any earlier
    # would not find it.
    $about->set_default_size( DIALOG_WIDTH, DIALOG_HEIGHT );
    _unstretch( $about );

    $about->run;
    $about->destroy;

    return;
}

# Every scrolled window in the dialog, made to scroll in both directions. See
# L</THE PAGES DO NOT NEGOTIATE THE SIZE>.
#
# Recursive over the whole tree rather than reaching for a known child: the
# internal layout of GtkAboutDialog is not public and has changed between GTK
# releases, and a walk that finds nothing leaves a dialog that behaves exactly
# as it did before.
sub _unstretch
{
    my ( $widget ) = @_;

    if ( $widget->isa( 'Gtk3::ScrolledWindow' ) )
    {
        $widget->set_policy( 'automatic', 'automatic' );

        # 3.22 and later would otherwise let the child's natural size back in
        # through the other door.
        for my $setter (
            qw(set_propagate_natural_width set_propagate_natural_height) )
        {
            $widget->$setter( 0 ) if $widget->can( $setter );
        }
    }

    return unless $widget->isa( 'Gtk3::Container' );

    _unstretch( $_ ) for $widget->get_children;

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

    return
        sprintf "Vaporwave and glitch-art transformations for photographs\n"
        . "%d effects · %d presets", $effects, $presets;
}

# The licence page: the real files if they are there, the built-in MIT text if
# they are not. set_license() puts the dialog into GTK_LICENSE_CUSTOM, so the
# two are alternatives rather than something to set both of.
sub _set_license
{
    my ( $about ) = @_;

    local $@;
    my $notice = eval { GlitchVape::Licenses::notice() };

    if ( defined $notice && length $notice )
    {
        # Not wrapped: these files are wrapped at 72 columns already, and
        # wrapping them again puts a ragged second line under every line of
        # the SIL Open Font License.
        $about->set_wrap_license( 0 );
        $about->set_license( $notice );

        return;
    }

    $about->set_license_type( 'mit-x11' );

    return;
}

# Everything bundled whose licence is not this project's own. The fonts come
# from what is actually on disk; the two entries after them are things baked
# into the source, which no directory walk could find.
sub _add_credits
{
    my ( $about ) = @_;

    local $@;
    my $bundled = eval { GlitchVape::Licenses::bundled() } || [];

    my @fonts;
    for my $entry ( @$bundled )
    {
        my $line = $entry->{ name };
        $line .= " -- $entry->{ license }" if $entry->{ license };

        push @fonts, $line;
    }

    if ( @fonts )
    {
        $about->add_credit_section( 'Bundled fonts', \@fonts );
    }

    $about->add_credit_section(
        'Also',
        [
            'vgatext draws with Terminus glyphs baked into the source'
                . ' -- SIL Open Font License',
            'Every other typeface is whatever fontconfig could see',
        ]
    );

    return;
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
