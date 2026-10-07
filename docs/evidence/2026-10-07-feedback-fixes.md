# Feedback fixes from the 0.3.x reports: iOS 26.0 libc++, Report a problem's zip, Steam demos

**Date:** 2026-10-07. **Branch:** `feedback/2026-10-07`. **Linear:** PLA-5, PLA-21, PLA-19, PLA-18.
**Phone:** iPhone18,4, iOS 27.0, dev build, IPA sha256
`3b50fcb336041034a0c19aff1ed98314fad01c9e4cf65ae8782cce089e5f5620` (head `4e66f29`).

## PLA-5: dyld refuses the app on iOS 26.0 (`std::__1::__hash_memory`)

0.3.3 dies at launch on iOS 26.0.1: `Symbol not found: __ZNSt3__113__hash_memoryEPKvm`,
expected in `/usr/lib/libc++.1.dylib`.

- **Which binary.** `llvm-nm -u` over every Mach-O of the `296886d4` IPA: only the app
  executable imports it. In `app/Staged/lib` it comes from `libdxmt_combined.a` alone: 20 objects,
  airconv (`air_signature.o`) and DXMT's static LLVM 15 (`CodeViewDebug`, `DwarfDebug`,
  `DbgEntityHistoryCalculator`, …).
- **Why.** The host clang (22.1.8, Arch) searches its own `../include/c++/v1` before the
  sysroot's, so those iOS objects took Arch's libc++ 22 headers. Their `__config_site` has
  `_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS 0`, so `_LIBCPP_AVAILABILITY_HAS_HASH_MEMORY` is
  on and `std::hash<std::string>` calls the exported `__hash_memory` (libc++ 21) instead of the
  inline `__murmur2_or_cityhash`. The SDK 26.5 `.tbd` exports it, so the link passes. A
  one-line probe (`std::hash<std::string>`, `--target=arm64-apple-ios18.0`) imports it with the
  default search path and does not with `-stdlib++-isystem $SDK/usr/include/c++/v1`.
- **Fix.** `dxmt-base.sh` (the unix slice), `dxmt-combined.sh` (LLVM iOS, in a new
  `llvm-ios-15.0.7-sdkcxx` cache directory) and `mesa.sh` pass the SDK's libc++ headers to every
  iOS C++ compile. `verify-ipa.py` gained a `libc++` check: no Mach-O imports a symbol in
  `LIBCXX_NEWER_THAN_MINOS`. Against the `296886d4` IPA it fails, naming `S1Probe`.
- **Result.** The rebuilt `libdxmt_combined.a` is `a10f3c5b7a1d8f61` (114,658,552 B, from
  115,503,632). `pp verify`: 80 checks, the new one passing; `llvm-nm -u` finds no
  `__hash_memory` in any of the IPA's four Mach-Os.

**Not shown:** a launch on iOS 26.0.x. Our phone runs iOS 27.0, where the symbol exists either
way; the check above shows dyld would no longer need it. The iOS 26.0 reporter's launch would
confirm it.

## The build on the phone (Hollow Knight, app-367520)

| run | Direct3D | JIT | first frame | result |
| --- | --- | --- | --- | --- |
| `ui-runs/20261007T102850` | default (Vulkan) | 2.19 s | +7.96 s | ran to first-frame+10 |
| `ui-runs/20261007T102945` | Vulkan | 2.39 s | +8.92 s | ran to first-frame+10 |
| `ui-runs/20261007T103039` | DXMT | 2.42 s | +8.98 s | ran to first-frame+10 |

The DXMT run is the one that runs the rebuilt airconv (its shaders go through it). The stop
screenshots are black: Hollow Knight's opening fades from black at that point.

## PLA-21: Report a problem shares one zip

`ui-runs/20261007T103222`: Game options shows *Report a problem · Shares a zip of the logs*;
pressing it logs `report a problem for app-367520: sharing s1-host.log, hollow_knight-player.log,
rpm-poison.log as Playport-report-app-367520-20261007-103304.zip`, and the share sheet offers that
one file, *ZIP Archive · 3 KB*.

The blocking `NSFileCoordinator.coordinate(readingItemAt:options:error:byAccessor:)` first used
made `pp verify`'s paths check fail: Swift's escape check for its non-escaping ObjC block embeds
the source file's full path, which `-file-prefix-map` does not map. The queue form,
`coordinate(with:queue:byAccessor:)`, has none.

## Not checked on the phone

- **PLA-19, Steam demos in the Library:** `SteamGame.games` keeps `type: Demo` next to `Game`
  (a unit test); the test account's library was not looked at for a demo.
- **PLA-18:** the pairing step's new wording shows only on an unpaired phone; the test phone is
  paired.
