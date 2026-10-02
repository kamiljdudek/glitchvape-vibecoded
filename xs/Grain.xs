/* GlitchVape::Grain's compiled functions: the glue between Perl and grain.c.
 *
 * Built the way Perl builds an extension -- with perl's own flags, for the
 * baseline x86-64 every amd64 machine runs -- because this is the code that
 * runs before anybody knows what the CPU can do. It answers that question,
 * and moves numbers in and out of GlitchVape::Random; everything that needs
 * x86-64-v3 is in grain.c, and nothing reaches it until _cpu_ok has said so.
 *
 * Every function is underscored: GlitchVape::Grain is the interface, and
 * chooses between these and its own Perl. */

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "grain.h"

/* Random keeps its generator in two entries of its hash: state, and _spare
 * while the second of a gaussian pair is waiting. */
static HV *rng_hash( pTHX_ SV *rng )
{
    if ( !SvROK( rng ) || SvTYPE( SvRV( rng ) ) != SVt_PVHV )
        croak( "GlitchVape::Grain: expected a GlitchVape::Random" );
    return (HV *) SvRV( rng );
}

static gv_rng rng_in( pTHX_ HV *hv )
{
    SV **state = hv_fetchs( hv, "state", 0 );
    SV **spare = hv_fetchs( hv, "_spare", 0 );

    gv_rng g = { .state = state ? (uint32_t) SvUV( *state ) : 0 };
    if ( spare && SvOK( *spare ) )
    {
        g.have_spare = true;
        g.spare      = SvNV( *spare );
    }
    return g;
}

/* Exactly what gauss_list leaves: the state, and _spare only if one waits. */
static void rng_out( pTHX_ HV *hv, const gv_rng *g )
{
    (void) hv_stores( hv, "state", newSVuv( g->state ) );
    if ( g->have_spare )
        (void) hv_stores( hv, "_spare", newSVnv( g->spare ) );
    else
        (void) hv_deletes( hv, "_spare", G_DISCARD );
}

/* A new string of len bytes for C to fill. */
static SV *bytes( pTHX_ STRLEN len )
{
    SV *sv = newSV( len + 1 );
    SvPOK_only( sv );
    SvCUR_set( sv, len );
    *SvEND( sv ) = '\0';
    return sv;
}

static void no_room( pTHX )
{
    croak( "GlitchVape::Grain: out of memory" );
}

MODULE = GlitchVape::Grain    PACKAGE = GlitchVape::Grain

PROTOTYPES: DISABLE

# Whether this CPU runs what grain.c was compiled for. Asked by libgcc's own
# CPUID reading, which also checks that the kernel saves the AVX registers --
# a CPU that has AVX2 under an OS that does not is a CPU without it.
bool
_cpu_ok()
  CODE:
    __builtin_cpu_init();
    RETVAL = __builtin_cpu_supports( "x86-64-v3" );
  OUTPUT:
    RETVAL

# In place: the bytes of data are changed and its length is not.
void
_pixels( SV *rng, SV *data, UV w, UV h, NV sd, NV bias, bool mono )
  PREINIT:
    HV    *hv;
    STRLEN len;
    char  *px;
    gv_rng g;
  CODE:
    hv = rng_hash( aTHX_ rng );
    px = SvPVbyte_force( data, len );
    if ( len != 3 * w * h )
        croak( "GlitchVape::Grain: %" UVuf "x%" UVuf " needs %" UVuf
               " bytes, not %" UVuf, w, h, 3 * w * h, (UV) len );

    g = rng_in( aTHX_ hv );
    if ( !gv_grain_pixels( (uint8_t *) px, w, h, &g, sd, bias, mono ) )
        no_room( aTHX );
    rng_out( aTHX_ hv, &g );
    SvSETMAGIC( data );

SV *
_cells( SV *rng, UV count, NV sd, bool mono )
  PREINIT:
    HV    *hv;
    gv_rng g;
  CODE:
    hv     = rng_hash( aTHX_ rng );
    RETVAL = bytes( aTHX_ 3 * count );
    g      = rng_in( aTHX_ hv );
    if ( !gv_grain_cells( (uint8_t *) SvPVX( RETVAL ), count, &g, sd, mono ) )
    {
        SvREFCNT_dec( RETVAL );
        no_room( aTHX );
    }
    rng_out( aTHX_ hv, &g );
  OUTPUT:
    RETVAL

# Packed as native doubles, so that a test can compare them to the bit.
SV *
_gauss( SV *rng, UV n, NV sd )
  PREINIT:
    HV    *hv;
    gv_rng g;
  CODE:
    hv     = rng_hash( aTHX_ rng );
    RETVAL = bytes( aTHX_ n * sizeof( double ) );
    g      = rng_in( aTHX_ hv );
    if ( !gv_gauss( (double *) SvPVX( RETVAL ), n, &g, sd ) )
    {
        SvREFCNT_dec( RETVAL );
        no_room( aTHX );
    }
    rng_out( aTHX_ hv, &g );
  OUTPUT:
    RETVAL

const char *
_path()
  CODE:
    RETVAL = gv_grain_path_name();
  OUTPUT:
    RETVAL

# Forcing GFNI on a CPU without it would be an illegal instruction rather than
# an error, so that is refused here.
void
_use_path( const char *name )
  CODE:
    if ( strEQ( name, "gfni" ) )
    {
        __builtin_cpu_init();
        if ( !__builtin_cpu_supports( "gfni" ) )
            croak( "GlitchVape::Grain: this CPU has no GFNI" );
        gv_grain_use_path( GV_PATH_GFNI );
    }
    else if ( strEQ( name, "table" ) )
        gv_grain_use_path( GV_PATH_TABLE );
    else if ( strEQ( name, "auto" ) )
        gv_grain_use_path( GV_PATH_AUTO );
    else
        croak( "GlitchVape::Grain: no generator path called '%s'", name );
