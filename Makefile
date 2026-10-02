# GlitchVape is Perl and data files, and one small library: film grain's
# arithmetic in C, which the Perl beside it can always stand in for (see "The
# compiled grain" below). This exists so that `make install DESTDIR=...` is
# one command with one definition of where everything goes and what is
# compiled how, rather than that knowledge living in a spec file where only
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

# Where the compiled grain goes. Beside the modules by default, which is where
# perl looks first; the distributions keep architecture-dependent modules in a
# directory of their own -- perl's vendorarch -- and pass it here. Wherever it
# is, it has to be on @INC: that is how GlitchVape::Grain finds it installed.
PERLARCHDIR ?= $(PERLDIR)

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

.PHONY: all xs test check check-split check-licenses tidy critic dist deb \
        srpm rpm rpms man install install-cli install-fonts \
        install-fonts-extra install-gui uninstall clean

all: xs
	@echo "$(NAME) $(VERSION)"
	@echo "make test      run the test suite"
	@echo "make install   PREFIX=$(PREFIX)"
	@echo "make deb       build the Debian packages"
	@echo "make rpm       build the RPM packages (make rpms for the srpm too)"

# With the machine's plug-ins switched off: one installed here has no business
# failing the program's own tests, and t/48-plugins.t loads the fixtures it
# means to by name. See GlitchVape::Plugins.
#
# After the compiled grain is built, so that the suite runs what will ship --
# and t/56-grain-c.t holds it to the Perl. GLITCHVAPE_PURE_PERL=1 runs the
# whole suite on the Perl alone.
test check: xs
	GLITCHVAPE_PLUGINS=none $(PROVE) -Ilib -r t/

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
# The compiled grain
#
# The one thing here that is compiled: the arithmetic of `grain`, the one loop
# that does Perl arithmetic on every pixel of a full-size picture. It is a
# speed-up and never a requirement. GlitchVape::Grain keeps the Perl it
# replaces as the reference and the fallback, gives the same bytes either way,
# and uses the Perl wherever this was not built -- any architecture but x86-64
# -- or the CPU predates what it was built for.
#
# Two objects in one library, compiled two different ways:
#
#   xs/Grain.xs  the glue, compiled the way perl compiles an extension: its
#                own ccflags, for the baseline every x86-64 machine runs,
#                because this is the code that asks the CPU what it can do.
#   xs/grain.c   the kernel, C23 for x86-64-v3 (AVX2, BMI2, FMA), reached
#                only once the glue has had a yes.
#
# Into $(BUILDDIR)/xs, laid out the way perl looks for a library, which is
# where GlitchVape::Grain loads it from in a checkout.

# GCC by name, because the kernel is written for it: GCC's attributes and
# builtins, and C23 at GCC 14 or later. A CC given on the command line or in
# the environment still wins.
ifeq ($(origin CC),default)
CC = gcc
endif

# Asked of the compiler rather than of uname, so that a cross build asks about
# the machine it builds for -- and of uname when there is no compiler, so that
# an x86-64 machine without one fails loudly instead of quietly building the
# Perl-only program.
XS_TARGET := $(shell $(CC) -dumpmachine 2>/dev/null || uname -m)

XS_DIR = $(BUILDDIR)/xs
XS_SO  = $(XS_DIR)/auto/GlitchVape/Grain/Grain.so

# What perl was built with, which the glue has to match: the defines change
# the layout of perl's own structures, so they are not a matter of taste.
PERL_CONFIG = $(shell $(PERL) -MConfig -e 'print $$Config{$(1)}')

# The distribution's flags when it passes them (dpkg-buildflags, Fedora's
# %set_build_flags), and perl's own optimisation when it does not -- which is
# also how debhelper builds every other perl extension. The kernel takes the
# distribution's flags too, for their hardening and their debug information,
# with its own after them, so that where the two disagree -- -O2 against -O3,
# -march=x86-64 against x86-64-v3, -flto against -fno-lto -- the kernel's win.
XS_OPTIMIZE = $(or $(CFLAGS),$(call PERL_CONFIG,optimize))

XS_GLUE_FLAGS = $(call PERL_CONFIG,ccflags) $(XS_OPTIMIZE) $(CPPFLAGS) \
    -std=c23 $(call PERL_CONFIG,cccdlflags) \
    -I$(call PERL_CONFIG,archlibexp)/CORE -Ixs \
    -DVERSION=\"$(VERSION)\" -DXS_VERSION=\"$(VERSION)\"

# The kernel's own, each for a reason:
#
#   -std=c23                   what it is written in.
#   -O3                        half a percent over -O2, measured.
#   -march=x86-64-v3           AVX2, BMI2, FMA and MOVBE, and nothing newer:
#                              the floor GlitchVape::Grain asks the CPU for.
#                              Not -march=native, because a package runs on
#                              machines other than the one that built it, and
#                              the tuning stays generic: -mtune=native bought
#                              nothing measurable. AVX-512 is deliberately
#                              not used; GFNI is, where the CPU has it, by an
#                              attribute on the two functions that need it.
#   -ffp-contract=off          the bytes depend on it. Without it GCC fuses a
#                              multiply and an add into one FMA -- vector
#                              intrinsics included -- which rounds once where
#                              Perl rounds twice.
#   -fno-math-errno            change no value: sqrt becomes one instruction
#   -fno-trapping-math         instead of a call that might set errno.
#   -funroll-loops             about one percent.
#   -fno-plt                   calls to log through the GOT rather than a
#                              stub: about one and a half percent, since
#                              there are a million of them at 720 pixels.
#   -fvisibility=hidden        nothing in the kernel is for anyone outside
#                              the library.
#   -fno-lto                   nothing crosses into the kernel per pixel, so
#                              LTO has nothing to inline -- and the code this
#                              command compiles is then the code that ships,
#                              not code recompiled at link time under the
#                              link's options, which are the glue's.
#
# What is not here is mostly what would change a value: -ffast-math and
# everything in it, and a vector log, which rounds unlike the scalar one Perl
# calls -- the link below refuses a library that calls one. -fipa-pta and
# -fno-semantic-interposition were measured and bought nothing.
GRAIN_CFLAGS = -std=c23 -O3 -march=x86-64-v3 -ffp-contract=off \
    -fno-math-errno -fno-trapping-math -funroll-loops -fno-plt \
    -fvisibility=hidden -fno-lto -Wall -Wextra -Wpedantic

# make xs PGO=1: profile-guided, by compiling the kernel instrumented, running
# xs/train.c over it, and compiling it again from what that recorded. Opt-in,
# because it buys one or two percent and costs reproducibility: the profile
# records which way the training machine's CPU stepped the generator, so two
# builds of the same source on different machines differ. The profile sits
# beside the object, which is how GCC finds it again: both compiles name the
# same object.
PGO ?=

ifneq ($(findstring x86_64,$(XS_TARGET)),)

xs: $(XS_SO)

# A recipe that fails leaves no target behind. Without this, a PGO build that
# failed after its first compile would leave the instrumented kernel in place,
# looking up to date, for the next build to link into the library.
.DELETE_ON_ERROR:

# What the library was last built with, rewritten only when that changes, so
# that a different PGO, CFLAGS or compiler rebuilds everything -- timestamps
# alone would keep an object built the other way and call it current.
XS_RECORD = $(CC) $(XS_GLUE_FLAGS) $(KERNEL) $(LDFLAGS) PGO=$(PGO)

$(XS_DIR)/flags: FORCE
	@mkdir -p $(@D)
	@echo '$(XS_RECORD)' > $@.new
	@if cmp -s $@.new $@; then rm $@.new; else mv $@.new $@; fi

.PHONY: FORCE
FORCE:

$(XS_DIR)/Grain.c: xs/Grain.xs $(XS_DIR)/flags
	@mkdir -p $(@D)
	$(PERL) -MExtUtils::ParseXS -e \
	    'ExtUtils::ParseXS->new->process_file(filename => $$ARGV[0], prototypes => 0)' \
	    $< > $@.tmp
	mv $@.tmp $@

$(XS_DIR)/Grain.o: $(XS_DIR)/Grain.c xs/grain.h $(XS_DIR)/gcc-ok $(XS_DIR)/flags
	$(CC) -c $(XS_GLUE_FLAGS) -o $@ $<

# C23 is GCC 14's: before that -std=c23 is not even a flag, and the error
# would say so less plainly than this.
$(XS_DIR)/gcc-ok:
	@mkdir -p $(@D)
	@v=$$($(CC) -dumpversion 2>/dev/null | cut -d. -f1); \
	    if [ -z "$$v" ]; then \
	        echo "xs: $(CC) is not installed, and the grain is compiled" \
	            "on $(XS_TARGET)" >&2; exit 1; \
	    elif [ "$$v" -lt 14 ]; then \
	        echo "xs: xs/grain.c is C23 and needs GCC 14 or later;" \
	            "$(CC) is $$v" >&2; exit 1; \
	    fi
	@touch $@

KERNEL = $(CC) -c $(CPPFLAGS) $(CFLAGS) $(GRAIN_CFLAGS) \
    $(call PERL_CONFIG,cccdlflags) -o $(XS_DIR)/grain.o xs/grain.c

ifeq ($(PGO),1)
# The training run has to execute the kernel, so the machine building it has
# to be one the kernel runs on; train says so if it is not.
$(XS_DIR)/grain.o: xs/grain.c xs/grain.h xs/train.c $(XS_DIR)/gcc-ok \
        $(XS_DIR)/flags
	rm -f $(XS_DIR)/grain.gcda
	$(KERNEL) -fprofile-generate -fprofile-update=single
	$(CC) -c $(CPPFLAGS) $(CFLAGS) -std=c23 -O2 -Ixs -o $(XS_DIR)/train.o \
	    xs/train.c
	$(CC) $(LDFLAGS) -fprofile-generate -o $(XS_DIR)/train \
	    $(XS_DIR)/train.o $(XS_DIR)/grain.o -lm
	$(XS_DIR)/train
	$(KERNEL) -fprofile-use -fprofile-partial-training
else
$(XS_DIR)/grain.o: xs/grain.c xs/grain.h $(XS_DIR)/gcc-ok $(XS_DIR)/flags
	$(KERNEL)
endif

# glibc's vector maths -- _ZGV* -- would round differently from the scalar
# log Perl calls, and t/56-grain-c.t might not catch one bit in the last
# place of a gaussian that a byte then truncates. So a library that calls it
# is not one to ship.
$(XS_SO): $(XS_DIR)/Grain.o $(XS_DIR)/grain.o
	@mkdir -p $(@D)
	$(CC) $(call PERL_CONFIG,lddlflags) $(LDFLAGS) -o $@.tmp $^ -lm
	@if nm -D --undefined-only $@.tmp | grep -q '_ZGV'; then \
	    echo "xs: the grain calls glibc's vector maths, which rounds" \
	        "unlike Perl" >&2; rm -f $@.tmp; exit 1; \
	fi
	mv $@.tmp $@

else

xs:
	@echo "xs: the grain is compiled only for x86-64; $(or $(XS_TARGET),this machine)" \
	    "keeps to the Perl"

endif

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

install-cli: xs
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

# The compiled grain, where this machine builds one: under auto/, as perl
# lays its extensions out, and executable as perl installs them -- which is
# also what the packagings' strip and debug-information steps look for.
ifneq ($(findstring x86_64,$(XS_TARGET)),)
	$(INSTALL_DIR) $(DESTDIR)$(PERLARCHDIR)/auto/GlitchVape/Grain
	$(INSTALL_PROGRAM) $(XS_SO) $(DESTDIR)$(PERLARCHDIR)/auto/GlitchVape/Grain/
endif

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
#
# Unless PERLDIR is not on @INC, which is what the default is: nothing on
# Debian or Fedora searches /usr/local/share/perl5, so a plain `make install`
# used to put the modules somewhere perl never looks and leave scripts that
# died with "Can't locate GlitchVape.pm". Then the line is not removed but
# replaced, with one naming PERLDIR -- the same fact baked in at install time
# that GlitchVape::Paths::DATADIR is. The packagings pass their vendor
# directory, which is on @INC, and get no line at all, as before.
#
# FindBin itself is a separate question, and conflating the two broke every
# install of the window: glitchvape-gui asks FindBin where it is so that Open
# can start a second instance of *this* program, which is a fact it needs
# whether it was installed or not. So the `use FindBin ()` beside the line
# goes only when nothing else in the script names the package -- and both
# halves are asserted, because a script left using FindBin without loading it
# does not fail to compile. $FindBin::RealBin is simply undef, and the program
# spawns /RealScript out of the root directory.
.PHONY: fix-inc
fix-inc:
	set -e; \
	onpath=$$($(PERL) -e '($$d = shift) =~ s{/+\z}{}; \
	    print scalar grep { !ref && $$_ eq $$d } @INC' '$(PERLDIR)'); \
	for s in $(SCRIPT_LIST); do \
	    f=$(DESTDIR)$(BINDIR)/$$s; \
	    if [ "$$onpath" = 0 ]; then \
	        $(PERL) -i -pe 's{^use lib "\$$FindBin::Bin/\.\./lib";$$}{use lib \x27$(PERLDIR)\x27;}' $$f; \
	        want=1; \
	    else \
	        sed -i -e '\|^use lib "\$$FindBin::Bin/\.\./lib";$$|d' $$f; \
	        want=0; \
	    fi; \
	    grep -q 'FindBin::' $$f || sed -i -e '/^use FindBin ();$$/d' $$f; \
	    [ "$$(grep -c '^use lib ' $$f || true)" = "$$want" ] \
	        || { echo "install: $$s adds the wrong lib directories" >&2; \
	             exit 1; }; \
	    [ "$$want" = 0 ] || grep -qxF "use lib '$(PERLDIR)';" $$f \
	        || { echo "install: $$s does not name $(PERLDIR)" >&2; \
	             exit 1; }; \
	    ! grep -q 'FindBin::' $$f || grep -q '^use FindBin ();' $$f \
	        || { echo "install: $$s uses FindBin but no longer loads it" >&2; \
	             exit 1; }; \
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
	    bin lib presets t xs Makefile README.md docs LICENSE $(PKGDIR) \
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
	@ls -1 $(BUILDDIR)/$(NAME)*_$(VERSION)-*.deb 2>/dev/null || true

uninstall:
	rm -f  $(addprefix $(DESTDIR)$(BINDIR)/,$(SCRIPTS))
	rm -f  $(addprefix $(DESTDIR)$(MANDIR)/man1/,$(MAN1))
	rm -rf $(DESTDIR)$(DATADIR)
	rm -rf $(DESTDIR)$(PERLDIR)/GlitchVape $(DESTDIR)$(PERLDIR)/GlitchVape.pm
	rm -rf $(DESTDIR)$(PERLARCHDIR)/auto/GlitchVape
	rm -f  $(DESTDIR)$(APPDIR)/$(NAME).desktop
	rm -f  $(DESTDIR)$(METAINFODIR)/$(NAME).metainfo.xml
	rm -f  $(DESTDIR)$(ICONDIR)/256x256/apps/$(NAME).png

# $(BUILDDIR) goes whole: the compiled grain, the tarball, the unpacked trees
# both packagings build in, the .deb files and the rpmbuild tree are all
# inside it, so there is one thing to remove rather than a list to keep in
# step with the targets that create them.
clean:
	rm -f $(MAN1)
	find . -name '*.bak' -o -name '*.tdy' -o -name '*.ERR' -o -name '*.LOG' \
	    | xargs -r rm -f
	rm -rf .prove $(BUILDDIR)
