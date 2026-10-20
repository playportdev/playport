# RDR2 with the owner's chosen defaults (owner-run test)

**IPA:** dev `3e260842aec44a3300b1e41757423c6bdd4fa5eef619a6a2584633e98326368c`
(`.work/out/20261020-155847-3e260842/`). **Decision:** [0142](../decisions/0142-rdr2-owner-test-defaults-heap-size-semaphores-and-afp.md).
**Linear:** PLA-413, PLA-364.

## What the build changes

RDR2's (`app-1174180`) compatibility default gets three runtime keys besides `jumbo-mb=8960`. Each
is the owner's choice for a test the owner plays; a dev build's Runtime keys row overrides each:

| Key | Effect | Override |
| --- | --- | --- |
| `env.PLAYPORT_VK_HEAP_MB=3072` | KosmicKrisp reports heap 0 as 3,072 MiB, not 8,192 (mesa 0064); the plan's budget cap of 3,072 MiB is unchanged | `env.PLAYPORT_VK_HEAP_MB=0` |
| `env.MADEIRA_FASTSYNC_SEM=1` | semaphores get fastsync cells (`[fastsync] mode=auto ... sem=on`) | `env.MADEIRA_FASTSYNC_SEM=0` |
| `env.FEX_HOSTFEATURES=disableafp` | FEX runs without FEAT_AFP: no FPCR write at each x64-to-ARM64EC call and return (patches/fex 0005); the app adds the CPU's own switches (`enablelrcpc2`) after it | `env.FEX_HOSTFEATURES=enableafp` |

The first IPA (`3e260842`) also had `inproc-sync=1` (Madeira's in-process sync, madsync), which the
owner chose too; it was dropped after the owner's first play (below). The current IPA is listed under
the scripted runs.

## Host checks

- `build/stages/mesa.sh $PLAYPORT_BUILD/run/mesa host hosttest`: passed. New check
  `check_heap_cap`: `PLAYPORT_VK_HEAP_MB=1536` gives heap 1,536 MiB, budget at most 1,536; 100 and
  5,120 (the mock's working set) are ignored; with `PLAYPORT_VK_BUDGET_MB=1024` and heap 3,072 the
  heap is 3,072 and the budget 1,024; two 192 MiB allocations succeed under a 256 MiB heap.
- `./pp test`: all passed.

## Phone

- Hollow Knight first frame+10 on `3e260842`: passed (run `.work/ui-runs/20261020T155956`, first
  frame at +9.03 s).

## The owner's plays on `3e260842` (16:04–16:31)

The owner played; the workstation only read the logs. The owner's launches ran without the dev
session settings of runs s5/s6 (`donorPoolMB=auto`, `endGameSocialClubAfterSignIn`,
`refuseGameSocialClubRestart`): `pp ui` sets those for its session and undoes them at the app's next
launch outside it, so every owner arm logged `memory plan: ... pool_mb=0` and no 0133/0138 line.

| Arm | Start | Sync | Result |
| --- | --- | --- | --- |
| 1 | 16:04 | `inproc-sync=1`: `[madsync] ... ENABLED`, no `[fastsync]` line | the launcher's log: `[svc] Unable to open SC manager! (1722)` from 16:04:29, three failed service starts, then error category 1 code 135, "Failed to connect to the Rockstar Games Library Service" (16:04:40); RDR2.exe never started |
| 2 | 16:07 | `inproc-sync=0`: `[fastsync] mode=auto ... sem=on` | a Mesa shader re-translation run (2,006 translated); first frame +86.1 s; the footprint reached 7,797 MB at +114.8 s before the game's sign-in, so 0140 ended the launcher; the game later logged its sign-in (+131.1 s) but the owner saw it not signed in |
| 3 | 16:11 | as arm 2 | the owner's Online attempt (out of scope): first frame +98.3 s, 0140's end at 7,799 MB at +115.2 s, then jetsam `per-process-limit` at 16:15:39 with the footprint at 8,190 MB; no crash report |
| 4 | 16:18 | — | the app was opened; no game launched |

- **The heap:** `[kk-memory] heap 0: size 3072 MiB reported in place of 8192 MiB (PLAYPORT_VK_HEAP_MB)`
  for every Vulkan instance of the launcher and the game. RDR2's own device memory before the sign-in
  is the same as in s6 (`[kk-mem] memory=93/1060`).
- **FEX:** every process logged `FEX: iOS host AFP=0`.
- **The footprint before the sign-in** was about 2 GB over s6's (7.8 against 5.5 GB). At the same
  point (KosmicKrisp's Metal memory at about 1,378 MiB, 3,305 shaders), internal + compressed +
  graphics is about the same in s6, f2 and arm 3 (7,632 / 8,067 / 8,094 MB), but the footprint is
  5,493 / 6,986 / 7,791 MB: s6 and f2 had the 4,096 MB donor pool, the owner's arms none.
- **The launcher end** at +115.2 s in arm 3 ended Launcher.exe (pid 112), its error handler and three
  SocialClubHelper.exe processes, pid 1400 among them: the renderer child of pid 436, which
  Launcher.exe started. It kept RDR2.exe (pid 1044) and its crashpad. The game's own helper was
  created by RDR2.exe after the end.
- No `[kk-compile] FAIL` and no `[fastsync] desync` in any arm.

## The second IPA (`inproc-sync` dropped)

Dev IPA `5e5a1555e1c04c1a04a3cc2d40d9111b3593339ba09cd86dce98e0b415ef95d9`
(`.work/out/20261020-163518-5e5a1555/`): Hollow Knight first frame+10 passed (run
`.work/ui-runs/20261020T163618`); `./pp test` passed.

## Scripted Story runs (workstation, unattended), 16:37–19:03

All with the s5/s6 session settings (`donorPoolMB=auto`: `memory plan ... pool_mb=4096`;
`endGameSocialClubAfterSignIn` and `refuseGameSocialClubRestart` on; no `PLAYPORT_SC_SINGLE`), aspect
16:9, the compatibility defaults unless noted; every run signed in (the launcher ended at the game's
sign-in, +101.9 to +128.0 s). Run directories `.work/ui-runs/20261020T*-rdr2-<run>`.

| Run | IPA | Change | Result |
| --- | --- | --- | --- |
| o1 | 5e5a1555 | defaults | jetsam `per-process-limit` 16:42:36, ~2 min into the Story load; last sample 7,014 MB, graphics 2,184 |
| o2 | 5e5a1555 | defaults | jetsam `highwater` 16:49:22 (8,392,082 KB), ~2 min into the load |
| o3 | 5e5a1555 | `env.PLAYPORT_VK_HEAP_MB=0` (heap 8,192) | jetsam `per-process-limit` 16:58:29 at 8,041 MB, 3.2 min after the press: the heap size is not the cause |
| o4 | 5e5a1555 | `env.MADEIRA_FASTSYNC_SEM=0` | reached gameplay (two stick cycles), 12–13 frames/s at `thermal: serious`, peak 7,948 MB; killed 17:07:39 as `highwater 0` amid system-wide low memory |
| b1 | c903bf08 | `MESA_KK_DUMP_MSL_MIN_KB=60` | jetsam in the load 17:36:02; 803 `[kk-dump]` writes (the MSL scan below) |
| w1 | e5db6774 | `env.MADEIRA_FASTSYNC_SEM=0` | jetsam in the load 18:09:06 (8,388,611 KB), at sign-in +121 s, just before 0133's end of the game's Social Club |
| w2 | e5db6774 | defaults | ended by decision 0022's JIT-pool rule: the pool head ran out at about +105 s, the app restarted it 240 s later |
| w2b | e5db6774 | defaults | the landing page started Story by itself after about 2.5 min idle; jetsam `per-process-limit` at +368 s, 8,389,251 KB |
| r2 | e5db6774 | defaults, Resolution Scale 1/2 set in the game's Graphics menu first | no kill (peak 7,562 MB), but the Story load never finished: a spinner on black at 60 frames/s, `[kk-gpu]` busy 4 %, for 9 min until the run was ended (free space on the phone fell to 3.3 GB) |

- **Against s6** (IPA 62cea69c, 14 min of Story) at the Story press +60 s, o1 is 1,062 MB higher
  (6,249 against 5,187 MB): internal +695, compressed +480, graphics +362 MB; the donor pool's live
  memory is about the same (2,634 against 2,428 MB). Named: the runtime's FEX memory resident and
  compressed +328 MB (367 against 39; already in f2 on 0fec3324 at +9 s, so before today's defaults),
  RDR2.exe private +200 MB, the game's own device memory +218 MiB (`[kk-mem] memory=` 1,246 against
  1,028) with KosmicKrisp's Metal memory +225 MiB, host malloc +76 MB.
- `[fastsync] desync` 0 and `[kk-compile] FAIL` 0 in every run.

## The white beard

The owner saw Arthur's beard white. In the porch shots (f3 on 0fec3324, o4 on 5e5a1555) it is dark.
It shows white, with red patches on the face, in the seated cabin-interior shot of the voided arm A
(c903bf08); the desktop reference of the same shot (`.work/gpu-reference/rdr2/`) has it brown. The
phone's s1/s2 frames of that interior (before mesa 0060) were already washed out by haze.

- **MSL scan** (b1's dump, 3,567 files): 359 rolled loops in 224 fragment shaders; no `sample()` or
  `sample_compare()` without `level()` inside any of them, and no `dfdx`/`dfdy`/`fwidth` inside a
  loop. A derivative or implicit-LOD sample in a loop that 0060 left rolled is ruled out.
- **Suspect now:** the interior's lighting or exposure (the haze predates 0060). Not fixed.
