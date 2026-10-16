# Stock CEF in place of Social Club's CEF, under desktop Proton

**Date:** 2026-10-16 (09:30–10:00). **Branch:** `dev/pla-291-rockstar-launcher` (from `6832893`).
**Linear:** [PLA-369](https://linear.app/playportdev/issue/PLA-369). **Plan:**
[publisher launchers](../plans/2026-10-12-launchers.md), Rockstar track.

Host only: no phone, no build, no sign-in, no game. The owner approved the test. Rockstar's binaries
were not analysed: only libcef.dll's version resource was read, and runtime behaviour and the
launcher's logs were observed. Sources are marked **[M]** measured here, **[I]** inference.

## Question

Can a stock, open-source CEF distribution of the same version stand in for the CEF that ships with
Social Club, so that the launcher UI renders? If it can, a custom low-address-space build of that
version (route 1, a separate owner decision) is worth costing. If it cannot, that route is closed.

## Answer

**Yes [M].** With Spotify's stock CEF 143.0.14 files in place of Social Club's, the launcher
started the same 9-process CEF tree and reached the sign-in page. Its log shows no error,
the same state sequence as with the original files, and no integrity or signature refusal.
The files were still the stock ones after the run. The reservation pattern is the same with either
build, so a library rebuilt from the same CEF source with smaller reservations is a drop-in
candidate [I].

## Setup

- Proton 10.0-4b (`proton run`); windows on sway (`DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-1`, set per
  command). `lsteamclient`/`steamclient`/`steamclient64` disabled, `STEAM_COMPAT_CLIENT_INSTALL_PATH`
  an empty directory and `TMPDIR` under `$PLAYPORT_BUILD`, and URL opens blocked. A guard stops the
  run if a prefix process connects to the owner's Steam client. `Launcher.exe` was started
  standalone, with no wrapper or extra switches. Stage R's runner was used, with a separate prefix
  and a trace filter (`$PLAYPORT_BUILD/agent-notes/pla254-rockstar/prun2.py`, `vfilter.py`, `vana.py`).
- `WINEDEBUG=+pid,+virtual,+process,+loaddll`. The filter keeps only allocations of 1 GiB or more,
  the view each one made, and frees of those views.
- The swap and control runs used a copy of Stage R's prefix (`prefix-swap/`). Stage R's own prefix was
  not changed (its `libcef.dll` hash was checked after the runs).

## Version and files

| Item | Value |
| --- | --- |
| Social Club `libcef.dll` version resource | `143.0.14+gdd46a37+chromium-143.0.7499.193` (249,338,488 B, sha256 `c6ee879d42c8ed86f870c53407962df5de4e1eaf3e7e673da32f7f080c69486a`) |
| Social Club `chrome_elf.dll` | 143.0.7499.193, sha256 `b46223f386643ba5cfe3152c5fa2bdd535e3b2d80e25e82073131889d8834a4e` |
| Stock standard distribution | `cef_binary_143.0.14+gdd46a37+chromium-143.0.7499.193_windows64.tar.bz2`, 318,440,603 B, sha1 `4912e99b3522500d38f075150095a7a786c35f3b` (matches `index.json`), sha256 `0fa946d0f3834165632483fa3a3c2744aaa2d69862697953766293100d2d8b1d` |
| Stock client distribution (for `cefclient.exe`) | `…_windows64_client.tar.bz2`, 148,748,504 B, sha1 `7397f51ed560be39d0fb52a78c9ae6aa4a6e727f` (matches), sha256 `8d3b38eb8fa36cbbd32de8b85dd63e246a1d1cab7086e1c988d3fe1f5941ae7a`; its `libcef.dll` is byte-identical to the standard one |
| Stock `libcef.dll` | 249,330,176 B, sha256 `18319c4ce85018649b71574bf1f312be06f5850ad7049da0fd5dc5c2480ab392` |
| Stock `chrome_elf.dll` | sha256 `bc81fc3f9e18da8a506336f9bb3270f4869bbd201a8a4f847e87c38cf3cb4037` |

Compared with Social Club's files [M]:

- `v8_context_snapshot.bin`, `icudtl.dat`, both `chrome_*_percent.pak`, `vk_swiftshader_icd.json` and
  all 55 base locale `.pak` files are byte-identical.
- `resources.pak` differs (12,525,357 B against 12,525,247 B).
- Every DLL differs throughout its content, not only in an appended signature. Social Club's are
  Rockstar's own build of the same CEF version.
- The stock locales directory adds the `_FEMININE`/`_MASCULINE`/`_NEUTER` variants (220 files).

Files swapped in: all of the standard distribution's `Release/` set except `bootstrap*.exe` and
`libcef.lib` (`libcef.dll`, `chrome_elf.dll`, `libEGL.dll`, `libGLESv2.dll`, `d3dcompiler_47.dll`,
`dxcompiler.dll`, `dxil.dll`, `vk_swiftshader.dll`, `vk_swiftshader_icd.json`, `vulkan-1.dll`,
`v8_context_snapshot.bin`), plus all of `Resources/` (the paks, `icudtl.dat`, `locales/`).
`SocialClubHelper.exe`, `socialclub.dll` and Rockstar's other files were left in place.

## Stock cefclient's reservations

The stock `cefclient.exe` in its own scratch prefix, with decision 0109's switches (`--in-process-gpu
--disable-gpu --disable-gpu-compositing --js-flags=--jitless`, plus `--no-sandbox`) and a `data:`
URL, rendered its window and page [M]. Screenshot `runs/cef-client1/shot-0045.png`: the cefclient
window with its toolbar, and the page heading "PLA-369 stock CEF 143.0.14".

Reservations of 1 GiB or more, per process type, from two runs (`cef-client2`, `cef-client3`) [M]. "Align" is the
largest power of two dividing the address. Wine's trace does not name the calling DLL; "load point"
is the last native module loaded in that process before the call. A module's `DllMain` runs after
its imports load, so a reservation shown after `libcef.dll` can come from `chrome_elf.dll`'s
initialisation (chunk 9 placed the phone's failing pool reservation there).

| Process (`--type=`) | Reservation | Count | Align | Load point | Fate |
| --- | --- | --- | --- | --- | --- |
| every process | 32 GiB `MEM_RESERVE`, requested at a 32 GiB-aligned address | 2 | ≥ 32 GiB | after `libcef.dll` | kept |
| every process | 16 GiB `MEM_RESERVE`, unaligned (64 KiB) | 2 | 64 KiB | after `libcef.dll` | kept |
| cefclient only (every type) | one more 32 GiB (aligned) + 16 GiB pair | 1 | ≥ 32 GiB / 64 KiB | after `cefclient.exe`, before `libcef.dll` | kept |
| `renderer` only | a third 32 GiB, aligned, without a 16 GiB companion | 1 | ≥ 32 GiB | after `libcef.dll` | kept |
| `renderer` only | 1,320 GiB `MEM_RESERVE \| MEM_RESERVE_PLACEHOLDER` | 1 | ≥ 4 GiB | after `libcef.dll` | its first 36 GiB split off; the rest stays reserved as placeholders |
| `renderer` only | 4 GiB and 16 GiB `MEM_REPLACE_PLACEHOLDER`, inside the 1,320 GiB region | 1 each | 4 GiB, 16 GiB | after `libcef.dll` | kept |
| `renderer` only | 1 GiB, 32 GiB-aligned request | 1 | ≥ 4 GiB | after `libcef.dll` | kept; 8 MiB decommitted |

Some renderers first failed the 1,320 GiB request at their hint. They then got a low address with no
hint, released it, and succeeded at another hint.

The research model, against this:

- **Two PartitionAlloc instances, 32 GiB aligned to 32 GiB: confirmed.** Each instance also takes its
  own 16 GiB unaligned reservation, so the metadata is 2 × 16 GiB, not one 16 GiB [M].
  cefclient has a third pair, made before `libcef.dll` loads. That is its own executable's
  allocator; `SocialClubHelper.exe` has none [M].
- **The V8 sandbox: confirmed** in renderers as a 1,320 GiB placeholder region. The 4 GiB and 16 GiB
  carves inside it are the pointer-compression cage and cppgc's cage [I]. The extra 32 GiB pool in
  renderers is a further PartitionAlloc pool [I].
- Per process [M]: about 96 GiB for every non-renderer type, and about 1,449 GiB for a renderer
  (96 + 32 + 1,320 + 1), with or without `--jitless`.

## Swap (stock files) and control (Rockstar's files)

Each run lasted 150 s (`runs/swap1`, `runs/control1`), with the same procedure. Process lists come
from 5 s snapshots; the states come from `socialclub_launcher.log` [M].

| | Swap: stock CEF files | Control: Social Club's files |
| --- | --- | --- |
| Refused? | no: no message, no error code, no signature or integrity complaint; the log's module list reads "Chromium Embedded Framework (…\libcef.dll) - 143.0.14.0" | — |
| Social Club UI states | `WAIT_BROWSER_WINDOW` → `LOADING` (`https://rgl.rockstargames.com/launcher`) → `WAITING_FOR_PAGE_LOAD` → `WAITING_FOR_PAGE_READY` → `PAGE_READY` → `START_SIGN_IN` → `FINISHED`, at 50.7 s | the same, at 47.6 s |
| `SC_INIT_ERR_*` | none | none |
| Screen at 90 s and 150 s | the launcher's sign-in page: Rockstar logo, "Sign In", Email and Password fields, and the cookie notice over the lower half | the same page (the Email field has focus) |
| Wine-side errors | only the usual prefix noise: `kerberos`/`ntlm` "no support" per process, `openxr` registry key, 5 `RoGetActivationFactory`, 2 `ole:marshal_object`, one `ntoskrnl:ZwLoadDriver`, and a stack overflow in Proton's `xalia.exe` (not a CEF process) | same set |
| Files after the run | the stock files, unchanged (byte-compared with the distribution) | the original files (sha256 list checked before the run) |

Screenshots stay under `$PLAYPORT_BUILD/agent-notes/pla254-rockstar/runs/{swap1,control1}/`.

### Process counts per type

The same in both runs at the sign-in page, steady from about 60 s to 150 s [M]:

| `SocialClubHelper.exe --type=` | Count |
| --- | --- |
| (browser, no `--type=`) | 1 |
| `gpu-process` | 1 |
| `renderer` | 3 |
| `utility`: network, storage, audio, video capture | 1 each (4) |
| **steady total** | **9** |
| short-lived `utility` (exited) | `ProcessorMetrics` 1 in both; in the swap run only, `FilePatcher` 2 and `Unzipper` 3 at about 85 s |

This replaces the research's assumed 6/7 split: 6 non-renderer and 3 renderer processes. At the
sizes above, that is about 6 × 96 + 3 × 1,449 ≈ 4,900 GiB of reservations for one launcher tree [I].
On the phone those all share one address window.

## What this means

- **The stock build is accepted.** Social Club's helper and `socialclub.dll` load the open-source
  CEF 143.0.14 distribution and drive the full sign-in UI, with nothing refusing it. A rebuild of the
  same CEF/Chromium revision, with PartitionAlloc's pools and the V8 sandbox shrunk, is technically
  a drop-in candidate. Whether it loads on the phone, and what it costs, are open. The build itself
  is the owner's separate decision.
- **The target is known.** Per process: two 32 GiB, 32 GiB-aligned pools and two 16 GiB metadata
  regions. Renderers add a 32 GiB pool, a 1,320 GiB sandbox placeholder and a 1 GiB region. A
  low-address-space build has to shrink all of them.
