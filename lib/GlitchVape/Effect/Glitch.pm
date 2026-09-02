package GlitchVape::Effect::Glitch;

use strict;
use warnings;

use GlitchVape::Magick   ();
use GlitchVape::Registry ();
use GlitchVape::Pixels   ();
use GlitchVape::VGA      ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Effect::Glitch - destructive, data-level corruption

=head1 DESCRIPTION

Where L<GlitchVape::Effect::Signal> models analogue faults, this module models
digital ones: sorting runs of pixels, corrupting compressed bytes, and reusing
stale motion data. These damage the image rather than merely filtering it, so
they sit in the C<destroy> stage, after grading but before the display-surface
effects that would otherwise be destroyed along with everything else.

=cut

my $R = 'GlitchVape::Registry';

=head1 A FROZEN GLITCH IS A LOOK

Every effect here draws from C<rng_for>, which folds the frame index into the
stream, so a loop is damaged differently on every frame. That is what damage
on a running tape does and it stays the default.

It was also the only thing available, and the other reading is a real one: the
same corruption held for the whole loop is a picture of a frame that broke and
stayed broken, which is a staple of the genre and was unreachable. C<reroll>
is the switch, and C<rng_fixed> -- the same numbers on every frame, derived
under the same label -- is all it takes.

=cut

# Which stream a damage effect draws from. rng_fixed is derived under the same
# label as rng_for, so a still renders the identical picture either way and
# only a loop can tell them apart.
sub _damage_rng
{
    my ( $ctx, $p, $label ) = @_;

    return $ctx->rng_for( $label ) if $p->{ reroll };
    return $ctx->rng_fixed( $label );
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'pixelsort',
    title   => 'Pixel Sort',
    stage   => 'damage',
    summary => 'Sort runs of pixels by brightness',
    doc     => <<'DOC',
Finds contiguous runs of pixels whose brightness falls inside a threshold band
and sorts each run. The threshold is what makes this read as art rather than
noise: sorting everything just smears the picture into gradients, whereas
sorting only the dark runs (or only the bright ones) leaves the subject legible
while the shadows pour sideways.
DOC
    params => {
        reroll => {
            label     => 'Varying sort',
            default   => 1,
            type      => 'bool',
            animation => 1,
            doc       => 'Draw a new sort on every frame; off freezes it, so '
                . 'the frame breaks once and stays broken. Bites only below '
                . 'full coverage: sorting every line leaves nothing to '
                . 'choose',
        },
        direction => {
            default => 'horizontal',
            type    => 'enum',
            values  => [ qw(horizontal vertical) ],
            doc     => 'Axis along which runs are sorted',
        },
        key => {
            default => 'luma',
            type    => 'enum',
            values  => [ qw(luma hue saturation red green blue) ],
            doc     => 'What the sort compares',
        },
        lower => {
            default => 0.25,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Runs start where brightness exceeds this',
        },
        upper => {
            default => 0.80,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Runs end where brightness exceeds this',
        },
        reverse => {
            default => 0,
            type    => 'bool',
            doc     => 'Sort descending',
        },
        min_run => {
            default => 12,
            type    => 'int',
            min     => 2,
            max     => 4000,
            doc     => 'Ignore runs shorter than this',
        },
        max_run => {
            default => 0,
            type    => 'int',
            min     => 0,
            max     => 8000,
            doc     => 'Split runs longer than this (0 = unlimited)',
        },
        coverage => {
            default => 1.0,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'Fraction of eligible lines actually sorted',
        },
    },
    apply => \&_pixelsort,
);

sub _pixelsort
{
    my ( $ctx, $p ) = @_;

    my $vertical = $p->{ direction } eq 'vertical';

    # Sorting columns means fighting the row-major pixel layout for every
    # access. Rotating, sorting rows, and rotating back is dramatically faster
    # and produces an identical result.
    $ctx->image->Rotate( degrees => 90 ) if $vertical;

    my $rng   = _damage_rng( $ctx, $p, 'pixelsort' );
    my $lower = $p->{ lower } * 255;
    my $upper = $p->{ upper } * 255;
    my $keyer = _keyer( $p->{ key }, 255 );

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my $w = $px->width;

            $px->each_row(
                sub {
                    my ( $y, $row ) = @_;
                    return undef
                        if $p->{ coverage } < 1
                        && !$rng->chance( $p->{ coverage } );

                    my @v = unpack 'C*', $row;

                    # One sort key per pixel, computed once. Calling the keyer
                    # from inside the comparator would evaluate it O(n log n)
                    # times per run instead of n.
                    my @key =
                        map { $keyer->( @v[ $_ * 3 .. $_ * 3 + 2 ] ) }
                        0 .. $w - 1;

                    my $changed = 0;
                    my $i       = 0;

                    while ( $i < $w )
                    {
                        if ( $key[ $i ] < $lower || $key[ $i ] > $upper )
                        {
                            $i++;
                            next;
                        }

                        my $start = $i;
                        $i++
                            while $i < $w
                            && $key[ $i ] >= $lower
                            && $key[ $i ] <= $upper;
                        my $len = $i - $start;

                        next if $len < $p->{ min_run };

                        # Splitting a long run gives repeated short gradients,
                        # which reads as deliberate banding rather than one
                        # very long smear.
                        my $chunk = $len;
                        if ( $p->{ max_run } && $p->{ max_run } < $len )
                        {
                            $chunk = $p->{ max_run };
                        }

                        for (
                            my $off = $start ;
                            $off < $start + $len ;
                            $off += $chunk
                            )
                        {
                            my $end = $off + $chunk - 1;
                            $end = $start + $len - 1
                                if $end > $start + $len - 1;
                            next if $end - $off + 1 < $p->{ min_run };

                            my @idx = sort { $key[ $a ] <=> $key[ $b ] }
                                ( $off .. $end );
                            @idx = reverse @idx if $p->{ reverse };

                            @v[ $off * 3 .. ( $end + 1 ) * 3 - 1 ] =
                                map { @v[ $_ * 3 .. $_ * 3 + 2 ] } @idx;
                            $changed = 1;
                        }
                    }

                    # Returning undef leaves the row untouched, which skips
                    # a pointless write-back for rows that had no sortable run.
                    if ( !$changed )
                    {
                        return undef;
                    }

                    return pack 'C*', @v;
                }
            );
        }
    );

    $ctx->image->Rotate( degrees => -90 ) if $vertical;
    return;
}

# Returns a coderef mapping (r,g,b) to a comparable scalar in 0..$q.
sub _keyer
{
    my ( $key, $q ) = @_;

    return sub { 0.299 * $_[ 0 ] + 0.587 * $_[ 1 ] + 0.114 * $_[ 2 ] }
        if $key eq 'luma';

    return sub { $_[ 0 ] }
        if $key eq 'red';
    return sub { $_[ 1 ] }
        if $key eq 'green';
    return sub { $_[ 2 ] }
        if $key eq 'blue';

    if ( $key eq 'saturation' )
    {
        return sub {
            my ( $max, $min ) = ( $_[ 0 ], $_[ 0 ] );
            for ( $_[ 1 ], $_[ 2 ] )
            {
                $max = $_ if $_ > $max;
                $min = $_ if $_ < $min;
            }

            # A fully black pixel has no saturation and no denominator.
            if ( !$max )
            {
                return 0;
            }

            return ( $max - $min ) / $max * $q;
        };
    }

    # Hue, scaled to the same 0..$q range as the other keys so one threshold
    # pair works regardless of which key is chosen.
    return sub {
        my ( $r, $g, $b ) = @_;
        my ( $max, $min ) = ( $r, $r );
        for ( $g, $b )
        {
            $max = $_ if $_ > $max;
            $min = $_ if $_ < $min;
        }
        my $d = $max - $min;
        return 0 unless $d;

        # Standard HSV hue: which channel is brightest decides which 120
        # degree sector the hue falls in, and the other two position it
        # within that sector.
        my $hue;
        if ( $max == $r )
        {
            $hue = ( $g - $b ) / $d;
        }
        elsif ( $max == $g )
        {
            $hue = ( ( $b - $r ) / $d ) + 2;
        }
        else
        {
            $hue = ( ( $r - $g ) / $d ) + 4;
        }

        # Perl's % is integer-only, so wrap into [0,1) by hand.
        $hue /= 6;
        $hue -= int $hue;
        $hue += 1 if $hue < 0;
        return $hue * $q;
    };
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'databend',
    title   => 'Databend',
    stage   => 'damage',
    summary => 'Corrupt bytes inside compressed image data',
    doc     => <<'DOC',
Encodes the image as JPEG, overwrites bytes in the entropy-coded section, then
decodes the damaged file. Because JPEG is differentially coded, a single
altered byte shifts the DC term for every block after it, so one edit produces
a coloured band running to the end of the image rather than one bad pixel.

The first two kilobytes are never touched: that is the header, and corrupting
it produces a file that will not decode at all.
DOC
    params => {
        reroll => {
            label     => 'Varying corruption',
            default   => 1,
            type      => 'bool',
            animation => 1,
            doc => 'Draw a new corruption on every frame; off freezes it, '
                . 'so the frame breaks once and stays broken',
        },
        hits => {
            default => 12,
            type    => 'int',
            min     => 0,
            max     => 5000,
            doc     => 'Number of bytes to corrupt',
        },
        quality => {
            default => 70,
            type    => 'int',
            min     => 5,
            max     => 100,
            doc     =>
                'JPEG quality before corruption; lower spreads damage further',
        },
        start => {
            default => 0.15,
            type    => 'num',
            min     => 0.01,
            max     => 0.99,
            doc     => 'Earliest point in the file to corrupt, as a fraction',
        },
        mode => {
            default => 'random',
            type    => 'enum',
            values  => [ qw(random increment zero repeat) ],
            doc     => 'How a byte is altered',
        },
        attempts => {
            default => 6,
            type    => 'int',
            min     => 1,
            max     => 40,
            doc     => 'Retries if the corrupted file will not decode',
        },
    },
    apply => \&_databend,
);

sub _databend
{
    my ( $ctx, $p ) = @_;
    return if $p->{ hits } <= 0;
    require Image::Magick;

    my $rng = _damage_rng( $ctx, $p, 'databend' );

    my $src = $ctx->tmpfile( '.jpg' );
    $ctx->image->Set( quality => $p->{ quality } );
    GlitchVape::Magick::check( $ctx->image->Write( $src ),
        "databend: could not stage JPEG" );

    open my $in, '<:raw', $src or die "databend: cannot read $src: $!\n";
    my $data = do { local $/; <$in> };
    close $in;

    my $len = length $data;
    my $min = int( $len * $p->{ start } );
    $min = 2048 if $min < 2048;

    if ( $len <= $min + 16 )
    {
        $ctx->log( 'databend: image too small to corrupt safely, skipping' );
        return;
    }

    # Corruption is a gamble: some edits land on a marker and the decoder gives
    # up entirely. Retry with fresh positions rather than failing the render.
    for my $attempt ( 1 .. $p->{ attempts } )
    {
        my $bent = $data;

        for ( 1 .. $p->{ hits } )
        {
            my $pos  = $rng->int_between( $min, $len - 2 );
            my $orig = ord substr( $bent, $pos, 1 );

            my $new =
                  $p->{ mode } eq 'zero' ? 0
                : $p->{ mode } eq 'increment'
                ? ( $orig + $rng->int_between( 1, 8 ) ) % 256
                : $p->{ mode } eq 'repeat'
                ? ord substr( $bent, $rng->int_between( $min, $len - 2 ), 1 )
                : $rng->int_between( 0, 255 );

            # 0xFF starts a marker; writing one invents a segment boundary and
            # usually truncates the image.
            $new = 0xFE if $new == 0xFF;

            substr $bent, $pos, 1, chr $new;
        }

        my $out = $ctx->tmpfile( '.jpg' );
        open my $fh, '>:raw', $out or die "databend: cannot write $out: $!\n";
        print { $fh } $bent;
        close $fh or die "databend: cannot finish writing $out: $!\n";

        my $img = Image::Magick->new;
        my $rerr;
        {
            # A damaged JPEG is expected to warn; only a hard failure matters.
            local $SIG{ __WARN__ } = sub { };
            $rerr = $img->Read( $out );
        }

        if ( @$img && $img->[ 0 ]->Get( 'width' ) )
        {
            $img->Set( colorspace => 'sRGB' );
            $img->Set( alpha      => 'off' );
            $ctx->image( $img );
            $ctx->log( 'databend: %d bytes corrupted on attempt %d',
                $p->{ hits }, $attempt );
            return;
        }
    }

    $ctx->log(
        'databend: no decodable result after %d attempts, leaving image intact',
        $p->{ attempts }
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'blockshift',
    title   => 'Block Displacement',
    stage   => 'damage',
    summary => 'Displace rectangular blocks (datamosh-style tearing)',
    doc     => <<'DOC',
Copies rectangular regions to the wrong place, imitating what a video decoder
does when it applies motion vectors to a frame the encoder never sent -- blocks
of a previous image sliding into the current one. Offsets are quantised to a
macroblock grid, because a decoder can only ever be wrong in multiples of it.

How big a block gets is C<extent>, in macroblocks, and which way it runs is
C<shape>. It was a maximum width and a maximum height instead, and between
them they only ever said those same two things -- the default was eight
macroblocks by three and the one preset that set them was twelve by four, both
of them the short side at a third of the long one. Two numbers for one fact is
two numbers that can disagree, and a decoder's tears do not come in arbitrary
rectangles: they run along the scanlines, because that is the direction
vectors and slices run in.
DOC
    params => {
        reroll => {
            label     => 'Varying blocks',
            default   => 1,
            type      => 'bool',
            animation => 1,
            doc       => 'Draw new blocks on every frame; off freezes it, so '
                . 'the frame breaks once and stays broken',
        },
        blocks => {
            default => 10,
            type    => 'int',
            min     => 0,
            max     => 500,
            doc     => 'Number of blocks to displace',
        },
        size => {
            default => 16,
            type    => 'int',
            min     => 4,
            max     => 512,
            doc     => 'Macroblock grid size',
        },
        spread => {
            default => 6,
            type    => 'int',
            min     => 1,
            max     => 200,
            doc     => 'Maximum displacement in macroblocks',
        },
        extent => {
            default => 8,
            type    => 'int',
            min     => 1,
            max     => 64,
            doc     => 'Longest a block gets, in macroblocks. The short side '
                . 'follows from the shape',
        },
        shape => {
            default => 'wide',
            type    => 'enum',
            values  => [ qw(wide square tall) ],
            doc     => 'Which way a block runs. Wide is what a decoder '
                . 'actually produces, because vectors and slices run along '
                . 'the scanlines; the other two are the same fault in a '
                . 'machine that scanned some other way',
        },
    },
    apply => \&_blockshift,
);

# How many macroblocks a block may run to, each way.
#
# It was two numbers, a maximum width and a maximum height, and they were
# always saying one thing: how big, and which way round. Both the default and
# the only preset that set them had the short side at a third of the long one
# -- eight by three and twelve by four -- so the second number was never
# carrying information, it was carrying an opportunity to make the two
# disagree.
sub _block_shape
{
    my ( $p ) = @_;

    my $long = $p->{ extent };

    my $short = int( $long / 3 + 0.5 );
    $short = 1 if $short < 1;

    my $shape = $p->{ shape } // 'wide';

    return ( $long,  $long ) if $shape eq 'square';
    return ( $short, $long ) if $shape eq 'tall';
    return ( $long,  $short );
}

sub _blockshift
{
    my ( $ctx, $p ) = @_;
    return if $p->{ blocks } <= 0;

    my $rng  = _damage_rng( $ctx, $p, 'blockshift' );
    my $grid = $p->{ size };

    my ( $wide, $tall ) = _block_shape( $p );

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my ( $w, $h ) = ( $px->width, $px->height );
            return if $w < $grid * 2 || $h < $grid * 2;

            my $cols = int( $w / $grid );
            my $rows = int( $h / $grid );

            for ( 1 .. $p->{ blocks } )
            {
                my $bw = $rng->int_between( 1, $wide );
                my $bh = $rng->int_between( 1, $tall );
                $bw = $cols if $bw > $cols;
                $bh = $rows if $bh > $rows;

                my $sx = $rng->int_between( 0, $cols - $bw ) * $grid;
                my $sy = $rng->int_between( 0, $rows - $bh ) * $grid;

                my $dx =
                    $sx + $rng->int_between( -$p->{ spread }, $p->{ spread } ) *
                    $grid;
                my $dy = $sy + $rng->int_between( -1, 1 ) * $grid;

                my $pw = $bw * $grid;
                my $ph = $bh * $grid;

                # Clamp the destination inside the frame; a partial write would
                # corrupt neighbouring rows rather than being cropped.
                $dx = 0        if $dx < 0;
                $dy = 0        if $dy < 0;
                $dx = $w - $pw if $dx + $pw > $w;
                $dy = $h - $ph if $dy + $ph > $h;
                next if $dx == $sx && $dy == $sy;

                $px->set_rect( $dx, $dy, $pw, $ph,
                    $px->rect( $sx, $sy, $pw, $ph ) );
            }
        }
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'slice',
    title   => 'Slice Shatter',
    stage   => 'damage',
    summary => 'Shatter the image into displaced horizontal slabs',
    doc     => <<'DOC',
Cuts the picture into horizontal slabs and offsets each one. Unlike C<tracking>,
which damages a few bands and leaves the rest alone, this displaces everything,
giving the shattered look of a frame assembled from the wrong pieces.
DOC
    params => {
        reroll => {
            label     => 'Varying slices',
            default   => 1,
            type      => 'bool',
            animation => 1,
            doc       => 'Draw new slices on every frame; off freezes it, so '
                . 'the frame breaks once and stays broken',
        },
        slices => {
            default => 24,
            type    => 'int',
            min     => 2,
            max     => 400,
            doc     => 'Number of slabs',
        },
        spread => {
            default => 40,
            type    => 'num',
            min     => 0,
            max     => 800,
            doc     => 'Maximum sideways displacement',
        },
        bias => {
            default => 2.0,
            type    => 'num',
            min     => 0.2,
            max     => 8,
            doc     => 'Higher values keep most slabs near zero displacement',
        },
        edge => {
            default => 'wrap',
            type    => 'enum',
            values  => [ qw(wrap smear) ],
            doc     => 'Fill mode for the vacated edge',
        },
    },
    apply => \&_slice,
);

sub _slice
{
    my ( $ctx, $p ) = @_;
    return if $p->{ spread } <= 0;

    my $rng  = _damage_rng( $ctx, $p, 'slice' );
    my $wrap = $p->{ edge } eq 'wrap';

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;
            my ( $w, $h ) = ( $px->width, $px->height );

            my $sh = int( $h / $p->{ slices } ) || 1;

            for ( my $y = 0 ; $y < $h ; $y += $sh )
            {
                # The last slab is short whenever the height does not divide
                # evenly into the requested slice count.
                my $bh = $sh;
                if ( $y + $sh > $h )
                {
                    $bh = $h - $y;
                }
                last if $bh <= 0;

                # Raising a uniform draw to a power biases it towards zero,
                # so most slabs barely move and a few move a long way.
                my $mag = $rng->rand**$p->{ bias };

                my $direction = -1;
                if ( $rng->chance( 0.5 ) )
                {
                    $direction = 1;
                }

                my $shift = int( $mag * $p->{ spread } * $direction );
                next unless $shift;

                $px->set_band(
                    $y, $bh,
                    GlitchVape::Pixels::shift_band(
                        $px->band( $y, $bh ),
                        $w, $bh, $shift, $wrap
                    )
                );
            }
        }
    );
    return;
}

# ---------------------------------------------------------------------------

$R->register(
    name    => 'vgatext',
    title   => 'VGA Text Corruption',
    stage   => 'damage',
    summary => 'Text-mode characters burnt through the picture',
    doc     => <<'DOC',
A graphics card losing its mind: runs of the picture replaced by character
cells from the 8x16 text-mode font, in the sixteen colours the hardware had.

This is what a video card does when the framebuffer and the character
generator disagree about which one is driving the display -- the RAMDAC keeps
scanning out, but part of what it scans is being interpreted as text. The
result is not random noise; it is legible, wrong, and arranged on a grid,
which is what makes it read as a fault rather than as an effect.

Painted at `destroy`, so everything after it happens to the corrupted picture
rather than beside it: the scanlines, the grain and the curvature all run over
the characters, because a broken framebuffer is still going out through the
same CRT.

The glyphs are one bit per pixel and scaling is pixel replication, so a cell
at `scale` 4 is thirty-two pixels of hard-edged blocks. See
L<GlitchVape::VGA> for why they are not drawn with a real font.
DOC
    params => {
        reroll => {
            label     => 'Varying glyphs',
            default   => 1,
            type      => 'bool',
            animation => 1,
            doc       => 'Draw new glyphs and places on every frame; off '
                . 'freezes it, so the frame breaks once and stays broken',
        },
        runs => {
            default => 16,
            type    => 'int',
            min     => 0,
            max     => 400,
            doc     => 'How many separate corrupted runs appear',
        },
        length => {
            default => 10,
            type    => 'int',
            min     => 1,
            max     => 200,
            doc     => 'Longest run, in character cells; each is a random '
                . 'length up to this',
        },
        scale => {
            default => 3,
            type    => 'int',
            min     => 1,
            max     => 16,
            doc     => 'Image pixels per font pixel, so a cell is 8 by 16 '
                . 'of these',
        },
        charset => {
            default => 'mixed',
            type    => 'enum',
            values  => [ GlitchVape::VGA::charset_names() ],
            doc     => 'Which characters the corruption is made of',
        },
        grid => {
            default => 1,
            type    => 'bool',
            doc     => 'Snap runs to one character grid across the whole '
                . 'frame, as a real text mode would, rather than letting '
                . 'them land anywhere',
        },
        background => {
            default => 1,
            type    => 'bool',
            doc     => 'Draw the cell background. Off leaves the picture '
                . 'showing through everywhere the glyph is not lit',
        },
        opacity => {
            default => 1,
            type    => 'num',
            min     => 0,
            max     => 1,
            doc     => 'How completely the characters replace the picture',
        },
    },
    apply => \&_vgatext,
);

sub _vgatext
{
    my ( $ctx, $p ) = @_;

    return unless $p->{ runs } > 0;
    return unless $p->{ opacity } > 0;

    my $rng = _damage_rng( $ctx, $p, 'vgatext' );

    my @chars   = GlitchVape::VGA::charset( $p->{ charset } );
    my @colours = GlitchVape::VGA::colours();

    return unless @chars;

    my $scale = $p->{ scale };
    my $cw    = GlitchVape::VGA::CELL_W * $scale;
    my $ch    = GlitchVape::VGA::CELL_H * $scale;

    GlitchVape::Pixels->edit(
        $ctx,
        sub {
            my ( $px ) = @_;

            my $w = $px->width;
            my $h = $px->height;

            return if $cw > $w || $ch > $h;

            # A cell rendered once is a cell rendered once: the same
            # character in the same two colours comes up repeatedly in a
            # frame full of runs, and building its rows is the expensive part.
            my %cell;

            for my $n ( 1 .. $p->{ runs } )
            {
                my $cells = $rng->int_between( 1, $p->{ length } );

                my ( $x, $y ) = _run_origin( $rng, $p, $w, $h, $cells );
                next unless defined $x;

                # One background for the whole run, one foreground for the
                # whole run. Per-cell colours look like confetti; a card
                # writing an attribute byte once and then a row of characters
                # is what actually happens.
                my $back = $rng->int_between( 0, $#colours );
                my $fore = $rng->int_between( 0, $#colours );
                $fore = ( $fore + 1 ) % scalar @colours if $fore == $back;

                my @row = ( q{} ) x GlitchVape::VGA::CELL_H;

                for my $c ( 1 .. $cells )
                {
                    my $char = $chars[ $rng->int_between( 0, $#chars ) ];
                    my $key  = "$char/$fore/$back";

                    $cell{ $key } ||= GlitchVape::VGA::cell_rows(
                        char       => $char,
                        fore       => $colours[ $fore ],
                        back       => $colours[ $back ],
                        scale      => $scale,
                        background => $p->{ background },
                    );

                    for my $r ( 0 .. GlitchVape::VGA::CELL_H - 1 )
                    {
                        $row[ $r ] .= $cell{ $key }[ $r ];
                    }
                }

                GlitchVape::VGA::blit(
                    px         => $px,
                    x          => $x,
                    y          => $y,
                    rows       => \@row,
                    scale      => $scale,
                    opacity    => $p->{ opacity },
                    background => $p->{ background },
                );
            }

            return;
        }
    );

    return;
}

# Where one run starts. On the grid the origin is a whole number of cells from
# the top-left corner, which is what makes several runs line up with each
# other the way rows of text do; off it, anywhere at all.
sub _run_origin
{
    my ( $rng, $p, $w, $h, $cells ) = @_;

    my $cw = GlitchVape::VGA::CELL_W * $p->{ scale };
    my $ch = GlitchVape::VGA::CELL_H * $p->{ scale };

    my $wide = $cells * $cw;
    return ( undef, undef ) if $wide > $w;

    unless ( $p->{ grid } )
    {
        return (
            $rng->int_between( 0, $w - $wide ),
            $rng->int_between( 0, $h - $ch ),
        );
    }

    my $columns = int( $w / $cw );
    my $rows    = int( $h / $ch );

    return ( undef, undef ) if $columns < $cells || $rows < 1;

    return (
        $rng->int_between( 0, $columns - $cells ) * $cw,
        $rng->int_between( 0, $rows - 1 ) * $ch,
    );
}

1;
