# 0066: The Vulkan backend turns DXVK's tiler mode off

**Status:** accepted, 2026-10-08, unattended under the owner's protocol in the
[Vulkan performance plan](../plans/2026-10-06-vulkan-performance.md) (rule 4: a
config lever kept goes into `GraphicsBackend.runtimeEnvironment`). Supersedes
[0024](0024-dxvk-picks-its-compiler-threads.md)'s "the Vulkan backend starts with
no `DXVK_CONFIG`"; the rest of 0024 (DXVK picks its compiler thread count) stands.
The measurements are in the
[evidence record](../evidence/2026-10-08-vulkan-perf-config-levers.md).

## Decision

- **The Vulkan backend starts with `DXVK_CONFIG=dxvk.tilerMode = False`**
  (`GraphicsBackend.runtimeEnvironment`), for every game on that backend, dev and
  release. vkd3d-proton does not read it.
- **A dev build's Graphics options (0060) go over it per DXVK option:** a DXVK item
  follows the backend's `DXVK_CONFIG` after `;`, and DXVK takes the last value of a
  key, so an option that names `dxvk.tilerMode` wins and any other keeps tiler mode off
  (`GraphicsBackend.environment(graphicsOptions:)`). Other variables replace the
  backend's, as before.

## Why

DXVK at its pin (`dxvk_device.cpp`) turns tiler mode on for every tile-based driver
it knows, KosmicKrisp included. In tiler mode each render pass is recorded into a
secondary command buffer (`dxvk_context.cpp`, `beginSecondaryCommandBuffer`), so that
later clears, discards and resolves can still change the pass's load and store ops;
the pass is then begun on the primary and the secondary executed into it. KosmicKrisp
cannot run a secondary natively: its trampolines enqueue every secondary command into a
`vk_cmd_queue` (a copy of each call and its arrays), and `vkCmdExecuteCommands`
(`vk_common_CmdExecuteCommands`) replays that queue into the primary on `dxvk-cs`.
Without tiler mode DXVK records the pass straight into the primary, as on a desktop
GPU. Tiler mode also prefers cached memory for mapped allocations, which changes
nothing on KosmicKrisp: its one memory type is cached and coherent.

On route v2 (720, free-running, the same IPA, window t = 85–115 s, where both runs are
in the same place), tiler mode off took Hollow Knight's work a frame from 60.5 to
57.5 Mi/f (−5 %) and CPU power from 1784 to 1675 mW (−6 %), with GPU time unchanged
(5.81 against 5.80 ms), FPS and p99 unchanged, and 180 MiB less memory. The end
screenshot is drawn correctly. The GPU cost a tile-based GPU could pay for the
load and store ops DXVK can no longer patch after the fact did not show.

## What it costs

- **The load and store ops of a pass are fixed when it begins.** A clear, discard or
  resolve that comes after it can no longer turn a store into `DONT_CARE` or a load
  into a clear; on Apple's GPU that can cost memory bandwidth in a game whose
  passes depend on it. Hollow Knight showed none; a game that does would show as
  more GPU time on Vulkan than on DXMT.
- **DXVK's desktop path on a tiler.** Fewer Vulkan users run DXVK this way on
  tile-based GPUs than on desktops; a rendering fault on Vulkan should be retried with
  `dxvk.tilerMode=True` in the game's Graphics options before it is reported.
