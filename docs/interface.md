# The window

How the graphical interface is arranged, and the arrangements that were
tried first. Split out of the [README](../README.md), which is the tour;
this is the detail behind it.


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

### The list is banded by stage

The pipeline is sorted by stage and the rows cannot be dragged, so an effect
you add appears wherever its stage falls rather than where you put it. A plain
sorted list invites the worst reading of that — a list that rearranges itself
and refuses to be rearranged — so the rows sit under stage headings instead,
and the order belongs to the bands rather than to the rows.

Each heading's tooltip says where in the chain it runs and *why it has to*:
data damage runs before the overlays because damage is done to the picture and
not to the furniture; framing is last because bars added earlier would be
scanned and bled like picture. Only the occupied stages appear.

The same sentences are on the wizard's first page, under each stage, which is
where you are choosing which part of the chain to change and therefore where
the chain having an order is the thing you are reasoning about.

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
`osd.date` gets a calendar. A parameter that offers a list of values says
whether that list is everything: `bitmap.palette` is a plain drop-down of the
palettes, while `palette.name` keeps an entry beside its list, because that
effect is about the colours and an inline `#FF71CE,#01CDFE` is exactly what
somebody might mean. Export calls the same `GlitchVape::render` that
`bin/glitchvape` calls, and the result is byte-identical to the equivalent
command line; there is a test that asserts exactly that.

The declaration also decides the *order* of the rows and what they are
**called**, and which of them are greyed out. A parameter can say that it
needs another to hold first — `osd.date` needs a timestamp that is not being
invented — and the control is greyed rather than hidden while that is not
true: a row that vanishes teaches nobody what turned it on, and one that sits
there looking typeable while nothing it says reaches the render is worse. The
value is left alone, so switching the gate back on gives back what was typed.

The three parameters with a second widget beside the entry — the colour
picker, the calendar and the clock — keep the **entry** as the value, with the
widget only a way of filling it in. Each has meanings no picker can express:
an empty colour means *no colour*, an empty `osd.date` means *draw no date*,
and both the date and the time take any literal string at all. So the calendar
writes `JAN 05 1995` into the field, opening on whatever the field already
says rather than on today — a present-day timestamp being exactly the
anachronism the effect exists to avoid — and the clock, which Gtk3 does not
have and which is two spin buttons and a meridiem here, writes `PM  3:47` the
same way. A value they cannot parse is left alone: somebody who typed
`TUESDAY` meant it.

A **seed** gets a fourth: a spin button with a reroll button beside it. It is
the one number in any declaration nobody wants to choose. It exists so a
render can be repeated — type it back in and the same static, the same clicks,
the same drive come out — so it has to stay a number you can read and write
down. But almost every time anybody touches one, what they want is not a
particular value, it is a *different* one, and a spin button offers 1, 2, 3 as
though the numbers near each other were near each other. So the box stays for
the rare case and the button is there for the common one, which is every
generated track that has a seed at all.

### The menu

The hamburger at the end of the header bar holds what is done rarely enough
not to earn a button of its own — which is the test for whether something
belongs behind one:

Grouped by what an entry is *for*, with a separator between each group, so the
grouping is visible rather than merely intended:

| Group | | |
|---|---|---|
| move | **Undo** / **Redo** | the same actions as the header-bar pair; here because a menu is where a keyboard-first user looks for them |
| change | **Randomize** | a new seed — reshuffles every effect that draws on randomness, leaving the parameters alone |
| keep | **Save as preset…** | writes the current settings to `presets/`, usable immediately as `-p <name>` |
| discard | **Clear all effects** | empties the pipeline without leaving the image; an ordinary edit, so undo steps back over it |
| | **Clear preview cache** | empties the render store; nothing is lost but time |
| settings | **Preferences…** | General, Preview, Metadata and Watermarking, in a stack — the settings that belong to the program rather than to a photograph |
| | **Export profiles…** | named export settings, kept separately for videos and for stills |
| tells you | **Check dependencies…** | what this machine can actually do, as features, backends and formats with a light each |
| | **Copy command line…** | the `glitchvape` invocation that produces this export, to read and to copy |
| about | **About GlitchVape** | version, licence, and how many effects and presets this copy can actually see |

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

#### Export is a wizard

Export used to be one file chooser asking *where*, with everything else
settled in a menu dialog that had to be visited first and said nothing about
the export it was for. The two halves of one action were in two places and
only one of them was on the way.

It is a `GtkAssistant` now, asking in the order the decisions are made:

1. **Express or Advanced.** Express picks a saved profile and shows both the
   settings and the exact path it would write, so the rest is one click.
   Advanced asks the questions below.
2. **Resolution**, 3. **Format**, 4. **Format options** — skipped when the
   chosen format has none, 5. **Frames and frame rate** — stills never see it,
   6. **File location**, pre-filled with `~/Videos` or `~/Pictures` and a name
   derived from the source and the preset.

Pages that do not apply are left out rather than shown greyed: a page saying
it does not apply teaches nothing that omitting it does not.

The navigation is Next throughout and Apply at the end. Gtk offers a
jump-to-the-end button labelled *Finish* whenever two or more complete pages
are ahead of you, which meant three different terminal buttons appeared and
vanished during one walk on a rule nobody could see. It is suppressed, here
and in the Add Effect assistant, by `GlitchVape::GUI::Assistant`.

**Export profiles** in the menu manages the saved ones — a list per kind with
an action bar, and four built-ins that ship so the first run has something to
offer. The four are read-only: neither Edit nor Remove applies to them, and
both buttons say why rather than only refusing. Duplicate is how you get one
like a default but different. Your own live in
`~/.config/glitchvape/export-profiles.yml`.

The settings a profile holds are these:

**Video**

| | |
|---|---|
| Frame rate | the same setting as in Preferences → Preview — see below |
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

The frame rate appears here *and* in Preferences because it is
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

Forty-five effects are too many for one list, so **+ → Single effect…** opens
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
disk. It also belongs to one effect: Back, a different choice and forward
again is far quicker than a render, so every request carries a token and a
result that arrives after the page has moved on is dropped rather than shown
under the wrong heading.

**Reset to defaults**, at the foot of the settings, puts every parameter back
to what the effect declares — and greys itself out while there is nothing to
put back, the same argument as the greyed parameters above it.

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

### Another photograph is another window

Open used to replace what was in the window, which threw away the pipeline,
the soundtrack and the whole undo history of the previous photograph — in one
click, with no way back, since the history went with it. Nothing else in the
program can destroy that much at once.

So Open starts a second copy of the program on the new file and leaves this
one alone; the dialog says **Open image in a new window** when that is what
it is about to do. The exception is the first Open in a window, where there is
nothing to lose and an empty window would otherwise be left behind.

That is a rule about whether anything is open, not about whether anything has
been *done* to it. Whether a pipeline is worth keeping is not a question the
program can answer for you, and a window that sometimes replaces what is in it
is worse than one that never does — the only way to find out which you have is
to lose the work. If the second instance cannot be started, it says so and
nothing is opened: falling back to opening it here would be the exact thing
this avoids.

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

The speaker button in the toolbar plays the preview silently, and the same
setting is a switch in **Preferences → Preview** — one setting seen twice rather
than two that can disagree, so moving either moves the other. The switch is
there because that dialog has room to say what the button cannot: that the
soundtrack is still rendered and still in the exported file.

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

The pane then shows that render at whatever zoom fits it, which is almost
never 1:1, and **the scaling is nearest-neighbour**. Smoothing it would be
right for a photograph and is wrong for everything this program adds to one:
a scanline gap, a dither checker, a grain, the one-pixel highlight that makes
a bevel look raised — each is an artefact one pixel across, and averaged into
a pane at 90% every one of them becomes a soft grey suggestion of itself. It
shows worst on `chicago`, whose whole subject is hard edges. Enlarged, the
preview gives square pixels; reduced, it drops them rather than blending them,
which is the same lie a smaller screen tells.

The animated preview does not get this: it plays an H.264 loop through
GStreamer's `gtksink`, which exposes no filter of its own. A loop therefore
previews softer than the file it came from.

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

