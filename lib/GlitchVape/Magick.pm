package GlitchVape::Magick;

use strict;
use warnings;

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Magick - error handling for PerlMagick calls

=head1 DESCRIPTION

PerlMagick does not throw. Every method returns a string, empty on success and
otherwise of the form:

    Exception 410: unable to open image `/tmp/x.png'

The number matters. Codes below 400 are B<warnings> and are routine in this
program -- a JPEG carrying a malformed EXIF block, a PNG whose embedded colour
profile disagrees with its colour type, a deliberately corrupted file being
decoded by C<databend>. Treating those as failures would abort renders that
were working correctly. Codes of 400 and above are real errors.

Getting that distinction right at fourteen separate call sites, by hand, is how
a program ends up either dying on harmless warnings or silently continuing past
a genuine failure. Hence one helper.

=cut

# ImageMagick's own severity scale: anything at or above ErrorException is
# fatal, everything below it is a warning.
use constant ERROR_THRESHOLD => 400;

=head2 check( $err, $context )

Dies if C<$err> reports a genuine ImageMagick error, naming C<$context>.
Returns true otherwise, so it can be used as a statement or a guard:

    GlitchVape::Magick::check( $img->Read($path), "cannot read $path" );

A non-empty return that is not an C<Exception> string at all is treated as
success, matching PerlMagick's habit of returning assorted status text.

=cut

sub check
{
    my ( $err, $context ) = @_;

    # PerlMagick hands back either an empty string, a plain string, or an
    # object that stringifies. Force it to a string once, up front, so the
    # rest of this only has to deal with one shape.
    my $text = q{};
    if ( defined $err )
    {
        $text = "$err";
    }

    # An empty result is PerlMagick's way of saying the call succeeded.
    if ( !length $text )
    {
        return 1;
    }

    my ( $code ) = $text =~ /^Exception \s+ (\d+)/x;

    # Text that is not an exception report at all is not a failure; PerlMagick
    # returns assorted status strings that mean nothing is wrong.
    if ( !defined $code )
    {
        return 1;
    }

    # Below the threshold this is a warning, which is routine here.
    if ( $code < ERROR_THRESHOLD )
    {
        return 1;
    }

    if ( !defined $context || !length $context )
    {
        $context = 'ImageMagick call failed';
    }

    die "GlitchVape: $context: $text\n";
}

=head2 is_error( $err )

The same test without dying, for callers that want to recover rather than
abort -- C<databend> retries with fresh corruption instead of failing.

=cut

sub is_error
{
    my ( $err ) = @_;

    # Same normalisation as check(): stringify once, then decide.
    my $text = q{};
    if ( defined $err )
    {
        $text = "$err";
    }

    if ( !length $text )
    {
        return 0;
    }

    my ( $code ) = $text =~ /^Exception \s+ (\d+)/x;

    if ( !defined $code )
    {
        return 0;
    }

    if ( $code < ERROR_THRESHOLD )
    {
        return 0;
    }

    return 1;
}

1;
