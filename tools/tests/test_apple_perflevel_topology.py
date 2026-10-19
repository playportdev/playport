# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the Apple silicon topology shipped by wine-unix 0043 (PLA-392): the hw.perflevelN
reading and the table built from it, taken verbatim from the patch's added lines, against
sysctl values given here, with Wine's logical_proc_info_add_* recorded instead of stored."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PATCH = next((REPO / "patches/wine-unix").glob("0043-*.patch"))


def patch_code():
    added = "\n".join(line[1:] for line in PATCH.read_text().splitlines()
                      if line.startswith("+") and not line.startswith("+++")) + "\n"
    begin = added.index("#define APPLE_MAX_PERFLEVELS")
    create = added.index("static NTSTATUS create_apple_perflevel_info(")
    return added[begin:added.index("\n}\n", create) + 3]


# Just enough of Wine's types and of system.c's helpers for the patch's functions.
HARNESS = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef long long LONGLONG; typedef uintptr_t ULONG_PTR; typedef uint32_t DWORD, ULONG;
typedef uint8_t BYTE; typedef uint16_t WORD; typedef int BOOL; typedef int NTSTATUS;
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS 0
#define STATUS_NO_MEMORY 0xc0000017
#define ERR(...) printf(__VA_ARGS__)
typedef enum { CacheUnified, CacheInstruction, CacheData, CacheTrace } PROCESSOR_CACHE_TYPE;
typedef struct { BYTE Level; BYTE Associativity; WORD LineSize; DWORD Size; PROCESSOR_CACHE_TYPE Type; } CACHE_DESCRIPTOR;
typedef enum { RelationProcessorCore, RelationNumaNode, RelationCache, RelationProcessorPackage, RelationGroup } LOGICAL_PROCESSOR_RELATIONSHIP;
static ULONG cpu_count;

/* sysctlbyname over a table; an entry of size 4 is an int, of size 8 a 64-bit value */
struct sysctl_value { const char *name; long long value; size_t size; };
static const struct sysctl_value *sysctls;
static int sysctlbyname( const char *name, void *old, size_t *oldlen, void *new, size_t newlen )
{
    for (const struct sysctl_value *v = sysctls; v && v->name; v++)
        if (!strcmp( v->name, name ))
        {
            if (*oldlen < v->size) return -1;
            memcpy( old, &v->value, v->size );
            *oldlen = v->size;
            return 0;
        }
    return -1;
}

struct entry { LOGICAL_PROCESSOR_RELATIONSHIP rel; DWORD id; ULONG_PTR mask; CACHE_DESCRIPTOR cache; };
static struct entry entries[64];
static unsigned int entry_count, group_cpus;
static ULONG_PTR group_mask;

static BOOL logical_proc_info_add_by_id( LOGICAL_PROCESSOR_RELATIONSHIP rel, DWORD id, ULONG_PTR mask )
{
    for (unsigned int i = 0; i < entry_count; i++)
        if (entries[i].rel == rel && entries[i].id == id)
        {
            if (rel == RelationProcessorPackage) entries[i].mask |= mask;
            return TRUE;
        }
    entries[entry_count++] = (struct entry){ rel, id, mask };
    return TRUE;
}
static BOOL logical_proc_info_add_cache( ULONG_PTR mask, CACHE_DESCRIPTOR *cache )
{
    for (unsigned int i = 0; i < entry_count; i++)
        if (entries[i].rel == RelationCache && entries[i].mask == mask && entries[i].cache.Level == cache->Level
            && entries[i].cache.Type == cache->Type)
            return TRUE;
    entries[entry_count++] = (struct entry){ RelationCache, 0, mask, *cache };
    return TRUE;
}
static BOOL logical_proc_info_add_numa_node( ULONG_PTR mask, DWORD node_id )
{
    entries[entry_count++] = (struct entry){ RelationNumaNode, node_id, mask };
    return TRUE;
}
static void logical_proc_info_add_group( DWORD num_cpus, ULONG_PTR mask )
{
    group_cpus = num_cpus;
    group_mask = mask;
}
'''

DRIVER = r'''
static CACHE_DESCRIPTOR defaults[10];

/* The topology for the table, or 0 when the patch falls back to the equal-cluster code. */
static int build( const struct sysctl_value *table, ULONG cpus )
{
    struct apple_perflevel levels[APPLE_MAX_PERFLEVELS];
    unsigned int count;

    sysctls = table;
    cpu_count = cpus;
    entry_count = group_cpus = 0;
    group_mask = 0;
    memset( defaults, 0, sizeof(defaults) );
    defaults[1] = (CACHE_DESCRIPTOR){ 1, 8, 128, 131072, CacheInstruction };
    defaults[2] = (CACHE_DESCRIPTOR){ 1, 8, 128, 65536, CacheData };
    defaults[3] = (CACHE_DESCRIPTOR){ 2, 8, 128, 6291456, CacheUnified };
    if (!read_apple_perflevels( levels, &count )) return 0;
    assert( create_apple_perflevel_info( levels, count, defaults ) == STATUS_SUCCESS );
    return 1;
}

static void dump( void )
{
    for (unsigned int i = 0; i < entry_count; i++)
    {
        const struct entry *e = &entries[i];
        if (e->rel == RelationCache)
            printf( "cache L%u type %u size %u mask %lx\n", e->cache.Level, e->cache.Type, e->cache.Size,
                    (unsigned long)e->mask );
        else
            printf( "rel %u id %u mask %lx\n", e->rel, e->id, (unsigned long)e->mask );
    }
    printf( "group %u mask %lx\n", group_cpus, (unsigned long)group_mask );
}

int main( void )
{
    /* iPhone18,4's values, as the patch logged them on the phone (2026-10-19): level 0 the
     * 2 P cores, level 1 the 4 E cores; as ints */
    static const struct sysctl_value phone[] = {
        { "hw.nperflevels", 2, 4 },
        { "hw.perflevel0.logicalcpu", 2, 4 }, { "hw.perflevel0.physicalcpu", 2, 4 },
        { "hw.perflevel0.cpusperl2", 2, 4 }, { "hw.perflevel0.l1icachesize", 196608, 4 },
        { "hw.perflevel0.l1dcachesize", 131072, 4 }, { "hw.perflevel0.l2cachesize", 16777216, 4 },
        { "hw.perflevel1.logicalcpu", 4, 4 }, { "hw.perflevel1.physicalcpu", 4, 4 },
        { "hw.perflevel1.cpusperl2", 4, 4 }, { "hw.perflevel1.l1icachesize", 131072, 4 },
        { "hw.perflevel1.l1dcachesize", 65536, 4 }, { "hw.perflevel1.l2cachesize", 6291456, 4 },
        { NULL }
    };
    /* two L2s in one level, 64-bit values, and a level with no sizes (the defaults then) */
    static const struct sysctl_value split[] = {
        { "hw.nperflevels", 2, 8 },
        { "hw.perflevel0.logicalcpu", 4, 8 }, { "hw.perflevel0.physicalcpu", 4, 8 },
        { "hw.perflevel0.cpusperl2", 2, 8 },
        { "hw.perflevel1.logicalcpu", 2, 8 }, { "hw.perflevel1.physicalcpu", 2, 8 },
        { "hw.perflevel1.cpusperl2", 2, 8 }, { "hw.perflevel1.l2cachesize", 4194304, 8 },
        { NULL }
    };
    static const struct sysctl_value smt[] = {
        { "hw.nperflevels", 1, 4 },
        { "hw.perflevel0.logicalcpu", 8, 4 }, { "hw.perflevel0.physicalcpu", 4, 4 },
        { NULL }
    };
    unsigned int i, cores = 0;
    ULONG_PTR cores_mask = 0;

    assert( build( phone, 6 ) );
    dump();
    for (i = 0; i < entry_count; i++)
    {
        const struct entry *e = &entries[i];
        assert( !(e->mask & ~(ULONG_PTR)0x3f) );
        if (e->rel == RelationProcessorCore)
        {
            assert( e->mask == (ULONG_PTR)1 << e->id );
            cores++;
            cores_mask |= e->mask;
        }
        if (e->rel == RelationProcessorPackage) assert( e->mask == 0x3f );
        if (e->rel != RelationCache) continue;
        /* processors 0-3 are level 1 (E), 4-5 level 0 (P) */
        if (e->cache.Level == 2)
            assert( (e->mask == 0x0f && e->cache.Size == 6291456) || (e->mask == 0x30 && e->cache.Size == 16777216) );
        else if (e->mask & 0x0f)
            assert( e->cache.Size == (e->cache.Type == CacheInstruction ? 131072 : 65536) );
        else
            assert( e->cache.Size == (e->cache.Type == CacheInstruction ? 196608 : 131072) );
    }
    assert( cores == 6 && cores_mask == 0x3f && group_cpus == 6 && group_mask == 0x3f );

    assert( build( split, 6 ) );
    dump();
    for (i = 0; i < entry_count; i++)
        if (entries[i].rel == RelationCache && entries[i].cache.Level == 2)
            assert( (entries[i].mask == 0x03 && entries[i].cache.Size == 4194304)
                    || ((entries[i].mask == 0x0c || entries[i].mask == 0x30) && entries[i].cache.Size == 6291456) );
        else if (entries[i].rel == RelationCache)
            assert( entries[i].cache.Size == defaults[entries[i].cache.Type == CacheInstruction ? 1 : 2].Size );

    /* the equal-cluster code keeps the rest */
    assert( !build( phone, 4 ) );  /* madeira.cfg cpu-count below the phone's */
    assert( !build( smt, 8 ) );    /* more threads than cores */
    assert( !build( NULL, 6 ) );   /* no perf levels: an Intel Mac */
    printf( "ok\n" );
    return 0;
}
'''


class ApplePerflevelTopology(unittest.TestCase):
    def test_clusters_from_perf_levels(self):
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="apple-perflevels-", dir=work) as tmp:
            root = Path(tmp)
            (root / "test.c").write_text(HARNESS + patch_code() + DRIVER)
            build = subprocess.run(["cc", "-std=c11", "-Wall", "-Werror", "-Wno-unused-function",
                                    "-Wno-unused-parameter", "-o", str(root / "test"), str(root / "test.c")],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(root / "test")], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        out = run.stdout
        self.assertIn("Playport: processor topology from 2 perf levels; level 1 processors 0-3 l1i 131072 "
                      "l1d 65536 l2 6291456 by 4; level 0 processors 4-5 l1i 196608 l1d 131072 l2 16777216 by 2",
                      out)
        self.assertIn("cache L2 type 0 size 6291456 mask f\n", out)
        self.assertIn("cache L2 type 0 size 16777216 mask 30\n", out)
        self.assertNotIn("mask f0", out)
        self.assertTrue(out.endswith("ok\n"))


if __name__ == "__main__":
    unittest.main()
