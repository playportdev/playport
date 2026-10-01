# MultiVersus plays on Direct3D 12 feature level 12_0 (vkd3d-proton on KosmicKrisp)

**Date:** 2026-09-30. **Phone:** iPhone18,4, iOS 27.0, the shared reference
phone. **Branch:** `d3d12-fl12`.
**Title:** MultiVersus (Steam app 1818750, 18.0 GB, build 17784632), Unreal
Engine 5.1.1, its Direct3D 12 renderer (`-dx12`), game page set to Vulkan.
Offline: its servers closed in 2025 and the final build plays locally.
**IPA** (dev): `Playport-26.5-7f581919.ipa`, sha256
`7f581919db8ae588f08a749ae4f79c6f5cdfde36521035d2e7517712c8b14c39`.

## Choosing the title

The paired account owns 81 games. The one that needed to be Direct3D 12 at
feature level 12_0, play offline, and fit on the phone was MultiVersus. Its
executable carries Microsoft's Agility SDK (`Binaries/Win64/D3D12/`), and its
Direct3D 12 renderer is Unreal Engine 5.1's SM6 path: feature level 12_0 and
shader model 6.6. Without `-dx12` it runs Direct3D 11.
The others were ruled out:

- REMATCH, SMITE 2, THE FINALS, Predecessor, Marvel Rivals and skate. are
  online-only.
- Sniper Elite 5, Metro Exodus and Jedi: Survivor do not fit, even with The
  Witcher 3 removed.
- Shadow and Rise of the Tomb Raider and Civilization VI run Direct3D 12 at
  11_0.

MultiVersus installed through the UI (`pp ui --action install:1818750`) in
327 s into the 27 GB that was free, so nothing had to be uninstalled. The
phone has 8.5 GB free after it. The Witcher 3 (1.32) and En Garde! stay
installed.

The game page is set to Vulkan with the argument `-dx12` (saved with
`--keep-settings`), so a Play from the page runs it on Direct3D 12.

## What stopped it, in order

1. **No feature level 12_0** (`patches/vkd3d-proton` 0001). KosmicKrisp has
   no sparse binding, so vkd3d-proton reported tiled resources tier 0 and
   stopped at 11_1. It now reaches 12_0 on a driver with no sparse binding
   at all, and TiledResourcesTier stays 0. It logs how it decided:
   `Max feature level 0xc000: tiled resources tier 0 (sparse binding 0),
   resource binding tier 3, typed UAV loads 1, shader model 0x66`.
2. **Shader model 6.0 only** (`patches/vkd3d-proton` 0002). KosmicKrisp has
   no float controls, no compute shader derivatives and no 64-bit buffer
   atomics. On KosmicKrisp only, SM 6.6 is now exposed without them, as
   vkd3d-proton already does for derivatives on pre-Turing NVIDIA. A
   shader that used one of them would fail to compile. None did in these
   runs: there were no pipeline errors in the logs.
3. **"Out of video memory trying to allocate a rendering resource"**
   (`patches/mesa` 0013). This was a message box, and the game exited 0. The
   new `[msgbox]` log line (`patches/wine-pe` 0011) showed it. vkd3d-proton
   makes an 8192-query timestamp pool, and Metal refuses a counter heap of more than
   4096 entries on the A19 (`Requested Heap size is too large (requested
   8192 max is 4096)`). KosmicKrisp now splits a timestamp pool over heaps of
   at most 4096 entries.
4. **A black screen that never ended, on either backend**
   (`patches/madeira-unix` 0046). The game started, but its GameThread
   waited, and one thread (`mmdevapi_midi_notify`) spun at 99% of a core.
   The iOS audio table answered every MIDI unix call with a stub that set
   nothing:
   - `midi_init` left DRV_SUCCESS, so mmdevapi started its notify thread;
   - `midi_notify_wait` set neither `quit` nor `send_notify`, so that thread
     looped and called `DriverCallback` with whatever was on its stack.

   The MIDI calls now answer as a driver with no devices. The title screen
   came up on the next run, at 50 fps.
5. **A random `E_INVALIDARG` crash** (`patches/vkd3d-proton` 0003). Unreal's
   crash report named it: `hr failed at D3D12Resources.cpp:391 with error
   E_INVALIDARG` (GPUCrash). It came 45 to 80 s into the title screen or at
   the first button press. The engine's transient heaps place resources at
   offsets that are not multiples of their 64 KiB placement alignment: a
   256 KiB UAV buffer at 0x8000, and a 1564x720 R32G8X24 depth-stencil
   texture at 0x48000. The texture was found with the new failure log
   (`patches/vkd3d-proton` 0004). A buffer is now placed at any 256-byte
   offset, and a single-sampled texture at any offset its image's own
   memory alignment divides. After that, none of three 100 s title-screen
   runs and four further plays crashed. Two of those plays went into
   Training for over a minute.

Decision [0032](../decisions/0032-vkd3d-proton-as-a-series.md) records the
vkd3d-proton series.

Also: MultiVersus imports `dxva2`, `qwave` and `ktmw32`, which the runtime
did not bundle (`0xc0000135` at start). They are Wine builtins now staged
(`build/stages/stage-artifacts.py`).

## On the phone (IPA `7f581919…`)

| Run | Result |
| --- | --- |
| MultiVersus, Play from the page (Vulkan, `-dx12`) | first frame +9.7 s. The title screen showed at about +60 s, at 50 fps (Metal HUD). START, then the account sync ("Syncing Account State"), then the main menu. UP and A went to Training, and the stage loaded. `pp pad push multiversus-training` played 68 s of walking, jumping and attacking. The fighter moved and hit the bot (8% damage shown), and the app was still running afterwards (`pp phone status`: `app_pid`). Training ran at 26-31 fps with 30-38 ms of GPU time. The app footprint was 6.8-7.2 GB of the 8 GB limit. |
| Hollow Knight, default (DXMT) | first frame +9.5 s, the main menu at 58 fps (`until first-frame+10`) |
| En Garde!, default (DXMT, Direct3D 11) | first frame +7.0 s (`until first-frame+20`) |

The build from the committed tree, `Playport-26.5-843fb3b3.ipa` (sha256
`843fb3b332b6ff80ca6a9538811db5675a07512d6dcff4016457c076926c7b0a`), has the
same `artifacts.tsv` as `7f581919…`. It is what the phone has now. Hollow
Knight (DXMT) reached its first frame at +10.5 s, and MultiVersus reached its
title screen (Vulkan, `-dx12`, first frame at +9.5 s).

An earlier IPA of this series, with the same vkd3d-proton behaviour, took
En Garde! with `-DX12` on Vulkan (also UE 5.1.1) past device creation to its
splash screen (`Kowloon`, 37 fps). Before these changes, both games quit a
Direct3D 12 start at once.

## Not shown

- **Hollow Knight on Vulkan with `-force-d3d12`** (a test setup, not how the
  cohort runs) was already flaky on `main`: 2 of 5 starts ended at +3 s
  (`0x20474343`, an unhandled JIT SIGBUS). With this series it still reaches
  its first frame in most starts: 3 of 5 with SM 6.6, and 1 of 1 with SM 6.0
  and feature level 12_0. The failures now fault 1 s in, reading a garbage
  pointer from UnityPlayer.dll (`+0x2616e3`, `+0x21e23a0`). Not investigated
  further.
- The title screen ignores the scripted pad for up to about a minute and a
  half after it shows, so a scripted run sends START until the account sync
  starts (`tools/pad/multiversus-training.txt`).
- Online modes (the servers are gone), the Rifts and a full match against
  bots. Performance (26-31 fps in Training) is not tuned. The phone ran
  thermal `serious` during the last runs.
- The release variant.
