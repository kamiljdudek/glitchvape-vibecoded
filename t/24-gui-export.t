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
use GlitchVape::Palette     ();
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
        name   => 'timestamp',
        spec   => $spec->{ params }{ timestamp },
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
        effect => 'text',
        name   => 'string',
        spec   => GlitchVape::Registry->get( 'text' )->{ params }{ string },
        value  => 'HELLO',
    );

    ok $text->{ stretch }, 'so does an entry';
}

# ---------------------------------------------------------------------------
# A row is called what the declaration calls it

# The key is what --set and the preset write, and the popover's header says it
# already. The row can afford English, and where an effect offers it the whole
# point is that it reads without a manual: 'rec_mode' is what a preset writes,
# 'DV REC mode' is what the tape said.
{
    my $spec = GlitchVape::Registry->get( 'osd' )->{ params }{ rec_mode };

    my $built = GlitchVape::GUI::Params->build(
        effect => 'osd',
        name   => 'rec_mode',
        spec   => $spec,
        value  => 'SP',
    );

    is $built->{ label }->get_text, 'DV REC mode',
        'a declared label is what the row is called';

    # And a parameter that declares none is still called by its key, so this
    # costs the other forty effects nothing.
    my $plain = GlitchVape::Registry->get( 'scanlines' )->{ params }{ opacity };
    my $bare  = GlitchVape::GUI::Params->build(
        effect => 'scanlines',
        name   => 'opacity',
        spec   => $plain,
        value  => 0.35,
    );

    is $bare->{ label }->get_text, 'opacity',
        'and a parameter with nothing to say keeps its key';
}

# ---------------------------------------------------------------------------
# A suggestion list may be three strings the effect made up

# The named sources below are program-wide facts -- every registered palette,
# every duotone ramp. Three tape speeds are not: nothing else in the program
# has an opinion about them, and requiring a %SUGGEST_SOURCE entry for them
# would mean an effect that wants to offer three strings has to edit the GUI,
# which is the coupling invariant 1 forbids.
{
    my $spec = GlitchVape::Registry->get( 'osd' )->{ params }{ rec_mode };

    is_deeply $spec->{ suggest }, [ qw(SP LP HD) ],
        'osd.rec_mode carries its own suggestions';

    my $built = GlitchVape::GUI::Params->build(
        effect => 'osd',
        name   => 'rec_mode',
        spec   => $spec,
        value  => 'SP',
    );

    isa_ok $built->{ control }, 'Gtk3::ComboBoxText', 'so it gets a combo';

    my $rows = 0;
    $built->{ control }->get_model->foreach( sub { $rows++; return 0 } );
    is $rows, 3, 'offering the three the effect named';

    # Typeable, because the point of the editable combo is that the list is an
    # offer: a deck with a mode nobody here thought of is still a deck.
    ok $built->{ control }->get_child->isa( 'Gtk3::Entry' ),
        'and still takes a mode of your own';
}

# ---------------------------------------------------------------------------
# Settings that only bite in a loop are kept apart from the rest

# The same invariant as the suggestion lists below: the declaration decides,
# not a list in the GUI. A parameter that does nothing to the still on screen
# reads as a broken control when it sits between two that work, so they are
# grouped -- and the grouping has to follow the flag rather than the name, or
# the next one added is grouped only if somebody remembers.
{
    my ( $ordinary, $animation ) = GlitchVape::GUI::Params::split(
        GlitchVape::Registry->get( 'watermark' )->{ params } );

    is_deeply $animation, [ 'direction', 'drift' ],
        'the watermark keeps its two loop-only settings together';

    ok scalar @$ordinary,                      'and still has ordinary ones';
    ok !( grep { $_ eq 'drift' } @$ordinary ), 'with the drift not among them';

    my ( undef, $grade ) = GlitchVape::GUI::Params::split(
        GlitchVape::Registry->get( 'grade' )->{ params } );

    is_deeply $grade, [ 'sway', 'sway_by' ],
        'a grade that wanders keeps the wander and its size together';

    my ( $plain, $swap ) = GlitchVape::GUI::Params::split(
        GlitchVape::Registry->get( 'duotone' )->{ params } );

    is_deeply $swap, [ 'swap' ], 'and a duotone keeps its swap apart';
    ok scalar( grep { $_ eq 'ramp' } @$plain ),
        'with the ramp it swaps still among the ordinary settings';

    my ( undef, $none ) = GlitchVape::GUI::Params::split(
        GlitchVape::Registry->get( 'posterize' )->{ params } );

    is_deeply $none, [],
        'an effect with nothing loop-only gets no second group';

    # Every one of them, so a drift declared without the flag is caught here
    # rather than by somebody wondering why one effect looks different.
    my @unflagged;
    for my $effect ( GlitchVape::Registry->names )
    {
        my $params = GlitchVape::Registry->get( $effect )->{ params };

        for my $key ( sort keys %$params )
        {
            next unless $key eq 'drift' || $key eq 'pulse';
            next if $params->{ $key }{ animation };
            push @unflagged, "$effect.$key";
        }
    }

    is_deeply \@unflagged, [],
        'every drift and pulse in the registry is marked as loop-only';
}

# ---------------------------------------------------------------------------
# A suggestion list comes from the declaration, not from a list in the GUI

# The property being pinned is invariant 1: adding an effect must not require
# editing GlitchVape::GUI::Params. A parameter says `suggest => 'palette'`
# where its type and range are declared, and the combo fills itself. This used
# to be a table here keyed on 'effect.param', so every new effect that wanted
# palette names needed a line adding to the GUI -- which is exactly the
# coupling the invariant exists to forbid.
{
    my @palette_params = ( [ 'palette', 'name' ], [ 'gradient_map', 'name' ], );

    my $offered = scalar GlitchVape::Palette::names();

    for my $pair ( @palette_params )
    {
        my ( $effect, $param ) = @$pair;
        my $spec = GlitchVape::Registry->get( $effect )->{ params }{ $param };

        is $spec->{ suggest }, 'palette',
            "$effect.$param declares where its suggestions come from";

        my $built = GlitchVape::GUI::Params->build(
            effect => $effect,
            name   => $param,
            spec   => $spec,
            value  => $spec->{ default },
        );

        isa_ok $built->{ control }, 'Gtk3::ComboBoxText',
            "so $effect.$param gets a combo";

        my $rows = 0;
        $built->{ control }->get_model->foreach( sub { $rows++; return 0 } );
        is $rows, $offered, 'offering every registered palette';

        # An entry as well as a list, because these two effects are about the
        # colours, so an inline '#FF71CE,#01CDFE' that no list could
        # enumerate is exactly what somebody might mean.
        ok $built->{ control }->get_child->isa( 'Gtk3::Entry' ),
            'and still takes an inline colour list';
    }
}

# ---------------------------------------------------------------------------
# A parameter can offer a list and mean only that list

# The same declaration-driven mechanism, and the difference is what typing
# something else would mean. bitmap has five settings that together make a
# picture look like a machine, and the palette is which machine -- so an entry
# beside a list of the machines invites typing where picking is the question.
{
    my $spec = GlitchVape::Registry->get( 'bitmap' )->{ params }{ palette };

    is $spec->{ choose }, 'palette',
        'bitmap.palette declares a closed list rather than a suggestion';
    ok !$spec->{ suggest }, 'and does not declare both';

    my $built = GlitchVape::GUI::Params->build(
        effect => 'bitmap',
        name   => 'palette',
        spec   => $spec,
        value  => 'laserwave',
    );

    isa_ok $built->{ control }, 'Gtk3::ComboBoxText', 'so it gets a combo';
    ok !$built->{ control }->get_child->isa( 'Gtk3::Entry' ),
        'with nothing to type into';

    my $rows = 0;
    $built->{ control }->get_model->foreach( sub { $rows++; return 0 } );
    is $rows, scalar GlitchVape::Palette::names(),
        'offering every registered palette and no more';

    is $built->{ get }->(), 'laserwave', 'and it opens on the current value';
}

# ---------------------------------------------------------------------------
# A closed list still tells the truth about a value it does not hold

# The command line and the presets accept things a list was never meant to
# enumerate -- bitmap.palette still takes an inline '#FF71CE,#01CDFE' there --
# and a combo that quietly showed the first entry instead would be naming a
# palette the render is not using.
{
    my $spec = GlitchVape::Registry->get( 'bitmap' )->{ params }{ palette };

    my $inline = '#FF71CE,#01CDFE,#05FFA1';

    my $built = GlitchVape::GUI::Params->build(
        effect => 'bitmap',
        name   => 'palette',
        spec   => $spec,
        value  => $inline,
    );

    is $built->{ get }->(), $inline,
        'a value the list does not hold is what the control reads back';

    my $rows = 0;
    $built->{ control }->get_model->foreach( sub { $rows++; return 0 } );
    is $rows, scalar( GlitchVape::Palette::names() ) + 1,
        'shown as an entry of its own, added to the offered ones';
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
