# Effects

How the stages are named, the effects worth knowing about before reaching for
`--explain`, and the palettes. Split out of the [README](../README.md), which
has the table of stages and the effects in each.

## The stages, and what they are called

The left column of the README's table is the identifier — what `--explain`
reports and what the library calls it. The middle column is what the interface
shows, because a stage is two things at once: where an effect runs, and what
it is for. The names were chosen to be honest about both. `colour` rather than
`grade`, because only one of the six effects there is grading. `damage` rather
than `destroy`, which said how it felt rather than what it did. `optics`
rather than `screen`, because a lens is not a screen but belongs in the same
late pass — which is also why `softness` sits there rather than under grain,
and why `static`, which is radio-frequency snow, sits with the rest of the
transport artefacts.

Every effect carries a presentable name alongside its identifier —
`chroma_shift` is *Chromatic Aberration*, `wave` is *Tape Wobble*. The
identifier is what presets, `--set` and the copied command line use and it
never changes; the name is what the interface shows. Both appear side by side
wherever an effect is listed, so the two stay connectable.

## A few worth knowing about

- **`rgb_shift`** — anaglyph misregistration: the red/cyan doubling of a 3D
  comic read without the glasses. Distinct from `chroma_shift`, which splits
  two channels symmetrically around a third — here red goes one way and the
  cyan half, green *and* blue, goes the other, which a symmetric split cannot
  express. The two sides jitter independently and are redrawn every frame, so
  an animation flutters like a press run rather than sitting at one offset.
  Bit-for-bit identical to ffmpeg's `rgbashift`, in pure Perl.
- **`vgatext`** — a graphics card losing its mind: runs of the picture
  replaced by 8×16 text-mode character cells in the sixteen CGA colours. Not
  random noise — legible, wrong, and arranged on a grid, which is what makes it
  read as a fault rather than as an effect. The glyphs are one bit per pixel
  and scaling is pixel replication, so a cell at `scale` 4 is thirty-two pixels
  of hard-edged blocks; see
  [Bitmaps that live in the file](../CLAUDE.md#bitmaps-that-live-in-the-file).
  It sits at `damage`, so the scanlines and grain and curvature all run *over*
  the characters — a broken framebuffer still goes out through the same CRT.
- **`chroma_bleed`** — the most physically accurate VHS artefact. Composite
  video gives colour far less bandwidth than brightness, so colour smears
  horizontally while edges stay sharp. Done properly in YCbCr, smearing only
  Cb and Cr, and one-sided: the colour trails to the right of whatever it
  belongs to, because on tape it arrives late along the line. `vertical` is
  the up-and-down smear, off by default because real tape has almost none.
- **`defrag`** — redraws the picture as the cluster map from the disk
  defragmenter that shipped with Windows 95, inside the defragmenter's own
  window: a grid of blocks eight pixels across and ten down, each one the
  state of what is supposed to be in it, most of the grid left as bare white
  paper because most of that window always was. Fourteen states, eight of them
  off the window's own legend. `palette` picks between two sixteen-colour
  tables with chequered blocks and three one-ink phosphor screens; `free` says
  how much of the disk is empty and `scatter` how ragged the edge of it is;
  `window: 0` leaves the map bare.
- **`crop`** — reframes to a shape (square, 4:3, 16:9, 2.39:1, 4:5, 9:16, or
  the picture's own) and chooses what is inside it. `zoom` magnifies rather
  than shrinks: the frame that comes out is the same size at every setting, so
  the rest of the chain is never handed a smaller canvas.
- **`pixelsort`** — sorts runs of pixels within a brightness band. The band is
  what makes it read as art rather than noise: sorting only the dark runs
  leaves the subject legible while the shadows pour sideways. How long a smear
  may be is a share of the line rather than a count of pixels, so a preview
  and an export agree about it.
- **`databend`** — corrupts bytes inside the compressed JPEG stream. Because
  JPEG codes DC terms differentially, one altered byte shifts every block
  after it, giving a coloured band rather than one bad pixel.
- **`head_switch`** — the torn strip along the bottom edge, where a
  helical-scan VCR switches heads a few lines before the end of each field.
  Broadcast masks it off; a raw tape capture shows it.
- **`grain`** — Gaussian, and concentrated in the shadows by default. The noise
  floor is constant, so it is only visible where the signal is weak. Applying
  grain evenly is the most common thing that makes an imitation look fake.

Build a look from nothing:

```bash
glitchvape -e duotone -e scanlines -e grain --set duotone.ramp=hotline photo.heic
```

## Palettes

Moods: `vapor` `hotline` `mallsoft` `laserwave` `sunset` `neontokyo` `crt`
`amber` `gameboy` `broadcast` `seapunk` `fax`.

Real hardware, for the eight-bit end: `cga` `ega` `c64` `spectrum` `nes`.
These are not moods somebody chose but the whole set of colours a machine
could show, which is why they look the way they do.

Anything that takes a palette takes any of them, and takes colours of your own
instead. `palette` and `gradient_map` spell that `custom`, with the colours in
a parameter of their own — which is a row of colour pickers in the window:

```bash
glitchvape -e palette --set palette.name=custom \
    --set palette.colors='#FF71CE,#01CDFE,#05FFA1' photo.png
```

An inline list written into the name itself still works everywhere, which is
what older command lines and hand-written presets say:

```bash
glitchvape -e palette --set palette.name='#FF71CE,#01CDFE,#05FFA1' photo.png
```
