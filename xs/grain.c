/* GlitchVape's film grain, in C.
 *
 * The arithmetic of GlitchVape::Grain's Perl -- the polar method over
 * Random's xorshift32, then each pixel moved by its gaussian scaled for the
 * shadows -- giving the same bytes for the same seed. Not a faster grain but
 * the same one: the Perl stays as the reference and the fallback, and
 * t/56-grain-c.t holds the two together, every gaussian to the bit.
 *
 * Compiled for x86-64-v3 (AVX2, BMI2, FMA, MOVBE) and nothing older: the
 * Perl side asks the CPU first and keeps to Perl when the answer is no.
 * GFNI, which v3 does not promise, is asked about again here and used for
 * the generator when it is there.
 *
 * What "the same bytes" forbids, which is most of the usual tricks:
 *
 *   - fused multiply-add. -ffp-contract=off, because a*b+c in one rounding
 *     is not Perl's a*b+c in two, and one bit of difference in s moves a
 *     draw across the rejection boundary and every number after it.
 *   - -ffast-math and anything in it that changes a value: reassociation,
 *     reciprocals, flushing denormals.
 *   - a vector log. glibc's libmvec versions round differently from the
 *     scalar log Perl calls, so the logs stay scalar glibc calls -- which
 *     makes them the floor of what this can cost.
 *
 * What it does instead is give the CPU independent work. The plain port was
 * one long dependency chain -- each random number waits for the one before,
 * the rejection branch mispredicts one time in five, every pair waits for its
 * log -- so -O3 -march=native bought it 1%. Here each stage runs over a batch
 * at a time: the generator eight or sixteen steps at once, the rejection
 * without a branch, the logs back to back where they overlap, the rest four
 * wide.
 */

#include <immintrin.h>
#include <math.h>
#include <stdbit.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <threads.h>

#include "grain.h"

/* Anything newer than C17: GCC 14 still calls C23 202000L, its draft number. */
#if __STDC_VERSION__ <= 201710L
#error "grain.c is C23: build it with -std=c23"
#endif

/* GlitchVape::Random's _RESCUE: what a state of nought becomes. Random never
 * holds one -- a seed of nought is rescued when it is made, and linear steps
 * never reach nought from anything else -- but gauss_list would draw RESCUE
 * first if it were handed one, and so does this. */
constexpr uint32_t RESCUE = 0x1D87'2B41;

/* By starting from the one state whose next is RESCUE, which is this. The
 * compiler checks it: one xorshift step, written out in constants. */
constexpr uint32_t BEFORE_RESCUE = 0xD7B4'2E5E;
constexpr uint32_t BEFORE_13     = BEFORE_RESCUE ^ BEFORE_RESCUE << 13;
constexpr uint32_t BEFORE_17     = BEFORE_13 ^ BEFORE_13 >> 17;
static_assert( ( BEFORE_17 ^ BEFORE_17 << 5 ) == RESCUE );

/* Polar attempts per batch: 2048 draws, about 1600 gaussians. Big enough to
 * keep the logs back to back, small enough that a batch stays in L1. */
constexpr size_t ATTEMPTS = 1'024;

/* ---------------------------------------------------------------------------
 * The generator
 *
 * xorshift32 is linear over GF(2): the next state is M times this one, for a
 * fixed 32x32 bit matrix M. So a run of consecutive states can all be stepped
 * forward at once by a power of M, and no lane waits on another -- where the
 * scalar generator could never start a draw before the last had finished.
 *
 * The power is applied two ways, to the same effect. GFNI's GF2P8AFFINEQB is
 * an 8x8 bit-matrix product per byte; with eight lanes "byte-sliced" -- one
 * qword per byte position, holding that byte of every lane -- a whole step is
 * sixteen 8x8 blocks in four instructions. Two such groups of eight run side
 * by side, sixteen draws apart, because one alone is a chain of shuffle,
 * product and XOR that keeps the unit waiting. Without GFNI it is four lookup
 * tables of 256 entries, one per input byte, eight lanes stepping by M^8.
 *
 * Draws come out split rather than in order: within each eight, the four that
 * will be the polar method's u and then the four that will be its v. Which
 * lane holds which draw is a free choice, and making it this one is what
 * spares the rejection below a shuffle per attempt. */

[[gnu::always_inline]] static inline uint32_t xorshift( uint32_t x )
{
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

/* M^8 by input byte, for the tables. */
static uint32_t jump8[ 4 ][ 256 ];

/* M^16 as 8x8 blocks for GFNI: for each rotation r of the byte slices, the
 * blocks taking slice (j - r) mod 4 to slice j, one qword per output slice. */
alignas( 32 ) static uint64_t gf_rot[ 4 ][ 4 ];

static once_flag tables_once = ONCE_FLAG_INIT;

/* M^k applied to each single bit: the columns of the matrix. */
static void columns( uint32_t col[ static 32 ], int k )
{
    for ( int t = 0; t < 32; t++ )
    {
        uint32_t x = UINT32_C( 1 ) << t;
        for ( int i = 0; i < k; i++ ) x = xorshift( x );
        col[ t ] = x;
    }
}

/* Built on first use rather than by a constructor, which is not a matter of
 * taste: this file is compiled for x86-64-v3, a constructor runs when the
 * library is loaded, and the library is loaded before anyone has asked
 * whether the CPU can run it. */
static void build_tables( void )
{
    uint32_t col[ 32 ];

    columns( col, 8 );
    for ( int b = 0; b < 4; b++ )
        for ( unsigned v = 0; v < 256; v++ )
        {
            uint32_t y = 0;
            for ( int t = 0; t < 8; t++ )
                if ( v >> t & 1 ) y ^= col[ 8 * b + t ];
            jump8[ b ][ v ] = y;
        }

    /* GF2P8AFFINEQB's matrix: output bit r is the parity of (byte 7 - r of
     * the qword) AND the input byte. */
    columns( col, 16 );
    for ( int r = 0; r < 4; r++ )
        for ( int j = 0; j < 4; j++ )
        {
            int      i = ( j - r + 4 ) % 4;
            uint64_t a = 0;

            for ( int ob = 0; ob < 8; ob++ )
            {
                unsigned row = 0;
                for ( int ib = 0; ib < 8; ib++ )
                    if ( col[ 8 * i + ib ] >> ( 8 * j + ob ) & 1 )
                        row |= 1u << ib;
                a |= (uint64_t) row << ( 8 * ( 7 - ob ) );
            }
            gf_rot[ r ][ j ] = a;
        }
}

/* The next eight draws after x, in the split order: 1 3 5 7 2 4 6 8. */
[[gnu::always_inline]] static inline uint32_t next8( uint32_t x,
                                                     uint32_t lane[ static 8 ] )
{
    for ( int k = 0; k < 8; k++ )
        lane[ ( k & 1 ) * 4 + k / 2 ] = x = xorshift( x );
    return x;
}

/* Eight lanes as dwords <-> byte slices: an 8x4 byte transpose either way,
 * and the same shuffle both ways round, a transpose being its own inverse. */
[[gnu::always_inline]] static inline __m256i transpose4x4( __m256i q )
{
    const __m128i t = _mm_setr_epi8( 0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14,
                                     3, 7, 11, 15 );
    return _mm256_shuffle_epi8( q, _mm256_broadcastsi128_si256( t ) );
}

[[gnu::always_inline]] static inline __m256i to_slices( __m256i lanes )
{
    return _mm256_permutevar8x32_epi32(
        transpose4x4( lanes ), _mm256_setr_epi32( 0, 4, 1, 5, 2, 6, 3, 7 ) );
}

[[gnu::always_inline]] static inline __m256i to_lanes( __m256i slices )
{
    return transpose4x4( _mm256_permutevar8x32_epi32(
        slices, _mm256_setr_epi32( 0, 2, 4, 6, 1, 3, 5, 7 ) ) );
}

/* Sixteen draws further on: slice j of the result is the XOR over input
 * slices i of block (j, i) times slice i. Rotating the slices lines each i up
 * with its j, four blocks to an instruction, paired so the XORs are a tree. */
[[gnu::target( "gfni" ), gnu::always_inline]] static inline __m256i
step16( __m256i x, __m256i m0, __m256i m1, __m256i m2, __m256i m3 )
{
    __m256i a = _mm256_gf2p8affine_epi64_epi8( x, m0, 0 );
    __m256i b = _mm256_gf2p8affine_epi64_epi8(
        _mm256_permute4x64_epi64( x, _MM_SHUFFLE( 2, 1, 0, 3 ) ), m1, 0 );
    __m256i c = _mm256_gf2p8affine_epi64_epi8(
        _mm256_permute4x64_epi64( x, _MM_SHUFFLE( 1, 0, 3, 2 ) ), m2, 0 );
    __m256i e = _mm256_gf2p8affine_epi64_epi8(
        _mm256_permute4x64_epi64( x, _MM_SHUFFLE( 0, 3, 2, 1 ) ), m3, 0 );

    return _mm256_xor_si256( _mm256_xor_si256( a, b ), _mm256_xor_si256( c, e ) );
}

/* ---------------------------------------------------------------------------
 * Which way the generator is stepped */

static gv_path forced = GV_PATH_AUTO;

void gv_grain_use_path( gv_path path )
{
    forced = path;
}

static bool have_gfni( void )
{
    __builtin_cpu_init();
    return __builtin_cpu_supports( "gfni" );
}

static gv_path chosen_path( void )
{
    if ( forced != GV_PATH_AUTO ) return forced;
    return have_gfni() ? GV_PATH_GFNI : GV_PATH_TABLE;
}

const char *gv_grain_path_name( void )
{
    return chosen_path() == GV_PATH_GFNI ? "gfni" : "table";
}

/* ---------------------------------------------------------------------------
 * Gaussians, a batch at a time
 *
 * Random::gauss_list: the polar method, each accepted pair giving two values,
 * the second kept back as the spare. Its arithmetic exactly -- including
 * x / 2**32 * 2 - 1, which is (x - 2**31) * 2**-31 with nothing rounded on
 * either side, and so is a signed conversion and one multiply here. */

/* The left-pack: for each 4-bit mask of accepted attempts, where each kept
 * lane goes, as the pair of floats a double is to a float permute. */
alignas( 32 ) static constexpr int32_t pack_pd[ 16 ][ 8 ] = {
    { 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 1, 0, 0, 0, 0, 0, 0 },
    { 2, 3, 0, 0, 0, 0, 0, 0 }, { 0, 1, 2, 3, 0, 0, 0, 0 },
    { 4, 5, 0, 0, 0, 0, 0, 0 }, { 0, 1, 4, 5, 0, 0, 0, 0 },
    { 2, 3, 4, 5, 0, 0, 0, 0 }, { 0, 1, 2, 3, 4, 5, 0, 0 },
    { 6, 7, 0, 0, 0, 0, 0, 0 }, { 0, 1, 6, 7, 0, 0, 0, 0 },
    { 2, 3, 6, 7, 0, 0, 0, 0 }, { 0, 1, 2, 3, 6, 7, 0, 0 },
    { 4, 5, 6, 7, 0, 0, 0, 0 }, { 0, 1, 4, 5, 6, 7, 0, 0 },
    { 2, 3, 4, 5, 6, 7, 0, 0 }, { 0, 1, 2, 3, 4, 5, 6, 7 },
};

/* Where a value handed out came from: what the generator is after its pair,
 * that pair's spare, and whether it was the first of the two. Or the spare
 * the caller came in holding, which advanced nothing. */
typedef struct origin
{
    double u, v;
    bool   first;
    bool   pair;
} origin;

typedef struct stream
{
    alignas( 32 ) double u[ ATTEMPTS + 4 ], v[ ATTEMPTS + 4 ], s[ ATTEMPTS + 4 ],
        L[ ATTEMPTS + 4 ];

    /* The values not yet handed out: up to two carried from the batch before,
     * then this batch's. */
    alignas( 32 ) double g[ 2 + 2 * ATTEMPTS + 8 ];
    size_t have, carried;
    origin carry[ 2 ];

    uint32_t state;   /* the generator after the last draw */
    size_t ( *fill )( struct stream *st );
    double   sd;
    origin   last;
    bool     any;
} stream;

/* Four polar attempts from eight draws -- u from the low four, v from the
 * high -- without a branch: each is written at n, and n moves past the ones
 * the polar method keeps. A left-pack, by a table indexed by the four-bit
 * mask the compare leaves. Only u and v are kept: s is worked out again from
 * them to the same bits, and so is the raw draw a v came from, should the
 * generator need to be left just after it. */
[[gnu::always_inline]] static inline size_t reject4( __m256i draws, double u_out[],
                                                     double v_out[], size_t n )
{
    __m256i sgn = _mm256_xor_si256( draws, _mm256_set1_epi32( INT32_MIN ) );
    __m256d u   = _mm256_mul_pd( _mm256_cvtepi32_pd( _mm256_castsi256_si128( sgn ) ),
                                 _mm256_set1_pd( 0x1p-31 ) );
    __m256d v   = _mm256_mul_pd(
        _mm256_cvtepi32_pd( _mm256_extracti128_si256( sgn, 1 ) ),
        _mm256_set1_pd( 0x1p-31 ) );
    __m256d s = _mm256_add_pd( _mm256_mul_pd( u, u ), _mm256_mul_pd( v, v ) );

    unsigned m = (unsigned) _mm256_movemask_pd( _mm256_and_pd(
        _mm256_cmp_pd( s, _mm256_set1_pd( 1.0 ), _CMP_LT_OQ ),
        _mm256_cmp_pd( s, _mm256_setzero_pd(), _CMP_NEQ_OQ ) ) );

    __m256i keep = _mm256_load_si256( (const __m256i *) pack_pd[ m ] );
    _mm256_storeu_pd( u_out + n, _mm256_castps_pd( _mm256_permutevar8x32_ps(
                                     _mm256_castpd_ps( u ), keep ) ) );
    _mm256_storeu_pd( v_out + n, _mm256_castps_pd( _mm256_permutevar8x32_ps(
                                     _mm256_castpd_ps( v ), keep ) ) );

    return n + stdc_count_ones( m );
}

/* A batch of attempts, drawn and sorted in one pass: what each generator
 * hands over is never written out, only what the polar method keeps of it.
 * Returns the pairs kept, and leaves st->state at the last draw. */
static size_t fill_table( stream *restrict st )
{
    uint32_t x[ 8 ];
    next8( st->state, x );

    /* Sixty-four at a time into a small buffer, then sorted from it: the
     * same lanes loaded straight back as one vector would wait on eight
     * scalar stores the CPU cannot forward to a single wide load. */
    alignas( 32 ) uint32_t buf[ 64 ];
    size_t n = 0;

    for ( size_t i = 0; i < 2 * ATTEMPTS; i += 64 )
    {
        for ( int k = 0; k < 64; k += 8 )
        {
#pragma GCC unroll 8
            for ( int j = 0; j < 8; j++ )
            {
                buf[ k + j ] = x[ j ];
                x[ j ] = jump8[ 0 ][ x[ j ] & 0xFF ] ^ jump8[ 1 ][ x[ j ] >> 8 & 0xFF ]
                       ^ jump8[ 2 ][ x[ j ] >> 16 & 0xFF ] ^ jump8[ 3 ][ x[ j ] >> 24 ];
            }
        }
        for ( int k = 0; k < 64; k += 8 )
            n = reject4( _mm256_load_si256( (const __m256i *) ( buf + k ) ), st->u,
                         st->v, n );
    }

    st->state = buf[ 63 ];
    return n;
}

[[gnu::target( "gfni" )]] static size_t fill_gfni( stream *restrict st )
{
    const __m256i m0 = _mm256_load_si256( (const __m256i *) gf_rot[ 0 ] );
    const __m256i m1 = _mm256_load_si256( (const __m256i *) gf_rot[ 1 ] );
    const __m256i m2 = _mm256_load_si256( (const __m256i *) gf_rot[ 2 ] );
    const __m256i m3 = _mm256_load_si256( (const __m256i *) gf_rot[ 3 ] );

    alignas( 32 ) uint32_t first[ 8 ], second[ 8 ];
    next8( next8( st->state, first ), second );

    __m256i a = to_slices( _mm256_load_si256( (const __m256i *) first ) );
    __m256i b = to_slices( _mm256_load_si256( (const __m256i *) second ) );

    size_t  n = 0;
    __m256i d = _mm256_setzero_si256();

    for ( size_t i = 0; i < 2 * ATTEMPTS; i += 16 )
    {
        n = reject4( to_lanes( a ), st->u, st->v, n );
        d = to_lanes( b );
        n = reject4( d, st->u, st->v, n );

        a = step16( a, m0, m1, m2, m3 );
        b = step16( b, m0, m1, m2, m3 );
    }

    st->state = (uint32_t) _mm256_extract_epi32( d, 7 );
    return n;
}

/* One batch: draw and reject, log, and append its gaussians after the carry. */
static void batch( stream *restrict st )
{
    size_t n = st->fill( st );

    /* The lanes past n are whatever the left-pack left there; make them
     * harmless rather than let them be read. */
    for ( size_t i = n; i < ( n + 3 ) / 4 * 4; i++ ) st->u[ i ] = st->v[ i ] = 0.5;

    for ( size_t i = 0; i < n; i += 4 )
    {
        __m256d u = _mm256_load_pd( st->u + i ), v = _mm256_load_pd( st->v + i );
        _mm256_store_pd( st->s + i, _mm256_add_pd( _mm256_mul_pd( u, u ),
                                                   _mm256_mul_pd( v, v ) ) );
    }

    /* glibc's log, one at a time: Perl calls this one, and the vector ones
     * round differently. Back to back they overlap, which is all that can be
     * done for them. */
    for ( size_t i = 0; i < n; i++ ) st->L[ i ] = log( st->s[ i ] );

    for ( size_t i = n; i < ( n + 3 ) / 4 * 4; i++ ) st->L[ i ] = 0;

    double       *out   = st->g + st->have;
    const __m256d minus = _mm256_set1_pd( -2.0 );
    const __m256d sd    = _mm256_set1_pd( st->sd );

    for ( size_t i = 0; i < n; i += 4 )
    {
        __m256d u  = _mm256_load_pd( st->u + i );
        __m256d v  = _mm256_load_pd( st->v + i );
        __m256d f  = _mm256_sqrt_pd( _mm256_div_pd(
            _mm256_mul_pd( minus, _mm256_load_pd( st->L + i ) ),
            _mm256_load_pd( st->s + i ) ) );
        __m256d g0 = _mm256_mul_pd( _mm256_mul_pd( sd, u ), f );
        __m256d g1 = _mm256_mul_pd( sd, _mm256_mul_pd( v, f ) );

        __m256d lo = _mm256_unpacklo_pd( g0, g1 );
        __m256d hi = _mm256_unpackhi_pd( g0, g1 );
        _mm256_storeu_pd( out + 2 * i, _mm256_permute2f128_pd( lo, hi, 0x20 ) );
        _mm256_storeu_pd( out + 2 * i + 4,
                          _mm256_permute2f128_pd( lo, hi, 0x31 ) );
    }

    st->carried = st->have;
    st->have += 2 * n;
}

/* Where the value at position k of g came from. */
static origin origin_of( const stream *st, size_t k )
{
    if ( k < st->carried ) return st->carry[ k ];

    size_t p = ( k - st->carried ) / 2;
    return ( origin ){ .u     = st->u[ p ],
                       .v     = st->v[ p ],
                       .first = ( k - st->carried ) % 2 == 0,
                       .pair  = true };
}

/* The first used values have been handed out. What is left over -- at most
 * two, the rest of a pixel's channels -- moves to the front for next time. */
static void handed_out( stream *st, size_t used )
{
    if ( used )
    {
        st->last = origin_of( st, used - 1 );
        st->any  = true;
    }

    size_t left = st->have - used;
    if ( left > 2 ) left = 0;   /* only at the end, where nothing follows */

    origin keep[ 2 ];
    for ( size_t k = 0; k < left; k++ ) keep[ k ] = origin_of( st, used + k );
    memmove( st->g, st->g + used, left * sizeof( double ) );
    memcpy( st->carry, keep, sizeof keep );

    st->have    = left;
    st->carried = left;
}

static stream *stream_open( const gv_rng *rng, double sd )
{
    stream *st = aligned_alloc( alignof( stream ), sizeof( stream ) );
    if ( !st ) return nullptr;

    call_once( &tables_once, build_tables );

    st->fill  = chosen_path() == GV_PATH_GFNI ? fill_gfni : fill_table;
    st->sd    = sd;
    st->any   = false;
    st->state = rng->state ? rng->state : BEFORE_RESCUE;

    st->have = st->carried = 0;
    if ( rng->have_spare )
    {
        /* Random::gauss_list hands out a waiting spare before drawing. */
        st->g[ 0 ]     = sd * rng->spare;
        st->carry[ 0 ] = ( origin ){ .pair = false };
        st->have = st->carried = 1;
    }
    return st;
}

/* Where Perl's generator would be now: just after the pair the last value
 * came from, holding its second value if that went unused. */
static void stream_close( stream *st, gv_rng *rng )
{
    if ( st->any && st->last.pair )
    {
        /* The raw draw v was made from: v is (x - 2**31) * 2**-31 exactly,
         * so x is v * 2**31 + 2**31 exactly. And the spare worked out again
         * as it was the first time, which costs one log rather than a store
         * for every pair. */
        double u = st->last.u, v = st->last.v, s = u * u + v * v;

        rng->state = (uint32_t) ( (int64_t) ( v * 0x1p31 ) + 0x8000'0000 );
        rng->have_spare = st->last.first;
        rng->spare      = v * sqrt( -2 * log( s ) / s );
    }
    else if ( st->any )
        rng->have_spare = false;   /* only the spare it came with was used */

    free( st );
}

/* ---------------------------------------------------------------------------
 * The pixels
 *
 * GlitchVape::Grain's loop, four pixels at a time: luma, the shadow bias,
 * the noise added, clamped and truncated to a byte -- in Perl's order of
 * operations, with the division by 255 a division. A bias of nought gives a
 * scale of exactly one, which is what Perl's `if ( $bias )` skipping it
 * gives. */

[[gnu::always_inline]] static inline uint8_t clamp8( double t )
{
    return t < 0 ? 0 : t > 255 ? 255 : (uint8_t) t;
}

[[gnu::always_inline]] static inline double scale_of( const uint8_t *p,
                                                      double         bias )
{
    return 1 - bias * ( ( 0.299 * p[ 0 ] + 0.587 * p[ 1 ] + 0.114 * p[ 2 ] ) / 255 );
}

[[gnu::always_inline]] static inline __m128i to_bytes( __m256d t )
{
    t = _mm256_min_pd( _mm256_max_pd( t, _mm256_setzero_pd() ),
                       _mm256_set1_pd( 255 ) );
    return _mm256_cvttpd_epi32( t );
}

/* Three channels of four pixels, as four ints each, back to twelve bytes --
 * written as eight and four so nothing past them is touched. */
[[gnu::always_inline]] static inline void store12( uint8_t *p, __m128i r,
                                                   __m128i g, __m128i b )
{
    __m128i rgb = _mm_or_si128(
        r, _mm_or_si128( _mm_slli_epi32( g, 8 ), _mm_slli_epi32( b, 16 ) ) );
    rgb = _mm_shuffle_epi8( rgb, _mm_setr_epi8( 0, 1, 2, 4, 5, 6, 8, 9, 10,
                                                12, 13, 14, -1, -1, -1, -1 ) );
    _mm_storel_epi64( (__m128i *) p, rgb );
    _mm_storeu_si32( p + 8, _mm_srli_si128( rgb, 8 ) );
}

/* np pixels from p, room of them to the end of the picture: a vector load
 * reads sixteen bytes for twelve, so the last few are done one at a time. */
static void pixels( uint8_t *restrict p, size_t np, size_t room,
                    const double *restrict n, double bias, bool mono )
{
    const __m128i sel_r = _mm_setr_epi8( 0, -1, -1, -1, 3, -1, -1, -1, 6, -1,
                                         -1, -1, 9, -1, -1, -1 );
    const __m128i sel_g = _mm_setr_epi8( 1, -1, -1, -1, 4, -1, -1, -1, 7, -1,
                                         -1, -1, 10, -1, -1, -1 );
    const __m128i sel_b = _mm_setr_epi8( 2, -1, -1, -1, 5, -1, -1, -1, 8, -1,
                                         -1, -1, 11, -1, -1, -1 );
    const __m256d c299 = _mm256_set1_pd( 0.299 ), c587 = _mm256_set1_pd( 0.587 ),
                  c114 = _mm256_set1_pd( 0.114 ), c255 = _mm256_set1_pd( 255 ),
                  one = _mm256_set1_pd( 1.0 ), vb = _mm256_set1_pd( bias );

    size_t k = 0;
    for ( ; k + 4 <= np && k + 6 <= room; k += 4 )
    {
        uint8_t *q   = p + 3 * k;
        __m128i  raw = _mm_loadu_si128( (const __m128i *) q );
        __m256d  R   = _mm256_cvtepi32_pd( _mm_shuffle_epi8( raw, sel_r ) );
        __m256d  G   = _mm256_cvtepi32_pd( _mm_shuffle_epi8( raw, sel_g ) );
        __m256d  B   = _mm256_cvtepi32_pd( _mm_shuffle_epi8( raw, sel_b ) );

        __m256d luma = _mm256_div_pd(
            _mm256_add_pd( _mm256_add_pd( _mm256_mul_pd( c299, R ),
                                          _mm256_mul_pd( c587, G ) ),
                           _mm256_mul_pd( c114, B ) ),
            c255 );
        __m256d scale = _mm256_sub_pd( one, _mm256_mul_pd( vb, luma ) );

        __m256d nr, ng, nb;
        if ( mono )
            nr = ng = nb = _mm256_mul_pd( _mm256_loadu_pd( n + k ), scale );
        else
        {
            /* Twelve values in channel order, R G B R G B ..., dealt out to
             * three vectors of one channel each. */
            __m256d a = _mm256_loadu_pd( n + 3 * k );
            __m256d b = _mm256_loadu_pd( n + 3 * k + 4 );
            __m256d c = _mm256_loadu_pd( n + 3 * k + 8 );

            nr = _mm256_permute4x64_pd(
                _mm256_blend_pd( _mm256_blend_pd( a, b, 0b0100 ), c, 0b0010 ),
                _MM_SHUFFLE( 1, 2, 3, 0 ) );
            ng = _mm256_permute_pd(
                _mm256_blend_pd( _mm256_blend_pd( a, b, 0b1001 ), c, 0b0100 ),
                0b0101 );
            nb = _mm256_permute4x64_pd(
                _mm256_blend_pd( _mm256_blend_pd( a, b, 0b0010 ), c, 0b1001 ),
                _MM_SHUFFLE( 3, 0, 1, 2 ) );

            nr = _mm256_mul_pd( nr, scale );
            ng = _mm256_mul_pd( ng, scale );
            nb = _mm256_mul_pd( nb, scale );
        }

        store12( q, to_bytes( _mm256_add_pd( R, nr ) ),
                 to_bytes( _mm256_add_pd( G, ng ) ),
                 to_bytes( _mm256_add_pd( B, nb ) ) );
    }

    for ( ; k < np; k++ )
    {
        uint8_t *q     = p + 3 * k;
        double   scale = scale_of( q, bias );

        if ( mono )
        {
            double d = n[ k ] * scale;
            for ( int c = 0; c < 3; c++ ) q[ c ] = clamp8( q[ c ] + d );
        }
        else
            for ( int c = 0; c < 3; c++ )
                q[ c ] = clamp8( q[ c ] + n[ 3 * k + c ] * scale );
    }
}

/* ---------------------------------------------------------------------------
 * What the glue calls. */

bool gv_grain_pixels( uint8_t px[], size_t w, size_t h, gv_rng *rng,
                      double sd, double bias, bool mono )
{
    size_t total = w * h;
    if ( !total ) return true;

    stream *st = stream_open( rng, sd );
    if ( !st ) return false;

    for ( size_t done = 0; done < total; )
    {
        batch( st );

        size_t np = mono ? st->have : st->have / 3;
        if ( np > total - done ) np = total - done;

        pixels( px + 3 * done, np, total - done, st->g, bias, mono );
        handed_out( st, mono ? np : 3 * np );
        done += np;
    }

    stream_close( st, rng );
    return true;
}

bool gv_grain_cells( uint8_t out[], size_t count, gv_rng *rng, double sd,
                     bool mono )
{
    if ( !count ) return true;

    stream *st = stream_open( rng, sd );
    if ( !st ) return false;

    for ( size_t done = 0; done < count; )
    {
        batch( st );

        size_t nc = mono ? st->have : st->have / 3;
        if ( nc > count - done ) nc = count - done;

        uint8_t *o = out + 3 * done;
        for ( size_t k = 0; k < nc; k++ )
        {
            if ( mono )
                o[ 3 * k ] = o[ 3 * k + 1 ] = o[ 3 * k + 2 ] =
                    clamp8( 128 + st->g[ k ] );
            else
                for ( int c = 0; c < 3; c++ )
                    o[ 3 * k + c ] = clamp8( 128 + st->g[ 3 * k + c ] );
        }

        handed_out( st, mono ? nc : 3 * nc );
        done += nc;
    }

    stream_close( st, rng );
    return true;
}

bool gv_gauss( double out[], size_t n, gv_rng *rng, double sd )
{
    if ( !n ) return true;

    stream *st = stream_open( rng, sd );
    if ( !st ) return false;

    for ( size_t done = 0; done < n; )
    {
        batch( st );

        size_t k = st->have < n - done ? st->have : n - done;
        memcpy( out + done, st->g, k * sizeof( double ) );
        handed_out( st, k );
        done += k;
    }

    stream_close( st, rng );
    return true;
}
