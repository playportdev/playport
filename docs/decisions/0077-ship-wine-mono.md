# 0077: Playport ships Wine Mono, as Proton does

**Status:** accepted, 2026-10-11, by the supervisor of the compatibility speedrun with the
owner away; the owner decided on 2026-10-09 that Wine Mono ships
([compatibility speedrun plan](https://linear.app/playportdev/issue/PLA-633), "Settled");
[PLA-125](https://linear.app/playportdev/issue/PLA-125). Settles the Mono half of
[0071](0071-wine-modules-full-proton-set.md)'s "until Gecko/Mono are decided".
Amended by [0085](0085-dotnet-framework-directories.md): the prefix gets the support package's
.NET Framework directories as links, and a WoW64 process's `mscoree` reads the 32-bit
`InstallRoot`.

## Context

Wine's `mscoree` runs .NET programs on Wine Mono, which Wine does not build: Proton ships
WineHQ's release in `share/wine/mono/wine-mono-<version>`, and a wineboot'ed prefix gets the
release's support package (`winemono-support.msi`), whose registry says which .NET Framework
versions are installed. The app had neither, so every .NET or XNA program failed, and
installers that check for .NET planned to download it: House of Golf 2's prerequisite
installer (WiX Burn) read no `SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full`, planned
`NetFx40Redist`, failed the download and exited `0x2`
([evidence](../evidence/2026-10-09-uepre-winsxs-sent-text.md), PLA-113).

## Decision

- **The release the wine pin expects, unmodified, laid out as Proton's.** pins.lock's
  `wine-mono` row names WineHQ's release that the wine pin's `mscoree` asks for
  (`WINE_MONO_VERSION`, 11.3.0 at `wine-11.19`); it moves with the wine pin.
  `build/stages/wine-mono.sh` fetches the shared-directory tarball
  (`wine-mono-<version>-x86.tar.xz`) and the source release, each checked against its
  sha256 in the script, and `build/stages/stage-artifacts.py` stages every file as
  `Runtime/mono/wine-mono-<version>/…` (provenance `wine-mono`). A symbolic link (the
  framework directories' links into the GAC) is staged as a copy of its target, as an IPA
  holds no links. Nothing is left out, the reference assemblies (`lib/mono/*-api`, 98 MiB)
  included: the tree is the one Proton ships.
- **mscoree finds it without a change.** The runtime is at the app root, which ntdll gives
  every process as `WINEDATADIR`, and the prefix's `z:` is `/`, so `mscoree`'s
  `get_mono_path_datadir` finds `<WINEDATADIR>\mono\wine-mono-<version>`, the same lookup
  Proton's layout uses. No patch, no registry path to the bundle (which moves on each
  install), no install step.
- **The support package's registry is in the prefix seed, not installed.**
  `app/tools/prefix-registry.py` `WINE_MONO` carries the keys and values the release's
  `winemono-support.msi` writes (read from a desktop prefix after `msiexec /i` of it): `NDP`
  v1.1 to v4 (`v4\Full` `Install`=1, `Release` 0x82348), `.NETFramework` `InstallRoot` and
  policy, Active Setup's .NET components, XNA Framework 4.0 and the `CorSymWriter` class.
  They are marked for top-up, so an existing prefix gets them at its next launch, as every
  seed change does. Left out: the package's Windows Installer bookkeeping and uninstall
  entry, the fake `C:\windows\Microsoft.NET\Framework*` files its `dotnetfakedlls.inf`
  writes, and the 32-bit view: as the rest of the seed, only the 64-bit view, which an i386
  caller reads while the prefix has no `Software\Wow6432Node` (checked on the phone's
  prefix); seeding that key would hide every other `HKLM\Software` key from i386 callers.
- **control.exe stays disabled** (0071): `mshtml` still starts `appwiz.cpl install_gecko`
  and waits; `mscoree` no longer has a reason to.
- **Licensing.** The source release is the Corresponding Source (`build/source-bundle.json`)
  and the notices' source: `build/notices-wine-mono.py` carries every licence, copying,
  notice, patents and third-party file of it into the app's Licenses/ (a superset, as
  accepted for other parts), checked against the locked sha256
  ([LICENSING.md](../LICENSING.md), [NOTICES.md](../NOTICES.md)).

## Why

Proton parity is the speedrun's target: a .NET, XNA or MonoGame title, or an installer
that checks .NET, should get here what it gets under desktop Proton. Taking WineHQ's build
of the exact version the Wine pin expects avoids building Mono, and the shared directory
needs no install step in a prefix the app never boots with wineboot. Mono's x86 code runs
under FEX like a game's.

## Costs and limits

- **Size:** +2,946 files, +276.6 MiB unpacked (226 MiB the tree, 60 MiB the link copies), and
  the dev IPA from 287.4 MB to 394.6 MB (+107.2 MB deflated). The reference assemblies and
  the link copies are where a later saving would come from.
- **i386 .NET programs do not start yet:** an i386 IL-only exe fails in Playport's WoW64
  main-image mapping (`virtual_map_main_module = 0xc00000bb`, `error 50`), before Mono is
  involved; x86-64 .NET programs run. XNA 4 titles are i386, so they wait for that fix.
- No fake Framework directories: a program that checks for `mscorlib.dll` in
  `C:\windows\Microsoft.NET\Framework*\v4.0.30319` as a file still finds none.
- Start-up: no measurable change for Hollow Knight or Portal 2 (first frame +8.73 s and
  +5.75 s, against +8.84 s and +5.78 s on the IPA before).
