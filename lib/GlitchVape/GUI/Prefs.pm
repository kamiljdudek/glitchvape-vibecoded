package GlitchVape::GUI::Prefs;

use strict;
use warnings;
use utf8;

use File::Spec ();

use GlitchVape::Config        ();
use GlitchVape::GUI::Profiles ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Prefs - what the program remembers between runs

=head1 DESCRIPTION

Preferences: the settings that belong to the program rather than to a
photograph. A preset is a look and an export profile is a way of writing; these
are neither, and until now there was nowhere for them.

No Gtk3 in here, for the same reason L<GlitchVape::GUI::Profiles> has none: the
file format and the defaults are testable without a display, and the window
over them is a separate thing.

=head1 EVERY PREFERENCE HAS A DEFAULT HERE

C<defaults()> is the whole list, and it is what C<load> merges the saved file
onto. A preference that is not in it does not exist, which is what makes
"restore defaults" a matter of forgetting the file rather than of a second
list that has to be kept in step with the first.

It is also what makes an old file safe: keys that are no longer known are
dropped on load rather than carried around, and keys that did not exist when
the file was written come from here.

=head1 WHAT STRIPPING METADATA MEANS

C<metadata_keep> off does not mean every tag goes. Orientation, colour space
and the rest of the structural tags describe how to read the pixels, and
throwing those away damages the file. What comes out is the part that is about
the photographer rather than the photograph: where it was taken, what took it,
when, and anything they wrote in it.

That distinction is the reason this is not simply ImageMagick's C<Strip>,
which removes all of it.

=cut

use constant FILENAME => 'preferences.yml';

our $ERROR = q{};

=head2 defaults()

Every preference and what it means when nothing has been said.

=cut

sub defaults
{
    return {

        # General
        clear_cache_on_exit => 1,

        # Off, because a render that changes every time it is asked for is
        # not what Apply usually means: the ordinary use of pressing it twice
        # is to see the same thing again after moving a slider.
        randomize_each_render => 0,

        # Preview
        frames => 24,
        fps    => 12,
        muted  => 0,

        # Metadata. Off by default because the safe answer to "should this
        # picture still say where it was taken" is no, and because it is what
        # the program did before there was a choice.
        metadata_keep   => 0,
        metadata_credit => 0,

        # Watermarking. None by default: a tool that signs its output without
        # being asked is a tool people stop using for anything that matters.
        watermark         => 'none',
        watermark_preview => 1,
    };
}

=head2 kinds()

The watermark styles, as C<< [ key, label, description ] >> in display order.

=cut

sub kinds
{
    return (
        [ 'none', 'None', 'Nothing is added to the picture.' ],
        [
            'logo',
            'Semitransparent logo',
            'The VA letters, small and faint, in the bottom right corner.'
        ],
        [
            'bar',
            'Bar along the bottom',
            'A black strip under the picture reading "Created with '
                . 'GlitchVape" in bright purple.'
        ],
    );
}

=head2 dir() / path()

Where the file lives. Shares C<GLITCHVAPE_PROFILES> with the export profiles,
because it is the same directory and one override for the pair is one thing
for a test to set.

=cut

sub dir  { return GlitchVape::GUI::Profiles::dir() }
sub path { return File::Spec->catfile( dir(), FILENAME ) }

=head2 load()

The saved preferences over the defaults. Never dies: a file somebody has
hand-edited into nonsense should cost them their preferences, not the program.

=cut

sub load
{
    my $out = defaults();

    my $saved = _read();
    return $out unless ref $saved eq 'HASH';

    for my $key ( keys %$out )
    {
        next unless exists $saved->{ $key };
        next unless defined $saved->{ $key };

        $out->{ $key } = $saved->{ $key };
    }

    return $out;
}

=head2 save( $prefs )

Write them. True, or false with the reason in C<$ERROR>.

=cut

sub save
{
    my ( $prefs ) = @_;

    $ERROR = q{};

    my $dir = dir();
    unless ( -d $dir )
    {
        require File::Path;
        unless ( eval { File::Path::make_path( $dir ); 1 } )
        {
            $ERROR = "cannot create $dir";
            return 0;
        }
    }

    my $path = path();

    require Encode;

    open my $fh, '>:raw', $path or do
    {
        $ERROR = "cannot write $path: $!";
        return 0;
    };

    print { $fh } Encode::encode( 'UTF-8', _to_yaml( $prefs ) );
    close $fh;

    return 1;
}

=head2 forget()

Remove the saved file, so the defaults stand again. Missing is success: the
point is that there is nothing there afterwards.

Nothing in the interface calls this -- there is no reset button -- but it is
how the defaults are got back, and deleting one file is a thing somebody can
be told to do.

=cut

sub forget
{
    my $path = path();

    return 1 unless -e $path;
    return 1 if unlink $path;

    $ERROR = "cannot remove $path: $!";
    return 0;
}

# ---------------------------------------------------------------------------

sub _read
{
    my $path = path();
    return undef unless -f $path;

    return eval { GlitchVape::Config::read_yaml( $path ) };
}

sub _to_yaml
{
    my ( $prefs ) = @_;

    my $out = "# GlitchVape preferences. Written by the interface.\n";

    for my $key ( sort keys %$prefs )
    {
        $out .= "$key: " . _scalar( $prefs->{ $key } ) . "\n";
    }

    return $out;
}

sub _scalar
{
    my ( $v ) = @_;

    $v = q{}    unless defined $v;
    return "''" unless length $v;
    return $v if $v =~ /^-?[0-9]+(?:[.][0-9]+)?$/;
    return $v if $v =~ m{^[A-Za-z0-9_./-]+$} && $v !~ /^-/;

    my $quoted = $v;
    $quoted =~ s/'/''/g;

    return "'$quoted'";
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::GUI::Preferences> for the window, and
L<GlitchVape::GUI::Profiles> for the export settings, which are kept
separately because they are a list rather than a set of switches.

=cut
