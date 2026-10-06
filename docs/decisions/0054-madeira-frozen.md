# 0054: Madeira frozen at 8c050d0; Playport owns its layer

**Status:** accepted, 2026-10-06, by the owner. Supersedes
[0052](0052-madeira-reconciliation.md) in whole: it adopts the freeze-and-own
fallback that 0052 drafted. Changes the Madeira parts of
[0049](0049-latest-pins.md) (`madeira` no longer moves by `pp sync`) and
[0053](0053-carrying-model.md) (Madeira does not move with `pp sync`).
Restates [0023](0023-in-process-sync-stays-off.md): madsync stays off, and
fastsync comes as a Playport patch. Keeps [0001](0001-superproject-on-madeira.md),
[0007](0007-dxmt-on-upstream.md), [0008](0008-fex-on-upstream.md) and
[0013](0013-wine-on-upstream.md), with the port rows read as below.

## Decision

- **The `madeira` pin is frozen at `8c050d0`**, the layer `main` builds since
  deps-latest. It is still the `upstream/madeira` gitlink and `pins.lock`
  still records it. It does not move.
- **Playport owns that layer.** `build/*-unix`, the `*_ios.c` replacements,
  Winios and the four port series (`wine-port`, `fex-port`, `dxmt-port`,
  `rpmalloc-port`) are Playport's to maintain from `8c050d0`. Wine, FEX, DXMT,
  rpmalloc and the other components keep moving as series on their own
  upstreams (0049).
- **Madeira is watched, not followed.** `pp sync` is a watch report by
  default: Madeira's commits past the pin, and its forks' commits past the
  port rows, that touch what Playport builds or patches. A fix Playport wants
  is ported by hand as a Playport patch, with the Madeira commit named in its
  message ([UPSTREAM-SYNC.md](../UPSTREAM-SYNC.md)). Moving the pin needs
  `--move-pin-0054`, and a new decision record first.
- **Fastsync is the first such port** (decision 0052 had planned it with the
  Madeira move): Madeira's wine fork f6848ad (client) and e200a5e (server
  cells) and Madeira's 89710fc (`server_ios.c`), as `patches/wine-unix`
  0015–0017 and `patches/madeira-unix` 0081, class `feature`. The app sets
  `MADEIRA_FASTSYNC`. It is on by default only when neither cohort title
  regresses with it on this base, as 0052 required
  ([evidence](../evidence/2026-10-06-fastsync-on-8c050d0.md)). Madsync stays
  off (0023). Playport's system-APC semantics (`wine-unix` 0002) stay as they
  are: a system APC is never dropped.
- **`madeira-main` stays an unmerged reference branch.** It holds the
  `bbbf8d0` move, its evidence and its re-ports, as a source for hand ports.
- **No rewrite.** The source stays the `upstream/madeira` submodule plus the
  patch series. Copying Madeira's code into this repository would be a later
  decision.
- **The `*-port` rows become frozen provenance records.** `wine-port`
  `723d1bf`, `fex-port` `0f8edf8`, `dxmt-port` `ca8a251` and `rpmalloc-port`
  `1f271c0` record which fork commits each port series came from. They equal
  the gitlinks of the frozen pin, so the build's check (0013: a port row must
  equal Madeira's gitlink) still holds and never fires. They no longer track a
  moving Madeira gitlink.

## Why

- **The Madeira move was where the trouble came from.** Moving to Madeira
  `bbbf8d0` on `madeira-main` brought four issues, each found on the phone
  (`docs/evidence/2026-10-06-madeira-bbbf8d0.md`,
  `2026-10-06-portal2-madeira-wow64.md` and `2026-10-06-proton-alignment.md`
  on `madeira-main`):
  1. Hollow Knight drew only black frames with Madeira's FEX, which turns
     FEAT_AFP off for the ARM64EC module by default.
  2. The session's wineserver thread crashed at session start
     (`PEB+0xb8`): Madeira's hardware registry keys read the PEB before
     wine-11.19 had made it.
  3. Portal 2 did not start: Madeira's i386 child path found no 32-bit PEB
     on wine-11.19.
  4. Hollow Knight crashed in 3 of 31 plays on address-space exhaustion at a
     thread creation; a holdback switch stopped it, but the late consumer was
     never named.

  The deps-latest moves (every other row, decision 0049) brought none: every
  IPA passed the gate on both titles
  ([deps-latest](../evidence/2026-10-05-deps-latest.md)).
- **Most of the CPU gain came with deps-latest.** Portal 2's walk went from
  367 to 295 mW of CPU power with deps-latest (−20 %). On `madeira-main`,
  fastsync on against off was 248 against 264 mW (−6 %) with 10 % fewer
  wineserver requests a frame. That one measured win is ported on its own.
- **The directions diverge.** Madeira is Metal-first: DXMT, DXMT's D3D9, its
  own D3D12 and FFmpeg video. Playport is Vulkan/KosmicKrisp-first and as
  close to Proton as it can be (0044, 0047, the alignment plan). Following
  Madeira means reconciling designs Playport does not run at every move.
- **0052's own fallback trigger.** Its trigger 2 is Madeira moves that each
  take more than one work session to reconcile, from the dry run to the
  device gates. The first move after 0052, to `bbbf8d0`, took more than one
  (its dry run on 2026-10-05, its gates through 2026-10-06), and the owner
  did not wait for a second.

## Cost

- Playport maintains the iOS layer alone. Madeira's later fixes reach
  Playport only through a person reading the watch report and porting them.
- The `*_ios.c` replacements stay forked from wine-11.4. Each Wine move
  re-ports them (`madeira-port` patches at the end of `patches/madeira-unix`)
  without Madeira's own re-ports to lean on.

## Duties that do not change

- **Provenance.** The code comes from willfaust/Madeira at `8c050d0`, and no
  other project is named as provenance (AGENTS.md, 0001). The frozen pin stays
  the `upstream/madeira` gitlink.
- **Licences.**
  - Madeira's code stays GPL-3.0-or-later with the Madeira Converter
    Exception (`LICENSE-MADEIRA.md` files kept verbatim).
  - The `build/*-unix` copies of Wine keep their LGPL-2.1-or-later headers,
    and the un-headered ones stay as 0039 reads them.
  - Madeira's FEX, DXMT and rpmalloc changes keep their terms over MIT (FEX),
    0BSD (rpmalloc) and LGPL-2.1-or-later (DXMT after v0.80).
  - NOTICES.md carries every upstream notice.
  - Playport's own exception (0006) covers only Playport's lines.
- **Corresponding Source ([0042](0042-the-source-bundle-is-complete.md)).**
  The frozen commits must stay fetchable. The proprietary
  `libmetalirconverter.dylib` and Madeira's own app stay out of anything
  Playport ships (0001's reason holds for a mirror).

## Pending: the public mirror (an owner action)

Making the frozen commits fetchable for good means a public repository that
Playport controls, with an immutable tag per commit, and
`build/source-bundle.json` packing from it. Creating that repository is the
owner's to do; nothing has been created. Until then the bundle packs from
Madeira's and its forks' own repositories, where these commits are today.

| Row | Repository | Commit |
|---|---|---|
| `madeira` | willfaust/Madeira | `8c050d03f4d89096e1e2e2c8bb44479fffd86619` |
| `wine-port` | willfaust/wine (`madeira-lgpl`) | `723d1bf5132768276cea9bc35ab59c83557bb5fb` |
| `fex-port` | willfaust/FEX (`ios-port-2607`) | `0f8edf8f6383ae8085e0ffac511c789cdae97514` |
| `dxmt-port` | willfaust/dxmt (`ios-port`) | `ca8a2516d819e7e1f366981825ad1f0d26f80fdd` |
| `rpmalloc-port` | willfaust/rpmalloc (`ios-madeira`) | `1f271c0c3202663801a0aec32bdb57e5241d6a0e` |
