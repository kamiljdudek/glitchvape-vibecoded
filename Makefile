# GlitchVape has nothing to compile: it is Perl and data files. This exists so
# that `make install DESTDIR=...` is one command with one definition of where
# everything goes, rather than that knowledge living in a spec file where only
# rpmbuild can exercise it.

NAME       = glitchvape
VERSION    = 0.01

# Where the packaging lives, and where everything it produces goes.
#
# Two directories rather than a scatter of files at the top of the tree: what
# a distribution needs to build a package is not what somebody reading the
# program needs to see first, and build output is not source at all. $(BUILDDIR)
# is entirely disposable -- `make clean` removes it whole -- which is why the
# rpmbuild tree is put inside it too.
PKGDIR     = package
BUILDDIR   = build

PREFIX     ?= /usr/local
DESTDIR    ?=

BINDIR      = $(PREFIX)/bin
DATADIR     = $(PREFIX)/share/$(NAME)
MANDIR      = $(PREFIX)/share/man
ICONDIR     = $(PREFIX)/share/icons/hicolor
APPDIR      = $(PREFIX)/share/applications
METAINFODIR = $(PREFIX)/share/metainfo

# Where the modules go. Overridden by the packaging with the distribution's
# own vendor directory; the default is what a plain `make install` should use.
PERLDIR    ?= $(PREFIX)/share/perl5

INSTALL         = install
INSTALL_DATA    = $(INSTALL) -m 644
INSTALL_PROGRAM = $(INSTALL) -m 755
INSTALL_DIR     = $(INSTALL) -d -m 755

PERL      ?= perl
PROVE     ?= prove
POD2MAN   ?= pod2man

# The manual pages are generated rather than written, because the POD they
# come from is not documentation kept alongside the tools -- it is the
# documentation the tools themselves print. `glitchvape --help` is pod2usage
# over the same block, so a flag cannot be documented in one and missing from
# the other.
MAN1 = $(addsuffix .1,$(SCRIPTS))

# ---------------------------------------------------------------------------
# Which fonts are ours to hand on, and in which package
#
# Two questions, and they used to be answered by one rule. A font ships if its
# licence ships with it -- decided structurally rather than by a list to keep
# up to date: a release unpacked whole brings its LICENSE along and ships, a
# file dropped in loose brings nothing with it and does not. But "has a
# licence" is not "has a licence we may pass on in this package", and treating
# them as the same thing meant a font could only be documented by being
# distributed.
#
# So there are two directories, and which one a font is in is the answer to
# the second question:
#
#   assets/fonts/          free to redistribute; ships in the base package,
#                          whose License tag has to cover every one of them.
#   assets/fonts-nonfree/  documented but restricted, or not established at
#                          all; ships only in glitchvape-fonts-extra.
#
# Both are on GlitchVape::Fonts' search path, so a checkout finds every font
# either way and the split is invisible to everything but the packaging.
#
# Restricted today: W95FA alone. VCR OSD Mono was here until its author
# answered the question directly -- free for any purpose, commercial included
# -- which is what moved it up. `make check-licenses` states what the rule
# concluded for each directory.
FONT_LICENCE_GLOB = LICENSE* LICENCE* COPYING* OFL*

FONT_LICENCES = $(wildcard $(foreach g,$(FONT_LICENCE_GLOB),assets/fonts/*/$(g)))
FONT_DIRS     = $(sort $(patsubst %/,%,$(dir $(FONT_LICENCES))))
FONT_FILES    = $(if $(FONT_DIRS),$(shell find $(FONT_DIRS) -type f))

EXTRA_LICENCES = \
    $(wildcard $(foreach g,$(FONT_LICENCE_GLOB),assets/fonts-nonfree/*/$(g)))
EXTRA_FONT_DIRS  = $(sort $(patsubst %/,%,$(dir $(EXTRA_LICENCES))))
EXTRA_FONT_FILES = \
    $(if $(EXTRA_FONT_DIRS),$(shell find $(EXTRA_FONT_DIRS) -type f))

SCRIPTS   = glitchvape glitchvape-batch glitchvape-gui

# Split so that the packaging can put the window in its own subpackage.
# GUI.pm sits beside GUI/ rather than inside it, so it has to be named
# separately -- and it is the file that pulls in Gtk3, which is the whole
# point of the split. `make check-split` proves the division is honest.
GUI_MODULES = lib/GlitchVape/GUI.pm $(shell find lib/GlitchVape/GUI -name '*.pm')
CLI_MODULES = $(filter-out $(GUI_MODULES), $(shell find lib -name '*.pm'))

.PHONY: all test check check-split check-licenses tidy critic dist deb \
        srpm rpm rpms man install install-cli install-fonts \
        install-fonts-extra install-gui uninstall clean

all:
	@echo "$(NAME) $(VERSION) -- nothing to build."
	@echo "make test      run the test suite"
	@echo "make install   PREFIX=$(PREFIX)"
	@echo "make deb       build the Debian packages"
	@echo "make rpm       build the RPM packages (make rpms for the srpm too)"

test check:
	$(PROVE) -Ilib -r t/

# The base package must not need Gtk3. A module that reaches for it from
# outside the GUI set would make that false silently, so it is asserted here
# rather than discovered when someone installs the CLI on a server.
check-split:
	@bad=$$(grep -lE '^ *(use|require) +(Gtk3|Glib)\b' $(CLI_MODULES) || true); \
	    if [ -n "$$bad" ]; then \
	        echo "check-split: these are not GUI modules but use Gtk3/Glib:" >&2; \
	        echo "$$bad" >&2; exit 1; \
	    fi
	@echo "check-split: $(words $(CLI_MODULES)) CLI modules, \
$(words $(GUI_MODULES)) GUI modules, no Gtk3 outside the GUI set"

# Every font that ships, ships with the licence its author wrote. The rule
# above makes that true by construction; this says out loud what it decided,
# because "no font shipped without its licence" is the kind of claim that
# should be checked by the build rather than believed.
#
# It is not a tautology: it re-reads the directories at check time, so a
# release whose licence file was lost in an unpack -- or a path hardcoded
# somewhere in defiance of FONT_DIRS -- fails here rather than in a bug
# report from somebody's lawyer.
check-licenses:
	@fail=0; \
	for d in $(FONT_DIRS); do \
	    found=$$(cd $$d && ls $(FONT_LICENCE_GLOB) 2>/dev/null | head -1); \
	    if [ -z "$$found" ]; then \
	        echo "check-licenses: $$d ships fonts but has no licence" >&2; \
	        fail=1; \
	    else \
	        echo "  base   $$d  ($$found)"; \
	    fi; \
	done; \
	for d in $(EXTRA_FONT_DIRS); do \
	    found=$$(cd $$d && ls $(FONT_LICENCE_GLOB) 2>/dev/null | head -1); \
	    if [ -z "$$found" ]; then \
	        echo "check-licenses: $$d ships fonts but has no licence" >&2; \
	        fail=1; \
	    else \
	        echo "  extra  $$d  ($$found)"; \
	    fi; \
	done; \
	for f in $$(find assets/fonts assets/fonts-nonfree -maxdepth 1 -type f \
	        2>/dev/null); do \
	    echo "  hold   $$f  (nothing beside it says what its terms are)"; \
	    fail=1; \
	done; \
	[ $$fail -eq 0 ] || exit 1; \
	echo "check-licenses: $(words $(FONT_FILES)) files from \
$(words $(FONT_DIRS)) releases in the base package, \
$(words $(EXTRA_FONT_FILES)) from $(words $(EXTRA_FONT_DIRS)) in \
$(NAME)-fonts-extra, each with its licence"

# ---------------------------------------------------------------------------
# Manual pages

# Section 1 with the project as the "source" and no date, so that two builds
# of the same source produce byte-identical pages -- pod2man defaults the date
# to the file's mtime, which makes the package unreproducible for no gain.
man: $(MAN1)

%.1: bin/%
	$(POD2MAN) --section=1 --center="GlitchVape" --release="$(NAME) $(VERSION)" \
	    --date="2026-08-25" $< $@

tidy:
	perltidy -b -bext='/' $(CLI_MODULES) $(GUI_MODULES) $(addprefix bin/,$(SCRIPTS))

critic:
	perlcritic lib/ bin/ t/

# install-fonts-extra is deliberately not here. The default install is what a
# person gets from `sudo make install`, and it should put nothing on their
# machine whose terms this project could not state -- the same rule the base
# package follows. Ask for it by name, or install glitchvape-fonts-extra.
install: install-cli install-fonts install-gui

# ---------------------------------------------------------------------------
# The command line, the library and the data

install-cli:
	$(INSTALL_DIR) $(DESTDIR)$(BINDIR)
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/presets
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/assets/artwork
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/assets/luts
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/assets/fonts

# The system-wide drop-in directory, shipped empty. $(DATADIR)/fonts rather
# than $(DATADIR)/assets/fonts: the second belongs to whoever installed the
# package and is rewritten by the next upgrade, while this one is the
# $XDG_DATA_DIRS location GlitchVape::Fonts searches and nothing here will
# ever write to it. Per-user, the equivalent is ~/.local/share/glitchvape/fonts
# and needs no install step at all.
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/fonts

	for m in $(CLI_MODULES); do \
	    d=$(DESTDIR)$(PERLDIR)/$$(dirname $${m#lib/}); \
	    $(INSTALL_DIR) $$d && $(INSTALL_DATA) $$m $$d; \
	done

# The one line that has to change between a checkout and an install. Written
# as a constant on a line of its own precisely so this substitution can be a
# single unambiguous match -- and verified below, because a silent miss here
# is an install that cannot find a single preset.
	sed -i "s|^use constant DATADIR => q{};|use constant DATADIR => '$(DATADIR)';|" \
	    $(DESTDIR)$(PERLDIR)/GlitchVape/Paths.pm
	grep -q "^use constant DATADIR => '$(DATADIR)';" \
	    $(DESTDIR)$(PERLDIR)/GlitchVape/Paths.pm \
	    || { echo "install: failed to set DATADIR in Paths.pm" >&2; exit 1; }

	$(INSTALL_DATA) presets/*.yml $(DESTDIR)$(DATADIR)/presets/
	$(INSTALL_DATA) assets/artwork/logo.png $(DESTDIR)$(DATADIR)/assets/artwork/
	$(INSTALL_DATA) assets/artwork/icon-256.png $(DESTDIR)$(DATADIR)/assets/artwork/

# Beside the data rather than only in the packaging's licence directory,
# because the about window and `glitchvape --licenses` read it from here.
# There is one copy and the program quotes it; nothing restates it in Perl.
	$(INSTALL_DATA) LICENSE $(DESTDIR)$(DATADIR)/LICENSE

	for s in glitchvape glitchvape-batch; do \
	    $(INSTALL_PROGRAM) bin/$$s $(DESTDIR)$(BINDIR)/$$s; \
	done
	$(MAKE) fix-inc SCRIPT_LIST="glitchvape glitchvape-batch"

	$(MAKE) install-man MAN_LIST="glitchvape glitchvape-batch"

# ---------------------------------------------------------------------------
# The fonts that are ours to hand on
#
# Installed with their directory structure intact, which is not tidiness:
# GlitchVape::Licenses finds a licence by walking beside the font, so a
# release flattened into one directory would arrive with its LICENSE
# detached from what it covers.

install-fonts: check-licenses
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/assets/fonts
	@set -e; for f in $(FONT_FILES); do \
	    rel=$${f#assets/fonts/}; \
	    d=$(DESTDIR)$(DATADIR)/assets/fonts/$$(dirname $$rel); \
	    $(INSTALL_DIR) $$d; \
	    echo "$(INSTALL_DATA) $$f $$d/"; \
	    $(INSTALL_DATA) $$f $$d/; \
	done

# ---------------------------------------------------------------------------
# The fonts that are not
#
# Same layout one directory over, which is what makes this a packaging
# decision rather than a code one: GlitchVape::Fonts searches
# assets/fonts-nonfree wherever it finds it, so a machine with this installed
# and a machine with a checkout resolve the same roles.

install-fonts-extra: check-licenses
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/assets/fonts-nonfree
	@set -e; for f in $(EXTRA_FONT_FILES); do \
	    rel=$${f#assets/fonts-nonfree/}; \
	    d=$(DESTDIR)$(DATADIR)/assets/fonts-nonfree/$$(dirname $$rel); \
	    $(INSTALL_DIR) $$d; \
	    echo "$(INSTALL_DATA) $$f $$d/"; \
	    $(INSTALL_DATA) $$f $$d/; \
	done

# ---------------------------------------------------------------------------
# The window

install-gui:
	$(INSTALL_DIR) $(DESTDIR)$(BINDIR)
	$(INSTALL_DIR) $(DESTDIR)$(APPDIR)
	$(INSTALL_DIR) $(DESTDIR)$(METAINFODIR)
	$(INSTALL_DIR) $(DESTDIR)$(ICONDIR)/256x256/apps

	for m in $(GUI_MODULES); do \
	    d=$(DESTDIR)$(PERLDIR)/$$(dirname $${m#lib/}); \
	    $(INSTALL_DIR) $$d && $(INSTALL_DATA) $$m $$d; \
	done

	$(INSTALL_PROGRAM) bin/glitchvape-gui $(DESTDIR)$(BINDIR)/glitchvape-gui
	$(MAKE) fix-inc SCRIPT_LIST="glitchvape-gui"

	$(MAKE) install-man MAN_LIST="glitchvape-gui"

	$(INSTALL_DATA) $(PKGDIR)/$(NAME).desktop \
	    $(DESTDIR)$(APPDIR)/$(NAME).desktop
	$(INSTALL_DATA) $(PKGDIR)/$(NAME).metainfo.xml \
	    $(DESTDIR)$(METAINFODIR)/$(NAME).metainfo.xml

# The logo is 215x185 and an icon theme directory wants a square, so the icon
# is the middle 185x185 of it enlarged to 256 -- cropped rather than padded,
# because a launcher shows the icon at 48 pixels and white bars top and bottom
# would spend a third of that on nothing.
#
# Enlarged with a nearest-neighbour filter, which is why the file is kept in
# the tree rather than generated here: any smooth filter turns a 16-colour
# pixel-art image into three and a half thousand blended ones and softens
# every edge, and installing should need no image tooling at all. See
# assets/artwork/icon-256.png; the command that made it is in the README.
	$(INSTALL_DATA) assets/artwork/icon-256.png \
	    $(DESTDIR)$(ICONDIR)/256x256/apps/$(NAME).png

# ---------------------------------------------------------------------------

# Generated at install time rather than committed, so that a page can never
# disagree with the --help of the tool it documents.
.PHONY: install-man
install-man:
	$(INSTALL_DIR) $(DESTDIR)$(MANDIR)/man1
	for s in $(MAN_LIST); do \
	    $(POD2MAN) --section=1 --center="GlitchVape" \
	        --release="$(NAME) $(VERSION)" --date="2026-08-25" \
	        bin/$$s $(DESTDIR)$(MANDIR)/man1/$$s.1; \
	done

# Installed scripts find the modules on @INC like anything else, so the
# checkout's `use lib` has to go. Left in, it would put a directory that does
# not exist -- or worse, one that does -- ahead of the installed library.
.PHONY: fix-inc
fix-inc:
	for s in $(SCRIPT_LIST); do \
	    sed -i -e '/^use FindBin ();$$/d' \
	           -e '\|^use lib "\$$FindBin::Bin/\.\./lib";$$|d' \
	        $(DESTDIR)$(BINDIR)/$$s; \
	    ! grep -q 'FindBin' $(DESTDIR)$(BINDIR)/$$s \
	        || { echo "install: $$s still refers to FindBin" >&2; exit 1; }; \
	done

# What goes into the tarball, and so into the src.rpm. Everything the build
# needs and nothing it does not.
#
# assets/ is named a directory at a time rather than whole, so that the font
# directories are exactly $(FONT_DIRS) and $(EXTRA_FONT_DIRS) -- the releases
# that brought a licence with them. A font sitting loose in either directory
# is a font somebody fetched for their own machine and is not in the tarball,
# which is the same rule .gitignore applies and the one check-licenses states.
#
# Both trees are in the one tarball because both packagings build every binary
# package from it: which font ends up in which .rpm or .deb is decided by the
# spec's %files lists and by debian/rules, not by what the source carries.
#
# assets/luts is not named here even though install-common creates it and the
# spec ships it: it is an empty directory for LUTs somebody drops in, so there
# has never been anything in the tree to put in the tarball. Naming it made
# tar report a missing file on every `make dist` -- harmlessly, because the
# pipe swallows the status, which is the only reason it went unnoticed.
#
# $(PKGDIR) goes in whole, spec and debian/ together, because both packagings
# are built from this tarball and each needs its own half of it. Nothing has
# to be excluded from it any more: a build never writes there. It writes into
# $(BUILDDIR), which is not in the tarball at all.
DIST    = $(NAME)-$(VERSION)
TARBALL = $(BUILDDIR)/$(DIST).tar.gz

dist: check-licenses
	rm -rf $(BUILDDIR)/$(DIST) $(TARBALL)
	mkdir -p $(BUILDDIR)/$(DIST)
	tar -cf - \
	    --exclude='*.bak' --exclude='*.tdy' \
	    --exclude='*.ERR' --exclude='*.LOG' \
	    bin lib presets t Makefile README.md LICENSE $(PKGDIR) \
	    assets/artwork $(FONT_DIRS) $(EXTRA_FONT_DIRS) \
	    .perlcriticrc .perltidyrc \
	  | tar -xf - -C $(BUILDDIR)/$(DIST)
	tar -czf $(TARBALL) -C $(BUILDDIR) $(DIST)
	rm -rf $(BUILDDIR)/$(DIST)
	@echo "$(TARBALL)"

# ---------------------------------------------------------------------------
# The RPM packages
#
# Both are built from the tarball with -t rather than from the spec in the
# tree, which is not a detail: -t unpacks the tarball and builds what is
# inside it, so a file `make dist` failed to include is a build failure here
# rather than a package that is missing something nobody notices until it is
# installed. It is the same reason `make deb` runs the test suite.
#
# Everything lands under $(RPMTOPDIR), which is inside $(BUILDDIR) rather than
# in $$HOME: a build of this tree should not write outside this tree, and
# `make clean` should be able to undo it. Point it at ~/rpmbuild if the
# habitual location is wanted:
#
#     make rpm RPMTOPDIR=$$HOME/rpmbuild
#
# It is made absolute because rpmbuild's %_topdir will not accept a relative
# path -- it resolves it against wherever rpmbuild happens to chdir to, which
# is not here.
RPMTOPDIR ?= $(CURDIR)/$(BUILDDIR)/rpmbuild
RPMBUILD  ?= rpmbuild

# Extra macro definitions, and extra rpmbuild flags. Two variables rather than
# one because they do not go to the same places: the defines are also handed
# to `rpm --eval` by the check below, and rpm rejects rpmbuild-only options
# like --nocheck, so putting everything in one variable makes the check fail
# on exactly the invocation that was trying to get past it.
#
#     make rpm RPMDEFINES='--define "foo bar"' RPMFLAGS='--nodeps --nocheck'
RPMDEFINES ?=
RPMFLAGS   ?=

# --define rather than a bare -D so the value survives a path with a space in
# it, and stated once so neither target depends on the other having run.
RPM_DEFINES = --define "_topdir $(RPMTOPDIR)" $(RPMDEFINES)

# Two things are checked, because two things go wrong and they look nothing
# alike.
#
# rpmbuild missing is the obvious one. The second is subtler and cost an
# afternoon: %{perl_vendorlib} is defined by Fedora's perl-macros package, and
# without it every %files entry naming it expands to a literal
# "%{perl_vendorlib}/..." and the build dies with `File must begin with "/"`,
# which reads exactly like a bug in the spec and is not one. Debian's rpm
# package installs rpmbuild without any of Fedora's macros, so this is
# precisely what `make rpm` on the wrong machine looks like.
#
# Evaluated with the same defines the build will use, so supplying the value
# through RPMDEFINES satisfies the check rather than running into it.
.PHONY: rpm-tools
rpm-tools:
	@command -v $(RPMBUILD) >/dev/null || { \
	    echo "rpm: $(RPMBUILD) is not installed." >&2; \
	    echo "  Fedora/RHEL:  sudo dnf install rpm-build" >&2; \
	    echo "  Debian:       run 'make deb' instead" >&2; \
	    exit 1; \
	}
	@case "$$(rpm $(RPM_DEFINES) --eval '%{perl_vendorlib}' 2>/dev/null)" in \
	    /*) : ;; \
	    *) \
	        echo "rpm: %{perl_vendorlib} does not resolve to a path." >&2; \
	        echo "  The spec installs the modules there, so the build" >&2; \
	        echo "  would fail with a misleading File-must-begin-with-/." >&2; \
	        echo "  Fedora/RHEL:  sudo dnf install perl-macros" >&2; \
	        echo "  Debian:       rpmbuild is here but Fedora's macros are" >&2; \
	        echo "                not; run 'make deb' instead" >&2; \
	        exit 1 ;; \
	esac

srpm: dist rpm-tools
	$(RPMBUILD) $(RPM_DEFINES) $(RPMFLAGS) -ts $(TARBALL)
	@echo "Built:"
	@ls -1 $(RPMTOPDIR)/SRPMS/$(NAME)-$(VERSION)-*.src.rpm 2>/dev/null \
	    | sed 's/^/  /' || true

# The binary packages: all three of them, from the one tarball, exactly as a
# build service would do it.
#
# This needs every BuildRequires the spec names, which rpmbuild checks before
# it starts. `sudo dnf builddep $(PKGDIR)/$(NAME).spec` installs them, and is not run
# from here: a Makefile target that acquires root to install packages is not
# something to have happen because somebody typed `make rpm`. For a quick
# local build without them:
#
#     make rpm RPMFLAGS='--nodeps --nocheck'
#
# which skips the dependency check and the %check section -- and therefore
# skips the test suite, so it proves the packaging and not the program.
rpm: dist rpm-tools
	$(RPMBUILD) $(RPM_DEFINES) $(RPMFLAGS) -tb $(TARBALL)
	@echo "Built:"
	@find $(RPMTOPDIR)/RPMS -name '$(NAME)*-$(VERSION)-*.rpm' \
	    -newer $(TARBALL) -printf '  %p\n' 2>/dev/null || true

# Both, which is what a release actually needs: the source package to hand to
# a build service and the binaries to try before doing so.
rpms: srpm rpm

# ---------------------------------------------------------------------------
# The Debian packages
#
# Built from the tarball, like the RPMs, because debian/ no longer sits at the
# top of this tree -- it is in $(PKGDIR) with the spec, and dpkg-buildpackage
# insists on being run from a directory that has debian/ directly beneath it.
# Unpacking the tarball into $(BUILDDIR) and moving $(PKGDIR)/debian into place
# gives it exactly that.
#
# This is the arrangement the RPM side already had, and it buys the same
# thing: a file `make dist` failed to include is a build failure here rather
# than a package quietly missing something. It also means a build writes
# nothing into the source tree at all -- the staging directories, the
# substvars and the .debhelper logs all land under $(BUILDDIR) and go with
# `make clean`, so there is nothing left for .gitignore to name.
#
# -b for binary only: there is no signed source upload to make here, and the
# three .deb files are what anybody asking for `make deb` wants. They land
# beside the unpacked tree, which is to say in $(BUILDDIR).
#
# DPKGFLAGS is the counterpart of RPMFLAGS, and exists for the same one case:
#
#     make deb DPKGFLAGS=-d
#
# -d skips dpkg-checkbuilddeps, which is what a machine with debhelper
# unpacked somewhere other than / needs -- the tools are on PATH but no
# debhelper-compat is registered with dpkg, so the check refuses a build that
# then works perfectly.
DPKGFLAGS ?=

deb: dist
	@command -v dpkg-buildpackage >/dev/null \
	    || { echo "deb: dpkg-dev is not installed" >&2; exit 1; }
	@command -v dh >/dev/null \
	    || { echo "deb: debhelper is not installed" >&2; exit 1; }
	rm -rf $(BUILDDIR)/$(DIST)
	tar -xzf $(TARBALL) -C $(BUILDDIR)
	mv $(BUILDDIR)/$(DIST)/$(PKGDIR)/debian $(BUILDDIR)/$(DIST)/debian
	cd $(BUILDDIR)/$(DIST) && dpkg-buildpackage -us -uc -b $(DPKGFLAGS)
	@echo
	@echo "Built in $(BUILDDIR):"
	@ls -1 $(BUILDDIR)/$(NAME)*_$(VERSION)-*_all.deb 2>/dev/null || true

uninstall:
	rm -f  $(addprefix $(DESTDIR)$(BINDIR)/,$(SCRIPTS))
	rm -f  $(addprefix $(DESTDIR)$(MANDIR)/man1/,$(MAN1))
	rm -rf $(DESTDIR)$(DATADIR)
	rm -rf $(DESTDIR)$(PERLDIR)/GlitchVape $(DESTDIR)$(PERLDIR)/GlitchVape.pm
	rm -f  $(DESTDIR)$(APPDIR)/$(NAME).desktop
	rm -f  $(DESTDIR)$(METAINFODIR)/$(NAME).metainfo.xml
	rm -f  $(DESTDIR)$(ICONDIR)/256x256/apps/$(NAME).png

# $(BUILDDIR) goes whole: the tarball, the unpacked trees both packagings
# build in, the .deb files and the rpmbuild tree are all inside it, so there
# is one thing to remove rather than a list to keep in step with the targets
# that create them.
clean:
	rm -f $(MAN1)
	find . -name '*.bak' -o -name '*.tdy' -o -name '*.ERR' -o -name '*.LOG' \
	    | xargs -r rm -f
	rm -rf .prove $(BUILDDIR)
