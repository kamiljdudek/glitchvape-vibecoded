# CLAUDE.md

Orientation for anyone — human or agent — picking this codebase up. The
[README](README.md) explains what GlitchVape *does* and how to use it; this
file explains how it is put together, which invariants are easy to break
without noticing, and how each of them is checked.

## What it is

A Perl image pipeline that puts a photograph through a chain of thirty-nine
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
| `lib/GlitchVape/Effect/*.pm` | the thirty-nine effects, grouped by theme not by stage |
| `lib/GlitchVape/GUI.pm`, `GUI/` | everything Gtk3, and the only thing that may `use Gtk3` |
| `presets/*.yml` | a look, as a set of effects and parameters |
| `assets/fonts/`, `assets/fonts-nonfree/` | bundled typefaces, split by licence — see below |
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
string parameters get something better based on their name (a colour picker, a
font-role combo, a calendar for `osd.date`).

### 2. Where an effect runs is a property of the effect

`stage` is not decoration. The pipeline sorts by it, because order is not a
free choice — scanlines applied before a downsample get eaten by the resample.
The nine stages, in execution order:

`format` → `colour` → `channels` → `damage` → `signal` → `grain` → `optics` →
`overlay` → `framing`

The stages double as the browsing categories in the Add Effect wizard, which
is deliberate: where an effect runs and what it is for are the same fact, so
there is no second taxonomy to keep in sync.

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

## Packaging

Three binary packages from one source, in both packagings, split the same way:

| | |
|---|---|
| `glitchvape` | library + CLI |
| `glitchvape-gui` | the window |
| `glitchvape-fonts-extra` | typefaces whose terms are not established |

`debian/rules` installs one package at a time from the Makefile's own targets
rather than staging everything and splitting it back out with `.install`
globs — the split already exists and `check-split` proves it.

`GlitchVape::Paths::DATADIR` is one constant naming the installed data
directory, rewritten by `make install`. Empty means "not installed" and sends
`Assets` and `Config` back to walking up from `__FILE__`, which is what makes
a checkout behave as though the packaging did not exist.

Manual pages are generated from the tools' own POD at install time rather than
committed, so `man glitchvape` and `glitchvape --help` cannot document
different flags — `pod2usage` reads the same block.

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
make dist              # source tarball
make deb               # the three .deb packages (needs debhelper)
make rpm               # the three .rpm packages (make rpms for the srpm too)
make srpm              # source RPM only

perl -Ilib bin/glitchvape --check-deps    # what external tools are present
perl -Ilib bin/glitchvape --check-fonts   # what each font role resolved to
perl -Ilib bin/glitchvape --list-effects  # all of them, by stage
perl -Ilib bin/glitchvape --explain NAME  # one effect's parameters
```

Three environment variables override where things are found, which is how the
tests run against the checkout regardless of what is installed:
`GLITCHVAPE_ASSETS`, `GLITCHVAPE_PRESETS`, `GLITCHVAPE_FONTS`.

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
- **A `.webm` does not say which codec it holds.** VP9 and AV1 both live in
  it; `--codec` settles it, and codec availability is checked before the first
  frame rather than after twenty-four renders.
