# 0023: In-process sync stays off; NT waits keep going to the wineserver

**Status:** accepted, 2026-09-28; superseded in part by
[0052](0052-madeira-reconciliation.md), which turns Madeira's fastsync on by
default (madsync stays off, as here); 0054, which supersedes 0052, ports
fastsync as a Playport patch, on only where neither cohort title regresses. Settles item 3 of the
[runtime-risks plan](../plans/2026-09-27-runtime-risks.md) (only in-process
sync is fast, and it is off). The measurements are in the
[evidence record](../evidence/2026-09-28-server-sync.md).

## Decision

- **Sync stays as it is.**
  - Madeira's in-process NT sync (madsync) stays opt-in
    (`inproc-sync = 1` in madeira.cfg, madeira-unix 0014).
  - Every wait and wake on an event, mutex or semaphore stays a request to the
    in-process wineserver.
  - System APCs under madsync and per-object waits on
    `os_sync_wait_on_address` are not built.
- **The switch works again for experiments.** wine-unix 0006 fixes the
  start-up crash `inproc-sync = 1` had on the wine-11.18 port. The switch
  still has madeira-unix 0014's defect: a thread blocked in madsync runs no
  system APC.
- **The per-frame count stays measured.** madeira-unix 0037 logs the
  requests per thread and kind, and `pp perf` reports them per frame
  (`srv/f`, `server.txt`, `summary.json`'s `server`).

## Why

**Neither cohort title is limited by server waits.**

- **Hollow Knight.** The main thread limits the frame rate, and it spends
  0.8 % of its time in server round trips (about 2 non-blocking `select`s a
  frame). With in-process sync on it makes none, and its work per frame does
  not change.
- **The Witcher 3.** It makes about 425 requests a frame. Its task threads
  spend 10 to 20 % of their time in round trips, and the in-process
  wineserver takes a fifth to two fifths of a core. But the GPU is 97 to 99 %
  busy, and its time per frame is the frame time. With in-process sync on,
  requests fall to 9 a frame and the CPU's power by about 40 mW (265 to
  222 mW), and the frame rate stays where the GPU holds it.

**Making madsync correct is a large change for no frame.** Two things are
missing:

- a thread blocked in madsync would have to be woken whenever the server
  queues a system APC for it, and then take the APC and wait again;
- one global mutex would have to become per-object waits.

That rewrites a synchronisation primitive every thread depends on. The
defect it must fix (a named-pipe read that returns no data) is a silent one.
For the cohort the reward is CPU power.

## Cost

- The Witcher 3 pays about 40 mW of CPU and a busy wineserver thread. When
  the CPU budget is low, the round trips slow down (70 to 150 µs each at
  0.84 GHz, against 45 µs in Hollow Knight). So a CPU-bound title with many
  cross-thread handoffs would lose frames to them.
- **Revisit** when a title's frame-limiting thread spends more than about 5 %
  of its time in round trips (`server.txt`) while the GPU is not saturated.
  Start by measuring it with `inproc-sync = 1`, as the evidence record does.
