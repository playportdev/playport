# A launcher's child processes against the JIT pool (runtime risks, item 2)

**Date:** 2026-09-28. **Phone:** iPhone18,4, iOS 27.0, unplugged (battery 65 %
to 57 %). Branch `fm/pp-launcher-stress` on main `2a1b525`. The test program is
the dev build's *PoolStress* title
([decision 0026](../decisions/0026-a-dev-test-title-for-the-jit-pool.md)),
played through the UI with its mode and N as the game's launch arguments:
`pp ui --settings 'dir-poolstress:{"arguments":"MODE N [PACE_MS] [REGIONS]"}' --play dir-poolstress --until done`.

| IPA | sha256 | What it has |
| --- | --- | --- |
| `Playport-26.5-c2cb58c9.ipa` | `c2cb58c9582badd60e9399518943ffac2e3d566496b62314b144d96c60b8d7b7` | the test title, without madeira-unix 0039 |
| `Playport-26.5-962c0402.ipa` | `962c0402cc1e6ef87c557d31216ab7edcc5d30896896dbe690b3c8995cf8fb73` | the test title and madeira-unix 0039 (commit `60b9a9a`) |

Every run's `pool-stress:`, `title: pool:` and result lines are in
[timelines.txt](2026-09-28-launcher-stress/timelines.txt). The fields are
those of [the jit-pool record](2026-09-28-jit-pool.md). *head* is the head's
bump cursor, *tail* is what FEX's code buffers reserved, and *room* is what is
left between them. A `title: pool:` line follows each child: the program waits
2.5 s after each child is ready, longer than the app's 2 s sampling.

## No child process started before this branch

The first play (`alive 8`, c2cb58c9) started one child, which exited with code 1
before it ran any of its own code. The log
([excerpt](2026-09-28-launcher-stress/child-crash-before-0039.txt)) shows why:

- `wine_ios_child_main` gave the child's thread its TEB (`0x140f17000`) and a
  cloned PEB (`0x140884000`).
- `init_startup_info` then called `virtual_alloc_first_teb()`, which the port
  onto wine-11.18 kept from upstream (madeira-unix 0022). That switched the
  thread to a new TEB (`0x14126a000`) and a new PEB (`0x14126d000`,
  `[init-peb] thread_peb=0x14126d000`).
- `init_thread_stack` set up the old TEB. `signal_start_thread` started the new
  one, whose `StackBase` is 0, so `init_syscall_frame` stored the first
  context at `0 - sizeof(CONTEXT)` (`SEGV … addr=0xfffffffffffffc60`) and the
  child died.

So since that port, a Windows program that starts a process got no process,
only a handle that is signalled at once. No cohort title noticed: Hollow
Knight's one child, its crash handler, is refused before this point.
This branch fixed it by allocating the first TEB only when the thread has
none, which is the first process. The same fix reached main first, from
separate work, as
[madeira-unix 0039](../../patches/madeira-unix/0039-ntdll-allocate-the-first-TEB-only-for-a-thread-that-.patch)
([child-process](2026-09-28-child-process.md), with three more child
fixes in 0040 to 0043), so the branch keeps main's patch and drops its own.
The runs below used this branch's copy of the fix. With it, every child
started, ran its code and exited 0. The final IPA, rebased on main, is in
the last section.

## What a child costs

`alive 64`, 896 MiB pool (962c0402). Each child starts, runs its code and
stays until the next starts:

| Alive children | Head | Tail | Room | Images | Alias entries |
| --- | --- | --- | --- | --- | --- |
| 0 (the parent) | 20 MiB | 17 MiB | 860 MiB | 6 | 2 |
| 1 | 40 | 33 | 824 | 12 | 4 |
| 8 | 178 | 145 | 574 | 54 | 18 |
| 16 | 335 | 273 | 289 | 102 | 34 |
| 24 | **492** | **401** | **3** | 150 | 50 |

- **Each child takes 19.6 MiB of head and 16 MiB of tail**, 35.6 MiB in all,
  the same for every child. The spawn took 71 to 127 ms.
- **The head part is six image copies**, not only ntdll. The child's
  ntdll copy is 4.04 MiB (`children_mb` 97 for 24). The child also loads its own
  copies of `kernelbase.dll` (5.7 MiB), `libarm64ecfex.dll` (FEX, 4.0 MiB),
  `ucrtbase.dll` (3.7 MiB), `kernel32.dll` (2.0 MiB) and its executable, all
  already loaded by the parent (`[jit-pool] image …` lines). A pseudo-process
  shares no image with its parent. The `[jit-pool] image` lines show the
  whole image being copied, x18 trampolines included.
- **The tail part is FEX's first code buffer** (16 MiB). This program's
  children run little code. A child that runs more takes more: in the
  `REGIONS` run below each process's tail reached 144 MiB, FEX's 16 MiB
  buffer and one of 128 MiB, as Hollow Knight's does.
- **The pool ran out at child 25.** Its ntdll copy found no room
  (`[child-ntdll] JIT pool exhausted (need 0x408000, …)`). `CreateProcess`
  failed with `ERROR_NOT_ENOUGH_MEMORY`, the parent told its 24 children to
  exit and exited, and the launch ended as *ran out of JIT memory*
  (`pool=exhausted:head exit=0x00010018 after_s=67`; 0x18 = 24 children).
- **With a 512 MiB pool** (`set:jitPoolSimulatedMB=512`, the floor for a
  memory limit below 4 GB), 13 children were alive at once. The 14th got its
  ntdll copy, but not `ucrtbase.dll` (`EXHAUSTED (image …+0x3b0000)`, 33
  refusals), and exited with `c0000135`. The launch ended as *ran out of JIT
  memory* (`pool=exhausted:head exit=0x0003000d after_s=39`).

## A dead child's head is not given back

`serial 40`, 896 MiB pool. Each child exits before the next starts, so at most
one is ever alive:

| Children started | Head | Head live | Tail | Tail live | Room |
| --- | --- | --- | --- | --- | --- |
| 0 | 20 MiB | 20 | 17 | 17 | 860 |
| 1 | 40 | 20 | 33 | 17 | 824 |
| 10 | 216 | 20 | 33 | 17 | 648 |
| 20 | 412 | 20 | 33 | 17 | 452 |
| 40 | **804** | 20 | 33 | 17 | **60** |

- **The tail is reused.** FEX's code buffer of a dead child goes to the next
  child, and the tail stays at 33 MiB.
- **The head is not.** Every child's images are freed (*head live* falls back
  to 20 MiB), but the head cursor still rises by 19.6 MiB per child started.
  The runtime checks each freed image range when it frees it, and 248 of them
  had already lost their execute permission (`[pool-freechk] POISONED AT FREE
  … <== narrowed during the module's life`). A range like that is dropped when
  it is offered for reuse (Madeira's ml242/ml243 guard). Only the small guest
  JIT blocks (16 and 64 KiB) were reused (`reused freed range`). So each
  process a title starts costs 19.6 MiB of head for the rest of the session,
  whether it is alive or not: at 896 MiB, about 43 children started one after
  another fill the pool.

## A heavy child that runs the head out can end the app

`alive 12 2500 400`: each process makes 400 guest JIT regions (400 alias
entries and 25 MiB of head) and calls 409,600 generated functions. FEX gave
each process 144 MiB of tail. With the parent and five children, the head and
tail met (`room_mb=1`, tail 645 MiB, 2,137 alias entries), and a child's next
`PAGE_EXECUTE_READWRITE` request was refused (`EXHAUSTED (anon RWX)`, 2,017
times). The child did not see the refusal as a failed allocation: it wrote to
the page anyway and faulted, and after 2,000 redeliveries of the same fault the
runtime ended the process (`[redeliv] terminating process`). In the one-process
runtime that process is the app, so the app closed, less than 2 s after the
last `pool:` sample. The launch did not end as *ran out of JIT memory*, and
`pp ui` reported `the app exited before the stop condition`. The
anonymous-alias table did not fill up: the head ran out first.

## Rewritten guest code runs stale (a new finding, not pursued)

In the title these runs used (c2cb58c9, 962c0402), every process wrote 512
small functions into a `PAGE_EXECUTE_READWRITE` region, called them, rewrote
each one's constant in place, called `FlushInstructionCache` and called them
again. That rewrite pass has since been removed from `pool-stress.c`, so a run
of the current title shows no `stale=` field. On the phone, the first calls
always gave the right answers (`bad=0`), but after the rewrite **352 of 512**
gave the old answer (`stale=352`) in every process of every run (102,455 of
204,800 with 400 regions). Under the workstation's Wine, all were right. A
translation of the old code is still used after the guest has changed the code
and flushed. A guest JIT that patches code in place (Mono, V8) could run stale
code the same way. This record does not investigate it further. It was
reported, not failed, so the exit code stayed about processes.

## What this means for decision 0019

[Decision 0019](../decisions/0019-jit-pool-sized-from-the-limit.md) kept a
private ntdll copy per pseudo-process, without a launcher to measure. The
numbers support it:

- **The ntdll copy is a small part of what a child costs.** It is 4.04 MiB of
  the 19.6 MiB of head a child takes (21 %), and 11 % of the 35.6 MiB an alive
  child takes. One shared copy would raise the number of alive children at
  896 MiB from 24 to about 27, and would not change the sequential limit much
  (19.6 to 15.6 MiB per child started). As 0019 says, a shared copy would
  also have to reach each child's own `.data`.
- **The larger costs are elsewhere:**
  - every child loads its own copy of the parent's system DLLs (15.5 MiB);
  - a dead child's images are never reused, because their ranges lost
    execute permission during the child's life;
  - the head runs out inside a guest JIT write, which can end the app instead
    of ending as *ran out of JIT memory*.

  These are the follow-ups for a title that starts children.
- **What a title can afford.** Hollow Knight at its first frame leaves 588 MiB
  of room. A title of its size could keep about 16 light children alive at
  once, or start about 29 in turn over a session. With a 512 MiB pool,
  about 13 light children fit beside a parent as small as this program, and
  about 5 beside Hollow Knight (204 MiB of room,
  [jit-pool](2026-09-28-jit-pool.md#sizing-from-the-limit)).

## Hollow Knight with madeira-unix 0039

`pp ui --play app-367520 --until first-frame+10 --shot` (962c0402): first frame
at +9.48 s (JIT 3.09 s), head 164 MiB, tail 145 MiB, 39 alias entries, no
child (the crash handler is still refused at the spawn gate:
`[proc-gate] REFUSING spawn of … UnityCrashHandler64.exe`), title screen at
118 fps (shot (screenshot not published)).

## The test title in the UI

`pp ui --action open:installed --action open:dir-poolstress --shot-each-action`:
*PoolStress*, badged *Untested*, 13.8 KB, `C:\Games\PoolStress`,
`pool-stress.exe`, with the Play button
(shot (screenshot not published)). The dev app copied it
there from its bundle before the library scan (`library: dev title PoolStress:
copied pool-stress.exe into C:\Games`). The release build of the same commit
(`Playport-26.5-release-1a3c6b9c.ipa`) passed `pp verify --variant release`
(71 checks): it has no `DevTitles/`, no `DevTitles` type and no `DevTitles`
string. It was not installed on the phone.

## The final IPA, rebased on main

`Playport-26.5-4edc4d21.ipa`, sha256
`4edc4d214a55559d1de47c262f32f836d9e596b081a9d2848c28b7ff6c4a98b1`: this branch
rebased on main `2852776`, with main's madeira-unix 0039 to 0043 in place of
the branch's own fix and without the rewrite pass. Played on 2026-09-29:

| Run | Result |
| --- | --- |
| `pp ui --play app-367520 --until first-frame+10 --shot` | ok: first frame at +10.11 s, head 164 MiB, tail 145 MiB, no child |
| `alive 64` | 24 children alive; the 25th ran the head out: `pool=exhausted:head exit=0x00010018 after_s=67`, head 492 MiB, tail 401 MiB, as before |
| `serial 10` | `exit=0x00000000 after_s=31`: head 216 MiB with 20 live, tail 33 MiB, as before |

The numbers above therefore hold on main's child fixes too.
