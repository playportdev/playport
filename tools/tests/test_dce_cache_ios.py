# SPDX-License-Identifier: GPL-3.0-or-later
"""NtUserGetDCEx's cache DC choice as wine-unix 0207 ships it: on iOS every pseudo-process
shares win32u's one DCE list. A process never releases a window surface of another process
that a cache DC still holds (PLA-871), and the list stays bounded as processes end."""
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

# Just enough of win32u for dce.c's alloc_dce, release_dce, free_dce, the iOS helpers and
# NtUserGetDCEx's cache search, all taken from dce.c as the pinned Wine plus the series
# makes it. A DC records the process whose window surface it holds: the GDI side releases
# that surface when the DC gets another one, and that release must happen in the surface's
# own process (on the phone the last release freed the pixels in the caller's address
# space, PLA-871). set_visible_region does nothing to a disabled DC, as in win32u.
HARNESS = r'''
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int BOOL;
typedef unsigned short WORD;
typedef unsigned int UINT, DWORD;
typedef long LONG;
typedef void *HWND, *HDC, *HRGN;
typedef struct { LONG left, top, right, bottom; } RECT;
#define TRUE 1
#define FALSE 0
#define WINE_IOS 1
#define TRACE(...) do {} while (0)
#define WARN(...) do {} while (0)
#define DCX_WINDOW 0x1
#define DCX_CACHE 0x2
#define DCX_CLIPCHILDREN 0x8
#define DCX_CLIPSIBLINGS 0x10
#define DCX_PARENTCLIP 0x20
#define DCHF_DISABLEDC 0x8
#define DCHF_ENABLEDC 0x10
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
static void list_remove( struct list *elem )
{
    elem->next->prev = elem->prev; elem->prev->next = elem->next;
}
typedef struct { struct { void *UniqueProcess, *UniqueThread; } ClientId; void *Peb; } TEB;
static TEB current;
static TEB *NtCurrentTeb(void) { return &current; }
#define HandleToULong(h) ((DWORD)(uintptr_t)(h))
static DWORD current_pid(void) { return HandleToULong( current.ClientId.UniqueProcess ); }
static LONG InterlockedIncrement( LONG *value ) { return ++*value; }
static DWORD last_error;
static DWORD RtlGetLastWin32Error(void) { return last_error; }
static void RtlSetLastWin32Error( DWORD error ) { last_error = error; }
static int user_locked;
static void user_lock(void) { assert( !user_locked ); user_locked = 1; }
static void user_unlock(void) { assert( user_locked ); user_locked = 0; }

/* the windows: their process, and whether they still exist */
#define MAX_WINDOWS 8192
struct window_surface { DWORD pid; RECT rect; };
static struct window_surface dummy_surface;
static struct { DWORD pid; BOOL alive; struct window_surface surface; } windows[MAX_WINDOWS];
static unsigned int window_count;
static HWND create_window(void)
{
    assert( window_count < MAX_WINDOWS - 1 );
    windows[++window_count].pid = current_pid();
    windows[window_count].alive = TRUE;
    windows[window_count].surface.pid = current_pid();
    return (HWND)(uintptr_t)(0x10000 + 2 * window_count);
}
static unsigned int window_index( HWND hwnd ) { return ((uintptr_t)hwnd - 0x10000) / 2; }
static DWORD get_window_thread( HWND hwnd, DWORD *process )
{
    unsigned int i = window_index( hwnd );
    if (!i || i > window_count || !windows[i].alive)
    {
        last_error = 1400;  /* ERROR_INVALID_WINDOW_HANDLE */
        return 0;
    }
    if (process) *process = windows[i].pid;
    return 0x1000 + windows[i].pid;
}
/* the surface update_visible_region gives a DC: the top window's, if it is the caller's */
static struct window_surface *window_surface_for( HWND hwnd )
{
    unsigned int i = window_index( hwnd );
    return windows[i].alive && windows[i].pid == current_pid() ? &windows[i].surface : NULL;
}

/* the DCs: whether disabled, and whose window surface each holds (0: none or the dummy) */
#define MAX_DCS 8192
typedef struct { BOOL disabled; DWORD surface; } DC;
static DC dcs[MAX_DCS];
static unsigned int dc_count, releases, forgotten;
static DC *dc_of( HDC hdc ) { return &dcs[(uintptr_t)hdc]; }
static HDC NtGdiOpenDCW( void *a, void *b, void *c, int d, BOOL e, int f, void *g, void *h )
{
    (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; (void)h;
    assert( dc_count < MAX_DCS - 1 );
    return (HDC)(uintptr_t)++dc_count;
}
static BOOL NtGdiDeleteObjectApp( void *obj ) { (void)obj; return TRUE; }
static void set_dc_dce( HDC hdc, void *dce ) { (void)hdc; (void)dce; }
static void set_dc_pixel_format_internal( HDC hdc, int format, struct list *drawables )
{
    (void)hdc; (void)format; (void)drawables;
}
static WORD set_dce_flags( HDC hdc, WORD flags )
{
    BOOL old = dc_of( hdc )->disabled;
    if (flags & DCHF_DISABLEDC) dc_of( hdc )->disabled = TRUE;
    else if (flags & DCHF_ENABLEDC) dc_of( hdc )->disabled = FALSE;
    else return FALSE;
    return old;
}
static DC *get_dc_ptr( HDC hdc ) { return dc_of( hdc )->disabled ? NULL : dc_of( hdc ); }
static void release_dc_ptr( DC *dc ) { (void)dc; }
/* the DC drops its surface's reference: in win32u its last one frees the pixels in the caller */
static void release_surface( DC *dc )
{
    if (!dc->surface) return;
    assert( dc->surface == current_pid() );  /* PLA-871 */
    releases++;
    dc->surface = 0;
}
static void set_visible_region( HDC hdc, HRGN hrgn, const RECT *vis_rect, const RECT *device_rect,
                                struct window_surface *surface )
{
    DC *dc = get_dc_ptr( hdc );
    (void)hrgn; (void)vis_rect; (void)device_rect;
    if (!dc) return;
    release_surface( dc );
    dc->surface = surface ? surface->pid : 0;
}
static void dibdrv_forget_window_surface( DC *dc )
{
    if (dc->surface) forgotten++;
    dc->surface = 0;
}
static void release_dc_driver( HWND hwnd, HDC hdc ) { (void)hwnd; (void)hdc; }
static const struct { void (*pReleaseDC)( HWND, HDC ); } driver = { release_dc_driver }, *user_driver = &driver;

STRUCT_CODE

static struct list dce_list = LIST_INIT(dce_list);
#define DCE_CACHE_SIZE 64

HELPER_CODE

RELEASE_CODE

ALLOC_CODE

FREE_CODE

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

/* NtUserGetDCEx( hwnd, 0, DCX_CACHE ) around that search: a new DC when it finds none */
static struct dce *get_dc( HWND hwnd, BOOL *update )
{
    struct dce *dce = cache_dce( hwnd, DCX_CACHE, update );
    if (!dce)
    {
        dce = alloc_dce();
        assert( dce );
        dce->flags = DCX_CACHE;
        list_add_head( &dce_list, &dce->entry );
    }
    dce->hwnd = hwnd;
    if (*update) set_visible_region( dce->hdc, 0, &dummy_surface.rect, &dummy_surface.rect,
                                     window_surface_for( hwnd ) );
    return dce;
}

/* release_dc for a cache DC */
static void release_dc( struct dce *dce )
{
    dce->count = 0;
    set_dce_flags( dce->hdc, DCHF_DISABLEDC );
}

/* a process ends: its windows go, with free_dce run (DestroyWindow) or not (it died) */
static void end_process( DWORD pid, BOOL destroys_windows )
{
    unsigned int i;
    for (i = 1; i <= window_count; i++)
    {
        if (windows[i].pid != pid || !windows[i].alive) continue;
        if (destroys_windows) free_dce( NULL, (HWND)(uintptr_t)(0x10000 + 2 * i), NULL );
        windows[i].alive = FALSE;
    }
}

static unsigned int list_length(void)
{
    unsigned int n = 0;
    struct list *e;
    for (e = dce_list.next; e != &dce_list; e = e->next) n++;
    return n;
}

/* a process paints DCE_CACHE_SIZE windows at once, then releases their DCs */
static void paint_full_cache( struct dce **dces )
{
    BOOL update;
    int i;
    for (i = 0; i < DCE_CACHE_SIZE; i++)
    {
        dces[i] = get_dc( create_window(), &update );
        assert( dces[i]->count == 1 && dc_of( dces[i]->hdc )->surface == current_pid() );
    }
    for (i = 0; i < DCE_CACHE_SIZE; i++) release_dc( dces[i] );
}

/* a hundred processes each fill the cache; every second one dies, the others destroy
 * their windows: the shared list stays one cache, and no process releases a surface of
 * another (release_surface asserts it) */
static int bounded(void)
{
    struct dce *dces[DCE_CACHE_SIZE];
    unsigned int p, i, dying = 0;

    for (p = 0; p < 100; p++)
    {
        as_process( 0x100 + 4 * p, 0x140000000 + 0x1000 * p );
        paint_full_cache( dces );
        assert( list_length() == DCE_CACHE_SIZE );
        end_process( 0x100 + 4 * p, p % 2 );
        if (!(p % 2)) dying++;
        else for (i = 0; i < DCE_CACHE_SIZE; i++)
        {
            /* DestroyWindow left each DC empty: it released its surface in its own process */
            assert( !dces[i]->hwnd && !dc_of( dces[i]->hdc )->surface && dc_of( dces[i]->hdc )->disabled );
        }
    }
    /* only the DCs a dead process left still held its surfaces; each was forgotten, once */
    assert( forgotten == dying * DCE_CACHE_SIZE );
    return 0;
}

/* PLA-871: a full cache of another process's DCs on its live windows, each holding that
 * window's surface; the next process gets a new DC and leaves them as they are */
static int live(void)
{
    struct dce *other[DCE_CACHE_SIZE], *dce;
    BOOL update;
    int i;

    as_process( 0x70, 0x142794000 );
    paint_full_cache( other );

    as_process( 0xbc, 0x1437cc000 );
    dce = get_dc( create_window(), &update );
    assert( list_length() == DCE_CACHE_SIZE + 1 );
    for (i = 0; i < DCE_CACHE_SIZE; i++)
        assert( dce != other[i] && !other[i]->count && dc_of( other[i]->hdc )->surface == 0x70 );

    /* a process with the first one's pid and another PEB is another process */
    as_process( 0x70, 0x1437cc000 );
    dce = get_dc( create_window(), &update );
    assert( list_length() == DCE_CACHE_SIZE + 2 );
    for (i = 0; i < DCE_CACHE_SIZE; i++) assert( dce != other[i] );
    assert( !forgotten );
    return 0;
}

/* a process's own released DC for the same window is taken again, its region kept, and
 * with its own cache full it reuses its own oldest unused DC */
static int own(void)
{
    struct dce *own[DCE_CACHE_SIZE], *dce;
    HWND hwnd;
    BOOL update;

    as_process( 0xbc, 0x1437cc000 );
    paint_full_cache( own );
    hwnd = own[5]->hwnd;
    assert( get_dc( hwnd, &update ) == own[5] && !update && own[5]->count == 1 );
    release_dc( own[5] );
    dce = get_dc( create_window(), &update );
    assert( dce == own[0] && update && list_length() == DCE_CACHE_SIZE );
    assert( releases == 1 && !forgotten );  /* own[0]'s window surface, in its own process */
    return 0;
}

/* another process's DC whose window went with its process, and an empty one of a live
 * process, are taken; the first one's surface is forgotten, not released */
static int ended(void)
{
    struct dce *dead[DCE_CACHE_SIZE], *alive[2], *dce;
    HWND gone;
    BOOL update;
    int i;

    as_process( 0x70, 0x142794000 );
    paint_full_cache( dead );
    end_process( 0x70, FALSE );

    as_process( 0xbc, 0x1437cc000 );
    dce = get_dc( create_window(), &update );
    assert( dce == dead[0] && update && dc_of( dce->hdc )->surface == 0xbc && forgotten == 1 );
    assert( list_length() == DCE_CACHE_SIZE );
    release_dc( dce );
    /* it is the taker's now */
    assert( get_dc( dce->hwnd, &update ) == dce && !update );
    release_dc( dce );

    as_process( 0xd0, 0x1440ae000 );
    for (i = 0; i < 2; i++) alive[i] = get_dc( create_window(), &update );
    for (i = 0; i < 2; i++) release_dc( alive[i] );
    gone = alive[1]->hwnd;
    free_dce( NULL, gone, NULL );
    windows[window_index( gone )].alive = FALSE;

    /* the next process takes the empty DC; it held no surface to forget */
    assert( forgotten == 3 );
    as_process( 0xe4, 0x1442f0000 );
    dce = get_dc( create_window(), &update );
    assert( dce == alive[1] && forgotten == 3 );
    /* the live process's DC on its live window is left holding its surface */
    assert( !alive[0]->count && dc_of( alive[0]->hdc )->surface == 0xd0 );
    return 0;
}

int main( int argc, char **argv )
{
    assert( argc == 2 );
    if (!strcmp( argv[1], "bounded" )) return bounded();
    if (!strcmp( argv[1], "live" )) return live();
    if (!strcmp( argv[1], "own" )) return own();
    if (!strcmp( argv[1], "ended" )) return ended();
    return 2;
}
'''


def between(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i) + len(end)]


class DCECacheIOS(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        cls._tmp = tempfile.TemporaryDirectory(prefix="dce-cache-", dir=work)
        root = Path(cls._tmp.name)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        if not wow64_test.patched_upstream_files(wow64_test.BUILD / "cache/wine.git", wow64_test.pin("wine"),
                                                 ["wine-port", "wine-valve", "wine-unix"], [SOURCE], root):
            cls.exe = None
            return
        code = (root / SOURCE).read_text()
        helpers = "".join(wow64_test.c_function(code, name) for name in
                          ("is_current_process_dce", "is_live_other_process_dce", "take_other_process_dce"))
        source = (HARNESS.replace("STRUCT_CODE", between(code, "struct dce\n{", "\n};\n"))
                  .replace("HELPER_CODE", helpers)
                  .replace("RELEASE_CODE", wow64_test.c_function(code, "release_dce"))
                  .replace("ALLOC_CODE", between(code, "static struct dce *alloc_dce(void)", "\n}\n"))
                  .replace("FREE_CODE", between(code, "\nvoid free_dce(", "\n}\n"))
                  .replace("SEARCH_CODE", between(code, "        struct dce *dceEmpty = NULL",
                                                  "        user_unlock();\n")))
        (root / "test.c").write_text(source)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                        "-o", str(root / "test"), str(root / "test.c")],
                       check=True, capture_output=True)
        cls.exe = root / "test"

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def run_case(self, name):
        if not self.exe:
            self.skipTest("no Wine cache in $PLAYPORT_BUILD/cache")
        run = subprocess.run([str(self.exe), name], capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stderr)
        return run

    def test_the_list_stays_one_cache_as_processes_end(self):
        self.assertEqual(self.run_case("bounded").stderr, "")

    def test_another_process_s_dcs_on_its_live_windows_are_not_taken(self):
        # the skip is logged, naming that process's oldest DC
        self.assertEqual(self.run_case("live").stderr.splitlines()[0],
                         "[dce] pid 00bc: a full DC cache, 64 DCs of other processes not taken "
                         "(the oldest unused: pid 0070, hwnd 0x10002)")

    def test_a_process_reuses_its_own_dcs(self):
        self.run_case("own")

    def test_an_ended_process_s_dcs_and_empty_ones_are_taken(self):
        self.run_case("ended")


if __name__ == "__main__":
    unittest.main()
