# RDR2: x64 critical sections, an InitOnce stub, the launcher crash and the process heap (PLA-364, PLA-413)

**Linear:** PLA-364, PLA-413. Follows [the performance arms](2026-10-20-rdr2-perf-arms.md): same porch
view, same scripts (`.work/agent-notes/pla413e/`: `perfarm2.sh`, `perfpost2.sh`, `arm.py`), session settings
`donorPoolMB=auto`, `endGameSocialClubAfterSignIn=true`, `refuseGameSocialClubRestart=true`, aspect 16:9,
Story pressed by the landing script, no stick input, runs to first frame+540.

## IPAs

| IPA (dev) | Tree | Hollow Knight first frame+10 |
| --- | --- | --- |
| `f01287bb9978568bd8efeb6afb5fa64dd451ca6895bbcc1d94050efd6c71a9eb` | 741fea3: wine-pe 0050 (`MADEIRA_X64_CS_FASTPATH`, off by default) | passed (`.work/ui-runs/20261021T012623`) |
| `bddcf0094e7c69dd308c192b44ea22228d47cf498ef808b88f961278a5bf3566` | + process heap at HeapSegmentReserve, + InitOnceExecuteOnce x64 stub (off by default) | passed (`…T021459`) |
| `76a60e14365d646f4aacfc16f47b8feb181cc267def4e4c7eca7caebe933187f` | InitOnce stub, fex 0060 (`MADEIRA_FEX_EC_CALLRET_POP`, off), mesa 0081 (depth/stencil state cache, on), 0082 (`MESA_KK_SAFE_MATH`, off) | passed (`…T024917`); first frame+60 with `MADEIRA_FEX_EC_CALLRET_POP=1` passed (`…T025007`) |
| `822f25ec3090df7357c943208a829af31752aaea9b492f44471de23d6f0a2a81` | 76a60e14 without the InitOnce stub (ntdll identical to f01287bb's) | passed (`…T031339`) |
| `95eac7159fca0156b5711433e1cbc7748b371a86792850befb051526396e6817` | 822f25ec + wine-pe 0051 (process heap) | not run (the phone left the network) |

## Critical sections in x64 code (wine-pe 0050)

Porch view, windows from 10 s after it appears, all after `thermal: serious`:

| Run | IPA | Arm | Window | fps | GPU busy | cores | E GHz | mW | x64→EC/s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| c1 (`…T013308-rdr2-c1`) | f01287bb | `MADEIRA_X64_CS_FASTPATH=1` | 60 s | **17.2** | 44 % | 3.13 | 1.61 | 455 | 501 k |
| c1 | | | 300 s | **17.3** | 43 % | 3.05 | 1.62 | 449 | 503 k |
| a2 (`…T020204-rdr2-a2`) | f01287bb | defaults | 60 s | **16.2** | 43 % | 3.11 | 1.52 | 420 | 605 k |
| a2 | | | 300 s | **16.2** | 42 % | 3.05 | 1.52 | 418 | 604 k |
| pA (yesterday) | ee38ddeb | defaults | 60 s / 300 s | 16.2 / 15.7 | 43 % | 2.50 / 2.77 | 1.60 / 1.54 | 469 / 412 | 476 k / 570 k |

- **The stubs bind.** `[x64-cs] L"RDR2.exe": 2 of its KERNEL32.dll imports go to the x64 stubs`, and the same
  for every x64 module of the game and the launcher. In `[xp-api-top]` ntdll's `RtlEnterCriticalSection` and
  `RtlLeaveCriticalSection` fall from 66 k/s each (a2) to 1.5–1.6 k/s each (c1): RDR2 calls them through its
  imports, not through `GetProcAddress`.
- **fps:** +6 % (17.2–17.3 against 16.2), one run each, but the E clock also differed by 6 % (1.61 against
  1.52 GHz), and fps per E-GHz is the same (10.7). Not yet separable from the noise; a repeat was planned and
  not run (below). No crash, no anti-tamper exit in c1.
- The phone was on its charger (6 % to 80 %) for these runs and cooled 6.5–9 min between them.
- **The next transitions** (c1, per second): `vkAllocateDescriptorSets` 84 k, `vkUpdateDescriptorSets` 83 k,
  `vkCmdBindDescriptorSets` 50 k, `vkCmdBindVertexBuffers` 42 k, `vkCmdBindIndexBuffer` 40 k,
  `RtlQueryPerformanceCounter` 39 k, `vkCmdDrawIndexed` 34 k, `InitOnceExecuteOnce` 25 k, `vkCmdBindPipeline`
  21 k, `vkCmdSetDeviceMask` 20 k. About 4.8 k descriptor sets are allocated and written per frame.

## The AFP arm (G), measured from yesterday's log

pG's 39.6 MB host log came back once `pp phone pull` was fixed (below), as `s1-host.prev.log`.
`env.FEX_HOSTFEATURES=enableafp`, porch view from about 23:21:59:

| Window | fps | GPU busy | cores | E GHz | mW | x64→EC/s |
| --- | --- | --- | --- | --- | --- | --- |
| 60 s | 13.3 | 38 % | 2.02 | 1.56 | 428 | 299 k |
| 300 s | 13.5 | 41 % | 2.64 | 1.36 | 345 | 454 k |

13.3–13.5 against pA's 16.2/15.7, with `thermal: serious` before first frame and a lower E clock (1.36 GHz over
300 s). One run; AFP on is not a win for RDR2, which keeps `disableafp`.

## The InitOnceExecuteOnce stub broke the Rockstar launcher

The stub answered a completed `INIT_ONCE` x64-side (behind `MADEIRA_X64_ONCE_FASTPATH=1`). With its code in
ntdll, switched on or off, every RDR2 run failed before the game started:

| Run | IPA | Arm | Result |
| --- | --- | --- | --- |
| e1 (`…T021803-rdr2-e1`) | bddcf009 | CS + ONCE | launcher thread `01a4` faulted, launcher exited `0xc0000005`, PlayRDR2 "Unable to launch game" |
| d1 (`…T023044-rdr2-d1`) | bddcf009 | defaults | the same |
| p1 (`…T025215-rdr2-p1`) | 76a60e14 | CS + ONCE + call-ret pop | the same, then an exception loop that grew `s1-host.log` past 1.1 GB; run ended by hand |
| d3 (`…T025949-rdr2-d3`) | 76a60e14 | defaults | the same |
| z2 (`…T031440-rdr2-z2`) | 822f25ec | defaults | launched, box closed, Story pressed at 03:17:52 |

The first fault in each: a new launcher thread (started at the same address as in good runs) runs ntdll with no
TEB register (`[x18-decline] #1 … x18=0`) and reads `0x60` (the TEB's PEB field) in `RtlProcessFlsData`; then
`Launcher.exe` reads a null TLS array (`x86=48 8b 0c d8 …`, `AV READ of 0`). It never occurred on f01287bb or
822f25ec. The stub is dropped (kept in `.work/agent-notes/pla364c/dropped/`). That ntdll's layout alone
decides whether this race fires is itself a Madeira-side hazard, not explained here.

The process-heap change was in bddcf009 too and was first blamed and dropped; 76a60e14 (stub, no heap change)
failed the same way, so it is restored as wine-pe 0051, untested on RDR2.

## RDR2's 0xc0000005 after the PlayRDR2 box (r1, n1, a1)

a1 on f01287bb, defaults, ended at the same point as r1 and n1: RDR2's main thread read `0x70616c0000`
(`[fault-rgn] … NO wine view`), with `rdx=0x70616bffe8`, `rax=12` and `x86=0f b7 04 42` (`movzx eax, word
[rdx+rax*2]`), one character past a 12-character string ending at the process heap's base + 0x10000
(`[xp-api-cs] … process heap 0x70616b0000`). The guest stack holds the ASCII `frida`: an anti-tamper scan.
Wine makes the process heap's first region 64 KB (`RtlCreateHeap(flags, NULL, 0, 0)`), so a block can end
where the mapping ends; Windows makes it the PEB's `HeapSegmentReserve` (1 MB). wine-pe 0051 does the same;
not yet confirmed on the phone (the crash is intermittent: r1 and n1 yesterday, a1 of three launches on f01287bb today).

## `pp phone pull`

pymobiledevice3's `apps pull` lost the network connection on its first 4 MB read of an 18 MB `s1-host.log`
and left a 0-byte file that `pp phone pull` reported as `ok`. It now reads through `tools/afc.py pull` in
512 KB reads, reopens a dropped connection and resumes at its offset, and renames the file into place only
whole: the 39.6 MB `s1-host.prev.log` came back in 10 s (commit d29cf66).

## Not reached

The phone left the network at 03:21, 3 min after z2's Story press (its syslog stream ends at 03:20:29, the app
exited; `netmuxd` lists no device since). Not measured, all built and gated on Hollow Knight only:
`MADEIRA_FEX_EC_CALLRET_POP=1`, the depth/stencil state cache (mesa 0081, on by default in 76a60e14 and later)
and its `[kk-gpu]` counters (begins, `ONE_TIME_SUBMIT` begins, passes, depth/stencil compiles),
`MESA_KK_SAFE_MATH=1` for the hair, wine-pe 0051 on RDR2.
