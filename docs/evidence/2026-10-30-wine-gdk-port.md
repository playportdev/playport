# patches/wine-gdk: Xodus's and Xodus Nexus's Wine patches ported (PLA-494)

**Date:** 2026-10-30. **Linear:** [PLA-494](https://linear.app/playportdev/issue/PLA-494).
**Kind:** source port, workstation. No phone run.

## Sources

- Xodus Nexus's Wine fork `domsvoboda/nexus-wine` at `71bbdadab0cca92965e0f2fa17146030757b51ee`,
  the commit the ground-truth runtime (`runtime-11.0-20261028-ge5afe21e`) was built from
  ([ground truth](2026-10-30-xbox-ground-truth-nexus.md)). Its commits over Valve's `proton_11.0`
  carry `Nexus-Migration-Patch:` (Xodus Nexus v0.4.1 `assets/wine-*.patch`) or
  `Upstream-Source:` (xodus-gaming/wine) lines; each wine-gdk patch names its original in
  `Ported-from:`.
- Base: the `wine` pin (WineHQ 11.20, `7298a818`) plus `patches/wine-port`, `wine-valve` and
  `wine-pe`. Every hunk was compared with that base, not cherry-picked.

## What became which patch

| Patch | From | Port |
| --- | --- | --- |
| 0001 windows.web JsonArray Size/Append | xodus-gaming/wine 83aba5c4 (Olivia Ryan) | clean. The other 13 windows.web JSON commits are already in WineHQ at the pin (b3c2cc15 … eb0fffa7): nothing to port |
| 0002 windows.ui.core.textinput edit context, TryShow/TryHide | xodus-gaming/wine f7331a3e (ChristopherHX) | adapted: WineHQ has the CoreTextServicesManager, input-view stubs and the IDL (Alistair Leslie-Hughes); only the edit context and the Try* successes remain |
| 0003 advapi32 CredEnumerateW host ERROR_NOT_FOUND | same | adapted: the fix without the added traces of credential names |
| 0004 winhttp HTTP/2 through nghttp2 | nexus-wine e2789976 (domsvoboda) | adapted to WineHQ's read_buffer/data-stream reading and request states; h2 offered only when libnghttp2.dll loads; origin-form :path through a proxy |
| 0005 winhttp body diagnostics never opened | nexus-wine a58b93d3 | clean |
| 0006 winhttp IPv6 fast fallback (request), WebSocket close timeout | nexus-wine 8aa7f701 | adapted: WineHQ has the session option; WebSocket code is in socket.c |
| 0007 mscoree Mono path bound | nexus-wine 793332fe | clean |
| 0008 twinapi.appcore app-state registration | nexus-wine 9064d380 (domsvoboda, Gustavo Rosa) | clean |
| 0009 kernelbase package identity from AppxManifest.xml | nexus-wine 873e6a63 | adapted: SHA-256 from SymCrypt (WineHQ dropped libtomcrypt). The ground truth's runtime lists `appmodel-package-identity-v1` and ships its own kernelbase.dll |

## Found upstream or left out

- Response options and decompression (Nexus `wine-winhttp-response-options.patch`,
  nexus-wine ca7c4974 and Xodus's DECOMPRESSION stub 9eeb99f3): backports of WineHQ 335ae423
  (decompression) and the SERVER_CERT_CHAIN_CONTEXT commits, all in the pin.
- Data transfer (DataTransferManager, IDataTransferManagerInterop): in WineHQ (dde4e7e6).
- wintypes IsMethodPresent: WineHQ answers S_OK/FALSE, which the patch's crash note asks for.
- devices.enumeration CreateFromIdAsync: returns the first device for any id; left out.
- Not asked for by the ticket: the memory-file loader (a04cd2cc) and AF_UNIX (excluded), HLSL
  state keywords (vkd3d), concrt140, bcrypt ECDSA sizes, ApplicationData folders, WinRT
  IPackageId, the StoreContext wine.inf registration, the xgameruntime submodule.

## Open

- HTTP/2 is on by default for every session (as in Nexus), so every title's WinHTTP over TLS
  uses h2 wherever libnghttp2.dll is staged.
- No run exercised the patches: the desktop proof and the Hollow Knight (Steam) phone smoke are
  unrun.
