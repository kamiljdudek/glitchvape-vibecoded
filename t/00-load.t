#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;

my @modules = qw(
    GlitchVape
    GlitchVape::Animate
    GlitchVape::Assets
    GlitchVape::Audio
    GlitchVape::Config
    GlitchVape::Context
    GlitchVape::DTMF
    GlitchVape::Effect::Color
    GlitchVape::Effect::Glitch
    GlitchVape::Effect::Overlay
    GlitchVape::Effect::Screen
    GlitchVape::Effect::Signal
    GlitchVape::Effect::Texture
    GlitchVape::Fonts
    GlitchVape::Generator
    GlitchVape::IO
    GlitchVape::Licenses
    GlitchVape::Magick
    GlitchVape::Noise
    GlitchVape::Palette
    GlitchVape::Paths
    GlitchVape::Pipeline
    GlitchVape::Pixels
    GlitchVape::Random
    GlitchVape::Raster
    GlitchVape::Registry
    GlitchVape::Tools
    GlitchVape::VGA
    GlitchVape::Wav
);

require_ok( $_ ) for @modules;

# Loading the effect modules must populate the registry; if a registration
# block ever stops running, every preset silently becomes a no-op.
require GlitchVape;
my @names = GlitchVape::Registry->names;
cmp_ok scalar @names, '>=', 30, 'registry has the full effect set';

my %stage =
    map { $_ => 1 } map { GlitchVape::Registry->get( $_ )->{ stage } } @names;
ok $stage{ $_ }, "stage '$_' has at least one effect"
    for GlitchVape::Registry->stages;

done_testing;
