/* The compiled half of GlitchVape's film grain. See grain.c, and
 * GlitchVape::Grain for the Perl half and the contract between the two. */
#ifndef GLITCHVAPE_GRAIN_H
#define GLITCHVAPE_GRAIN_H

#include <stddef.h>
#include <stdint.h>

/* GlitchVape::Random's generator, as handed in and handed back: the
 * xorshift32 state, and the second value of a gaussian pair when one is
 * waiting -- unscaled, as Random keeps it in _spare. */
typedef struct gv_rng
{
    uint32_t state;
    bool     have_spare;
    double   spare;
} gv_rng;

/* How the generator is stepped: the GF(2) matrix in GFNI instructions, or
 * the same matrix as four lookup tables. The same numbers either way. */
typedef enum gv_path : unsigned char
{
    GV_PATH_AUTO,
    GV_PATH_TABLE,
    GV_PATH_GFNI,
} gv_path;

/* Each of these is false only when it could not get its working space, and
 * has then changed nothing -- neither the bytes nor the generator. */

/* Grain over packed RGB, in place: one gaussian a pixel or three. */
[[nodiscard]] bool gv_grain_pixels( uint8_t px[], size_t w, size_t h,
                                    gv_rng *rng, double sd, double bias,
                                    bool mono );

/* Coarse grain's cells: clamp( 128 + gauss ) for each of count cells,
 * three bytes a cell -- one value repeated, or three. */
[[nodiscard]] bool gv_grain_cells( uint8_t out[], size_t count, gv_rng *rng,
                                   double sd, bool mono );

/* The gaussians themselves, n of them, which is Random::gauss_list. Nothing
 * in a render needs them bare; the tests do, because a byte truncated from a
 * sum can hide a difference in the last bit of what was added. */
[[nodiscard]] bool gv_gauss( double out[], size_t n, gv_rng *rng, double sd );

/* For the tests, which hold both paths to the same numbers. */
void        gv_grain_use_path( gv_path path );
const char *gv_grain_path_name( void );

#endif
