# GlitchVape

![GlitchVape](assets/artwork/logo.png)

> **This is an entirely vibe-coded application.** It is a tool for me, the
> author, aimed at simplifying the application of filters and transformations.


Vaporwave and glitch-art transformations for photographs. Reads PNG, JPEG and
HEIC; writes stills or short looping animations.

```bash
glitchvape --preset vhs-decay Pictures/IMG_8111.HEIC
```

---

## Install

Debian 13 / WSL:

```bash
sudo apt update && sudo apt install -y \
  imagemagick libimage-magick-perl \
  ffmpeg libheif-examples \
  pngquant gifsicle webp libimage-exiftool-perl \
  libpath-tiny-perl libjson-perl libyaml-libyaml-perl \
  libtry-tiny-perl libcapture-tiny-perl libfile-which-perl \
  libparallel-forkmanager-perl libmoo-perl libtest-deep-perl \
  fonts-noto-cjk fonts-ipafont fonts-vlgothic fonts-mplus fonts-misaki \
  fonts-terminus fonts-unifont fonts-cascadia-code fonts-hack
```

Check what the tool can actually see:

```bash
./bin/glitchvape --check-deps
./bin/glitchvape --check-fonts
```

Only `imagemagick` and `libimage-magick-perl` are strictly required. Everything
else degrades gracefully: without `ffmpeg` you lose animation, without
`pngquant` the quantiser falls back to ImageMagick's, without CJK fonts the
text effects report which package would fix it.

### For the graphical interface

`glitchvape-gui` is optional and needs nothing that the command-line tool does:

```bash
sudo apt install -y libgtk3-perl libgtk3-imageview-perl
```

Plus, for the animated preview and for auditioning an audio track:

```bash
sudo apt install -y gir1.2-gstreamer-1.0 gstreamer1.0-plugins-good \
  gstreamer1.0-gtk3 gstreamer1.0-libav
```

GTK 3 rather than 4 because Debian has no `libgtk4-perl` — GTK 4 from Perl
would mean raw `Glib::Object::Introspection` without the API overrides
`Gtk3.pm` provides. GStreamer is reached through introspection because Debian
dropped the Perl binding years ago; the typelib is the same library.

Without these, `glitchvape-gui` prints the one `apt` line that fixes it and
exits. The animated preview is checked separately and only when first asked
for, so a machine with GTK but no GStreamer runs the still interface normally.

### Fedora

There is a spec file, so the shortest route is a package:

```bash
sudo dnf install -y rpm-build perl-macros
sudo dnf builddep -y package/glitchvape.spec   # what BuildRequires names
make rpm                                # the three binary packages
```

`make srpm` builds only the source package, and `make rpms` builds both. All
three go through the tarball rather than the spec in the tree, so a file
`make dist` forgot is a build failure rather than a package quietly missing
something.

Output lands wherever `rpmbuild` would have put it, `~/rpmbuild/RPMS`.
`RPMTOPDIR` moves it:

```bash
make rpm RPMTOPDIR=$PWD/build-rpm       # build without touching $HOME
make rpm RPMFLAGS='--nodeps --nocheck'  # skip BuildRequires and the tests
```

The last one proves the packaging rather than the program: `--nocheck` skips
the `%check` section, which is where the test suite runs.

Or build straight out of a checkout:

```bash
sudo dnf install -y ImageMagick ImageMagick-perl perl-File-Which \
  ffmpeg-free pngquant gifsicle perl-Image-ExifTool libheif-tools \
  dejavu-sans-fonts google-noto-sans-cjk-fonts cascadia-code-fonts \
  terminus-fonts ipa-gothic-fonts
sudo dnf install -y perl-Gtk3 perl-Gtk3-ImageView \
  perl-Glib-Object-Introspection            # for the window
sudo dnf install -y gstreamer1 gstreamer1-plugins-base \
  gstreamer1-plugins-good gstreamer1-plugins-good-gtk   # animated preview
```

`ffmpeg-free` is what Fedora ships; RPM Fusion's `ffmpeg` works too, which is
why the spec asks for `/usr/bin/ffmpeg` rather than for either package by
name. There is no Fedora package for Misaki, so the `pixel` role falls through
to Terminus.

### Debian and Ubuntu

There is a `package/debian/` directory, so the shortest route is again a
package:

```bash
sudo apt install -y build-essential debhelper devscripts
make deb
```

Three come out, in the parent directory:

| | |
|---|---|
| `glitchvape` | the library and the command-line tools |
| `glitchvape-gui` | the Gtk3 window |
| `glitchvape-fonts-extra` | one typeface, `non-free/fonts` |

The third is separate because of what is written above about W95FA: its terms
are a font aggregator's description rather than a document, which is not
enough for a package that claims MIT and OFL on the tin. `glitchvape` only
*suggests* it, and the `ui` role falls through to DejaVu without it.

`package/debian/README.Debian` has the detail, including the one thing this packaging
cannot do as it stands: a source package in main may not contain non-free
content, and this one carries `assets/fonts-nonfree/`. Built locally or in a
PPA it is fine; an upload to Debian proper would need either the licence
settled — at which point the font moves up and the third package disappears —
or the tarball repacked, for which `package/debian/copyright` already carries a
commented-out `Files-Excluded` line.

The packaging drives the same `Makefile` the RPM spec does, rather than
restating where anything goes, and `package/debian/rules` installs one binary package
at a time from the targets the Makefile already splits — which is why there
are no `.install` files here. `make check-split`, `make check-licenses` and
the test suite all run during the build.

#### Packaging layout

Everything a distribution needs lives in `package/` — the RPM spec, `debian/`,
the desktop entry and the AppStream metadata — and everything the packaging
targets produce lands in `build/`, which is gitignored and which `make clean`
removes whole. A build writes nothing into the source tree.

Both packagings build from the tarball `make dist` writes there. `rpmbuild -t`
finds `package/glitchvape.spec` inside it; `make deb` unpacks the tarball and
moves `package/debian` into place, because `dpkg-buildpackage` insists on a
`debian/` directly beneath the directory it runs in. Building from the tarball
rather than in the tree means a file `make dist` failed to include is a build
failure rather than a package quietly missing something.

Installed, the modules go to `%{perl_vendorlib}` — `/usr/share/perl5` on
Debian — and the data to
`/usr/share/glitchvape`, which are nowhere near each other — so the walk-up
from `__FILE__` that finds `assets/` and `presets/` in a checkout finds
nothing. `GlitchVape::Paths` is the one constant naming the installed data
directory, and `make install` rewrites it. In a checkout it is empty, which
means "not installed" and sends both callers back to the walk-up, so a
checkout behaves exactly as it did before that module existed.

The window is a separate subpackage. `make check-split` asserts that nothing
outside the GUI module set reaches for Gtk3, which is what makes
`glitchvape` installable on a machine that will never open one — and both
builds run that assertion rather than trusting it.

Fonts are split the same way and for a licensing rather than a technical
reason: `assets/fonts/` ships in the base package and `assets/fonts-nonfree/`
in `glitchvape-fonts-extra`. Both are on the search path, so which package is
installed changes what `--check-fonts` resolves and nothing else.

Manual pages are generated from the tools' own POD at install time rather than
committed, so `man glitchvape` and `glitchvape --help` cannot document
different flags — `pod2usage` reads the same block.

The launcher icon is not. `assets/artwork/icon-256.png` is committed, because
generating it needs ImageMagick and installing should not. It is the middle
185×185 of the 215×185 logo, enlarged to 256 — cropped rather than padded,
since a launcher draws it at 48 pixels and white bars top and bottom would
spend a third of that on nothing:

```bash
magick assets/artwork/logo.png -gravity center -crop 185x185+0+0 +repage \
    -filter point -resize 256x256! -strip assets/artwork/icon-256.png
```

`-filter point` is the part that matters. The logo is 16-colour pixel art, and
any smooth filter resamples it into some three and a half thousand blended
colours and softens every edge — which is exactly the character the thing is
made of. The same reasoning is why the about window shows the logo unscaled.

### Optional fonts

Debian has no package for the classic camcorder faces. Drop `.ttf`/`.otf`
files into `assets/fonts/` — creating it if this is a fresh clone, since the
directory is gitignored — and they are picked up automatically, ahead of
anything installed system-wide. Subdirectories are searched too, so an
upstream release can be unpacked whole — licence, README and all — rather than
having its font files picked out of it; the top level is searched first, so a
loose file still wins over one in a folder beneath it.

Only what FreeType can load counts: `ttf`, `otf`, `ttc`, `pcf`, `bdf`. The
`woff`/`woff2` files that font releases carry for the web are ignored, because
ImageMagick cannot render from them — there is no reason to keep them here.

| Font | Role | Where | Licence |
|---|---|---|---|
| **VCR OSD Mono** | `vcr` | [dafont.com/vcr-osd-mono.font](https://www.dafont.com/vcr-osd-mono.font) | free, [including commercial use](https://www.dafont.com/font-comment.php?file=vcr_osd_mono) |
| **Departure Mono** | `vcr`, `pixel` | [departuremono.com](https://departuremono.com) | OFL 1.1 |
| **Fusion Pixel** | `pixel` | [github.com/TakWolf/fusion-pixel-font](https://github.com/TakWolf/fusion-pixel-font) | OFL 1.1 |
| **W95FA** | `ui` | [dafont.com/w95fa.font](https://www.dafont.com/w95fa.font) | *unverified* — dafont says OFL; no licence text came with it |

Three of the four are in the repository, under `assets/fonts/`, each unpacked
as its author published it with the statement of terms beside the font. That
is not tidiness: `glitchvape --licenses` and the about window read those files
off disk rather than quoting a copy pasted into Perl, which is how the OFL's
"the licence travels with the font" is satisfied by the actual document.

W95FA is the fourth, and it is in `assets/fonts-nonfree/` instead. dafont
describes it as OFL and free for personal and commercial use, but the download
carries no licence text and no statement by its author has been found that can
be cited — a claim about the terms rather than the terms. So it is packaged on
its own, as `glitchvape-fonts-extra`, and the base package can say *MIT and
OFL-1.1 and VCR OSD Mono's grant* and mean it.

Both directories are on the font search path, so a checkout finds every font
either way and the split is invisible to everything but the packaging. Adding
a font is a line in `.gitignore` plus its licence beside it; `make
check-licenses` reports what the rule concluded and fails if a font arrived
without one.

VCR OSD Mono was in the second directory until its author was asked directly,
in the font's own comment thread: *"Yes, the font is free even for commercial
purposes."* That is an unconditional grant with no SPDX identifier, so both
packagings name it as a `LicenseRef` pointing at the file that records it. It
is the worked example of how a font gets promoted.

Nothing breaks without any of them. Every role falls through to whatever
fontconfig can see — `pixel` finds Misaki, `mono` finds Cascadia — and
`--check-fonts` names the package or the download for anything still missing.

Fusion Pixel is the one that ships as a multi-file release; only the `ja` and
`zh_hans` cuts are named by the `pixel` role, and `ja` is preferred because it
carries kana, which is what the text effects actually draw.

Font *roles* are what presets ask for, not font names, so a preset keeps
working on a machine with a different subset installed. `--check-fonts` shows
which file each role currently resolves to.

---

## Usage

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

#### `--fit` is a box; `--max-dim` is a number

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

#### `--codec` settles what the extension cannot

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

Discovery:

```bash
glitchvape --list-effects       # all 39, grouped by pipeline stage
glitchvape --explain pixelsort  # parameters and documentation for one effect
glitchvape --list-presets
glitchvape --list-palettes
glitchvape --list-audio-filters
glitchvape --list-generators
```

### Batch

```bash
glitchvape-batch -p vhs-decay Pictures/          # a directory of photos
glitchvape-batch --all-presets photo.heic        # every preset, to compare
glitchvape-batch -p mallsoft -j 8 -r Pictures/   # 8 workers, recursive
```

Existing outputs are skipped unless `--force`, so an interrupted run restarts
cheaply.

---

## Graphical interface

```bash
glitchvape-gui                              # open empty
glitchvape-gui -p vhs-decay Pictures/IMG_8111.HEIC
```

What goes into the render on the left, the render itself on the right, Apply
between them, Export to write the result at full size.

The left pane is two pages of a stack under a switcher, because effects and
soundtrack are both answers to the same question:

- **Image** — the effects in the pipeline, one row each: a checkbox for
  whether it is in the render, its presentable name beside the identifier a
  preset and `--set` would use, and a minus to take it out.
- **Soundtrack** — the tracks mixed under an animation, the same shape. With
  **Animate** off the page says so rather than disappearing; nothing is
  discarded, so switching animation off to check a still frame and back on
  again finds the mix as it was.

The foot of the pane is an action bar shared by both pages:

| | |
|---|---|
| **+** | adds to whichever page is showing — a popover offers *Single effect…* or *Effects from a preset…* on Image, and the file or a generated kind on Soundtrack |
| **cog** | the settings of the selected row — a popover on Image, the track's own wizard on Soundtrack |
| **camera** | **Animate**: whether the render is a loop or a still |
| **Apply** | renders it |

Only Apply keeps a label — four of them do not fit the pane, and it is the
one with a render bill attached. The other three carry tooltips naming their
keys, `Alt+D`, `Alt+J` and `Alt+N`, which are accelerators rather than
mnemonics because a button with no label has nowhere to underline a letter.
All four sit outside the scrolled list, so none can be scrolled away by a long
pipeline, and Apply keeps the accent colour that marks it as the one action
the rest of the pane is leading up to. Apply becomes **Stop** while a render
is in flight, icon and tooltip along with the word, and the button is pinned
to the wider of the two so the bar does not twitch.

Switching page drops the effect selection, and the cog goes back to waiting
for one: it acts on the effect list, and a selection kept across the switch
would point at something not on screen.

While a render runs, a spinner sits over the picture rather than in the bar,
and the picture can still be panned and zoomed under it.

### An effect's settings are a popover

A row says whether an effect is in the render and what it is called. Its
parameters are in a popover hung off the cog: select a row, press the cog,
press it again to put the settings away.

A popover rather than a window because there is no OK here and no Cancel — a
control writes to the state the moment it moves. A window with a title bar and
no confirming buttons looks like a dialog and behaves like a panel, and people
go looking for the button that commits the change; the only one there is Apply,
which belongs to the whole pipeline.

It is deliberately **not** modal, which is not a popover's default. Rendering
here is an explicit Apply, so one that closed the moment anything else was
clicked would have to be reopened after every render. Left non-modal it stays
up across an Apply, and it follows the selection: click another row and it
shows that effect instead.

It carries the effect's summary, its identifier, and a switch for whether it is
in the render — the same fact as the row's checkbox, and the two move together.
Removing the effect it is showing closes it, and an undo or a fresh preset
rebuilds what it shows.

The cost, paid knowingly: one effect at a time. Two sets of controls at once
is genuinely the better way to decide how much `chroma_shift` answers this
much `scanlines`.

It is a front end, not a second implementation. The controls are generated
from the same `register()` declarations that produce the CLI flags and
`--explain`, so an effect added to the registry gets a widget without anyone
editing the GUI — a `num` with a range becomes a slider marked at its default,
an `enum` becomes a combo, a colour gets a picker beside its entry, and
`osd.date` gets a calendar. Export calls the same `GlitchVape::render` that
`bin/glitchvape` calls, and the result is byte-identical to the equivalent
command line; there is a test that asserts exactly that.

The two parameters with a second widget beside the entry — the colour picker
and the calendar — keep the **entry** as the value, with the widget only a way
of filling it in. Both have a meaning no picker can express: an empty colour
means *no colour*, and an empty `osd.date` means *invent a plausible 1990s
date, a different one per seed*, which is the effect's default and what most
renders want. So the calendar writes `JAN 05 1995` into the field and offers
an **Any 1990s date** button to empty it again, opening on whatever the field
already says rather than on today — a present-day timestamp being exactly the
anachronism the effect exists to avoid. A date it cannot parse is left alone:
`osd.date` accepts any literal string, and somebody who typed `TUESDAY` meant
it.

### The menu

The hamburger at the end of the header bar holds what is done rarely enough
not to earn a button of its own — which is the test for whether something
belongs behind one:

| | |
|---|---|
| **Randomize** | a new seed — reshuffles every effect that draws on randomness, leaving the parameters alone |
| **Animation settings…** | how many frames the loop is and how fast; it reports the resulting length |
| **Export settings…** | what Export writes and at what size — a tab for video, a tab for stills |
| **Clear all effects** | empties the pipeline without leaving the image; an ordinary edit, so undo steps back over it |
| **Save as preset…** | writes the current settings to `presets/`, usable immediately as `-p <name>` |
| **Copy command line…** | the `glitchvape` invocation that produces this export, to read and to copy |
| **Check dependencies…** | what `--check-deps` and `--check-fonts` print, in a window — a graphical session being exactly where nobody has a terminal open |
| **Clear preview cache** | empties the render store; nothing is lost but time |
| **About GlitchVape** | version, licence, and how many effects and presets this copy can actually see |

The seed is an action rather than a field. A seed is never typed in — what it
is only matters *after* the fact, for reproducing a render that came out well
— so it is reported in the status line after every render, and `Copy command
line` carries it.

Frames and rate are the same kind of thing: set once and then left, while the
**Animate** toggle they govern sits beside **Apply**, because that is what it
acts on. It changes what Apply *does* — twenty-four renders instead of one —
and what Export then writes, rather than how the result is displayed. Put over
with the preview controls it reads as another free adjustment like zoom, which
it is not.

A toggle rather than a checkbox because it is a mode the window is *in*, and a
pressed button says that from across the room in a way a tick in a box does
not.

#### Export settings

Export asks one question in a file chooser: *where*. Everything else could be
inferred from the name typed there — letting the extension pick the encoder
and the preset decide the size. A fine default and a poor only option, because
the two things people actually change are the size and the format, and neither
should require knowing that `.webm` means VP9.

**Video**

| | |
|---|---|
| Frame rate | the same setting as in Animation settings — see below |
| Resolution | 512 / 720 / 900 / 1080 / 1440 / 1920 px, or **Native**. Default 720 |
| Format | MP4 · H.264, WebM · VP9, WebM · AV1 |

The sizes are the previewer's list extended upwards, and they mean what the
previewer's mean: **a cap on the longer side**, aspect preserved, never
enlarged. `720` is 720×540 for a 4:3 photograph and 540×720 for a portrait
one. It is not the broadcast sense of 720p — nothing here pads a picture out
to a frame it does not fill.

**Native** is deliberately not the default. It means *no cap at all*, and on a
modern phone photograph that is a 12-megapixel video, which is not what
somebody who has not thought about it wants.

The frame rate appears here *and* in Animation settings because it is
genuinely both — how fast the loop plays, and the rate of the file. Rather
than two numbers that can disagree, both dialogs read and write the same one.

**Stills**

| | |
|---|---|
| Same as the original | a JPEG in stays a JPEG out; a HEIC stays a HEIC |
| PNG | lossless |
| Windows Bitmap · 256 colours | an 8-bit `.bmp` with a dithered palette |
| ☐ Keep retro-friendly dimensions | fit the result inside 640×480 |

The retro box is `--fit 640x480` and turns with the photograph, so a portrait
shot becomes 480×640 rather than being made tiny. It is applied to the
*finished* picture, so a border or letterbox added by an effect is inside the
box rather than pushing the result out of it.

The chosen format also decides the filename Export opens with, so picking
*Windows Bitmap* means `out/IMG_8111.gameboy.bmp` is already in the box rather
than something to type over.

#### Copy command line

The interface claims to be a front end rather than a second implementation.
This is that claim made legible — shown whole, in a monospaced box, with a
Copy button:

```
glitchvape \
    -p gameboy \
    -s 7 \
    --colors 256 \
    --fit 640x480 \
    -o out/IMG_8111.gameboy.bmp \
    Pictures/IMG_8111.HEIC
```

Shown rather than only copied because the command is the one thing here worth
reading: it names every effect that differs from the preset, so it doubles as
a summary of what has been dialled in — and a clipboard is a poor place to
read anything from.

The breaks are not a column count. Each line is one flag and the value that
belongs to it, so every line is a complete thought, the whole thing is still
one command, and deleting a line removes exactly one setting rather than
corrupting the syntax. Paste it into a shell and it runs.

It carries the export settings too, and only the parts that apply to what is
being written: a codec means nothing to a still and a palette means nothing to
a video. `--max-dim` is absent when the size is Native, because the flag's
absence is what leaves the preset's own limit standing — and `--codec` is
absent for H.264 in an `.mp4`, because the extension already says it.

It is also diffed rather than dumped:

```
glitchvape -p hotline -s 4242 -e vgatext --set vgatext.runs=7 \
    -d bloom --set scanlines.opacity=0.55 -d grille photo.heic
```

The state holds a concrete value for every parameter of every effect, because
a widget needs one. Emitting all of them would be correct and useless — a
preset with nine effects is three hundred `--set` flags. So the command is
compared against what `-p hotline` produces on its own and only the
differences are printed, which is shorter *and* still exact: `--set` always
wins over the file, so a parameter left out is one the preset already sets to
that value. Generated tracks are diffed against their declared defaults the
same way.

The preview size and the mute button are deliberately absent: neither changes
what is exported.

### Adding an effect is a wizard

Thirty-nine effects is too many for one list, so **+ → Single effect…** opens
a three-page assistant that asks the questions in the order a person has them.

**What kind of thing am I after?** The nine stages under their presentable
titles, each with a line of description and a count of what is still free.
Categories are the pipeline stages rather than a taxonomy invented alongside
them, because where an effect runs and what it is for are the same fact.

**Which one?** Everything unused in that category, by name and summary, with a
search box. Search deliberately reaches outside the chosen category — someone
who types `scanline` while standing in Colour meant the effect, not the
category — and matches the presentable name, the summary *and* the identifier,
so knowing either spelling is enough. A note under the list says which scope
is in force.

On both list pages a click **picks** a row; only a double click or Enter moves
on. GtkListBox activates on a single click by default, which made touching a
name indistinguishable from choosing it and pressing Continue — so nobody
could look down the list.

**How strong?** The declared parameters, built by the same code that builds
them for the effects list, against a live preview.

That preview is not an impression of the effect. It is the whole current
pipeline plus the candidate, rendered at 320px through the same path and the
same cache as every other preview, so what it shows is what Apply produces.
Renders are coalesced rather than issued per slider step: a drag costs one
render, when it stops, and dragging back to a value already seen redraws from
disk.

Nothing reaches the pipeline until Apply. The wizard previews against a
detached copy of the state, so cancelling — at any point, however many
previews have been rendered — leaves the settings exactly as they were. Once
applied, the effect is an ordinary member of the list with no memory of having
arrived through a wizard.

### Watching a loop render

A still gives a spinner over the picture and nothing else — there is one step
and it is the whole render. A loop counts: **Frame 7 of 24**, a small bar
under it, and after a few frames a rough estimate of how much longer.

The estimate ignores the first frame. That one pays for decoding the source,
which every frame after it reuses, so extrapolating from it alone promises a
wait half again as long as the one that actually follows — and a figure that
then falls steadily is worse than no figure at all.

The bar stops short of full when the frames are done and the label changes to
**Encoding…**, because after the last frame there is still an ffmpeg run, and
with a soundtrack an audio render before it. Export counts the same way, and
is the one that benefits: it renders at full size rather than preview size.

The frame is as fine as the counting gets. Inside one is a chain of
ImageMagick calls, none of which reports progress, so anything more precise
would be made up.

### The picture appears when you open it

Opening a file puts the photograph on the screen straight away, with nothing
applied to it. There is no pipeline to run, so it costs only the decode and
the downscale — under a second on a twelve-megapixel HEIC, and a cache lookup
the second time.

Deliberately not the preset's render, even when one was named on the command
line: that can be eight seconds, and the point of this is to be immediate.
Apply is what renders the preset.

### Why Apply is a button

A render is one to eight seconds depending on size, so there is no live
preview to be had. Making it explicit also gives undo something to be a step
of: one Apply is one history entry, rather than fifty from dragging a slider.

Renders happen in a forked child watched by the main loop, so the window stays
responsive and a second Apply cancels the first.

### Undo does not stack images

Effects cannot be piled up on the result of the previous one, and the reason
is the stage model. The pipeline sorts by declared stage because order is not
a free choice — scanlines applied before a downsample get eaten by the
resample — so an effect switched on later may still have to run earlier.
Applying incrementally would also break the per-effect random streams that let
one parameter be tuned without reshuffling the rest.

So an undo step is a whole configuration, and every state re-renders from the
source. That would be slow if it happened: each render is cached under a
digest of the settings that produced it, and a state on the undo stack has
been rendered before, so stepping back through history is a file lookup.

### Adding a track

The **Soundtrack** page lists what is mixed under the animation. **+** offers
*Audio file…* — which asks for a file and then opens a three-page wizard:

1. **Crop.** The whole file as a waveform, drawn in the `vapor` palette, with
   a selection you drag by either edge or move as a block. Play auditions the
   selection — the original file, seeked, so it starts instantly and you can
   go on dragging while it plays. Past 30 seconds an exclamation appears
   saying what that costs; it does not stop you, and it goes away again if you
   drag back.
2. **Filters.** The four under [Audio](#audio), each with a switch and an
   amount, generated from the same declarations that drive `--audio-filter`.
   Play here renders the crop through the chain and plays *that*, so nothing
   has to be imagined. Four one-press chains — Slowed + reverb, Mallsoft,
   Tape dub, Nothing.
3. **Confirm.** What was chosen and how long the result will be.

Below a separator the same popover lists the generated kinds — **Phone dial
tones**, **TV static** — each opening the window for that one.

Asking which kind first and configuring it afterwards, rather than one dialog
with a kind combo at the top: the kind decides what every other control in the
window is, so choosing it there would rebuild the dialog underneath the
pointer. The window that opens is already the right one, and its title says
which.

Neither the popover nor the window knows what the kinds are. The popover is
built from the generator registry and the controls are built from that kind's
declaration by the same code that builds the effect pane, so a third generator
appears in both without either being touched.

The readout updates on every change. For a dialled phrase it shows the
keypress sequence itself, which matters more than it looks: multi-tap makes
`a` and `2` the same sound, and watching `2` appear three times for a `c` is
what makes the encoding obvious rather than mysterious.

There is one file at most, so that line of the popover goes away once it has
been used. Generated tracks stack, so theirs never do — add as many as you
like. The list then holds everything in the mix, each row with its own minus,
so dropping the music does not take the static with it. Selecting a row and
pressing the cog reopens whatever built it — the same gesture the effects use,
which is why the rows carry no Edit button of their own. Removing is one press
with no confirmation, because the wizards are quick to run again.

Those stay dialogs rather than becoming popovers. A generated track has a real
Cancel and only commits on Add: deciding whether to have a track at all is a
decision you can back out of, in a way that moving a slider on one you already
have is not. The audio file is a three-page wizard besides.

### Mute in preview

The speaker button in the toolbar plays the preview silently.

Rendering a loop with a soundtrack and then watching it over and over while
tuning an effect is how this interface actually gets used, and by the fifth
repeat the tones are not telling anybody anything. Muting is a property of the
player rather than of the render: it takes effect at once, costs no re-render,
and the exported file still has its sound. It is playbin's own `mute`, not a
volume of zero, so the audio is not decoded at all and cannot drift back in
through a seek.

The track is in the *preview*, not only the export: what a soundtrack does to
a loop is exactly the thing a still cannot show.

There is no zoom on the waveform. The whole file is always across the width,
and the spin buttons beside it place an edge to a hundredth of a second — so
the eye finds the section and the numbers place it, and no scroll offset has
to exist.

### Preview size

Previews render at a reduced size, chosen under the preview. Effects work in
pixels rather than fractions of the frame, so a small preview is a fair
impression of the full-size render rather than a crop of it. Export is always
full size.

| | 512 px | 720 px | 900 px | full |
|---|---|---|---|---|
| `vhs-decay`, 12 MP source | 1.9 s | 2.8 s | 3.6 s | 8.0 s |

### The cache

`$XDG_CACHE_HOME/glitchvape`, or `~/.cache/glitchvape`. Working files go in a
per-session subdirectory removed on exit — including on `INT`/`TERM`/`HUP` —
directories left by a crashed session are swept at startup by checking whether
their pid still exists, and the shared preview store is capped at 256 MB,
discarding least-recently-used entries after every render.

### One thing worth knowing

The parent process never touches ImageMagick. It is built with OpenMP, and an
OpenMP thread pool does not survive `fork`: the child inherits the pool's
mutexes without the threads that would release them, and the first parallel
operation deadlocks forever. Caching the decoded source in the parent — the
obvious optimisation, worth 0.4 s per render — is therefore the one thing that
cannot be done. Every image operation happens in a child that has not forked.

The consolation is a more honest preview: it reads the source through
`GlitchVape::IO::load` at the preview size, the same call the CLI makes, so it
differs from the export only in the size it was rendered at.

---

## Presets

| Preset | |
|---|---|
| `vhs-decay` | third-generation dub, tape shedding oxide |
| `broadcast` | weak aerial, 2am, off-air |
| `mallsoft` | empty shopping centre, security-camera memory |
| `dreamcore` | overexposed, hazy, half-remembered |
| `hotline` | neon-noir, high contrast, blown highlights |
| `sunset` | synthwave horizon with grid and sun |
| `crt-terminal` | green phosphor monitor, close up |
| `gameboy` | four-tone handheld LCD |
| `photocopy` | faxed, photocopied, scanned back in |
| `deepfry` | reposted into oblivion |
| `datamosh` | decoder given the wrong frame |
| `anaglyph` | red/cyan misregistration, a 3D comic without the glasses |

A preset is a YAML file naming effects and their parameters:

```yaml
name: vhs-decay
title: Third-generation dub
extends: base-vhs          # optional; merged underneath this file
output:
  max_dim: 1600
effects:
  tracking:  { bands: 6, displacement: 55 }
  scanlines: { opacity: 0.3, spacing: 3 }
  vignette:  { enabled: 0 }        # switch off something inherited
order: [downsample, tracking, scanlines]   # optional
```

`extends` merges per effect, so a child overrides only the parameters it
mentions. `--set` always wins over the file, so a preset is a starting point
rather than a commitment:

```bash
glitchvape -p vhs-decay --set tracking.bands=12 --set grain.amount=0.2 in.heic
```

Presets are found in `./presets`, or wherever `$GLITCHVAPE_PRESETS` points.

In the window a preset is one of the two things **+** offers on the Image
page. It is the only thing there that *replaces* what is already in the
pipeline, which the chooser says before you press Load, and the name is
recorded — so `Copy command line` still comes back as `-p vhs-decay` with
whatever you changed on top.

---

## Effects

39 effects, sorted automatically into a signal chain. Order is not a free
choice — scanlines applied before a downsample get eaten by the resample — so
each effect declares a stage and the pipeline sorts by it.

| Stage | Shown as | Effects |
|---|---|---|
| **format** | Resolution & Format | `downsample` |
| **colour** | Colour | `grade` `palette` `duotone` `gradient_map` `posterize` `quantize` |
| **channels** | Channel Separation | `chroma_shift` `rgb_shift` `chroma_bleed` |
| **damage** | Data Damage | `pixelsort` `databend` `blockshift` `slice` `vgatext` `deepfry` |
| **signal** | Signal & Tape | `wave` `tracking` `head_switch` `ghost` `vhold` `interlace` `dropout` `static` |
| **grain** | Grain & Dither | `grain` `dither` |
| **optics** | Screen & Optics | `scanlines` `grille` `bloom` `vignette` `curvature` `halftone` `glare` `softness` |
| **overlay** | Overlays | `text` `osd` `grid` `watermark` |
| **framing** | Framing | `letterbox` |

The left column is the identifier — what `--explain` reports and what the
library calls it. The middle column is what the interface shows, because a
stage is two things at once: where an effect runs, and what it is for. The
names were chosen to be honest about both. `colour` rather than `grade`,
because only one of the six effects there is grading. `damage` rather than
`destroy`, which said how it felt rather than what it did. `optics` rather
than `screen`, because a lens is not a screen but belongs in the same late
pass — which is also why `softness` sits there rather than under grain, and
why `static`, which is radio-frequency snow, sits with the rest of the
transport artefacts.

Every effect carries a presentable name alongside its identifier —
`chroma_shift` is *Chromatic Aberration*, `wave` is *Tape Wobble*. The
identifier is what presets, `--set` and the copied command line use and it
never changes; the name is what the interface shows. Both appear side by side
wherever an effect is listed, so the two stay connectable.

A few worth knowing about:

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
  of hard-edged blocks; see [Why the font is in the source](#why-the-font-is-in-the-source).
  It sits at `damage`, so the scanlines and grain and curvature all run *over*
  the characters — a broken framebuffer still goes out through the same CRT.
- **`chroma_bleed`** — the most physically accurate VHS artefact. Composite
  video gives colour far less bandwidth than brightness, so colour smears
  horizontally while edges stay sharp. Done properly in YCbCr, blurring only
  Cb and Cr.
- **`pixelsort`** — sorts runs of pixels within a brightness band. The
  threshold is what makes it read as art rather than noise: sorting only the
  dark runs leaves the subject legible while the shadows pour sideways.
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
glitchvape -e duotone -e scanlines -e grain --set duotone.name=hotline photo.heic
```

### Palettes

`vapor` `hotline` `mallsoft` `laserwave` `sunset` `neontokyo` `crt` `amber`
`gameboy` `broadcast` `seapunk` `fax`, plus inline lists:

```bash
glitchvape -e palette --set palette.name='#FF71CE,#01CDFE,#05FFA1' photo.png
```

---

## Seeds

Effects draw randomness from a seeded generator, so the same `--seed` with the
same input reproduces a render exactly. Without one, a random seed is chosen
and printed on completion — a result worth keeping can always be reproduced.

Each effect gets its own *derived* stream. Adding or removing one effect does
not change what any other effect does, which means tuning a preset one
parameter at a time actually converges instead of reshuffling the whole image
on every edit.

---

## Animation

```bash
glitchvape -p vhs-decay --animate --frames 24 --fps 12 -o loop.mp4 photo.heic
glitchvape -p sunset --animate -o loop.gif photo.heic
```

The pipeline runs once per frame. Effects with a periodic component read their
position in the loop and complete exactly one cycle, so the result loops
seamlessly; effects driven by randomness get a fresh pattern each frame, so
static flickers rather than sitting still. The output extension picks the
encoder (`.mp4`, `.webm`, `.gif`).

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

---

## Library

```perl
use GlitchVape;

GlitchVape::render(
    input  => 'Pictures/IMG_8111.HEIC',
    output => 'out/render.png',
    preset => 'vhs-decay',
    seed   => 1337,
);
```

| Module | |
|---|---|
| `GlitchVape` | facade: `render()`, `effect_list()` |
| `GlitchVape::Registry` | effect declaration, stage model, presentable names, parameter validation |
| `GlitchVape::Paths` | where the data files ended up, checkout or installed |
| `GlitchVape::Pipeline` | ordered execution |
| `GlitchVape::Config` | preset loading, inheritance, override merging |
| `GlitchVape::Context` | per-render state: image, RNG, scratch dir |
| `GlitchVape::Pixels` | raw RGB buffer access |
| `GlitchVape::Magick` | PerlMagick error handling (warning vs. failure) |
| `GlitchVape::IO` | decode, EXIF orientation, encode |
| `GlitchVape::Palette` | named palettes, gradient and CLUT construction |
| `GlitchVape::Random` | seeded, portable PRNG |
| `GlitchVape::Assets` | finding the files that ship beside the code |
| `GlitchVape::Fonts` | logical font roles to installed files |
| `GlitchVape::VGA` | the 8x16 text-mode font and the CGA palette |
| `GlitchVape::Animate` | frame sequences to MP4/GIF, and muxing a track |
| `GlitchVape::Audio` | cropping, filtering and rendering a soundtrack |
| `GlitchVape::Generator` | the registry of synthesised soundtrack kinds |
| `GlitchVape::DTMF` | spelling a phrase out in dialpad tones |
| `GlitchVape::Noise` | the hiss of an untuned television |
| `GlitchVape::Wav` | packed samples into a RIFF file |

The graphical interface is a separate set of modules that the library does not
depend on:

| Module | |
|---|---|
| `GlitchVape::GUI` | window assembly and the Apply/Export/undo actions |
| `GlitchVape::GUI::State` | the edited configuration and its undo history |
| `GlitchVape::GUI::Render` | forked background rendering |
| `GlitchVape::GUI::Cache` | the preview store, and cleaning it |
| `GlitchVape::GUI::Params` | registry declarations to Gtk widgets |
| `GlitchVape::GUI::Wizard` | the three-page Add Effect assistant |
| `GlitchVape::GUI::Preview` | the preview pane, still and animated |
| `GlitchVape::GUI::Audio` | the crop-and-filter wizard |
| `GlitchVape::GUI::About` | the about window |
| `GlitchVape::GUI::CommandLine` | the state as a command you could have typed |
| `GlitchVape::GUI::Generated` | the add-a-generated-track dialog |
| `GlitchVape::GUI::Waveform` | the waveform with a draggable selection |
| `GlitchVape::GUI::Player` | auditioning a stretch of a file |

Adding an effect means one `register()` call — the CLI flags, `--explain`
output and validation all derive from that declaration.

### Why the font is in the source

`vgatext` draws with an 8×16 bitmap font that lives in `GlitchVape::VGA` as
sixteen bytes per glyph, rather than by handing ImageMagick a TrueType file.

A TrueType renderer hints and antialiases: it produces grey edge pixels and
nudges stems onto the pixel grid, and both are exactly what a text-mode
display could not do. Blown up four times for a glitch block, an antialiased
glyph looks like a photograph of a letter rather than like a letter a graphics
card drew. One bit per pixel and pixel replication is the whole point.

Keeping the bitmaps in the file also means the effect needs no font installed,
which matters more than it sounds — the font *roles* above exist precisely
because the program cannot assume any particular typeface is present, and an
effect whose subject is one specific ROM font would be the worst thing to
leave to fontconfig.

The glyphs were extracted from Terminus at its native pixel size — a console
font drawn on the same 8×16 grid for the same reasons — and then baked in.
Terminus is under the SIL Open Font License; what is stored is a bitmap of it
rather than the font.

### A note on `GlitchVape::Pixels`

PerlMagick's `SetPixels` is a **silent no-op** on ImageMagick 7 as packaged for
Debian: it returns success and changes nothing. Every effect that moves or
rewrites pixels therefore goes through `GlitchVape::Pixels`, which exports the
image to a raw 8-bit RGB blob, works on it as a Perl string, and reads it back.

That is also the faster path. A 1920x1440 image is 8 MB as a packed string but
around 24 million scalars as a Perl list, and displacing a run of pixels is one
`substr`.

---

## Development

```bash
make test               # 1877 tests, or: prove -Ilib t/
make check-split        # assert the CLI half needs no Gtk3
make check-licenses     # assert every bundled font brought its licence
make install PREFIX=…   # DESTDIR honoured
make dist               # source tarball, into build/
make deb                # the three .deb packages, into build/
make rpm                # the three .rpm packages (make rpms adds the srpm)
make clean              # removes build/ whole, plus the tools' leavings
perlcritic lib/ bin/ t/ # clean at severity 1
perltidy -b lib/**/*.pm # reformat to the house style
```

### Code style

Two config files in the repo root define it, and both are read automatically
when the tools are run from there.

`.perltidyrc` — braces on their own line (Allman), wide spacing inside every
bracket, no vertical tightness:

```perl
sub check
{
    my ( $err, $context ) = @_;

    # PerlMagick hands back either an empty string, a plain string, or an
    # object that stringifies. Force it to a string once, up front.
    my $text = q{};
    if ( defined $err )
    {
        $text = "$err";
    }
    ...
}
```

`--converge` is set: without it a few long call sites oscillate between two
equally-valid line breakings, so a second `perltidy` pass would produce a diff
and the style would not be reproducible.

**No ternaries.** Every conditional is a spelled-out `if`/`else`, which leaves
somewhere to put the reason:

```perl
# Both default to on rather than being taken as plain truthiness, so that
# an explicit quality => 0 or strip => 0 is honoured.
my $quality = 92;
if ( defined $opt{ quality } )
{
    $quality = $opt{ quality };
}
```

Cascading ternaries became lookup tables rather than long `if`/`elsif` chains
where the branches are unrelated — see `Fonts::resolve_or_die`.

`.perlcriticrc` runs at severity 1 and has `RequireTidyCode` pointed at
`.perltidyrc`, so the two tools enforce the same thing: a file `perltidy`
would reformat is a `perlcritic` finding.

`t/10-render.t` renders every registered effect and asserts each one measurably
changes the image — the check that catches an effect silently doing nothing.
`t/11-cli.t` renders the same Japanese string via `--set` and via a preset and
asserts the two are byte-identical, since those paths differ in encoding.
`t/12-gui-state.t` renders once through the interface's state model and once
through the command-line entry point and asserts the same — the check that
catches the GUI growing its own interpretation of a preset.

`perlcritic` runs at severity 1, the harshest setting. Around 1100 findings
appear there against the default policies; each is either fixed in the code or
disabled in `.perlcriticrc` with the reason. Notably, `ProhibitMagicNumbers` is
off — image processing is arithmetic on pixel values, and naming `255` or `0.5`
adds indirection to formulae that read better as written — but the one genuinely
opaque constant it pointed at, ImageMagick's severity-400 error threshold
repeated at fourteen call sites, became `GlitchVape::Magick`.
