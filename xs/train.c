/* What `make xs PGO=1` trains the kernel on: its own work, on a picture of
 * its own making, at the settings the presets ask for -- mostly one value a
 * pixel, as ten of the twelve that use grain are, with a shadow bias and
 * without, at a size that ends on a ragged vector, and the coarse grain's
 * cells. Down both of the generator's paths where the CPU has both, so that
 * neither is laid out as though it never runs; where it has only the tables,
 * -fprofile-partial-training keeps the untrained GFNI path compiled as it
 * would have been without a profile.
 *
 * It also checks that the two paths agree, which costs nothing here and
 * would be a bug worth failing a build over. */

#include <stdio.h>
#include <string.h>

#include "grain.h"

constexpr size_t W     = 720;       /* a preview */
constexpr size_t H     = 540;
constexpr size_t RW    = 333;       /* nothing divides it */
constexpr size_t RH    = 211;
constexpr size_t CELLS = 360 * 270; /* size 2, at the preview's size */

typedef struct setting
{
    double amount, bias;
    bool   mono;
    int    reps;
} setting;

/* From the presets: hotline, vhs-decay, mallsoft, deepfry, datamosh -- and a
 * bias of nought, and an amount that clamps half of what it touches. */
static constexpr setting SETTINGS[] = {
    { 0.05, 0.7, true, 6 },   { 0.09, 0.55, true, 6 }, { 0.035, 0.3, true, 6 },
    { 0.12, 0.2, false, 3 },  { 0.06, 0.4, false, 3 }, { 0.08, 0.0, false, 2 },
    { 1.0, 0.3, false, 1 },
};

/* A diagonal ramp through a coarse chequer: every brightness from black to
 * white, so that the shadow bias sees all of them, and both ends, so that
 * the clamp does. */
static void picture( uint8_t px[], size_t w, size_t h )
{
    for ( size_t y = 0; y < h; y++ )
        for ( size_t x = 0; x < w; x++ )
        {
            uint8_t *p = px + 3 * ( y * w + x );
            uint8_t  v = (uint8_t) ( ( x + y ) * 255 / ( w + h - 2 ) );

            p[ 0 ] = ( x / 40 + y / 40 ) % 2 ? v : 255 - v;
            p[ 1 ] = v;
            p[ 2 ] = (uint8_t) ( v * 3 / 4 );
        }
}

static bool train( uint8_t px[], uint8_t cells[] )
{
    for ( size_t s = 0; s < sizeof SETTINGS / sizeof SETTINGS[ 0 ]; s++ )
        for ( int r = 0; r < SETTINGS[ s ].reps; r++ )
        {
            const setting *t   = &SETTINGS[ s ];
            gv_rng         rng = { .state = 1'337 + (uint32_t) r };

            picture( px, W, H );
            if ( !gv_grain_pixels( px, W, H, &rng, t->amount * 255, t->bias,
                                   t->mono ) )
                return false;

            picture( px, RW, RH );
            if ( !gv_grain_pixels( px, RW, RH, &rng, t->amount * 255, t->bias,
                                   t->mono ) )
                return false;

            if ( !gv_grain_cells( cells, CELLS, &rng, t->amount * 255, t->mono ) )
                return false;
        }
    return true;
}

/* The same picture and seed down one path; what it made and where it left the
 * generator, for comparing with the other. */
static gv_rng sample( gv_path path, uint8_t px[] )
{
    gv_rng rng = { .state = 42 };

    gv_grain_use_path( path );
    picture( px, RW, RH );
    if ( !gv_grain_pixels( px, RW, RH, &rng, 0.08 * 255, 0.6, false ) )
        rng.state = 0;
    return rng;
}

int main( void )
{
    __builtin_cpu_init();
    if ( !__builtin_cpu_supports( "x86-64-v3" ) )
    {
        fputs( "train: this CPU cannot run the kernel it is meant to train;"
               " build without PGO=1\n",
               stderr );
        return 1;
    }
    bool gfni = __builtin_cpu_supports( "gfni" );

    static uint8_t px[ 3 * W * H ], other[ 3 * RW * RH ], cells[ 3 * CELLS ];

    gv_grain_use_path( GV_PATH_TABLE );
    if ( !train( px, cells ) ) return 1;

    if ( gfni )
    {
        gv_grain_use_path( GV_PATH_GFNI );
        if ( !train( px, cells ) ) return 1;

        gv_rng a = sample( GV_PATH_TABLE, other );
        gv_rng b = sample( GV_PATH_GFNI, px );
        if ( memcmp( px, other, sizeof other ) || a.state != b.state
             || a.have_spare != b.have_spare
             || ( a.have_spare && memcmp( &a.spare, &b.spare, sizeof a.spare ) ) )
        {
            fputs( "train: the GFNI and table generators disagree\n", stderr );
            return 1;
        }
    }

    printf( "train: profiled the %s generator%s\n", gfni ? "GFNI and table" : "table",
            gfni ? "s" : "" );
    return 0;
}
