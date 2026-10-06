# Wineserver requests per frame, and in-process sync on and off

**Date:** 2026-09-28. **Tree:** origin/main `6a53077` (after the Wine-on-Proton
plan) plus madeira-unix 0037 (the `[srv]` census; it was 0035 in these IPAs,
before the branch was rebased onto main's 0035 and 0036) and wine-unix 0006
(below).
**Phone:** iPhone Air (`iPhone18,4`), iOS 27.0, over netmuxd Wi-Fi. Every run
started at `thermal_start: nominal`. hk-a, w3-a and w3-a2 ran on battery or
with a charger plugged in partway through; w3-b2 and hk-b ran on a charger
(`summary.json` has each). Settles item 3 of the
[runtime-risks plan](../plans/finished.md#runtime-risks); the decision is
[0023](../decisions/0023-in-process-sync-stays-off.md).

**Result:**

- **The Wine-on-Proton plan changed nothing here.** It took none of Valve's
  fsync and ntsync commits, and `inproc_sync` is wine-11.18's code. Every NT
  wait still goes to the in-process wineserver, and madsync is still opt-in
  (madeira-unix 0014).
- **Hollow Knight: the main thread's server time is under 1 %.** In play
  (King's Pass, t = 105 to 180 s) the whole process makes 14 to 16 server
  requests a frame: 6 to 7 `select`, 3 `release_semaphore`, 3 to 4
  `set_timer`, 1 `event_op`. The main thread (`0024`, 86 to 90 % busy) makes
  2.1 to 2.3 a frame, all `select`s that almost never block. Its round trips
  take 0.09 to 0.11 ms a frame, 0.8 % of its time.
- **The Witcher 3: server traffic is large, but the GPU sets the frame rate.**
  Walking Kaer Morhen (t = 60 to 150 s), the process makes about 425 requests
  a frame: about 250 `select`, 125 `release_semaphore`, 55 `event_op`. The four
  `red Task Thread`s each spend 10 to 20 % of their time in round trips, and
  the main thread 5 to 10 %. The in-process wineserver thread is the second
  or third busiest thread (22 to 40 % of a core). But the GPU is 97 to 99 %
  busy and its time per frame equals the frame time (56 to 60 ms).
- **In-process sync on removes the traffic and not the frame limit.**
  inproc-sync on first crashed at start (below). With that fixed:
  - The Witcher 3 drops to 9 requests a frame, and the wineserver thread
    leaves the busiest threads. Process CPU falls from 153 % to 136 % and the
    CPU's power from 265 to 222 mW. The frame rate stays GPU-bound: 16.3 FPS,
    against 17.5 and 15.9 FPS off.
  - Hollow Knight drops to 4 requests a frame, and the main thread makes
    none. Its work stays at 18.6 to 21.2 Mi/f, as with sync off.
- **`inproc-sync = 1` crashed at start on the wine-11.18 port.** The first
  process's `server_init_process` closes a handle before its TEB is set.
  `close_inproc_sync` then looked up the per-process cache through
  `NtCurrentTeb()->Peb`, a NULL TEB (`KERN_INVALID_ADDRESS at 0x60`, run
  w3-b). wine-unix 0006 gives a thread with no PEB an empty cache. Nothing
  changes with sync off: `close_inproc_sync` returns first there.
- **Decision: sync stays as it is** ([0023](../decisions/0023-in-process-sync-stays-off.md)).
  Neither title is limited by server waits. Making madsync correct (system
  APCs, and per-object waits instead of one global mutex) would save The
  Witcher 3 about 40 mW of CPU and no frames.

## 1. The census (madeira-unix 0037)

`server_call_unlocked` counts each request by kind in its thread's slot, with
the wall time of the round trip. The kinds are `sel` (select), `ev` (event),
`mtx` (mutex), `sem` (semaphore), `hdl` (handles), `msg` (message queue) and
`oth` (everything else). `server_select` adds the time a pending select blocks
for its wake-up, and counts the selects that blocked. Once a second the xprobe
thread logs:

- `[srv]`: the process's totals and its ten busiest request types;
- `[srv-t]`: each thread's counts, round-trip ms, blocked ms and blocked
  selects.

`pp perf --analyze` reads these lines into:

- the `srv/f` column;
- `server.txt`, which lists, per 15 s, the threads with the most round-trip
  time and marks with `*` the thread that retired the most instructions;
- `summary.json`'s `server`, per frame over the played buckets, for the
  process and for the busiest thread.

A select's blocked time is counted when the select ends. So a thread that
wakes from a long wait shows more than 100 % in its window, and blocked time
is only meaningful over whole runs. The name table lacks
`get_inproc_sync_fd`, which shows as `req297` in the in-process-sync runs.

## 2. IPAs

| IPA | what | sha256 |
|---|---|---|
| A | main + madeira-unix 0037 | `50c864748d13a06af4024d7e72c8b1aa6713c926e2606a2f239720b5395867db` |
| B | A with madsync on by default (0014's default flipped; not committed) | `596a79215fa1c96c20153cdad8401434b282c2ddfa94010c910199ca28e3dbe0` |
| A′ | A + wine-unix 0006: the branch | `71210dfc808892dc759f06bf935439e9d89795b0ac69119d4bab2d0baf485d31` |
| B′ | A′ with madsync on by default (not committed) | `38c3cdbbf7c30c1b1f9bf423db34a27ab0f8bdd65cf03228fd908b8b0adeae0b` |

## 3. Runs

Hollow Knight:

```
pp perf --secs 180 --pad first-frame+35:hk-new-game --pad first-frame+90:hk-walk
```

The Witcher 3 (`--title app-292030`), with `--cool 8`:

```
pp perf --title app-292030 --secs 150 --cool 8 --pad first-frame+10:witcher3-continue --pad first-frame+50:witcher3-walk
```

w3-a used `--cool 5`.

| run | IPA | sync | play window | FPS | GPU ms | GPU busy | CPU % | CPU mW | requests/frame | round trips ms/frame (all threads) |
|---|---|---|---|---|---|---|---|---|---|---|
| hk-a | A | off | 105–180 s | 85.7 | 9.9 | 88 % | 247 | 258 | 14.2 | 1.2–1.6 |
| hk-b | B′ | on | 105–180 s | 79.2 | 9.7 | 84 % | 244 | 238 | 4.0 | 0.4–0.6 |
| w3-a | A | off | 60–150 s | 17.5 | 56.4 | 98 % | 153 | 265 | 425 | 35–48 |
| w3-a2 | A | off | 60–150 s | 15.9 | 60.1 | 97 % | 279 | 262 | 424 | 36–78 |
| w3-b | B | on | – | crashed at start (§ above) | | | | | | |
| w3-b2 | B′ | on | 60–150 s | 16.3 | 60.5 | 98 % | 136 | 222 | 9.1 | 2.8–3.5 |

- **Hollow Knight.** Both runs parked the P cores (P% 0 to 1) under thermal
  pressure 20. The frame rates differ within what that throttling varies by.
  The main thread's work did not change (`threads.txt`: 17.8 to 21.0 Mi/f in
  hk-a, 18.6 to 21.2 in hk-b), and neither did the GPU time.
- **The Witcher 3's runs are GPU-bound.** w3-a2 ran under a lower CPU budget
  (404 mW, E cores at 0.84 GHz). There the round trips took longer: 70 to
  150 µs each against 45 µs in Hollow Knight, and the task threads spent up to
  20 % of their time in them. The frame rate still followed the GPU.

Hollow Knight's main thread, hk-a (`server.txt`):

| window | FPS | requests/frame | blocked selects/frame | round trips ms/frame | share of its time |
|---|---|---|---|---|---|
| 105 s | 92.1 | 2.14 | 0.01 | 0.087 | 0.76 % |
| 120 s | 84.7 | 2.23 | 0.08 | 0.100 | 0.76 % |
| 135 s | 86.2 | 2.08 | 0.52 | 0.097 | 0.81 % |
| 150 s | 79.2 | 2.05 | 0.05 | 0.101 | 0.78 % |
| 165 s | 87.0 | 2.28 | 0.28 | 0.107 | 0.82 % |

The Witcher 3's threads, w3-a, window 90 s (18.0 FPS, 411 requests a frame):

| thread | requests/frame | of which select / semaphore / event | round trips ms/frame | share of its time | blocked |
|---|---|---|---|---|---|
| `red Task Thread` 1–4 (each) | 77–85 | 50 / 21–27 / 5–7 | 6.6–7.2 | 12–13 % | 80 % |
| main `0024` | 45 | 18 / 11 / 10 | 3.3 | 6.1 % | 71 % |
| RenderThread `0080` | 16 | 2 / 11 / 0 (and 2 mutex) | 2.2 | 4.1 % | 0 % |
| busiest `0054` | 7 | 6 / 0 / 1 | 0.4 | 0.7 % | 77 % |

With sync on (w3-b2), the task threads make 0.5 to 0.6 requests a frame and
spend about 1 % of their time in round trips. The main thread makes 6.4, for
the message queue and handles.

The runs' directories (`summary.json`, `server.txt`, `threads.txt`,
`this-launch.log`) were in the lane's build area and are not kept.

## 4. Plays of the branch

These are `pp ui --play app-367520 --until first-frame+10 --shot`:

- A′: first frame at +11.12 s (`jit: acquire(896 MiB) -> 0 after 3.10 s`);
- B′ with sync on: first frame at +9.44 s.

Both ran on to first frame + 10 s with no crash report.

The branch head (rebased onto main, the census as madeira-unix 0037), IPA
`eb7de3b0c6595bf1f02a8ef69182456d9367b20b0d4dc43ac8a9eed8eed86458`: first
frame at +10.45 s, on to first frame + 10 s with no crash report, and its
`[srv]` lines logged once a second.
