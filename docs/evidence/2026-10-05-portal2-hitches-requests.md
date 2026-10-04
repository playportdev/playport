# Portal 2: what the in-play hitches are, and fewer wineserver requests a frame

## Result

- **Every hitch over 150 ms in two 5-minute human plays has a cause.** There are two
  kinds. Most are the reload after a death, and the rest are the first build of a
  render pipeline. No hitch is left unexplained. Neither kind is JIT, and the ones
  that are not pipeline builds are not shader work either.
  - **Death reload:** the game reloads its autosave, and the hitches up to 625 ms
    in the 239–246 s and 195–201 s clusters are that load.
  - **First pipeline build:** KosmicKrisp builds a pipeline in Metal the first time
    a draw needs it. That took 200–390 ms at 62 s, 100 s, 139 s and 210 s. The
    shader cache keeps the pipeline after that: the second play, at 540p, built only
    3 new shaders, and none of the first play's slow builds came back.
- **Two cheap request fixes** take Portal 2 from 56.9–58.4 to 50.8 wineserver
  requests a frame. That is the same scripted 180 s run, before and after, and the
  main thread's requests fall from 28 to 21.5 a frame:
  - **wine-pe 0028:** XInput scans an empty pad slot's device list at most once a
    second. Before, it scanned on every poll, which cost 3.75 `open_key` a frame.
  - **wine-unix 0014:** `NtUserSetCursor` returns at once when the cursor is already
    set, which saves 3 `set_cursor` a frame.
- **Hollow Knight** reaches its first frame (+9.83 s) and runs to `first-frame+10`
  on the same IPA. Its rate at the main menu is unchanged, 983 requests a second
  against 982 before.

IPA: `.work/out/20261005-003816-86ba2d6c/Playport-26.5-86ba2d6c.ipa` (dev), SHA256
`86ba2d6cc409ef32dfa594735df147bb1c23ed39ae99a08c34d2e7a6c46bd362`. Its 78 IPA checks
pass. The Hollow Knight play and the scripted Portal 2 run below used it, and it is
installed. The build after the patch messages were reworded has the same
`artifacts.tsv`: only the signatures and profiles differ. That build is
`.work/out/20261005-004915-a7463cc5/Playport-26.5-a7463cc5.ipa`, SHA256
`a7463cc5691d3c126ea06fc1256abb04f8732d598fabfb03521e5b802d484138`.

## The hitches

The plays are `p2-human-720` and `p2-human-540`: `pp perf --title app-620 --secs 300
--settings '{"screen":"720"}'` (and `"540"`), on IPA `7d5d8b3d…`. In each, a person
played the same chamber: portals, the tunnels, and one death with its reload. There
was no map change. The times below are seconds from the first HUD frame
(`hitches.txt`). They are matched to the log lines around them by the wall clock that
the `[xp]` census writes four times a second.

| Run | t (s) | Frame (ms) | Cause |
| --- | --- | --- | --- |
| 720 | 62.1, 62.4 | 484, 154 | first pipeline builds after the load: `[kk-compile] render ms=391`, then 67, 67 and 54 |
| 720 | 100.2 | 217 | first pipeline build, `ms=201` |
| 720 | 139.4 | 354 | first pipeline build, `ms=338`; at 139.08 the periodic `[thread-sample]` finds `dxvk-cs` waiting in `kevent_id` (a libdispatch wait) |
| 720 | 239.3–245.8 | 238, 333, 154, 600, 275 | death reload (below); 245.8 also has a 41 ms build |
| 540 | 195.0–201.4 | 242, 333, 625, 233 | death reload, with the same signature |
| 540 | 210.3 | 317 | first pipeline build, `ms=225` |

**Death reload.** Both clusters begin with the same steps:

1. The game checks its save directory:
   `[file-wfail]` creates of `…\portal2\SAVE\<id>\` answer "already exists".
2. There is a burst of about 1230 `close_handle` in one second.
3. There is a second of about 3100 `open_key` on the main thread (`002c`), which take
   118 ms of round trips, then about 600–700 more.
4. Six loader threads each make about 2000 selects and up to 1400 event
   operations in a second.

At 769 mW (`serious`), parts of the load ran on the E cores only, at about 1 GHz:
`[xp]` reads `P=0 E=137…191`, `GHz E=0.95–1.07`. The reload is the game's own work,
and the thermal limit stretches it. Which registry keys the load opens was not
traced.

**First pipeline build.** A `[kk-compile] render ms=N` line is a Metal build over
20 ms (mesa 0016). These builds are pipelines that no earlier launch had made:

- The 720 play translated 54 shaders, which took 5494 ms, 5377 ms of it in Metal.
  It logged 41 builds over 20 ms and 19 over 100 ms.
- The 540 play came later on the same install. It translated 3 shaders and logged 4
  long builds. None of them had an MSL hash from the 720 play's builds.

So the disk cache of mesa 0015 covers a pipeline from its second use on. A new area
of a map costs one hitch per new pipeline, once per install. This corrects the
shader-cache record's "no build over 20 ms": that was a run in a chamber the cache
had already seen.

## The requests

`[srv]` counted 77 requests a frame in the 720 play. Its main thread made 34 of them,
with 0.94 ms of round trips a frame. Three of the request types came from that
thread alone:

- `set_cursor`, 7.18 a frame;
- `open_key`, 3.62 a frame;
- `get_message` and `accept_hardware_message`, 3.59 a frame each.

The ratio of 2 `set_cursor` to 1 `accept_hardware_message` held in every second.

- **`open_key` was XInput.** A `wine_xinput_hid_update` thread was running. It
  starts only when the host snapshot has no pad in a slot that the game polls.
  `xinput_get_state` then ran `update_controller_list()` on every poll of an empty
  slot: `SetupDiGetClassDevsW` and its registry keys. That thread already rescans
  every 2 s and on a device notification. wine-pe 0028 skips the poll's scan when
  any scan ran in the last second. Over the whole after-run, 36 `open_key` are
  left.
- **`set_cursor` was `SetCursorPos` plus `SetCursor` with the same cursor.** The
  diagnostic madeira-unix 0077 logs each second's `set_cursor` requests by call, as
  `[srv-cur] … handle= count= pos= clip= get=`. After the fix, the requests are all
  `pos` (about 280 a second), and `handle` is 14 in the whole run. Before the fix,
  `set_cursor` was 6.1 a frame against 3.1 after. So about 3 a frame were
  `NtUserSetCursor` with the cursor that the thread input already had. A
  WM_MOUSEMOVE that a `SetCursorPos` queues brings that `WM_SETCURSOR`. wine-unix
  0014 reads the thread input's shared memory and returns the same handle without
  the request. A handle that is not a live cursor of the process still goes to the
  server, for its error.
- **Kept on purpose:** `SetCursorPos` about 3 a frame, and the `get_message` and
  `accept_hardware_message` that its WM_MOUSEMOVE brings. That is 9 requests a
  frame. The server queues a WM_MOUSEMOVE for every `SetCursorPos`, even to the
  same position, deliberately (Wine 3909f51), as Windows does. Dropping it would
  change what a game sees.
- **Not attributed:** `create_event` and `close_handle`, at 2.9 a frame in the
  scripted run and 5 in play. They come from the main thread and three unnamed game
  threads (`0090`, `0094`, `0098`), and the XInput fix did not change them.

The scripted runs are `pp perf --title app-620 --secs 180 --pad
first-frame+30:p2-cold-boot --pad first-frame+75:p2-walk`, with the default settings.
`p2c-warm` and `p2m3e-after` were run before this change, on IPAs `090b7613…` and
`05dcdeb7…`. They were re-analysed with `pp perf --analyze` for the `server` figures.

| Run | IPA | srv/f | set_cursor/f | open_key/f | main req/f | main rt ms/f | main Mi/f (t ≥ 90) | FPS mean |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `p2c-warm` | `090b7613` | 56.92 | 6.13 | 3.75 | 27.95 | 0.849 | 24.3 | 58.0 |
| `p2m3e-after` | `05dcdeb7` | 58.36 | 6.25 | 3.80 | 28.63 | 0.781 | 24.3 | 59.0 |
| `p2r-after` | `86ba2d6c` | 50.81 | 3.10 | 0 | 21.54 | 0.623 | 23.8 | 58.9 |

The main thread's round trips fall by 0.16–0.23 ms a frame, and its instructions per
frame by about 2%. That is a small gain. The frame rate is not comparable between
these runs: `p2c-warm` started hot, at a 769 mW budget, and `p2r-after` stayed at
"fair". The scripted run held 60 at p10 (59.3) and ended with no fault, refusal or
pool exhaustion.

## Not checked

- No 5-minute human play has run on this IPA, so its in-play request rate (about 70
  a frame is expected, from 77) is not measured.
- Hollow Knight was played to `first-frame+10` only. At its main menu it made about
  983 requests a second, with no per-frame `open_key` or `set_cursor`, before or
  after.
