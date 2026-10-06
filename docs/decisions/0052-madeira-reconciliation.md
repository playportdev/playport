# 0052: Madeira reconciliation: whose design runs where Madeira and Playport overlap

**Status:** accepted, 2026-10-05, by the owner; superseded by
[0054](0054-madeira-frozen.md), which freezes Madeira at `8c050d0` (its
freeze-and-own fallback) and ports fastsync as a Playport patch. Settled step 2 of the
[dependency strategy](../plans/finished.md#dependency-strategy) (order row 4).
Supersedes [0023](0023-in-process-sync-stays-off.md) for fastsync: Madeira's
fastsync is on by default, and madsync stays off as 0023 decided. Narrows
[0047](0047-i386-titles-on-vulkan.md)'s guest window to Madeira's design;
keeps 0047's Vulkan default, [0041](0041-codecs-supersets-and-relinking.md)'s
GStreamer and [0001](0001-superproject-on-madeira.md). (0051 is taken on
`main` by another record.)

## Decision

Madeira stays the base. Where Madeira and Playport implement the same thing,
Playport runs Madeira's design unless a cohort title needs Playport's. In that
case Playport's design is carried as a patch on top of Madeira's, never
beside it.

| Area | Runs | Carried by Playport |
|---|---|---|
| i386/WoW64 guest windows | **Madeira's**: lazy windows, `ProcessWineIosWowGuestBase`, the wine fork's window-aware wow64/wow64win, FEX's guest-window codegen | What Portal 2 needs and Madeira lacks: i386 winevulkan pointer conversion, the wow64win gaps Portal 2 finds, i386 diagnostics. The app exports `MADEIRA_GDI_SHARED_SECTION=1` for an i386 title's session and `FEX_MADEIRA_HOSTPROBE` for every session. Playport's own window (madeira-unix 0049–0075 and the WoW64 patches in wine-pe, wine-unix and fex) is dropped once Portal 2 is at parity on Madeira's |
| In-process sync | **Madeira's fastsync, on by default** (the app exports `MADEIRA_FASTSYNC=auto`, as Madeira's app does); **madsync off** (only with `inproc-sync = 1`) | wine-unix 0006/0007; Playport's system-APC semantics (wine-unix 0002), reworked for fastsync: a system APC is never dropped; it is handed to a waiting thread or kept on the issuing thread, and a thread in a fastsync wait still runs it. This replaces Madeira's 074e0e3, which drops an undeliverable async I/O APC and so brings back the zero-byte pipe read |
| winegstreamer | **Playport's** GStreamer (0041) | Madeira's FFmpeg/VideoToolbox unix side is not built; winegstreamer binds GStreamer's tables for 64-bit and wow64 callers |
| Direct3D 9 | **Playport's** DXVK d3d9 on KosmicKrisp (0047) | Madeira's DXMT D3D9 frontend is carried unbuilt; trying it on Portal 2 is a later, measured experiment |
| winemetal unix-call slots | upstream 0–145, Madeira's 146–149 (as rebased), then Madeira's new calls appended in its order (DXSO 150–154, `d3d9_nop` 155) | the renumbering; `pp slots` stays mandatory |
| Duplicate fixes | **Madeira's** where it is diff-equivalent or better (TEB/TSD bitmap, MIDI, killed-thread sections, clean-checkout configure, rpmalloc size queries); Madeira's ARM64EC export-IAT classifier replaces Playport's "never selected" stub, gated on Hollow Knight | Playport's where Madeira's is weaker (per-PEB emulator alias callbacks, madeira-unix 0044) |

**The move's gate.** `main` does not move to the new Madeira until Portal 2 is
at parity on Madeira's WoW64: it launches, reaches its menu, plays at 59 FPS
or more at 720p with the frame cap, and its hitches are within the spread
measured on the deps-latest build. Hollow Knight passes as for any move.
Fastsync is measured on and off on both titles during the move, and stays on
unless either title regresses with it.

## Why

- **Most of the runtime is Madeira's design.** Following it where it overlaps
  removes the biggest source of conflicts: Madeira's i386 work and Playport's
  edit the same functions, and both would fire on one i386 launch.
- **Fastsync is Madeira's default and what its app runs.** Fastsync keeps a
  server path: a wait that does not finish in its short in-process spin falls
  through to the wineserver. Running Madeira's default keeps Playport on the
  configuration Madeira tests.
- **Where Playport keeps its own design, a cohort title needs it, or Madeira's
  design brings back a silent bug Playport fixed.**
  - Hollow Knight's H.264/AAC cinematics need GStreamer's decoders.
  - Portal 2 plays at 59.6 FPS on DXVK d3d9.
  - A dropped system APC returns a pipe read with no data.
- Proton, the reference, uses GStreamer and DXVK d3d9.

## Cost

- Portal 2 must be brought up again on Madeira's WoW64. Until it reaches
  parity, the `madeira` pin does not move on `main`.
- At every Madeira move, Playport carries the GStreamer binder, the APC
  semantics and the slot renumbering.
- Fastsync on is a behaviour change for both titles; the on/off measurement
  in the move is its check.

## Fallback: freeze-and-own (soft fork)

A new record adopts it if one of these holds:

1. Madeira makes a design mandatory that Playport cannot run. Examples:
   in-process sync with no server-wait path, removal of the wineserver sync
   path, or an i386 path that cannot carry Vulkan.
2. Two consecutive Madeira moves each take more than one work session to
   reconcile, counted from the dry run to the device gates.
3. Portal 2 cannot reach parity on Madeira's WoW64 within two work sessions.
4. Madeira's licence terms for the built paths change incompatibly, or its
   history becomes unfetchable.

Freezing means the `madeira` pin stops moving. `build/*-unix`, Winios and the
four port series become Playport-maintained from that commit. Wine, FEX, DXMT
and rpmalloc keep moving as series. It is not a rewrite.

Duties that do not change under a freeze:

- **Provenance.** The code still comes from willfaust/Madeira at a recorded
  commit, and no other project is named as provenance (AGENTS.md, 0001). The
  frozen pin stays `upstream/madeira`'s gitlink.
- **Licences.**
  - Madeira's code stays GPL-3.0-or-later with the Madeira Converter
    Exception (`LICENSE-MADEIRA.md` files kept verbatim).
  - The `build/*-unix` copies of Wine keep their LGPL-2.1-or-later headers,
    and the un-headered ones stay as 0039 reads them.
  - Madeira's FEX, DXMT and rpmalloc changes keep their terms over MIT (FEX),
    0BSD (rpmalloc) and LGPL-2.1-or-later (DXMT after v0.80, and the imported
    D3D9 code).
  - NOTICES.md carries every upstream notice.
  - Playport's own exception (0006) covers only Playport's lines.
- **Corresponding Source (0042).**
  - Every pinned commit must stay fetchable. Before freezing, Playport mirrors
    Madeira and its forks at the pinned commits into a public repository it
    controls, with an immutable tag per commit, and
    `build/source-bundle.json` packs from there.
  - The proprietary `libmetalirconverter.dylib` and Madeira's own app stay
    dropped (0001's reason holds for a mirror).
