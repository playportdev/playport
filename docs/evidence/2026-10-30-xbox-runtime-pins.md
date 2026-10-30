# The Xbox runtime pins: xgameruntime and nghttp2 built as ARM64EC DLLs

**Date:** 2026-10-30. **Kind:** a workstation build and host checks in a side copy
(decision [0117](../decisions/0117-side-copies-that-build.md)), dev variant. No phone run.
**Trees:** nexus-xgameruntime `ab2fac35b500b87fefe51add26a0672a71d11576` plus
`patches/xgameruntime` 0001; nghttp2 `85e300c79fb6dbcfa9c1013215c8710c1c2cd3d2` (tag
`v1.70.0`), unmodified. Built by `build/stages/xbox-pe.sh` with llvm-mingw 20260922
(clang 23.1.2) for `arm64ec-windows`.
**Plan:** [the Xbox plan](../plans/2026-10-30-xbox-game-pass.md), runtime track;
[PLA-493](https://linear.app/playportdev/issue/PLA-493).

## The pins

- **xgameruntime** is the commit the ground truth's runtime carried. The release
  `runtime-11.0-20261028-ge5afe21e` names it in its `XODUS_NEXUS_PATCH.json` source graph
  ([ground truth](2026-10-30-xbox-ground-truth-nexus.md)). It is on the fork's `main`, three
  commits before its head (`5539e7d`, the commit
  [LICENSING.md](../LICENSING.md#xbox-planned) was first read at). The licence facts were read
  again at the pin and hold.
- **nghttp2** is tag `v1.70.0`, the commit Nexus's runtime pins. It is built library only.

## Build

- **One patch was needed, for the Wine tree.** `cmake/Xml2.cmake` and `cmake/Winrt.cmake`
  check the Wine tree (`NEXUS_WINE_SOURCE`) file by file against sha256 locks that name
  ValveSoftware/wine `7fc704ef`. They also compile a fixed list of libxml2 sources.
  Playport's Wine tree (the pe stage's: the wine pin with its series) differs from Valve's:
  - `libs/xml2` has no `SAX.c`, and its `Makefile.in`, `SAX.c`, `include/libxml/tree.h` and
    `xpath.c` differ from the lock;
  - `include/` differs in `wtypes.idl`, `basetsd.h` and `guiddef.h`.

  So the configure step failed. `patches/xgameruntime` 0001 adds `NEXUS_WINE_SOURCE_LOCK`
  (default on, as upstream behaves), which the stage turns off. It also takes libxml2's
  sources from the tree's own `libs/xml2/Makefile.in`. libxml2's `COPYING` is the same in both
  trees.
- **ARM64EC needed no change.** With `-D_WIN32_WINNT=0x0A00`, both trees compile and link
  for `arm64ec-w64-mingw32` as they are. The only warnings were five copies of xgameruntime's
  `-Wextern-c-compat` in `xappcapture.h`; nghttp2 had none.
  - **xgameruntime** links its C++ runtime statically. It imports only system DLLs Wine
    ships: kernel32, the UCRT API sets, ole32, bcrypt, winhttp, crypt32, iphlpapi, ws2_32,
    the WinRT core API sets, shell32 and advapi32. It exports `QueryApiImpl`,
    `InitializeApiImpl(Ex, Ex2)`, `UninitializeApiImpl`, `XErrorReport`,
    `NexusRegisterCloudShutdown`, `XodusSaveFilesMonitor`, `DllGetActivationFactory` and
    `DllCanUnloadNow`.
  - **nghttp2** exports 181 functions.
  - Each DLL is stripped of DWARF and marked a Wine builtin. `llvm-readobj` reads both as
    `IMAGE_FILE_MACHINE_ARM64EC`, while the COFF header says x86-64, as for every ARM64EC image.
- **Outputs:**
  - `xgameruntime.dll`: 2,731,520 bytes, sha256 `996a9013…df657efd`;
  - `libnghttp2.dll`: 243,200 bytes, sha256 `55e0d50f…a7be98c`.

  The stage takes about 6 seconds (`pp build`'s xbox stage, 13:42:11 to 13:42:17).
- **Path-independent.** A first run of the same script with its root in another directory,
  before this build's `pe` stage ran, gave the same two sha256. The root, the Wine tree and
  llvm-mingw are all mapped with `-ffile-prefix-map`. The only paths left in
  `xgameruntime.dll` are llvm-mingw's own CI paths in libc++abi's assertion strings, which
  `verify-ipa`'s path check allows. So the two `app/artifacts.tsv` rows are committed.
  This build also rewrote other rows from the copy's own rebuilt trees: six i386 rows that
  depend on GStreamer, `libdxmt_combined.a` and `libidevice_ffi.a`. Those were not committed
  and keep main's values (0117).
- **Staging.** Both DLLs go into `Runtime/arm64ec-windows` with Wine's own set, under the
  provenance keys `P11-xgameruntime` and `P11-nghttp2`, in both variants. Wine's winhttp
  loads `libnghttp2.dll` from system32. The prefix registry seed check still passes:
  xgameruntime has no `WINE_REGISTRY` resource.

## Checks

- **`pp build`** (dev, in the side copy): every stage ran. The IPA is
  `Playport-26.5-40a13827.ipa`, sha256 `40a13827031e595e3e9862b9b5e4d33bb37cb2b6dd3e85a9ad0d22272a861676`.
  **`verify-ipa`: 92 checks passed, 0 failed.** That includes the three new `xbox` checks
  (rows, ARM64EC Wine builtins, exports); `pp verify` on the IPA reports 0 failures too.
- **Notices.** The app's `Licenses/` holds 783 files, and `components.json` covers every
  provenance key, the two new ones included. New in the collection:
  - xgameruntime's `LICENSE` and Nexus's MIT text (`tests/Nexus/LICENSE`);
  - the headers of `env.c` and `statics.h`;
  - libHttpClient's `LICENSE.md` (`build/notices-extra/`);
  - the headers of libxml2's `list.c`, `dict.c` and `timsort.h` from the Wine tree;
  - nghttp2's `COPYING` and the header of its `sfparse.c`.
- **Main untouched.** No entry under main's `.work` newer than the copy's marker names the
  copy. None of main's `run` and `cache` files newer than the marker contains the copy's
  path. Main's `inputs` and CEF inputs have no newer entry. Main's own build wrote its `run`
  meanwhile.

## Not run

- **Phone gates.** No title loads either DLL yet; the Xbox launch path comes with later
  tickets. The Hollow Knight (Steam) smoke for a runtime change waits until the branch moves
  to the main checkout.
- **Desktop.** No desktop run under Wine has loaded either DLL; that is the PLA-495 desktop proof.
