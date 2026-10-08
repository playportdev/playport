# Vulkan performance: Wine's Vulkan present path

**Date:** 2026-10-08. **Plan:** [Vulkan performance](../plans/2026-10-06-vulkan-performance.md)
(PLA-72), work-queue item 1. **Change:** `patches/wine-unix` 0021 (win32u: know the
desktop window before a client surface's per-present update). **Controls:**
[route-v2 controls](2026-10-08-vulkan-perf-controls.md) (IPA `0d4a0f1e…`).

## Why the present path asks the server

Both Vulkan routes made `get_window_parents`, `get_window_rectangles` and
`get_windows_offset` 2.0 times a frame each, DXMT none. In the unix tree (Wine 11.19 plus
`wine-port`, `wine-valve` and `wine-unix`; none of those series touches this code, so it is
WineHQ's as released), `win32u_vkQueuePresentKHR` (`dlls/win32u/vulkan.c`) calls
`client_surface_update` before the host present and `client_surface_present` after it. Both
run `client_surface_update_locked` (`dlls/win32u/window.c`): `NtUserGetAncestor(GA_ROOT)`,
then `get_client_surface_rects`, which calls `get_window_rects(toplevel, COORDS_PARENT)`,
`get_present_rect`, `get_client_rect` and `map_window_points(hwnd, toplevel)`.

None of these needs the server for a window of the calling process. Each walks the window's
parents with `get_win_ptr` and goes to the server only when a parent is
`WND_OTHER_PROCESS`: `list_window_parents` (`get_window_parents`), `get_window_rects`
(`get_window_rectangles`) and `get_windows_offset` (`get_windows_offset`). The game's window
is its own, but its parent, the desktop window, was made by the session's first
pseudo-process (`patches/madeira-unix` 0043). `get_win_ptr` turns another process's window
into `WND_DESKTOP` only when `is_desktop_window` matches the thread's
`user_thread_info.top_window`, and that is set only by `get_desktop_window`. The present
runs on the renderer's own thread (DXVK's, vkd3d-proton's), which never calls it, so for
that thread the desktop is another process's window and each of the three walks ends in its
request: 3 requests an update, 2 updates a present, the 6 a frame measured.

**What the alternatives would have cost.** Caching the rects and invalidating them on
`apply_window_pos` (which already calls `update_client_surfaces`) misses the changes that
come from elsewhere (display mode and DPI changes, the present rect, another
process's move), which is why upstream refreshes on every present. Updating once a present
instead of twice keeps 3 requests a frame. Giving the present thread its desktop handle keeps
upstream's per-present refresh as it is and removes all six: `client_surface_update_locked`
now calls `get_desktop_window()` first (one `get_desktop_window` request on a thread's first
update, a field read after; iOS's `get_desktop_window` in `winstation_ios.c` then calls the
driver's `SetDesktopWindow`, which winios leaves to the null driver). It covers every client
surface (Vulkan and OpenGL share the function); DXMT does not use client surfaces.

**What upstream and Proton do.** At Wine 11.19 the code is as above; the `wine-valve` picks
do not touch `window.c` or `vulkan.c`. Whether a later WineHQ or Proton tree changed it is
not known from this tree.

Host checks: `pp build` (IPA `baa20a27…`, `unix` rebuilt, `libwin32u_unix.a` changed) and
`pp test` passed.
