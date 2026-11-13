# SPDX-License-Identifier: GPL-3.0-or-later
"""flush_window_surfaces as wine-unix 0206 ships it: on iOS every pseudo-process shares
win32u's one surface list, and a process flushes only its own windows' surfaces (PLA-870),
throttled by its own thread's idle time, not another process's."""
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

# Just enough of win32u for dce.c's flush_window_surfaces, taken from dce.c as the pinned
# Wine plus the series makes it. Two pseudo-processes' surfaces share the
# list, as in the one app process: one of a process that ended while a thread of it
# held its surface's lock (the Borderlands 2 prerequisites' run), one of the caller.
# The tick count stands still, so a non-idle flush is due only to a thread that has not
# gone idle itself.
HARNESS = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>
#include <time.h>
typedef int BOOL;
typedef unsigned int DWORD;
typedef void *HWND;
#define TRUE 1
#define FALSE 0
#define WINE_IOS 1
struct list { struct list *next, *prev; };
#define LIST_ENTRY_OF(ptr, type, field) ((type *)((char *)(ptr) - offsetof(type, field)))
#define LIST_FOR_EACH_ENTRY(elem, list, type, field) \
    for ((elem) = LIST_ENTRY_OF((list)->next, type, field); &(elem)->field != (list); \
         (elem) = LIST_ENTRY_OF((elem)->field.next, type, field))
struct window_surface { struct list entry; HWND hwnd; pthread_mutex_t mutex; int flushed; };
static struct list window_surfaces = { &window_surfaces, &window_surfaces };
static pthread_mutex_t surfaces_lock = PTHREAD_MUTEX_INITIALIZER;

static struct window_surface ended = { .hwnd = (HWND)0x20034, .mutex = PTHREAD_MUTEX_INITIALIZER };
static struct window_surface own = { .hwnd = (HWND)0x40042, .mutex = PTHREAD_MUTEX_INITIALIZER };
static __thread DWORD current_pid;
struct user_thread_info { DWORD last_idle; };
static __thread struct user_thread_info thread_info;
static struct user_thread_info *get_user_thread_info(void) { return &thread_info; }

static DWORD NtGetTickCount(void) { return 1000; }
/* the user handle table's owner of each window: 0xbc ended, 0xd0 calls */
static HWND is_current_process_window( HWND hwnd )
{
    DWORD pid = hwnd == ended.hwnd ? 0xbc : hwnd == own.hwnd ? 0xd0 : 0;
    return pid == current_pid ? hwnd : NULL;
}
static void window_surface_flush( struct window_surface *surface )
{
    pthread_mutex_lock( &surface->mutex );
    surface->flushed++;
    pthread_mutex_unlock( &surface->mutex );
}

PATCH_CODE

static void add( struct window_surface *surface )
{
    surface->entry.next = &window_surfaces;
    surface->entry.prev = window_surfaces.prev;
    window_surfaces.prev->next = &surface->entry;
    window_surfaces.prev = &surface->entry;
}
static void *dies_holding_its_lock( void *arg ) { pthread_mutex_lock( &ended.mutex ); return arg; }
static void *message_wait( void *arg ) { current_pid = 0xd0; flush_window_surfaces( TRUE ); return arg; }

static int lock_of_an_ended_process(void)
{
    pthread_t t;
    struct timespec deadline;

    add( &ended );
    add( &own );
    pthread_create( &t, NULL, dies_holding_its_lock, NULL );
    pthread_join( t, NULL );

    /* the caller's idle flush returns: it never waits on the ended process's lock */
    pthread_create( &t, NULL, message_wait, NULL );
    clock_gettime( CLOCK_REALTIME, &deadline );
    deadline.tv_sec += 5;
    assert( pthread_timedjoin_np( t, NULL, &deadline ) == 0 );
    /* and it flushed its own window, not the other process's */
    assert( own.flushed == 1 );
    assert( ended.flushed == 0 );
    /* the list's lock is free again, for the next window that registers a surface */
    assert( pthread_mutex_trylock( &surfaces_lock ) == 0 );
    return 0;
}

static void *other_process_idles( void *arg ) { current_pid = 0xbc; flush_window_surfaces( TRUE ); return arg; }
static void *paints_without_idling( void *arg ) { current_pid = 0xd0; flush_window_surfaces( FALSE ); return arg; }

static int idle_of_another_process(void)
{
    pthread_t t;

    add( &ended );
    add( &own );
    /* another process's thread just went idle */
    pthread_create( &t, NULL, other_process_idles, NULL );
    pthread_join( t, NULL );
    assert( ended.flushed == 1 && own.flushed == 0 );

    /* a thread of the caller that never goes idle still flushes its own surface */
    pthread_create( &t, NULL, paints_without_idling, NULL );
    pthread_join( t, NULL );
    assert( own.flushed == 1 && ended.flushed == 1 );

    /* and a thread that just went idle itself waits the 50 ms before a non-idle flush */
    current_pid = 0xd0;
    flush_window_surfaces( TRUE );
    assert( own.flushed == 2 );
    flush_window_surfaces( FALSE );
    assert( own.flushed == 2 && ended.flushed == 1 );
    return 0;
}

int main( int argc, char **argv )
{
    assert( argc == 2 );
    if (!strcmp( argv[1], "lock" )) return lock_of_an_ended_process();
    if (!strcmp( argv[1], "idle" )) return idle_of_another_process();
    return 2;
}
'''


class WindowSurfacesIOS(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        cls._tmp = tempfile.TemporaryDirectory(prefix="window-surfaces-", dir=work)
        root = Path(cls._tmp.name)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        if not wow64_test.patched_upstream_files(wow64_test.BUILD / "cache/wine.git", wow64_test.pin("wine"),
                                                 ["wine-port", "wine-valve", "wine-unix"], [SOURCE], root):
            cls.exe = None
            return
        text = (root / SOURCE).read_text()
        start = text.index("void flush_window_surfaces( BOOL idle )")
        code = text[start:text.index("\n}\n", start) + 3]
        (root / "test.c").write_text(HARNESS.replace("PATCH_CODE", code))
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-pthread",
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

    def test_a_process_flushes_only_its_own_windows_surfaces(self):
        self.run_case("lock")

    def test_another_process_going_idle_does_not_hold_back_the_caller_s_flush(self):
        self.run_case("idle")

if __name__ == "__main__":
    unittest.main()
