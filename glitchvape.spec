Name:           glitchvape
Version:        0.01
Release:        1%{?dist}
Summary:        Apply VHS, CRT and databending effects to photographs

License:        MIT
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

# The typefaces the presets ask for are not shipped -- they are a couple of
# dozen megabytes under licences of their own. Font *roles* fall through to
# whatever fontconfig can see, so these are what makes the fallbacks good
# rather than merely present. `glitchvape --check-fonts` reports what each
# role resolved to.
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


%package gui
Summary:        Graphical front end for GlitchVape
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
make test


%files
%doc README.md
# Requires a LICENSE file at the top of the tarball. About.pm still declares
# gpl-3-0 via set_license_type(); both need to say MIT.
%license LICENSE
%{_bindir}/%{name}
%{_bindir}/%{name}-batch
%dir %{_datadir}/%{name}
%dir %{_datadir}/%{name}/assets
%dir %{_datadir}/%{name}/assets/artwork
%dir %{_datadir}/%{name}/assets/fonts
%dir %{_datadir}/%{name}/assets/luts
%{_datadir}/%{name}/assets/artwork/logo.png
%{_datadir}/%{name}/assets/artwork/icon-256.png
%{_datadir}/%{name}/presets/
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
