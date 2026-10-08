# 0060: A dev build's game page sets the Vulkan layers' options, from an allowlist

**Status:** accepted, 2026-10-06, under the owner's answer 3 in the
[Vulkan performance plan](../plans/2026-10-06-vulkan-performance.md) (step 0.1).
Narrows 0034's "environment variables gone" for dev builds only; 0012 holds.

## Decision

- **A Graphics options row** in a game's Developer section (dev builds only,
  `app/Sources/S1Probe/UI/GameDetailView.swift`), saved per game as
  `LaunchSettings.graphicsOptions`, a typed line like the Runtime keys row's.
- **Items at spaces**, each `NAME=value` for one of `DXVK_CONFIG`, `VKD3D_CONFIG`,
  `MESA_KK_DEBUG`, `MESA_KK_EXPERIMENTAL` and `MESA_KK_DISABLE_WORKAROUNDS`, or a
  DXVK option (`dxvk.tilerMode=False`, a `dxvk`, `dxgi`, `d3d8`–`d3d11` section),
  which goes into `DXVK_CONFIG`. DXVK options join with `;` (as DXVK splits
  `DXVK_CONFIG`), a repeated other variable with `,` (vkd3d-proton's and Mesa's
  lists). A line with any other item is not used at all, and the row says so
  (`LaunchSettings.graphicsEnvironment`).
- **The launch sets them over the backend's own environment**
  (`GraphicsBackend.runtimeEnvironment`) and logs `graphics options: …`. A
  `MESA_KK_DEBUG` given here replaces the dev build's own `compile`.
- **The release app ignores them**, as it ignores the other dev-only settings
  (`LibraryModel`), and offers no row.
- The workstation reaches the row as it reaches every launch setting, through the
  UI: `pp ui --settings 'app-367520:{"graphicsOptions":"dxvk.tilerMode=False"}'`.

## Why

Step 3 of the plan screens DXVK, vkd3d-proton and KosmicKrisp switches, each an A/B
on one installed IPA. Without a way in, each would be a build, which breaks the
plan's one-IPA protocol and costs an install per arm. 0034 removed free-form
environment variables from the game page; an allowlist of the three layers'
option strings gives the measurements what they need and nothing else (no
`DYLD_*`, no Wine or FEX switch, nothing a player's launch reads). What step 3 keeps
goes to every player through `GraphicsBackend.runtimeEnvironment`, not through
this row.

## Costs

One more dev-only row and a parser with tests (PlayportKit). The variables reach
the whole app process as well as the game (KosmicKrisp reads them there), which
is harmless while one process plays one title (0030).
