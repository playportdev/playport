# Every dependency to its latest version (alignment plan, step 1)

**Date:** 2026-10-05. **Plan:** [Proton ARM64 alignment](../plans/2026-10-05-proton-arm64-alignment.md),
step 1 (rows 2–10), under decision [0049](../decisions/0049-latest-pins.md).
**Kind:** build records for one move per commit. The phone was away (the
owner's) from 14:14: by the owner's direction each move is built and tested
on the workstation and committed with its IPA, and the gate plays and
`pp perf` runs are made later on these IPAs, in order, so that a regression
can be bisected.

## Baseline (before any move)

- Commit `e71e8a7` (decision 0049, no pin change), dev IPA
  `.work/out/20261005-140757-b1c15122/Playport-26.5-b1c15122.ipa`, SHA256
  `b1c1512228c25d16a0e08860ad878bde053f04378630d35d6359ec54958803f3`.
- Gate, one locked session (`pp install --no-build`, then both plays):
  - Hollow Knight (`app-367520`), `.work/ui-runs/20261005T140831`: JIT after
    2.39 s, first frame at +9.48 s, ran on to `first-frame+10`; the screenshot
    shows the main menu.
  - Portal 2 (`app-620`), `.work/ui-runs/20261005T140921`: JIT after 2.42 s,
    first frame at +5.46 s (as in the 2026-10-04 records, 5.6–5.7 s), ran on to
    `first-frame+10`; the screenshot is black (the game's start, before its
    menu, as at that point in earlier runs).
- `pp perf` before (both routes): **pending: phone away.** The Hollow Knight
  run (`dl0-base-hk`) was stopped in its cooldown wait before it measured.

## The moves

One row per dependency. Valve's columns are the 2026-10-05 snapshot in the
plan (stable `proton_11.0` / experimental / bleeding-edge).

| Row | Old pin | New pin | Latest upstream | Valve stable / experimental / bleeding-edge | Build, `pp test` | Gate | `pp perf` |
|---|---|---|---|---|---|---|---|
| `wine` | wine-11.18 `7b3fff7` | wine-11.19 `455e350` | wine-11.19 (2026-10-02; no later tag) | Valve Wine `dc26e61` / `6d211aa` / `750fd01` | passed | pending: phone away | pending: phone away |

## IPAs, in order

Each IPA is a dev build of exactly its commit (a clean tree), kept in its
`out/` directory for the plays and a bisection.

| Step | Commit | IPA | SHA256 |
|---|---|---|---|
| baseline | `e71e8a7` | `.work/out/20261005-140757-b1c15122/Playport-26.5-b1c15122.ipa` | `b1c1512228c25d16a0e08860ad878bde053f04378630d35d6359ec54958803f3` |

## wine → wine-11.19

- **Distance:** 353 WineHQ commits, `wine-11.18..wine-11.19` (`455e3509b98a`).
- **Trial** (`pp rebase wine-pe|wine-unix 455e3509 --trial`): wine-pe stack
  211 patches, 210 clean, 1 conflict; wine-unix stack 198 patches, 197 clean,
  1 conflict. No 3-way merge, nothing upstream.
- **Resolution (one):** `wine-port/0031` (Crashpad-VEH context guard), in
  `dlls/ntdll/signal_arm64ec.c`'s syscall table. Upstream added
  `NtOpenPrivateNamespace` after `NtOpenMutant` (`3f65f20`) and made
  `NtReleaseSemaphore`'s count signed (`f89a7ca`); the patch wraps
  `NtOpenMutant` and `NtReleaseMutant`. Kept both: the patch's
  `DEFINE_WRAPPED_SYSCALL` lines with upstream's new and changed lines. The
  wine-unix run replayed it by rerere; its tree and exported series are the
  same as wine-pe's. Its trailer is now `Rebased: resolved`.
- **Range-diff flags:** only `wine-port/0031`, the resolution above (checked:
  the two added or changed upstream lines and nothing else). No clean patch
  changed. `wine-valve` replayed clean (127 patches).
- **The replacements** (Madeira's `*_ios.c`, built against these Wine
  headers): 7 WineHQ commits in 11.18..11.19 touch the files they override;
  the server protocol did not change. `madeira-unix/0080` (class
  `madeira-port`) carries three into them:
  - `b28fa1c` (`pImeToAsciiEx` takes the IME update pointer, `gdi_driver.h`):
    `driver_ios.c`'s null and loader drivers; needed to compile;
  - `0998bfa` (a zero group affinity is the whole group): `thread_ios.c`;
  - `4e819f0` (hardware messages mergeable): `queue_ios.c`.
  `f59c425` (win32u `freetype.c`) comes in through `freetype_ios.c`'s
  `#include`. **Not carried:** the three `virtual.c` commits (`76159fc` the
  first thread data below 16 GiB, `4c18d96` a top-down reserve, `5285712`
  the 64-bit virtual heap from `mmap`). They change the Linux preloader's
  address layout; `virtual_ios.c` places the first thread data, the reserves
  and the virtual heap for iOS itself (the 4 GiB `__PAGEZERO`, the arena and
  the guest band), so carrying them is a separate change for the phone.
- **Build:** the `unix`, `pe`, `dxmt` and `vulkan` stages ran; the three
  `wine-pe-*.tsv` manifests and `app/artifacts.tsv` changed, and the prefix
  registry seed gained one key (`app/registry/system.reg`, `pp registry`).
  `pp test`: all passed.
- **Open question 5** (does wine-11.19's wow64 consume `ChpeV2CpuAreaInfo` as
  FEX `af04940` assumes): WineHQ's `dlls/wow64` does not read it at all. The
  consumer is ntdll's unix side: `signal_arm64.c`'s suspend doorbell
  (`SuspendDoorbell` with `InSimulation`/`InSyscallCallback`) and the thread
  context code, which take the TEB's pointer whoever set it — the premise of
  `af04940`. Neither changed between 11.18 and 11.19. On Playport that code is
  Madeira's `signal_arm64_ios.c` (which has the doorbell path) and
  `thread_ios.c`; whether they behave as WineHQ's for a WoW64 thread's CPU
  area is what the FEX move's Portal 2 play shows.
