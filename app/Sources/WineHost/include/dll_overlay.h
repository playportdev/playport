/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * dll_overlay — the runtime's DLL sets a launch links into the prefix's DLL
 * farms (drive_c/windows/system32, sysarm64, syswow64).
 *
 * A farm is the runtime's own <arch>-windows set, with the launch's overlays
 * (PLAYPORT_DLL_OVERLAY) linked over it: a comma-separated list of runtime
 * directories, each with <arch>-windows sets of its own, applied in order, so
 * a later one's file replaces an earlier one's. The Direct3D backend's set
 * (Runtime/vulkan, decision 0014) comes first; the Khronos Vulkan loader's
 * (Runtime/vulkan-loader, decision 0131) after it. DLLs load through these
 * links, so they decide which file a name loads. Every link into a runtime set
 * is removed before a farm is relinked, so a launch without an overlay gets
 * the runtime's own file back (Wine's vulkan-1.dll after a Khronos one).
 */

#ifndef DLL_OVERLAY_H
#define DLL_OVERLAY_H

#include <stddef.h>

#define DLL_OVERLAY_MAX 4
#define DLL_OVERLAY_NAME 64

/* The overlay names of list, in order, into names. A name is a plain runtime
 * directory name: not empty, no '/', ':' or "..", shorter than
 * DLL_OVERLAY_NAME. Returns the count (0 for a NULL or empty list), or -1 when
 * any name is bad or there are more than DLL_OVERLAY_MAX: the whole list is
 * refused, so a launch gets no overlay rather than part of one. */
int dll_overlay_names(const char *list, char names[DLL_OVERLAY_MAX][DLL_OVERLAY_NAME]);

/* Link every file of src_dir into dir, replacing what is there; the count
 * linked, or -1 when src_dir cannot be opened. */
int dll_overlay_link_dir(const char *src_dir, const char *dir);

/* Remove every link in dir into an <arch>-windows set, the runtime's or an
 * overlay's, of this or an earlier bundle path; other entries stay. */
void dll_overlay_unlink_runtime_links(const char *dir);

/* Link each overlay's runtime/<name>/<set> into dir, in list order. An
 * overlay with no such set is skipped unless required; with required, an
 * overlay that links nothing fails the farm. Returns the links made, or -1
 * (a bad list, or a required overlay with nothing linked); log gets one line
 * naming each overlay's count, or what failed. */
int dll_overlay_link(const char *runtime, const char *list, const char *set, const char *dir, int required,
                     char *log, size_t loglen);

/* WINEDLLPATH for list: each overlay's runtime/<name>, the last first (it wins
 * in the farms too), then runtime. Returns 0, or -1 when out is too small or
 * the list is bad (out then holds runtime alone when it fits). */
int dll_overlay_search_path(const char *runtime, const char *list, char *out, size_t outlen);

#endif
