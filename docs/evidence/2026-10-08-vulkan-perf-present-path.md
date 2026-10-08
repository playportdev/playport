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

Host checks: `pp build` (`unix` rebuilt, `libwin32u_unix.a` changed) and `pp test` passed.

## On the phone

**IPA:** dev `baa20a273bfbc25cbfb3328bfc924c6abe87c11db4bbace99823106bc1504a96`, built from
`vulkan-performance-2` at `977e26d` (the controls' IPA plus `wine-unix` 0021). Phone:
iPhone18,4, iOS 27.0, on charge at 100 %, unattended. One locked session: `pp install
--no-build` (upgrade in place), the gate, then the DXVK run; the vkd3d run after it.

| play | run | first frame | result |
|---|---|---|---|
| Hollow Knight, default backend (DXMT) | `ui-runs/20261008T031215` | +9.56 s (JIT 2.46 s) | `first-frame+10` |
| Portal 2, default backend | `ui-runs/20261008T031307` | +5.56 s (JIT 2.52 s) | `first-frame+10` |

Route v2, burst, 720/free (`burst.sh NAME dxvk|vkd3d`), each started at thermal `nominal`
after the 15-minute rest; neither log has a `ui: undo session` or `Metal HUD off` line
(PLA-82). Figures: `pp perf --compare CONTROL RUN --window 85:125`.

| run | FPS | p50 | p99 | p99.9 | ≥25/50/100 | GPU ms | Mi/f | CPU% | CPU mW | sys mW | srv/f |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `vk-v2-dxvk-2` (control) | 118.5 | 8.34 | 12.5 | 25.01 | 7/0/0 | 5.81 | 61.5 | 132.3 | 1858 | 6090 | 17.84 |
| `vk-v2-dxvk-presentfix-1` | 118.3 | 8.34 | 16.67 | 25.01 | 8/0/0 | 5.81 | 60.8 | 129.5 | 1805 | 6294 | 12.10 |
| `vk-v2-vkd3d-1` (control) | 118.0 | 8.34 | 16.67 | 20.84 | 4/0/0 | 5.85 | 66.6 | 122.5 | 2060 | 6877 | 23.19 |
| `vk-v2-vkd3d-presentfix-1` | 118.0 | 8.34 | 16.67 | 29.18 | 8/0/0 | 5.86 | 65.1 | 119.8 | 2051 | 7663 | 17.00 |

| | DXVK control | DXVK 0021 | vkd3d control | vkd3d 0021 |
|---|---|---|---|---|
| `get_window_parents` / `get_window_rectangles` / `get_windows_offset` a frame | 2.1 each | 0 | 2.1 each | 0 |
| the present thread's requests a frame (`dxvk-submit`, t = 0–60) | 6.2–6.6 | none in the table | – | – |
| server round-trip time a frame (t = 90, 105) | 0.56, 0.58 ms | 0.40, 0.41 ms | 0.81, 0.80 ms | 0.61, 0.63 ms |
| wineserver thread Mi/f (t = 90, 105) | 4.47, 4.50 | 3.43, 3.46 | 5.72, 5.69 | 4.58, 4.56 |
| all threads Mi/f (t = 90, 105) | 59.0, 63.9 | 57.9, 63.1 | 64.3, 68.5 | 63.0, 67.3 |

(The wineserver thread is the host thread the log names in `wineserver_main starting … on
thread m…`.)

**Result.** The three requests are gone on both routes: DXVK's srv/f is DXMT's now (12.1
against 12.0), vkd3d's drops by 6.2 to 17.0 (its own five a frame remain: `event_op`,
`release_semaphore`, `set_queue_mask`, `get_message`, `select`). The wineserver thread does
about 1.1 Mi/f less (−23 % DXVK, −20 % vkd3d), all threads 0.7 and 1.5 Mi/f less, CPU power
53 and 9 mW less. FPS, p50 and GPU time do not move. p99 on DXVK went from 12.5 to 16.67 ms,
one 120-Hz step; DXVK's p99 was 16.7 ms in the step-1 burst set too, so it moves between the
two from run to run, and the change only removes work from the present thread. vkd3d's
p99.9 and hitches ≥25 ms (4 → 8) and both runs' sys mW (+204, +786; the charger-side
`SystemLoad`, which CPU mW does not follow) are read the same way: single runs, not caused by
fewer server calls. The end screenshot of the DXVK run shows the Knight in King's Pass with
the HUD on, drawn as before.

**Kept** (rule 4): the change does what it was for, costs nothing measured and is a strict
reduction in work. The gap left on DXVK is not in wineserver requests.

## Games observed

- Hollow Knight (367520): gate on DXMT, `first-frame+10`; route-v2 runs on DXVK and vkd3d,
  both in play at the end.
- Portal 2 (620): gate, `first-frame+10`.
