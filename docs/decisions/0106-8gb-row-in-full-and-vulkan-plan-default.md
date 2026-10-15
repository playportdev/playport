# 0106: the 8 GB row in full, and the Vulkan clamp on by default

**Status:** accepted, 2026-10-15, by the owner ("fix vulkan, set 8gb limits as I said, the 8gb
test that will be run one day can change them"); the 512 MiB margin is the implementing
worker's choice. Amends [0105](0105-memory-defaults-per-phone.md).
[PLA-355](https://linear.app/playportdev/issue/PLA-355) (the 8 GB row),
[PLA-362](https://linear.app/playportdev/issue/PLA-362) (Vulkan),
[PLA-216](https://linear.app/playportdev/issue/PLA-216).

## Context

0105's clamp told the guest G = min(tier G, (L + 64) rounded down to 1,024). The public
figure for an entitled 8 GB phone's limit is about 6,046 MiB, 98 under the 8 GB row's 6,144,
so that phone got 5,120 / 1,536 rather than the owner's 6,144 / 2,048. The limit is read
as available + footprint, and a phone's real limit is not a whole GiB.

On the Vulkan backend V reached DXGI (DXVK's `dxgi.maxDeviceMemory`) and KosmicKrisp's
heap budget (patches/mesa 0036, `PLAYPORT_VK_BUDGET_MB`) only with `vulkan-vram-plan = 1`, so
Hollow Knight on its default Vulkan backend still saw an 8 GiB device with a 6 GiB budget
([evidence](../evidence/2026-10-15-vulkan-clamp.md)).

## Decision

- **The clamp applies only when L < tier G − 512 MiB.** Otherwise the tier's G (and V)
  apply in full. Clamped, the rule is 0105's: G = min(tier G, (L + 64) rounded down to
  1,024), V = min(tier V, 3/8 of G rounded down to 512, at least 768).

  | Phone, L (MiB) | G / V before | G / V now |
  | --- | --- | --- |
  | 12 GB with Game Mode, 8,191 | 8,192 / 3,072 | 8,192 / 3,072 |
  | 12 GB before Game Mode, 6,144 | 6,144 / 2,048 | 6,144 / 2,048 (clamped) |
  | 12 GB unentitled, about 3,356 | 3,072 / 1,024 | 3,072 / 1,024 (clamped) |
  | 8 GB entitled, about 6,046 | 5,120 / 1,536 | 6,144 / 2,048 |
  | 8 GB unentitled, about 3,355 | 3,072 / 1,024 | 3,072 / 1,024 (clamped) |

  Why 512: the readings of a tier's own limit fall short of its G by up to about 100 MiB
  (1 on the 12 GB phone, 98 on the 8 GB public figure), while the shortfalls the clamp is
  for are whole GiB or more (2 GiB before Game Mode, about 5 GiB unentitled). 512 MiB sits
  between the two with room on both sides. A limit 513 MiB or more short still clamps and
  rounds down, as before.
- **Vulkan takes the plan's V by default.** On the Vulkan backend the app adds
  `dxgi.maxDeviceMemory = V` to `DXVK_CONFIG` and sets `PLAYPORT_VK_BUDGET_MB = V` (KosmicKrisp
  caps heap 0's budget, not its size). `vulkan-vram-plan = 0` in a title's config turns both
  off; any other value, or none, leaves them on. A title's `vram-mb` still wins over the
  plan's V, here as on DXMT. The `memory plan:` line shows `vulkan_clamp=1`.
- **The 8 GB row may change.** No 8 GB phone has run it. The PLA-355 measurement on a real
  8 GB phone may change its G, V or pool, by a new record.

## Consequences

- **An 8 GB phone may be told more than its limit holds.** G 6,144 against L 6,046, with
  V 2,048 and the 1,024 pool: 0105's note that G − pool + V + runtime can exceed L applies
  more strongly there. A title that fills its budget is jetsammed rather than refused; its
  fix is a per-title `totalphys` or `vram-mb`, and the 8 GB measurement may lower the row.
- **DXVK evicts once over budget.** DXVK's allocator on a unified-memory device does not refuse
  allocations over the budget (`enforceBudget` is off), but frees empty chunks sooner and starts
  evicting and defragmenting once a heap is over it. A Vulkan title that keeps more than V
  resident (3,072 MiB on the 12 GB phone, 2,048 on 8 GB) may pay for that work each frame.
  This is unmeasured on a heavy Vulkan title; Hollow Knight uses far less. Such a title's fix
  is `vulkan-vram-plan = 0` or a larger `vram-mb`.
- A Vulkan title now reads the same video memory as it would on DXMT, which keeps
  minimum-spec checks consistent between the backends.
