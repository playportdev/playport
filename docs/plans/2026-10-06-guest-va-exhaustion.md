# Plan: Death's Door quits 14 s in (a guest address-space allocation fails)

**Date:** 2026-10-06. **Kind:** plan, done: fix (a), `madeira-unix` 0082, then the fill's causes (0083 CEF removed, 0084, 0085), gated in
[2026-10-06-guest-va-exhaustion](../evidence/2026-10-06-guest-va-exhaustion.md) (The Witcher 3
not played; Portal 2 was the VA title). **Pins read:** `madeira` 8c050d0
(frozen, decision 0054) with `patches/madeira-unix` (0001–0081); `dxmt` with
`patches/dxmt-port` and `patches/dxmt`. **Found by:** the owner's play after the
[Epic gate](../evidence/2026-10-06-epic-games.md), IPA `d17028de…`.

## What happened

Death's Door (`epic-65d73e3be8824829b5b788bd849b6559`, Unity x86-64, D3D11 on DXMT)
reaches its title screen at +4.5 s and quits at +14 s, before any input. Hollow Knight
on the same IPA shows none of the failures below. The game files verify 1334/1334,
so this is not an Epic or install fault. The driven gate play stopped at +14.5 s,
just before the failure, which is why the gate passed.

From the phone's `s1-host.log` of that play:

1. From about +7 s, `[va-scan] FAILED` lines (130 of them) for requests of 0x40000 to
   0x1ffff000 in the clamped window `0x7020000000..0x73ffff0000`: `errno=17` (EEXIST),
   then `relaxing ceiling, retrying unclamped`. Those retries succeed for a while.
2. At the end, the unclamped retries fail too:
   - bottom-up over `0x100000000..0x73ffff0000`, size 0x110000: `tries=1200 skips=633
     stop=gaps-exhausted(bottom-up) firstfail=0x100000000 errno=12` (ENOMEM), while Wine's
     view list reports `maxgap=0x6ea0000000`;
   - top-down, size 0x100000: `walked-all-views firstfail=0x73ffef0000 errno=17`, with
     `tailgap=0x72d82a0000`.

   So Wine believes hundreds of GB are free, while the kernel refuses (ENOMEM) or the
   space is taken by host mappings Wine does not track (EEXIST).
3. `virtual_map_image` then fails for `dbghelp.dll` (`c0000017`), the iOS audio timer
   thread cannot be created, and DXMT's `d3d11.dll` throws `dxmt::MTLD3DError` (C++,
   code `0x20474343`). Nothing catches it, so the process ends with that exit code
   after 14246 ms.
4. Memory was not the limit: 2.6 GB resident (`[footprint]`) of an 8 GB limit, and the
   FEX band was 3.7 GB used of 16 GB, with 790 free 16 MB slots.

## Questions this plan answers first

- **Q1. Is it every launch at the same point?** One run is not enough to tell. Nothing
  was pressed, so the trigger is the game's own loading at the title screen.
- **Q2. What is filling the window?** The census `ios_furniture_census` walks the Mach map
  of `0x7000000000..0x73ffff0000`. Is the clamped window full of host (Metal, IOSurface,
  IOKit) regions, or of Wine views? Which caller keeps asking (sizes 1–16 MB, bottom-up)?
  Unity's Mono heap, DXMT's buffers and their Metal heaps are the candidates.
- **Q3. Why ENOMEM at `0x100000000` with a 443 GB gap in Wine's list?** Either iOS caps
  this process's VA below where that gap lies (the entitlements carry no extended
  virtual addressing), or the scan's 1200-try budget runs out crawling the low VA iOS
  occupies before it reaches free space. The `firstfail`/`tailgap` pair already tells
  refusal from occupancy (see the ml798 comment in `virtual_ios.c`).
- **Q4. Is it DXMT's?** The same game on the Vulkan backend (DXVK on KosmicKrisp, the
  game's Graphics option) allocates differently. If it runs on there, the allocation
  pattern is DXMT's. The [KosmicKrisp-default plan](2026-10-06-kosmickrisp-default.md)
  moves every title off DXMT in the end, but this fault can hit any heavy title, so it
  is fixed here regardless.

## Steps

**1. Reproduce and measure (phone: two runs, one session).**
- `pp ui --play epic-65d73e3be8824829b5b788bd849b6559 --until first-frame+40 --shot`
  with DXMT, then the same with `--settings 'epic-…:{"graphics":"vulkan"}'`. Record each
  run's time to the exit, the count and first time of `[va-scan] FAILED`, and the
  `title: band:` and `[footprint]` lines.
- In the DXMT run, have the census and `[band-map]` written at the first unclamped
  failure. This is a dev-only logging patch in `patches/madeira-unix`, not kept:
  `Class: diagnostic`.
- Write down Q1–Q4's answers in `.work/agent-notes/va-exhaustion/` before any fix.

**2. Find the caller (host only, from the logs).** Tag each failing request with its
caller: return address to module, the way `[seh-xlate]` names modules. Sum the views
by module. Only then choose between the fixes below.

**3. Fix (one patch in `patches/madeira-unix`, with `Class:`, `Evidence:` and
`Offered-upstream: no`).** The candidates, depending on step 1 and 2:
- **(a) Placement.** The unclamped scan skips host regions using the Mach map for the
  whole window, not only in the clamped one (`skips=` exists there). It also tries the
  top-down tail Wine believes free before it gives up, so it no longer stops at
  1200 tries or at the first EEXIST.
- **(b) Reserve up front.** If iOS refuses fixed mappings past a cap (Q3), Wine never
  scans there. It reserves a guest heap window at start, as `wine_host.c` reserves the
  JIT pool and ntdll reserves the FEX band, and serves unhinted guest reserves from it.
  Decision 0054's layer allows this; it needs one note in ARCHITECTURE.md (the FEX host
  band section's neighbour).
- **(c) Steer.** If one caller reserves far more than it touches (as Hollow Knight's
  512 MB arenas did, madeira-unix 0032), steer or shrink that caller's reserves.
- DXMT catching its own allocation failure is not a fix: the game would only fail later.

**4. Gate (phone, one session).**
- Death's Door runs to `first-frame+60` and a scripted New Game into play
  (`tools/pad/`, a new `dd-new-game` script) with no `[va-scan] FAILED` past the
  clamped retries.
- Hollow Knight plays to `first-frame+10`, which every Wine patch requires (decision 0007).
- One title that stresses VA plays to its first frame: The Witcher 3 or Portal 2, both
  installed.
- The result goes into `docs/evidence/<date>-guest-va-exhaustion.md`, and the Epic
  evidence and the PC-store plan's Phase 3 line link to it.

## Not in this plan

- Dropping DXMT (the KosmicKrisp-default plan).
- The extended virtual addressing entitlement. A free-team profile may not carry it.
  If Q3 says it is the only fix, that is a decision record of its own, and the owner's
  call.

## Risks

- `virtual_ios.c` is about 19,700 lines with many interacting placement rules (the
  clamped window, the spill cap, the steering valve, the FEX band). A placement change
  can starve another band. Step 4's three titles are the check, and `title: band:`
  `refused` must stay 0.
- A first-run cause can hide a second one: the gate goes into play, not just past +14 s.
