# Vulkan clamp: KosmicKrisp's heap budget follows the memory plan (PLA-353)

**Date:** 2026-10-15 (07:09–07:13). **Branch:** `research/extended-memory`.
**Linear:** [PLA-353](https://linear.app/playportdev/issue/PLA-353), under
[PLA-216](https://linear.app/playportdev/issue/PLA-216).
**Plan:** [donor memory](../plans/finished.md#guest-ram-from-donor-processes), the follow-up left open by
[the memory plan](2026-10-14-memory-plan.md).

**Setup:**

- iPhone18,4, iOS 27.0.1, 100 % at the start and the end, unattended mode on.
- Dev IPA SHA256 `efd4f8e653f397169ed80c68608ad66a5c548ef8adbecc09e8ada7ec43fe42de`
  (commit `4e3ea9e`), installed in place in this session ("upgrade in place, container kept").
- Hollow Knight (app-367520), launched to first frame +10 with a shot, no presses, no save.
  The session script is `$PLAYPORT_BUILD/agent-notes/donor-memory/runs/vkclamp-session.sh`, with its
  `.log` and run directories under `runs/vkclamp/`.

## The problem

DXVK over KosmicKrisp saw `Heap 0: 8.0 GiB (DEVICE_LOCAL)`, Metal's recommended working set,
with a `VK_EXT_memory_budget` budget of about 6 GiB: 90 % of what the process may still allocate
(mesa 0004) plus what Metal already holds. By DXVK's code, DXGI then reports 8,160 MiB of
dedicated video memory (the heap less 32 MiB) and the heap budget as `QueryVideoMemoryInfo`'s
Budget. DXMT reports the plan's 1,536 MiB. `vulkan-vram-plan = 1` (PLA-352) added
`dxgi.maxDeviceMemory = <plan>` to `DXVK_CONFIG`, which clamps only the dedicated memory in
the adapter description. The budget a game reads from DXGI, and the one DXVK's own allocator
works to, stayed about 6 GiB.

## The change

- **patches/mesa 0036:** when `PLAYPORT_VK_BUDGET_MB` is 256 or more, KosmicKrisp caps heap 0's
  budget at that many MiB, and logs one line:
  `[kk-memory] heap 0: size 8192 MiB, budget capped at 1536 MiB (PLAYPORT_VK_BUDGET_MB)`.
  Unset, the driver is unchanged.
- **The app:** the same key, `vulkan-vram-plan = 1`, now also sets `PLAYPORT_VK_BUDGET_MB` to
  the plan's video memory (`MemoryPlan.vulkanEnvironment`, or a title's own `vram-mb`). It is
  set only on the Vulkan backend, as the DXVK option is. The key stays off by default.
- **Host test:** `build/mesa-host-test/kk-host-test.c` makes three instances on the mock bridge.
  Uncapped, the heap is 5,120 MiB with a budget of 5,120 MiB. At 1,536 the heap stays 5,120 and
  the budget is 1,536. At 100 the cap is ignored and the budget is 5,120.

### Decisions

- **Only the budget is capped, not the heap's size.** The budget is advice: what the application
  should stay under now. The heap's size states what the device can hold, and an application
  may size pools or caches from it. A smaller heap would change what a title may allocate and how
  DXVK sizes its chunks (by the heap's size), for every Vulkan and vkd3d-proton title. DXGI's
  dedicated memory, the one place a D3D game reads a size, is already clamped by DXVK's option.
  Clamping the size is the larger change, and it was not needed.
- **One key, not two.** `vulkan-vram-plan` already meant "Vulkan reports the plan's video memory".
  It was added on this branch the day before, and no title sets it. A second key would allow a
  DXGI description of 1.5 GiB with a 6 GiB budget, which is the state this change removes. The
  variable is separate (`PLAYPORT_VK_BUDGET_MB`, not `PLAYPORT_VRAM_MB`) because the app always
  sets `PLAYPORT_VRAM_MB` for DXMT, and the cap has to stay opt-in.

## Phone results

| Run | Settings | First frame | Plan line | DXVK log (each device) | `[kk-memory]` | DXGI dedicated (by DXVK's code) |
| --- | --- | --- | --- | --- | --- | --- |
| `hk-vulkan-off` | `graphics=vulkan` | +9.41 s | video 1,536, `vulkan_clamp=0` | `Heap 0: 8.0 GiB`, `Budget: 6.1 GiB`; then `8.0 GiB`, `6.28 GiB` | none | 8,160 MiB |
| `hk-vulkan-on` | `graphics=vulkan`, runtime `vulkan-vram-plan=1` | +10.37 s | video 1,536, `vulkan_clamp=1`; `DXVK_CONFIG dxgi.maxDeviceMemory = 1536; PLAYPORT_VK_BUDGET_MB=1536` | `Heap 0: 8.0 GiB`, `Budget: 1.50 GiB`; then the same | 2 lines (one per instance), size 8,192, cap 1,536 | 1,536 MiB |
| `hk-dxmt` (gate) | `graphics=dxmt` | +9.29 s | video 1,536, `vulkan_clamp=0` | — | none | `ml1042 video memory budget = 1536 MB (… from Playport's memory plan)` |

- **All three runs reached first frame +10** (`ok`, `until_reached`). Each shot at +10 shows
  Hollow Knight's title menu, with Start Game, Options, Achievements, Extras and Quit Game.
- **The `c0000005` lines** are the same 14 in all three runs (`[mach-deliver]` and `[exc-disp]`,
  handled during start-up). No run logged an unhandled exception.
- **What is inferred, not logged.** DXVK does not log the adapter description or
  `QueryVideoMemoryInfo`. The "DXGI dedicated" column applies DXVK's pinned `dxgi_adapter.cpp`
  to the logged heap and the option. DXGI's Budget is the logged heap budget.
- **First frame on.** It came about 1 s later than off (+10.37 vs +9.41 s). One run each way:
  noise until repeated. Hollow Knight's GPU memory is far under 1.5 GiB.

## Risks and not checked

- DXVK's allocator on a unified-memory device does not refuse allocations over budget
  (`enforceBudget` is off). It does free empty chunks sooner and starts evicting and
  defragmenting once a heap is over its budget. A title that keeps more than the plan's video
  memory resident (1.5 GiB on the reference phone) may pay for that work every frame. Not
  measured: no heavier Vulkan or Direct3D 12 title was launched. That step was optional, and of
  the installed candidates The Witcher 3 has a known quit hang, so it was skipped.
- vkd3d-proton (Direct3D 12) reads the same budget. That path was not run.
- The cap is read when the instance enumerates its physical device. The app sets it before Wine
  starts, and the app restarts for each game (decision 0029).
- The host test's uncapped checks need about 2 GiB of free host memory.
