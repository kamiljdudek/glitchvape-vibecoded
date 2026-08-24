#!/usr/bin/perl

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use GlitchVape::Magick;

# The whole point of this module is the warning/error split. Getting it wrong
# in either direction is silent: too strict and ordinary renders abort on a
# harmless EXIF warning, too lax and a genuine failure is carried forward as if
# it had worked.

{
    ok GlitchVape::Magick::check( '', 'nothing wrong' ), 'empty error passes';
    ok GlitchVape::Magick::check( undef, 'nothing wrong' ),
        'undef error passes';
}

{
    ok GlitchVape::Magick::check( 'Exception 315: unknown field', 'reading' ),
        'a warning below the threshold passes';

    ok GlitchVape::Magick::check( 'Exception 399: borderline', 'reading' ),
        'the value just below the threshold passes';
}

{
    my $err = do
    {
        local $@;
        eval {
            GlitchVape::Magick::check( 'Exception 410: unable to open',
                'reading x.png' );
        };
        $@;
    };
    like $err, qr/reading x\.png/, 'a real error names the context';
    like $err, qr/Exception 410/,  'a real error includes ImageMagick\'s text';

    $err = do
    {
        local $@;
        eval {
            GlitchVape::Magick::check( 'Exception 400: at the threshold',
                'reading' );
        };
        $@;
    };
    ok $err, 'the threshold value itself is an error';
}

# PerlMagick returns assorted status text that is not an exception at all;
# treating those as failures would abort working renders.
{
    ok GlitchVape::Magick::check( 'some other status text', 'doing a thing' ),
        'non-exception text is not treated as an error';
}

{
    is GlitchVape::Magick::is_error( '' ),    0, 'is_error: empty';
    is GlitchVape::Magick::is_error( undef ), 0, 'is_error: undef';
    is GlitchVape::Magick::is_error( 'Exception 315: warning' ), 0,
        'is_error: warning';
    is GlitchVape::Magick::is_error( 'Exception 410: bad' ), 1,
        'is_error: error';
    is GlitchVape::Magick::is_error( 'unrelated text' ), 0,
        'is_error: non-exception';
}

# The check must survive being handed a PerlMagick error object rather than a
# plain string, which is what the real call sites pass.
{

    package GlitchVape::Test::FakeError;
    use overload '""' => sub { $_[ 0 ]{ text } }, fallback => 1;
    sub new { bless { text => $_[ 1 ] }, $_[ 0 ] }
}

{
    my $warning = GlitchVape::Test::FakeError->new( 'Exception 315: minor' );
    ok GlitchVape::Magick::check( $warning, 'reading' ),
        'an overloaded warning object passes';

    my $fatal = GlitchVape::Test::FakeError->new( 'Exception 425: fatal' );
    my $err   = do
    {
        local $@;
        eval { GlitchVape::Magick::check( $fatal, 'reading' ) };
        $@;
    };
    like $err, qr/Exception 425/, 'an overloaded error object is caught';
}

done_testing;
