# The command line

Every option of `glitchvape`, the few whose meaning is not obvious from the
name, and `glitchvape-batch`. Split out of the [README](../README.md);
`glitchvape --help` prints the same list, and `glitchvape --man` the manual.

```bash
glitchvape [options] <input>
```

| Option | |
|---|---|
| `-p, --preset NAME` | preset to build the pipeline from |
| `-o, --output PATH` | output file (default `out/<name>.<preset>.png`) |
| `-s, --seed VALUE` | any string or number; same seed reproduces the render |
| `--set E.P=V` | override one parameter; repeatable |
| `-e, --enable NAME` | switch an effect on with its defaults |
| `-d, --disable NAME` | switch an effect off |
| `--max-dim N` | downscale the source first (default 1920) |
| `--fit WxH` | downscale to fit a box, e.g. `640x480` — see below |
| `--colors N` | quantise a still to an N-entry palette |
| `-a, --animate` | render a loop instead of a still |
| `--frames N` / `--fps N` | loop length and rate (default 24 @ 12) |
| `--codec NAME` | `h264`, `vp9` or `av1`; default from the extension |
| `-j, --jobs N` | processes drawing a loop's frames (default one per core) |
| `--audio PATH` | add a soundtrack; the loop repeats to cover it |
| `--audio-start` / `--audio-end` | seconds; which part of the track |
| `--audio-filter F=V` | vaporwave filter; repeatable |
| `--generate KIND` | add a generated track; repeatable |
| `--gen K=V` | set a parameter on the last `--generate` |
| `--dtmf TEXT` | shorthand for one dialled track |
| `--dtmf-digits` | take the text as a literal dial string |
| `--dtmf-dial-tone` | lift the handset first: `eu` `us` `uk` `jp` |
| `-n, --dry-run` | print the resolved pipeline, render nothing |
| `-v, --verbose` | per-effect logging; twice for timings |

The soundtrack options are in [audio.md](audio.md), with the generators and
their parameters.

## `--fit` is a box; `--max-dim` is a number

`--max-dim` caps the longer side and lets the other fall where the aspect
ratio puts it, which is the right rule for *no bigger than this*. It cannot
say *must land on a 640×480 screen*, because that is two numbers.

`--fit` is those two numbers, and the box turns with the picture:

```bash
glitchvape --fit 640x480 photo.heic
```

| source | result |
|---|---|
| 4:3 landscape | 640×480 |
| 3:4 portrait | 480×640 |
| 16:9 | 640×360 |
| already smaller | untouched — a box is a ceiling, never a floor |

A portrait photograph gets 480×640 rather than 360×480 because a screen of
that size filled its height with one. The box is applied to the source *and*
to the result: `letterbox` and `border` add pixels, so constraining only the
input would be a promise this makes and does not keep.

`--colors` is the other half of a period-correct file. ImageMagick's BMP
encoder given a truecolour image writes a 24-bit file with a `.bmp` on the
end, which is not what asking for 256 colours meant, so the palette is built
first and the image switched to palette type:

```bash
glitchvape -p gameboy --fit 640x480 --colors 256 -o out/1995.bmp photo.heic
```

## `--codec` settles what the extension cannot

`.mp4` means H.264 and `.gif` means GIF; `.webm` is genuinely ambiguous, since
VP9 and AV1 both live in it. Without `--codec`, `.webm` is VP9 — the one every
build of ffmpeg can write.

| | |
|---|---|
| `h264` | common default |
| `vp9` | smaller at the same quality; plays in browsers |
| `av1` | smallest of the three, modern and demanding codec|

AV1 needs an encoder not every ffmpeg has. That is checked *before* the first
frame rather than discovered at the last step of a job whose first twenty-four
steps are whole renders.

## Finding things out

```bash
glitchvape --list-effects       # all of them, grouped by pipeline stage
glitchvape --explain pixelsort  # parameters and documentation for one effect
glitchvape --list-presets
glitchvape --list-palettes
glitchvape --list-audio-filters
glitchvape --list-generators
```

## Batch

```bash
glitchvape-batch -p vhs-decay Pictures/          # a directory of photos
glitchvape-batch --all-presets photo.heic        # every preset, to compare
glitchvape-batch -p mallsoft -j 8 -r Pictures/   # 8 workers, recursive
```

Existing outputs are skipped unless `--force`, so an interrupted run restarts
cheaply.
