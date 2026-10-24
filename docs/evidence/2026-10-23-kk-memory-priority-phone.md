# KosmicKrisp memory priority: main-checkout phone gate

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431). **Plan:**
[Proton parity](../plans/finished.md#kosmickrisp-proton-parity). B1 runtime smoke passed on
DXVK and vkd3d-proton, with the client-log limitation below. No gameplay or performance claim.

## Integration and build

Rebased `dev/kk-proton-parity` from `7103952` onto main `26699f6`, then detached the side
copy and switched the branch into the main checkout (transfer HEAD `4fa1e73`). Main was not
moved; no merge or push. Original B1 `a2fba62` → `7dee945`, Mesa 0104 → **0119**;
B3 `12d113b` → `2a76219`, 0105 → **0120**. Experimental bits are now **16/17**, leaving
main's 0–15 intact. Both sets of host tests survive the append/helper conflicts; embedded
patches were regenerated against 0118, with no other semantic change.

Fresh main-checkout dev IPA:
`$PLAYPORT_BUILD/out/20261023-071927-5e3fc6a8/Playport-26.5-5e3fc6a8.ipa`, SHA256
`5e3fc6a89019ef10f054d3ce47f4191e0354ff5df66c73d65814d7fd0241da7d`.
`pp build`: 89 verification checks passed, 0 failed; independent `pp verify --sha256` passed.
No tracked build-record rows changed. Upgrade in place succeeded; container retained.

**Local-source qualification:** the IPA includes the owner's uncommitted
`app/Sources/S1Probe/UI/SettingsView.swift` edit. It was never changed, staged, stashed or
committed by this worker. File SHA256
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`;
binary diff SHA256 `3e371c630d659be316befde9e60824ae0a4be12f44a52084d1595740532ea7b9`.
Private snapshots are under `$PLAYPORT_BUILD/agent-notes/kk-parity/`. This is not an
exact committed-source IPA.

Main Mesa host suite passed: B1 allocation=1/set=2, **185/185** MSL libraries identical;
B3 **185/185**, GPL+B3 **239/239** identical before their own identifier checks;
cache miss/hit/second-device checks passed. The combined `gpl,memory_priority,module_identifier`
run passed. Eighteen experimental bits are unique; existing MSL41/NO_FP_PRESERVE isolation
checks passed alongside parity checks. `pp test --quick`, `pp names` and `pp secrets` passed.
Logs: `$PLAYPORT_BUILD/agent-notes/kk-parity/b1-{build,verify,hosttest,combined-host,quick}.log`.

## Phone

Owner confirmed VPN/JIT ready after the prior session's setup failure; no failed startup was
retried. Phone: iPhone18,4, iOS 27.0.1, 80% on external power before/after. Built-in JIT
succeeded in 2.94–3.10 s. Existing unattended state was retained, not enabled or renewed.
Installation and the first four runs held one `pp phone lock` session.

All runs explicitly selected `graphics=vulkan`, 720p/60, scripted pad, HUD off, with
`arguments=-force-d3d11` (DXVK) or `-force-d3d12` (vkd3d). Baselines used empty
`graphicsOptions`; B1 used only
`MESA_KK_EXPERIMENTAL=memory_priority MESA_KK_DEBUG=memory`. Settings were session-restored.

All paths below are beneath `$PLAYPORT_BUILD/ui-runs/`. Each final `event:result` has
`ok:true`, `exit:0`, `until_reached:true`, `why:"until first-frame+10"`, and the full IPA hash above.

| Run | Directory | First frame | Last priority allocations/sets |
| --- | --- | --- | --- |
| Flag off, DXVK | `20261023T072230` | +10.86 s | no suffix |
| Flag off, D3D12 | `20261023T072320` | +12.93 s | no suffix |
| B1, DXVK | `20261023T072414` | +10.95 s | 14/14 |
| B1, D3D12 | `20261023T072504` | +10.95 s | 28/13 |
| B1, D3D12, `VKD3D_DEBUG=trace` | `20261023T072648` | +11.07 s | 28/13 |

Logs (`pull/s1-host.log`) confirm DXVK 3.1.1 and the D3D11 route, and vkd3d-proton
`567710d877bb3d4` creating the D3D12 swapchain. DXVK's extension lists name both
`VK_EXT_memory_priority` and `VK_EXT_pageable_device_local_memory`; their feature values
are 0 in flag-off runs and 1 in flag-on runs (including the DXGI client in D3D12 runs).
There are no new GPU fault/device-loss/shader-compilation-error signatures. Existing vkd3d
alignment/shared-fence/present-wait fixmes also appear in the baseline; a baseline compile
summary's `failed=0` is not an error. All five stop screenshots show the expected title/menu,
with no obvious corruption (the first is captured dimmer). No gameplay was driven.

**Verification limit:** release vkd3d compiles `TRACE` out (`VKD3D_NO_TRACE_MESSAGES`), so
its own extension-name enumeration is **not observable**, even in the trace run. The original
client-log criterion is therefore not literally fulfilled for vkd3d. Its initial `[kk-mem]`
line, before DXVK allocates, is `priority allocations=1 sets=0`; `memory.c`'s
`vkd3d_memory_allocation_init` chains that priority only when `memoryPriority` is enabled.
This is behavioral evidence for vkd3d memory priority. The initial zero sets is not a failure:
later mixed/global counts reach 25/11 then 28/13, but cannot attribute pageable calls to
vkd3d rather than DXVK. Vkd3d-specific pageable enablement is not independently proven here.
Supervisor accepted the runtime gate with this explicit limit, without a logging rebuild.
Priority remains a no-op residency hint, default off.

A next-session UI inspection (`20261023T072801`, exit 0) restored inherited defaults:
720p/60/Vulkan, no arguments; existing control overrides retained. Logs/screenshots remain
private under `.work`; no artwork is published. Next: **B3 phone gate**, then **A0 CPU profile**;
descriptor work remains gated on A0. Neither was run in this chunk.
