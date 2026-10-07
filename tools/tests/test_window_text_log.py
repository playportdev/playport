# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile the diagnostic policy/formatter directly from the shipped patch."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PATCH = REPO / "patches/madeira-unix/0094-win32u-log-changed-captions-and-static-dialog-text-o.patch"


class WindowTextLog(unittest.TestCase):
    def test_policy_and_bounded_utf16_escaping(self):
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="window-text-test-", dir=work) as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "apply", "--include=build/win32u-unix/window_text_log.h", str(PATCH)],
                           cwd=root, check=True)
            source = root / "test.c"
            source.write_text(r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
typedef uint16_t WCHAR;
#define WS_CHILD 0x40000000u
#define SS_TYPEMASK 0x1fu
#define SS_LEFT 0
#define SS_CENTER 1
#define SS_RIGHT 2
#define SS_SIMPLE 11
#define SS_LEFTNOWORDWRAP 12
#include "build/win32u-unix/window_text_log.h"

int main(void)
{
    struct { char out[IOS_WINDOW_TEXT_BYTES]; char canary; } b;
    WCHAR long_text[IOS_WINDOW_TEXT_UNITS]; /* intentionally no terminator */
    const WCHAR text[] = {'E','r','r','o','r',':',' ',0x00e9,0xd83d,0xde00,
                          '\n','\r','\t','"','\\',1,127,0};
    const WCHAR empty[] = {0};
    const unsigned int textual[] = {SS_LEFT, SS_CENTER, SS_RIGHT, SS_SIMPLE, SS_LEFTNOWORDWRAP};
    unsigned int i;

    assert(ios_window_text_kind(0, 0, 0) == 1); /* custom top-level dialog */
    assert(ios_window_text_kind(WS_CHILD, 0, 0) == 0);
    assert(ios_window_text_kind(0, 0, 1) == 0); /* even a top-level Edit */
    assert(ios_window_text_kind(WS_CHILD, 0, 1) == 0); /* Edit/password fields */
    for (i = 0; i < 32; i++)
    {
        int expected = 0;
        for (unsigned int j = 0; j < sizeof(textual) / sizeof(textual[0]); j++)
            if (i == textual[j]) expected = 2;
        assert(ios_window_text_kind(WS_CHILD | i, 1, 0) == expected);
    }
    b.canary = '!';
    ios_window_text_escape(text, b.out);
    assert(!strcmp(b.out, "Error: \\u00e9\\ud83d\\ude00\\n\\r\\t\\\"\\\\\\u0001\\u007f"));
    assert(!strchr(b.out, '\n') && !strchr(b.out, '\r'));
    assert(b.canary == '!');
    ios_window_text_escape(empty, b.out);
    assert(!strcmp(b.out, ""));
    for (i = 0; i < IOS_WINDOW_TEXT_UNITS; i++) long_text[i] = 0x1234;
    ios_window_text_escape(long_text, b.out);
    assert(strlen(b.out) == IOS_WINDOW_TEXT_BYTES - 1);
    assert(!strcmp(b.out + strlen(b.out) - 3, "..."));
    assert(b.canary == '!');
    for (i = 0; i < IOS_WINDOW_TEXT_UNITS; i++) long_text[i] = 'a';
    ios_window_text_escape(long_text, b.out);
    assert(strlen(b.out) == IOS_WINDOW_TEXT_UNITS + 3);
    assert(b.canary == '!');
    return 0;
}
''')
            exe = root / "test"
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(source),
                            "-o", str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

    def test_actual_text_setter_creation_and_updates(self):
        # Compile the real patched setter with Wine/server/driver stand-ins.
        # This catches placement mistakes in the hook, not just formatter bugs.
        source_path = REPO / ".work/run/unix/mythic/build/win32u-unix/defwnd_ios.c"
        if not source_path.exists():
            self.skipTest("runtime source tree absent; formatter/policy still tested")
        # Read the function from the patch-applied build tree; CI without build
        # inputs exercises the standalone header above.
        source = source_path.read_text()
        if "if (text_changed) log_window_text" not in source:
            self.skipTest("runtime tree has not applied the diagnostic patch yet")
        setter = source[source.index("static BOOL set_window_text("):source.index("static int get_window_text(")]
        work = REPO / ".work"
        with tempfile.TemporaryDirectory(prefix="window-text-setter-", dir=work) as tmp:
            root = Path(tmp)
            probe = root / "test.c"
            probe.write_text(r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef uint16_t WCHAR;
typedef void *HWND;
typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define WINE_IOS 1
#define TRACE(...) ((void)0)
#define IS_INTRESOURCE(p) ((uintptr_t)(p) < 65536)
typedef struct { WCHAR *text; unsigned int dwStyle; } WND;
static WND window;
static int locked, missing, logged, sent, driven;
static size_t lstrlenW(const WCHAR *s) { size_t n = 0; while (s[n]) n++; return n; }
static WCHAR *copy_w(const WCHAR *s) {
    size_t bytes = (lstrlenW(s) + 1) * sizeof(*s);
    WCHAR *out = malloc(bytes); memcpy(out, s, bytes); return out;
}
static int compare_w(const WCHAR *a, const WCHAR *b) {
    while (*a && *a == *b) { a++; b++; } return *a - *b;
}
#define wcsdup copy_w
#define wcscmp compare_w
static WCHAR *towstr(const char *s) {
    size_t n = strlen(s); WCHAR *out = malloc((n + 1) * sizeof(*out));
    for (size_t i = 0; i <= n; i++) out[i] = (unsigned char)s[i];
    return out;
}
static WND *get_win_ptr(HWND h) { (void)h; if (missing) return NULL; locked = 1; return &window; }
static void release_win_ptr(WND *w) { assert(w == &window && locked); locked = 0; }
struct request { uintptr_t handle; };
#define SERVER_START_REQ(name) do { struct request storage, *req = &storage;
#define SERVER_END_REQ } while (0)
static uintptr_t wine_server_user_handle(HWND h) { return (uintptr_t)h; }
static void wine_server_add_data(struct request *r, WCHAR *s, size_t n) { (void)r; (void)s; (void)n; }
static void wine_server_call(struct request *r) { (void)r; assert(locked); sent++; }
static void log_window_text(HWND h, const WCHAR *s, unsigned int style) {
    (void)h; assert(!locked && s[0] && style == window.dwStyle);
    assert(sent == driven + 1); logged++;
}
static void driver_set(HWND h, const WCHAR *s) { (void)h; assert(!locked && s); driven++; }
static struct { void (*pSetWindowText)(HWND, const WCHAR *); } driver = {driver_set}, *user_driver = &driver;
'''+ setter + r'''
int main(void) {
    HWND h = (HWND)(uintptr_t)0x10000;
    const WCHAR first[] = {'B','o','d','y',0}, second[] = {'U','p','d','a','t','e',0}, empty[] = {0};
    window.dwStyle = 123;
    assert(set_window_text(h, first, FALSE) && logged == 1); /* WM_NCCREATE */
    assert(set_window_text(h, first, FALSE) && logged == 1); /* identical WM_SETTEXT */
    assert(set_window_text(h, "Body", TRUE) && logged == 1); /* ANSI equivalent */
    assert(set_window_text(h, second, FALSE) && logged == 2);
    assert(set_window_text(h, "ANSI", TRUE) && logged == 3);
    assert(set_window_text(h, NULL, FALSE) && !window.text && logged == 3);
    assert(set_window_text(h, empty, FALSE) && logged == 3);
    assert(!set_window_text(h, (void *)(uintptr_t)42, FALSE) && logged == 3);
    missing = 1;
    assert(!set_window_text(h, first, FALSE) && logged == 3);
    assert(sent == driven && !locked);
    free(window.text);
    return 0;
}
''')
            exe = root / "test"
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(probe),
                            "-o", str(exe)], check=True)
            subprocess.run([str(exe)], check=True)


if __name__ == "__main__":
    unittest.main()
