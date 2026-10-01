# Kingdom Come: Deliverance's loading: where the time goes, and in-process sync

**Date:** 2026-10-01. **Phone:** iPhone18,4, iOS 27.0. **Branch:** `kcd`
(512 MiB JIT pool, [0036](../decisions/0036-one-512-mib-jit-pool.md)).
Bears on [0023](../decisions/0023-in-process-sync-stays-off.md).

## Method

`.work/kcd/timed.sh` drives one play:

1. It plays the game through the UI and skips the logos and the history
   intro with B (a held B for the intro).
2. It screenshots until the menu shows, then presses A on Continue.
3. It screenshots until Rattay shows.

Each screenshot is sorted as loading or play by the brightness of its top
rows: loading screens are letterboxed in black. Each run follows 8 minutes
of cool-down.

## Results

| run | setting | Play → menu | Continue → Rattay |
|---|---|---|---|
| t2-base | none | 95 s | 32 s |
| t2-sync | `inproc-sync=1` (runtime keys) | **177 s** | 31 s |
| t2-notso | memory ordering `tso` off | 90 s | 31 s |

**Where Play → menu goes** (t2-base):

- the first frame at +24 s;
- about 15 s of skipped videos;
- about 50 s in which the main thread loads the menu's level, 92 to 97 %
  busy;
- a short wait for the screen to settle.

**Where the main thread's time goes** (`[wprof]`, 37 bursts over a load):

- 50 % in the game's translated code (`WHGame.dll`);
- 15 % in FEX's own code (`xtajit64.dll`; `ExitFunctionEC` alone is 10.6 %);
- 13 to 18 % in wineserver round trips while the menu loads, and 30 to 40 %
  during the Rattay load.

**The game's online service does not hold the load up.** Its failed
connects and logins (PROS: the Steam token check fails under the emulator,
and it retries every 0.5 s) run on a thread of their own.

## In-process sync makes the load slower

With `inproc-sync = 1`, the menu's level took about 90 s instead of 30 s.
Over that window the main thread was 88 % busy at a steady 2,000 `SetEvent`
and 5,200 waits a second. Without it, the same window had bursts of 1,600
`SetEvent` a second and was over in 30 s.

madsync handles every wait and wake behind one process-wide mutex (0023's
"one global mutex would have to become per-object waits"). This load
signals its worker threads thousands of times a second, and that serialises
on the mutex. The Rattay load was unchanged.

The out-of-process wineserver is the better choice for this game's loads.
0023 stands. Its in-game effect was not measured here.

## Skipping the intro by the command line: no

`WHGame.dll` has `g_skipIntro` ("Skip all the intro videos"):

- **`+g_skipIntro 1` as two arguments:** the game ran `+g_skipIntro` as a
  command that prints the variable (`g_skipIntro = 0 []` in `kcd.log`) and
  ignored the `1`.
- **As one quoted argument, `"+g_skipIntro 1"`:** the same result. The
  variable is most likely restricted to `-devmode`, which was not tried.

Pressing B skips the same videos in about 15 s.
