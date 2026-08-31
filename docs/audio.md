# Soundtracks

Adding audio to a loop: files, generated tracks, and how a mix is put
together. Split out of the [README](../README.md).

### Audio

An animation can carry a soundtrack, and adding one changes what the length of
the output means. The loop stays as many frames as `--frames` says; it is
*repeated* for as long as the track lasts:

```bash
glitchvape -p mallsoft --animate --audio track.mp3 \
    --audio-start 30 --audio-end 52 \
    --audio-filter slowed=0.75 --audio-filter reverb=0.5 photo.heic
```

That is a two-second loop over twenty-two seconds of music — eleven repeats.
So the crop is what decides how long the finished piece is, which is why it is
worth a wizard in the interface rather than two numbers.

| Filter | | |
|---|---|---|
| `slowed` | 0.5–1.0, default 0.80 | resample slower and lower — the tape sound |
| `wobble` | 0–1, default 0.25 | slow pitch wobble, a worn transport |
| `muffled` | 0–1, default 0.65 | roll the top off, around 3 kHz at the default |
| `reverb` | 0–1, default 0.40 | the other half of "slowed + reverb" |

A filter not named is off. `--list-audio-filters` prints the ranges.

Order is not a free choice here either, for the same kind of reason the effect
pipeline sorts by stage: speed and wobble are tape, then tone, then the room.
A bright reverb tail on a deliberately muffled source sounds like a mistake
rather than like a room.

`slowed` divides the length, so a twenty-second crop at 0.75 is a
twenty-seven second video. Both the wizard and `--audio` say so before
rendering.

A GIF cannot carry audio; `.mp4` and `.webm` can, and both say so rather than
dropping the track silently.

### Generated tracks

A soundtrack does not have to be a file. `--generate` adds a track the program
makes up, and it is repeatable — static under a dialled phrase under a piece
of music is an ordinary thing to want, and nothing in the mixer cares how many
inputs it has:

```bash
glitchvape -p anaglyph --animate \
    --generate static --gen tone=0.5 --gen seconds=20 \
    --generate dtmf --gen 'text=call me maybe' --gen dial_tone=eu \
    --generate heart --gen bpm=105 --gen sway=15 \
    photo.heic
```

Each `--generate` starts a track and the `--gen` flags after it belong to it.
That is clumsier than one flag with a comma-separated list, and deliberately:
a dialled phrase is prose, full of spaces and commas, and this way it needs no
quoting rules of its own. `--list-generators` prints the kinds and what each
takes.

#### `dtmf` — a dialled phrase

Letters go in the multi-tap way a keypad took them before predictive text —
`c` is key 2 pressed three times — a space is a single 0, and digits, `*` and
`#` are already keys, so mixed input like `call 5551234` needs no flag.
`mode=digits` takes the text literally instead, which is the only way to reach
the `A`–`D` column at 1633 Hz.

`dial_tone=eu` lifts the handset first: two seconds of the continuous tone an
off-hook line makes, which is 425 Hz in most of Europe, 350+440 Hz in North
America, 350+450 Hz on BT and 400 Hz on NTT.

The cadence defaults to the Hayes S11 register — 95 ms, which on a real modem
set *both* the tone length and the inter-digit pause during auto-dial, so the
pair is one decision rather than two. `same_key_pause_ms` lengthens only the
gap between two presses of the same key, which is what real multi-tap entry
needed to tell `cc` from `f`.

`--dtmf TEXT` and its `--dtmf-*` family are shorthand for one of these.

#### `static` — an untuned television

| | | |
|---|---|---|
| `seconds` | 10 | length, when nothing else sets it |
| `tone` | 0.35 | how far open the top end is |
| `drift` | 0.3 | slow swell in the level |
| `hum` | 0.15 | 50 Hz mains buzz of the set itself |
| `crackle` | 0.2 | how often the signal ticks and spits |
| `gain` | 0.5 | level |
| `seed` | 1 | the same seed gives the same static |

It is **pink** noise rather than white, and band-limited to a television's
audio path on top of that. White noise has equal power at every frequency,
which puts most of its energy in the top octave — the octave where hearing
tires fastest — and half a minute of it is unpleasant however quietly it is
played. Pink falls 3 dB per octave, which is the distribution rain and
waterfalls have and the reason those are restful. Real static is not white
anyway: it arrives through a small speaker at the back of a wooden box.

The result is unmistakably snow, and can be left running under a loop without
anybody wanting it turned off. Mains hum and the occasional crackle are what
stop it sounding like a synthesiser; `hum` is the single most evocative
control, since hiss alone could be anything but hiss over 50 Hz is a
television.

Synthesised at 16 kHz rather than CD rate, because a television's audio has
nothing above 8 kHz in it. That makes the buffer a third of the size and hands
the final band limit to ffmpeg's resampler on the way into the mix, which is a
better low-pass than the one-pole it would otherwise need, and free.

#### `geiger` — a counter ticking

| | | |
|---|---|---|
| `seconds` | 20 | length, when nothing else sets it |
| `strength` | 60 | clicks per second at closest approach |
| `baseline` | 2 | clicks per second with nothing nearby |
| `speed` | 0.3 | how quickly you drift towards and away from the source |
| `tone` | 0.5 | how bright each click is |
| `gain` | 0.7 | level |
| `seed` | 1 | the same seed gives the same clicks |

The clicks are the easy half. The **timing** is what makes it recognisable,
and the physically correct model is also the shortest code: radioactive decay
has no memory, so the gap between clicks is exponentially distributed and is
drawn as `-log(rand) / rate`. That is why the clicks *clump* — a burst, a
pause, a double-tap — which is the whole character of the sound. Jittering
around a fixed interval, the intuitive alternative, gives something that
sounds like a failing metronome instead.

A real tube is insensitive for a moment after each discharge, so it undercounts
as the rate climbs. That is modelled too, which is why a strong source fuses
into a buzz rather than merely ticking faster: the observed rate follows the
standard `n / (1 + n·τ)` and there is a test pinning it against that formula.

The distance to the source is a bounded random walk, and intensity follows the
inverse square law, so the rate rises and falls on a Lorentzian — a sharp peak
with long tails, which is far better to listen to than a sine sweep because a
sine spends most of its travel doing nothing. Nothing repeats, and a track
asked to cover three minutes simply wanders for three minutes.

Synthesised at 44.1 kHz, unlike the static: the sharpness of a click *is* its
content, and band-limiting one to 8 kHz turns a tick into a thud.

#### `heart` — a heartbeat

| | | |
|---|---|---|
| `seconds` | 20 | length, when nothing else sets it |
| `bpm` | 70 | beats per minute, before any wandering |
| `sway` | 8 | how far the rate may wander either side of that, in bpm |
| `sway_rate` | 0.3 | how quickly it wanders within that ceiling |
| `depth` | 0.5 | how much chest is around it |
| `gain` | 0.8 | level |
| `seed` | 1 | the same seed gives the same wandering |

Two valve closures a beat — S1, the *lub*, and S2, the *dub*. **The two gaps
are not equal**, and that is the whole thing: S1 to S2 is the beat itself,
S2 to the next S1 is the heart refilling, and at rest the split is roughly a
third and two thirds. Space them evenly and what comes out is a drum loop.

The ratio is not fixed either. As the rate rises it is the *pause* that gets
squeezed out, not the beat — the contraction takes about as long as it takes.
At 60 bpm the pause is more than twice the beat; by 150 it has all but gone.
That is why a racing heart sounds urgent rather than merely quick, so systole
is scaled by the square root of the cycle length and the suite measures the
ratio across the range.

The rate wanders, because a heart held at exactly N beats a minute reads as a
loop within about four beats. `sway` is a ceiling it never passes and
`sway_rate` is how briskly it moves inside it; the wandering stays irregular
at either setting, since what those shape is a random walk and not a waveform.

Each thud is a burst of noise through a low-pass tuned low, not a sine: a
valve closing is a broadband thud and a sine burst gives a synthesised kick
drum. Almost none of it is above 200 Hz, so 16 kHz is generous rather than a
compromise.

#### `drive` — a hard disk working

| | | |
|---|---|---|
| `seconds` | 20 | length, when nothing else sets it |
| `activity` | 0.35 | how often the drive is asked for something |
| `travel` | 0.3 | how far the head goes |
| `fan` | 0.4 | the whirr behind it |
| `rpm` | 5400 | spindle speed, which sets the pitch of the whine |
| `gain` | 0.7 | level |
| `seed` | 1 | the same seed gives the same work |

Almost nothing that makes a drive recognisable is timbre. A recording of one
seek is one seek; what says *hard disk* is the **pattern** — long quiet, then
a rattle, then quiet again — which is why this is worth generating rather than
sampling.

So the seeks are not a Poisson process the way the Geiger clicks are. Drawing
gaps from one distribution gives an even scatter of ticks, which is exactly
the failure that generator goes out of its way to avoid. There are two states
instead: idle waits an exponential gap, and a burst is a run of seeks a few
tens of milliseconds apart whose length is geometric, so most bursts are short
and the occasional one runs on. Turning `activity` up lengthens the quiet and
leaves the bursts alone, because how fast a drive seeks while it is working is
a property of the drive rather than of how busy it is.

The other half is that **a seek's pitch is how far the head went**. The head
is a mass on a voice coil, driven hard, moved and stopped, so a seek is a
resonance swept downward as the mechanism settles — it is the sweep that makes
it a chirp rather than a click. Seek time goes as roughly the square root of
the distance, because the actuator spends the move speeding up and then
slowing down rather than travelling at a speed. A short hop is a tick around
2.7 kHz lasting four milliseconds; a full stroke starts near 1 kHz and takes
five times as long. `travel` is which of those you mostly get, which is the
difference between one file being read and a defragment.

The chirp is a two-pole resonator driven by noise, and its input is normalised
by `1 - r²`: such a filter's gain at its own frequency goes as `1/(1-r)`, which
at the ringiest end of the range is a factor of eighty. Unnormalised it does
not come out loud, it comes out clipped — which it did.

The bed is air noise low-passed to a rumble, plus a tone at the fan's
blade-pass frequency and the spindle under that. Noise alone is a hiss; the
tones are what make it a machine, and they are kept faint, because a fan you
can hear the pitch of is a fan with something wrong with it.

### Mixing, and which one is in charge

Give `--audio` and any number of `--generate` together and they are all
summed. **The file decides the length.**

What covering that length means is each generator's own business. Static
simply carries on — it has no ending, so there is no seam to hide. A dialled
phrase is not looped, because a sentence repeated is a stutter rather than a
sentence: it plays once, stops, and after three seconds of silence the line
opens again on a continuous tone for whatever is left.

```
dialling  [============]
silence                 [===]
open line                    [==========]
static    [~~~~~~~~~~~~~~~~~~~~~~~~~~~~~]
rain      [~~~~~~~~~~~~~~~~~~~~~~~~~~~~~]  40s, and 40s is the video
```

That is what a handset does once you have finished dialling, and it means the
number the crop wizard showed you is the length of the finished video. With no
file at all, the longest generated track sets the length and the rest fill out
to it.

Anything with an ending that is longer than the file gets cut, and both the
command line and the interface say so rather than letting it happen quietly.

The vaporwave filters apply to the file only. Slowing is a resample, and a
resampled DTMF tone is no longer on the DTMF grid — it stops being a dialled
number and becomes two detuned sine waves.

