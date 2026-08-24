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

SCRIPTS   = glitchvape glitchvape-batch glitchvape-gui

# Split so that the packaging can put the window in its own subpackage.
# GUI.pm sits beside GUI/ rather than inside it, so it has to be named
# separately -- and it is the file that pulls in Gtk3, which is the whole
# point of the split. `make check-split` proves the division is honest.
GUI_MODULES = lib/GlitchVape/GUI.pm $(shell find lib/GlitchVape/GUI -name '*.pm')
CLI_MODULES = $(filter-out $(GUI_MODULES), $(shell find lib -name '*.pm'))

.PHONY: all test check check-split tidy critic dist srpm install install-cli \
        install-gui uninstall clean

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

tidy:
	perltidy -b -bext='/' $(CLI_MODULES) $(GUI_MODULES) $(addprefix bin/,$(SCRIPTS))

critic:
	perlcritic lib/ bin/ t/

install: install-cli install-gui

# ---------------------------------------------------------------------------
# The command line, the library and the data

install-cli:
	$(INSTALL_DIR) $(DESTDIR)$(BINDIR)
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/presets
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/assets/artwork
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/assets/luts
	$(INSTALL_DIR) $(DESTDIR)$(DATADIR)/assets/fonts

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

	for s in glitchvape glitchvape-batch; do \
	    $(INSTALL_PROGRAM) bin/$$s $(DESTDIR)$(BINDIR)/$$s; \
	done
	$(MAKE) fix-inc SCRIPT_LIST="glitchvape glitchvape-batch"

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
# needs and nothing it does not: assets/fonts/ is excluded because the fonts
# are not this project's to redistribute, and the code falls through to
# fontconfig without them.
DIST = $(NAME)-$(VERSION)

dist:
	rm -rf $(DIST) $(DIST).tar.gz
	mkdir -p $(DIST)
	tar -cf - \
	    --exclude=assets/fonts --exclude='*.bak' --exclude='*.tdy' \
	    --exclude='*.ERR' --exclude='*.LOG' \
	    bin lib presets assets t Makefile README.md \
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
