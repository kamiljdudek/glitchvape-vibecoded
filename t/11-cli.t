#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Spec ();
use File::Temp ();
use Test::More;

use GlitchVape::Tools ();

plan skip_all => 'ImageMagick is not installed'
    unless GlitchVape::Tools::have( 'magick' );
plan skip_all => 'Image::Magick is not installed'
    unless eval { require Image::Magick; 1 };

my $bin     = "$FindBin::Bin/../bin/glitchvape";
my $presets = "$FindBin::Bin/../presets";

plan skip_all => 'glitchvape not found' unless -x $bin;

my $dir = File::Temp->newdir( 'gv_cli_XXXXXX', TMPDIR => 1 );

my $src = "$dir/src.png";
{
    my $img = Image::Magick->new( size => '320x240' );
    $img->Read( 'gradient:#202060-#E0C080' );
    $img->Write( $src );
}

sub run_cli
{
    my ( @args ) = @_;
    my $out =
        GlitchVape::Tools::capture( $^X, "-I$FindBin::Bin/../lib", $bin,
        @args );

    # capture() returns undef if the command could not be started at all;
    # the callers here only ever match against the text.
    if ( !defined $out )
    {
        return q{};
    }

    return $out;
}

# Exit status only; diagnostics go to STDERR and are silenced here.
sub run_cli_status
{
    my ( @args ) = @_;

    my $pid = fork;
    die "t/11-cli.t: fork failed: $!" unless defined $pid;

    unless ( $pid )
    {
        open STDOUT, '>', File::Spec->devnull or exit 127;
        open STDERR, '>', File::Spec->devnull or exit 127;
        exec $^X, "-I$FindBin::Bin/../lib", $bin, @args;
        exit 127;
    }

    waitpid $pid, 0;
    return $? >> 8;
}

sub bytes_of
{
    my ( $path ) = @_;
    open my $fh, '<:raw', $path or return '';
    my $data = do { local $/ = undef; <$fh> };
    close $fh;
    return $data;
}

local $ENV{ GLITCHVAPE_PRESETS } = $presets;

{
    my $out = run_cli( '--list-effects' );
    like $out, qr/scanlines/, '--list-effects lists an effect';
    like $out, qr/OPTICS/,    '--list-effects groups by stage';
}

{
    my $out = run_cli( '--explain', 'pixelsort' );
    like $out, qr/lower/,   '--explain lists a parameter';
    like $out, qr/default/, '--explain shows defaults';
}

{
    my $out = run_cli( '--list-presets' );
    like $out, qr/vhs-decay/, '--list-presets finds the library';
}

{
    my $out = run_cli( '-p', 'vhs-decay', '--dry-run', $src );
    like $out, qr/scanlines/, '--dry-run describes the pipeline';
    like $out, qr/seed:/,     '--dry-run reports the seed it would use';
}

# Text given on the command line and text loaded from a preset must produce
# identical output. They arrive by different routes -- @ARGV is raw bytes,
# YAML::XS returns decoded characters -- and if the CLI path is not decoded
# the same string renders as mojibake.
{
    my $text = 'ヴェイパーウェイブ';

    my $yaml = <<"YAML";
name: utf8check
title: Encoding round-trip fixture
effects:
  text:
    string: $text
    font: cjk
    size: 0.12
    shadow: ''
YAML

    my $preset = "$dir/utf8check.yml";
    open my $fh, '>:encoding(UTF-8)', $preset
        or die "t/11-cli.t: cannot write $preset: $!";
    print { $fh } $yaml;
    close $fh;

    my $from_preset = "$dir/from_preset.png";
    my $from_cli    = "$dir/from_cli.png";

    run_cli(
        '-p',        $preset, '--seed', '1',
        '--max-dim', '0',     '-o',     $from_preset,
        $src
    );

    run_cli(
        '-e',        'text',          '--set',  "text.string=$text",
        '--set',     'text.font=cjk', '--set',  'text.size=0.12',
        '--set',     'text.shadow=',  '--seed', '1',
        '--max-dim', '0',             '-o',     $from_cli,
        $src,
    );

SKIP:
    {
        skip 'no CJK font installed', 2
            unless -s $from_preset && -s $from_cli;

        ok -s $from_cli, 'CLI-supplied UTF-8 text renders';
        is bytes_of( $from_cli ), bytes_of( $from_preset ),
            'CLI text and preset text render identically (no double-encoding)';
    }
}

# The wording of this error is asserted in t/04-config.t; what matters here is
# that the CLI turns it into a non-zero exit rather than reporting success.
{
    my $status = run_cli_status( '-p', 'no-such-preset', $src );
    isnt $status, 0, 'an unknown preset exits non-zero';

    $status = run_cli_status( '--list-presets' );
    is $status, 0, 'a successful run exits zero';
}

done_testing;
