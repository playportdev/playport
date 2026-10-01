# Hollow Knight: in-process sync and the Metal HUD's cost

*The raw logs, tables and screenshots this record names were removed in the 2026-09-25 repository cleanup; they remain in git history.*

**Date:** 2026-09-25. **Tree:** the commit that adds `perf-run.py --no-hud`
and `--frames`. **Build:** the lane build from the
[thread-QoS record](2026-09-25-hk-thread-qos.md), still installed, IPA sha256
`62e149af5ef540aa739592b89a08137958d4c2e64814d35be38ae0e7f52bb80f`. Every run
logged `[thr-qos]` lines and FEX build id `rev=ml908 compiled Sep 24 2026 23:29:34`,
the same as that record's runs.
**Phone:** iPhone Air (`iPhone18,4`, A19 Pro: 2 P + 4 E cores), over
netmuxd Wi-Fi, on a 15 W charger. Every run was under
`flock $PLAYPORT_BUILD/device.lock`.

**Result:**

- **In-process sync.** With `inproc-sync = 1` in madeira.cfg, Hollow Knight
  loads, reaches King's Pass and plays the scripted walk as before. Wineserver
  requests fall from 1,333–1,389/s to 317–322/s. The busiest native thread
  falls from 2.8 to 1.7–1.9 million instructions per frame (Mi/f); by its CPU
  share it is the in-process wineserver's loop. The main thread's work does not
  change, so the whole process does about 1 Mi/f less, 2 %.
- **The Metal HUD.** Its per-frame log lines cost native (GCD) threads about
  1.6 Mi/f. The process does 2.5 Mi/f less without it (4.5 %): menu CPU falls
  from 85 % to 74–75 % of one core. Every measured run so far carried this cost.
- **Frame counting without the HUD.** Frames counted from DXMT's
  per-16-present lines match the HUD's frame counter: the median difference
  per 5 s bucket is 0.1–0.2 FPS, and 41 or 46 of 48 buckets differ by 1 FPS
  or less.
- **Thermal outcome.** Neither change can be judged on its thermal outcome
  from these runs. nohud1 started while the thermal pressure level was still
  raised from the run before, and throttled early.

## 1. Runs

All three runs used `perf-run.py --secs 240 --env HOST_SCREEN=720
--vpad 48:harness/device/vpad/hk-new-game.txt --vpad 103:harness/device/vpad/hk-walk.txt
--env WINE_IOS_THREAD_QOS=UnityGfxDeviceWorker=utility,Job.Worker=utility,Background Job.Worker=utility,dxmt-=utility,Loading.=utility`.
Each started about 9 minutes after the previous run ended.

| run | madeira.cfg | Metal HUD | notes |
|---|---|---|---|
| qos4 | absent (inproc-sync off) | on | from the [thread-QoS record](2026-09-25-hk-thread-qos.md) |
| sync1 | `inproc-sync = 1` | on | log: `[madsync] ml1058 in-process synchronisation ENABLED` |
| nohud1 | `inproc-sync = 1` | off (`--no-hud`) | frames from DXMT's Present lines |

madeira.cfg was removed again after nohud1, leaving it absent as before.

## 2. Work per frame

In `compare.txt`, the menu is
t = 60–90 s and gameplay (King's Pass, `hk-walk.txt`) is t = 105–150 s, where
t counts from the first frame line. The figures are Mi/f from the census's
`[xp-t]` lines. That line lists only the up to 14 threads with at least 2 ms
of CPU in each 250 ms tick, so `all` leaves out the smallest threads.
`native` sums the native (`m<n>`) threads, and `top native` is the busiest of
them.

```
run     phase       fps   all  0024  00b0  00c0  009c native top native other
qos4    menu      119.6  24.8   5.7   3.6   3.1   2.7    8.8   2.8   0.9
qos4    gameplay  119.3  56.8  21.1  11.3   6.3   5.8    9.3   2.8   2.9
sync1   menu      119.3  23.6   5.7   3.6   3.0   2.7    7.7   1.7   0.8
sync1   gameplay  119.4  55.9  21.4  11.3   6.2   5.8    8.3   1.9   2.8
nohud1  menu      119.3  21.2   5.5   3.4   2.9   2.4    6.1   1.7   0.9
nohud1  gameplay  119.3  53.4  20.6  11.4   6.1   5.4    6.7   1.9   3.1
```

The busiest native thread is `m522279` in qos4, at about 5 % CPU and a P-core
share of about 0.87. In the same run, `[thread-sample]` shows the in-process
wineserver's `main_loop` (in `semaphore_timedwait`) at 4–10 % CPU. That loop
wakes at least once per millisecond (`fd_ios.c`, a 1 ms tick) even with no
request, and that is the part in-process sync cannot remove. The HUD's lines are
written by GCD worker threads (`S1Probe[pid:<thread>] metal-HUD:`), each about
0.5–1.2 Mi/f, and these are what disappear in nohud1.

Per-thread tables: `sync1-threads.txt`,
`nohud1-threads.txt`. The
qos4 table is in the thread-QoS record.

## 3. Server traffic

The runtime's `[sync-census] ml1115` line, from the 20 s `[thread-sample]` burst
(`qos4-sync-census.txt`,
`sync1-sync-census.txt`,
`nohud1-sync-census.txt`):

| run | server requests/s in gameplay | thread alerts (wakes/s) |
|---|---|---|
| qos4 | 1,333–1,389 | 6,400–14,700 |
| sync1 | 318–322 | 10,400–14,700 |
| nohud1 | 317 | 12,500–13,000 |

In-process sync removes the wineserver round trips for waits and wakes on NT
sync objects (events, semaphores, mutexes). Thread alerts (the
`NtWaitForAlertByThreadId` behind critical sections, SRW locks and condition
variables) did not go through the server before and are unchanged, at about
110 per frame.

## 4. Frame rate and thermals

`sync1-summary.txt` shows
119–120 FPS through 240 s. Thermal pressure 10 came at t = 125 s and 20 at
t = 170 s. The P clock was 2.8–3.0 GHz at t = 200–215 s and 1.61 GHz from
t = 230 s. In qos4, pressure 10 came at t = 110 s and 20 at t = 145 s, and the
P clock was 1.31 GHz from t = 195 s. The later throttling in sync1 is within the
spread that starting temperature causes, so it is no evidence for in-process
sync.

`nohud1-summary.txt`: no
thermal pressure change was logged in the whole run. thermalmonitord logs the
level only when it changes, so the run started with the level already raised by
sync1. Its limit level (`mTLL`) was 3 at t = 120 s and 4 at t = 135 s. The P clock
reached 1.31 GHz at t = 150 s and the E clock 1.70 GHz, and FPS was 103–116 from
then on. `perf-run.py` now prints `-` for pressure and limit level until the
run's first logged change, rather than 0.

## 5. Frame counting without the HUD

`perf-run.py --no-hud` launches without `MTL_HUD_ENABLED` and
`MTL_HUD_LOG_ENABLED`. The analysis then counts frames from DXMT's
`[iOS DXMT] Present #N t=<monotonic s>` lines, one per 16 presents. The wall
time of each line is its `t` plus an offset, taken as the 95th percentile of
(the wall time of the last timed line before it − t). `--analyze DIR --frames present`
does the same for a run that has HUD lines.
`fps-hud-vs-present.txt`
compares both counts for qos4 and sync1. The largest differences are at the
two scene loads (t = 10–15 s and t = 100 s), where a frame of 100–250 ms falls
on a bucket edge. Without the HUD there is no frame time, GPU time or memory
column, and `hitches.txt` is empty.
