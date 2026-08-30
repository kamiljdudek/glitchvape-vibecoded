package GlitchVape::GUI::Assistant;

use strict;
use warnings;
use utf8;

use Gtk3 ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Assistant - the navigation both wizards want

=head1 DESCRIPTION

Two windows in this program are C<Gtk3::Assistant>s -- the export wizard and
the Add Effect wizard -- and both wanted the same thing from the navigation
that Gtk does not offer as a setting. This is that thing, in one place, so
that a third assistant gets it by asking rather than by copying.

=head1 THE "FINISH" BUTTON GOES

GtkAssistant keeps a jump-to-the-last-page button, labelled "Finish", and
shows it whenever the walk forward from the current page crosses two or more
complete content pages and lands on a confirm page.

That is a rule about how many pages happen to be left, and it produces a
button that comes and goes for reasons nothing on the screen explains. In the
export wizard it appeared on the resolution, format and options pages,
vanished on the frame rate page because only one page was left to skip, and
was replaced by Apply on the last: three different terminal buttons in one
walk. In the Add Effect wizard it appeared on the category page, but only
after going back to it from a chosen effect, because that is when the page
ahead first became complete -- so the same page had different buttons the
second time it was seen.

Neither is a shortcut anybody asked for. Both are a button labelled with the
end of the job in the middle of the job.

=head1 WHICH BUTTON IT IS

There is no accessor for it, and its label is translated, so matching the word
would work on an English desktop and nowhere else. It is picked out by what it
does instead: it is the only button whose visibility answers to the
completeness of the pages I<ahead> of the current one. Marking those complete
and then incomplete, without moving off the page, makes exactly one button
appear and disappear.

Holding the page still is what makes the answer unambiguous. An earlier
version of this probe compared two different pages and had to tell the button
apart from Back, whose visibility depends on the page as well.

Finding nothing is not an error. A Gtk that no longer has the button, or has
it under different rules, leaves the probe with no single answer and nothing
is hidden.

=cut

=head2 navigate( $assistant, $forward )

Suppresses the Finish button and then installs C<$forward> as the assistant's
forward page function, which may be C<undef> for Gtk's own page-after-page
order.

The order matters, which is why it is one call and not two: the probe walks
the pages with Gtk's default order, and a forward function that skips the
middle of the assistant -- which the export wizard's does, for the express
route -- would make the walk too short for the button to appear at all, and
the probe would find nothing to hide.

Call it once the assistant has been shown. Gtk only works out which navigation
buttons belong on a page once the assistant has been realised; probing before
that finds every button visible and tells us nothing. Nothing is repainted in
the meantime -- the probe never runs the main loop, and never leaves the first
page -- so there is no frame in which any of it is on screen.

Returns the button it hid, or undef.

=cut

sub navigate
{
    my ( $assistant, $forward ) = @_;

    my $suppressed = _suppress_last( $assistant );

    $assistant->set_forward_page_func( $forward ) if $forward;

    return $suppressed;
}

sub _suppress_last
{
    my ( $assistant ) = @_;

    my $header = $assistant->get_titlebar or return undef;

    my @buttons = grep { $_->isa( 'Gtk3::Button' ) } _descendants( $header );
    return undef unless @buttons;

    # Two content pages and a confirm page is the shortest assistant the
    # button can appear on at all; below that there is nothing to find.
    my $count = $assistant->get_n_pages;
    return undef unless $count >= 3;

    my @pages = map { $assistant->get_nth_page( $_ ) } 0 .. $count - 1;
    my @was   = map { $assistant->get_page_complete( $_ ) ? 1 : 0 } @pages;

    # The walk only starts from a content page, and an assistant whose first
    # page is an introduction would otherwise answer "hidden" to both halves
    # of the probe. Lent for the length of it and given back.
    my $type = $assistant->get_page_type( $pages[ 0 ] );
    $assistant->set_page_type( $pages[ 0 ], 'content' );

    $assistant->set_page_complete( $_, 1 ) for @pages;
    my %shown = map { $_ => 1 } grep { $_->get_visible } @buttons;

    $assistant->set_page_complete( $_, 0 ) for @pages[ 1 .. $#pages ];
    my %alone = map { $_ => 1 } grep { $_->get_visible } @buttons;

    $assistant->set_page_complete( $pages[ $_ ], $was[ $_ ] ) for 0 .. $#pages;
    $assistant->set_page_type( $pages[ 0 ], $type );

    my @only = grep { $shown{ $_ } && !$alone{ $_ } } @buttons;
    return undef unless @only == 1;

    my $suppressed = $only[ 0 ];

    # Gtk shows it again from every recalculation -- every page change, and
    # every set_page_complete -- so hiding it once would last until the first
    # of those. It is hidden as it is shown instead, which needs saying only
    # here and holds for the life of the window.
    $suppressed->signal_connect( show => sub { $_[ 0 ]->hide; return } );
    $suppressed->hide;

    return $suppressed;
}

sub _descendants
{
    my ( $widget ) = @_;

    return ()      unless $widget;
    return $widget unless $widget->can( 'get_children' );

    return $widget, map { _descendants( $_ ) } $widget->get_children;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::ExportWizard> and L<GlitchVape::GUI::Wizard>, the two
assistants this serves.

=cut
