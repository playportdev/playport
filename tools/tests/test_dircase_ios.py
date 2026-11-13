# SPDX-License-Identifier: GPL-3.0-or-later
"""wine-unix 0208 and 0209 (PLA-879): ntdll's case-insensitive lookups through a cache of
directory listings, a walk that starts at the last component when the rest exists as named,
and a miss under a kept directory answered from its listing after one stat.

The cache (dlls/ntdll/unix/ios_dircase.h) is tested alone (dircase_ios_test.c). Then
find_file_in_dir, lookup_unix_name and the patch's iOS block, as file.c is with the series
applied, resolve paths over a real directory tree: in any case, missing, created, and with
a directory changed after its listing was kept."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PATCHES = sorted((REPO / "patches/wine-unix").glob("020[89]-ntdll-iOS-*.patch"))
SOURCE = "dlls/ntdll/unix/file.c"
HEADER = "dlls/ntdll/unix/ios_dircase.h"
_spec = importlib.util.spec_from_file_location("wow64_test", REPO / "build/wow64/test.py")
wow64_test = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wow64_test)

# Just enough of ntdll's unix side for those functions. Names are ASCII here, so the
# multibyte conversions and the case table are ASCII; get_dir_case_sensitivity counts its
# calls, which the scan without the cache makes once per search.
HARNESS = r'''
#define _GNU_SOURCE
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
typedef uint16_t WCHAR;
typedef WCHAR *LPWSTR;
typedef const WCHAR *LPCWSTR;
typedef unsigned char BOOLEAN;
typedef int BOOL;
typedef unsigned int UINT, ULONG;
typedef unsigned int NTSTATUS;
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS 0
#define STATUS_NO_SUCH_FILE 0xc000000f
#define STATUS_NO_MEMORY 0xc0000017
#define STATUS_OBJECT_NAME_INVALID 0xc0000033
#define STATUS_OBJECT_NAME_NOT_FOUND 0xc0000034
#define STATUS_OBJECT_NAME_COLLISION 0xc0000035
#define STATUS_OBJECT_PATH_NOT_FOUND 0xc000003a
#define FILE_OPEN 1
#define FILE_CREATE 2
#define FILE_OVERWRITE 4
#define MAX_DIR_ENTRY_LEN 255
#define INVALID_NT_CHARS   '*','?','<','>','|','"'
#define INVALID_DOS_CHARS  INVALID_NT_CHARS,'+','=',',',';','[',']',' ','\345'
#define TRACE(...) do {} while (0)
#define WARN(...) do {} while (0)
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { ULONG Length; void *RootDirectory; UNICODE_STRING *ObjectName; } OBJECT_ATTRIBUTES;
struct client_id { void *UniqueProcess, *UniqueThread; };
struct teb { struct client_id ClientId; };
static struct teb the_teb = { { (void *)0x8c, (void *)0x90 } };
static struct teb *NtCurrentTeb(void) { return &the_teb; }
#define HandleToULong(h) ((ULONG)(uintptr_t)(h))
static void mutex_lock( pthread_mutex_t *m ) { pthread_mutex_lock( m ); }
static void mutex_unlock( pthread_mutex_t *m ) { pthread_mutex_unlock( m ); }
static WCHAR ntdll_towupper( WCHAR c ) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
#define towlower test_towlower
static WCHAR towlower( WCHAR c ) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static int wcsnicmp( const WCHAR *a, const WCHAR *b, int n )
{
    int r = 0;
    for (; n > 0; n--, a++, b++) if ((r = ntdll_towupper( *a ) - ntdll_towupper( *b )) || !*a) break;
    return r;
}
static const WCHAR *wcschr( const WCHAR *s, WCHAR c ) { for (; *s; s++) if (*s == c) return s; return NULL; }
static int ntdll_wcstoumbs( const WCHAR *src, int len, char *dst, int dstlen, BOOL strict )
{
    (void)strict;
    if (len > dstlen) return -1;
    for (int i = 0; i < len; i++) dst[i] = (char)src[i];
    return len;
}
static int ntdll_umbstowcs( const char *src, int len, WCHAR *dst, int dstlen )
{
    if (len > dstlen) return -1;
    for (int i = 0; i < len; i++) dst[i] = (unsigned char)src[i];
    return len;
}
static NTSTATUS errno_to_status( int err ) { (void)err; return STATUS_OBJECT_NAME_NOT_FOUND; }
static int is_case_sensitive = 1;
static int is_invalid_dos_char( WCHAR c ) { static const WCHAR bad[] = { INVALID_DOS_CHARS, 0 }; return wcschr( bad, c ) != NULL; }
static int case_queries;
static BOOLEAN get_dir_case_sensitivity( int root_fd, const char *dir ) { (void)root_fd; (void)dir; case_queries++; return TRUE; }
static int reparse_calls;
static NTSTATUS resolve_reparse_point( int fd, int root_fd, OBJECT_ATTRIBUTES *attr, UNICODE_STRING *nt_name,
                                       unsigned int nt_pos, int len, char **buffer, int unix_len, int pos,
                                       UINT disposition, BOOL open_reparse, BOOL is_unix, unsigned int reparse_count )
{
    (void)fd; (void)root_fd; (void)attr; (void)nt_name; (void)nt_pos; (void)len; (void)buffer; (void)unix_len;
    (void)pos; (void)disposition; (void)open_reparse; (void)is_unix; (void)reparse_count;
    reparse_calls++;
    return STATUS_OBJECT_NAME_NOT_FOUND;
}
int ios_counters_on = 1;
static int stats;
static int counted_fstatat( int fd, const char *path, struct stat *st, int flags ) { stats++; return fstatat( fd, path, st, flags ); }
#define fstatat counted_fstatat

HASH_CODE
LEGAL_CODE
IOS_CODE
FIND_CODE
WALK_CODE
LOOKUP_CODE

static int root_fd;

/* name: a Windows path relative to the root, backslashes. Returns the status; *out the unix name. */
static NTSTATUS look( const char *name, UINT disposition, char *out )
{
    WCHAR w[512];
    UNICODE_STRING us;
    OBJECT_ATTRIBUTES attr = { sizeof(attr), NULL, &us };
    int n = (int)strlen( name ), unix_len = 2 * MAX_DIR_ENTRY_LEN + 3 * n + 16;
    char *buffer = malloc( unix_len );
    NTSTATUS status;
    for (int i = 0; i < n; i++) w[i] = (unsigned char)name[i];
    us.Buffer = w;
    us.Length = us.MaximumLength = n * sizeof(WCHAR);
    buffer[0] = '.';
    status = lookup_unix_name( root_fd, &attr, &us, 0, &buffer, unix_len, 1, disposition, FALSE, FALSE, 0 );
    strcpy( out, buffer );
    free( buffer );
    return status;
}

static char tree[PATH_MAX];

/* The same, from an absolute unix prefix (root AT_FDCWD), as a game's C: path is. */
static NTSTATUS look_abs( const char *name, UINT disposition, char *out )
{
    WCHAR w[512];
    UNICODE_STRING us;
    OBJECT_ATTRIBUTES attr = { sizeof(attr), NULL, &us };
    int n = (int)strlen( name ), unix_len = 2 * MAX_DIR_ENTRY_LEN + 3 * n + (int)strlen( tree ) + 16;
    char *buffer = malloc( unix_len );
    NTSTATUS status;
    for (int i = 0; i < n; i++) w[i] = (unsigned char)name[i];
    us.Buffer = w;
    us.Length = us.MaximumLength = n * sizeof(WCHAR);
    strcpy( buffer, tree );
    status = lookup_unix_name( AT_FDCWD, &attr, &us, 0, &buffer, unix_len, (int)strlen( tree ), disposition, FALSE,
                               FALSE, 0 );
    strcpy( out, buffer + strlen( tree ) );
    free( buffer );
    return status;
}

static void touch( const char *path )
{
    int fd = openat( root_fd, path, O_CREAT | O_WRONLY, 0644 );
    assert( fd >= 0 );
    close( fd );
}

/* Ages a directory's mtime past the cache's 2 s rule, so its listing may be kept. */
static void age( const char *dir )
{
    struct timespec t[2] = { { time(NULL) - 60, 0 }, { time(NULL) - 60, 0 } };
    assert( !utimensat( root_fd, dir, t, 0 ) );
}

int main( int argc, char **argv )
{
    char out[1024];
    int q;

    assert( argc == 2 );
    assert( (root_fd = open( argv[1], O_RDONLY | O_DIRECTORY )) >= 0 );
    assert( realpath( argv[1], tree ) );
    assert( !mkdirat( root_fd, "Games", 0755 ) && !mkdirat( root_fd, "Games/Borderlands 2", 0755 ) );
    assert( !mkdirat( root_fd, "Games/Borderlands 2/WillowGame", 0755 ) );
    assert( !mkdirat( root_fd, "Games/Borderlands 2/WillowGame/CookedPCConsole", 0755 ) );
    touch( "Games/Borderlands 2/WillowGame/CookedPCConsole/Engine.upk" );
    touch( "Games/Borderlands 2/WillowGame/CookedPCConsole/GD_Weap_Shared.upk" );
    age( "Games/Borderlands 2/WillowGame/CookedPCConsole" );
    age( "Games/Borderlands 2/WillowGame" );
    age( "Games/Borderlands 2" );
    age( "Games" );
    sleep( 3 );   /* the directories' ctimes, which utimensat sets to now, past the 2 s rule */

    /* As named: the whole-path stat, no walk. */
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\Engine.upk", FILE_OPEN, out ) == STATUS_SUCCESS );
    assert( !strcmp( out, "./Games/Borderlands 2/WillowGame/CookedPCConsole/Engine.upk" ) && !case_queries );

    /* The last component in another case: one search, then answered by the kept listing. */
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\ENGINE.UPK", FILE_OPEN, out ) == STATUS_SUCCESS );
    assert( !strcmp( out, "./Games/Borderlands 2/WillowGame/CookedPCConsole/Engine.upk" ) && case_queries == 1 );
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\gd_weap_shared.UPK", FILE_OPEN, out ) == STATUS_SUCCESS );
    assert( !strcmp( out, "./Games/Borderlands 2/WillowGame/CookedPCConsole/GD_Weap_Shared.upk" ) && case_queries == 1 );

    /* An earlier component in another case: the walk folds each one. */
    assert( look( "games\\BORDERLANDS 2\\willowgame\\cookedpcconsole\\engine.upk", FILE_OPEN, out ) == STATUS_SUCCESS );
    assert( !strcmp( out, "./Games/Borderlands 2/WillowGame/CookedPCConsole/Engine.upk" ) );

    /* Missing: not found, and the reparse point probe ("name?") is answered by the listing too. */
    q = case_queries;
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\Missing_LOC_DEU.upk", FILE_OPEN, out ) ==
            STATUS_OBJECT_NAME_NOT_FOUND );
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\Missing_LOC_FRA.upk", FILE_OPEN, out ) ==
            STATUS_OBJECT_NAME_NOT_FOUND );
    assert( case_queries == q );
    /* A miss in a kept listing costs three stats: the whole path, its directory, and the
     * reparse point's name; no directory is read. */
    stats = 0;
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\Missing_LOC_ITA.upk", FILE_OPEN, out ) ==
            STATUS_OBJECT_NAME_NOT_FOUND );
    assert( stats == 3 );
    assert( look( "Games\\Borderlands 2\\Nowhere\\Engine.upk", FILE_OPEN, out ) == STATUS_OBJECT_PATH_NOT_FOUND );

    /* Creating a missing file names it as asked; an existing one collides in any case. */
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\New.upk", FILE_CREATE, out ) == STATUS_NO_SUCH_FILE );
    assert( !strcmp( out, "./Games/Borderlands 2/WillowGame/CookedPCConsole/New.upk" ) );
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\engine.upk", FILE_CREATE, out ) ==
            STATUS_OBJECT_NAME_COLLISION );

    /* A file added after the listing was kept: the directory's new mtime drops the listing. */
    touch( "Games/Borderlands 2/WillowGame/CookedPCConsole/Missing_LOC_DEU.upk" );
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\missing_loc_deu.UPK", FILE_OPEN, out ) == STATUS_SUCCESS );
    assert( !strcmp( out, "./Games/Borderlands 2/WillowGame/CookedPCConsole/Missing_LOC_DEU.upk" ) );
    /* ... and one removed. */
    assert( !unlinkat( root_fd, "Games/Borderlands 2/WillowGame/CookedPCConsole/GD_Weap_Shared.upk", 0 ) );
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\gd_weap_shared.upk", FILE_OPEN, out ) ==
            STATUS_OBJECT_NAME_NOT_FOUND );

    /* A directory changed within 2 s is searched each time, the name and the reparse
     * point probe: its listing is not kept. */
    q = case_queries;
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\Absent.upk", FILE_OPEN, out ) == STATUS_OBJECT_NAME_NOT_FOUND );
    assert( look( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\Absent.upk", FILE_OPEN, out ) == STATUS_OBJECT_NAME_NOT_FOUND );
    assert( case_queries == q + 4 );

    /* A trailing backslash names a directory; the walk handles it as before. */
    assert( look( "games\\", FILE_OPEN, out ) == STATUS_SUCCESS && !strcmp( out, "./Games/" ) );

    /* From an absolute prefix (root AT_FDCWD), as a C: path is: a lookup that misses under a
     * directory whose listing is kept by its path, spelled as kept, is answered from that
     * listing after one stat of the directory: no whole-path stat, no walk. A hit costs the
     * whole-path stat alone, as before. */
    sleep( 3 );   /* CookedPCConsole's last change (the unlink above) past the 2 s rule */
    assert( look_abs( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\engine.UPK", FILE_OPEN, out ) == STATUS_SUCCESS );
    assert( !strcmp( out, "/Games/Borderlands 2/WillowGame/CookedPCConsole/Engine.upk" ) );
    stats = 0;
    assert( look_abs( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\Pkg_LOC_DEU.upk", FILE_OPEN, out ) ==
            STATUS_OBJECT_NAME_NOT_FOUND );
    assert( stats == 1 );
    stats = 0;
    assert( look_abs( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\Engine.upk", FILE_OPEN, out ) == STATUS_SUCCESS );
    assert( stats == 1 );
    /* A missing directory on the way: its parent's listing answers, for any disposition, and
     * leaves the name where the walk leaves it, at that parent. */
    assert( look_abs( "Games\\Borderlands 2\\Nowhere\\x.upk", FILE_OPEN, out ) == STATUS_OBJECT_PATH_NOT_FOUND );
    assert( !strcmp( out, "/Games/Borderlands 2" ) );
    stats = 0;
    assert( look_abs( "Games\\Borderlands 2\\NOWHERE\\Localization\\INT\\x.INT", FILE_OPEN, out ) ==
            STATUS_OBJECT_PATH_NOT_FOUND );
    assert( stats == 1 && !strcmp( out, "/Games/Borderlands 2" ) );
    stats = 0;
    assert( look_abs( "Games\\Borderlands 2\\Nowhere\\New.upk", FILE_CREATE, out ) == STATUS_OBJECT_PATH_NOT_FOUND );
    assert( stats == 1 );
    /* Creating a missing file still gets the walk's name for it. */
    assert( look_abs( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\New.upk", FILE_CREATE, out ) ==
            STATUS_NO_SUCH_FILE );
    assert( !strcmp( out, "/Games/Borderlands 2/WillowGame/CookedPCConsole/New.upk" ) );
    /* A trailing backslash walks, as before. */
    assert( look_abs( "Games\\Borderlands 2\\Nowhere\\", FILE_OPEN, out ) == STATUS_OBJECT_NAME_NOT_FOUND );

    /* The path as spelled, not folded: in another case the walk folds it, and a directory
     * whose name differs only in case from a kept one is its own. */
    stats = 0;
    assert( look_abs( "games\\borderlands 2\\Nowhere\\x.upk", FILE_OPEN, out ) == STATUS_OBJECT_PATH_NOT_FOUND );
    assert( stats > 1 );
    assert( !mkdirat( root_fd, "GAMES", 0755 ) && !mkdirat( root_fd, "GAMES/Borderlands 2", 0755 ) );
    assert( !mkdirat( root_fd, "GAMES/Borderlands 2/Nowhere", 0755 ) );
    touch( "GAMES/Borderlands 2/Nowhere/x.upk" );
    assert( look_abs( "GAMES\\Borderlands 2\\Nowhere\\x.upk", FILE_OPEN, out ) == STATUS_SUCCESS );
    assert( !strcmp( out, "/GAMES/Borderlands 2/Nowhere/x.upk" ) );

    /* An 8.3 short name is not in a listing; the walk's scan finds it. */
    assert( look_abs( "Games\\Absent.upk", FILE_OPEN, out ) == STATUS_OBJECT_NAME_NOT_FOUND );   /* keeps Games */
    {
        static const WCHAR longw[] = { 'B','o','r','d','e','r','l','a','n','d','s',' ','2' };
        WCHAR shortw[12];
        char path[256] = "Games\\";
        ULONG n = hash_short_file_name( longw, 13, shortw ), i, len = strlen( path );
        assert( n == 8 && shortw[4] == '~' );
        for (i = 0; i < n; i++) path[len++] = (char)shortw[i];
        strcpy( path + len, "\\WillowGame\\CookedPCConsole\\Engine.upk" );
        stats = 0;
        assert( look_abs( "Games\\Nowhere.upk", FILE_OPEN, out ) == STATUS_OBJECT_NAME_NOT_FOUND && stats == 1 );
        assert( look_abs( path, FILE_OPEN, out ) == STATUS_SUCCESS );
        assert( !strcmp( out, "/Games/Borderlands 2/WillowGame/CookedPCConsole/Engine.upk" ) );
    }

    /* A reparse point ("name?") under a missing name: the walk resolves it. */
    touch( "Games/Borderlands 2/Link?" );
    sleep( 3 );
    assert( look_abs( "Games\\Borderlands 2\\Nowhere\\x.upk", FILE_OPEN, out ) == STATUS_OBJECT_PATH_NOT_FOUND );
    stats = 0;
    assert( look_abs( "Games\\Borderlands 2\\Nowhere\\x.upk", FILE_OPEN, out ) == STATUS_OBJECT_PATH_NOT_FOUND );
    assert( stats == 1 );   /* Borderlands 2 kept again, Link? in it */
    reparse_calls = 0;
    assert( look_abs( "Games\\Borderlands 2\\LINK\\x.upk", FILE_OPEN, out ) == STATUS_OBJECT_NAME_NOT_FOUND );
    assert( reparse_calls == 1 );

    /* The directory changed (a file added): the revalidation drops the listing, and the
     * whole-path stat or the walk finds the file. */
    touch( "Games/Borderlands 2/WillowGame/CookedPCConsole/Late.upk" );
    assert( look_abs( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\Late.upk", FILE_OPEN, out ) == STATUS_SUCCESS );
    touch( "Games/Borderlands 2/WillowGame/CookedPCConsole/Pkg_LOC_DEU.upk" );
    assert( look_abs( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\pkg_loc_deu.upk", FILE_OPEN, out ) ==
            STATUS_SUCCESS );
    assert( !strcmp( out, "/Games/Borderlands 2/WillowGame/CookedPCConsole/Pkg_LOC_DEU.upk" ) );
    /* A directory on the way renamed: the kept path no longer leads to its listing. */
    assert( !renameat( root_fd, "Games/Borderlands 2/WillowGame", root_fd, "Games/Borderlands 2/Moved" ) );
    assert( look_abs( "Games\\Borderlands 2\\WillowGame\\CookedPCConsole\\Missing.upk", FILE_OPEN, out ) ==
            STATUS_OBJECT_PATH_NOT_FOUND );
    assert( look_abs( "Games\\Borderlands 2\\Moved\\CookedPCConsole\\ENGINE.upk", FILE_OPEN, out ) == STATUS_SUCCESS );
    assert( !strcmp( out, "/Games/Borderlands 2/Moved/CookedPCConsole/Engine.upk" ) );

    /* The census reports the walks it timed. */
    ios_fm_flush( "test" );
    return 0;
}
'''


def between(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i) + len(end)]


class DirCaseIOS(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        cls._tmp = tempfile.TemporaryDirectory(prefix="dircase-", dir=work)
        cls.root = Path(cls._tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_the_cache_alone(self):
        root = self.root / "header"
        root.mkdir()
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        self.assertEqual(len(PATCHES), 2)
        for patch in PATCHES:
            subprocess.run(["git", "-C", str(root), "apply", f"--include={HEADER}", str(patch)], check=True)
        exe = root / "dircase-test"
        subprocess.run(["cc", "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                        "-I", str(root / "dlls/ntdll/unix"), str(REPO / "tools/tests/dircase_ios_test.c"),
                        "-o", str(exe)], check=True)
        run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_lookups_over_a_directory_tree(self):
        root = self.root / "file"
        root.mkdir()
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        if not wow64_test.patched_upstream_files(wow64_test.BUILD / "cache/wine.git", wow64_test.pin("wine"),
                                                 ["wine-port", "wine-valve", "wine-unix"], [SOURCE], root,
                                                 include=[HEADER]):
            self.skipTest("no Wine cache in $PLAYPORT_BUILD/cache")
        code = (root / SOURCE).read_text()
        ios = code[code.index("/* Playport (iOS): case-insensitive lookups through a cache"):
                   code.index("/***********************************************************************\n"
                              " *           find_file_in_dir")]
        source = (HARNESS.replace("HASH_CODE", wow64_test.c_function(code, "hash_short_file_name"))
                  .replace("LEGAL_CODE", wow64_test.c_function(code, "is_legal_8dot3_name"))
                  .replace("IOS_CODE", ios)
                  .replace("FIND_CODE", wow64_test.c_function(code, "find_file_in_dir"))
                  .replace("WALK_CODE", wow64_test.c_function(code, "lookup_unix_name_walk"))
                  .replace("LOOKUP_CODE", between(code, "static NTSTATUS lookup_unix_name( int root_fd,",
                                                  "    return status;\n}\n")))
        (root / "test.c").write_text(source)
        exe = root / "lookup-test"
        # hash_short_file_name's 32-character table fills its array, as upstream has it.
        subprocess.run(["cc", "-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
                        "-Wno-unterminated-string-initialization", "-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-pthread",
                        "-I", str(root / "dlls/ntdll/unix"), str(root / "test.c"), "-o", str(exe)], check=True)
        tree = root / "tree"
        tree.mkdir()
        run = subprocess.run([str(exe), str(tree)], capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("[file-miss] test", run.stderr)
        self.assertIn('dir="./Games/Borderlands 2/WillowGame/CookedPCConsole"', run.stderr)
        self.assertRegex(run.stderr, r"[1-9][0-9]* misses answered by path")


if __name__ == "__main__":
    unittest.main()
