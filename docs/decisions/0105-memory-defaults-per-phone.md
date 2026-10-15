# 0105: the memory defaults per phone

**Status:** accepted, 2026-10-15, by the owner ("implement now and merge to main"), with the
supervisor's extrapolation of the 6 and 4 GB rows; the clamp is the implementing worker's
choice. Amended by [0106](0106-8gb-row-in-full-and-vulkan-plan-default.md): the clamp
applies only to a limit more than 512 MiB under the tier's G, and the Vulkan clamp is on by
default. [PLA-355](https://linear.app/playportdev/issue/PLA-355),
[PLA-352](https://linear.app/playportdev/issue/PLA-352) (the memory plan),
[PLA-351](https://linear.app/playportdev/issue/PLA-351) and
[PLA-216](https://linear.app/playportdev/issue/PLA-216) (the donor pool). Replaces the memory
plan's formulas ([evidence](../evidence/2026-10-14-memory-plan.md)) and Auto's sizing from the
headroom ([evidence](../evidence/2026-10-15-donor-pool-auto-headroom.md)).
[Evidence](../evidence/2026-10-15-memory-defaults.md).

## Context

The memory plan told the guest the app's limit L as its RAM (8,192 MiB on the 12 GB reference
phone) and reported L − 4 GiB − 2 GiB − 512 MiB = 1,536 MiB of video memory; a donor pool
could raise the guest's RAM up to the game's budget (0 MiB on that phone). Auto sized the dev
build's pool from RAM − 2 GiB − 12 % − min(L, 4 GiB): 4,096 MiB on 12 GB, none on an entitled
8 GB phone. Kingdom Come runs told 9,216 MiB of RAM and 2,048–3,072 MiB of video memory, with
and without the pool, at low and at medium, at 720 and at the panel's 2736×1260, all survived
600 s ([ceiling](../evidence/2026-10-15-memory-ceiling-vram.md),
[medium](../evidence/2026-10-15-vram-medium.md)).

## Decision

- **One table, by the phone's RAM** (PlayportKit `MemoryPlan.Tier`), for the guest's RAM G
  (`MADEIRA_TOTAL_PHYS_MB`), the video figure V (`PLAYPORT_VRAM_MB`) and the dev build's Auto
  donor pool:

  | Phone RAM | Reported RAM (hw.memsize) | G (MiB) | Auto pool (MiB) | V (MiB) |
  | --- | --- | ---: | ---: | ---: |
  | 12 GB (and more) | ≥ 10 GiB (11,734 measured) | 8,192 | 4,096 | 3,072 |
  | 8 GB | ≥ 7 GiB (7,679) | 6,144 | 1,024 | 2,048 |
  | 6 GB | ≥ 5 GiB (5,734) | 3,072 | 0 (setting hidden) | 1,024 |
  | 4 GB | under 5 GiB (3,662) | 2,048 | 0 (setting hidden) | 768 |

  The 12 and 8 GB rows are the owner's. The 6 and 4 GB rows extrapolate his pattern: G is the
  app's limit rounded down to a whole GiB, the pool exists only where RAM is spare, and V is
  3/8 of G rounded down to 512 MiB, at least 768 (the rule reproduces every row's V).
- **The clamp to the limit.** The limit L is read just before Wine starts. When it is lower
  than the tier assumes (a signer that dropped the increased-memory-limit entitlement, or a
  Play before Game Mode raises 6 to 8 GiB), G = min(tier G, L rounded down to 1,024) and
  V = min(tier V, 3/8 of that G rounded down to 512, at least 768): 6,144 / 2,048 on the 12 GB
  phone at L 6,144, 3,072 / 1,024 unentitled. L is read as available + footprint in whole MiB
  (8,191 for the 8 GiB limit), so 64 MiB of slack are added before rounding. The
  `memory plan:` line says `clamp=yes`. This errs low: a guest told less RAM than it could use
  loses little, while one told more than the app may hold can be ended by jetsam.
- **The pool no longer raises G.** G is the table's value with or without a pool. Auto asks
  for the tier's pool, still at most one donor's grant and still behind the growth stop
  (`donor-pool: pressure`); the fixed sizes and Off are unchanged.
- **Overrides win as before:** a title's `totalphys` and `vram-mb` (its cohort `config`, the
  dev Runtime keys, the shared madeira.cfg) and `MADEIRA_TOTAL_PHYS_MB` set in the
  environment; the dev `set:donorPoolMB` fixed sizes and Off.
- **The `memory plan:` line** shows the tier and its row, RAM, L, the clamp, the planned and
  effective G and V, the pool granted and any override.

## Consequences

- **G − pool + V + about 2 GiB of runtime can exceed L** if a title fills everything:
  4 + 3 + 2 = 9 GiB against 8 on the 12 GB phone, 5 + 2 + 2 = 9 against 6 on 8 GB. Most titles
  use far less; Kingdom Come at medium/native peaked at 6.3 GB of footprint with the pool. A
  title that does fill its budget is jetsammed rather than refused, and its fix is a per-title
  `vram-mb` or `totalphys`.
- **On Vulkan, V reaches DXGI and KosmicKrisp only with `vulkan-vram-plan = 1`** (off by
  default): a Vulkan title (Hollow Knight's default backend, decision 0044) still sees about
  8 GiB of video memory. G applies to every backend.
- **V mainly matters for minimum-spec checks.** Kingdom Come's graphics memory did not follow
  V at 1,536, 2,048 or 3,072 MiB, at low or medium; only its machine class moved (2 from 2,048
  on). DXMT's trim (ml1075) still shrinks the budget as the footprint nears L.
- **The 8 GB and smaller rows are unmeasured** (PLA-355): no 4, 6 or 8 GB phone has run them.
- The release build has no donor pool; its G and V are the same table's.
- `DonorPoolSizing`'s headroom constants (the system reserve, the app's part, the 6 GiB Auto
  maximum, the 1 GiB minimum) and the plan's overhead, guest-share and margin constants are
  removed.
