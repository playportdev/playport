# ppsync

Playport's in-process NT synchronisation: events, mutexes and semaphores, with
the waits on them, run by a library that the wineserver thread and every guest
thread call directly. Wine's own in-process synchronisation code
(`server/inproc_sync.c`, `dlls/ntdll/unix/sync.c`) is written against the Linux
ntsync driver. On iOS, `linux/ntsync.h` here stands in for that driver's header,
and `ppsync.c` is the driver. It replaces Madeira's madsync (`build/madsync`,
which Playport had turned off) and Madeira's fastsync (event and semaphore cells,
`patches/wine-unix` 0015–0017 until ppsync).

| File | What |
| --- | --- |
| `linux/ntsync.h` | the driver's structures; private request codes; `ioctl`/`close` redirected to ppsync |
| `ppsync.h` | the library's own calls: the switch, the server-to-client hand-off, `ppsync_kick`, `ppsync_freeze`, `ppsync_thread_gone`, counters |
| `ppsync.c` | the engine (iOS and Linux) |
| `ppsync_test.c` | host tests: `pp test` runs them plainly and under ThreadSanitizer |

The unix stage copies this directory into the Madeira tree as `build/ppsync`
(`build/stages/unix.sh`); `patches/madeira-unix` builds it into
`libntdll_unix.a` and `libwineserver.a` in place of madsync.

## Rules

- **Semantics.** These are the ntsync driver's
  (`Documentation/userspace-api/ntsync.rst`):
  - recursive, owner-tracked mutexes, abandonment reported once as `EOWNERDEAD`;
  - manual- and auto-reset events, and pulse;
  - wait-any and wait-all over at most 64 objects, plus an optional alert
    object reported as `index == count`. A wait-all on one object twice is
    `EINVAL`;
  - absolute timeouts on `CLOCK_MONOTONIC`, or on `CLOCK_REALTIME` with the
    `NTSYNC_WAIT_REALTIME` flag.
- **Locks.** Every object has its own lock. A change takes only that lock,
  unless a wait-all waiter is linked on the object (`all_hint`). In that case,
  and for every wait-all, the global `g_all_lock` is taken first. Only a holder
  of `g_all_lock` holds more than one object lock. The engine masks no signals:
  the iOS runtime ends a thread only at a safe point in guest code, never in
  host code (`mach_ios.c`, PLA-200).
- **Waking.** Whoever changes an object satisfies its waiters directly: it
  claims a waiter with a compare-and-swap on the waiter's `signaled` word,
  consumes the object, and wakes the thread's futex word (`os_sync_wait_on_address`
  or `__ulock_wait` on iOS, `futex` on Linux). Each thread sleeps on a word
  of its own.
- **The server's reach** (what Linux does with SIGUSR1, which iOS does not
  deliver):
  - `ppsync_kick(tid)`: a system APC was queued, or the thread is being ended.
    Its wait, now or the next one, returns `ECANCELED` having consumed nothing.
    ntdll then makes a zero-timeout server wait, which runs the APC (or ends the
    thread), and waits again.
  - `ppsync_freeze(tid, on)`: the thread's logical suspend count left or
    reached zero. A frozen thread's wait is not satisfied, and a frozen thread
    does not start or leave a wait. A server wait behaves the same way:
    `check_wait` refuses a suspended thread. The exception is a kick, because
    system APCs run while a thread is suspended.
  - `ppsync_thread_gone(tid)`: thaw and kick.
- **Polls.** A zero-timeout wait on one object that is not ready is answered
  without a lock. One load is the object's state at one instant, and the alert,
  read last, is only ever lowered by the waiting thread itself. A poll on
  several objects takes the locks.
- **Switch.** ppsync is on by default. `inproc-sync = 0` in madeira.cfg (a
  title's runtime keys) or `PLAYPORT_PPSYNC=0` (Settings › Developer) turns it
  off, back to server waits. `ppsync-spin-us = N` (0–200, default 0) makes a
  waiter spin on its own word for up to N µs before it sleeps.
- **Log.** `[ppsync] in-process synchronisation ENABLED|disabled` once.
  Then at most every 10 s a line with waits, sleeps, lock-free polls, wakes,
  timeouts, kicks, frozen waits, objects and lock contention.
