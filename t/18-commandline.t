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

done_testing;
