package GlitchVape::GUI::Profiles;

use strict;
use warnings;
use utf8;

use File::Spec ();

use GlitchVape::Config ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::GUI::Profiles - named export settings, and where they are kept

=head1 DESCRIPTION

An export profile is a name attached to a set of export settings, so that the
answer to "how do I usually write this" can be given once and picked from a
list afterwards. It is the export half of what a preset is for the picture.

No Gtk3 in here. The manager and the wizard are the windows over this; this is
the file format, the search for the file, and the built-in list. Keeping them
apart is what lets the whole thing be tested without a display.

=head1 STILLS AND VIDEOS ARE SEPARATE LISTS

A profile is for one or the other and says which, because almost nothing in it
means anything to both. A frame rate is not a property a PNG can have, and
"same as the original" is not an answer a video can give. Offering one list and
greying half of every profile out would be describing the split without
acting on it.

C<kind> is therefore part of the profile rather than something worked out from
its settings, and the wizard shows only the profiles matching what is about to
be written.

=head1 THE BUILT-IN PROFILES ARE NOT WRITTEN OUT

Four of them ship, and they exist so that the first run of the wizard has
something to offer rather than an empty list and an instruction to go and make
one. They are not copied into the user's file: a built-in that had been written
out would keep whatever it said the day it was written, and stop tracking the
program.

They are also read-only in the manager, so the only way one of them changes is
a saved profile carrying the same name. That is still honoured, and still wins:
it is what happens to somebody who made a profile called C<Video · standard>
before there was a built-in of that name, and having their settings quietly
replaced by ours would be the worse of the two outcomes.

=cut

# One YAML file rather than one per profile. A profile is half a dozen scalars
# and there will never be many: a directory of them would be more machinery
# than the thing it holds.
use constant FILENAME => 'export-profiles.yml';

# Why the last save failed, for a caller that wants to say so.
our $ERROR = q{};

# Shipped so the list is never empty. Ordered by how likely each is to be what
# somebody wants, since the wizard offers the first one selected.
my @BUILTIN = (
    {
        name     => 'Video · standard',
        kind     => 'video',
        settings => { video_size => 720, video_format => 'mp4', fps => 12 },
    },
    {
        name     => 'Video · full HD',
        kind     => 'video',
        settings => { video_size => 1920, video_format => 'mp4', fps => 24 },
    },
    {
        name     => 'Still · same as the original',
        kind     => 'still',
        settings => { still_format => 'origin', retro => 0 },
    },
    {
        name     => 'Still · retro 640×480 bitmap',
        kind     => 'still',
        settings => { still_format => 'bmp256', retro => 1 },
    },
);

=head2 defaults()

What a profile means when it does not say. Kept here rather than beside the
dialogs that edit them, because this is the module with no Gtk3 in it: a
profile has to be resolvable on a machine with no display, and reaching into
the window code for a hash of five numbers would have dragged the whole
toolkit in behind it. L<GlitchVape::GUI::Export/defaults> forwards to this.

=cut

sub defaults
{
    return {
        video_size   => 720,
        video_format => 'mp4',
        fps          => 12,
        still_format => 'origin',
        retro        => 0,
    };
}

=head2 dir()

The directory the user's profiles live in. C<GLITCHVAPE_PROFILES> overrides it,
which is how the tests run without touching a real home directory.

=cut

sub dir
{
    return $ENV{ GLITCHVAPE_PROFILES } if $ENV{ GLITCHVAPE_PROFILES };

    # Config rather than data: these are preferences, and losing them costs a
    # minute rather than a photograph.
    my $base = $ENV{ XDG_CONFIG_HOME };
    $base = File::Spec->catdir( $ENV{ HOME }, '.config' )
        if !defined $base || !length $base;

    return File::Spec->catdir( $base, 'glitchvape' );
}

=head2 path()

The profiles file itself, whether or not it exists.

=cut

sub path { return File::Spec->catfile( dir(), FILENAME ) }

=head2 builtin()

The shipped profiles, as fresh copies. Copies because the caller is about to
put them in a list it may then edit, and a built-in edited in place would stay
edited for the rest of the session.

=cut

sub builtin
{
    return [ map { _clone( $_ ) } @BUILTIN ];
}

=head2 load()

Every profile, built-in and saved, as C<< [ { name, kind, settings, builtin },
... ] >>. A saved profile with the same name as a built-in replaces it in
place, so editing one does not also move it to the bottom of the list.

Never dies. A profiles file that has been hand-edited into nonsense should cost
the user their profiles, not their ability to export.

=cut

sub load
{
    my @profiles = @{ builtin() };
    $_->{ builtin } = 1 for @profiles;

    my $saved = _read();

    for my $one ( @$saved )
    {
        next unless _looks_like_profile( $one );

        $one->{ builtin } = 0;

        my ( $at ) =
            grep { $profiles[ $_ ]{ name } eq $one->{ name } } 0 .. $#profiles;

        if ( defined $at ) { $profiles[ $at ] = $one }
        else               { push @profiles, $one }
    }

    return \@profiles;
}

=head2 save( $profiles )

Write the ones that are not built-in. Returns true, or false with the reason
left in C<$GlitchVape::GUI::Profiles::ERROR> -- the caller is a window and
wants to put it in a status bar rather than take the process down. Its own
variable and not C<$@>, which anything between here and the status bar is
entitled to overwrite.

=cut

sub save
{
    my ( $profiles ) = @_;

    my @mine = grep { !$_->{ builtin } } @{ $profiles || [] };

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

    # Encoded here rather than by the handle. A profile name carries whatever
    # the user typed and the built-in ones carry a middle dot, and printing a
    # decoded string to a raw handle emits Latin-1 for anything under U+0100 --
    # a lone 0xB7 that is not valid UTF-8 at all. The parser then rejects the
    # whole file and every saved profile silently disappears, which is a much
    # worse failure than the one character that caused it.
    require Encode;

    open my $fh, '>:raw', $path or do
    {
        $ERROR = "cannot write $path: $!";
        return 0;
    };

    print { $fh } Encode::encode( 'UTF-8', _to_yaml( \@mine ) );
    close $fh;

    return 1;
}

=head2 named( $profiles, $name )

The profile called C<$name>, or undef.

=cut

sub named
{
    my ( $profiles, $name ) = @_;

    return undef unless defined $name;

    for my $one ( @{ $profiles || [] } )
    {
        return $one if $one->{ name } eq $name;
    }

    return undef;
}

=head2 of_kind( $profiles, $kind )

Just the still ones, or just the video ones, in order.

=cut

sub of_kind
{
    my ( $profiles, $kind ) = @_;

    return [ grep { $_->{ kind } eq $kind } @{ $profiles || [] } ];
}

=head2 settings( $profile )

The profile's settings, filled out with the defaults for everything it does not
mention. A profile stores only what its kind cares about, so this is what makes
one safe to hand to code that expects a whole settings hash.

=cut

sub settings
{
    my ( $profile ) = @_;

    return { %{ defaults() }, %{ ( $profile || {} )->{ settings } || {} }, };
}

=head2 unique_name( $profiles, $wanted )

C<$wanted>, or C<"$wanted 2"> and upwards until it is not taken. Two profiles
with one name would make the saved copy of a built-in ambiguous.

=cut

sub unique_name
{
    my ( $profiles, $wanted ) = @_;

    $wanted = 'Profile' unless defined $wanted && length $wanted;

    my %taken = map { $_->{ name } => 1 } @{ $profiles || [] };
    return $wanted unless $taken{ $wanted };

    my $n = 2;
    $n++ while $taken{ "$wanted $n" };

    return "$wanted $n";
}

# ---------------------------------------------------------------------------

sub _clone
{
    my ( $one ) = @_;

    return {
        name     => $one->{ name },
        kind     => $one->{ kind },
        builtin  => $one->{ builtin } ? 1 : 0,
        settings => { %{ $one->{ settings } || {} } },
    };
}

# A hash with a name and a kind we recognise. Anything else in the file is
# skipped rather than fixed up: a half-understood profile would export to
# somewhere the user did not ask for.
sub _looks_like_profile
{
    my ( $one ) = @_;

    return 0 unless ref $one eq 'HASH';
    return 0 unless defined $one->{ name } && length $one->{ name };
    return 0 unless defined $one->{ kind };
    return 0 unless $one->{ kind } eq 'still' || $one->{ kind } eq 'video';

    $one->{ settings } = {} unless ref $one->{ settings } eq 'HASH';

    return 1;
}

sub _read
{
    my $path = path();
    return [] unless -f $path;

    my $data = eval { GlitchVape::Config::read_yaml( $path ) };
    return [] unless ref $data eq 'ARRAY';

    return $data;
}

# Hand-rolled, like the preset writer, and for the same reason: the structure
# is known and shallow, and depending on a YAML *writer* as well as a reader
# would double what has to be installed for the program to keep its settings.
sub _to_yaml
{
    my ( $profiles ) = @_;

    my $out = "# GlitchVape export profiles. Written by the interface.\n";

    for my $one ( @$profiles )
    {
        $out .= '- name: ' . _scalar( $one->{ name } ) . "\n";
        $out .= '  kind: ' . _scalar( $one->{ kind } ) . "\n";

        my $settings = $one->{ settings } || {};
        next unless keys %$settings;

        $out .= "  settings:\n";
        for my $key ( sort keys %$settings )
        {
            $out .= "    $key: " . _scalar( $settings->{ $key } ) . "\n";
        }
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

L<GlitchVape::GUI::Export> for what a settings hash holds and what it means,
and L<GlitchVape::GUI::ExportWizard> for the window that asks for one.

=cut
