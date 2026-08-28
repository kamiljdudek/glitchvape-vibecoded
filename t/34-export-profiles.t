#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Test::More;

# No Gtk here on purpose. The profile store is the half of the export settings
# that has nothing to do with windows, and keeping it testable on a machine
# with no display is why it is a module of its own.
use GlitchVape::GUI::Profiles ();

my $dir = File::Temp->newdir( 'gv_profiles_XXXXXX', TMPDIR => 1 );
local $ENV{ GLITCHVAPE_PROFILES } = "$dir";

my $P = 'GlitchVape::GUI::Profiles';

# ---------------------------------------------------------------------------
# There is always something to offer

# The wizard's first page offers a profile. With none shipped it would open on
# an empty list and an instruction to go elsewhere first, which is the state
# the built-ins exist to prevent.
{
    my $all = $P->can( 'load' )->();

    ok scalar @$all, 'profiles load before anything has been saved';
    ok !( grep { !$_->{ builtin } } @$all ),
        'and all of them are the built-in ones';

    ok scalar @{ $P->can( 'of_kind' )->( $all, 'video' ) },
        'at least one is for videos';
    ok scalar @{ $P->can( 'of_kind' )->( $all, 'still' ) },
        'and at least one for stills';

    ok !-e $P->can( 'path' )->(),
        'and nothing has been written to disk to achieve it';
}

# ---------------------------------------------------------------------------
# A profile is filled out with the defaults it does not mention

# A still profile says nothing about frame rates and a video one says nothing
# about palettes, so what comes back has to be a whole settings hash or every
# reader would need to know which keys its kind omits.
{
    my $all   = $P->can( 'load' )->();
    my $still = $P->can( 'of_kind' )->( $all, 'still' )->[ 0 ];

    my $settings = $P->can( 'settings' )->( $still );

    ok exists $settings->{ fps },
        'a still profile still resolves a frame rate from the defaults';
    ok exists $settings->{ video_format }, 'and a video format';
}

# ---------------------------------------------------------------------------
# Saving, and the encoding that nearly ate it

# Every built-in name carries a middle dot and one carries a multiplication
# sign. Printing a decoded string to a raw handle emits Latin-1 for anything
# below U+0100, so the file came out holding a lone 0xB7 -- not valid UTF-8,
# rejected by the parser, and every saved profile silently gone on the next
# load. One character, all the settings.
{
    my $all = $P->can( 'load' )->();

    push @$all,
        {
        name     => 'Мой профиль · 60 fps',
        kind     => 'video',
        builtin  => 0,
        settings =>
            { video_size => 1920, video_format => 'webm-av1', fps => 60 },
        };

    ok $P->can( 'save' )->( $all ), 'the profiles save';
    ok -s $P->can( 'path' )->(),    'and there is a file with something in it';

    my $back = $P->can( 'load' )->();
    my $mine = $P->can( 'named' )->( $back, 'Мой профиль · 60 fps' );

    ok $mine, 'a name outside ASCII survives the round trip';
    is $mine->{ settings }{ fps }, 60, 'with its settings intact';
    is $mine->{ builtin },         0,  'and marked as the user\'s own';
}

# ---------------------------------------------------------------------------
# A saved profile with a built-in's name replaces it where it stands

# The manager will not let you edit a default, so the only way to reach this is
# to have saved a profile under a name that later became a built-in. When that
# happens the saved one wins -- quietly replacing somebody's settings with ours
# is the worse of the two outcomes -- and it wins *in place* rather than being
# appended, so the list does not reorder itself for reasons nobody can see.
{
    my $all = $P->can( 'load' )->();

    my ( $at ) = grep { $all->[ $_ ]{ builtin } } 0 .. $#$all;
    my $name = $all->[ $at ]{ name };

    $all->[ $at ]{ builtin } = 0;
    $all->[ $at ]{ settings }{ video_size } = 512;

    ok $P->can( 'save' )->( $all ), 'an edited built-in saves';

    my $back = $P->can( 'load' )->();

    is $back->[ $at ]{ name },    $name, 'and comes back in the same place';
    is $back->[ $at ]{ builtin }, 0,     'now belonging to the user';
    is $back->[ $at ]{ settings }{ video_size }, 512, 'with the edit kept';
}

# ---------------------------------------------------------------------------
# Two profiles never share a name

# The saved file matches built-ins by name, so a duplicate would make it
# ambiguous which of them a saved entry was overriding.
{
    my $all   = $P->can( 'load' )->();
    my $taken = $all->[ 0 ]{ name };

    isnt $P->can( 'unique_name' )->( $all, $taken ), $taken,
        'a name already in use comes back changed';
    is $P->can( 'unique_name' )->( $all, 'Nothing calls itself this' ),
        'Nothing calls itself this',
        'and one that is free comes back as it went in';
}

# ---------------------------------------------------------------------------
# A damaged file costs the profiles, not the program

# These are preferences. Somebody who has hand-edited the file into nonsense
# should find their profiles back at the defaults, not find that the interface
# will no longer export anything.
{
    open my $fh, '>', $P->can( 'path' )->() or die $!;
    print { $fh } "this is: not\n  valid: [ yaml\n";
    close $fh;

    my $all = eval { $P->can( 'load' )->() };

    ok $all, 'a corrupt profiles file still loads' or diag $@;
    ok !( grep { !$_->{ builtin } } @$all ),
        'falling back to the built-in list';
}

done_testing;
