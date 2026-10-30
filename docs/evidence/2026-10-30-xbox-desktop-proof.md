# Xbox desktop proof: Playport's Wine and runtime start the pilot against Nexus's backend

**Date:** 2026-10-30. **Linear:** [PLA-495](https://linear.app/playportdev/issue/PLA-495).
**Kind:** desktop runs on the workstation in a side copy (decision
[0117](../decisions/0117-side-copies-that-build.md)), headless sway session. No phone run.
**Plan:** [the Xbox plan](../plans/2026-10-30-xbox-game-pass.md), runtime track.

## Result

**Passed.** Hollow Knight: Voidheart Edition (`9MW9469V91LM`, version 1.5.12620.0), the
pilot Xodus Nexus installed for the [ground truth](2026-10-30-xbox-ground-truth-nexus.md),
reached its main menu (Start Game, Options, Extras, Quit Game). The account's Xbox gamerpic
and gamertag were in the top right corner, which shows the in-game Xbox sign-in. It ran on
Playport's Wine with Playport's `xgameruntime` and nghttp2, all built for x86-64. Nexus's own
backend (`xodus-cli run` and `xodus-service`) did the licence and decryption, and answered
the runtime over Nexus's TCP bridge. The runtime's device, SISU and XSTS steps all
succeeded. The screenshots are kept out of the repo because they show the gamertag.

## What ran

| Part | What |
| --- | --- |
| Wine tree | the `wine` pin `7298a818` with `patches/wine-port` (57), `wine-valve` (131), `wine-pe` (52) and `wine-gdk` (9): 249 commits, head `0e7e7d17cb6`. Every wine-gdk commit has the same `git patch-id` as `patches/wine-gdk` at the integration head `20135b0`. It is the tree PLA-494 applied, reflink-copied |
| Desktop-only change | one commit on top (`cb3990e4b66`, not in any series; below) |
| Wine build | `configure --enable-archs=x86_64 --disable-tests` on x86_64-linux-gnu (gcc 16.2.1, `-O2`). The PE side was built with llvm-mingw 20260922 (clang 23.1.2), with `CROSSCFLAGS -I` pointing at PLA-494's nghttp2 headers. `wine --version`: `wine-11.18-944-g0e7e7d17cb6` |
| xgameruntime | `ab2fac35` with `patches/xgameruntime` 0001. Built with `build/stages/xbox-pe.sh`'s cmake, flags and `winebuild --builtin`, `ARCH=x86_64`, against the desktop tree's `widl` and sources. `xgameruntime.dll` is 2,479,616 B, sha256 `40b34958…9055c2` |
| nghttp2 | `85e300c7` (v1.70.0), library only, the same way. `libnghttp2.dll` is 188,928 B, sha256 `bed5a30c…973821` |
| Install | both DLLs went into the Wine tree's `lib/wine/x86_64-windows`, so wineboot put them in `system32`. winhttp is builtin by default. No `winhttp=b` or `libnghttp2=n` override was set |
| Graphics | DXVK v3.1.1-97-ga78a467c, copied from Nexus's runtime into the prefix with `dxgi,d3d11,d3d10core,d3d9=n`. Graphics is not under test; D3D11 FL 11_1 on RADV (RX 9070) |
| Backend | Xodus Nexus v0.4.1 (unmodified), backend 0.2.13, already signed in. These are the ground truth's scratch, keyring and installed pilot |
| Launch | Nexus's Settings → "Wine / Proton" path was set to a wrapper in the desktop tree's `bin/`. Beside it was an `XODUS_NEXUS_PATCH.json` listing `cloud-saves-pr28` and `xodus-tcp-bridge-v1`, the features Nexus checks before it starts its account service and TCP bridge. Nexus then ran `xodus-cli run <game> <wrapper> --exe "Hollow Knight.exe" --materialize-chain`. The wrapper sets `WINEPREFIX` (our own prefix), `WINE_WINHTTP_HTTP2=1` and the DXVK overrides, then execs our `wine`. `xodus-cli` wrote the two decrypted exes into its launch view (`.xodus-chain-*`, removed at exit) and started the game from there. Our Wine has no memory-file loader, but this pilot needs none: its DLLs are plaintext and the launch view links them |
| Capture | the ground truth's mitmproxy (Wine through `http_proxy`, CA in the prefix's ROOT store) and its bridge tap (frame kinds and the three non-secret request fields only) |

## Runs

| Run (CET) | Prefix registry | Result |
| --- | --- | --- |
| 1, 15:05 | PLA-499's keys, scratch CA | Rendered the language picker. Xbox sign-in failed: `init-default` hr `0x80072F7D` (ERROR_WINHTTP_SECURE_FAILURE) on every attempt. Cause: the scratch CA was gone from ROOT (below) |
| 2, 15:10 | the same, CA imported again | Sign-in succeeded (below). Stopped at the language picker, because the headless seat takes no input |
| 3, 15:14 | the same plus the pilot's language choice | **Main menu with the gamertag and gamerpic.** Stopped by Nexus's Stop after 2 min |
| 4, 15:16 | PLA-499's keys **removed** | The same as run 3: main menu with the gamertag, the same sign-in phases and calls |

The runtime's sign-in phases in runs 2 to 4 (`XUSER_AUTH_METADATA_LOG`: phases, HRESULTs and
HTTP status only):

- `init-default` 0;
- `init-tickets` 0 (in run 2, the first attempt was `0x80004005` and the retry 3 s later
  succeeded; see the bridge below);
- `init-device` 0;
- `sisu` 0 with device, user and title tokens present;
- `init-current` 0, then `init-complete` 0;
- three `xsts` calls at HTTP 200, then `get-token-complete` 0.

The store metadata log has four Store API calls, all `hr=0`. Three come from the game's
`XGamingRuntimeThunks.dll`, `Microsoft.Xbox.Services.141.GDK.C.Thunks.dll` and `XCurl.dll`;
api 20 also comes from the thunks.

## What needed registering

- **Nothing, for this pilot.** Run 4 had neither PLA-499 key in the prefix and still reached
  the menu with sign-in. Those keys are `HKLM\Software\Microsoft\GamingServices`
  CurrentVersion/AvailableVersion `38.117.27001.0` (REG_QWORD) and the
  `Windows.Services.Store.StoreContext` → `xgameruntime.dll` class, both views. They are
  still Nexus's set, written every launch, and cost nothing.
- **Windows.Data.Json:** WineHQ's own registration covers `JsonArray`, `JsonObject` and
  `JsonValue` → `windows.web.dll`. A fresh prefix has them, and so does Playport's
  `app/registry/system.reg`.
- **AppState:** nothing to register; wine-gdk 0008 is exports in `twinapi.appcore`.
- **Compared with Nexus's prefix:** its WinRT class list (`ActivatableClassId`, 75 classes)
  differs from ours only by `StoreContext`. Ours has four more WineHQ classes.
- **Run-only items, not runtime needs:**
  - The scratch CA, so that mitmproxy could see Wine's traffic.
  - HK's `GameLangSet`/`M2H_lastLanguage` PlayerPrefs (HKCU `Software\Team Cherry\Hollow
    Knight`), so that the headless run skipped the language picker. The values were copied
    from the ground truth's prefix.

## The ROOT store purge (run 1)

The scratch CA was imported into `HKLM\...\SystemCertificates\Root` right after wineboot.
At that point crypt32 had not yet synced the host roots, so
`HKLM\Software\Wine\HostImportedCertificates` did not exist. On its first sync, crypt32
treats a missing key as "every cached root came from an older Wine's host import". It marks
them all as imported, then deletes the ones the host does not have, and the CA was one of
them.

The probe proved it. A WinHTTP GET to `title.mgt` through the proxy (an x86-64 probe built
with llvm-mingw) failed with chain status `PARTIAL_CHAIN` and error 12045. Imported again
after that first sync, the CA stayed, and the probe got `200` over HTTP/2.

This is WineHQ behaviour, not wine-gdk's. Any root seeded into a prefix before the first
sync has to be seeded after it, or listed as not imported.

## Bridge (runs 2 to 4, same as Nexus's own runtime)

- One connection opened and closed with no frames. This is the launcher's readiness probe.
- Then one `MSA_TOKEN_REQUEST` (type 3) per launch, with `ClientId` `000000004823914A` (the
  pilot's `MSAAppId`), `AllowUi` true and `MSAFullTrust` false.
- The reply is `MSA_TOKEN_RESPONSE` with `Token`, `Expiry`, `DeviceRps`, `DeviceExpiry`,
  `XboxMsaAccountId` and `StoreMsaAccountId`.
- There were no Store licence or package-update requests.
- In run 2, two more empty connections came before the request. They line up with the first
  `init-tickets` E_FAIL and its retry. Nexus's ground-truth run 2 shows the same pattern with
  Nexus's runtime.

## Hosts (Wine's traffic, run 3; run 4 identical)

| Host | Calls | HTTP |
| --- | --- | --- |
| title.mgt.xboxlive.com | `titles/default/endpoints`, `titles/current/endpoints` | 2, 200 |
| device.auth.xboxlive.com | `device/authenticate` | 2, 200 |
| sisu.xboxlive.com | `authorize` | 2, 200 |
| xsts.auth.xboxlive.com | `xsts/authorize` ×3 | 2, 200 |
| profile.xboxlive.com | `users/me/profile/settings` | 2, 200 |
| images-eds-ssl.xboxlive.com | gamerpic `image` | 1.1, 200 |
| titlestorage.xboxlive.com | blob list (JSON), `save1,savedgame` (69 B) | 2, 200 |
| titlestorage.xboxlive.com | `<guid>,binary` | **1.0, 400** text/html |

Every Xbox Live call except the gamerpic went over HTTP/2, through `WINE_WINHTTP_HTTP2=1`
and wine-gdk 0004 with our `libnghttp2.dll`.

## Desktop-only change (not for the phone)

`patches/wine-port` (Madeira's iOS layer) uses Darwin calls in `dlls/ntdll/unix/sync.c`
without a guard: `mach_absolute_time`, `mach_timebase_info`, the QoS classes,
`pthread_set_qos_class_self_np`, and an arm64 `yield` in a spin loop. The Linux build stops
there. That file was the only unix-side compile failure in the whole tree.

The scratch commit `cb3990e4b66` adds a `#ifndef __APPLE__` block: monotonic-nanosecond
`mach_*` stand-ins, a no-op QoS and `pause` on x86. It also guards the second
`<mach/mach_time.h>` include. The phone build is unchanged, so no series changed.

The PE side's iOS diagnostics (`[ndr-shift]`, `[alert-storm]`, `alloc_thread_tls` lines on
`err`) are loud in the game log but harmless. Without `winemac.drv`, the display driver
falls back to x11 by WineHQ's default list.

## Fixes

- **Needed in wine-gdk or xgameruntime:** none. Both series built for x86_64 unchanged.
- **Desktop-only:** the sync.c guard above.

## Open

- **titlestorage `<guid>,binary` GET** went out as HTTP/1.0 and got 400 text/html, in every
  run with sign-in. The ground truth saw an HTTP/1.0 400 on one titlestorage lock with
  Nexus's own runtime. Both runs went through mitmproxy, so the proxy may be the cause.
  Cloud-save download is PLA-500's; it does not block the menu.
- The phone (ARM64EC) run is PLA-499's.
