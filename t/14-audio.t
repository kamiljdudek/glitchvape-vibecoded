#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Spec ();
use File::Temp ();

use Test::More;
use GlitchVape::Audio ();
use GlitchVape::Tools ();

# The pure parts -- the filter table, the chain builder, the arithmetic that
# says how long the result will be -- need nothing installed and are where the
# behaviour actually lives. Anything that decodes or encodes is skipped
# without ffmpeg rather than failing, as elsewhere in this suite.

# ---------------------------------------------------------------------------
# The filter table

{
    my $filters = GlitchVape::Audio::filters();

    cmp_ok scalar @$filters, '>=', 4, 'the filter table is populated';

    is_deeply [ map { $_->{ name } } @$filters ],
        [ qw(slowed wobble muffled reverb) ],
        'filters come back in chain order, not alphabetically';

    for my $f ( @$filters )
    {
        ok length $f->{ label },    "$f->{name} has a label";
        ok length $f->{ summary },  "$f->{name} has a summary";
        ok defined $f->{ default }, "$f->{name} has a default";

        cmp_ok $f->{ default }, '>=', $f->{ min },
            "$f->{name} default is inside its range";
        cmp_ok $f->{ default }, '<=', $f->{ max },
            "$f->{name} default is inside its range";
    }
}

# ---------------------------------------------------------------------------
# Validation

{
    my $ok = GlitchVape::Audio::resolve_filters( { slowed => 0.8 } );
    is_deeply $ok, { slowed => 0.8 }, 'a valid filter passes through';

    my $high = GlitchVape::Audio::resolve_filters( { slowed => 42 } );
    is $high->{ slowed }, 1.0,
        'a value above the range is clamped, not refused';

    my $low = GlitchVape::Audio::resolve_filters( { reverb => -3 } );
    is $low->{ reverb }, 0, 'a value below the range is clamped';

    is_deeply GlitchVape::Audio::resolve_filters( {} ), {},
        'no filters resolves to no filters';

    # A typo is worth stopping for: the alternative is a render that silently
    # lacks the sound the user asked for.
    local $@;
    ok !eval { GlitchVape::Audio::resolve_filters( { slwoed => 0.8 } ); 1 },
        'an unknown filter name dies';
    like $@, qr/no audio filter named/, 'and says so';

    local $@;
    ok !eval { GlitchVape::Audio::resolve_filters( { slowed => 'fast' } ); 1 },
        'a non-numeric amount dies';
}

# ---------------------------------------------------------------------------
# The chain

{
    is GlitchVape::Audio::filter_chain( {} ), q{},
        'no filters is an empty chain';

    my $slow = GlitchVape::Audio::filter_chain( { slowed => 0.8 } );
    like $slow, qr/asetrate=44100\*0\.8/, 'slowed resamples down';
    like $slow, qr/aresample=44100/,      'and back up to the working rate';

    # 1.0 is not a slowdown, and asking ffmpeg to resample to the rate it is
    # already at would cost a pass for nothing.
    is GlitchVape::Audio::filter_chain( { slowed => 1.0 } ), q{},
        'slowed at 1.0 contributes nothing';

    is GlitchVape::Audio::filter_chain( { reverb => 0 } ), q{},
        'a filter at zero contributes nothing';

    my $all = GlitchVape::Audio::filter_chain(
        { reverb => 0.5, slowed => 0.8, muffled => 0.6, wobble => 0.3 } );

    # Order is not a free choice: the room has to come after the tone
    # shaping, or a bright tail sits on a deliberately muffled source.
    my @order = $all =~ /(asetrate|vibrato|lowpass|aecho)/g;
    is_deeply \@order, [ qw(asetrate vibrato lowpass aecho) ],
        'the chain is ordered speed, wobble, tone, room';

    like $all, qr/highpass=f=80/, 'muffled also takes the bottom out';
}

# ---------------------------------------------------------------------------
# Lengths

{
    my $spec = { path => 'x.mp3', start => 10, end => 25, filters => {} };

    is GlitchVape::Audio::selection_length( $spec ), 15,
        'a selection is end - start';
    is GlitchVape::Audio::output_duration( $spec ), 15,
        'with no filters the result is the selection';

    is GlitchVape::Audio::speed( {} ), 1, 'no slowdown is 1x';
    is GlitchVape::Audio::speed( { slowed => 0.5 } ), 0.5,
        'slowed reports its rate';

    # Slowing stretches: this is the number the wizard shows, and the reason
    # it shows a resulting length at all rather than only the crop.
    $spec->{ filters } = { slowed => 0.75 };
    is GlitchVape::Audio::output_duration( $spec ), 20,
        'slowing to 0.75 makes 15 seconds into 20';

    $spec->{ filters } = { reverb => 0.5 };
    is GlitchVape::Audio::output_duration( $spec ), 15.5,
        'reverb adds its tail';

    # A backwards or empty selection is zero rather than negative, so nothing
    # downstream has to defend against a negative duration.
    is GlitchVape::Audio::selection_length( { start => 20, end => 10 } ), 0,
        'a backwards selection is zero';
    is GlitchVape::Audio::selection_length( {} ), 0, 'an empty spec is zero';
}

# ---------------------------------------------------------------------------
# The exclamation

{
    my $spec = { path => 'x.mp3', start => 0, end => 29.9 };
    ok !GlitchVape::Audio::is_long( $spec ),
        'just under 30 seconds is not long';

    $spec->{ end } = 30.1;
    ok GlitchVape::Audio::is_long( $spec ), 'just over 30 seconds is long';

    is GlitchVape::Audio::LONG_SELECTION, 30,
        'the threshold the interface warns at is 30 seconds';
}

# ---------------------------------------------------------------------------
# Describing

{
    is GlitchVape::Audio::format_time( 0 ),     '0:00.0', 'zero';
    is GlitchVape::Audio::format_time( 9.25 ),  '0:09.2', 'seconds';
    is GlitchVape::Audio::format_time( 61.5 ),  '1:01.5', 'past a minute';
    is GlitchVape::Audio::format_time( undef ), '0:00.0', 'undef is zero';

    my $spec = {
        path    => '/music/track.mp3',
        start   => 12,
        end     => 28,
        filters => { slowed => 0.8, reverb => 0.4 },
    };

    my $text = GlitchVape::Audio::describe( $spec );
    like $text, qr/track\.mp3/,     'describe names the file';
    like $text, qr/0:12\.0/,        'and where it starts';
    like $text, qr/slowed/,         'and what is on';
    like $text, qr/slowed.*reverb/, 'in chain order';

    is GlitchVape::Audio::describe( undef ), 'no audio',
        'nothing describes as nothing';
}

# ---------------------------------------------------------------------------
# Cache key parts

{
    my $spec = { path => 'x.mp3', start => 0, end => 5, filters => {} };

    my @bare = GlitchVape::Audio::spec_parts( $spec );
    ok scalar @bare, 'a spec contributes parts';

    $spec->{ filters } = { slowed => 0.8 };
    my @with = GlitchVape::Audio::spec_parts( $spec );

    # The stat fields of a path that does not exist come back undef, which is
    # fine for a digest and noisy in a join.
    my $flatten = sub {
        return join '|', map { $_ // q{} } @_;
    };

    isnt $flatten->( @bare ), $flatten->( @with ),
        'changing a filter changes the parts, so the preview cache cannot '
        . 'serve the previous chain';

    is_deeply [ GlitchVape::Audio::spec_parts( undef ) ], [],
        'no spec contributes nothing';
}

# ---------------------------------------------------------------------------
# Extensions

{
    ok GlitchVape::Audio::is_supported( 'a.mp3' ),  'mp3';
    ok GlitchVape::Audio::is_supported( 'a.FLAC' ), 'case does not matter';
    ok GlitchVape::Audio::is_supported( 'a.mp4' ),
        'a video file is a source too';
    ok !GlitchVape::Audio::is_supported( 'a.txt' ), 'but not everything';
    ok !GlitchVape::Audio::is_supported( undef ),   'and not nothing';
}

# ---------------------------------------------------------------------------
# Everything below decodes or encodes

unless ( GlitchVape::Tools::have( 'ffmpeg' )
    && GlitchVape::Tools::have( 'ffprobe' ) )
{
    done_testing;
    exit 0;
}

my $dir = File::Temp->newdir( 'gv_audio_XXXXXX', TMPDIR => 1 );

# Six seconds: silent for the first three, a tone for the last three. That
# shape is what makes the peak list checkable -- a uniform tone would pass a
# broken bucketing just as well as a correct one.
my $source = File::Spec->catfile( "$dir", 'source.wav' );

my $made = system(
    GlitchVape::Tools::find( 'ffmpeg' ),
    '-y',   '-loglevel', 'error',
    '-f',   'lavfi',
    '-i',   'aevalsrc=' . q{'0.9*sin(2*PI*440*t)*gt(t,3)'} . ':d=6:s=44100',
    '-c:a', 'pcm_s16le', $source
);

unless ( $made == 0 && -s $source )
{
    diag 'could not generate a test file with ffmpeg';
    done_testing;
    exit 0;
}

{
    my $probe = GlitchVape::Audio::probe( $source );

    cmp_ok abs( $probe->{ duration } - 6 ), '<', 0.1,
        'probe reads the duration';
    is $probe->{ rate }, 44_100, 'and the sample rate';
    ok $probe->{ channels } >= 1, 'and the channel count';

    local $@;
    ok !eval { GlitchVape::Audio::probe( "$dir/nope.mp3" ); 1 },
        'probing a missing file dies';
}

{
    my $peaks = GlitchVape::Audio::peaks( $source, buckets => 100 );

    is scalar @$peaks, 100, 'peaks comes back at the requested resolution';

    my @out_of_range = grep { $_ < 0 || $_ > 1 } @$peaks;
    is scalar @out_of_range, 0, 'every peak is a 0..1 magnitude';

    # The first half is silent and the second is not, which is the whole point
    # of the shape generated above.
    my $quiet = 0;
    $quiet += $peaks->[ $_ ] for 0 .. 40;
    my $loud = 0;
    $loud += $peaks->[ $_ ] for 59 .. 99;

    cmp_ok $quiet, '<', 0.5, 'the silent half reads as silent';
    cmp_ok $loud,  '>', 10,  'the loud half reads as loud';
}

{
    my $out = File::Spec->catfile( "$dir", 'plain.wav' );

    GlitchVape::Audio::render(
        spec   => { path => $source, start => 4, end => 6, filters => {} },
        output => $out,
    );

    ok -s $out, 'render writes a track';

    my $probe = GlitchVape::Audio::probe( $out );
    cmp_ok abs( $probe->{ duration } - 2 ), '<', 0.15,
        'a two-second selection renders two seconds';
}

{
    my $out = File::Spec->catfile( "$dir", 'slow.wav' );

    my $spec = {
        path    => $source,
        start   => 4,
        end     => 6,
        filters => { slowed => 0.5 },
    };

    GlitchVape::Audio::render( spec => $spec, output => $out );

    my $probe = GlitchVape::Audio::probe( $out );

    # Halving the rate doubles the length, and output_duration is what the
    # wizard promised the user before the render happened. The two agreeing
    # is the check that matters.
    cmp_ok abs( $probe->{ duration } - 4 ), '<', 0.15,
        'slowing to 0.5 doubles the length';
    cmp_ok
        abs(
        $probe->{ duration } - GlitchVape::Audio::output_duration( $spec ) ),
        '<', 0.15,
        'and the estimate the wizard showed matches what was rendered';
}

{
    local $@;
    ok !eval {
        GlitchVape::Audio::render(
            spec   => { path => $source, start => 5, end => 5 },
            output => File::Spec->catfile( "$dir", 'empty.wav' ),
        );
        1;
    },
        'an empty selection is refused rather than producing a zero-length file';
}

# ---------------------------------------------------------------------------
# One file, any number of generated tracks

{
    my $file = { path      => 'x.mp3', start => 0, end => 10, filters => {} };
    my $dial = { generated => [ { kind => 'dtmf', text => 'call me' } ] };
    my $both = { %$file, %$dial };

    ok GlitchVape::Audio::has_file( $file ), 'a path is a file';
    ok !GlitchVape::Audio::has_generated( $file ),
        'and contributes no generated tracks';
    ok GlitchVape::Audio::has_generated( $dial ), 'a phrase is generated';
    ok !GlitchVape::Audio::has_file( $dial ),     'and is not a file';
    ok GlitchVape::Audio::has_file( $both )
        && GlitchVape::Audio::has_generated( $both ),
        'a spec can be both';

    my @none = GlitchVape::Audio::generated( $file );
    is scalar @none, 0,
        'generated() on a spec with none is an empty list rather than undef';

    # Generated alone: the longest of them is the whole soundtrack.
    my $dialled = GlitchVape::Audio::generated_duration( $dial );
    cmp_ok $dialled, '>', 0, 'a phrase has a duration';
    is GlitchVape::Audio::output_duration( $dial ), $dialled,
        'and on its own that duration is the whole track';

    is GlitchVape::Audio::generated_duration( $file ), 0,
        'a spec with no generated tracks generates for no time';

    # The answer that matters: with a file, the file decides. Everything else
    # is fitted to it rather than the other way round, so the crop the wizard
    # measured is the length of the finished video.
    is GlitchVape::Audio::output_duration( $both ),
        GlitchVape::Audio::output_duration( $file ),
        'with a file present the file decides the length';

    my $slow = { %$both, filters => { slowed => 0.5 } };
    is GlitchVape::Audio::output_duration( $slow ), 20,
        'and it is the filtered file length, not the raw crop';
}

# They stack, and the longest of them wins when there is no file.
{
    my $spec = {
        generated => [
            { kind => 'static', seconds => 4 },
            { kind => 'dtmf',   text    => 'hi' },
            { kind => 'static', seconds => 25 },
        ],
    };

    my @three = GlitchVape::Audio::generated( $spec );
    is scalar @three, 3, 'three generated tracks are three generated tracks';

    is GlitchVape::Audio::generated_duration( $spec ), 25,
        'the longest sets the length';
    is GlitchVape::Audio::output_duration( $spec ), 25,
        'and with no file that is the length of the result';

    # Two of the same kind is an ordinary thing to ask for, not a collision.
    my @kinds = map { $_->{ kind } } GlitchVape::Audio::generated( $spec );
    is_deeply \@kinds, [ qw(static dtmf static) ],
        'two of one kind coexist, in the order they were added';
}

# A long track is as slow to encode as a long crop, so it earns the same
# exclamation.
{
    ok !GlitchVape::Audio::is_long(
        { generated => [ { kind => 'dtmf', text => 'hi' } ] } ),
        'a short phrase is not long';

    ok GlitchVape::Audio::is_long(
        { generated => [ { kind => 'dtmf', text => 'a' x 200 } ] } ),
        'a phrase over thirty seconds is';

    ok GlitchVape::Audio::is_long(
        { generated => [ { kind => 'static', seconds => 90 } ] } ),
        'and so is a long bed of static';

    ok GlitchVape::Audio::is_long(
        {
            path      => 'x.mp3',
            start     => 0,
            end       => 40,
            generated => [ { kind => 'dtmf', text => 'hi' } ],
        }
        ),
        'and so is a long crop with a short phrase under it';

    # But not the other way round. The file decides the length, so ten minutes
    # of static under a five-second crop produces five seconds of video -- and
    # warning about that would be warning about nothing.
    ok !GlitchVape::Audio::is_long(
        {
            path      => 'x.mp3',
            start     => 0,
            end       => 5,
            filters   => {},
            generated => [ { kind => 'static', seconds => 600 } ],
        }
        ),
        'a long generated track under a short crop is not long, because the '
        . 'crop is what will be rendered';

    # The warning is about the finished length, so a filter that stretches it
    # counts towards it.
    ok GlitchVape::Audio::is_long(
        {
            path    => 'x.mp3',
            start   => 0,
            end     => 20,
            filters => { slowed => 0.5 },
        }
        ),
        'and a crop under the threshold that slowing pushes over it is';
}

# What gets cut when the file is shorter than something under it. Static is
# exempt: it has no end to be cut short of.
{
    my $room = {
        path      => 'x.mp3',
        start     => 0,
        end       => 60,
        filters   => {},
        generated => [ { kind => 'dtmf', text => 'hello there' } ],
    };

    my @fits = GlitchVape::Audio::truncated( $room );
    is scalar @fits, 0, 'a phrase that fits is not reported';

    # Two seconds of room and a phrase that dials for far longer.
    my $tight = { %$room, end => 2 };
    my @cut   = GlitchVape::Audio::truncated( $tight );

    is scalar @cut, 1, 'a phrase that does not fit is';
    like $cut[ 0 ][ 0 ], qr/hello there/, 'named by its description';
    cmp_ok $cut[ 0 ][ 1 ], '>', 0, 'with how much of it will be lost';

    my $noise = {
        %$room,
        end       => 3,
        generated => [ { kind => 'static', seconds => 300 } ],
    };
    my @snow = GlitchVape::Audio::truncated( $noise );
    is scalar @snow, 0,
        'static is never reported as cut short: its length is a request '
        . 'rather than a consequence';

    my @loose = GlitchVape::Audio::truncated(
        { generated => [ { kind => 'dtmf', text => 'a' x 100 } ] } );
    is scalar @loose, 0,
        'and nothing is cut when there is no file to be cut against';
}

{
    my $file = { path => 'x.mp3', start => 0, end => 10, filters => {} };

    my $text = GlitchVape::Audio::describe(
        {
            %$file,
            generated => [
                { kind => 'dtmf',   text    => 'call me' },
                { kind => 'static', seconds => 5 },
            ],
        }
    );

    like $text, qr/x[.]mp3/,  'describe names the file';
    like $text, qr/call me/,  'and quotes the dialled track';
    like $text, qr/static/,   'and names the static';
    like $text, qr/[+].*[+]/, 'showing all three as mixed';

    my $alone = GlitchVape::Audio::describe(
        { generated => [ { kind => 'dtmf', text => 'call me' } ] } );
    like $alone,   qr/call me/, 'one track alone describes as itself';
    unlike $alone, qr/[+]/,     'with nothing to mix it with';

    is GlitchVape::Audio::describe( {} ), 'no audio',
        'an empty spec is still nothing';
}

{
    my $bare = { path => 'x.mp3', start => 0, end => 5, filters => {} };

    my $flat = sub {
        return join '|', map { $_ // q{} } @_;
    };

    my $one = { %$bare, generated => [ { kind => 'dtmf', text => 'hi' } ], };
    my $two = {
        %$bare,
        generated => [
            { kind => 'dtmf',   text    => 'hi' },
            { kind => 'static', seconds => 5 },
        ],
    };

    isnt $flat->( GlitchVape::Audio::spec_parts( $bare ) ),
        $flat->( GlitchVape::Audio::spec_parts( $one ) ),
        'adding a track changes the cache parts, so the preview cache '
        . 'cannot serve the version without it';

    isnt $flat->( GlitchVape::Audio::spec_parts( $one ) ),
        $flat->( GlitchVape::Audio::spec_parts( $two ) ),
        'and so does adding a second';

    ok scalar(
        GlitchVape::Audio::spec_parts(
            { generated => [ { kind => 'static', seconds => 5 } ] }
        )
        ),
        'a generated track alone contributes parts';
}

{
    local $@;
    ok !eval {
        GlitchVape::Audio::render( spec => {}, output => '/dev/null' );
        1;
    }, 'a spec with nothing in it is refused';
}

done_testing;
