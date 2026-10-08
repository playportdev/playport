# 0067: Not accepted: vkd3d-proton serializing its submissions on KosmicKrisp with a semaphore, not a barrier command buffer

**Status:** not accepted, 2026-10-08, unattended under the owner's protocol in the
[Vulkan performance plan](../plans/2026-10-06-vulkan-performance.md) (decision 0061: each
new vkd3d-proton patch gets its own record; rule 4: what does not help is reverted). The
patch took effect but moved no CPU figure in a warm 720/60 Direct3D 12 pair
([evidence](../evidence/2026-10-08-vulkan-perf-vkd3d-kk-driver.md)). It was reverted:
`patches/vkd3d-proton` keeps 0001–0004, and [0032](0032-vkd3d-proton-as-a-series.md)'s
series is unchanged. The record stays as the code reading for whoever takes it up again.

## What was proposed

- **`patches/vkd3d-proton` 0005** (class `feature`): `VK_DRIVER_ID_MESA_KOSMICKRISP` joins
  RADV, AMD's drivers and NVIDIA's in `vkd3d_driver_implicitly_syncs_host_readback()`
  (`libs/vkd3d/command.c`). On KosmicKrisp vkd3d-proton then creates no reusable
  full-barrier command buffer, and each Direct3D 12 queue serializes its
  `ExecuteCommandLists` submissions with a binary semaphore, as on those drivers.
- Not offered upstream: it is Playport's entry for a driver upstream does not target.
- vkd3d-proton's other driver lists stay as they are. In particular KosmicKrisp does not
  join the tiler workarounds (`tiler_renderpass_barriers`, `tiler_suspend_resume`):
  that is a separate measurement, after [0066](0066-dxvk-tiler-mode-off.md).

## Why it was proposed

Without it, vkd3d-proton appends one `SIMULTANEOUS_USE` command buffer, a single
`ALL_COMMANDS` to `ALL_COMMANDS | HOST` memory barrier, to every submission. A Metal
command buffer can be committed once, so KosmicKrisp (`kk_queue.c`,
`rerecord_and_commit_cmd_buffer`) re-records that buffer on every later submission: the
queue mutex, a new Metal command buffer, a replay of its `vk_cmd_queue`, an allocation, a
residency pass, a commit with a completion handler, and the same mutex again when it
completes. The barrier itself encodes nothing: `kk_CmdPipelineBarrier2` acts only inside an
open render or compute encoder, and this buffer has none, so it commits an empty Metal
command buffer.

The semaphore path keeps what the barrier promised:

- **Order between submissions.** KosmicKrisp has one queue, and a binary semaphore there is
  the runtime's wrapper over its Metal-event timeline: the wait and signal become
  `waitForEvent:value:`/`signalEvent:value:` on the same `MTL4CommandQueue`
  (`kk_queue_submit`). That adds ordering in Metal; the empty barrier buffer added none.
- **The host's view of GPU writes.** KosmicKrisp's only memory type is host visible,
  coherent and cached, in Metal shared storage, so there is no flush or invalidate for the
  barrier's `HOST_READ` to drive. A host read after a fence wait is ordered after the
  Metal command buffers that wrote the data, with or without the barrier.

## Why it was not kept

On Hollow Knight with `-force-d3d12` at 720/60 (warm pair, IPA `4554db58…` against
`18d0ea54…`), KosmicKrisp's first 40 Metal commits held 20 empty ones before and 13 after,
so the barrier buffers were gone. CPU power stayed at 793 against 792 mW, work a frame at
79.9 against 81.9 Mi/f, and the submitting `vkd3d_queue` thread at 0.82 against 0.83 Mi/f.
The re-record is too cheap to show against vkd3d's +45 % CPU power over DXMT, which lies in
the game's render worker under FEX. Carrying a patch with no measured gain is not worth
the cost of each `vkd3d-proton` pin move.

## What it would cost

One more patch to carry over each `vkd3d-proton` pin move. A game that reads a readback
resource with no fence wait was not ordered by the barrier on KosmicKrisp either, so it
changes nothing for it.
