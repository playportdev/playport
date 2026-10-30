# 0170: A game's native ARM64 Windows client runs as a plain ARM64 child, with no FEX

**Status:** proposed, 2026-10-30, by the owner while planning World of Warcraft
([PLA-508](https://linear.app/playportdev/issue/PLA-508)). Accepted after a native ARM64 child
runs on the phone and Hollow Knight still reaches first frame+10
([PLA-512](https://linear.app/playportdev/issue/PLA-512)). When accepted, it amends
[0082](0082-system32-programs.md) ("an x86-64 process cannot start a pure ARM64 one here") and
`ARCHITECTURE.md`'s "All guests are x86".

## Decision

- **Native ARM64 games come into scope,** starting with World of Warcraft's `Wow*-ARM64.exe`.
  Where a game ships an ARM64 client, Playport runs that client only: no x86-64 fallback.
- **The session root starts it as a native ARM64 child:** a pseudo-process on Wine's aarch64 set
  (`sysarm64`), with its own aarch64 ntdll and no WoW64 window and no FEX.
- **Two Wine trees stay** (arm64ec, and i386 with aarch64). Wine is not built ARM64X.
- **Its Direct3D 12 is vkd3d-proton built for aarch64,** with an aarch64 `vulkan-1.dll`, on
  Wine's aarch64 `winevulkan` and KosmicKrisp.

## Why

- WoW's minimum CPU (6 cores at 4 GHz) is far beyond what FEX's translation leaves on the phone;
  its ARM64 client skips translation entirely.
- Playport already ships Wine's whole aarch64 set and runs aarch64 images (`wow64.dll`,
  `xtajit.dll`) from the JIT pool with x18 patching; the missing part is the loader starting such a
  process.
- The ARM64X layout would rebuild what 0071 and 0082 rest on, with the iOS loader forks untested
  against it.

## Costs

- A Blizzard build whose ARM64 client fails leaves the game unplayable on Playport until a later
  build; there is no fallback.
- Code a game generates at run time (Warden) runs through the fault-emulated anonymous executable
  path; its cost is unmeasured.
- The workstation is x86-64, so the ARM64 client can only be tried on the phone.
- A second vkd3d-proton build to keep in step.
