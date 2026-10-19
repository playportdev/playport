/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * dll_overlay_test.c — dll_overlay.c on the Linux host (pp test): the
 * PLAYPORT_DLL_OVERLAY list read in order and refused whole when one name is
 * bad; overlays linked over a scratch system32 in list order, the last one's
 * file winning; an overlay with no set skipped in a farm that does not need
 * it and failing one that does; WINEDLLPATH with the last overlay first; and
 * a relink without the Khronos loader's overlay (decision 0131) giving the
 * runtime's own vulkan-1.dll back.
 */
#include "dll_overlay.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static void mk(const char *root, const char *rel)
{
    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/%s", root, rel);
    if (mkdir(p, 0755)) { perror(p); exit(1); }
}

static void put(const char *root, const char *rel)
{
    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/%s", root, rel);
    FILE *f = fopen(p, "w");
    if (!f) { perror(p); exit(1); }
    fputs(rel, f);
    fclose(f);
}

/* The link target of dir/name relative to root, or "" if it is no link. */
static const char *target(const char *root, const char *dir, const char *name)
{
    static char t[PATH_MAX];
    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/%s", dir, name);
    ssize_t n = readlink(p, t, sizeof(t) - 1);
    if (n <= 0) return "";
    t[n] = 0;
    size_t rl = strlen(root);
    return strncmp(t, root, rl) == 0 && t[rl] == '/' ? t + rl + 1 : t;
}

int main(void)
{
    char names[DLL_OVERLAY_MAX][DLL_OVERLAY_NAME];

    /* The list, in order; a bad name refuses the whole list. */
    CHECK(dll_overlay_names(NULL, names) == 0);
    CHECK(dll_overlay_names("", names) == 0);
    CHECK(dll_overlay_names("vulkan", names) == 1 && strcmp(names[0], "vulkan") == 0);
    CHECK(dll_overlay_names("vulkan,vulkan-loader", names) == 2 && strcmp(names[0], "vulkan") == 0
          && strcmp(names[1], "vulkan-loader") == 0);
    CHECK(dll_overlay_names("vulkan,", names) == -1);
    CHECK(dll_overlay_names(",vulkan", names) == -1);
    CHECK(dll_overlay_names("vulkan,../x", names) == -1);
    CHECK(dll_overlay_names("a/b", names) == -1);
    CHECK(dll_overlay_names("a:b", names) == -1);
    CHECK(dll_overlay_names("a,b,c,d,e", names) == -1);

    char root[PATH_MAX], runtime[PATH_MAX], sys32[PATH_MAX], wow[PATH_MAX], log[512], path[4096];
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof(root), "%s/dll-overlay-XXXXXX", tmp && tmp[0] ? tmp : ".");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }
    snprintf(runtime, sizeof(runtime), "%s/Runtime", root);
    snprintf(sys32, sizeof(sys32), "%s/system32", root);
    snprintf(wow, sizeof(wow), "%s/syswow64", root);
    mk(root, "Runtime");
    mk(root, "Runtime/arm64ec-windows");
    mk(root, "Runtime/i386-windows");
    mk(root, "Runtime/vulkan");
    mk(root, "Runtime/vulkan/arm64ec-windows");
    mk(root, "Runtime/vulkan/i386-windows");
    mk(root, "Runtime/vulkan-loader");
    mk(root, "Runtime/vulkan-loader/arm64ec-windows");
    mk(root, "Runtime/empty");
    mk(root, "Runtime/empty/arm64ec-windows");
    mk(root, "system32");
    mk(root, "syswow64");
    put(root, "Runtime/arm64ec-windows/vulkan-1.dll");
    put(root, "Runtime/arm64ec-windows/d3d11.dll");
    put(root, "Runtime/arm64ec-windows/kernel32.dll");
    put(root, "Runtime/i386-windows/d3d9.dll");
    put(root, "Runtime/vulkan/arm64ec-windows/d3d11.dll");
    put(root, "Runtime/vulkan/arm64ec-windows/vulkan-1.dll");   /* stands in for an earlier overlay's file */
    put(root, "Runtime/vulkan/i386-windows/d3d9.dll");
    put(root, "Runtime/vulkan-loader/arm64ec-windows/vulkan-1.dll");
    put(root, "Runtime/vulkan-loader/arm64ec-windows/winevulkan.json");
    put(root, "system32/game.ini");   /* not a runtime link: stays */

    /* The runtime's set, then the backend's and the loader's over it, in order. */
    snprintf(path, sizeof(path), "%s/arm64ec-windows", runtime);
    CHECK(dll_overlay_link_dir(path, sys32) == 3);
    CHECK(dll_overlay_link(runtime, "vulkan,vulkan-loader", "arm64ec-windows", sys32, 1, log, sizeof(log)) == 4);
    CHECK(strcmp(log, "vulkan 2, vulkan-loader 2") == 0);
    CHECK(strcmp(target(root, sys32, "d3d11.dll"), "Runtime/vulkan/arm64ec-windows/d3d11.dll") == 0);
    CHECK(strcmp(target(root, sys32, "vulkan-1.dll"), "Runtime/vulkan-loader/arm64ec-windows/vulkan-1.dll") == 0);
    CHECK(strcmp(target(root, sys32, "winevulkan.json"), "Runtime/vulkan-loader/arm64ec-windows/winevulkan.json") == 0);
    CHECK(strcmp(target(root, sys32, "kernel32.dll"), "Runtime/arm64ec-windows/kernel32.dll") == 0);
    /* The other order: the last overlay's file wins. */
    CHECK(dll_overlay_link(runtime, "vulkan-loader,vulkan", "arm64ec-windows", sys32, 1, log, sizeof(log)) == 4);
    CHECK(strcmp(target(root, sys32, "vulkan-1.dll"), "Runtime/vulkan/arm64ec-windows/vulkan-1.dll") == 0);

    /* A farm that does not need an overlay's set skips it; one that does fails. */
    snprintf(path, sizeof(path), "%s/i386-windows", runtime);
    CHECK(dll_overlay_link_dir(path, wow) == 1);
    CHECK(dll_overlay_link(runtime, "vulkan,vulkan-loader", "i386-windows", wow, 0, log, sizeof(log)) == 1);
    CHECK(strcmp(log, "vulkan 1, vulkan-loader none") == 0);
    CHECK(strcmp(target(root, wow, "d3d9.dll"), "Runtime/vulkan/i386-windows/d3d9.dll") == 0);
    CHECK(dll_overlay_link(runtime, "vulkan,vulkan-loader", "i386-windows", wow, 1, log, sizeof(log)) == -1);
    CHECK(strstr(log, "vulkan-loader has no i386-windows set") != NULL);
    CHECK(dll_overlay_link(runtime, "vulkan,empty", "arm64ec-windows", sys32, 1, log, sizeof(log)) == -1);
    CHECK(dll_overlay_link(runtime, "vulkan,../x", "arm64ec-windows", sys32, 1, log, sizeof(log)) == -1);
    CHECK(strstr(log, "bad overlay list") != NULL);

    /* A relink without the loader's overlay: Wine's vulkan-1.dll and no manifest. */
    dll_overlay_unlink_runtime_links(sys32);
    CHECK(strcmp(target(root, sys32, "vulkan-1.dll"), "") == 0);
    snprintf(path, sizeof(path), "%s/game.ini", sys32);
    CHECK(access(path, F_OK) == 0);
    snprintf(path, sizeof(path), "%s/arm64ec-windows", runtime);
    CHECK(dll_overlay_link_dir(path, sys32) == 3);
    CHECK(dll_overlay_link(runtime, "vulkan", "arm64ec-windows", sys32, 1, log, sizeof(log)) == 2);
    CHECK(strcmp(target(root, sys32, "vulkan-1.dll"), "Runtime/vulkan/arm64ec-windows/vulkan-1.dll") == 0);
    dll_overlay_unlink_runtime_links(sys32);
    snprintf(path, sizeof(path), "%s/arm64ec-windows", runtime);
    CHECK(dll_overlay_link_dir(path, sys32) == 3);
    CHECK(strcmp(target(root, sys32, "vulkan-1.dll"), "Runtime/arm64ec-windows/vulkan-1.dll") == 0);
    CHECK(strcmp(target(root, sys32, "winevulkan.json"), "") == 0);
    snprintf(path, sizeof(path), "%s/winevulkan.json", sys32);
    CHECK(access(path, F_OK) != 0);

    /* WINEDLLPATH: the last overlay first, then the runtime. */
    CHECK(dll_overlay_search_path("/R", NULL, path, sizeof(path)) == 0 && strcmp(path, "/R") == 0);
    CHECK(dll_overlay_search_path("/R", "vulkan", path, sizeof(path)) == 0 && strcmp(path, "/R/vulkan:/R") == 0);
    CHECK(dll_overlay_search_path("/R", "vulkan,vulkan-loader", path, sizeof(path)) == 0
          && strcmp(path, "/R/vulkan-loader:/R/vulkan:/R") == 0);
    CHECK(dll_overlay_search_path("/R", "vulkan,..", path, sizeof(path)) == -1 && strcmp(path, "/R") == 0);
    CHECK(dll_overlay_search_path("/R", "vulkan", path, 8) == -1 && strcmp(path, "/R") == 0);

    snprintf(path, sizeof(path), "rm -rf '%s'", root);
    if (system(path)) printf("cleanup of %s failed\n", root);
    printf(failures ? "dll overlay: %d failure(s)\n" : "dll overlay: ok\n", failures);
    return failures != 0;
}
