# 0157: ppsync, one in-process NT sync engine, replaces madsync and fastsync

**Status:** proposed, 2026-10-21. The owner asked for it, on by default, built
and host-tested in a side copy. It is accepted only after the phone gates below.
When accepted, it supersedes the sync parts of
[0023](0023-in-process-sync-stays-off.md) (madsync stays off) and
[0054](0054-madeira-frozen.md) (fastsync on by default). It amends
[0142](0142-rdr2-owner-test-defaults-heap-size-semaphores-and-afp.md) and
[0153](0153-rdr2s-settings-are-every-games-defaults.md): every game's
`env.MADEIRA_FASTSYNC_SEM=1` (`LaunchSettings.everyGame`) goes, because it has
no effect any more. The plan
is [2026-10-21-ppsync](../plans/2026-10-21-ppsync.md).

## Decision

- **One engine.** Wine's upstream in-process synchronisation (`inproc_sync`)
  runs on ppsync ([build/ppsync](../../build/ppsync/README.md)). ppsync is
  Playport's userspace implementation of the ntsync driver's interface, grown
  from madsync, and it covers every waitable object and every kind of wait.
  - Madeira's madsync goes: `patches/madeira-unix` 0220 builds ppsync in its
    place and drops 0014.
  - Fastsync goes: `patches/wine-unix` 0015–0017 and `patches/madeira-unix`
    0081 leave their series.
- **What it fixes and keeps.**
  - The server can now reach a waiting thread. It kicks a thread that has a
    system APC queued or is being ended (`wine-unix` 0045), and it freezes a
    suspended one.
  - Objects have their own locks. A global lock is taken only for wait-all.
  - A single-object poll is answered without a lock.
  - madsync's pseudo-descriptor table and server-to-client hand-off are kept.
- **On by default.** `inproc-sync = 0` (a title's runtime keys) and
  Settings › Developer › In-process sync (`PLAYPORT_PPSYNC=0`) turn it off,
  back to server waits, and replace fastsync's `MADEIRA_FASTSYNC` switch.
- **Gates before acceptance**, all on the phone, from the main checkout:
  - a Hollow Knight play through first frame+10;
  - the named-pipe check that failed under madsync;
  - RDR2's launcher reaching its service;
  - `pp perf` of a title with heavy sync traffic (The Witcher 3 or RDR2)
    against the fastsync IPA.

  If a gate fails, this branch does not merge.

## Why

madsync had removed the server round trips: The Witcher 3 fell from about 425
requests a frame to 9, and its CPU power by about 40 mW
([evidence](../evidence/2026-09-28-server-sync.md)). But system APCs never ran
in its waits, so it could not be the default. Fastsync was safe because it
returns to the server after at most 2 ms. It covered only events (and,
optionally, semaphores) in single-object, non-alertable waits, and it carries
its own protocol across five server files.

ppsync keeps madsync's coverage and fixes the defect. Because it is upstream
Wine's code path, a Wine move touches one stand-in driver, not a parallel
engine.

## Costs

- **New code** that every thread's waits depend on. It is tested on the host,
  under ThreadSanitizer (`pp test`), and not yet on the phone.
- **Windows for a suspended thread.**
  - A thread suspended just after its wait was satisfied, but before it
    returns, runs on until it blocks at the end of the wait. That is the same
    window the deferred physical hold already has for host code (`mach_ios.c`).
  - A thread held at the end of a satisfied wait that is then kicked returns
    its result. The physical hold stops it in guest code, and it takes the
    system APC at its next wait. A kick at the start of a wait is taken at
    once.
- **Relies on the abort design.** A thread that dies with an object lock held
  would leave that object locked. The iOS runtime ends threads only at guest
  safe points, and ppsync masks no signals.
