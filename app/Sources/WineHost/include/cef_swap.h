/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * cef_swap — Playport's own CEF build in place of a client's (decision 0110, PLA-370).
 *
 * Wine's NtCreateFile/NtOpenFile and NtQuery(Full)AttributesFile (patches/wine-unix,
 * dlls/ntdll/unix/file.c) ask playport_cef_swap_path for each resolved Unix name.
 * When the name is one of CEF's runtime files, the open is read-only, and the
 * directory's own libcef.dll has exactly the file version Playport built
 * (VS_FIXEDFILEINFO 143.0.14.0), the file is opened from the app bundle's
 * cef/143.0.14/ instead. The client's files are never changed. Every other open
 * returns after a short string check, with no system call.
 */
#ifndef PLAYPORT_CEF_SWAP_H
#define PLAYPORT_CEF_SWAP_H

#include <stddef.h>

#define CEF_SWAP_VERSION "143.0.14"
/* VS_FIXEDFILEINFO dwFileVersionMS / dwFileVersionLS of 143.0.14.0. */
#define CEF_SWAP_VERSION_MS ((143u << 16) | 0u)
#define CEF_SWAP_VERSION_LS ((14u << 16) | 0u)

/* The Unix path of Playport's copy of unix_name, malloc'd, or NULL to open the
 * client's own file. bundle_dir holds cef/143.0.14/. access, disposition and options
 * are NtCreateFile's. Logs one [cef-swap] line per directory decision and one per
 * file at its first substitution. */
char *playport_cef_swap_path(const char *unix_name, unsigned int access, unsigned int disposition,
                             unsigned int options, const char *bundle_dir);

/* The pieces, for the host test (app/tests/cef_swap_test.c). */

/* The payload-relative name for a client file (its directory's basename and its own
 * basename), or NULL when it is not one of CEF's runtime files. A locale keeps the
 * client's spelling under "locales/", written into buf. */
const char *cef_swap_payload_name(const char *dir_base, size_t dir_base_len, const char *base,
                                  char *buf, size_t buflen);

/* Whether NtCreateFile's arguments open an existing file for reading only. */
int cef_swap_read_only(unsigned int access, unsigned int disposition, unsigned int options);

/* The file version (VS_FIXEDFILEINFO dwFileVersionMS/LS) of the PE image at path,
 * from its standard RT_VERSION resource. 0 on success, -1 when it cannot be read. */
int cef_swap_file_version(const char *path, unsigned int *ms, unsigned int *ls);

/* Forget every cached directory decision, logged file and payload check (tests). */
void cef_swap_reset(void);

#endif
