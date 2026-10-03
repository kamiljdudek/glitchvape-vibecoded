# Fonts

The typefaces the presets ask for, which of them ship and which do not, and
where to put one of your own. Split out of the [README](../README.md).

Font *roles* are what presets ask for, not font names, so a preset keeps
working on a machine with a different subset installed. `--check-fonts` shows
which file each role currently resolves to.

## Adding fonts

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

## The bundled fonts

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
