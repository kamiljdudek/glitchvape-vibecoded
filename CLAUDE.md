# CLAUDE.md

Orientation for anyone — human or agent — picking this codebase up. The
[README](README.md) explains what GlitchVape *does* and how to use it; this
file explains how it is put together, which invariants are easy to break
without noticing, and how each of them is checked.

## What it is

A Perl image pipeline that puts a photograph through a chain of forty-five
VHS/CRT/glitch effects, plus a Gtk3 window over the same pipeline. Pure Perl
apart from the effects, which shell out to ImageMagick, and the animated
writers, which shell out to ffmpeg.

Nothing is compiled. `make install` is the one definition of where files go;
both the RPM spec and `debian/rules` drive it rather than restating paths.

## Layout

| | |
|---|---|
| `bin/` | `glitchvape` (CLI), `glitchvape-batch`, `glitchvape-gui` |
| `lib/GlitchVape.pm` | the façade — `render()`, which every front end calls |
| `lib/GlitchVape/Effect/*.pm` | the forty-five effects, grouped by theme not by stage |
| `lib/GlitchVape/GUI.pm`, `GUI/` | everything Gtk3, and the only thing that may `use Gtk3` |
| `presets/*.yml` | a look, as a set of effects and parameters |
| `assets/fonts/`, `assets/fonts-nonfree/` | bundled typefaces, split by licence — see below |
| `package/` | the spec, `debian/`, the desktop entry and the AppStream metadata |
| `build/` | everything the packaging targets produce; disposable, gitignored |
| `t/` | the suite; GUI tests skip themselves without a display |

## The invariants

Each of these is enforced by something that runs in the build, not by
convention. Breaking one should fail `make check-split`, `make
check-licenses` or `make test` — if you break one and nothing fails, that is
itself a bug worth fixing.

### 1. Effects are declarations, and the declaration drives everything

An effect calls `register()` with its name, stage, docs and a `params` hash
where each parameter has a type, a default and usually a range:

```perl
$R->register(
    name    => 'scanlines',
    stage   => 'optics',
    params  => {
        opacity => { default => 0.35, type => 'num', min => 0, max => 1,
                     doc => 'How dark each line is' },
    },
    apply   => \&_scanlines,
);
```

That one declaration produces the `--set` flag, the `--explain` output, the
preset key, *and* the widget in the window. **Adding an effect must not
require editing the GUI.** If you find yourself adding a special case to
`GlitchVape::GUI::Params` for one effect, the declaration is probably missing
a type or a range.

Parameter *kinds* map to widgets in `GUI/Params.pm`: `num` with a range → a
slider marked at its default, `bool` → a switch, `enum` → a combo, and a few
parameters get something better based on their name (a colour picker, a
font-role combo, a calendar for `osd.date`, a clock for `osd.time`, a reroll
button beside any `seed`).

A parameter may also say how it wants to be *presented*, and these are read by
the window and by `--explain` alike — never by the render:

| | |
|---|---|
| `order` | where it sits among its siblings; the default is alphabetical |
| `label` | what to call the row, where the key is not the clearest English |
| `needs` | which other parameters must hold before this one means anything |
| `placeholder` | the grey text an empty entry shows, since what empty *means* is the parameter's fact |
| `suggest` | values to offer, typeable: a named source (`palette`) or an inline list |
| `choose` | the same, but closed — a plain drop-down with nothing to type into |

`needs => { timestamp => 1, invent => 0 }` greys the control until both hold,
without hiding it and without touching the value — `osd` is what these exist
for, and `Registry::needs_met` is where the question is answered so that
nothing about it depends on Gtk. Naming a parameter the effect does not
declare is fatal at load time, because the alternative is a control greyed out
for ever that looks like a broken widget.

### 2. Where an effect runs is a property of the effect

`stage` is not decoration. The pipeline sorts by it, because order is not a
free choice — scanlines applied before a downsample get eaten by the resample.
The nine stages, in execution order:

`format` → `colour` → `channels` → `damage` → `signal` → `grain` → `optics` →
`overlay` → `framing`

The stages double as the browsing categories in the Add Effect wizard, which
is deliberate: where an effect runs and what it is for are the same fact, so
there is no second taxonomy to keep in sync. They also band the effect list in
the window, since a pipeline nobody can reorder is owed an explanation of the
order — which each stage carries as `STAGE_INFO->{because}`, one sentence
saying what would go wrong if its effects ran elsewhere.

### 3. The GUI is a front end, never a second implementation

Export calls the same `GlitchVape::render()` that `bin/glitchvape` calls, with
arguments in the same shape. `GUI/CommandLine.pm` turns the current state into
the equivalent `glitchvape` invocation, and that is the claim made checkable —
if the window can produce a render the command line cannot express, something
has gone wrong on the CLI side and needs a flag, not a workaround in the GUI.

### 4. Nothing outside `GUI/` may reach for Gtk3

That is what makes the base package installable on a machine that will never
open a window. `make check-split` greps for it and fails the build.

If a GUI module needs pure logic that the CLI also wants, the logic moves to a
CLI module — not the other way round.

### 5. Rendering happens in a forked child, and the parent must never touch ImageMagick

ImageMagick is built with OpenMP. An OpenMP thread pool does not survive
`fork`: the child inherits the pool's mutexes without the threads that would
release them, and the first parallel operation deadlocks forever.

So `GUI/Render.pm` forks per render and **the parent process never loads an
image at all** — not even to cache the decoded source, which is the obvious
optimisation and exactly the thing that cannot be done. Image dimensions come
from a separate `magick` subprocess.

This is the single most expensive mistake available in this codebase, because
it presents as an intermittent hang rather than an error.

### 6. Undo steps over configurations, not images

`GUI/State.pm` keeps a history of settings, and stepping back re-renders —
which is a cache hit, because `GUI/Cache.pm` is content-addressed on the
resolved configuration. One Apply is one history entry, so dragging a slider
does not produce fifty near-identical steps.

### 7. A preset is a look

Presets carry effects and parameters. They do **not** carry a path to a file
on somebody's machine, so the audio spec and the frame count live in the GUI
object rather than in the state that gets written to a preset.

## Fonts

Presets ask for a *role* — `vcr`, `pixel`, `ui`, `mono`, `sans`, `cjk`,
`cjk_serif` — never a font name, and each role falls through a candidate list
to whatever fontconfig can see. **A missing font is a different-looking
render, never an error.** `glitchvape --check-fonts` prints what each role
resolved to.

Two bundled directories, split by licence rather than by anything technical:

| | |
|---|---|
| `assets/fonts/` | free to redistribute; ships in the base package |
| `assets/fonts-nonfree/` | documented but restricted, or not established; ships only in `glitchvape-fonts-extra` |

Both are on the search path, so a checkout finds every font either way and the
split is invisible outside the packaging. A font ships only if a licence file
sits beside it — `make check-licenses` re-reads the directories and fails if
one arrived without. Adding a font is a line in `.gitignore` plus its licence
beside it; there is no list of font names anywhere to keep up to date.

Promoting a font from restricted to bundled is moving its directory. VCR OSD
Mono is the worked example: its terms were unverified until its author was
asked directly and answered, at which point it moved up and the packaging
followed automatically.

## Bitmaps that live in the file

Two modules keep pictures in their own source rather than in `assets/`, and
the same argument covers both.

`GlitchVape::VGA` holds an 8x16 text-mode font as hex, because a TrueType
renderer antialiases and hints and a text-mode display could do neither. It
also holds the cell rasteriser and the blit, because two effects paint text
cells now -- `vgatext` and `stars` -- and a second copy of a blitter is a
second place for a rounding to drift.
`GlitchVape::Chicago` holds the nine glyphs a Windows 95 window needs that are
pictures rather than rules -- the document icon, three caption glyphs, four
arrows and the sizing grip -- as one character per pixel, keyed by a five-ink
palette.

Everything else about that window is a *rule*: two bevels, four flat fills and
a 50% dither, applied at metrics that do not change with the window's size.
That is what lets the size be a setting at all — and it is what lets the same
module serve `chicago`, which lays a window over the picture with a hole in
it, and `maximised`, which builds one *around* the picture at `framing`.
`around()` is that layout read backwards: given what has to go inside, how big
is the window. The two can disagree, so the test builds a window from
`around()` and then measures the hole `render()` actually left.

It is checked the only way it can be: `t/40-chicago.t` renders the window at the size of the screenshot
every measurement came off and compares it, region by region, against the
pixels that screenshot had. The screenshot itself is gone; the test is now
the record of it.

Both scale by **pixel replication and never interpolation** — `Sample`, not
`Resize`. An interpolated one-pixel highlight is a grey smear, and a bevel
whose highlight is grey does not read as raised.

The lettering drawn on the same picture has to survive the same treatment, and
that is a fact about the font rather than a setting. With antialiasing off a
rasteriser inks a pixel when the pixel's *centre* is inside the outline, so a
stem narrower than a pixel vanishes — for some of the positions it can land in
and not others, which reads as a corrupt font rather than as a size one pixel
too small. `Chicago::type_size` measures the stem of an `l` at a large em and
takes `ceil(1 / stem)`, never below the twelve the interface wants: twelve for
the `pixel` role, thirteen for W95FA. It is a measurement and not a table, so
a font nobody here has seen gets the same answer.

## Packaging

Three binary packages from one source, in both packagings, split the same way:

| | |
|---|---|
| `glitchvape` | library + CLI |
| `glitchvape-gui` | the window |
| `glitchvape-fonts-extra` | typefaces whose terms are not established |

Everything a distribution needs is under `package/` and nothing a build
produces is anywhere but `build/`, which is why `make clean` is one `rm -rf`.
Both packagings build from the tarball `make dist` writes there: `rpmbuild -t`
finds `package/glitchvape.spec` inside it, and `make deb` unpacks it and moves
`package/debian` into place, because `dpkg-buildpackage` insists on a
`debian/` directly beneath the directory it is run from. Building from the
tarball rather than in the tree means a file `make dist` failed to include is
a build failure rather than a package quietly missing something.

`package/debian/rules` installs one package at a time from the Makefile's own
targets rather than staging everything and splitting it back out with
`.install` globs — the split already exists and `check-split` proves it.

`GlitchVape::Paths::DATADIR` is one constant naming the installed data
directory, rewritten by `make install`. Empty means "not installed" and sends
`Assets` and `Config` back to walking up from `__FILE__`, which is what makes
a checkout behave as though the packaging did not exist.

Manual pages are generated from the tools' own POD at install time rather than
committed, so `man glitchvape` and `glitchvape --help` cannot document
different flags — `pod2usage` reads the same block.

Both packagings are built on every push to main by
`.github/workflows/packages.yml`, which uploads the three `.deb`s, the three
`.rpm`s and the source RPM as artifacts. Each is built in a container of the
distribution it is for — `debian:trixie` and `fedora:latest` — and each
installs its build-dependencies out of its own packaging file, `apt-get
build-dep ./package` reading `debian/control` and `dnf builddep` reading the
spec. Neither job repeats a dependency list; repeating one was tried and it
drifted from `debian/control` inside an hour.

Building either on the runner itself was tried and neither works. The RPMs
need `%{perl_vendorlib}` supplied by hand and the `BuildRequires` list stood
down with `--nodeps`, which produces three `.rpm` files without exercising the
spec anybody will actually build: with the dependency list skipped, the
buildroot is whatever the runner happened to have. The `.deb`s need
ImageMagick 7, and `ubuntu-slim` is Ubuntu 24.04, which ships version 6 —
there is no `magick` binary there at all, `Tools` finds `convert` instead, and
five tests fail under it.

That is the argument for the containers, and it is the same argument twice:
every missing `BuildRequires` found so far — `prove`, `FindBin`, `lib`,
`Digest::SHA`, a YAML parser, the `magick` binary as distinct from the Perl
binding, and a CJK font with fontconfig to see it by — was invisible on a
workstation, where one `perl` package carries most of them and the rest are
simply already installed. A container has exactly what the packaging asked
for and nothing else, which is the point.

## Conventions

- **`make tidy` and `make critic` before finishing.** `.perltidyrc` and
  `.perlcriticrc` are in the repo and the suite is close to critic-clean; a
  new finding is yours. Where a rule genuinely does not apply, annotate with
  `## no critic (...)` and say why, rather than leaving it to accumulate.
- **Comments explain why, not what.** This codebase leans hard on that — a
  comment recording the reasoning behind a non-obvious choice is wanted, a
  comment restating the line below it is not. Match the density around you.
- **POD is part of the module**, and several modules carry a `=head1` arguing
  for a design decision. Update it when the decision changes.
- **Tests are prose.** Assertion names read as sentences about behaviour
  rather than as function names, and blocks carry a comment saying what
  property is being pinned and why it matters.
- **`use utf8` where literals are non-ASCII** — `·`, `…`, `×` appear in labels
  and status text, and without it they render as mojibake.

## Commands

```bash
make test              # the whole suite; GUI tests skip without a display
make check-split       # no Gtk3 outside GUI/
make check-licenses    # every bundled font has its licence beside it
make tidy critic       # perltidy + perlcritic
make man               # manual pages from the tools' POD
make dist              # source tarball, into build/
make deb               # the three .deb packages (needs debhelper)
make rpm               # the three .rpm packages (make rpms for the srpm too)
make srpm              # source RPM only
make clean             # removes build/ whole, plus the tools' leavings

perl -Ilib bin/glitchvape --check-deps    # what external tools are present
perl -Ilib bin/glitchvape --check-fonts   # what each font role resolved to
perl -Ilib bin/glitchvape --list-effects  # all of them, by stage
perl -Ilib bin/glitchvape --explain NAME  # one effect's parameters
```

Three environment variables override where things are found, which is how the
tests run against the checkout regardless of what is installed:
`GLITCHVAPE_ASSETS`, `GLITCHVAPE_PRESETS`, `GLITCHVAPE_FONTS`.

Two escape hatches exist for building where the toolchain is not fully
installed — `make deb DPKGFLAGS=-d` skips `dpkg-checkbuilddeps`, and
`make rpm RPMFLAGS='--nodeps --nocheck'` skips the equivalent and the test
run. `RPMTOPDIR` moves the rpmbuild tree, which otherwise lives in `build/`.

## The window, and what it has already tried

The interface has been rearranged more than once, and the arrangements that
were discarded are the reason the current one looks as it does. That reasoning
is recorded here rather than in comments beside the code, so that the code
says what it does and this says what else was tried.

- **Effect parameters were once inline, in a disclosure per row.** The list
  was then as tall as the settings of everything in it, so a fifteen-effect
  preset could not be seen at once. The disclosure itself was hand-built from
  a toggle and a revealer rather than a `GtkExpander`, for the event-window
  reason in the list below; that problem went away with the disclosure.

- **Then they were non-modal windows, one per effect.** That bought comparing
  two effects' controls side by side, and cost honesty: a window with a title
  bar and no OK or Cancel looks like a dialog and behaves like a panel. They
  are one popover now — `GUI/Adjust.pm`, hung off the Adjust button, following
  the list selection. It is deliberately `set_modal(0)`, because Apply is a
  button here and a modal popover would have to be reopened after every
  render. Row activation went with the windows, on both lists: selecting is
  the whole gesture.

  Two things bit while doing it. `popdown()` closes with a transition, so the
  popover's own `get_visible` lags the decision — `Adjust.pm` keeps the state
  itself and clears it on the `closed` signal. And rebuilding either list
  emits `row-selected` on the way through, which without a guard tells the
  popover nothing is selected and closes it; `_rebuild_audio_rows` had the
  same problem from the other direction, rebuilding from `_sync_actions` and
  so destroying a row from inside its own selection handler. It now skips the
  rebuild unless the mix has actually changed.

- **The soundtrack was under the preview, in a revealer tied to Animate.**
  That put the two halves of one pipeline on opposite sides of the window and
  made half of it appear and disappear. It is the second page of the left
  pane's stack now, and with Animate off it explains what it is waiting for
  instead of vanishing — a tab that disappears teaches nobody what it was for.

- **The soundtrack page had its own pair of Add buttons, and its rows an
  Edit button each.** "Add something here" and "open what is selected" are
  each one action, so each is one button: Add and Adjust both serve whichever
  page is showing. The soundtrack keeps its *dialogs* — a generated track has
  a real Cancel and only commits on Add, so the argument that turned the
  effect settings into a popover does not transfer to it.

- **There was a preset combo above the effect list.** A preset is now one of
  the two things Add offers, because a preset is a set of effects and belongs
  beside "one effect" rather than in a control of its own. It still *replaces*
  the pipeline and still records its name, which is what keeps `--preset` in
  the copied command line; `Clear all effects` in the menu is what the
  combo's `(no preset)` entry used to do.

- **Add, Adjust and Animate were labelled buttons.** Four labels did not fit
  the pane. Only Apply keeps its word — it is the one with a render bill
  attached and the one that changes to Stop. Dropping a label drops its
  mnemonic, so those three keys moved to an accelerator group and each is
  named in its button's tooltip.

- **The render spinner was in the action bar.** It had to be faded rather than
  hidden, because appearing would shove the button beside it. It is over the
  preview now, which needs `set_overlay_pass_through` — see the list below.

- **Saving a preset was an icon beside the combo.** It is in the menu, where
  the platform puts Save As and where a rare operation is not guessed at from
  a picture of a floppy disk.

- **Open replaced the state.** Opening a second photograph threw away the
  first one's pipeline, soundtrack and undo history in one click. It starts a
  second instance of the program now — a process rather than a second window,
  because every window in one process would share the cache, the render child
  and the preferences, which is exactly what invariant 5 says does not survive
  being shared. The first Open in a window still fills it, since there is
  nothing to lose and an empty window would be left behind. There is
  deliberately no fallback to opening in place when the spawn fails.

- **Export once inferred everything from the filename.** Format, size, frame
  rate and palette are settings in a dialog now, because the two things people
  actually change are the size and the format and neither should require
  knowing that `.webm` means VP9.

## Generated soundtracks

`GlitchVape::Generator` is a registry in the same sense `Registry` is: one
`register()` call produces the `--generate`/`--gen` validation, the
`--list-generators` entry, the widgets in the wizard and the row in the Add
popover. Five kinds so far — `dtmf`, `static`, `geiger`, `heart`, `drive` —
each a module beside it exposing `params`, `param_order`, `duration`, `pcm`,
`render` and `describe`.

**Adding a kind must not require editing the GUI.** The icon is part of the
declaration for exactly that reason: it used to be a mapping keyed on kind
inside `GUI.pm`, in two copies that had drifted apart.

Three of them are about timing rather than timbre, and the timing is the part
worth protecting:

- **`geiger`** draws inter-click gaps from the exponential distribution
  radioactive decay actually has. That is what makes the clicks clump, which
  is the whole character of the sound; jittering around a fixed interval gives
  a broken metronome. Dead time is modelled too, so the observed rate follows
  `n / (1 + n·τ)` — `t/28-generators.t` checks it against that formula rather
  than against a recorded number.
- **`heart`** puts S1 and S2 closer together than S2 and the next S1, and
  scales systole by the square root of the cycle so it is the *pause* that
  disappears as the rate rises. Equal gaps would be a drum loop.

- **`drive`** alternates idle and burst, because a hard disk is quiet almost
  all the time and then seeks twenty times in half a second. One distribution
  of gaps gives an even scatter of ticks, which is the failure `geiger` avoids
  by going the other way. Turning `activity` up lengthens the quiet and leaves
  the bursts alone, since how fast a drive seeks while working is a property of
  the drive. Its chirps are a swept resonance whose pitch and length come from
  how far the head went, seek time going as the square root of distance —
  which is why one file being read and a defragment sound different.

Those tests read the click schedule by replacing `Geiger::_click`, because
once the rate is high enough for dead time to bind the clicks overlap and no
onset detector can separate them. The real sub is put back before the
reproducibility checks — with the recorder in place `pcm()` writes silence,
and two silent buffers compare equal whatever the seed was.

## What varies from frame to frame

Three behaviours, and which one an effect has is a property of what it is
modelling rather than a choice:

| | |
|---|---|
| re-rolls every frame | the medium at an instant — grain, tape noise, damage |
| moves if asked | `drift`, `pulse`, `rate`: the picture or the pattern travelling |
| identical every frame | the setup — resolution, colour maps, lens, framing |

A fourth exists in one place: `stars` is the *same* thing later. Its sky is
stepped rather than re-rolled, because what reads as twinkling is that stars
stay where they are between the moments they do not. Frame N is the sky after
N steps, computed from the seed each time rather than carried between frames,
which a render has no way to do. It cannot close its loop and does not pretend
to: a star that flares comes back somewhere else.

It lines up with the stages almost exactly, which is not a coincidence: damage,
signal and grain are things happening *now*, while format, colour, optics and
framing describe how the picture is made.

`reroll` is the switch for the first kind, and it is spelled the same way
everywhere — `rng_for` when on, `rng_fixed` when off, both derived under the
same label so a **still renders identically either way**. The five damage
effects arrive with it on, because a tape being chewed while it plays is what
they are for; `dither` arrives with it off, because a shimmer nobody asked for
would change what every preset using one already renders.

There are three random streams, not two, and an effect wants exactly one:

| | |
|---|---|
| `rng_for` | a fresh roll every frame, and no two loops line up |
| `rng_phase` | a fresh roll every frame, and the loop closes |
| `rng_fixed` | one roll, held for the whole render |

`rng_phase` keys on the frame's position around the loop rather than on its
index, so the frame after the last one is the first one again. It is what lets
something random close, which `chicago`'s `jitter` is: that one shakes the
window in place rather than travelling, so there is no period for
`Context::travel` to snap and it is deliberately not called a drift. The seam
is invisible either way — one more jump among all the others — but the window
is recognisable frame to frame, so coming back to a *different* position would
be a jolt somebody could point at, which is not true of grain.

Three shapes of motion sit beside those, and an effect picks by what the thing
being moved actually does:

| | |
|---|---|
| `travel` | a repeating pattern scrolling; the distance snaps to whole repeats |
| `excursion` | a one-off feature swept out and back, half the loop each way |
| `swell` | the same rock folded onto one side, for a quantity with no other direction |

`swell` is what `duotone`'s and `gradient_map`'s `swap` rides, and `static`'s
`surge`: a swap of minus a third is not a thing, so the negative half of an
excursion would have to be thrown away, and the extreme belongs in the middle
of the loop rather than twice at the quarters.

`swap` is one function — `Palette::swapped` — under one name on both effects,
because turning a palette end for end is the same operation whether it has two
stops or five: every stop heads for the place its opposite number started
from, and an odd middle stop is already there. What it moves is the *list of
colours* rather than the ramp's name, so it works on the named palettes and on
an inline one alike. Each pair goes opposite ways round the hue circle rather
than mixing through each other, because mixed channel by channel they meet in
the middle and the frame collapses to one colour. Half a slider being the
worst-looking place on it is not a control anybody can use.

`static`'s `surge` is measured towards a picture that is nothing but snow, so
no setting can ask for a density there is no room for. The specks themselves
are redrawn every frame and are avowedly not periodic — that is what snow is —
so what closes is the amount, and that is what `t/31-drift.t` asks about.

`t/31-drift.t` is driven off the registry and so covers every effect declaring
a `drift` the day it is declared. A moving parameter under any other name is
outside that sweep and owes the same two proofs — the loop closes, and a still
is untouched — in its own file.

`t/38-reroll.t` walks the registry and proves both halves for every effect
that declares one, so an effect growing a `reroll` is covered the day it is
declared. Two effects need a nudge before the question can even be asked, and
the reasons are recorded there: `pixelsort` consults no randomness at full
coverage, and `osd` blinks whatever the switch says.

## Progress is counted in frames

A still is one step and the step is the whole render, so nothing is reported
and no bar appears. A loop takes long enough to be worth watching, so the
child counts frames down a pipe opened before the fork, and the parent reads
it with a `Glib::IO` watch — bytes off a pipe, which is the same thing it
already does for the error file, and nothing that would have the parent touch
ImageMagick.

The frame is the smallest honest unit: inside one is a chain of ImageMagick
calls, none of which reports progress.

Two things are easy to get wrong here and both were:

- **The total is `frames + 1`, and every report in a render must use the same
  one.** The extra step is the ffmpeg run after the last frame — with a
  soundtrack, an audio render before that — so a bar reaching full and then
  sitting there would be saying the render had finished. Reporting `frames` for
  the loop and `frames + 1` for the encode changes the denominator underneath
  the bar, which reads as a jump backwards.
- **A watch that returned 0 has already removed itself.** `_end_progress` runs
  on every path that finishes with a child, so the callback clears the id when
  it returns 0 — otherwise the removal is a `GLib-CRITICAL`.

`GlitchVape::render` takes `on_frame` and `on_encode` for the same purpose, so
the export path reports through the library rather than through a second loop
in the GUI. The estimate discards the first frame: it pays for decoding the
source that every later frame reuses, so extrapolating from it promises a wait
half again as long as the one that follows.

## Things that have cost time before

- **`Pango::FontDescription->from_string(...)` silently does nothing useful.**
  It is a function, not a method; called with `->` it receives the class name
  as an extra argument, and the binding drops the excess — leaving a
  description of a font family literally called `Pango::FontDescription`,
  which resolves to the default UI font. It looks like it worked, because a
  fallback always does. Call it as `Pango::FontDescription::from_string(...)`.
- **`GtkListBox` activates a row on a single click by default**, so a list
  where activation means "go to the next page" cannot be browsed. Set
  `set_activate_on_single_click(0)` and let double-click and Enter activate.
- **Setting a width on every generated control stretches the switches.**
  `GUI/Params.pm` returns a `stretch` flag for that reason; honour it rather
  than special-casing widget classes at the call site.
- **Mnemonics collide silently.** Gtk cycles between two controls claiming
  the same Alt key rather than complaining, so adding a labelled button to the
  main window is exactly when one gets introduced. `t/26-gui-layout.t` walks
  the window and fails on a duplicate.
- **Seeking a `Gtk3::Calendar` emits `day-selected`** — twice, since
  `select_month` and `select_day` each do — so opening a date picker will
  write back over the field it was opened to show unless guarded.
- **`fit` must be applied on the way out as well as on the way in.** Effects
  that add furniture (`letterbox`, `border`) make the picture bigger than the
  one they were handed, so constraining only the source is a promise the code
  does not keep.
- **No sound on WSL is usually WSLg, not the program.** `/mnt/wslg/pulseaudio.log`
  is the place to look: `module-rdp-sink.c: data_send: send failed` followed by
  a reconnect means PulseAudio is accepting the stream and the bridge to
  Windows is dropping it. Everything inside the program looks healthy in that
  state — the pipeline prerolls, the position advances at real time, and
  `pulsesink` connects without error — so it is worth checking the log before
  suspecting the player.
- **A preview served from the cache answers from an idle, not a child**, so
  `Render::cancel` cannot stop it — there is no job to cancel, and the
  `on_done` is already queued. Anything that has to stop caring about a
  render in flight needs its own token or flag: `GUI/Wizard.pm` keeps a
  counter so a preview of the effect you have just navigated away from is
  dropped instead of appearing under the new one's heading, and `_finish`
  keeps a `gone` flag for the same reason.
- **`Gtk3::ImageView` smooths, and the preview pane is almost never 1:1.**
  Its `interpolation` defaults to Cairo's `good`, and the preview is shown at
  whatever zoom fits the pane — 0.905 on an ordinary window — so every
  one-pixel artefact this program makes is averaged away before anybody sees
  it. `GUI/Preview.pm` sets `nearest`, which is what keeps the claim that a
  preview differs from the export only in scale. The animated preview cannot
  be fixed the same way: `gtksink` exposes no filter, and the loop is H.264
  besides.

- **A `Gtk3::Assistant` must not be destroyed from its own `apply` handler.**
  Gtk's click handler goes on to work out whether a page follows this one, so
  the window is freed and then read: a `GTK_IS_ASSISTANT` assertion and a
  segfault, on the successful path only, which makes it look like whatever
  Apply started did it. Record the answer in `apply` and act on it in `close`,
  which is where Gtk expects the window to go.
- **GtkAssistant's "Finish" button is a jump-to-the-end shortcut**, shown
  whenever two or more complete content pages lie ahead of a confirm page. It
  therefore appears in the middle of a walk and disappears later on, and it
  comes back on a page that was clean the first time it was seen, because
  going forward is what made the page ahead complete.
  `GlitchVape::GUI::Assistant` finds it -- by what it responds to, since its
  label is translated -- and keeps it hidden, for both assistants.

- **Walking a hash's keys draws from the RNG in a random order.** Perl
  randomises hash order per process, so a simulation that iterates
  `keys %something` and draws a number per key gives a different answer on
  every run from the same seed — which is the one promise this program makes
  about seeds. `GlitchVape::Starfield` sorts, and `t/41-starfield.t` proves it
  by running the same seed in four processes under different
  `PERL_HASH_SEED`s. It cannot be caught in one process, because the order is
  fixed for the life of one.

- **A cache in `$ctx->tmpdir` lives exactly one frame.** Every frame of an
  animation is rendered from its own `Context`, whose temp directory dies with
  it — so `cmyk` was rebuilding four rotations of a square twice the picture's
  diagonal for screens it had built the frame before, and the same went for
  the scanline and grille tiles, the Bayer matrices and the palette lookups.
  Eight frames of `cmyk` cost eight times one frame. Anything keyed on the
  settings rather than on the frame goes in `$ctx->cachedir`, which the
  animation loop hands to every frame; `tmpdir` stays per-frame, because the
  scratch files are numbered from one in each.

- **A `.webm` does not say which codec it holds.** VP9 and AV1 both live in
  it; `--codec` settles it, and codec availability is checked before the first
  frame rather than after twenty-four renders.
