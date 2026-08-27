#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Basename ();
use File::Find     ();
use File::Spec     ();
use Test::More;

# Every $self->_helper a module calls is a sub that module defines.
#
# This is the one class of mistake the suite could not see. A private helper
# is reached through a method call, so perl resolves it at run time and the
# file compiles perfectly without it; the failure surfaces only when that
# particular button is pressed. Worse, in the window it does not surface at
# all -- Glib catches exceptions thrown inside a signal handler, prints them
# to the terminal and carries on, so a dead helper reads as a control that
# quietly does nothing.
#
# _touch went missing exactly this way: a refactor reused its block for
# another sub, and eight call sites were left pointing at nothing while the
# whole suite stayed green.
#
# Source is scanned rather than the modules loaded, so this covers the GUI on
# a machine with no display and no Gtk3 -- which is where it is needed most,
# the GUI being both the largest package and the one whose errors get eaten.

my $lib = File::Spec->catdir( $FindBin::Bin, File::Spec->updir, 'lib' );

my @modules;
File::Find::find(
    {
        no_chdir => 1,
        wanted   => sub { push @modules, $File::Find::name if /\.pm\z/ },
    },
    $lib
);

@modules = sort @modules;
ok( scalar @modules, 'there are modules to check' );

# Holds only while every file is one package: a helper defined in file A
# cannot then satisfy a call in file B, so a missing definition is a real
# missing definition rather than a cross-file lookup this test cannot see.
for my $path ( @modules )
{
    open my $fh, '<', $path or die "cannot read $path: $!\n";
    my $src = do { local $/; <$fh> };
    close $fh;

    my $packages = () = $src =~ /^package\s/gm;
    is $packages, 1, "$path declares exactly one package";
}

for my $path ( @modules )
{
    open my $fh, '<', $path or die "cannot read $path: $!\n";
    my $src = do { local $/; <$fh> };
    close $fh;

    my %defined = map { $_ => 1 } $src =~ /^sub \s+ (\w+)/gmx;

    # Only literal names: $self->$direction in _step_history is a method
    # chosen at run time, and there is nothing here that could check it.
    # The while is the conditional -- the body runs only on a match -- but the
    # policy only recognises an if or a block form, not a statement modifier.
    my %called;
    ## no critic (RegularExpressions::ProhibitCaptureWithoutTest)
    $called{ $1 }++ while $src =~ /\$self \s* -> \s* (_\w+)/gx;
    ## use critic

    my @missing = sort grep { !$defined{ $_ } } keys %called;

    my $name = File::Basename::basename( $path );
    is_deeply \@missing, [], "$name calls no private method it does not define"
        or diag "no sub for: @missing";
}

done_testing;
