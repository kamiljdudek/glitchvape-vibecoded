# The library, and working on it

The module layout, why the pieces are divided as they are, and the
conventions for changing them. Split out of the [README](../README.md);
see also [CLAUDE.md](../CLAUDE.md), which records the invariants.


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
