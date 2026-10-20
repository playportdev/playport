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
