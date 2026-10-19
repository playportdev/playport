# Memory defaults per phone: the tier table on the 12 GB phone

**Date:** 2026-10-15 (14:35–15:00). **Branch:** `research/extended-memory` (`d6199a6`).
**Linear:** [PLA-355](https://linear.app/playportdev/issue/PLA-355),
[PLA-352](https://linear.app/playportdev/issue/PLA-352),
[PLA-351](https://linear.app/playportdev/issue/PLA-351),
[PLA-216](https://linear.app/playportdev/issue/PLA-216); titles PLA-42 (Hollow Knight, app-367520)
and PLA-49 (Kingdom Come: Deliverance, app-379430).
**Decision:** [0105](../decisions/0105-memory-defaults-per-phone.md).
**Plan:** [donor memory](../plans/finished.md#guest-ram-from-donor-processes).

## Setup

- iPhone18,4 (2736×1260 panel), iOS 27.0.1, 11,734 MiB of RAM, on the charger at 80 % all session,
  unattended mode on.
- Dev IPA SHA256 `f9e47014865d87b49a8e5fb5fbb7b7ce2bd848b3362680484ca64f09a9fb72d9` (`d6199a6`),
  installed in place by `pp install --no-build`.
- The host's toolchain was upgraded the same morning (system LLVM 22 → 23, Swift 6.4.0 → 6.4.1,
  pymobiledevice3 11.31.0): the build rebuilt every tree, the in-repo xtool was rebuilt
  (`build/toolchain/xtool.sh`), the stale mesa host build directory was removed, and two tool
  fixes went in (`build/pipeline`'s Swift resource-header path, `lockdown get`'s positional domain
  in `build/install` and `pp`). The first session stopped at the install's disk check on the latter;
  nothing was installed.
- Sessions `tier-session.sh` (install, HK, KCD) and `tier-hk-dxmt.sh` (HK on DXMT), each one
  `pp phone lock`. Runs under `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/tier/`.

## The table as implemented

PlayportKit `MemoryPlan.Tier`, by reported RAM (hw.memsize):

| Tier | Reported RAM | G (guest RAM, MiB) | Auto pool (MiB) | V (video, MiB) |
| --- | --- | ---: | ---: | ---: |
| 12 GB (and more) | ≥ 10,240 | 8,192 | 4,096 | 3,072 |
| 8 GB | ≥ 7,168 | 6,144 | 1,024 | 2,048 |
| 6 GB | ≥ 5,120 | 3,072 | 0 (not offered) | 1,024 |
| 4 GB | < 5,120 | 2,048 | 0 (not offered) | 768 |

- **Clamp:** G = min(tier G, (L + 64) rounded down to 1,024); V = min(tier V, 3/8 of G rounded
  down to 512, at least 768).
  - L 8,191 or 8,192 gives the 12 GB row unclamped.
  - L 6,144 (before Game Mode) gives 6,144 / 2,048.
  - L 3,356 (unentitled) gives 3,072 / 1,024.
- The host tests (`MemoryPlanTests`, `DonorPoolSizingTests`) cover every tier, the boundaries,
  the clamp and the overrides.

## Gate 1: install

`pp install --no-build` upgraded in place. `pp phone status` then reported the IPA above.

## Gate 2: Hollow Knight

**HK's default backend is Vulkan.** Its UnityPlayer.dll imports `D3D11On12CreateDevice`, so
decision 0044 picks Vulkan. The default-settings run therefore has no DXMT line, and a second run
named DXMT.

| Run | Settings | First frame | `memory plan:` | ml992 | ml1042 |
| --- | --- | ---: | --- | --- | --- |
| `hk` | defaults (Vulkan), `set:donorPoolMB=auto` | +12.84 s | `tier=12GB … L_mb=8192 clamp=none … pool_mb=4096 guest_ram_mb=8192 video_mb=3072 override=none` | `MADEIRA_TOTAL_PHYS_MB=8192 -> 8192 MB (override)` | none (Vulkan) |
| `hk-dxmt` | `{"graphics":"dxmt"}`, `set:donorPoolMB=auto` | +12.16 s | the same | the same | `video memory budget = 3072 MB (process limit 8192 MB …; from Playport's memory plan)`; ml1075 3,072, one query |

- **The pool.** Both runs logged `donor-pool: auto L_mb=8191 tier=12GB tier_pool_mb=4096 …
  donor_limit_mb=6139 target_mb=4096 reason="the 12 GB tier's pool"`, then `installed
  granted_mb=4096 objects=16 donors=1`.
- **Screenshots.** Both reached Hollow Knight's title menu (Start Game, Options, Achievements,
  Extras, Quit Game).
- **On Vulkan, V does not reach DXGI or KosmicKrisp** unless the title sets
  `vulkan-vram-plan = 1`, which is off by default. Vulkan titles therefore still see about
  8 GiB of video memory.

## Gate 3: Kingdom Come, medium, native, Auto, no overrides

**Flow:** `vram-medium-session.sh`'s Continue flow (wait-text menu, the Continue check,
`kcd-continue`, `kcd-walk`). One `pp perf --no-hud --secs 600 --cool 10 --cool-max 20
--syslog-all` with `{"screen":"native","frameLimit":60}`: no Runtime keys, `set:donorPoolMB=auto`.

**KCD's settings.** `attributes.xml` was read before and after and was identical: every
`sys_spec_*` at 2 (medium), HD textures off, `res_x`/`res_y` 2736×1260, `res_fs` 1. No save was
made, and no in-game setting was changed.

| | Result |
| --- | --- |
| `memory plan:` | `tier=12GB ram_mb=11734 tier_guest_ram_mb=8192 tier_video_mb=3072 tier_pool_mb=4096 L_mb=8192 clamp=none … pool_mb=4096 guest_ram_mb=8192 video_mb=3072 override=none` |
| ml992 / ml1042 | 8,192 (`MADEIRA_TOTAL_PHYS_MB`) / 3,072 "from Playport's memory plan"; ml1075 one query, 3,072 |
| KCD's `kcd.log` | "8192MB physical memory installed"; "Dedicated video memory: 3072 MB"; machine class 2 |
| Render | `[guest-window] hwnd=0x900ea shown: 2736x1260 at (0,0)` |
| Peak phys (`[footprint]` census, 297 cycles to the end) | 6,002 MB |
| Graphics ledger, max / mean of the last 20 | 2,633 / 2,496 MB |
| App `internal` / `compressed`, last 20 | 3,317 / 3,298 MB |
| Pool | 4,096 granted; live max 3,270 MiB; at the end live 3,270, resident 1,212, compressed 1,880 MiB; refused 48,724 (all after the growth stop); unmatched 0, map failures 0 |
| `donor-pool: pressure` | one line: growth stopped at level 13 % (spare 3,568 MiB), about +105 s after the install; it did not resume |
| Kernel available (`memorystatus_available_pages`) | 2,044 MiB minimum, median 2,404, from 147 samples at 14:48:57 only (the syslog capture ended at 14:48:59, about +75 s after the first frame, before Continue) |
| Jetsam | **none.** `pp perf` ended `ok` with census lines to the end. The 145 kill lines in the captured window are all `long-idle-exit`, and none names the app |
| FPS mean / median / p10 / min | 20.1 / 11.2 / 9.0 / 8.2 (whole run, about 90 s of menu and load at 60 included) |
| Thermal | nominal → fair → serious, max pressure 10 |

**Screenshots** (in the run directory, not published):

- +300 s faces a plastered wall and a red-and-ochre painted panel up close, with the HUD.
- +590 s looks up at Rattay's half-timbered gables and a church spire against a daylight sky,
  with chimney smoke.
- Neither shows corruption.

**Against B1** (the same scene and settings, `vram-mb=3072` as a Runtime key on the old plan;
[vram-medium](2026-10-15-vram-medium.md)):

- Graphics ledger 2,633 / 2,496 against 2,615 / 2,495.
- Peak phys 6,002 against 6,261.
- Pool live 3,270 against 3,327, with the growth stop at level 13 % against 12 %.
- FPS median 11.2 against 10.0.
- **The new defaults give the same picture as B1's override.**

## Verdict

- **On the 12 GB phone the tier table applies as decided:**
  - G 8,192, V 3,072, Auto pool 4,096, no clamp, no override;
  - ml992 and ml1042 take them, and KCD reports them.
- **Kingdom Come at medium/native ran 600 s on the defaults without a jetsam**, with the same
  memory as the earlier 3,072 override.

## Not shown

- The 8, 6 and 4 GB rows and the clamp on a phone: there is one 12 GB phone (PLA-355).
- The kernel's available memory during play: the syslog capture ended before Continue.
- A title that fills G − pool + V; Vulkan titles with `vulkan-vram-plan = 1`.

## Games

- **Hollow Knight (app-367520): Works.** First frame at +12.84 s on Vulkan and +12.16 s on DXMT,
  with the Auto pool.
- **Kingdom Come: Deliverance (app-379430): Works.** 600 s in Rattay through Continue, at medium
  and 2736×1260, on the new defaults (Auto pool):
  - no crash and no jetsam;
  - FPS median 11.2, thermal serious.
