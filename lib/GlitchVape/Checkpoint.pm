package GlitchVape::Checkpoint;

use strict;
use warnings;

use Digest::SHA ();
use Encode      ();
use File::Path  ();
use File::Spec  ();

use GlitchVape::Magick ();

our $VERSION = '0.01';

=head1 NAME

GlitchVape::Checkpoint - keep the picture as it stood after each effect

=head1 SYNOPSIS

    my $store = GlitchVape::Checkpoint->new( dir => $dir );

    my $ctx = $store->run(
        pipeline => $pipeline,
        base     => $source_key,
        seed     => 1337,
        load     => sub { GlitchVape::IO::load( $path, max_dim => 720 ) },
        context  => sub { GlitchVape::Context->new( image => $_[ 0 ], ... ) },
    );

=head1 DESCRIPTION

Adjusting one effect of a preset changes nothing before it. Every step up to
that one would hand the next exactly the picture it handed it last time, so
this keeps those pictures, and a render that finds the first few already done
starts after them. On one core, over the presets that ship and averaged over
which effect is the one adjusted, that is between half and nine tenths of the
render not done again.

The window is what this is for. It is the one place the same photograph goes
through nearly the same pipeline over and over; the command line renders a
thing once.

=head2 Keys

Each picture is filed under a key made from the key of the one before it and
everything the step did to it: the effect's name, its parameters as resolved,
the seed and the frame, and -- for an effect a plug-in drew -- that plug-in's
fingerprint, for the reason L<GlitchVape::GUI::State/cache_key> gives. The
first key, for the source before any effect, is the caller's, and has to name
the file, its size and date, the size it was loaded at and this program's
version.

So a key names a whole history, and two pipelines share keys for exactly as
long as their first steps agree. That a step's result depends on nothing else
is L<GlitchVape::Pipeline/run( $ctx, %opt )>'s to explain.

=head2 Kept as MPC, because nothing else gives the picture back

A resumed render has to be the same picture as one run from the start, to the
bit, or the preview a setting shows would depend on what was adjusted before
it. That rules out every ordinary format. Between effects the picture holds
sixteen-bit values while labelled as eight-bit -- C<grain> leaves it so, among
others -- and neither half of that survives a file: written at eight bits the
values are rounded, written at sixteen the label is lost, and setting the
label back with C<Set( depth =E<gt> 8 )> rounds the values after all. What the
next effect does with a picture in that state is not the same as what it does
with either of the others.

MPC is ImageMagick's pixel cache written to disk as it is, with every
attribute beside it: what goes in is what comes out, label and all. It is also
the fastest thing there is to read, being mapped rather than decoded. The
price is that it only means anything to the ImageMagick that wrote it, which
for a cache kept for one session is no price at all.

One checkpoint is two files, F<key.mpc> and the F<key.cache> it names. The
cache is renamed into place first, so an F<.mpc> that exists always has its
pixels beside it.

=head2 Only the latest history is kept

Each render prunes whatever the one before it wrote beyond the steps the two
share. The last render's own final picture is in the preview store, which is
what undo reads, so what is kept here is only what the next adjustment could
start from. And there is a byte budget, because at the window's full-size
setting one checkpoint of a twelve-megapixel photograph is seventy megabytes:
checkpoints are written in order until the budget is spent, which keeps the
decoded source -- the most expensive single step -- first.

=cut

use constant DEFAULT_BUDGET => 128 * 1024 * 1024;

=head2 digest( @parts )

A short hex digest of everything passed, each part length-prefixed so that
C<('a','bc')> and C<('ab','c')> differ. The key function for this and for
L<GlitchVape::GUI::Cache/key( @parts )>, which is this.

=cut

sub digest
{
    my ( @parts ) = @_;

    my $sha = Digest::SHA->new( 256 );

    for my $part ( @parts )
    {
        my $text = q{};
        if ( defined $part )
        {
            $text = "$part";
        }

        # Digest::SHA hashes bytes and refuses a string with a character
        # above 255 in it outright -- and half the parts here are effect
        # parameters, which is where a preset's Japanese text ends up.
        # Without this, applying any preset carrying a text effect died
        # before it rendered.
        #
        # Only what it would refuse is encoded. Encoding unconditionally
        # would re-encode a string that already holds octets, changing every
        # key that works today and discarding a warm cache for nothing.
        my $bytes = $text;
        $bytes = Encode::encode_utf8( $bytes ) if $bytes =~ /[^\x00-\xFF]/;

        # Length-prefixed rather than joined with a separator: otherwise
        # ('a','bc') and ('ab','c') hash identically, and two different
        # parameter sets could collide onto one cached image.
        $sha->add( length( $bytes ) . ':' );
        $sha->add( $bytes );
    }

    return substr $sha->hexdigest, 0, 32;
}

=head2 new( %arg )

    dir    => path     where the checkpoints go; created
    budget => bytes    most the directory may hold, default 128 MB

=cut

sub new
{
    my ( $class, %arg ) = @_;

    my $dir = $arg{ dir } or die "GlitchVape::Checkpoint: no directory\n";
    File::Path::make_path( $dir );

    return bless {
        dir    => $dir,
        budget => $arg{ budget } // DEFAULT_BUDGET,
    }, $class;
}

sub dir { $_[ 0 ]{ dir } }

=head2 chain( %arg )

    pipeline => GlitchVape::Pipeline
    base     => key of the source as loaded
    seed     => scalar
    frame    => N, frames => N     for a frame of a loop; a still by default

The key of the picture before any step and after each one: one more key than
there are steps.

=cut

sub chain
{
    my ( $self, %arg ) = @_;

    my @keys = ( $arg{ base } );

    for my $step ( $arg{ pipeline }->steps )
    {
        my @parts = (
            $keys[ -1 ],
            'step', $step->{ name },
            'seed', $arg{ seed },
            'frame',
            $arg{ frame }  // 0,
            $arg{ frames } // 1,
        );

        if ( my $plugin = $step->{ spec }{ plugin } )
        {
            require GlitchVape::Plugins;
            push @parts, GlitchVape::Plugins::fingerprint( $plugin ) // $plugin;
        }

        my $params = $step->{ params } || {};
        for my $key ( sort keys %$params )
        {
            push @parts, $key, _canonical( $params->{ $key } );
        }

        push @keys, digest( @parts );
    }

    return @keys;
}

# One string for any parameter value, unambiguous across the shapes a
# resolved parameter can take.
sub _canonical
{
    my ( $value ) = @_;

    return "\0undef" unless defined $value;

    # Each part length-prefixed, as digest() prefixes its own parts, so that
    # no two values can run together into the same string.
    my $part = sub { length( $_[ 0 ] ) . ":$_[ 0 ]" };

    if ( ref $value eq 'ARRAY' )
    {
        return
            'A['
            . join( q{}, map { $part->( _canonical( $_ ) ) } @$value ) . ']';
    }

    if ( ref $value eq 'HASH' )
    {
        return 'H{'
            . join( q{},
            map { $part->( $_ ) . $part->( _canonical( $value->{ $_ } ) ) }
            sort keys %$value ) . '}';
    }

    return "S$value";
}

=head2 source( %arg )

    base => key, load => sub { image }

The source as loaded: read from its checkpoint when there is one, loaded and
kept when there is not. For the frames of a loop, which each start from it.

=cut

sub source
{
    my ( $self, %arg ) = @_;

    my $img = $self->_read( $arg{ base } );
    return $img if $img;

    $img = $arg{ load }->();
    $self->_write( $arg{ base }, $img, 0 );

    return $img;
}

=head2 run( %arg )

    pipeline => GlitchVape::Pipeline
    base     => key of the source as loaded
    seed     => scalar
    load     => sub { image }                 the source, when not kept
    context  => sub { my ( $image ) = @_; GlitchVape::Context->new( ... ) }

Run the pipeline from the last step whose picture is kept, keeping each one
after it. Returns the context, holding the finished picture.

=cut

sub run
{
    my ( $self, %arg ) = @_;

    my @keys = $self->chain( %arg );

    $self->_prune( @keys );
    my $used = $self->_bytes;

    my $from = 0;
    my $img;

    for my $n ( reverse 0 .. $#keys )
    {
        $img  = $self->_read( $keys[ $n ] ) or next;
        $from = $n;
        last;
    }

    unless ( $img )
    {
        $img = $arg{ load }->();
        $used += $self->_write( $keys[ 0 ], $img, $used );
    }

    my $ctx = $arg{ context }->( $img );

    $arg{ pipeline }->run(
        $ctx,
        from  => $from,
        after => sub {
            my ( $done ) = @_;
            $used += $self->_write( $keys[ $done ], $ctx->image, $used );
        },
    );

    return $ctx;
}

sub _paths
{
    my ( $self, $key ) = @_;

    return (
        File::Spec->catfile( $self->{ dir }, "$key.mpc" ),
        File::Spec->catfile( $self->{ dir }, "$key.cache" ),
    );
}

sub _read
{
    my ( $self, $key ) = @_;

    my ( $mpc, $cache ) = $self->_paths( $key );
    return undef unless -s $mpc && -s $cache;

    require Image::Magick;
    my $img = Image::Magick->new;
    my $err = $img->Read( $mpc );

    # Unreadable is the same as absent: the render starts further back and
    # writes it again. A checkpoint is never worth failing a render over.
    return undef if "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400;
    return undef unless @$img;

    return $img;
}

# Keep one picture, if the budget allows. Returns the bytes it took.
sub _write
{
    my ( $self, $key, $img, $used ) = @_;

    my ( $mpc, $cache ) = $self->_paths( $key );
    return 0 if -s $mpc;

    my ( $w, $h ) = $img->Get( 'width', 'height' );
    my $channels = $img->Get( 'alpha' ) ? 4 : 3;
    my $expect   = $w * $h * $channels * 2;

    return 0 if $used + $expect > $self->{ budget };

    my $tmp = File::Spec->catfile( $self->{ dir }, ".$$-$key" );

    # A copy is written, because writing an MPC can attach the image it came
    # from to the file -- and the pipeline goes on drawing on this one.
    my $err = $img->Clone->Write( "$tmp.mpc" );

    if ( "$err" && "$err" =~ /^Exception (\d+)/ && $1 >= 400 )
    {
        unlink "$tmp.mpc", "$tmp.cache";
        return 0;
    }

    unless ( rename( "$tmp.cache", $cache ) && rename( "$tmp.mpc", $mpc ) )
    {
        unlink "$tmp.mpc", "$tmp.cache";
        return 0;
    }

    return ( -s $cache ) + ( -s $mpc );
}

# Everything that is not on the history about to be rendered. The .mpc goes
# first, so that nothing finds one whose pixels have already gone.
sub _prune
{
    my ( $self, @keys ) = @_;

    my %keep = map { $_ => 1 } @keys;

    opendir my $dh, $self->{ dir } or return;
    my @names = readdir $dh;
    closedir $dh;

    my @doomed =
        grep { /^([0-9a-f]{32})\.(?:mpc|cache)$/ && !$keep{ $1 } } @names;

    unlink map { File::Spec->catfile( $self->{ dir }, $_ ) }
        ( grep { /\.mpc$/ } @doomed ), ( grep { /\.cache$/ } @doomed );

    return;
}

sub _bytes
{
    my ( $self ) = @_;

    opendir my $dh, $self->{ dir } or return 0;
    my $total = 0;
    for my $name ( readdir $dh )
    {
        next unless $name =~ /\.(?:mpc|cache)$/;
        $total += -s File::Spec->catfile( $self->{ dir }, $name ) || 0;
    }
    closedir $dh;

    return $total;
}

1;
