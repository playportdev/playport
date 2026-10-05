# Portal 2: thread QoS, the E-core stretches and the reload's requests

## Result

- **Every game thread already runs at `USER_INTERACTIVE`.** A census now logs
  each thread's QoS class every 20 s (madeira-unix 0078, `[xp-qos]`). In Portal 2
  and Hollow Knight every guest thread is UI 47/47:
  - the main thread and the game's own threads;
  - DXVK's `dxvk-cs`, `-submit`, `-queue`, `-frame`, `-shader-*` and `-cache`;
  - Unity's job and background workers, and DXMT's encoder;
  - the mmdevapi and XInput threads.

  `server_init_thread` sets UI on every thread through `ios_eco_apply_self`. Only
  the ECO switch lowers it, and it was never on in these runs. So QoS does not
  put the game on the E cores, and no QoS change was made.
- **The E-only stretches move UI threads too.** In `p2-human-720-after` at
  t = 285–305 s, the main thread `002c` ran at a P share of 0.03–0.06 while it
  stayed at UI. The census was not in that build, but its code sets UI on every
  guest thread. Over those stretches:
  - threads waited for a core far more: `[xp]` `run=` was 1150–2700 ms per
    0.3 s window, against 450–650 in normal play;
  - the process retired more instructions for fewer frames: 1600–2500 Minst a
    window against 1200–1450, and 135–195 Mi/f against 97. The main thread rose
    from 32 to 68 Mi/f, and the game threads `0090`–`0098` doubled. On the slower
    cores that is spinning in waits, not more game work.
- **Windows priorities reach no thread.** The census also logs the first 200
  `SetThreadPriority` calls (`[thr-prio]`). The server applies none of them on
  iOS, as `apply_thread_priority` returns early. The calls each title makes:
  - Portal 2: LOWEST (-2) on DXVK's six shader workers; TIME_CRITICAL (15) on
    two threads; ABOVE_NORMAL (1) or HIGHEST (2) on a few more. The main
    thread also sets NORMAL (0) on its six job threads `0030`–`0044` again and
    again: 178 of the first 200 calls.
  - Hollow Knight: LOWEST on its 16 background job workers, TIME_CRITICAL on 12
    threads, including DXMT's encoder and finisher.

  No priority-to-QoS mapping was made. The [QoS record](2026-09-25-hk-thread-qos.md)
  found that `utility` on helper threads made the periodic stalls worse and did
  not delay the P-core loss. Applied to DXVK's shader workers, it would also
  lengthen the first-pipeline-build hitches that the CS thread waits on.
- **The death reload's ~3100 `open_key` are already gone.** They were XInput's
  device scan on every poll, which wine-pe 0028 limits. In
  `p2-human-720-after`, which runs on that build, the reload's seconds
  (08:24:20–08:24:27) have 1 `open_key` in all; the earlier build had 3181 in one
  second. No key diagnostic was kept: a draft `[srv-key]` patch logged only four
  start-up opens in a scripted reload, and it was dropped.
- **What the reload costs now.** Its busiest second makes 28,900 requests with
  552 ms of round trips. The largest counts are 13,238 `select` and 9,113
  `event_op`, which are the loader threads' waits. Then come 2,088
  `set_thread_info` (the game's `SetThreadPriority` loop), 2,087
  `add_fd_completion`, and 1,044 each of `get_thread_info` and `create_event`.
  The burst of about 1,240 `close_handle` the second before is the game freeing
  its handles, one request each. None of these is cheap to remove:
  - skipping a repeated `set_thread_info` needs the target's current priority,
    which costs a request of its own;
  - the selects and event operations are the game's own synchronisation.

Final IPA: `.work/out/20261005-085254-61647727/Playport-26.5-61647727.ipa` (dev),
SHA256 `6164772744c1e321e9b8840a95f538843399392453415e0e0614fe9ea574dabd`. It has
madeira-unix 0078 on 171b948 and passes its 78 IPA checks. It is installed.

## Runs

| Run | IPA | What | Result |
| --- | --- | --- | --- |
| `p2q-before` | `bcae3ed1` | `pp perf --title app-620 --secs 240 --cool 3 --pad first-frame+30:p2-cold-boot --pad first-frame+70:p2-walk` | 59.3 FPS mean, p10 59.7; play at P 75–90 % / E 33–56 %; no E-only bucket; thermal nominal to fair (from t = 215), no CPMS budget; 52.5 requests a frame |
| `p2q-loadlast` | `bcae3ed1` | `--secs 150`, `p2-cold-boot` at +30, the new `p2-load-last` at +80 (pause menu, LOAD LAST SAVE, confirm) | the reload's hitches were 213, 283, 617 and 208 ms (t = 87.7–93.6); no `open_key` burst; the CPMS budget fell to 769 mW (t = 135–150) and the P cores stayed busy at 77–87 % |
| HK | `61647727` | `pp ui --play app-367520 --until first-frame+10 --shot` | first frame at +9.10 s (+9.83 s in the previous record), ran on to the stop |

`bcae3ed1` is the final build plus the draft `[srv-key]` patch in wine-unix, which
only logs. So the Portal 2 runs stand for the final IPA. The 180 s `p2r-after`
of the previous record held 58.9 FPS mean and 59.3 at p10.

## The census

The `[xp-qos]` lines in `p2q-before` give each thread as
`id:name:class:base/current priority`:

| Thread | Class (base/current) |
| --- | --- |
| guest threads (main `002c`, `0024`, `0030`–`0044`, `0090`–`009c`, all `dxvk-*`, mmdevapi, XInput) | UI (47/47) |
| `wine-x18-exc`, the app's main thread and two unnamed native threads, one of them the busiest native thread (by its CPU, the wineserver's `main_loop`) | UI (47/47) |
| `com.apple.coremedia` root queue | none set (47/47) |
| GCD worker threads (Metal and app queues) | IN, UT or DEF; the kernel raises one to 47 while it serves UI work |
| `wine_disk$0`, `wine-stale-heal`, two idle helpers | DEF (31/31) |
| Hollow Knight's `AURemoteIO::IOThread` | real-time (97/97) |

Under the scripted load, the busy threads outside the guest are that UI thread
(`m5319844`, 11 % of a core, P share 0.71) and `wine-x18-exc` (6 %, 0.60).

## What is still open

- **Why the P cores go idle.** This happened in human plays only. In
  `p2-human-720` it was at the 769 mW budget (t = 215–230 and 255). In
  `p2-human-720-after` it was at 2199 mW (t = 255–260) and at 1688 mW
  (t = 285–300). No scripted run has shown it, not even `p2q-loadlast` at 769 mW.
  The census in this IPA records each thread's class through the next human
  play, so it can show whether any QoS changes during such a stretch.
- **Spinning on the E cores.** The extra instructions point at spin-waits, either
  the game's or the runtime's adaptive yield. Its share was not measured.
