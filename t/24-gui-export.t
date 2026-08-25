#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;

# Gtk, so this needs a display. On a build machine without one there is
# nothing to test rather than something failing.
BEGIN
{
    eval { require Gtk3; Gtk3->import; 1 }
        or plan skip_all => 'Gtk3 is not available';
    Gtk3::init_check()
        or plan skip_all => 'no display';
}

use GlitchVape              ();
use GlitchVape::Registry    ();
use GlitchVape::GUI::Export ();
use GlitchVape::GUI::Params ();
use GlitchVape::GUI::State  ();
use GlitchVape::GUI::Wizard ();

local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

# ---------------------------------------------------------------------------
# What a fresh session exports

{
    my $settings = GlitchVape::GUI::Export::defaults();

    is $settings->{ video_size }, 720,
        'the default resolution is 720, not the native size of the source';

    ok $settings->{ video_size } != 0, 'and Native is deliberately not it';

    is $settings->{ video_format }, 'mp4',
        'the default container is the current one';
    is $settings->{ still_format }, 'origin',
        'a still keeps the format it came in';
    ok !$settings->{ retro },
        'and is not shrunk to a retro screen unless asked';
}

# Native is on the list, and is the only entry that means "no limit".
{
    my $sizes = GlitchVape::GUI::Export::sizes();

    my @zero = grep { $_->[ 0 ] == 0 } @$sizes;
    is scalar @zero, 1, 'exactly one entry means no limit';
    like $zero[ 0 ][ 1 ], qr/native/i, 'and it is the one called Native';

    my %px = map { $_->[ 0 ] => 1 } @$sizes;
    ok $px{ $_ }, "the previewer's $_ px is on the list" for qw(512 720 900);

    ok !grep( { !defined $_->[ 1 ] || !length $_->[ 1 ] } @$sizes ),
        'every size has a label';
}

# ---------------------------------------------------------------------------
# The settings, as arguments to a render

# A video is a codec and a cap; a still is a palette and a box. Neither should
# ever be handed the other's flags.
{
    my $settings = {
        %{ GlitchVape::GUI::Export::defaults() },
        video_format => 'webm-av1',
        still_format => 'bmp256',
        retro        => 1,
    };

    my %video = GlitchVape::GUI::Export::render_options( $settings, 1 );

    is $video{ codec },   'av1', 'a video render is told its codec';
    is $video{ max_dim }, 720,   'and its size limit';
    ok !exists $video{ colors }, 'and nothing about a palette';
    ok !exists $video{ fit },    'and nothing about a retro screen';

    my %still = GlitchVape::GUI::Export::render_options( $settings, 0 );

    is $still{ colors }, 256, 'a still render is told its palette';
    is_deeply $still{ fit }, [ 640, 480 ], 'and the box it must fit';
    ok !exists $still{ codec },   'and nothing about a codec';
    ok !exists $still{ max_dim }, 'and is not capped by the video setting';
}

# Native is the absence of a cap, which is a flag left out rather than a zero
# passed in -- a max_dim of 0 would be a limit of nothing at all.
{
    my $settings =
        { %{ GlitchVape::GUI::Export::defaults() }, video_size => 0 };
    my %opt = GlitchVape::GUI::Export::render_options( $settings, 1 );

    ok !exists $opt{ max_dim }, 'Native passes no max_dim at all';
}

# Retro off means no box, not an enormous one.
{
    my $settings = { %{ GlitchVape::GUI::Export::defaults() }, retro => 0 };
    my %opt      = GlitchVape::GUI::Export::render_options( $settings, 0 );

    ok !exists $opt{ fit }, 'an unticked retro box passes no fit';
}

# ---------------------------------------------------------------------------
# Containers and extensions

{
    my %want = (
        'mp4'      => [ 'mp4',  'h264' ],
        'webm'     => [ 'webm', 'vp9' ],
        'webm-av1' => [ 'webm', 'av1' ],
    );

    for my $key ( sort keys %want )
    {
        my %got =
            GlitchVape::GUI::Export::video_target( { video_format => $key } );

        is_deeply [ @got{ qw(ext codec) } ], $want{ $key },
            "'$key' writes .$want{$key}[0] with $want{$key}[1]";
    }
}

{
    my $ext = \&GlitchVape::GUI::Export::still_extension;

    is $ext->( { still_format => 'png' }, 'a.jpg' ), 'png',
        'enforcing PNG ignores what came in';
    is $ext->( { still_format => 'bmp256' }, 'a.jpg' ), 'bmp',
        'a 256-colour bitmap is a .bmp';

    is $ext->( { still_format => 'origin' }, 'holiday.JPG' ), 'jpg',
        'same-as-origin follows the source, case-folded';
    is $ext->( { still_format => 'origin' }, 'IMG_1.HEIC' ), 'heic',
        'including a HEIC';
    is $ext->( { still_format => 'origin' }, 'no-extension' ), 'png',
        'and falls back to PNG when the source has no extension at all';
}

# A settings hash from an older session, or a corrupted one, must not take the
# export down: every lookup falls back to the first entry.
{
    my %opt = GlitchVape::GUI::Export::render_options(
        { video_format => 'no-such-format', video_size => 720 }, 1 );

    is $opt{ codec }, 'h264', 'an unknown format falls back to the first one';

    ok
        length GlitchVape::GUI::Export::describe(
        { still_format => 'nonsense' }, 0 ),
        'and describing it still says something';
}

# ---------------------------------------------------------------------------
# A switch is not a slider

# The wizard gives its controls a width so that sliders are usable in a narrow
# column. A Gtk3::Switch has a size of its own and comes out a lozenge the
# length of the dialog if it is included in that.
{
    my $spec = GlitchVape::Registry->get( 'osd' );

    my $bool = GlitchVape::GUI::Params->build(
        effect => 'osd',
        name   => 'rec',
        spec   => $spec->{ params }{ rec },
        value  => 1,
    );

    isa_ok $bool->{ control }, 'Gtk3::Switch', 'a bool parameter';
    ok !$bool->{ stretch }, 'and is marked as not wanting to be stretched';

    my $num = GlitchVape::GUI::Params->build(
        effect => 'osd',
        name   => 'size',
        spec   => $spec->{ params }{ size },
        value  => 4.5,
    );

    ok $num->{ stretch }, 'a slider does want the width';

    my $text = GlitchVape::GUI::Params->build(
        effect => 'osd',
        name   => 'rec_text',
        spec   => $spec->{ params }{ rec_text },
        value  => 'REC',
    );

    ok $text->{ stretch }, 'so does an entry';
}

# ---------------------------------------------------------------------------
# Clicking a name picks it; it does not leave the page

# GtkListBox activates a row on a single click by default, which on these two
# pages meant that touching a name was indistinguishable from choosing it and
# pressing Continue -- so nobody could look down the list.
{
    my $state = GlitchVape::GUI::State->new( source => 'photo.png', seed => 1 );

    my $wizard = GlitchVape::GUI::Wizard->run( state => $state );

    ok $wizard, 'the assistant opened';

    for my $page ( qw(category_list effect_list) )
    {
        my $list = $wizard->{ $page };

        ok !$list->get_activate_on_single_click,
            "the $page does not activate a row on a single click";
    }

    $wizard->_finish;
}

done_testing;
