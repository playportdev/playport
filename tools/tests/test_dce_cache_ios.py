# SPDX-License-Identifier: GPL-3.0-or-later
"""NtUserGetDCEx's cache DC choice as wine-unix 0207 ships it: on iOS every pseudo-process
shares win32u's one DCE list, and a process takes only its own cache DCs (PLA-871)."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SOURCE = "dlls/win32u/dce.c"
_spec = importlib.util.spec_from_file_location("wow64_test", REPO / "build/wow64/test.py")
wow64_test = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wow64_test)

# Just enough of win32u for dce.c's alloc_dce and NtUserGetDCEx's cache search, both taken
# from dce.c as the pinned Wine plus the series makes it. The cache is full of the DCs of a
# process that ended: on the phone such a DC still held its window's surface, whose pixels
# were at an address in a WoW64 window the next 32-bit process reused, and the process that
# took the DC over freed its own window's pixels when it dropped that surface.
HARNESS = r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef int BOOL;
typedef unsigned int UINT, DWORD;
typedef long LONG;
typedef void *HWND, *HDC, *HRGN;
#define TRUE 1
#define FALSE 0
#define WINE_IOS 1
#define TRACE(...) do {} while (0)
#define DCX_WINDOW 0x1
#define DCX_CACHE 0x2
#define DCX_CLIPCHILDREN 0x8
#define DCX_CLIPSIBLINGS 0x10
#define DCX_PARENTCLIP 0x20
#define DCHF_ENABLEDC 0x4
struct list { struct list *next, *prev; };
#define LIST_INIT(list) { &(list), &(list) }
#define LIST_ENTRY_OF(ptr, type, field) ((type *)((char *)(ptr) - offsetof(type, field)))
#define LIST_FOR_EACH_ENTRY(elem, list, type, field) \
    for ((elem) = LIST_ENTRY_OF((list)->next, type, field); &(elem)->field != (list); \
         (elem) = LIST_ENTRY_OF((elem)->field.next, type, field))
static void list_add_head( struct list *list, struct list *elem )
{
    elem->next = list->next; elem->prev = list; list->next->prev = elem; list->next = elem;
}
typedef struct { struct { void *UniqueProcess, *UniqueThread; } ClientId; void *Peb; } TEB;
static TEB current;
static TEB *NtCurrentTeb(void) { return &current; }
#define HandleToULong(h) ((DWORD)(uintptr_t)(h))
static LONG InterlockedIncrement( LONG *value ) { return ++*value; }
static int user_locked;
static void user_lock(void) { assert( !user_locked ); user_locked = 1; }
static void user_unlock(void) { assert( user_locked ); user_locked = 0; }
static uintptr_t next_hdc = 0x10000;
static HDC NtGdiOpenDCW( void *a, void *b, void *c, int d, BOOL e, int f, void *g, void *h )
{
    (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; (void)h;
    return (HDC)(next_hdc += 4);
}
static void set_dc_dce( HDC hdc, void *dce ) { (void)hdc; (void)dce; }
static BOOL set_dce_flags( HDC hdc, DWORD flags ) { (void)hdc; (void)flags; return FALSE; }

STRUCT_CODE

static struct list dce_list = LIST_INIT(dce_list);
#define DCE_CACHE_SIZE 64

HELPER_CODE

ALLOC_CODE

/* the cache search of NtUserGetDCEx, as it stands in the function */
static struct dce *cache_dce( HWND hwnd, DWORD flags, BOOL *update_vis_rgn_out )
{
    const DWORD clip_flags = DCX_PARENTCLIP | DCX_CLIPSIBLINGS | DCX_CLIPCHILDREN | DCX_WINDOW;
    BOOL update_vis_rgn = TRUE;
    struct dce *dce;
    {
SEARCH_CODE
    }
    *update_vis_rgn_out = update_vis_rgn;
    return dce;
}

static void as_process( DWORD pid, uintptr_t peb )
{
    current.ClientId.UniqueProcess = (void *)(uintptr_t)pid;
    current.Peb = (void *)peb;
}

/* a cache DC the process took for hwnd and released, as release_dc leaves it */
static struct dce *released_cache_dc( HWND hwnd )
{
    struct dce *dce = alloc_dce();
    assert( dce );
    dce->flags = DCX_CACHE;
    dce->hwnd = hwnd;
    dce->count = 0;
    list_add_head( &dce_list, &dce->entry );
    return dce;
}

int main(void)
{
    struct dce *ended[DCE_CACHE_SIZE], *own[DCE_CACHE_SIZE], *dce;
    BOOL update;
    int i;

    /* a process that ended (VCREDI~1.EXE) left a full cache of released DCs */
    as_process( 0x70, 0x142794000 );
    for (i = 0; i < DCE_CACHE_SIZE; i++) ended[i] = released_cache_dc( (HWND)(uintptr_t)(0x10040 + 2 * i) );

    /* the next process (VCREDI~3.EXE) gets a new DC, not one of those */
    as_process( 0xbc, 0x1437cc000 );
    assert( !cache_dce( (HWND)0x20034, DCX_CACHE, &update ) );
    for (i = 0; i < DCE_CACHE_SIZE; i++) assert( ended[i]->count == 0 );

    /* a process with the ended one's pid but another PEB is another process */
    as_process( 0x70, 0x1437cc000 );
    assert( !cache_dce( (HWND)0x10040, DCX_CACHE, &update ) );

    /* its own released DC for the same window is taken again, its region kept */
    as_process( 0xbc, 0x1437cc000 );
    dce = released_cache_dc( (HWND)0x20034 );
    assert( cache_dce( (HWND)0x20034, DCX_CACHE, &update ) == dce && !update && dce->count == 1 );
    dce->count = 0;

    /* and once its own cache is full, it reuses its own oldest unused DC */
    own[0] = dce;
    for (i = 1; i < DCE_CACHE_SIZE; i++) own[i] = released_cache_dc( (HWND)(uintptr_t)(0x20100 + 2 * i) );
    assert( cache_dce( (HWND)0x20500, DCX_CACHE, &update ) == own[0] && update );
    for (i = 0; i < DCE_CACHE_SIZE; i++) assert( ended[i]->count == 0 );
    return 0;
}
'''


def between(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i) + len(end)]


class DCECacheIOS(unittest.TestCase):
    def test_a_process_takes_only_its_own_cache_dcs(self):
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="dce-cache-", dir=work) as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q", tmp], check=True)
            if not wow64_test.patched_upstream_files(wow64_test.BUILD / "cache/wine.git", wow64_test.pin("wine"),
                                                     ["wine-port", "wine-valve", "wine-unix"], [SOURCE], root):
                self.skipTest("no Wine cache in $PLAYPORT_BUILD/cache")
            code = (root / SOURCE).read_text()
            struct = between(code, "struct dce\n{", "\n};\n")
            helper = between(code, "static BOOL is_current_process_dce(", "\n}\n")
            alloc = between(code, "static struct dce *alloc_dce(void)", "\n}\n")
            search = between(code, "        struct dce *dceEmpty = NULL",
                             "        user_unlock();\n")
            source = (HARNESS.replace("STRUCT_CODE", struct).replace("HELPER_CODE", helper)
                      .replace("ALLOC_CODE", alloc).replace("SEARCH_CODE", search))
            (root / "test.c").write_text(source)
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                            "-o", str(root / "test"), str(root / "test.c")],
                           check=True, capture_output=True)
            run = subprocess.run([str(root / "test")], check=True, capture_output=True, text=True, timeout=30)
        # the skip is logged, naming the ended process's oldest DC
        self.assertEqual(run.stderr.splitlines()[0],
                         "[dce] pid 00bc: a full DC cache, 64 DCs of other processes not taken "
                         "(the oldest unused: pid 0070, hwnd 0x10040)")


if __name__ == "__main__":
    unittest.main()
