# Guest address-space exhaustion: Death's Door runs on

**Date:** 2026-10-06. **Plan:** [guest VA exhaustion](../plans/2026-10-06-guest-va-exhaustion.md).
**Phone:** iPhone18,4, iOS 27.0, dev build, on battery. **Title:** Death's Door
(`epic-65d73e3be8824829b5b788bd849b6559`, Unity x86-64, D3D11). **Fix:** `patches/madeira-unix`
0082. Found by the [Epic gate](2026-10-06-epic-games.md).

## Measured (plan steps 1 and 2)

A diagnostic build (a `madeira-unix` patch, not kept, IPA `0219671c…`) tagged each view with
the module that asked for it (the first return address above the syscall frame in an image
outside ntdll/kernelbase/kernel32) and, at the first clamped failure and the first refusal,
walked the Mach map by range and summed Wine's views by owner.

- **Q1, every launch?** Most, not all. 512 MB reserves (`0x1ffff000`, about 19 per launch)
  are steered above the furniture ceiling once `va-pressure` is latched. A launch where a
  boot-time scan grinds (over 1024 tries crawling iOS's low VA, which depends on where iOS
  put things) latches it at once, and the reserves never enter the window. Otherwise it latches
  only when the reserves pass 8 GB, by which time 14 of them (7 GB) fill the window. The owner's
  launch and both diagnostic ones went the second way, and 3 of 7 on the fixed build. The quit
  followed every time on DXMT on a build without the fix.
- **Q2, what fills the clamped window** `[0x7000000000, 0x73ffff0000)` (16 GB): 8.7 GB that
  holds no guest views: the ml433 V8/cppgc holdback (`0x7200000000`, 8 GB, for CEF; no game
  uses it), the JIT pool's RW alias (512 MB) and 128 MB at `0x73f8000000`. And 7.6 GB of guest
  views: FEX (libarm64ecfex.dll) 3.6–4.1 GB, UnityPlayer.dll 1.2–2.2 GB, about 2.6 GB with no
  guest caller, d3d11.dll up to 0.6 GB. Largest free piece: 57 MB at the first failure, 0 at the
  refusal. Meanwhile `[0x7400000000, 0x7c00000000)` (32 GB) was empty, and 30 GB of it still
  free at the refusal.
- **Q3, ENOMEM at `0x100000000` with a 443 GB gap in Wine's list.** Not a VA cap and not the
  try budget. `[4 GB, 64 GB)` is iOS's own land (33,000 Mach regions, 60 GB mapped, largest
  hole 14–317 MB); `[64 GB, 448 GB)` is one 384 GB Mach region (the GPU carveout), which Wine's
  view list counts as free. The refused callers are those with a 4 GB floor (`limit_4g`): each
  x64 thread's 1 MB CHPE emulator stack. With `address_space_start` at `0x10000` after
  `set_large_address_space`, map_view treats their floor as a real constraint and does not let
  them past the ceiling, so their window was `[4 GB, 0x73ffff0000)`: nothing free. The callers
  that could relax escaped through a kernel pick, which put them in iOS's low VA (`0x1306f0000`,
  `0x13cd10000`…), the last holes the host's own allocators have.
- **Q4, DXMT's?** No. On Vulkan (`{"graphics":"vulkan"}`) the window fills the same way (a
  refusal too, 176 relaxed requests); that run went on to `first-frame+40`. DXMT dies because
  the refused allocation is the stack of a thread its d3d11.dll creates (`d3d11.dll+0x5f21c`),
  and it throws `dxmt::MTLD3DError`. XAudio2's timer thread (`xaudio2_7.dll+0x28258`) was the
  other refused stack.

## The fix (plan step 3, candidate a)

`madeira-unix` 0082: a request the furniture ceiling clamped scans above the ceiling
(`[max(limit_low, ceiling), user limit)`, bottom-up) before a kernel pick or a refusal. The
caller's own limits hold: `limit_low` stays the floor, and a caller with a `limit_high` is
never clamped. `[va-ceiling]` logs the first 16 placements and every failure. Not (b): iOS does
not cap the VA, and 32 GB is free. Not (c): no single caller fills the window; the 512 MB
reserves are already steered once pressure is latched.

## On the phone (plan step 4), IPA `5233877596c68fe74b4d0fee088c037d6e8ee4ce52a4ecc5044d13765a5d3ccd`

- **Death's Door, the case that quit** (steering armed only at 8191 MB): 248 clamped
  `[va-scan] FAILED` lines, each placed above the ceiling; none says `STATUS_NO_MEMORY`, no
  `[va-ceiling] FAILED`, no image map or thread creation failed. It ran 110 s, first frame at
  +4.92 s. The pad script `tools/pad/dd-new-game` (Start, slot 1, Start, the bus, Sharon's
  lines, a walk) took the crow onto the bridge with the HUD up, and it moved there. `title:
  band: … refused=0`.
- Two more such launches (`pp ui --until first-frame+20`; one had 158 clamped retries, all
  placed above) ran past +14 s to the stop.
- On the diagnostic build with the fix, by hand: title screen, slots, New game, the bus, the
  dialogue and control on the bridge ("L TO MOVE"), the crow walking right.
- Death's Door under `pp perf --secs 80 --pad first-frame+15:dd-new-game` (a launch with
  pressure latched at boot, so not the faulting path): into play, 39.9 FPS mean.
- **Hollow Knight** to `first-frame+10`: first frame +9.97 s, main menu drawn, `refused=0`.
- **Portal 2** to `first-frame+10`: first frame +5.97 s, the Source intro drawn, no
  `[va-ceiling]` needed, `refused=0`.

Screenshots are in the run directories under `.work`, not here.

## Left

- The 8 GB holdback sits in the window for CEF, which no game uses. Dropping it, or
  steering the 512 MB reserves from the first one, would keep the window from filling at all;
  not needed for this fix.
- The Witcher 3 was not played in this gate (Portal 2 was the VA title).
