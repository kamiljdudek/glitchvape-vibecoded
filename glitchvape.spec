Name:           glitchvape
Version:        0.01
Release:        1%{?dist}
Summary:        Apply VHS, CRT and databending effects to photographs

# The program is MIT. The binary package also carries two typefaces that are
# not the program's: Departure Mono and Fusion Pixel, both under the SIL Open
# Font License 1.1, each installed as its author published it with the licence
# text beside the font -- which is what the OFL asks for and what
# `glitchvape --licenses` and the about window quote.
#
# VCR OSD Mono and W95FA are *not* here. They are free to use, their
# redistribution terms are still being established, and until that is settled
# the Makefile refuses to put them in the tarball; see `make check-licenses`.
# Anyone who has them puts them in one of the drop-in directories below.
License:        MIT AND OFL-1.1
# TODO: point both of these at the repository once it is on a forge.
URL:            https://example.invalid/glitchvape
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

BuildRequires:  make
BuildRequires:  perl-generators
BuildRequires:  perl-interpreter
# Defines %%{perl_vendorlib}, which %%install passes to the Makefile.
BuildRequires:  perl-macros
BuildRequires:  perl(strict)
BuildRequires:  perl(warnings)
BuildRequires:  desktop-file-utils
BuildRequires:  libappstream-glib

# The suite is Perl-only apart from the effects, which need ImageMagick. It
# skips the window tests when there is no display, so it runs under mock.
BuildRequires:  perl(Test::More)
BuildRequires:  perl(Image::Magick)
BuildRequires:  perl(File::Which)

Requires:       ImageMagick
Requires:       perl-interpreter

# Listed rather than left to perl-generators. Fedora splits what used to be
# the core library into a package per module, so none of these is implied by
# perl-interpreter, and a missing one is a runtime failure rather than
# something the build would have caught.
Requires:       perl(Encode)
Requires:       perl(File::Basename)
Requires:       perl(File::Path)
Requires:       perl(File::Spec)
Requires:       perl(File::Temp)
Requires:       perl(File::Which)
Requires:       perl(Getopt::Long)
Requires:       perl(Image::Magick)
Requires:       perl(List::Util)
Requires:       perl(Pod::Usage)
Requires:       perl(Scalar::Util)

# Named as paths rather than as packages: /usr/bin/ffmpeg is provided both by
# Fedora's ffmpeg-free and by RPM Fusion's ffmpeg, and a package name would
# pick a side that the user has already picked for themselves.
Recommends:     /usr/bin/ffmpeg
Recommends:     /usr/bin/ffprobe

# Every one of these is optional by design: GlitchVape::Tools probes for them
# and the effects degrade rather than die. Without pngquant the quantiser
# falls back to ImageMagick's, without libheif-tools an iPhone HEIC is only
# readable if ImageMagick has the delegate, and without ffmpeg the animated
# writers are gone but stills still render.
Recommends:     pngquant
Recommends:     gifsicle
Recommends:     perl-Image-ExifTool
Recommends:     libheif-tools
Recommends:     fontconfig

# Two typefaces ship (see the License tag); the rest of what the presets ask
# for does not. Font *roles* fall through to whatever fontconfig can see, so
# these are what makes the fallbacks good rather than merely present.
# `glitchvape --check-fonts` reports what each role resolved to, and names the
# drop-in directory for anything still missing.
Recommends:     dejavu-sans-fonts
Recommends:     google-noto-sans-cjk-fonts
Recommends:     cascadia-code-fonts
Suggests:       terminus-fonts
Suggests:       ipa-gothic-fonts
Suggests:       source-foundry-hack-fonts

%description
GlitchVape puts a photograph through a signal chain of thirty-nine effects:
tape wobble and tracking error, chromatic aberration, pixel sorting and
databending, film grain, scanlines and phosphor grilles, and the text and
furniture that sit over the top.

Order is not a free choice -- scanlines applied before a downsample get eaten
by the resample -- so each effect declares where in the chain it belongs and
the pipeline sorts by it. Presets bundle a whole look, and a render can be
reproduced exactly from its seed.

This package contains the command-line tools and the library. For the window,
install %{name}-gui.

Departure Mono and Fusion Pixel are included under the SIL Open Font License;
%{name} --licenses prints their terms along with this program's. Fonts of your
own go in ~/.local/share/glitchvape/fonts, or in
%{_datadir}/%{name}/fonts for every account on the machine -- both are
searched ahead of what is installed here, so neither is disturbed by an
upgrade.


%package gui
Summary:        Graphical front end for GlitchVape
# No fonts in this subpackage: the assets belong to the base package.
License:        MIT
Requires:       %{name} = %{version}-%{release}
Requires:       perl(Gtk3)
Requires:       perl(Gtk3::ImageView)
Requires:       perl(Glib)
Requires:       perl(Glib::Object::Introspection)
Requires:       hicolor-icon-theme

# What the window needs on top of the base package's set.
Requires:       perl(Digest::SHA)
Requires:       perl(File::Copy)
Requires:       perl(POSIX)

%description gui
A Gtk3 window over the GlitchVape pipeline: presets and their parameters on
the left, the render on the right, an explicit Apply between them.

It is a front end rather than a second implementation. The controls are
generated from the same declarations that produce the command-line flags, so
an effect added to the registry gets a widget without anyone editing the
interface, and Export goes through the same code path as the command-line
tool -- the result is identical to the equivalent invocation.


%prep
%autosetup


%build
# Nothing is compiled. The default target only prints what the targets are,
# which would be noise in a build log.


%install
%make_install \
    PREFIX=%{_prefix} \
    PERLDIR=%{perl_vendorlib}

desktop-file-validate %{buildroot}%{_datadir}/applications/%{name}.desktop
appstream-util validate-relax --nonet \
    %{buildroot}%{_datadir}/metainfo/%{name}.metainfo.xml


%check
# The Makefile asserts that nothing outside the GUI module set reaches for
# Gtk3, which is what makes the base package installable without it.
make check-split
# And that every font in the tarball arrived with the licence it is under.
make check-licenses
make test


%files
%doc README.md
# Tagged where the Makefile installed it rather than copied into
# %%{_licensedir}, because this is the copy the program itself reads: the
# about window and --licenses quote this file instead of restating it in Perl,
# so there is one LICENSE on disk and `rpm -qL %{name}` still finds it.
%license %{_datadir}/%{name}/LICENSE
%{_bindir}/%{name}
%{_bindir}/%{name}-batch
%dir %{_datadir}/%{name}
%dir %{_datadir}/%{name}/assets
%dir %{_datadir}/%{name}/assets/artwork
%dir %{_datadir}/%{name}/assets/luts
%{_datadir}/%{name}/assets/artwork/logo.png
%{_datadir}/%{name}/assets/artwork/icon-256.png
%{_datadir}/%{name}/presets/

# The bundled font releases, each unpacked as published: the .otf files and,
# beside them, the OFL text and README their authors shipped. Owned whole
# rather than file by file so that updating a font is dropping in the new
# release, not editing this list.
#
# The licence files inside are not separately %%license-tagged: they are
# already in this glob, and listing a path twice in one %%files section is how
# a spec grows a "file listed twice" warning for no gain. What matters is that
# they are installed beside the fonts, which is where the OFL wants them and
# where GlitchVape::Licenses looks.
%{_datadir}/%{name}/assets/fonts/

# Shipped empty, and stays empty: the drop-in directory for fonts this package
# may not distribute -- VCR OSD Mono and W95FA today. It is on the search path
# ahead of the bundled fonts above, so a file dropped here wins and survives
# every upgrade of this package. Per-user, the same thing is
# ~/.local/share/glitchvape/fonts and needs no packaging at all.
%dir %{_datadir}/%{name}/fonts
# GUI.pm and GUI/ belong to the subpackage; everything else is here.
%{perl_vendorlib}/GlitchVape.pm
%{perl_vendorlib}/GlitchVape/
%exclude %{perl_vendorlib}/GlitchVape/GUI.pm
%exclude %{perl_vendorlib}/GlitchVape/GUI/


%files gui
%{_bindir}/%{name}-gui
%{perl_vendorlib}/GlitchVape/GUI.pm
%{perl_vendorlib}/GlitchVape/GUI/
%{_datadir}/applications/%{name}.desktop
%{_datadir}/metainfo/%{name}.metainfo.xml
%{_datadir}/icons/hicolor/256x256/apps/%{name}.png


%changelog
* Mon Aug 24 2026 Kamil Dudek <kamiljdudek@localhost.localdomain> - 0.01-1
- Initial package.
- Bundle Departure Mono and Fusion Pixel under the OFL, licence text included.
- Add a drop-in font directory under %{_datadir}/%{name} for the typefaces
  that are not ours to distribute.
