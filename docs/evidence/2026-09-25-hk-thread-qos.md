# Hollow Knight: helper threads on the E cores

**Date:** 2026-09-25. **Tree:** the commit that adds
[madeira-unix 0015](../../patches/madeira-unix/0015-thread-set-a-named-thread-s-QoS-class-from-WINE_IOS_.patch)
and `title-device-run.py --hold-polls`. **Build:** a lane build of that tree
(`PLAYPORT_BUILD=$PLAYPORT_BUILD/lanes/perf build/build-from-pins --from stage`
after the ntdll stage with the patch), installed in place, IPA sha256
`62e149af5ef540aa739592b89a08137958d4c2e64814d35be38ae0e7f52bb80f`.
**Phone:** iPhone Air (`iPhone18,4`, A19 Pro: 2 P + 4 E cores), iOS 27.0, over
netmuxd Wi-Fi, on a 15 W charger; every run under
`flock $PLAYPORT_BUILD/device.lock`.

**Result:** every Wine thread runs at `USER_INTERACTIVE`, the QoS class the
host thread gives it, so Unity's graphics worker, its job workers and DXMT's
encoder share the two P cores with the game's main thread. Giving those
threads `utility` QoS puts them wholly on the E cores (P share 0.00) and
leaves the main thread alone on the P cores (P share 0.99). Before thermal
throttling, at the same 3.8 to 4.0 GHz P clock, the process then draws about
1.55 W of CPU power instead of 1.9 to 2.0 W, and thermal pressure 20 comes
about 40 s later. From a comparable start, gameplay from 180 to 240 s ran at
116 to 119 FPS against 110 FPS without the change. It is not enough on its own:
from a warm start the P clock still reaches 1.31 GHz near t = 195 s.
`default` QoS does not keep the threads off the P cores. The change also
makes a periodic stall of unknown source, every 20.17 s, visible: without it
those frames last 25 ms, with it 33 to 42 ms.

## 1. Runs

All runs used `perf-run.py --secs 240 --env HOST_SCREEN=720
--vpad 45:harness/device/vpad/hk-new-game.txt --vpad 100:harness/device/vpad/hk-walk.txt`,
with the QoS setting below as `--env WINE_IOS_THREAD_QOS=...`. `utility` means
`UnityGfxDeviceWorker=utility,Job.Worker=utility,Background Job.Worker=utility,dxmt-=utility,Loading.=utility`,
and `default` means the same prefixes with `default`. Gameplay starts at about
t = 95 s, where `t` counts from the first HUD line. The start column gives how
long the phone rested after thermalmonitord logged `Thermal pressure level 0`
following the previous run; "warm" means a run shortly after another one with
no such wait. `jw1` is an earlier run of the previous build with
`-job-worker-count 1` in the title's arguments and no QoS setting.

[`compare.txt`](2026-09-25-hk-thread-qos/compare.txt):

| run | QoS | start | pressure 10 at | pressure 20 at | P clock ≤ 1.4 GHz at | FPS 110–175 | FPS 180–240 | worst 5 s | CPU mW 110–140 | P % / E % 110–140 | main thread busy at 225 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| base2 | none | 3 min | 100 | 130 | 180 | 119.2 | 109.6 | 103.1 | 1906 | 110 / 35 | 93 % |
| qos3 | utility | 13 min | 125 | 170 | never | 119.7 | 119.4 | 118.3 | 1565 | 66 / 95 | 66 % |
| qos4 | utility | 1 min | 110 | 145 | 195 | 119.6 | 116.1 | 113.2 | 1532 | 66 / 98 | 84 % |
| qos1 | utility | warm | 125 | 170 | never | 119.6 | 119.0 | 116.2 | 1539 | 65 / 95 | 66 % |
| jw1 | none, 1 job worker | warm | 105 | 130 | 195 | 120.0 | 118.6 | 117.0 | 2024 | 105 / 28 | 94 % |
| qos2 | default | hot | 30 | 110 | 145 | 110.6 | 106.0 | 95.1 | 1434 | 148 / 71 | 91 % |

Per run: `<run>-summary.txt` (the 5 s table), `<run>-threads.txt`,
`<run>-hitches.txt`; `qos3-thr-qos.txt` has the `[thr-qos]` lines, one per
matched thread (28 threads, every `rc=0`).

## 2. Where the threads ran

`qos3-threads.txt` at t = 120 s: the main thread `0024` 41 % of a core,
P share 0.99, 22.2 Mi/f; `UnityGfxDeviceWorker` 41 %, P 0.00, 12.1 Mi/f;
`dxmt-encode-thr` 20 %, P 0.00, 6.2 Mi/f. `base2` and the earlier `g720long`
have the worker at P 0.82 and the encoder at P 0.92. Total instructions per
frame are unchanged (57 to 61 Mi/f), so the change moves work to other
cores and does not remove any. The worker needs about 1.6 times the CPU time
on an E core (41 % against 26 %).

With `default` (qos2) the scheduler kept the threads mostly on the E cores
(worker P 0.13), but under pressure 20 the main thread's P share fell to
0.79, and that run throttled hardest. It also started hot, a few minutes after
qos1, so one run cannot separate those causes.

## 3. The 20.17 s stall

In the utility runs, the frames of 33 ms or more after the load hitches fall
on one period: qos3 at 66.14, 86.31, 126.62, 146.78, 166.93, 187.10, 207.27 and
227.44 s; qos4 at 63.96, 84.13, 124.45, 144.60, 164.78, 184.95, 205.14 and
225.34 s; qos1 likewise. The base run shows 25 ms frames on the same period
(176.88, 197.01, 217.40 s), and so did `g720` (153.64, 174.39 s).
In the 250 ms census window that holds such a frame, the
`[xp]` `run=` figure (threads waiting for a core) is 1,280 to 1,370 against
680 to 970 around it, and no thread of the process uses more CPU than
usual. The cores were taken by something outside the game's threads.

Ruled out, by their measured period or phase:
- thermalmonitord's 20 s PowerLog posts (`:02.5`, `:22.5`, `:42.5`; the
  stalls drift +0.17 s per period);
- the runtime's `[thread-sample]` bursts and `[rip-profile]` (period 24.3 s);
- its 10 s `[phys-map]`/`[malloc-zones]` walk (4 to 6 s from every stall);
- the Winios 20 s thread-stack timer (never armed: the compositor that starts
  it is not attached in title mode);
- the harness's `title-result.log` polls (qos4 ran with `--hold-polls`, no
  poll during the run, and still stalled on the period).
