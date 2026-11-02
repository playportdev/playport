# 0070: The runtime stages every Wine module it builds, as Proton ships them

**Status:** accepted, 2026-10-08, by the owner ("Proton parity, no census gate";
[PLA-78](https://linear.app/playportdev/issue/PLA-78)); the aarch64 companion set,
the 16-bit exclusion and the left-out programs are superseded by
[0071](0071-wine-modules-full-proton-set.md). Replaces the hand list of
Wine builtins beyond Madeira's reference bundle (`EXTRA_PE` in
`build/stages/stage-artifacts.py`) with a rule. Drops the owned-library PE census
that [the runtime DLL coverage plan](https://linear.app/playportdev/issue/PLA-78)
had made a gate for staging; the census, a runtime catalogue and the UI's warnings
stay optional later work. Keeps [0014](0014-vulkan-through-kosmickrisp.md) (the Vulkan
backend's own directory) and the Steam API emulator's directory.

## Decision

- **Selection is derived from the build's manifests.** For each architecture the
  production set is every `dlls/` and `programs/` entry of
  `build/generated/wine-pe-<arch>-windows.tsv` (the committed record of what the
  Wine PE build made), without `tests/`, 16-bit modules
  (`.dll16 .drv16 .exe16 .mod16 .vxd`: new WoW64 runs no 16-bit code) and the
  programs in `NOT_SHIPPED`. Proton's `lib/wine/<arch>-windows` is the same set
  (every built DLL, driver, `.sys`, `.cpl`, `.ocx`, `.acm`, `.ax`, `.tlb`, theme and
  program), so this is the parity the owner asked for. No name is pasted into a
  list; a new Wine module is staged by the build that makes it.
- **arm64ec (`system32`) and i386 (`syswow64`) take the whole production set.**
  The arm64ec build makes only eight programs (`cmd`, `dllhost`, `dpnsvr`,
  `dxdiag`, `msiexec`, `netsh`, `regsvr32`, `rundll32`, the ones that load DLLs
  of the guest's architecture); all are staged.
- **aarch64 stays the native companion set.** It is the WoW64 layer's native side
  (`sysarm64`, wine-pe 0015) and the home of the programs Wine builds only for
  aarch64, not a second copy of the guest's DLLs. It holds Madeira's reference set,
  `wow64.dll` and `wow64win.dll`, every built aarch64 program, and the normal and
  delay imports those reach (API-set contracts resolve through `apisetschema.dll`).
  An import that is neither built nor a replacement stops the stage. A full
  aarch64 set (about 500 more files) would serve no ARM64EC or WoW64 guest.
- **Programs are staged except four.** Proton ships every program, and
  installers and launchers call `msiexec`, `rundll32`, `regsvr32`, `cmd`, `reg`,
  `start` and the like. Left out: `winetest.exe` (Wine's install and Proton have
  none); `control.exe`, because mshtml, finding no Gecko, starts
  `control.exe appwiz.cpl install_gecko` and waits for it without a timeout, and
  the add-on download dialog would be a window the phone does not show (without
  `control.exe` the start fails and mshtml goes on without HTML rendering);
  `winedbg.exe`, which kernelbase starts for an unhandled exception: its crash
  dialog is another window the phone does not show, and in the first Portal 2
  play with it staged a crash went through it (`winedbg --auto`, "Program
  Error") instead of ending the title; without it a crashed title ends as before;
  `winemenubuilder.exe`, which writes host menu entries and which Proton also
  turns off.
- **Replacements take precedence over Wine's module of the same name**: FEX's
  `xtajit64.dll` (Wine builds one too) and `xtajit.dll`, the arm64ec `ntdll.dll`
  (provenance `P2-ec`), DXMT's `winemetal`, `d3d11`, `dxgi` and arm64ec
  `d3d10core` (`DXMT_PE`). The Vulkan backend's DXVK and vkd3d-proton stay under
  `Runtime/vulkan/` and the Steam API emulator under `Runtime/steamapi/`.
  Madeira's spelling of a name it shipped is kept (`Normaliz.dll`). The record
  stops when two rows name one destination in any case, so nothing overwrites a
  replacement. The `gap` rows are unchanged.
- **The registry seed follows the staged set.** `pp registry` registers every
  staged arm64ec module's `WINE_REGISTRY` scripts, as wineboot would. Nothing is
  loaded, downloaded or repaired at run time because of this change.

## Why

- Missing DLLs were found one failed play at a time (Witcher 3's `vcomp110`,
  Kingdom Come's `avifil32`, Jurassic World Evolution's `gdiplus`, an EOS sign-in's
  `cryptsp`, Valheim's `sspicli`), each a new IPA and phone run. A survey of the
  owned libraries found more (`twinapi.appcore`, `msvcp_win`, `sensapi`,
  `faultrep`, `evr`, `msvcp90`, ...). Proton's games expect the whole set.
- A census of every owned build would gate staging on store payload access that
  is not there; the files it would justify are already built and cost only space
  until loaded.
- i386 already took its whole DLL set (the WoW64 bring-up); the rule makes the
  three sets one policy.

## What it costs

- **Size.** +756 files, +502.4 MB (479.1 MiB) in the bundle, and the same in the
  IPA, which is stored, not deflated: the dev IPA went from 678.9 MB to
  1,181.4 MB, the release IPA likewise to 1,175.0 MB (evidence:
  [2026-10-08 Proton DLL parity](../evidence/2026-10-08-proton-dll-parity.md)).
  Deflated, the added files are about 48 MiB.
- **Registry.** The seed grows from 1,885 to 6,899 keys (176 to 589 CLSIDs, 65
  more WinRT activatable classes); no existing key or value changes. A
  `CoCreateInstance` that failed with `REGDB_E_CLASSNOTREG` now reaches Wine's
  implementation: WMI (`wbemprox`), DirectShow (`quartz`, `qedit`, `devenum`),
  mshtml without Gecko, scripting, MSXML, XACT and older XAudio2. BITS and WIA are
  registered as services, which the app never runs, so their creation fails.
- **Memory.** Files cost nothing until loaded, but a path that used to fail early
  can now load modules into the JIT pool. A title that regresses this way is a
  bug against this decision, not a reason to drop the module silently.
- **Unverified.** The aarch64-only programs (`reg`, `taskkill`, ...) had no run
  on the phone when this was written; their start in a session is not checked.
