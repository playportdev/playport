# 0128: An image maps above the furniture ceiling when the window below it is full

**Status:** accepted, 2026-10-19, chosen by the owner (PLA-418); the design approved by the
supervisor. Not yet shown on the phone.

## Context

- **The failure.** In run `20261019T173829` the guest window below the furniture ceiling,
  [0x7048000000, 0x73ffff0000), was full from +94 s
  ([evidence](../evidence/2026-10-19-rdr2-whole-launcher-end.md)). RDR2.exe's three loads of
  the 6 MB `socialclub.dll` failed with `c0000017`, and the game showed Social Club error 4.
- **What filled the window.** 139 `[va-scan] FAILED` lines:
  - one was RDR2's 8,960 MB reservation, which went above the ceiling as designed;
  - 132 were private allocations (8 MB pieces, thread stacks with a 4 GB floor, small pieces),
    and each was placed above the ceiling (`[va-ceiling] … placed at`);
  - six were the DLL: three loads, two tries each.

  At the end, 15,143 of the window's 15,232 MB were taken. 8,191 MB of that was the ml433 cage
  hold at 0x7200000000, which 0126's `jumbo-mb` had switched on for RDR2 (decision 0129 removes
  it).
- **Why private memory escapes and an image does not** (madeira-unix `virtual_ios.c`):
  - `map_view` caps a kernel-picked placement at the ceiling only when its caller set no upper
    limit. When the window fails, it retries bottom-up above the ceiling.
  - `map_image_view` applies the ceiling itself, as `limit_high`, whenever its caller set none.
    `map_view` then takes that limit for the caller's own. It does no retry above the ceiling,
    and it returns `STATUS_NO_MEMORY`.
  - `ios_ml1027_place`, the `[mmap-place]` placement, is only the last resort of an
    unclamped kernel pick. Images never reach it.
- **Why the ceiling exists.** It keeps the runtime's own allocations out of
  [0x73ffff0000, 0x7c00000000). That band is for CEF's PartitionAlloc pools and the large
  reservations (the 0126 hold).
- **What an image's address does not depend on:**
  - **Native ARM64EC code** runs from JIT-pool copies. In this run the RX alias was at
    0x108548000, already about 450 GB from every image, so ADRP reach has nothing to do with
    0x73 against 0x75.
  - **FEX's L2 lookup** masks addresses to 8 GB, so every DLL at 0x7… already aliases there. The
    L1 lookup compares all 64 bits.
  - **Coverage:** the ARM64EC code bitmap reaches the host limit (0x8000000000), and the guest
    page tables reach 0x7c00000000.
  - **The server** puts no address limit on an image view.
  - **i386 images** are placed by WoW64's window before any of this, below 4 GB.

## Decision

- **The fallback.** An image is placed above the ceiling only when both of these hold:
  - its caller set no upper limit, so the ceiling cap was the runtime's own;
  - both placements below the ceiling failed with `STATUS_NO_MEMORY`.

  It is then mapped bottom-up in [max(caller's lower limit, ceiling), 0x7c00000000), below FEX's
  band, as a private spill is. This is madeira-unix 0170, with the rule in `pp_image_place.h`.
- **The log.** Each such image logs `[va-ceiling] image size=… above the ceiling: placed at …`
  or `FAILED, none in …`. The `[img-map]` line after it names the DLL.
- **What does not change:**
  - an image whose window has room;
  - an image whose caller set its own upper limit;
  - an i386 image;
  - private allocations.

## Costs and risks

- **The band can split.** An image above the ceiling can split a gap that a later large
  reservation needs. Bottom-up placement keeps images at the band's bottom; the 0126 hold sits
  at the top of its hole.
- **Known gaps: three places assume no image at or above 0x7400000000:**
  - FEX's `[iOS-bogusrip]` check (fex `Core.cpp`, `GuestRIP >= 0x7400000000`). It only logs, at
    most 16 lines, and would call such an image's code a host address.
  - `ios_is_arena_addr` in `virtual_ios.c`. It only splits the zero-check probes' counters.
  - The guest-pc gate of the Mach fault delivery in `signal_arm64_ios.c`. It claims a native
    fault as the guest's only for a pc in [0x7000000000, 0x7400000000), so a native branch to
    such an image's address would be declined. Private memory above the ceiling already has
    this gap.

  The supervisor files a follow-up for all three.
- **Not shown yet:** whether the game also needs the launcher alive once `socialclub.dll` maps.
