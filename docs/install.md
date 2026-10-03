# Installing from a checkout

What the program needs beyond the Debian line in the [README](../README.md):
Fedora's equivalent, the window's dependencies, and the one part of it that is
compiled. Split out of the README; building packages instead is in
[packaging.md](packaging.md), and the typefaces are in [fonts.md](fonts.md).

## Fedora

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

## The window

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

## The compiled grain

One thing is compiled: the arithmetic of the `grain` effect, which in Perl
takes a third to half a second at preview size and in C a millisecond or two
— the same bytes from the same seed either way. `make` builds it on x86-64
(`make test` does too), with GCC 14 or later:

```bash
make                                    # into build/xs
make PGO=1                              # profile-guided, one or two percent more
```

Debian needs nothing beyond `gcc`, since `perl` already brings its headers;
Fedora needs `gcc perl-devel perl-ExtUtils-ParseXS`. The library is built for
x86-64-v3 — AVX2, BMI2 and FMA: Intel from Haswell (2013) and AMD from
Excavator (2015), though budget Pentium, Celeron and Atom parts went without
for years after — and uses GFNI for its random numbers where the CPU has it.
Anywhere it is not built, or on a CPU older than that, the Perl runs instead
and the pictures are the same, slower. `--check-deps` says which is in use and
why, and `GLITCHVAPE_PURE_PERL=1` switches the C off.
