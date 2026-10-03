# Packaging

What the packages contain, how both packagings are built from one tarball,
and where everything lands once installed. Split out of the
[README](../README.md); the commands for building and installing them are in
[install.md](install.md).

## The packages

Both packagings make the same three, split the same way:

| | |
|---|---|
| `glitchvape` | the library and the command-line tools — and on x86-64, the compiled grain |
| `glitchvape-gui` | the Gtk3 window |
| `glitchvape-fonts-extra` | one typeface, in `non-free/fonts` on Debian |

On x86-64 the compiled grain's debug information comes out beside them:
`glitchvape-dbgsym` on Debian, `glitchvape-debuginfo` and
`glitchvape-debugsource` on Fedora. That one file is also why the base package
is built per architecture while the other two are architecture-independent.

The third is separate because of what [fonts.md](fonts.md) says about W95FA:
its terms are a font aggregator's description rather than a document, which
is not enough for a package that claims MIT and OFL on the tin. `glitchvape`
only *suggests* it, and the `ui` role falls through to DejaVu without it.

`package/debian/README.Debian` has the detail, including the one thing this packaging
cannot do as it stands: a source package in main may not contain non-free
content, and this one carries `assets/fonts-nonfree/`. Built locally or in a
PPA it is fine; an upload to Debian proper would need either the licence
settled — at which point the font moves up and the third package disappears —
or the tarball repacked, for which `package/debian/copyright` already carries a
commented-out `Files-Excluded` line.

## How they are built

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

The packaging drives the same `Makefile` the RPM spec does, rather than
restating where anything goes, and `package/debian/rules` installs one binary package
at a time from the targets the Makefile already splits — which is why there
are no `.install` files here. `make check-split`, `make check-licenses` and
the test suite all run during the build.

`make srpm` builds only the source package, and `make rpms` builds it and the
binaries. The rpmbuild tree is `build/rpmbuild` unless `RPMTOPDIR` moves it,
and two escape hatches exist for a machine without the whole toolchain:

```bash
make rpm RPMTOPDIR=$HOME/rpmbuild       # the habitual place instead
make rpm RPMFLAGS='--nodeps --nocheck'  # skip BuildRequires and the tests
make deb DPKGFLAGS=-d                   # skip the build-dependency check
```

`--nocheck` proves the packaging rather than the program: it skips the
`%check` section, which is where the test suite runs.

## Where everything goes

Installed, the modules go to `%{perl_vendorlib}` — `/usr/share/perl5` on
Debian — the compiled grain to perl's `vendorarch`, and the data to
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

## The launcher icon

The launcher icon is not generated. `assets/artwork/icon-256.png` is
committed, because generating it needs ImageMagick and installing should not.
It is the middle 185×185 of the 215×185 logo, enlarged to 256 — cropped rather
than padded, since a launcher draws it at 48 pixels and white bars top and
bottom would spend a third of that on nothing:

```bash
magick assets/artwork/logo.png -gravity center -crop 185x185+0+0 +repage \
    -filter point -resize 256x256! -strip assets/artwork/icon-256.png
```

`-filter point` is the part that matters. The logo is 16-colour pixel art, and
any smooth filter resamples it into some three and a half thousand blended
colours and softens every edge — which is exactly the character the thing is
made of. The same reasoning is why the about window shows the logo unscaled.
