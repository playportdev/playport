# 0153: What works for RDR2 is every game's default, in dev and release

**Status:** accepted, 2026-10-21, by the owner ("as little per-game settings as possible; everything that
works for RDR2 is enabled for everything else"; relayed by the supervisor, PLA-364, PLA-413). Amends
[0009](0009-dev-and-release-builds.md) (the donor pool and the end of a game's own Social Club are no
longer dev-only), [0105](0105-memory-defaults-per-phone.md) and [0106](0106-8gb-row-in-full-and-vulkan-plan-default.md)
(the donor pool is on, Auto, in both builds), [0115](0115-a-steam-client-for-the-launched-app.md) (Playport's
Steam client for every Steam game), [0131](0131-the-khronos-vulkan-loader-for-a-game-whose-layer-must-load.md),
[0133](0133-a-dev-build-may-end-rdr2s-own-social-club-after-its-sign-in.md),
[0138](0138-refuse-rdr2s-social-club-restarts-at-process-creation.md),
[0141](0141-end-rdr2s-own-social-club-no-sooner-than-120-s-after-its-sign-in.md),
[0142](0142-rdr2-owner-test-defaults-heap-size-semaphores-and-afp.md) and
[0152](0152-rdr2-default-x64-critical-sections-and-fex-batch2.md) (their keys move from RDR2's entry to every
game). Revisit per key when a title shows a cost. [Evidence](../evidence/2026-10-21-every-game-defaults-gate.md):
Hollow Knight and RDR2, the only titles installed on the phone, on dev IPAs 55b643b6 and d95adbbd.

## Context

- **RDR2 reaches Story only with settings that were RDR2's, or dev-only.** Every porch run since
  2026-10-19 used the session settings `donorPoolMB=auto`, `endGameSocialClubAfterSignIn=true` and
  `refuseGameSocialClubRestart=true`. All three were compiled out of release. RDR2's compatibility entry
  held the rest. The switches and their measured effects are listed in `.work/agent-notes/SWITCHES.md` and
  in [the combined arms](../evidence/2026-10-21-rdr2-combined-arms.md).
- **The release app could not play RDR2.**
  - It had no donor pool: madeira-unix 0148's hooks were stubs, and run A of
    [the loading memory](../evidence/2026-10-19-rdr2-loading-memory.md) died without the pool.
  - It never ended the game's own Social Club, which is ~550 MB. x4, with the helper alive, was killed at
    8,120 MB.
  - `site/compatibility/games.json` lists RDR2 as broken.
- **The owner's direction.** Few per-game settings: what works for RDR2 is on for every game, each
  overridable per game.

## Decision

- **Every game's defaults (`LaunchSettings.everyGame`, PlayportKit).** They sit under each title's
  compatibility entry (`LaunchSettings.overEveryGame`). A person's game-page choice wins over both, the
  runtime keys per key (decision 0091). The runtime keys are the lowest level of a launch's madeira.cfg
  keys (`Effective.config`), under a cohort title's own: The Witcher 3 keeps `jumbo-mb=32768`. They are:
  - `windowsServices` on, `jitPoolMB` 896, `khronosVulkanLoader` on, `steamAPI` client;
  - `endLauncherAfterSignIn` on. It acts only for a game a PublisherLauncher starts, so RDR2 alone today;
  - the runtime keys `jumbo-mb=8960 env.PLAYPORT_VK_HEAP_MB=3072 env.MADEIRA_FASTSYNC_SEM=1
    env.MADEIRA_X64_CS_FASTPATH=1 env.MADEIRA_FEX_BATCH2=1 env.PLAYPORT_SC_BLOCK_CRASHPAD=1`.
- **Vulkan is the default backend** (`GraphicsBackend.default`). Settings › Graphics › Direct3D and a game
  page's choice still pick DXMT.
- **RDR2's entry keeps two items.**
  - `graphics: vulkan`: the game draws through Vulkan or Direct3D 12, which only the Vulkan layer runs,
    so a person's Settings choice of DXMT must not reach it.
  - `env.FEX_HOSTFEATURES=disableafp` (0142), **the one key not made global**. It turns Hollow Knight's
    picture black:
    - With every default on (dev IPA d4ff7de2), Hollow Knight reached its first frame and drew 60 frames/s
      at the same GPU time a frame, but the screen stayed black at first frame+10 and +25.
    - Bisected on its game page (first frame+25):
      - b1, every non-runtime default off: still black;
      - b2, `env.FEX_HOSTFEATURES=enableafp env.MADEIRA_FASTSYNC_SEM=0 env.PLAYPORT_VK_HEAP_MB=0`: the
        menu;
      - b3, `env.FEX_HOSTFEATURES=enableafp` alone: the menu;
      - b4, `env.FEX_HOSTFEATURES=disableafp` alone, first frame+40: black (black in 4 of 4 runs with it).
    - The cause (likely the guest's denormal flushing without AFP) is a follow-up. If it is fixed, the
      key becomes global and the exception goes.

  Everything else in the entry is now everyone's default.
- **The donor pool is on in both builds, Auto when never set.**
  - `DonorPool.swift` and the donor rounds (`DonorRounds.swift`, out of the dev memory probe) leave
    `Dev/`. The release app links `SharedMemory`, and its JIT helper answers the memory calls.
  - Settings › Graphics › Donor memory offers Off and Auto in both builds, and a dev build also offers
    the fixed sizes. The row shows only on a phone with a tier pool (`DonorPoolSizing.offered`).
  - A release build logs the install and the pressure changes, not the 30 s stats.
- **The end of a game's own Social Club, and the refusal of its restarts, are on in both builds.**
  - These are 0133 with 0141's timing and 0138. They are on when never set
    (`GameSocialClubEnd`, out of `Dev/`), with rows in Settings › Graphics.
  - Both act only for a Play with a publisher launcher's sign-in, on `SocialClubHelper.exe` whose creator
    or ancestor is RDR2.exe.
- **Not taken: `PLAYPORT_SC_SINGLE`.** It stays dev-only, compiled out of release (decision 0150). Run xs1
  ([single-process with the end](../evidence/2026-10-21-rdr2-sc-single-with-end.md)) was not clearly no
  worse: the porch went black after the game's helper was ended.

## Where each default acts

| Default | Where it acts | Elsewhere |
| --- | --- | --- |
| `endLauncherAfterSignIn`, the Social Club end and refusal | a game whose PublisherLauncher has a sign-in (RDR2); helpers under or started by RDR2.exe | nothing |
| `env.PLAYPORT_SC_BLOCK_CRASHPAD=1` | `RockstarErrorHandler.exe`, any `--type=crashpad-handler` start | a Chromium-based launcher's crash handler is refused too; Chromium goes on without it (RDR2's launcher did) |
| `khronosVulkanLoader` | every Vulkan game: the Khronos loader in place of Wine's `vulkan-1` | it loads only the layers a game asks for |
| `windowsServices` | services.exe starts before every game | a start-up cost, measured on the gate |
| `jitPoolMB` 896, `jumbo-mb=8960` | every game's JIT pool and an 8,960 MB address-space hold | a memory and start-up cost, measured on the gate |
| `steamAPI` client | every Steam game uses its own steam_api with Playport's client, not the emulator | a game that needs the emulator gets `steamAPI: emulated` in its compatibility entry |

## Costs and risks

- **Every game now runs on Vulkan, Playport's Steam client, Windows services, the larger pool and
  RDR2's runtime keys.**
  - Before this, each had been measured only on the games it was set for.
  - The gate (Hollow Knight to first frame+10, and every title installed on the phone) shows only that
    titles start. A title that a key breaks gets a per-key exception in its compatibility entry, not a
    silent revert.
- **The release app now holds the donor pool's helper memory path,** which had no release play before.
- **`PLAYPORT_SC_BLOCK_CRASHPAD` was not measured alone** (x3, x5, x6 only).
