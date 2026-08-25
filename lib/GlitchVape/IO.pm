package GlitchVape::IO;

use strict;
use warnings;

use File::Basename qw(basename fileparse);
use File::Spec     ();
use File::Temp     ();

use GlitchVape::Magick ();
use GlitchVape::Tools  ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::IO - reading, orienting and writing images

=head1 DESCRIPTION

Wraps PerlMagick's read/write with the two things that bite on phone photos:

=over 4

=item *

B<Orientation.> iPhone HEICs are almost always stored landscape with an EXIF
rotation flag. Every effect here is direction-sensitive -- scanlines are
horizontal, head-switching noise sits at the bottom -- so the image must be
physically rotated I<before> the pipeline runs, not tagged for the viewer to
rotate afterwards.

=item *

B<HEIC write support.> ImageMagick on Debian reads HEIC via libheif but often
cannot write it (the encoder needs x265). We detect that and route through
C<heif-enc> instead of failing at the last step of a long render.

=back

=cut

my %READABLE_EXT = map { $_ => 1 }
    qw(png jpg jpeg heic heif tif tiff webp bmp gif avif ppm pnm);

=head2 load( $path, %opt )

Returns an L<Image::Magick> object. Options:

    max_dim   => N       downscale so neither side exceeds N (0 = no limit)
    fit       => [W,H]   downscale to fit inside a box; see below
    orient    => 0       skip EXIF auto-rotation
    frame     => N       which frame of a multi-image file (default 0)

=head3 fit is a box, and the box turns with the picture

C<max_dim> is one number and cannot say "640 by 480": a 4:3 photograph capped
at 640 comes out 640x480, but a 16:9 one comes out 640x360, and a panorama
comes out 640x137. That is the right rule for "no bigger than this", and the
wrong one for "must land on a screen that is 640 by 480".

So C<fit> takes both numbers and shrinks to fit inside them, aspect preserved,
never enlarging. The box is applied along the picture's own long edge rather
than along x: C<< fit => [ 640, 480 ] >> gives 640x480 for a landscape
photograph and 480x640 for a portrait one, because a portrait photograph on a
VGA screen filled its height, not 360 pixels of its width.

Both may be given, and then both apply.

Fitting the source is not on its own enough to promise that the I<result>
fits: C<letterbox> and C<border> add pixels, so a 640x480 load can leave 668x508
on disk. C<save> takes the same option for that reason, and the two together
are what makes the promise true -- see L</save>.

=cut

sub load
{
    my ( $path, %opt ) = @_;

    die "GlitchVape::IO: no such file: $path\n"  unless -f $path;
    die "GlitchVape::IO: file is empty: $path\n" unless -s $path;

    require Image::Magick;

    my ( undef, undef, $ext ) = fileparse( lc $path, qr/\.[^.]*/ );
    $ext =~ s/^\.//;

    my $src = $path;
    my $tmp;

    # If IM lacks the HEIC delegate, transcode with heif-convert first.
    if ( $ext =~ /^(heic|heif)$/
        && !GlitchVape::Tools::supports_format( 'HEIC' ) )
    {
        $tmp = _heic_to_png( $path );
        $src = $tmp;
    }

    my $img = Image::Magick->new;
    my $err = $img->Read( $src );
    unlink $tmp if $tmp;
    GlitchVape::Magick::check( $err, "cannot read $path" );

    die "GlitchVape::IO: $path decoded to zero frames\n" unless @$img;

    # Collapse a multi-frame file (live photos, animated GIF) to one frame.
    my $frame = $opt{ frame } || 0;
    $frame = 0 if $frame > $#$img;
    my $out = Image::Magick->new;
    push @$out, $img->[ $frame ];

    # Orientation is on unless explicitly switched off, stated positively so
    # the condition does not have to be read as a double negative.
    my $auto_orient = !defined $opt{ orient } || $opt{ orient };

    if ( $auto_orient )
    {
        $out->AutoOrient;

        # AutoOrient leaves the now-stale flag behind; clear it so downstream
        # viewers do not rotate a second time.
        $out->Set( orientation => 'TopLeft' );
    }

    if ( my $max = $opt{ max_dim } )
    {
        my ( $w, $h ) = $out->Get( 'width', 'height' );
        if ( $w > $max || $h > $max )
        {
            $out->Resize( geometry => "${max}x${max}>" );
        }
    }

    if ( my $box = $opt{ fit } )
    {
        _fit_box( $out, $box );
    }

    # Effects assume 8-bit sRGB with a predictable channel order.
    $out->Set( colorspace => 'sRGB' )
        if lc( $out->Get( 'colorspace' ) // '' ) ne 'srgb';
    $out->Set( depth => 8 );
    $out->Set( alpha => 'off' ) unless $opt{ keep_alpha };

    return $out;
}

=head2 save( $img, $path, %opt )

Writes, choosing an encoder from the extension. Options:

    quality  => N       JPEG/HEIC quality (default 92)
    fit      => [W,H]   shrink to fit a box before writing
    colors   => N       quantise to an N-entry palette before writing
    strip    => 1       drop all metadata (default: on)
    optimise => 1       run pngquant/gifsicle where applicable

C<fit> here is the same box as L</load>'s and is what actually guarantees the
size of the file: the pipeline is free to make the picture bigger than what it
was given -- C<letterbox> and C<border> both do -- so the box has to be
applied again on the way out. Given to both, the source is fetched at roughly
the final size, which is what makes the pixel-scale effects look right, and
the last few pixels of growth are taken off here.

Applied before C<colors>, so the palette is built from the pixels that will be
written rather than from ones about to be resampled away.

C<colors> is what makes a 256-colour Windows bitmap a 256-colour Windows
bitmap. Quantising is not something the BMP encoder does on its own -- given a
truecolour image it writes a 24-bit file with a .bmp on the end, which is not
what anybody asking for 256 colours meant -- so the palette is built here and
the image is switched to palette type before the write, which is what makes
the encoder choose its 8-bit form.

=cut

sub save
{
    my ( $img, $path, %opt ) = @_;

    # Both default to on rather than being taken as plain truthiness, so that
    # an explicit quality => 0 or strip => 0 is honoured.
    my $quality = 92;
    if ( defined $opt{ quality } )
    {
        $quality = $opt{ quality };
    }

    my $strip = 1;
    if ( defined $opt{ strip } )
    {
        $strip = $opt{ strip };
    }

    my ( undef, $dir, $ext ) = fileparse( $path, qr/\.[^.]*/ );
    $ext = lc $ext;
    $ext =~ s/^\.//;
    $ext ||= 'png';

    _ensure_dir( $dir );

    $img->Strip if $strip;
    $img->Set( quality => $quality );

    _fit_box( $img, $opt{ fit } )     if $opt{ fit };
    _quantise( $img, $opt{ colors } ) if $opt{ colors };

    if ( $ext =~ /^(heic|heif)$/ && !_can_write_heic() )
    {
        return _save_via_heif_enc( $img, $path, $quality );
    }

    GlitchVape::Magick::check( $img->Write( $path ), "cannot write $path" );

    _optimise( $path, $ext, %opt ) if $opt{ optimise };

    die "GlitchVape::IO: wrote $path but it is empty\n" unless -s $path;
    return $path;
}

=head2 derive_output_path( $input, %opt )

Default output naming: F<IMG_8111.HEIC> plus preset C<vhs-decay> becomes
F<out/IMG_8111.vhs-decay.png>. Keeps a batch of renders self-describing
instead of a directory of C<output1.png>.

=cut

sub derive_output_path
{
    my ( $input, %opt ) = @_;

    my ( $name, undef, undef ) = fileparse( $input, qr/\.[^.]*/ );
    my $dir    = $opt{ dir }    // 'out';
    my $ext    = $opt{ format } // 'png';
    my $preset = $opt{ preset };
    my $seed   = $opt{ seed };

    my @parts = ( $name );
    push @parts, $preset  if defined $preset  && length $preset;
    push @parts, "s$seed" if $opt{ tag_seed } && defined $seed;

    return File::Spec->catfile( $dir, join( '.', @parts ) . ".$ext" );
}

=head2 is_supported( $path )

Whether the extension is one we attempt to read.

=cut

sub is_supported
{
    my ( $path ) = @_;
    my ( undef, undef, $ext ) = fileparse( lc $path, qr/\.[^.]*/ );
    $ext =~ s/^\.//;
    if ( $READABLE_EXT{ $ext } )
    {
        return 1;
    }

    return 0;
}

=head2 orientation( $path )

EXIF orientation string via exiftool, or undef. Diagnostic only -- the actual
rotation is done by ImageMagick.

=cut

sub orientation
{
    my ( $path ) = @_;
    my $et = GlitchVape::Tools::find( 'exiftool' ) or return undef;

    my $out = GlitchVape::Tools::capture( $et, '-s3', '-Orientation', $path );
    return undef unless defined $out;

    chomp $out;

    # exiftool prints nothing when the tag is absent, which is not the same as
    # an orientation of zero.
    if ( !length $out )
    {
        return undef;
    }

    return $out;
}

# The long side of the box against the long side of the picture. '>' on the
# geometry is what makes this a shrink rather than a resize: an image already
# inside the box is left exactly as it was, which matters because upscaling a
# small source to 640x480 would invent detail nobody asked for.
# Floyd-Steinberg is left on, which is ImageMagick's default: 256 colours
# without dithering bands a sky into stripes, and a dithered VGA-era palette
# is the look this is for in the first place.
sub _quantise
{
    my ( $img, $colors ) = @_;

    GlitchVape::Magick::check(
        $img->Quantize( colors => $colors ),
        "cannot quantise to $colors colours"
    );

    # Quantize alone leaves a truecolour image that happens to use few
    # colours. The encoder decides its bit depth from the type.
    $img->Set( type  => 'Palette' );
    $img->Set( depth => 8 );

    return;
}

sub _fit_box
{
    my ( $img, $box ) = @_;

    my ( $bw, $bh ) = @$box;
    return unless $bw && $bh;

    my ( $long, $short ) = $bw >= $bh ? ( $bw, $bh ) : ( $bh, $bw );

    my ( $w, $h ) = $img->Get( 'width', 'height' );
    return unless $w && $h;

    # A square picture is neither, and gets the short side: it has to fit
    # both ways round.
    my ( $limit_w, $limit_h ) =
        $w > $h ? ( $long, $short ) : ( $short, $long );

    return if $w <= $limit_w && $h <= $limit_h;

    $img->Resize( geometry => "${limit_w}x${limit_h}>" );

    return;
}

sub _heic_to_png
{
    my ( $path ) = @_;
    my $conv = GlitchVape::Tools::find( 'heif' )
        or die
        "GlitchVape::IO: $path is HEIC, but this ImageMagick has no HEIC\n"
        . "  delegate and heif-convert is not installed.\n"
        . "  Install it with:  sudo apt install libheif-examples\n";

    my ( $fh, $tmp ) =
        File::Temp::tempfile( 'gv_heic_XXXXXX', SUFFIX => '.png', TMPDIR => 1 );
    close $fh;

    die "GlitchVape::IO: heif-convert failed on $path\n"
        unless system( $conv, $path, $tmp ) == 0 && -s $tmp;

    return $tmp;
}

{
    my $probed;

    # ImageMagick's format list reports HEIC as "rw" whenever libheif is
    # linked, but writing also needs an HEVC encoder that Debian's libheif
    # does not ship. Actually attempting a 1x1 write is the only honest test;
    # it costs one exec, once per process.
    sub _can_write_heic
    {
        return $probed if defined $probed;
        return $probed = 0 unless GlitchVape::Tools::supports_format( 'HEIC' );

        my ( $fh, $tmp ) = File::Temp::tempfile(
            'gv_probe_XXXXXX',
            SUFFIX => '.heic',
            TMPDIR => 1
        );
        close $fh;

        my @argv =
            GlitchVape::Tools::magick_argv( '-size', '1x1', 'xc:black', $tmp );

        # The probe is expected to fail on a build without an HEVC encoder, so
        # silence it. If STDERR cannot be redirected, run noisily rather than
        # skipping the check.
        if ( open my $saved, '>&', \*STDERR )
        {
            if ( open STDERR, '>', File::Spec->devnull )
            {
                system( @argv );
                open STDERR, '>&', $saved
                    or die "GlitchVape::IO: could not restore STDERR: $!\n";
            }
            else
            {
                system( @argv );
            }
            close $saved;
        }
        else
        {
            system( @argv );
        }

        # A non-empty file means the encoder exists and worked.
        $probed = 0;
        if ( -s $tmp )
        {
            $probed = 1;
        }

        unlink $tmp;
        return $probed;
    }
}

sub _save_via_heif_enc
{
    my ( $img, $path, $quality ) = @_;

    my $enc = GlitchVape::Tools::find( 'heifenc' )
        or die "GlitchVape::IO: cannot write HEIC -- ImageMagick has no HEIC\n"
        . "  encoder and heif-enc is not installed.\n"
        . "  Install it with:  sudo apt install libheif-examples\n"
        . "  (or choose a different output extension, e.g. .png)\n";

    my ( $fh, $tmp ) =
        File::Temp::tempfile( 'gv_out_XXXXXX', SUFFIX => '.png', TMPDIR => 1 );
    close $fh;

    GlitchVape::Magick::check( $img->Write( $tmp ), 'staging write failed' );

    my $rc = system( $enc, '-q', $quality, $tmp, '-o', $path );
    unlink $tmp;

    die "GlitchVape::IO: heif-enc failed writing $path\n"
        unless $rc == 0 && -s $path;

    return $path;
}

sub _optimise
{
    my ( $path, $ext, %opt ) = @_;

    if ( $ext eq 'png' && ( my $pq = GlitchVape::Tools::find( 'pngquant' ) ) )
    {
        my $colors = $opt{ quantize_colors } || 256;
        system( $pq, '--force', '--skip-if-larger', '--quality', '45-95',
            '--speed', '1', $colors, '--output', $path, '--', $path );
    }
    elsif ( $ext eq 'gif'
        && ( my $gs = GlitchVape::Tools::find( 'gifsicle' ) ) )
    {
        system( $gs, '--batch', '--optimize=3', $path );
    }
    return;
}

sub _ensure_dir
{
    my ( $dir ) = @_;
    return if !length $dir || -d $dir;
    require File::Path;
    File::Path::make_path( $dir );
    return;
}

1;
