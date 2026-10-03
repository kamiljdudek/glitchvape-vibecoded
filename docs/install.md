# Installing GlitchVape

GlitchVape builds its own packages, an `.rpm` for Fedora and a `.deb` for
Debian and Ubuntu, and is installed from those; or it runs straight from a
clone of its source, with nothing installed. Split out of the
[README](../README.md).

1. [Dependencies on Fedora](#dependencies-on-fedora)
2. [Dependencies on Debian and Ubuntu](#dependencies-on-debian-and-ubuntu)
3. [Installing the packages](#installing-the-packages), on either
4. [Running from a clone](#running-from-a-clone)

The dependencies come first because both routes need some. Building the
packages needs the build tools, and nothing else by hand: a package pulls in
what it needs to run when it is installed. A clone needs all of that
installed by hand.

## Dependencies on Fedora

### To build the packages

```bash
sudo dnf install -y rpm-build perl-macros dnf5-plugins
sudo dnf builddep -y package/glitchvape.spec
```

`builddep` installs what the spec's `BuildRequires` names: the compiler and
perl's headers for the compiled grain, and what the test suite needs, since
the build runs it.

### To run from a clone

What the program needs:

```bash
sudo dnf install -y perl ImageMagick ImageMagick-perl perl-YAML-LibYAML \
  perl-File-Which
```

`perl` rather than `perl-interpreter`, because Fedora splits the standard
library into a package per module and the program uses a dozen of them.

What makes it better — animation, and the typefaces the presets ask for, with
fontconfig to find them by:

```bash
sudo dnf install -y ffmpeg-free fontconfig dejavu-sans-fonts \
  google-noto-sans-cjk-fonts cascadia-code-fonts
```

What it uses when it is there — a better quantiser, GIF optimisation, the
photograph's metadata, HEIC without an ImageMagick delegate, parallel batches,
and more candidates for the font roles:

```bash
sudo dnf install -y pngquant gifsicle perl-Image-ExifTool libheif-tools \
  perl-Parallel-ForkManager terminus-fonts ipa-gothic-fonts \
  source-foundry-hack-fonts
```

The window, and GStreamer for its animated preview and for auditioning a
soundtrack:

```bash
sudo dnf install -y perl-Gtk3 perl-Gtk3-ImageView \
  perl-Glib-Object-Introspection
sudo dnf install -y gstreamer1 gstreamer1-plugins-base \
  gstreamer1-plugins-good gstreamer1-plugins-good-gtk
```

The compiled grain, on x86-64 — see [below](#the-compiled-grain):

```bash
sudo dnf install -y gcc make perl-devel perl-ExtUtils-ParseXS
```

`ffmpeg-free` is what Fedora ships; RPM Fusion's `ffmpeg` works too, which is
why the spec asks for `/usr/bin/ffmpeg` rather than for either package by
name. There is no Fedora package for Misaki, so the `pixel` role falls through
to Terminus.

## Dependencies on Debian and Ubuntu

### To build the packages

```bash
sudo apt install -y build-essential
sudo apt build-dep -y ./package
```

`build-dep` reads `package/debian/control` straight out of the checkout and
installs its `Build-Depends`: debhelper, the compiler and perl's headers for
the compiled grain, and what the test suite needs, since the build runs it.

### To run from a clone

What the program needs:

```bash
sudo apt install -y imagemagick libimage-magick-perl libyaml-libyaml-perl \
  libfile-which-perl
```

What makes it better — animation, and the typefaces the presets ask for, with
fontconfig to find them by:

```bash
sudo apt install -y ffmpeg fontconfig fonts-dejavu-core fonts-noto-cjk \
  fonts-cascadia-code
```

What it uses when it is there — a better quantiser, GIF optimisation, the
photograph's metadata, HEIC without an ImageMagick delegate, parallel batches,
and more candidates for the font roles:

```bash
sudo apt install -y pngquant gifsicle libimage-exiftool-perl libheif-examples \
  libparallel-forkmanager-perl fonts-misaki fonts-terminus fonts-ipafont \
  fonts-vlgothic fonts-mplus fonts-unifont fonts-hack
```

The window, and GStreamer for its animated preview and for auditioning a
soundtrack:

```bash
sudo apt install -y libgtk3-perl libgtk3-imageview-perl
sudo apt install -y gir1.2-gstreamer-1.0 gstreamer1.0-plugins-good \
  gstreamer1.0-gtk3 gstreamer1.0-libav
```

GTK 3 rather than 4 because Debian has no `libgtk4-perl` — GTK 4 from Perl
would mean raw `Glib::Object::Introspection` without the API overrides
`Gtk3.pm` provides. GStreamer is reached through introspection because Debian
dropped the Perl binding years ago; the typelib is the same library.

The compiled grain, on amd64 — see [below](#the-compiled-grain). `perl`
already brings its headers, so the compiler is all there is to add:

```bash
sudo apt install -y gcc make
```

## Installing the packages

With the dependencies for building the packages installed, from the top of a
clone. Three packages come out of either build:

| | |
|---|---|
| `glitchvape` | the program and its library — all the command line needs |
| `glitchvape-gui` | the window |
| `glitchvape-fonts-extra` | W95FA, a typeface whose terms are not established — see [fonts.md](fonts.md) |

Install the first, or the first two; the third only if you want that font.
What each one needs to run comes with it from the distribution, and
[packaging.md](packaging.md) has what is in each and how they are built.

### On Fedora

```bash
make rpm
sudo dnf install -y build/rpmbuild/RPMS/*/glitchvape-[0-9]*.rpm \
  build/rpmbuild/RPMS/noarch/glitchvape-gui-[0-9]*.rpm
```

### On Debian and Ubuntu

```bash
make deb
sudo apt install -y ./build/glitchvape_*.deb ./build/glitchvape-gui_*.deb
```

Then, on either, check what the program can see:

```bash
glitchvape --check-deps
glitchvape --check-fonts
```

## Running from a clone

With the dependencies for a clone installed, from the top of the clone —
nothing needs installing, because the scripts find the modules beside them and
the modules find the presets and the fonts the same way:

```bash
make                                       # the compiled grain, on x86-64
./bin/glitchvape --check-deps              # what it can see
./bin/glitchvape --check-fonts             # what each font role resolved to
./bin/glitchvape -p vhs-decay photo.heic   # a render
./bin/glitchvape-gui                       # the window
make test                                  # the suite
```

Of what is listed for a clone, only the first group is needed; everything
else degrades gracefully. Without ffmpeg you lose animation, without pngquant
the quantiser falls back to ImageMagick's, without CJK fonts the text effects
report which package would fix it. Without the window's packages,
`glitchvape-gui` says what is missing — as an `apt` line, which is Debian's —
and exits; the animated preview is checked separately and only when first
asked for, so a machine with GTK but no GStreamer runs the still interface
normally. The
window's tests skip themselves without a display.

### The compiled grain

One thing is compiled: the arithmetic of the `grain` effect, which in Perl
takes a third to half a second at preview size and in C a millisecond or two
— the same bytes from the same seed either way. `make` builds it on x86-64,
and so does `make test`, with GCC 14 or later:

```bash
make                                    # into build/xs
make PGO=1                              # profile-guided, one or two percent more
```

The library is built for x86-64-v3 — AVX2, BMI2 and FMA: Intel from Haswell
(2013) and AMD from Excavator (2015), though budget Pentium, Celeron and Atom
parts went without for years after — and uses GFNI for its random numbers
where the CPU has it. Anywhere it is not built, or on a CPU older than that,
the Perl runs instead and the pictures are the same, slower. `--check-deps`
says which is in use and why, and `GLITCHVAPE_PURE_PERL=1` switches the C off.
