# 0170: A game's native ARM64 Windows client runs as a plain ARM64 child, with no FEX

**Status:** accepted, 2026-11-01, by the supervisor under the owner's delegation of all decisions
for the World of Warcraft work; proposed 2026-10-30 by the owner while planning it
([PLA-508](https://linear.app/playportdev/issue/PLA-508)). The condition it was proposed with is
met ([PLA-512](https://linear.app/playportdev/issue/PLA-512),
[evidence](../evidence/2026-10-30-native-arm64-child.md)): on IPA `2f36ea66` a plain ARM64 program
ran on the phone as a native ARM64 child with every check passing and its exit code back in the
app, a failing one ended as a failed play with the app usable, and Hollow Knight reached first
frame+10; the `d3d12` program drew through the aarch64 vkd3d-proton set on IPA `9ee99874`
([PLA-518](https://linear.app/playportdev/issue/PLA-518)). It amends
[0082](0082-system32-programs.md) ("an x86-64 process cannot start a pure ARM64 one here") and
`ARCHITECTURE.md`'s "All guests are x86". Amended by
[0176](0176-native-arm64-images-live-in-the-jit-pool.md): the child's images live in the JIT pool,
whose copy is the module's base. World of Warcraft's own client does not reach its login yet
([PLA-514](https://linear.app/playportdev/issue/PLA-514),
[evidence](../evidence/2026-10-31-wow-arm64-start.md)).

**Amended 2026-11-01 by [0177](0177-wow-plays-its-x64-client-through-fex.md):** World of Warcraft plays its x64 client through FEX; the native ARM64 child stays for other native ARM64 programs and Playport's probes, and "where a game ships an ARM64 client, Playport runs that client only" no longer applies to WoW.

## Decision

- **Native ARM64 games come into scope,** starting with World of Warcraft's `Wow*-ARM64.exe`.
  Where a game ships an ARM64 client, Playport runs that client only: no x86-64 fallback.
- **The session root starts it as a native ARM64 child:** a pseudo-process on Wine's aarch64 set
  (`sysarm64`), with its own aarch64 ntdll and no WoW64 window and no FEX.
- **Two Wine trees stay** (arm64ec, and i386 with aarch64). Wine is not built ARM64X.
- **Its Direct3D 12 is vkd3d-proton built for aarch64,** with an aarch64 `vulkan-1.dll`, on
  Wine's aarch64 `winevulkan` and KosmicKrisp. Its `dxgi.dll` is DXVK's, built for aarch64
  ([PLA-513](https://linear.app/playportdev/issue/PLA-513)): the arm64ec Vulkan backend already
  pairs vkd3d-proton with DXVK's `dxgi`, whose adapters are Vulkan devices on the same
  `winevulkan`; the aarch64 `dxgi.dll` Playport already shipped is DXMT's, whose adapters are
  Metal devices for DXMT's `d3d11`, over Wine's wined3d one. The set lives under
  `Runtime/vulkan/aarch64-windows` and `Runtime/vulkan-loader/aarch64-windows`, linked over
  `sysarm64` by a Vulkan launch, so other plays keep DXMT's and Wine's aarch64 DLLs.

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
