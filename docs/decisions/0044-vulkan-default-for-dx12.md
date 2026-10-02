# 0044: Vulkan is the default for detected Direct3D 12 games

**Status:** accepted, 2026-10-02. Changes [0015](0015-vulkan-backend-accepted.md)'s
DXMT-for-every-game default, not the shipped backends or explicit choices.

## Decision

- With no per-game or global Direct3D choice, a detected DX12 launch uses
  Vulkan (vkd3d-proton on KosmicKrisp); other launches still use DXMT.
- Adoption checks the selected executable's PE32/PE32+ normal and delay
  import tables for `d3d12.dll`, refreshing the result on each scan. It does
  not infer DX12 from an unrelated DLL shipped in the game's directory.
- The combined cohort and player arguments are checked for `-dx12`,
  `-d3d12`, and `-force-d3d12`, case-insensitively. Explicit older Direct3D,
  Vulkan or OpenGL flags suppress the import-based DX12 inference; the last
  recognized API flag wins.
- A game's explicit graphics choice wins over a global choice, which wins
  over detection. Existing choices are not migrated or overwritten. The
  game's Direct3D Default row shows the same result that Play uses, including
  the player's launch arguments.

## Why and limits

DXMT supports Direct3D 10/11, not 12. A DX12 game should default to the
backend that implements its API rather than require an override first.
This is routing, not a claim that every DX12 title works on the phone.

Imports in engine DLLs and dynamic `LoadLibrary` calls are not detected.
Dual-API executables importing D3D12 default to Vulkan unless their arguments
select an older API. The player can still override the backend in Settings
or Game options. Missing, unreadable and malformed executables give no
import-based inference. A build without Vulkan retains its existing refusal
before spending JIT; it does not silently route DX12 through DXMT.
