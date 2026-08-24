package GlitchVape::Audio;

use strict;
use warnings;

# L</describe> contains a literal '–' and '·'. Without this the source bytes
# are read as Latin-1 and get encoded a second time on the way out -- to
# mojibake on a UTF-8 terminal, and to the same through Glib into a Gtk label.
# The same reason bin/glitchvape and GlitchVape::GUI do it.
use utf8;

use File::Spec ();

use GlitchVape::Generator ();
use GlitchVape::Tools     ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Audio - cropping, filtering and rendering an audio track

=head1 DESCRIPTION

An animation is a couple of seconds of frames. A track is a couple of minutes.
This module is the part that reconciles the two: it reads a source file, cuts
the section the user chose, runs it through a filter chain, and writes a WAV
that L<GlitchVape::Animate> muxes into the video while repeating the loop for
as long as the audio lasts.

Nothing here draws anything or knows about Gtk. The interface's crop widget
asks for L</peaks> and the wizard's controls are generated from L</filters>,
in the same way L<GlitchVape::GUI::Params> builds itself from
L<GlitchVape::Registry> -- so a filter added below appears in the wizard, in
C<--audio-filter> validation and in C<--list-audio-filters> without any of
them being edited.

=head1 THE SPEC

One hashref describes an added soundtrack completely, and is what travels from
the wizard to C<GlitchVape::render>, and from C<--audio> flags to the same
place:

    {
        path    => 'track.mp3',
        start   => 12.5,               # seconds into the source
        end     => 28.0,
        filters => { slowed => 0.8, reverb => 0.4 },
        gain    => 1.0,
        generated => [
            { kind => 'dtmf',   text => 'call me' },
            { kind => 'static', tone => 0.35 },
        ],
    }

C<filters> holds only the filters that are switched on. A missing key is off,
which is why it is a plain hash rather than one carrying an C<enabled> flag
per entry: the spec is meant to be readable on a command line.

=head2 One file, any number of generated tracks

Both halves are optional. A C<path> alone is a cropped piece of music;
C<generated> alone is whatever L<GlitchVape::Generator> made up; together they
are all summed.

There is one file because there is one crop wizard, and a list of generated
tracks because stacking a bed of static under a dialled phrase is a reasonable
thing to want and nothing in the mixer cares how many inputs it has.

=head2 Which one is in charge

When a file is present B<the file decides the length> and every generated
track is asked to cover it. What covering means is the generator's own
business: static simply carries on, while a dialled phrase plays once and then
gives way to silence and a reopened line, because a sentence looped is a
stutter rather than a sentence.

With no file the longest generated track sets the length and the others fill
out to it.

The vaporwave filters apply to the file only. Slowing is a resample, and a
resampled DTMF tone is no longer on the DTMF grid -- it stops being a dialled
number and becomes two detuned sine waves.

=cut

# Everything is rendered at CD rate. The source may be anything; resampling
# once here means the filter chain, the muxer and the preview player all agree
# on a rate rather than each guessing.
use constant RATE => 44_100;

# Long enough that a crop boundary in the middle of a waveform does not click,
# short enough not to be heard as a fade. The out-fade is longer because a
# reverb tail ending abruptly is more noticeable than an attack starting late.
use constant FADE_IN  => 0.03;
use constant FADE_OUT => 0.08;

# Selections longer than this get an exclamation in the interface: the loop is
# repeated to cover the track, so half a minute of audio is a long render and
# a large file from what looks like one button press.
use constant LONG_SELECTION => 30;

=head1 FILTERS

Four, declared the way effects are. Each has a single 0..1-ish amount, because
a wizard page is not a mixing desk: the useful range of each of these is
narrow, and the interesting decision is which ones are on.

C<order> is the position in the chain and is not a free choice, for the same
reason effects have stages. Speed comes first because it is a resample and
everything after it should hear the slowed material; the tape wobble belongs
with it; tone shaping comes next; and the room is last, because a bright
reverb tail on a deliberately muffled source sounds like a mistake rather than
like a room.

=cut

my %FILTER = (
    slowed => {
        order   => 10,
        label   => 'Slowed',
        summary => 'Play it slower and lower, the way a tape at the wrong '
            . 'speed does',
        min     => 0.50,
        max     => 1.00,
        default => 0.80,
        digits  => 2,
        unit    => 'x speed',
        doc     =>
            "Resamples rather than time-stretches, so the pitch drops with the\n"
            . "speed -- which is the whole sound. A pitch-corrected slowdown is\n"
            . 'a different, and much less interesting, effect.',
        build => sub {
            my ( $value ) = @_;

            # 1.0 is a no-op, and asetrate at exactly the source rate would
            # still cost a resample pass.
            return () if $value >= 0.999;

            return ( sprintf( 'asetrate=%d*%.4f', RATE, $value ),
                sprintf( 'aresample=%d', RATE ) );
        },
    },

    wobble => {
        order   => 20,
        label   => 'Wow & flutter',
        summary => 'Slow pitch wobble, a worn tape transport',
        min     => 0.00,
        max     => 1.00,
        default => 0.25,
        digits  => 2,
        unit    => 'depth',
        doc     =>
            "Subtle at the default, and meant to be: this is the thing that\n"
            . "reads as a dub of a dub rather than as a file. Pushed past\n"
            . 'about 0.6 it stops sounding like tape and starts sounding seasick.',
        build => sub {
            my ( $value ) = @_;

            return () if $value <= 0.01;

            # vibrato's depth is 0..1 and is already extreme at 0.3, so the
            # slider covers the part of the range that is usable.
            return ( sprintf 'vibrato=f=0.8:d=%.3f', $value * 0.3 );
        },
    },

    muffled => {
        order   => 30,
        label   => 'Muffled tape',
        summary => 'Heard through a shopping-centre ceiling',
        min     => 0.00,
        max     => 1.00,
        default => 0.65,
        digits  => 2,
        unit    => 'amount',
        doc     =>
            "Rolls the top off and takes the bottom out. The amount moves the\n"
            . "low-pass corner logarithmically from 16 kHz down to 1.2 kHz --\n"
            . "0.65 puts it around 3 kHz, which is roughly a ceiling speaker.\n"
            . 'The high-pass sits at 80 Hz throughout, where a small speaker ends.',
        build => sub {
            my ( $value ) = @_;

            return () if $value <= 0.01;

            # Logarithmic, because pitch is: a linear sweep from 16 kHz spends
            # most of the slider in the range where nothing audible changes.
            my $cutoff = 16_000 * ( 1200 / 16_000 )**$value;

            return ( 'highpass=f=80', sprintf( 'lowpass=f=%d', $cutoff ) );
        },
    },

    reverb => {
        order   => 40,
        label   => 'Reverb',
        summary => 'The other half of "slowed + reverb"',
        min     => 0.00,
        max     => 1.00,
        default => 0.40,
        digits  => 2,
        unit    => 'wet',
        doc     =>
            "ffmpeg has no true reverb without LADSPA plugins, so this is a\n"
            . "four-tap echo tuned to read as a hall rather than as a slapback.\n"
            . 'It lengthens the result by half a second: the tail of the last tap.',
        build => sub {
            my ( $value ) = @_;

            return () if $value <= 0.02;

            # Four taps at prime-ish spacings. Even spacing gives a flutter
            # echo -- an audible pitch to the tail -- rather than a room.
            my @decay =
                map { sprintf '%.3f', $value * $_ } ( 0.55, 0.42, 0.30, 0.20 );

            return ( 'aecho=0.85:0.9:80|180|320|500:' . join '|', @decay );
        },
    },
);

# How much longer than its input the chain makes the output. Only the last
# echo tap outlives the material, and only the resample changes its length.
use constant REVERB_TAIL => 0.5;

=head2 filters()

The filter declarations, in chain order: a list of
C<< { name, label, summary, doc, min, max, default, digits, unit } >>. What
the wizard builds its controls from.

=cut

sub filters
{
    my @names = sort { $FILTER{ $a }{ order } <=> $FILTER{ $b }{ order } }
        keys %FILTER;

    return [
        map {
            {
                name    => $_,
                label   => $FILTER{ $_ }{ label },
                summary => $FILTER{ $_ }{ summary },
                doc     => $FILTER{ $_ }{ doc },
                min     => $FILTER{ $_ }{ min },
                max     => $FILTER{ $_ }{ max },
                default => $FILTER{ $_ }{ default },
                digits  => $FILTER{ $_ }{ digits },
                unit    => $FILTER{ $_ }{ unit },
            }
        } @names
    ];
}

=head2 filter_names()

Just the names, in chain order.

=cut

sub filter_names
{
    return map { $_->{ name } } @{ filters() };
}

=head2 resolve_filters( $given )

Validate and clamp a C<< { name => amount } >> hash. Dies on a name that is
not a filter -- a typo in C<--audio-filter> is worth stopping for, since the
alternative is a render that silently lacks the sound the user asked for.

Values outside the declared range are clamped rather than refused: a slider
handing back 1.0000000000002 is not a mistake worth a message.

=cut

sub resolve_filters
{
    my ( $given ) = @_;

    return {} unless ref $given eq 'HASH';

    my %out;
    for my $name ( sort keys %$given )
    {
        my $spec = $FILTER{ $name };

        unless ( $spec )
        {
            die "GlitchVape::Audio: no audio filter named '$name'.\n"
                . '  Available: '
                . join( ', ', filter_names() ) . "\n";
        }

        my $value = $given->{ $name };
        next unless defined $value && length $value;

        unless ( $value =~ /^-?\d+(?:\.\d+)?$/ )
        {
            die "GlitchVape::Audio: audio filter '$name' takes a number "
                . "between $spec->{min} and $spec->{max}, got '$value'\n";
        }

        $value = $spec->{ min } if $value < $spec->{ min };
        $value = $spec->{ max } if $value > $spec->{ max };

        $out{ $name } = $value + 0;
    }

    return \%out;
}

=head2 filter_chain( $filters )

The C<-af> argument for a resolved filter hash, or the empty string when
nothing is switched on.

=cut

sub filter_chain
{
    my ( $filters ) = @_;

    return q{} unless ref $filters eq 'HASH';

    my @parts;
    for my $name (
        sort { $FILTER{ $a }{ order } <=> $FILTER{ $b }{ order } }
        keys %$filters
        )
    {
        next unless $FILTER{ $name };
        push @parts, $FILTER{ $name }{ build }->( $filters->{ $name } );
    }

    return join ',', @parts;
}

=head2 speed( $filters )

The playback rate the chain applies, as a multiplier. 1 unless C<slowed> is on.

=cut

sub speed
{
    my ( $filters ) = @_;

    return 1 unless ref $filters eq 'HASH';

    my $value = $filters->{ slowed };
    return 1 unless defined $value && $value > 0;

    return $value;
}

=head2 has_file( $spec )

Whether a cropped audio file is part of this soundtrack.

=cut

sub has_file
{
    my ( $spec ) = @_;

    return 0 unless ref $spec eq 'HASH';
    return 0 unless defined $spec->{ path } && length $spec->{ path };

    return 1;
}

=head2 generated( $spec )

The generated tracks, as a list. Empty when there are none, so callers can
iterate without checking first.

=cut

sub generated
{
    my ( $spec ) = @_;

    return () unless ref $spec eq 'HASH';

    my $list = $spec->{ generated };
    return () unless ref $list eq 'ARRAY';

    return @$list;
}

=head2 has_generated( $spec )

Whether there are any.

=cut

sub has_generated
{
    my ( $spec ) = @_;

    my @list = generated( $spec );
    return scalar @list;
}

=head2 generated_duration( $spec )

The longest natural length among the generated tracks, which is what decides
how long the result runs when there is no file to overrule them.

=cut

sub generated_duration
{
    my ( $spec ) = @_;

    my $longest = 0;

    for my $track ( generated( $spec ) )
    {
        my $seconds = GlitchVape::Generator::duration( $track );
        $longest = $seconds if $seconds > $longest;
    }

    return $longest;
}

=head2 truncated( $spec )

Which generated tracks will not fit under the file, as a list of
C<< [ description, seconds over ] >>.

The file decides the length, so anything longer than it is cut. That is the
rule working, and a surprising thing to meet silently when what disappears is
the end of a sentence somebody typed -- so both the command line and the
interface ask this in order to say so.

Static is exempt: it has no natural end to be cut short of, and its length is
a request rather than a consequence.

=cut

sub truncated
{
    my ( $spec ) = @_;

    return () unless has_file( $spec );

    my $room = output_duration( $spec );
    my @over;

    for my $track ( generated( $spec ) )
    {
        next unless GlitchVape::Generator::has_ending( $track->{ kind } );

        my $seconds = GlitchVape::Generator::duration( $track );
        next unless $seconds > $room;

        push @over,
            [ GlitchVape::Generator::describe( $track ), $seconds - $room ];
    }

    return @over;
}

=head2 output_duration( $spec )

How long the finished track will be, in seconds.

An estimate where a file is involved, and deliberately so: slowing divides the
length exactly, but the reverb tail depends on where the material actually
stops. Close enough for the wizard to say what it is about to produce, and
never used to cut anything -- the encoder measures the real file.

With no file it is not an estimate at all: every part of a dialled phrase is a
sample count L<GlitchVape::DTMF> chose.

=cut

sub output_duration
{
    my ( $spec ) = @_;

    # No file: the longest generated track is the whole soundtrack, so its
    # length is the length. With a file present the file wins and everything
    # else is fitted to it -- see L</Which one is in charge>.
    unless ( has_file( $spec ) )
    {
        return generated_duration( $spec );
    }

    my $length = selection_length( $spec );
    return 0 unless $length > 0;

    my $seconds = $length / speed( $spec->{ filters } );

    my $reverb = $spec->{ filters }{ reverb };
    if ( defined $reverb && $reverb > 0.02 )
    {
        $seconds += REVERB_TAIL;
    }

    return $seconds;
}

=head2 selection_length( $spec )

C<end - start>, floored at zero.

=cut

sub selection_length
{
    my ( $spec ) = @_;

    return 0 unless ref $spec eq 'HASH';

    my $start = $spec->{ start } || 0;
    my $end   = $spec->{ end };
    return 0 unless defined $end;

    my $length = $end - $start;
    return 0 if $length < 0;

    return $length;
}

=head2 is_long( $spec )

Whether the finished soundtrack passes C<LONG_SELECTION>, which is what puts
the exclamation on the wizard's crop page.

On the length of the B<result> rather than on any one part of it, because the
warning is about what the render is going to cost and the render costs one
encode of the finished length. A ten-minute bed of static under a five-second
crop produces five seconds of video, and warning about it would be warning
about nothing.

=cut

sub is_long
{
    my ( $spec ) = @_;
    return output_duration( $spec ) > LONG_SELECTION;
}

=head1 READING A SOURCE

=head2 probe( $path )

C<< { duration, rate, channels } >> from C<ffprobe>. Dies if the file has no
audio stream, which is the one failure worth reporting up front -- the file
chooser cannot tell a video with sound from one without.

=cut

sub probe
{
    my ( $path ) = @_;

    die "GlitchVape::Audio: no such file: $path\n" unless -f $path;

    my $ffprobe = GlitchVape::Tools::require_tool( 'ffprobe', 'to read audio' );

    my $out = GlitchVape::Tools::capture(
        $ffprobe,                      '-v',
        'error',                       '-select_streams',
        'a:0',                         '-show_entries',
        'stream=sample_rate,channels', '-show_entries',
        'format=duration',             '-of',
        'default=noprint_wrappers=1',  $path,
    );

    my $text = $out;
    $text = q{} unless defined $text;

    my ( $duration ) = $text =~ /^duration=([\d.]+)/m;
    my ( $rate )     = $text =~ /^sample_rate=(\d+)/m;
    my ( $channels ) = $text =~ /^channels=(\d+)/m;

    unless ( defined $duration && defined $rate )
    {
        die
            "GlitchVape::Audio: $path has no audio track that ffmpeg can read.\n";
    }

    return {
        duration => $duration + 0,
        rate     => $rate + 0,
        channels => $channels || 1,
    };
}

# The waveform is drawn from a mono downmix at a rate far below anything
# audible: 2 kHz is 40 samples per pixel on a wide window, which is enough for
# the peak of each column to be the real peak rather than a sample of it.
use constant PEAK_RATE => 2000;

=head2 peaks( $path, %arg )

    buckets => 1200      how many columns to reduce the file to

An arrayref of C<$buckets> values in 0..1: the loudest sample in each slice of
the file. What the crop widget draws.

Decoding a whole file to measure it costs about a second for an album track,
so callers on a main loop should do this off it -- L<GlitchVape::GUI::Audio>
runs it in a child.

=cut

sub peaks
{
    my ( $path, %arg ) = @_;

    my $buckets = $arg{ buckets } || 1200;
    $buckets = 1 if $buckets < 1;

    my $ffmpeg = GlitchVape::Tools::require_tool( 'ffmpeg', 'to read audio' );

    my $pcm = _decode_pcm( $ffmpeg, $path );

    my $samples = length( $pcm ) / 2;
    return [ ( 0 ) x $buckets ] unless $samples > 0;

    # Signed 16-bit little-endian, which is what the -f s16le above asked for
    # regardless of what the host architecture would have chosen.
    my @sample = unpack 's<*', $pcm;

    my @out;
    for my $n ( 0 .. $buckets - 1 )
    {
        my $from = int( $n * $samples / $buckets );
        my $to   = int( ( $n + 1 ) * $samples / $buckets ) - 1;
        $to = $from if $to < $from;

        my $peak = 0;
        for my $i ( $from .. $to )
        {
            my $v = $sample[ $i ];
            $v    = -$v if $v < 0;
            $peak = $v  if $v > $peak;
        }

        push @out, $peak / 32_768;
    }

    return \@out;
}

# Read raw PCM from ffmpeg on a pipe. Not GlitchVape::Tools::capture, which
# leaves the handle on whatever layers the process defaults to: this is binary
# and a stray :utf8 layer would corrupt every sample above 127.
sub _decode_pcm
{
    my ( $ffmpeg, $path ) = @_;

    my @argv = (
        $ffmpeg,     '-v',  'error', '-i',
        $path,       '-f',  's16le', '-acodec',
        'pcm_s16le', '-ac', '1',     '-ar',
        PEAK_RATE,   '-',
    );

    my $pid = open my $fh, '-|';
    die "GlitchVape::Audio: cannot run ffmpeg: $!\n" unless defined $pid;

    unless ( $pid )
    {    # child
        open STDERR, '>', File::Spec->devnull or exit 127;
        exec { $argv[ 0 ] } @argv or exit 127;
    }

    binmode $fh, ':raw';
    my $pcm = do { local $/ = undef; <$fh> };
    close $fh;

    $pcm = q{} unless defined $pcm;

    return $pcm;
}

=head1 RENDERING

=head2 render( %arg )

    spec   => the audio spec
    output => path to write, .wav

Write the soundtrack. Returns the output path.

Dispatches on which halves of the spec are filled in: a file is cut and
filtered, a phrase is dialled, and when there are both the dialling is fitted
to the file's length and the two are mixed.

Short fades are added at both ends of a cut file whatever the filter chain is.
They are not offered as a filter because they are not a choice: a crop almost
never lands on a zero crossing, and without them every added track begins and
ends with a click.

=cut

sub render
{
    my ( %arg ) = @_;

    my $spec   = $arg{ spec }   or die "GlitchVape::Audio: no spec given\n";
    my $output = $arg{ output } or die "GlitchVape::Audio: no output given\n";

    my $file = has_file( $spec );
    my @made = generated( $spec );

    unless ( $file || @made )
    {
        die "GlitchVape::Audio: the spec has neither a file nor a "
            . "generated track\n";
    }

    return _render_file( $spec, $output ) unless @made;

    # One generated track and nothing to mix it with is just that track: no
    # temporary directory, no filter graph, no second pass through ffmpeg.
    if ( !$file && @made == 1 )
    {
        return GlitchVape::Generator::render(
            spec   => $made[ 0 ],
            output => $output,
        );
    }

    return _render_mix( $spec, $output );
}

# Everything summed. The file, if there is one, is rendered exactly as it
# would be on its own; then every generated track is asked to cover whatever
# length came out of that, and the lot goes through one amix.
sub _render_mix
{
    my ( $spec, $output ) = @_;

    require File::Temp;

    my $ffmpeg = GlitchVape::Tools::require_tool( 'ffmpeg', 'to mix audio' );

    my $dir = File::Temp->newdir( 'glitchvape_mix_XXXXXX', TMPDIR => 1 );

    my @input;
    my @part;
    my $length;

    if ( has_file( $spec ) )
    {
        my $track = File::Spec->catfile( "$dir", 'track.wav' );
        _render_file( $spec, $track );

        # Measured rather than estimated. output_duration is honest about
        # being an approximation, and this is the number every other track has
        # to land on exactly or amix will cut one of them short.
        $length = probe( $track )->{ duration };

        my $gain = $spec->{ gain };
        $gain = 1 unless defined $gain;

        push @input, $track;
        push @part, sprintf 'volume=%.3f', $gain;
    }
    else
    {
        $length = generated_duration( $spec );
    }

    my $n = 0;
    for my $track ( generated( $spec ) )
    {
        my $path = File::Spec->catfile( "$dir", sprintf 'gen%02d.wav', $n );

        # Each generator applies its own level as it synthesises, so there is
        # nothing to set here -- one fewer filter in the graph, and the level
        # that was auditioned is the level that is mixed.
        GlitchVape::Generator::render(
            spec    => $track,
            output  => $path,
            fill_to => $length,
        );

        push @input, $path;
        push @part,  undef;
        $n++;
    }

    _mix( $ffmpeg, \@input, \@part, $output );

    return $output;
}

# One amix over however many inputs there are.
sub _mix
{
    my ( $ffmpeg, $input, $part, $output ) = @_;

    my @chain;
    my @label;

    for my $n ( 0 .. $#$input )
    {
        my $label = "a$n";
        push @label, "[$label]";

        # asetpts=PTS-STARTPTS on every input: one that arrives with a
        # non-zero initial timestamp otherwise offsets the whole mix.
        my $steps =
            sprintf
            'aformat=sample_fmts=fltp:sample_rates=%d:channel_layouts=stereo,'
            . 'asetpts=PTS-STARTPTS', RATE;

        $steps .= ',' . $part->[ $n ] if defined $part->[ $n ];

        push @chain, sprintf '[%d:a:0]%s[%s]', $n, $steps, $label;
    }

    # normalize=0 because amix would otherwise divide every input by their
    # number to guard against clipping, which would make a mix quieter the
    # more was added to it and make the levels chosen in the wizard mean
    # nothing. The limiter guards against clipping instead, and only when it
    # has to.
    push @chain,
        sprintf '%samix=inputs=%d:duration=first:normalize=0:'
        . 'dropout_transition=0,alimiter=limit=0.95[out]',
        join( q{}, @label ), scalar @$input;

    my @argv = ( $ffmpeg, '-y', '-loglevel', 'error' );
    push @argv, '-i', $_ for @$input;

    push @argv,
        '-filter_complex', join( ';', @chain ),
        '-map',            '[out]',
        '-ac',             '2',
        '-ar',             RATE,
        '-c:a',            'pcm_s16le',
        $output;

    my $rc = system( @argv );

    die "GlitchVape::Audio: ffmpeg failed mixing the soundtrack (exit "
        . ( $rc >> 8 ) . ")\n"
        unless $rc == 0 && -s $output;

    return $output;
}

sub _render_file
{
    my ( $spec, $output ) = @_;

    my $path = $spec->{ path }
        or die "GlitchVape::Audio: the audio spec has no path\n";
    die "GlitchVape::Audio: no such file: $path\n" unless -f $path;

    my $length = selection_length( $spec );
    die "GlitchVape::Audio: the selection is empty\n" unless $length > 0;

    my $ffmpeg = GlitchVape::Tools::require_tool( 'ffmpeg', 'to render audio' );

    my $filters = resolve_filters( $spec->{ filters } );
    my $chain   = filter_chain( $filters );

    my @chain;
    push @chain, $chain if length $chain;
    push @chain, _fades( $spec );

    my @argv = (
        $ffmpeg, '-y', '-loglevel', 'error',

        # -ss before -i seeks by keyframe before decoding, which is the
        # difference between instant and decoding the whole file to reach
        # minute four of it.
        '-ss', sprintf( '%.3f', $spec->{ start } || 0 ),
        '-t',  sprintf( '%.3f', $length ),
        '-i',  $path,
    );

    push @argv, '-af', join( ',', @chain ) if @chain;

    push @argv, '-ac', '2', '-ar', RATE, '-c:a', 'pcm_s16le', $output;

    my $rc = system( @argv );

    die "GlitchVape::Audio: ffmpeg failed rendering the audio track (exit "
        . ( $rc >> 8 ) . ")\n"
        unless $rc == 0 && -s $output;

    return $output;
}

sub _fades
{
    my ( $spec ) = @_;

    my $duration = output_duration( $spec );

    my @fades = ( sprintf 'afade=t=in:st=0:d=%.3f', FADE_IN );

    # A fade-out placed past the end of a stream never runs, so a selection
    # shorter than the fade itself gets only the fade in.
    my $out_at = $duration - FADE_OUT;
    return @fades if $out_at <= 0;

    push @fades, sprintf 'afade=t=out:st=%.3f:d=%.3f', $out_at, FADE_OUT;

    return @fades;
}

=head1 DESCRIBING

=head2 format_time( $seconds )

C<m:ss.t>. Used by the wizard's readouts, the interface's track row and the
command-line summary, so all three spell a position the same way.

=cut

sub format_time
{
    my ( $seconds ) = @_;

    $seconds = 0 unless defined $seconds && $seconds > 0;

    my $minutes = int( $seconds / 60 );
    my $rest    = $seconds - $minutes * 60;

    return sprintf '%d:%04.1f', $minutes, $rest;
}

=head2 describe( $spec )

One line naming the file, the section and the chain, for a status bar.

=cut

sub describe
{
    my ( $spec ) = @_;

    return 'no audio' unless ref $spec eq 'HASH';

    my @halves;

    if ( has_file( $spec ) )
    {
        require File::Basename;

        my $text = sprintf '%s  %s–%s',
            File::Basename::basename( $spec->{ path } ),
            format_time( $spec->{ start } || 0 ),
            format_time( $spec->{ end } );

        my @on = sort { $FILTER{ $a }{ order } <=> $FILTER{ $b }{ order } }
            grep { $FILTER{ $_ } } keys %{ $spec->{ filters } || {} };

        if ( @on )
        {
            $text .= '  ·  ' . join ' + ',
                map { lc $FILTER{ $_ }{ label } } @on;
        }

        push @halves, $text;
    }

    for my $track ( generated( $spec ) )
    {
        push @halves, GlitchVape::Generator::describe( $track );
    }

    return 'no audio' unless @halves;

    return join '  +  ', @halves;
}

=head2 spec_parts( $spec )

The pieces of a spec that determine the rendered audio, flattened for a cache
key. The source file's size and modification time are folded in as well, so
replacing the track on disk without renaming it does not serve the previous
one from the cache -- the same reason
L<GlitchVape::GUI::State/cache_key> stats the image.

=cut

sub spec_parts
{
    my ( $spec ) = @_;

    return () unless ref $spec eq 'HASH';

    my @parts;

    if ( has_file( $spec ) )
    {
        my @stat = stat( $spec->{ path } );

        push @parts, 'audio', $spec->{ path }, $stat[ 7 ], $stat[ 9 ],
            $spec->{ start }, $spec->{ end };

        my $filters = $spec->{ filters } || {};
        for my $name ( sort keys %$filters )
        {
            push @parts, $name, $filters->{ $name };
        }

        push @parts, 'gain', $spec->{ gain };
    }

    for my $track ( generated( $spec ) )
    {
        push @parts, GlitchVape::Generator::spec_parts( $track );
    }

    return @parts;
}

=head2 is_supported( $path )

Whether the extension is one of the audio formats the file chooser offers.
Advisory only: ffmpeg reads a great deal more than this, and an unusual
extension is worth attempting rather than refusing.

=cut

my %SUPPORTED = map { $_ => 1 }
    qw(mp3 wav flac m4a aac ogg oga opus wma aiff aif mp4 mkv webm mov);

sub is_supported
{
    my ( $path ) = @_;

    return 0 unless defined $path;

    my ( $ext ) = lc( $path ) =~ /\.([^.]+)\z/;
    return 0 unless defined $ext;

    return $SUPPORTED{ $ext } || 0;
}

=head2 extensions()

The same list, for building a file filter.

=cut

sub extensions
{
    # Sorted into a list first: `return sort ...` is undefined in scalar
    # context, which a caller in a boolean would silently hit.
    my @names = sort keys %SUPPORTED;
    return @names;
}

1;

__END__

=head1 SEE ALSO

L<GlitchVape::Animate>, which muxes what this renders, and
L<GlitchVape::GUI::Audio>, the wizard that produces a spec.

=cut
