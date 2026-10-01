#!/usr/bin/env python3
"""Scratch wiring for the child-process test (never committed to the app).

apply: copies childtest_bin.h into app/Sources/WineHost/ and makes
wine_host_run_exe start C:\\childtest.exe (PLAYPORT_CHILDTEST=x64) or
C:\\childtest-arm64ec.exe (PLAYPORT_CHILDTEST=ec) with the title's DOS path and
arguments, when a game's launch settings set PLAYPORT_CHILDTEST.
revert: restores both files from git.
"""
import pathlib, shutil, subprocess, sys

here = pathlib.Path(__file__).resolve().parent
repo = here.parents[3]
src = repo / "app/Sources/WineHost/wine_host.c"
hdr = repo / "app/Sources/WineHost/childtest_bin.h"

OLD = """    snprintf(g_exe_path, sizeof(g_exe_path), "%s", tp.dos);
"""
NEW = """    snprintf(g_exe_path, sizeof(g_exe_path), "%s", tp.dos);
    const char *childtest = getenv("PLAYPORT_CHILDTEST");
    if (childtest && *childtest) {
        static const struct { const char *name; const unsigned char *bytes; unsigned int len; } exes[] = {
            { "childtest.exe", childtest_exe, childtest_exe_len },
            { "childtest-arm64ec.exe", childtest_arm64ec_exe, childtest_arm64ec_exe_len },
        };
        for (int i = 0; i < 2; i++) {
            char path[1200];
            snprintf(path, sizeof(path), "%s/drive_c/%s", g_prefix, exes[i].name);
            FILE *f = fopen(path, "wb");
            if (!f || fwrite(exes[i].bytes, 1, exes[i].len, f) != exes[i].len) host_log("childtest: cannot write %s", path);
            if (f) fclose(f);
        }
        snprintf(g_exe_path, sizeof(g_exe_path), "C:\\\\%s", strcmp(childtest, "ec") ? "childtest.exe" : "childtest-arm64ec.exe");
        host_log("childtest: %s runs %s as its child", g_exe_path, tp.dos);
        for (int i = 2; i < g_guest_argc; i++) free(g_guest_argv[i]);
        g_guest_argv[0] = "wine";
        g_guest_argv[1] = g_exe_path;
        g_guest_argv[2] = strdup(tp.dos);
        g_guest_argc = 3;
        for (int i = 0; i < nargs; i++) g_guest_argv[g_guest_argc++] = strdup(args[i]);
        g_guest_argv[g_guest_argc] = NULL;
        return start_guest();
    }
"""
INC_OLD = '#include "title_path.h"\n'
INC_NEW = '#include "title_path.h"\n#include "childtest_bin.h"\n'

if sys.argv[1:] == ["apply"]:
    s = src.read_text()
    assert s.count(OLD) == 1 and s.count(INC_OLD) == 1
    src.write_text(s.replace(INC_OLD, INC_NEW).replace(OLD, NEW))
    shutil.copy(here / "childtest_bin.h", hdr)
elif sys.argv[1:] == ["revert"]:
    subprocess.run(["git", "-C", str(repo), "checkout", "--", str(src)], check=True)
    hdr.unlink(missing_ok=True)
else:
    sys.exit("usage: wire.py apply|revert")
