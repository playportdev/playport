# FEX's per-thread band cost: a 4 MiB call-return stack and 1 MiB rpmalloc spans

[PLA-408](https://linear.app/playportdev/issue/PLA-408),
[decision 0121](../decisions/0121-a-4-mib-call-return-stack-and-1-mib-spans.md).

## Before

The baseline is run `20261019T105650` (IPA `4232943d…`, host log `pull/s1-host.log`). It is RDR2's
Steam play with the signed-in Rockstar Games Launcher
([record](2026-10-19-rockstar-physicaldrive.md)). The band filled at 197 threads: 718 spans
(11.2 GiB), 197 call-return stacks of 16 MiB and two guard pages, 197 L1 caches, and 1,238 MB of
other views. That is about 83 MB a thread.

The thread census at the peak counts the `[srv-own] new_thread`, `[band] ThreadInit` and
`[thr-name]` lines. Its rpmalloc bytes per thread, by process:

| process | threads | rpmalloc per thread |
| --- | --- | --- |
| `Launcher.exe` | 54 | 41 MB |
| CEF browser (`SocialClubHelper.exe`) | 49 | 54 MB |
| CEF renderers | 16–20 | 49–83 MB |
| services | 13 | 32 MB |

Every ThreadInit mapped a small and a medium span (`spans mapped small=1 medium=1`). By the
`[band]` lines' running counts, a process with 48 live threads had mapped 53 small, 100 medium
and 11 large spans. One with 17 live threads had mapped 21 small, 44 medium and 29 large spans,
and each large span was 16 MiB.

## The change

- **Call-return stack.** `patches/fex` 0055 brings back 0113's 4 MiB stack (removed 2026-10-17),
  ported onto the current tree with `git am -3` and no conflict. It also makes the
  `[bogus-state]` window line use the named constants.
- **Spans.** `patches/rpmalloc` 0006 sets 1 MiB spans with the medium and large pages the span,
  and cuts the large classes above 896 KiB. Decision 0121 gives the reasoning, with line
  citations in `rpmalloc.c`.
- **Census.** `patches/madeira-unix` 0164 knows the 1 MiB span and the 4 MiB stack.

A model of rpmalloc's class table and `get_size_class` (Python, from the patched source)
confirmed the following:
- the iOS table has 104 classes (73 small, 24 medium, 7 large);
- every class fits at least one block in its page;
- every size up to 2 MiB maps to the smallest class that holds it, or to the huge path above
  917,504 bytes.

The built FEX modules no longer carry the old `rpmalloc-span16` marker, so they were rebuilt
with the new constants.

## On the phone

This was one lock session with IPA `8553f02376fd29b5c194744526457a6fe3cd5d8392bf6bff6b5b7fe072ab1fc1`,
built from `c976d6a`. The battery was at 80 % on external power, with 5.5 GB free.

### Hollow Knight

Run `20261019T120213` reached first frame at +12.05 s, ok. Its game started at +5.10 s, so the
game took 6.95 s from start to first frame. The same span in today's earlier runs with 16 MiB
stacks and spans was 6.86 s (`20261019T112814`) and 5.59 s (`20261019T105528`). Most of the
later absolute time is the surface, ready at +1.75 s against +0.5 s; that wait comes before the
runtime starts.

The band held 1,254 MB with 55 threads, about 23 MB a thread: 347 spans and 577 MB of other
views. In `20261019T112814` the same 55 threads held 3,781 MB, about 69 MB a thread.

### RDR2 with the Rockstar launcher

Run `20261019T120333` used the session's default RDR2 settings: Vulkan, 896 MiB pool, Windows
services. It ended as `pool=exhausted:head still-running after_s=623`. The band was not the
limit:

| | before (`20261019T105650`, 16 MiB) | after (`20261019T120333`) |
| --- | --- | --- |
| threads at the band's peak | 197 (band full) | 213 (most seen: 216) |
| band used at the peak | 16,384 MB, full | 5,670 MB of 16,384 |
| per thread | about 83 MB | about 27 MB |
| rpmalloc spans | 718 × 16 MiB (11.2 GiB) | about 2,335 × 1 MiB (2.3 GiB) |
| call-return stacks | 197 × 16 MiB | 213 × 4 MiB |
| other views | 1,238 MB | 2,005 MB |
| refused | 24 | 0 |

A thread at the peak held about 11 MB of spans, 4 MB of call-return stack, 2 MB of L1 and
9.4 MB of other views. The other views are FEX's pooled buffers, rpmalloc's heap metadata and
its huge blocks, and they are now nearly as large as the spans.

**Owner input.** At the phone, the owner clicked *Enable Cloud Saves* on the launcher's Cloud
Saves popup, which the 90 s and 240 s screenshots show. No other input was given, and the
driver gave none. The order of events, in host time (host +0.57 s is 12:03:50.03) and in
`launcher.log`, read from the phone and kept under `.work`:
1. +70 s (12:04:59.9): the launcher asks for RDR2's cloud-save state and shows the popup.
2. About +375 s (12:10:05.7): after the owner's click, the launcher logs `cloud saves enabled state
   for app 'rdr2' = enabled`. It syncs the saves until 12:10:12.1.
3. +383.6 s (12:10:13.09): `Launcher.exe` (pid 0x70) logs `[gamelaunch] Launching game...` and
   creates `RDR2.exe -skipPatcherCheck … -useSteam -steamAppId=1174180` (pid 0x418). **This is
   the first run in which RDR2.exe started.**
4. RDR2.exe died in the loader within 0.3 s. All 33 of the run's JIT pool refusals (`[jit-pool]
   EXHAUSTED … FAILING the load`) are in that process, on its first thread 0x41c:
   - `kernelbase.dll` (want 0x330000) and `ucrtbase.dll` (want 0x154000) got no executable copy,
     because the pool's head had no room: bump 0x22f40000 of 0x38000000, the tail reservation
     0x1502c000, `room_mb=0`;
   - `xtajit64.dll` could not import `api-ms-win-crt-*`, so the process ended with `0xc0000135`.
5. +383.9 s: the launcher logged `Game exited with code 0xc0000135 … (reason:
   STATUS_DLL_NOT_FOUND)`. It showed its *Error* window (940×318), which `ReportGameExit` names
   "Red Dead Redemption 2 exited unexpectedly. Please click Retry below to enter the game
   again, or click Safe Mode to launch the game with reduced graphics settings."
6. +384.8 s: the app logged `pool: ran out of JIT memory (head)`, with `head_exhausted=33` and
   `head_mb=560`, of which `head_live_mb=533`. 240 s later it logged `the game is still running 240 s
   after it ran out of JIT memory`, and the restart ended the processes. The final screen is the
   app's alert, "Red Dead Redemption 2 ran out of JIT memory".

The band then held 211 threads at 5,083 MB. The JIT pool is the next limit (PLA-399), and this
change does not touch it.

No new crash appeared: `crashes/` is empty. The `[alloc-fail]` count (172) is the same as the
baseline's, and those lines are guest address hints.
