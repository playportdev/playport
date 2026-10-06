# 0047: i386 Direct3D 9 titles join the cohort, on Vulkan by default

**Status:** accepted, 2026-10-04. Extends [0005](0005-title-cohort.md)'s cohort
(x86-64 Direct3D 11 only) and [0044](0044-vulkan-default-for-dx12.md)'s
default backend; accepts the direction of the Portal 2 plan(../plans/finished.md#portal-2).

## Decision

- **Cohort.** i386 (PE32, machine `0x14c`) Direct3D 9 titles may join the
  cohort by 0005's scorecard. They run as WoW64 children of the session root
  through the plan's 4 GiB guest window (Wine's `wow64`/`wow64win`, FEX's
  `xtajit.dll` with inline `B + zext32(EA)` translation), and their Direct3D 9
  on DXVK's i686 `d3d9.dll` over Wine's i386 `winevulkan` and KosmicKrisp.
  Portal 2 (app 620) is the first.
- **Default backend.** With no per-game or global Direct3D choice, a title
  whose selected executable is i386 launches on Vulkan; x86-64 titles keep
  0044's rule (Vulkan for detected Direct3D 12, DXMT otherwise). Adoption
  reads the executable's COFF machine (`InstalledTitle.executableMachine`)
  on every scan. Launch arguments do not move an i386 title off Vulkan.
- **Precedence** stays 0044's: the game's own choice, then the global one,
  then detection. The game's page shows "Default · Vulkan" for an i386 title,
  and the player can still pick DXMT there.

## Why and limits

The machine is the robust test, not Direct3D 9 evidence. DXMT has no i386
build and no Direct3D 9, and wined3d would need a GL that iOS lacks, so for an
i386 title Vulkan is the only backend that can draw at all. Portal 2's
executable shows no Direct3D import (its renderer is `shaderapidx9.dll`, which
the engine loads by path), so 0046's static evidence would leave it unknown.
x86-64 Direct3D 9 titles keep DXMT's default: none has been tried, and
changing them is not needed for this cohort.

A global DXMT choice still wins over detection and would send an i386 title to
a backend that cannot run it; that is kept for consistency with 0044 rather
than special-cased. Older catalogues without the machine field default to DXMT
until the next scan, which runs on each app start.

Evidence: [milestone 2](../evidence/2026-10-04-portal2-d3d9-vulkan.md) (the
route and the menu at 60/120 FPS) and
[milestone 3](../evidence/2026-10-04-portal2-gameplay.md) (this default on the
phone, the pad and gameplay).
