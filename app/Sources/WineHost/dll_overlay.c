/* SPDX-License-Identifier: GPL-3.0-or-later */
/* dll_overlay — see include/dll_overlay.h. */
#include "dll_overlay.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int dll_overlay_names(const char *list, char names[DLL_OVERLAY_MAX][DLL_OVERLAY_NAME])
{
    if (!list || !list[0]) return 0;
    int n = 0;
    const char *p = list;
    for (;;) {
        const char *end = strchr(p, ',');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (!len || len >= DLL_OVERLAY_NAME || n == DLL_OVERLAY_MAX) return -1;
        memcpy(names[n], p, len);
        names[n][len] = 0;
        if (strchr(names[n], '/') || strchr(names[n], ':') || strstr(names[n], "..")) return -1;
        n++;
        if (!end) return n;
        p = end + 1;
    }
}

int dll_overlay_link_dir(const char *src_dir, const char *dir)
{
    char src[1600], dst[1600];
    DIR *d = opendir(src_dir);
    if (!d) return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(src, sizeof(src), "%s/%s", src_dir, e->d_name);
        snprintf(dst, sizeof(dst), "%s/%s", dir, e->d_name);
        unlink(dst);
        if (symlink(src, dst) == 0) n++;
    }
    closedir(d);
    return n;
}

void dll_overlay_unlink_runtime_links(const char *dir)
{
    static const char set[] = "-windows/";
    char dst[1600], target[1600];
    char **names = NULL;
    size_t count = 0, cap = 0;
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(dst, sizeof(dst), "%s/%s", dir, e->d_name);
        ssize_t len = readlink(dst, target, sizeof(target) - 1);
        if (len <= 0) continue;
        target[len] = 0;
        char *leaf = strrchr(target, '/');
        if (!leaf) continue;
        size_t sl = sizeof(set) - 1;
        if ((size_t)(leaf + 1 - target) < sl || strncmp(leaf + 1 - sl, set, sl)) continue;
        if (count == cap) {
            size_t ncap = cap ? 2 * cap : 64;
            char **grown = realloc(names, ncap * sizeof(*names));
            if (!grown) break;
            names = grown;
            cap = ncap;
        }
        if ((names[count] = strdup(e->d_name))) count++;
    }
    closedir(d);
    for (size_t i = 0; i < count; i++) {
        snprintf(dst, sizeof(dst), "%s/%s", dir, names[i]);
        unlink(dst);
        free(names[i]);
    }
    free(names);
}

int dll_overlay_link(const char *runtime, const char *list, const char *set, const char *dir, int required,
                     char *log, size_t loglen)
{
    char names[DLL_OVERLAY_MAX][DLL_OVERLAY_NAME];
    char src_dir[1400];
    size_t used = 0;
    if (loglen) log[0] = 0;
    int n = dll_overlay_names(list, names);
    if (n < 0) {
        if (loglen) snprintf(log, loglen, "bad overlay list \"%s\"", list);
        return -1;
    }
    int total = 0;
    for (int i = 0; i < n; i++) {
        snprintf(src_dir, sizeof(src_dir), "%s/%s/%s", runtime, names[i], set);
        int m = dll_overlay_link_dir(src_dir, dir);
        if (used < loglen)
            used += (size_t)(m < 0 ? snprintf(log + used, loglen - used, "%s%s none", i ? ", " : "", names[i])
                                   : snprintf(log + used, loglen - used, "%s%s %d", i ? ", " : "", names[i], m));
        if (m < 0 && !required) continue;
        if (m <= 0) {
            if (used < loglen) snprintf(log + used, loglen - used, " (%s has no %s set)", names[i], set);
            return -1;
        }
        total += m;
    }
    return total;
}

int dll_overlay_search_path(const char *runtime, const char *list, char *out, size_t outlen)
{
    char names[DLL_OVERLAY_MAX][DLL_OVERLAY_NAME];
    int n = dll_overlay_names(list, names);
    size_t used = 0;
    if (!outlen) return -1;
    out[0] = 0;
    for (int i = n - 1; i >= 0; i--) {
        int w = snprintf(out + used, outlen - used, "%s/%s:", runtime, names[i]);
        if (w < 0 || (size_t)w >= outlen - used) { used = 0; n = -1; break; }
        used += (size_t)w;
    }
    int w = snprintf(out + used, outlen - used, "%s", runtime);
    if (w < 0 || (size_t)w >= outlen - used) {
        if ((size_t)snprintf(out, outlen, "%s", runtime) >= outlen) out[0] = 0;
        return -1;
    }
    return n < 0 ? -1 : 0;
}
