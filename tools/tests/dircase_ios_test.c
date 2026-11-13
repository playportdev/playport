/* SPDX-License-Identifier: GPL-3.0-or-later */
/* wine-unix 0208's directory listing cache for case-insensitive lookups
 * (dlls/ntdll/unix/ios_dircase.h, taken from the patch by test_dircase_ios.py): what a
 * listing finds, which of two names that fold alike it keeps, when a listing is
 * stale or too fresh to keep, and the cache's limits. */
#include "ios_dircase.h"

#include <stdio.h>

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

/* ASCII upper-casing is enough here: the cache stores what its caller folds. */
static uint32_t up( const char *s, uint16_t *out )
{
    uint32_t n = 0;
    for (; *s; s++) out[n++] = (uint16_t)(*s >= 'a' && *s <= 'z' ? *s - 32 : *s);
    return n;
}

static int add( struct ios_dircase_dir *d, const char *name )
{
    uint16_t u[256];
    return ios_dircase_add( d, name, u, up( name, u ) );
}

static const char *find( const struct ios_dircase_dir *d, const char *name )
{
    uint16_t u[256];
    return ios_dircase_find( d, u, up( name, u ) );
}

static struct ios_dircase_key key( uint64_t ino, int64_t mtime )
{
    struct ios_dircase_key k = { 7, ino, mtime, 5, mtime, 6 };
    return k;
}

int main(void)
{
    struct ios_dircase_key k = key( 100, 1000 ), k2;
    struct ios_dircase_dir *d = ios_dircase_new( &k, 1 );
    static struct ios_dircase_cache cache;
    char name[64];

    /* A listing finds a name in any case, and only names it holds. */
    CHECK( d && add( d, "CookedPCConsole" ) && add( d, "Engine.upk" ) && add( d, "WillowGame.upk" ) );
    CHECK( find( d, "cookedpcconsole" ) && !strcmp( find( d, "COOKEDPCCONSOLE" ), "CookedPCConsole" ) );
    CHECK( !strcmp( find( d, "engine.UPK" ), "Engine.upk" ) );
    CHECK( !find( d, "Engine.up" ) && !find( d, "Engine.upk?" ) && !find( d, "" ) );
    /* Two names that fold alike: the first in directory order is the one found. */
    CHECK( add( d, "ENGINE.UPK" ) && !strcmp( find( d, "engine.upk" ), "Engine.upk" ) && d->count == 3 );
    /* Thousands of entries: the table grows and still finds each one. */
    for (int i = 0; i < 5000; i++) { snprintf( name, sizeof(name), "Pkg_%05d.upk", i ); CHECK( add( d, name ) ); }
    CHECK( d->count == 5003 && d->size >= 5003 * 4 / 3 );
    CHECK( !strcmp( find( d, "pkg_04321.UPK" ), "Pkg_04321.upk" ) && !find( d, "pkg_05000.upk" ) );
    CHECK( !strcmp( find( d, "willowgame.upk" ), "WillowGame.upk" ) );

    /* Too fresh to keep: a directory changed within 2 s of now, by mtime or ctime. */
    CHECK( ios_dircase_racy( &k, 1001, 0 ) && !ios_dircase_racy( &k, 1003, 0 ) );
    k2 = k; k2.ctime_sec = 1002;
    CHECK( ios_dircase_racy( &k2, 1003, 0 ) && ios_dircase_racy( &k, 999, 0 ) );

    /* The cache: a matching key finds the listing; any change of mtime or ctime drops it. */
    CHECK( ios_dircase_put( &cache, d ) && cache.count == 1 && cache.bytes == d->bytes );
    CHECK( ios_dircase_get( &cache, &k ) == d && cache.hits == 1 );
    k2 = k; k2.mtime_nsec++;
    CHECK( !ios_dircase_get( &cache, &k2 ) && cache.count == 0 && cache.stale == 1 && cache.bytes == 0 );
    CHECK( !ios_dircase_get( &cache, &k ) && cache.misses == 2 );

    /* At most IOS_DIRCASE_MAX_DIRS listings; the least recently used goes first. */
    for (unsigned i = 0; i < IOS_DIRCASE_MAX_DIRS; i++)
    {
        struct ios_dircase_key ki = key( 200 + i, 1000 );
        struct ios_dircase_dir *di = ios_dircase_new( &ki, 1 );
        CHECK( di && add( di, "a" ) && ios_dircase_put( &cache, di ) );
    }
    k2 = key( 200, 1000 );
    CHECK( ios_dircase_get( &cache, &k2 ) );   /* the oldest, used again */
    {
        struct ios_dircase_key kn = key( 999, 1000 );
        struct ios_dircase_dir *dn = ios_dircase_new( &kn, 1 );
        CHECK( dn && ios_dircase_put( &cache, dn ) && cache.count == IOS_DIRCASE_MAX_DIRS && cache.evicted == 1 );
    }
    CHECK( ios_dircase_get( &cache, &k2 ) );
    k2 = key( 201, 1000 );
    CHECK( !ios_dircase_get( &cache, &k2 ) );   /* the least recently used was evicted */
    /* Two threads that read the same directory: the first listing kept stays; a newer
     * key of the same directory replaces the old listing. */
    k2 = key( 200, 1000 );
    {
        struct ios_dircase_dir *dup = ios_dircase_new( &k2, 1 );
        unsigned n = cache.count;
        CHECK( dup && !ios_dircase_put( &cache, dup ) && cache.count == n );
        ios_dircase_free( dup );
        k2.mtime_sec = 2000;
        dup = ios_dircase_new( &k2, 1 );
        CHECK( dup && ios_dircase_put( &cache, dup ) && cache.count == n && ios_dircase_get( &cache, &k2 ) == dup );
    }
    /* A volume that folds case itself is kept as such: nothing to look up in it. */
    k2 = key( 300, 1000 );
    {
        struct ios_dircase_dir *ci = ios_dircase_new( &k2, 0 );
        CHECK( ci && !ci->case_sensitive && !find( ci, "a" ) );
        ios_dircase_free( ci );
    }

    if (failures) return 1;
    printf( "dircase_test: ok\n" );
    return 0;
}
