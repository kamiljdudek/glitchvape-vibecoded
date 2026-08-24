# GlitchVape has nothing to compile: it is Perl and data files. This exists so
# that `make install DESTDIR=...` is one command with one definition of where
# everything goes, rather than that knowledge living in a spec file where only
# rpmbuild can exercise it.

NAME       = glitchvape
VERSION    = 0.01

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

# ---------------------------------------------------------------------------
# Which fonts are ours to hand on
#
# A font ships if its licence ships with it, and the way that is decided is
# structural rather than a list to keep up to date: a release unpacked whole
# into assets/fonts/ brings its LICENSE along, and those directories ship.
# A file dropped loose into assets/fonts/ brings nothing with it, and does
# not ship -- which today is exactly VCR OSD Mono and W95FA, free to use but
# not yet established as free to redistribute inside somebody else's package.
#
# The consequence is that adding a font to the distribution is unpacking a
# release, and there is no way to add one that quietly leaves its licence
# behind. `make check-licenses` states what the rule concluded.
FONT_LICENCE_GLOB = LICENSE* LICENCE* COPYING* OFL*
FONT_LICENCES = $(wildcard $(foreach g,$(FONT_LICENCE_GLOB),assets/fonts/*/$(g)))
FONT_DIRS     = $(sort $(patsubst %/,%,$(dir $(FONT_LICENCES))))
FONT_FILES    = $(if $(FONT_DIRS),$(shell find $(FONT_DIRS) -type f))

SCRIPTS   = glitchvape glitchvape-batch glitchvape-gui

# Split so that the packaging can put the window in its own subpackage.
# GUI.pm sits beside GUI/ rather than inside it, so it has to be named
# separately -- and it is the file that pulls in Gtk3, which is the whole
# point of the split. `make check-split` proves the division is honest.
GUI_MODULES = lib/GlitchVape/GUI.pm $(shell find lib/GlitchVape/GUI -name '*.pm')
CLI_MODULES = $(filter-out $(GUI_MODULES), $(shell find lib -name '*.pm'))

.PHONY: all test check check-split check-licenses tidy critic dist srpm \
        install install-cli install-fonts install-gui uninstall clean

all:
	@echo "$(NAME) $(VERSION) -- nothing to build."
	@echo "make test      run the test suite"
	@echo "make install   PREFIX=$(PREFIX)"

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
	        echo "  ship  $$d  ($$found)"; \
	    fi; \
	done; \
	for f in $$(find assets/fonts -maxdepth 1 -type f 2>/dev/null); do \
	    echo "  hold  $$f  (nothing beside it says it may be redistributed)"; \
	done; \
	[ $$fail -eq 0 ] || exit 1; \
	echo "check-licenses: $(words $(FONT_FILES)) files from \
$(words $(FONT_DIRS)) font releases, each with its licence"

tidy:
	perltidy -b -bext='/' $(CLI_MODULES) $(GUI_MODULES) $(addprefix bin/,$(SCRIPTS))

critic:
	perlcritic lib/ bin/ t/

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

	$(INSTALL_DATA) $(NAME).desktop $(DESTDIR)$(APPDIR)/$(NAME).desktop
	$(INSTALL_DATA) $(NAME).metainfo.xml \
	    $(DESTDIR)$(METAINFODIR)/$(NAME).metainfo.xml

# The logo is 215x185; an icon theme directory means a square of that size.
# The padded copy is kept in the tree rather than generated here, so that
# installing needs no image tooling at all -- see assets/artwork/icon-256.png.
	$(INSTALL_DATA) assets/artwork/icon-256.png \
	    $(DESTDIR)$(ICONDIR)/256x256/apps/$(NAME).png

# ---------------------------------------------------------------------------

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
# directories are exactly $(FONT_DIRS) -- the releases that brought a licence
# with them. A font sitting loose in assets/fonts/ is a font somebody fetched
# for their own machine and is not in the tarball, which is the same rule
# .gitignore applies and the one check-licenses states.
DIST = $(NAME)-$(VERSION)

dist: check-licenses
	rm -rf $(DIST) $(DIST).tar.gz
	mkdir -p $(DIST)
	tar -cf - \
	    --exclude='*.bak' --exclude='*.tdy' \
	    --exclude='*.ERR' --exclude='*.LOG' \
	    bin lib presets t Makefile README.md LICENSE \
	    assets/artwork assets/luts $(FONT_DIRS) \
	    $(NAME).spec $(NAME).desktop $(NAME).metainfo.xml \
	    .perlcriticrc .perltidyrc \
	  | tar -xf - -C $(DIST)
	tar -czf $(DIST).tar.gz $(DIST)
	rm -rf $(DIST)
	@echo "$(DIST).tar.gz"

srpm: dist
	rpmbuild -ts $(DIST).tar.gz

uninstall:
	rm -f  $(addprefix $(DESTDIR)$(BINDIR)/,$(SCRIPTS))
	rm -rf $(DESTDIR)$(DATADIR)
	rm -rf $(DESTDIR)$(PERLDIR)/GlitchVape $(DESTDIR)$(PERLDIR)/GlitchVape.pm
	rm -f  $(DESTDIR)$(APPDIR)/$(NAME).desktop
	rm -f  $(DESTDIR)$(METAINFODIR)/$(NAME).metainfo.xml
	rm -f  $(DESTDIR)$(ICONDIR)/256x256/apps/$(NAME).png

clean:
	find . -name '*.bak' -o -name '*.tdy' -o -name '*.ERR' -o -name '*.LOG' \
	    | xargs -r rm -f
	rm -rf .prove $(DIST) $(DIST).tar.gz
