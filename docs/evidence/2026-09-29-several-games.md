# Several games in one app run: titles as children of a session root

**Date:** 2026-09-29. **Phone:** iPhone18,4, iOS 27.0, the shared reference
phone, unplugged (battery 49 % to 37 %). **Branch:** `fm/pp-multigame`.
**Decision:** [0027](../decisions/0027-titles-as-children-of-a-session-root.md).
**Follows:** [session root](2026-09-28-multigame-session-root.md) (not
shippable then), [child processes](2026-09-28-child-process.md) (madeira-unix
0039 to 0043: Hollow Knight still faulted as a child) and the
[launcher stress](2026-09-28-launcher-stress.md) (PoolStress).

**IPA** (dev): `Playport-26.5-5e2398e8.ipa`, sha256
`5e2398e8344346cac058cc43fa82e1971a57f36d867a0e763da6efecdb34aafe`.

## Hollow Knight as a child: an unwind that ran the parent's ntdll

The child faulted about 1 s in (`UNHANDLED pc=<pool> addr=0x20`, then
`0xc0000005`) right after Mono's thread-name exception (`0x406D1388`) was
caught by unwinding. PoolStress got an exception probe to reproduce it without
a game: an x86-64 function that raises `0x406D1388` from a frame whose
language handler catches it with `RtlUnwindEx`, as MSVC's `__except` does,
and checks that the frame's nonvolatile registers come back. In the parent it
passed; in every child it faulted the same way Hollow Knight did.

A scratch diagnostic (a wine-pe patch logging each unwind step and where
`RtlUnwindEx` ran, not kept) showed the cause. In the child,
`RtlUnwindEx entry runs at 0x107b8bb3c` (the session's ntdll copy) with
`peb=0x1401bd000` (the session's): the child's own ntdll copy was never
called. The unwind then looked up the child's modules in the session's loader
data, found no unwind information for the child's executable, walked garbage
(`no progress (repeated pc/frame)`) and resumed with the registers lost.

Why: every process that runs x86-64 code loads its own copy of the emulator,
whose alias table (`IosAliasEntries`) turns an x64-to-ARM64EC call's target
(kernel32's `RtlUnwindEx` forwarder to ntdll, a PE address) into the pool
copy it branches to. ntdll's unix side kept one global callback for that
table and drained it with the session's copies only, skipping a child's own
ntdll copy since it shares its PE address with the session's (a comment there
deferred "per-process alias routing"). **madeira-unix 0044** keeps the
callbacks per PEB: a process's emulator gets its own copies in place of the
session's, every other alias goes to all, and a dead process's callback is
dropped. With it (the IPA above, run 2):

```
pool-stress: p baseline regions=1/1 bad=0 (seh included)
pool-stress: c1 ready pid=52 regions=1/1 bad=0 seh_bad=0 work_ms=8
...
pool-stress: c8 ready pid=136 regions=1/1 bad=0 seh_bad=0 work_ms=7
pool-stress: p done started=8 ready=8 of 8 failed=0 total_ms=23512
```

## The session root

`playport-session.exe` (`app/SessionRoot`) is the app process's one Wine
main; the first Play starts it after the JIT pool and the wineserver. It
starts each title as its child, in a job, with the launch's variables over its
own environment, and reports when the job is empty. On the workstation (Wine
11 under Linux) its request, stop and refusal paths were driven with
PoolStress before the phone: a title with a variable, a stop of a running
title (`exit code 42b ... (stopped)`, `ERROR_PROCESS_ABORTED`), and a missing
executable refused with error 2.

## Hollow Knight twice: the GDI table was the first title's

The first build of the root started kernel32 only. PoolStress then Hollow
Knight worked, and Hollow Knight then Hollow Knight did not: the second died
0.8 s in (`exit=0xc0000005`) in gdi32, loading
`TEB->Peb->GdiSharedHandleTable` (`ldr x8,[x8,#0x60]; ldr x8,[x8,#0xf8]`) as 0.
win32u's `init_user` runs once per session and writes the table into the PEB
of the process that ran it, the first Hollow Knight; a child's PEB is cloned
from the root's (`wine_ios_child_main`), which had none. PoolStress never
touches win32u, so in the first order Hollow Knight was that process. The root
now calls `GetDesktopWindow` before any title, as explorer does, and logs what
it got (`session: desktop window 10020, GDI handle table 7039210000`).

## Runs of the final IPA

One device session (`pp phone lock`), each through the UI with its Back to
library button; lines in [timelines.txt](2026-09-29-several-games/timelines.txt)
and [session-lines.txt](2026-09-29-several-games/session-lines.txt).

| Run | What | Result |
| --- | --- | --- |
| 1 | Hollow Knight, quit from its menu (Quit Game, Yes), back to library, Hollow Knight again, quit | both `exit=0x00000000` after 49 and 50 s; first frame at +9.14 s (JIT 3.0 s), the second at **+5.64 s** with no JIT (`runtime running` at +0.51 s); 676 MiB of the 896 MiB pool free for the second |
| 2 | PoolStress (8 children), back to library, Hollow Knight | PoolStress `exit=0x00000000`, every child `seh_bad=0`; Hollow Knight's first frame at +6.40 s (title screen (screenshot not published)) |
| 3 | `set:jitPoolSimulatedMB=184`, Hollow Knight, back to library, Hollow Knight | the first ran the pool out loading (`pool=exhausted:head exit=0xc0000135`); the second Play was refused, `launch=refused pool=room room_mb=0`, on the *Playport needs to restart* screen (shot (screenshot not published)) |

Before these, the same code with the scratch diagnostic played Hollow Knight
alone to its first frame (+9.28 s) and PoolStress then Hollow Knight (+6.26 s).

## What is not shown

- A game stopped after it ran the pool out, then another Play: in run 3 the
  game ended by itself before the stop was needed. The stop itself (the root
  ending the title's job) ran only on the workstation.
- The Witcher 3 and En Garde! in a session, and a title that starts children
  of its own on the phone beyond PoolStress.
- How many Hollow Knights fit: each left about 161 MiB of head (run 1: head
  204 MiB after one, 365 after two), so a fourth is refused in an 896 MiB pool.
- The release variant: built from the same trees, it passed `pp verify
  --variant release` (71 checks) and carries the session root; it was not
  installed.
