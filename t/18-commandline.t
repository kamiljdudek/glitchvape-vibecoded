#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use GlitchVape                   ();
use GlitchVape::GUI::CommandLine ();
use GlitchVape::GUI::State       ();

local $ENV{ GLITCHVAPE_PRESETS } = "$FindBin::Bin/../presets";

# The interface promises that what it exports is what the command-line tool
# would produce from the same settings. This turns that promise into a string
# somebody can paste, so what matters is that the string is complete -- an
# omitted flag is a command that quietly renders something else.

sub state_for
{
    my ( %arg ) = @_;

    my $state = GlitchVape::GUI::State->new(
        source => $arg{ source } // 'photo.heic',
        seed   => $arg{ seed }   // 7,
    );

    $state->load_preset( $arg{ preset } ) if $arg{ preset };

    return $state;
}

sub command_for
{
    my ( $state, %arg ) = @_;
    return GlitchVape::GUI::CommandLine::format( state => $state, %arg );
}

# ---------------------------------------------------------------------------
# The shape of it

{
    my $state = state_for();
    my $line  = command_for( $state );

    like $line, qr/\Aglitchvape /, 'it is a glitchvape command';
    like $line, qr/-s 7/, 'the seed is in it, since it decides the render';
    like $line, qr/photo[.]heic\z/, 'and the input is last, as the tool wants';

    unlike $line, qr/-p /, 'no preset means no -p';
}

{
    my $state = state_for( preset => 'hotline' );
    my $line  = command_for( $state );

    like $line, qr/-p hotline/, 'a preset is named';

    # The whole point of diffing against the preset: an untouched preset is a
    # short command, not three hundred --set flags.
    unlike $line, qr/--set/,
        'and an untouched preset needs no overrides at all';
}

# ---------------------------------------------------------------------------
# Only the differences

{
    my $state = state_for( preset => 'hotline' );
    $state->param( 'scanlines', 'opacity', 0.55 );

    my $line = command_for( $state );

    like $line, qr/--set scanlines[.]opacity=0[.]55/,
        'a changed parameter is emitted';

    my @sets = $line =~ /--set /g;
    is scalar @sets, 1, 'and only the changed one';
}

{
    # Setting a parameter back to what the preset already says is not a
    # change, and must not produce a flag.
    my $state = state_for( preset => 'hotline' );
    my $was   = $state->param( 'scanlines', 'opacity' );

    $state->param( 'scanlines', 'opacity', 0.9 );
    $state->param( 'scanlines', 'opacity', $was );

    unlike command_for( $state ), qr/--set/,
        'a parameter put back is not a difference';
}

# ---------------------------------------------------------------------------
# Effects coming and going

{
    my $state = state_for( preset => 'hotline' );
    $state->add_effect( 'vgatext' );

    my $line = command_for( $state );

    like $line, qr/-e vgatext/, 'an added effect is enabled';
    unlike $line, qr/--set vgatext/,
        'and needs no overrides while it is at its defaults';

    $state->param( 'vgatext', 'runs', 3 );
    like command_for( $state ), qr/--set vgatext[.]runs=3/,
        'until one of them is changed';
}

{
    my $state = state_for( preset => 'hotline' );
    $state->enabled( 'bloom', 0 );

    like command_for( $state ), qr/-d bloom/,
        'an effect switched off is disabled';
}

{
    # The case that was silently wrong: an effect deleted outright is not in
    # the state at all, so it has to be found from the preset's side or the
    # preset simply puts it back.
    my $state = state_for( preset => 'hotline' );
    $state->remove_effect( 'grille' );

    like command_for( $state ), qr/-d grille/,
        'an effect removed outright is disabled too';
}

{
    my $state = state_for();
    $state->add_effect( 'duotone' );

    my $line = command_for( $state );

    like $line,   qr/-e duotone/, 'with no preset, effects are enabled by hand';
    unlike $line, qr/-d /,        'and there is nothing to switch off';
}

# ---------------------------------------------------------------------------
# Animation and soundtrack

{
    my $state = state_for();

    my $line = command_for( $state, animate => { frames => 24, fps => 12 } );

    like $line, qr/--animate/,   'animation is asked for';
    like $line, qr/--frames 24/, 'with its frame count';
    like $line, qr/--fps 12/,    'and rate';
}

{
    my $state = state_for();

    my $line = command_for(
        $state,
        animate => {
            frames => 24,
            fps    => 12,
            audio  => {
                path    => 'rain.wav',
                start   => 2,
                end     => 18,
                filters => { slowed => 0.8 },
            },
        }
    );

    like $line, qr/--audio rain[.]wav/,          'the file is named';
    like $line, qr/--audio-start 2/,             'with its crop';
    like $line, qr/--audio-end 18/,              'at both ends';
    like $line, qr/--audio-filter slowed=0[.]8/, 'and its filters';
}

{
    my $state = state_for();

    my $line = command_for(
        $state,
        animate => {
            frames => 24,
            fps    => 12,
            audio  => {
                generated => [
                    { kind => 'static', seconds => 20, tone => 0.5 },
                    { kind => 'dtmf',   text    => 'call me' },
                ],
            },
        }
    );

    like $line, qr/--generate static/, 'a generated track is started';
    like $line, qr/--gen seconds=20/,  'with the parameters that differ';
    like $line, qr/--gen tone=0[.]5/,  'from its declared defaults';
    like $line, qr/--generate dtmf/,   'and a second one after it';

    # A track left entirely at its defaults still needs its --generate, or it
    # would not be in the mix at all.
    my $bare = command_for(
        $state,
        animate => {
            frames => 24,
            fps    => 12,
            audio  => { generated => [ { kind => 'static' } ] },
        }
    );

    like $bare,   qr/--generate static/, 'a default track is still generated';
    unlike $bare, qr/--gen /,            'with nothing to say about it';
}

# ---------------------------------------------------------------------------
# Quoting

{
    my $state = state_for( source => 'my holiday/photo #2.heic' );
    $state->add_effect( 'text' );
    $state->param( 'text', 'string', '電脳 & co' );

    my $line = command_for( $state );

    like $line, qr/'my holiday\/photo #2[.]heic'/,
        'a path with a space and a hash is quoted';

    # Either the whole argument or just the value may end up quoted; what
    # matters is that the spaces and the ampersand are inside quotes.
    my $quoted = qr/'[^']*text[.]string=電脳 & co'/;
    like $line, $quoted, 'and so is a value with a space and an ampersand';

    # Single quotes are what makes this safe: inside them a shell interprets
    # nothing, so a '#' cannot start a comment and a '&' cannot fork.
    my $tricky = state_for( source => "it's here.png" );
    like command_for( $tricky ), qr/'it'\\''s here[.]png'/,
        'and an apostrophe is escaped the only way single quotes allow';
}

{
    # A bare word needs no quoting, and quoting everything would make the
    # command unreadable for the sake of nothing.
    my $state = state_for( preset => 'hotline' );
    my $line  = command_for( $state );

    unlike $line, qr/'hotline'/, 'a plain preset name is left unquoted';
}

# ---------------------------------------------------------------------------
# Output

{
    my $state = state_for();

    like command_for( $state, output => 'out/x.png' ), qr{-o out/x[.]png},
        'an output path is emitted when there is one';
    unlike command_for( $state ), qr/-o /, 'and left out when there is not';
}

# ---------------------------------------------------------------------------
# The wrapped form
#
# What the dialog shows. It has to be the same command as the one line -- a
# second rendering of the same words, not a second opinion about them -- and
# it has to still be one command after the line breaks.

{
    my $state = state_for( preset => 'vhs-decay' );
    $state->param( 'scanlines', 'opacity', 0.42 );

    my %arg = ( animate => { frames => 24, fps => 12 } );

    my $flat    = command_for( $state, %arg );
    my $wrapped = command_for( $state, %arg, wrap => 1 );

    isnt $wrapped, $flat, 'wrapping produces something different';

    like $wrapped, qr/\n/, 'and it has line breaks in it';
    unlike $flat,  qr/\n/, 'while the flat form still has none';

    # Every line but the last ends in a backslash, which is what makes the
    # whole thing one command rather than several broken ones.
    my @lines = split /\n/, $wrapped;

    cmp_ok scalar @lines, '>', 3, 'the command is broken over several lines';

    my $tail = pop @lines;

    is scalar( grep { /\\\z/ } @lines ), scalar @lines,
        'every line but the last ends in a backslash';
    unlike $tail, qr/\\\z/, 'and the last one does not';

    # Undoing the wrapping has to give back exactly the flat command: if it
    # does not, the dialog is showing something other than what Copy copies.
    my @unwrapped = split /\n/, $wrapped;

    for my $line ( @unwrapped )
    {
        $line =~ s/\s*\\\z//;    # the continuation marker
        $line =~ s/^\s+//;       # and the indent under it
    }

    is join( q{ }, @unwrapped ), $flat,
        'unwrapping it gives back the one-line form exactly';
}

# The source is a positional argument, so it has to be last and it has to be
# alone on its line -- appended to the line above it would read as that
# flag's value.
{
    my $state = state_for( source => 'photo.png' );

    my $wrapped = command_for( $state, wrap => 1, output => 'out/x.png' );

    my @lines = split /\n/, $wrapped;

    like $lines[ -1 ], qr/\A\s*photo[.]png\z/,
        'the source is alone on the final line';
}

# ---------------------------------------------------------------------------
# The export settings

# The command is what produces the export, so what the export settings decided
# has to be in it -- and only the parts of it that apply to what is being
# written.

SKIP:
{
    eval { require GlitchVape::GUI::Export; 1 }
        or skip 'GlitchVape::GUI::Export needs Gtk3', 8;

    my $state = state_for();

    my $export = {
        %{ GlitchVape::GUI::Export::defaults() },
        video_size   => 900,
        video_format => 'webm-av1',
        still_format => 'bmp256',
        retro        => 1,
    };

    my $video = command_for(
        $state,
        export  => $export,
        animate => { frames => 24, fps => 12 }
    );

    like $video,   qr/--max-dim 900/, 'a video export carries its size limit';
    like $video,   qr/--codec av1/,   'and its codec';
    unlike $video, qr/--colors/,      'and says nothing about a palette';
    unlike $video, qr/--fit/,         'nor about a retro screen';

    my $still = command_for( $state, export => $export );

    like $still,   qr/--colors 256/,  'a still export carries its palette';
    like $still,   qr/--fit 640x480/, 'and the box it must fit inside';
    unlike $still, qr/--codec/,       'and says nothing about a codec';
}

# H.264 in an .mp4 is what the extension already says, so naming it would be
# noise -- but a codec the extension cannot imply has to be named.
SKIP:
{
    eval { require GlitchVape::GUI::Export; 1 }
        or skip 'GlitchVape::GUI::Export needs Gtk3', 3;

    my $state    = state_for();
    my $defaults = GlitchVape::GUI::Export::defaults();

    my $animate = { frames => 24, fps => 12 };

    unlike command_for( $state, export => $defaults, animate => $animate ),
        qr/--codec/, 'the default H.264 needs no --codec';

    for my $format ( qw(webm webm-av1) )
    {
        my $settings = { %$defaults, video_format => $format };

        like command_for( $state, export => $settings, animate => $animate ),
            qr/--codec (?:vp9|av1)/, "but '$format' does";
    }
}

# Native size means the absence of a limit, which is the absence of a flag.
SKIP:
{
    eval { require GlitchVape::GUI::Export; 1 }
        or skip 'GlitchVape::GUI::Export needs Gtk3', 1;

    my $settings =
        { %{ GlitchVape::GUI::Export::defaults() }, video_size => 0, };

    unlike command_for(
        state_for(),
        export  => $settings,
        animate => { frames => 24, fps => 12 }
        ),
        qr/--max-dim/, 'Native prints no --max-dim at all';
}

done_testing;
