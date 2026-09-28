package GlitchVape::Plugin::Sprinkles;

# A plug-in that is everything a plug-in should be, and uses every place one
# can add to: an effect with a drift and a reroll, a suggestion list, a tool
# its effect requires, a palette and a duotone ramp, a font role and a font
# directory, a preset directory, and a kind of generated track. t/48 loads it
# through the real loader and asks what the program made of it; it is also
# the worked example of the API, so it is written the way one ought to be.

use strict;
use warnings;

use GlitchVape::Plugins api => 1;

use File::Basename ();
use File::Spec     ();

use GlitchVape::Config    ();
use GlitchVape::Fonts     ();
use GlitchVape::Generator ();
use GlitchVape::Magick    ();
use GlitchVape::Palette   ();
use GlitchVape::Registry  ();
use GlitchVape::Tools     ();
use GlitchVape::Wav       ();

our $VERSION = '1.00';

# Beside the module, the way a plug-in that does not use File::ShareDir keeps
# its data: it knows where it is, and says so.
my $HOME =
    File::Spec->catdir( File::Basename::dirname( __FILE__ ), 'Sprinkles' );

# A tool that is always there, so that `requires` can be asked about for real.
GlitchVape::Tools->register(
    name => 'sprinkler',
    bins => [ 'perl' ],
    pkg  => 'perl',
);

GlitchVape::Registry->register_source(
    name   => 'toppings',
    values => [ qw(hundreds thousands jimmies) ],
);

GlitchVape::Palette->register(
    name   => 'sprinkles',
    title  => 'Party sprinkles',
    colors => [ '#2B1B3D', '#FF4F9A', '#FFD23F', '#3BCEAC', '#FFFFFF' ],
);

GlitchVape::Palette->register_duotone(
    name   => 'sprinkles',
    colors => [ '#2B1B3D', '#FF4F9A' ],
);

GlitchVape::Fonts->register_role(
    name  => 'sprinkle_face',
    fonts => [ 'Sprinkle Sans', 'DejaVu Sans' ],
    hint  => 'Sprinkle Sans comes with the Sprinkles plug-in.',
);

GlitchVape::Fonts->add_dir( File::Spec->catdir( $HOME, 'fonts' ) );

GlitchVape::Config->add_preset_dir( File::Spec->catdir( $HOME, 'presets' ) );

GlitchVape::Registry->register(
    name    => 'sprinkles',
    title   => 'Sprinkles',
    stage   => 'grain',
    summary => 'Coloured specks scattered over the picture',
    doc     => <<'DOC',
Specks of a palette's colours, scattered like sprinkles on a cake. With
C<reroll> they are scattered afresh every frame and the loop still closes,
because the scattering is keyed on where a frame sits around the loop.
DOC
    requires => [ 'sprinkler' ],
    params   => {
        amount => {
            default => 0.02,
            type    => 'num',
            min     => 0,
            max     => 0.2,
            doc     => 'Share of the picture the specks cover',
        },
        topping => {
            default => 'hundreds',
            type    => 'str',
            choose  => 'toppings',
            doc     => 'The shape of a speck',
        },
        palette => {
            default => 'sprinkles',
            type    => 'str',
            choose  => 'palette',
            doc     => 'The colours they come in',
        },
        drift => {
            animation => 1,
            default   => 0,
            type      => 'num',
            min       => -4,
            max       =>  4,
            doc       => 'Widths of the picture the specks travel per loop',
        },
        reroll => {
            animation => 1,
            default   => 1,
            type      => 'bool',
            doc       => 'Scatter them afresh on every frame of a loop',
        },
    },
    apply => \&_sprinkle,
);

my %SPECK = (
    hundreds  => [ 1, 1 ],
    thousands => [ 2, 2 ],
    jimmies   => [ 4, 1 ],
);

sub _sprinkle
{
    my ( $ctx, $p ) = @_;

    my ( $w,  $h )  = $ctx->dims;
    my ( $sw, $sh ) = @{ $SPECK{ $p->{ topping } } || $SPECK{ hundreds } };

    my @inks = @{ GlitchVape::Palette::colors( $p->{ palette } ) };
    shift @inks if @inks > 2;

    # rng_phase rather than rng_for, so that scattering afresh every frame
    # still brings the frame after the last back to the first.
    my $rng =
          $p->{ reroll }
        ? $ctx->rng_phase( 'sprinkles' )
        : $ctx->rng_fixed( 'sprinkles' );

    my $shift = int( $ctx->travel( $p->{ drift } * $w, $w ) + 0.5 );

    my $count = int( $p->{ amount } * $w * $h / ( $sw * $sh ) );

    for ( 1 .. $count )
    {
        my $x = ( int( $rng->rand( $w ) ) + $shift ) % $w;
        my $y = int( $rng->rand( $h ) );

        my $ink = $inks[ int( $rng->rand( scalar @inks ) ) ];

        GlitchVape::Magick::check(
            $ctx->image->Draw(
                primitive => 'rectangle',
                points    => sprintf(
                    '%d,%d %d,%d', $x, $y, $x + $sw - 1, $y + $sh - 1
                ),
                fill   => $ink,
                stroke => 'none',
            ),
            'sprinkles: could not draw a speck'
        );
    }

    return;
}

GlitchVape::Generator->register(
    kind    => 'hum',
    label   => 'Fridge hum',
    icon    => 'audio-speakers-symbolic',
    summary => 'A refrigerator compressor in the next room',
    params  => {
        pitch => {
            default => 50,
            type    => 'int',
            min     => 40,
            max     => 120,
            doc     => 'The hum, in hertz',
        },
        seconds => {
            default => 2,
            type    => 'num',
            min     => 0.5,
            max     => 60,
            doc     => 'How long it runs',
        },
    },
    duration => sub {
        my ( $spec ) = @_;
        return $spec->{ seconds } || 2;
    },
    describe => sub {
        my ( $spec ) = @_;
        return sprintf 'fridge hum at %d Hz', $spec->{ pitch } // 50;
    },
    render => \&_hum,
);

sub _hum
{
    my ( %arg ) = @_;

    my $spec    = $arg{ spec };
    my $rate    = 16_000;
    my $seconds = $arg{ fill_to }  || $spec->{ seconds } || 2;
    my $pitch   = $spec->{ pitch } || 50;

    my $pcm = pack 's<*', map {
        GlitchVape::Wav::quantise(
            0.2 * sin( 6.283185307 * $pitch * $_ / $rate ) )
    } 0 .. int( $seconds * $rate ) - 1;

    return GlitchVape::Wav::write( $arg{ output }, $pcm, rate => $rate );
}

1;
