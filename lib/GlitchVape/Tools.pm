package GlitchVape::Tools;

use strict;
use warnings;

use File::Spec  ();
use File::Which ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Tools - external binary discovery and capability probing

=head1 DESCRIPTION

Effects degrade rather than die when an optional tool is missing: without
C<pngquant> the quantiser falls back to ImageMagick's, without C<ffmpeg> the
animated writers are unavailable but stills still render. This module is the
single place that knows what is actually installed.

=cut

my %CACHE;

# name => [ candidate binaries in preference order ], with a note used in
# diagnostics when nothing is found.
my %TOOL = (
    magick   => { bins => [ 'magick', 'convert' ],  pkg => 'imagemagick' },
    identify => { bins => [ 'magick', 'identify' ], pkg => 'imagemagick' },
    ffmpeg   => { bins => [ 'ffmpeg' ],             pkg => 'ffmpeg' },
    ffprobe  => { bins => [ 'ffprobe' ],            pkg => 'ffmpeg' },
    pngquant => { bins => [ 'pngquant' ],           pkg => 'pngquant' },
    gifsicle => { bins => [ 'gifsicle' ],           pkg => 'gifsicle' },
    exiftool => { bins => [ 'exiftool' ],     pkg => 'libimage-exiftool-perl' },
    heif     => { bins => [ 'heif-convert' ], pkg => 'libheif-examples' },
    heifenc  => { bins => [ 'heif-enc' ],     pkg => 'libheif-examples' },
    fc_list  => { bins => [ 'fc-list' ],      pkg => 'fontconfig' },
);

=head2 find( $name )

Absolute path to the tool, or undef. Cached.

=cut

sub find
{
    my ( $name ) = @_;
    return $CACHE{ $name } if exists $CACHE{ $name };

    my $spec = $TOOL{ $name } or return $CACHE{ $name } = undef;
    for my $bin ( @{ $spec->{ bins } } )
    {
        my $path = File::Which::which( $bin );
        return $CACHE{ $name } = $path if $path;
    }
    return $CACHE{ $name } = undef;
}

=head2 have( $name )

Boolean.

=cut

sub have { return defined find( $_[ 0 ] ) }

=head2 capture( @argv )

Run a command and return its standard output, discarding standard error.
Returns undef if the command could not be started.

Deliberately not backticks: those go through a shell, so any path containing a
space, a quote or a shell metacharacter has to be escaped by the caller -- and
getting that wrong fails silently, handing the tool a mangled filename and
producing empty output that looks just like "no result".

=cut

sub capture
{
    my ( @argv ) = @_;
    return undef unless @argv;

    my $pid = open my $fh, '-|';
    return undef unless defined $pid;

    unless ( $pid )
    {    # child
        open STDERR, '>', File::Spec->devnull or exit 127;
        exec { $argv[ 0 ] } @argv or exit 127;
    }

    my $out = do { local $/ = undef; <$fh> };
    close $fh;

    return $out;
}

=head2 require_tool( $name, $why )

Dies with an actionable message naming the Debian package.

=cut

sub require_tool
{
    my ( $name, $why ) = @_;

    my $path = find( $name );
    if ( $path )
    {
        return $path;
    }

    # The caller's reason, when given, turns "ffmpeg is required" into
    # "ffmpeg is required to write video", which is the difference between a
    # user knowing what to disable and having to guess.
    my $reason = q{};
    if ( $why )
    {
        $reason = " $why";
    }

    my $pkg = $TOOL{ $name }{ pkg } // $name;

    die "GlitchVape: '$name' is required$reason but was not found in PATH.\n"
        . "  Install it with:  sudo apt install $pkg\n";
}

=head2 magick_argv( @args )

ImageMagick 7 renamed the entry point to C<magick> and deprecated C<convert>;
IM6 has no C<magick>. Returns an argv list that works on either, so callers
never have to care which is installed.

=cut

sub magick_argv
{
    my ( @args ) = @_;
    my $path = require_tool( 'magick', 'to process images' );
    return ( $path, @args ) if $path !~ m{/convert$};
    return ( $path, @args );
}

=head2 mogrify_argv( @args )

As above, for in-place batch edits.

=cut

sub mogrify_argv
{
    my ( @args ) = @_;
    my $path = require_tool( 'magick', 'to process images' );
    return $path =~ m{/magick$}
        ? ( $path, 'mogrify', @args )
        : ( File::Which::which( 'mogrify' ) // $path, @args );
}

=head2 imagemagick_version()

Major version integer (7 or 6), or undef.

=cut

sub imagemagick_version
{
    return $CACHE{ _imver } if exists $CACHE{ _imver };
    my $path    = find( 'magick' ) or return $CACHE{ _imver } = undef;
    my $out     = capture( $path, '-version' );
    my ( $ver ) = ( $out // '' ) =~ /ImageMagick\s+(\d+)/;
    return $CACHE{ _imver } = $ver;
}

=head2 supports_format( $fmt )

Whether the installed ImageMagick has a working delegate for e.g. C<HEIC>.
Debian links libheif into libmagickcore, but a self-built IM often does not.

=cut

sub supports_format
{
    my ( $fmt ) = @_;
    $fmt = uc $fmt;
    return $CACHE{ "_fmt_$fmt" } if exists $CACHE{ "_fmt_$fmt" };

    my $path = find( 'magick' ) or return $CACHE{ "_fmt_$fmt" } = 0;
    my $out  = capture( $path, '-list', 'format' );

    # Lines look like "     HEIC  HEIC      rw+   High Efficiency ...", where
    # the mode field carries a trailing + for multi-image support.
    my $listing = $out // q{};

    my $ok = 0;
    if ( $listing =~ /^\s*\Q$fmt\E\*?\s+\S+\s+[rw+-]{3}/mi )
    {
        $ok = 1;
    }

    $CACHE{ "_fmt_$fmt" } = $ok;
    return $ok;
}

=head2 ffmpeg_encoder( $name )

Whether this ffmpeg was built with a named encoder, e.g. C<libsvtav1>.
Cached.

An encoder is not a tool: C<ffmpeg> being on the path says nothing about
whether it can write AV1, and the two builds Fedora offers differ in exactly
this way. Asked before the encode rather than after, so that an unavailable
codec is a sentence in a dialog instead of twenty renders followed by an
ffmpeg error.

=cut

sub ffmpeg_encoder
{
    my ( $name ) = @_;

    my $key = "_enc_$name";
    return $CACHE{ $key } if exists $CACHE{ $key };

    my $path = find( 'ffmpeg' ) or return $CACHE{ $key } = 0;

    # -hide_banner because the build configuration is several hundred lines
    # that would otherwise be scanned for every probe.
    my $out = capture( $path, '-hide_banner', '-encoders' );

    # Lines look like " V....D libsvtav1  SVT-AV1 ... (codec av1)"; the name
    # is the second field, and matching it whole avoids libaom-av1 answering
    # for av1_nvenc.
    my $ok = 0;
    if ( ( $out // q{} ) =~ /^\s*\S+\s+\Q$name\E\s/m )
    {
        $ok = 1;
    }

    return $CACHE{ $key } = $ok;
}

=head2 font_path( @names )

Resolve the first available font from a preference list, via fontconfig and
then via the bundled F<assets/fonts>. Returns a path suitable for IM's
C<-font>, or undef.

=cut

sub font_path
{
    my ( @names ) = @_;

    for my $name ( @names )
    {
        next unless defined $name && length $name;

        # An explicit path wins outright.
        return $name if -f $name;

        my $key = "_font_$name";
        return $CACHE{ $key }
            if exists $CACHE{ $key } && defined $CACHE{ $key };

        if ( my $fc = find( 'fc_list' ) )
        {
            my $out      = capture( $fc, '-f', "%{file}\n", $name );
            my ( $file ) = grep { length && -f } split /\n/, ( $out // '' );
            if ( $file )
            {
                $CACHE{ $key } = $file;
                return $file;
            }
        }
    }
    return undef;
}

=head2 report()

Ordered list of C<[ name, path_or_undef, package ]> for C<--check-deps>.

=cut

sub report
{
    return map { [ $_, find( $_ ), $TOOL{ $_ }{ pkg } ] }
        sort keys %TOOL;
}

1;
