/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * title_path — resolve a title's executable, named by a DOS path, inside the
 * Wine prefix, the way a player's launch names it.
 *
 * A probe is a bare file name in the bundle's PE set, linked into
 * C:\windows\system32. A title is a staged tree under the prefix's drive_c,
 * started by the DOS path of its executable, and it finds its data files
 * relative to that executable's directory, which must therefore be its
 * working directory. This resolves the name the caller gives into the three
 * forms the launch needs: the DOS path Wine is started with, the DOS
 * directory that becomes the working directory, and the host path, which is
 * checked to be a regular file before anything is launched.
 */

#ifndef TITLE_PATH_H
#define TITLE_PATH_H

#include <stddef.h>

typedef struct {
    char dos[1024];        /* C:\Games\Hollow Knight\hollow_knight.exe (on-disk case) */
    char dos_dir[1024];    /* C:\Games\Hollow Knight (C:\ for an exe at the drive root) */
    char unix_path[2048];  /* <prefix>/drive_c/Games/Hollow Knight/hollow_knight.exe */
} title_path;

/* path names the executable on drive C, in any of these spellings:
 *   C:\Games\Title\title.exe    absolute, drive C only
 *   \Games\Title\title.exe      rooted, on drive C
 *   Games\Title\title.exe       relative, taken from C:\ (the staged-title form)
 * '/' is accepted as a separator. Each component is matched against
 * <prefix_dir>/drive_c case-insensitively for ASCII letters, as Wine matches
 * names, preferring an exact match; the result carries the on-disk case.
 * Rejected: another drive (only C: maps into the prefix), empty, "." and ".."
 * components, characters Windows forbids in a name, and anything that is not
 * a regular file. Returns 0, or -1 (bad name), -2 (not found), -3 (not a
 * regular file), -4 (too long); msg gets a one-line reason either way. */
int title_path_resolve(const char *prefix_dir, const char *path, title_path *out, char *msg, size_t msglen);

#endif
