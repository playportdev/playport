# 0126: RDR2's Play holds an 8,960 MB address-space gap from the runtime's start

**Status:** accepted, 2026-10-19, chosen by the owner (PLA-417). Not yet shown on the phone.
Amended by [0129](0129-the-holds-serve-only-their-own-request.md): the hold serves only the
held size, and `jumbo-mb` no longer turns on the ml433 cage hold.

## Context

- **The reservation.** RDR2.exe reserves 8,960 MB of address space in one piece
  (`[jumbo#4]`, 0x230000000, unhinted). With the launcher alive, only the band above the
  furniture ceiling, [0x73ffff0000, 0x7c00000000), has room for it.
- **The failure.** In run `20261019T155050` the band held no gap that large (largest 7,851 MB):
  - a 2 GiB CEF PartitionAlloc pool sat at 0x7800000000 (the plain-slot walk, madeira-unix
    `virtual_ios.c` "task#29 CEF plan C");
  - two 256 KiB host regions sat at 0x76461c0000 and 0x7a6ab40000.

  The reservation failed (`[mmap-place] NO GAP FITS`); RDR2.exe showed "exited unexpectedly"
  and ended. In the other plays the CEF pools happened to land elsewhere.
- **The existing mechanism.** The runtime can already hold one hole from boot for a title
  (`jumbo-mb`, Madeira ml996/997, used by The Witcher 3):
  - the hole is held PROT_NONE at the top of the largest free hole below FEX's band;
  - a large unhinted reservation that finds no other room gets it.

## Decision

- **The compatibility entry** for `app-1174180` sets the runtime key `jumbo-mb=8960`.
- **A release build now launches with the compatibility default's runtime keys,** never a
  person's (`LaunchSettings.releaseRuntime`). Until now it launched with none.
- **A failed jumbo reservation names its band.** It logs every host region in [0x7400000000,
  0x7c00000000) as `[va-band]` lines (madeira-unix 0168), so the small regions that split it
  get named.
- **No placement rule changes for other titles.** Steering CEF's pools out of the band was
  rejected for now: it changes every CEF title, and the small host regions would still split
  the band.

## Costs and risks

- The held 8,960 MB is address space only (PROT_NONE, no reserve), not memory.
- If RDR2.exe's reservation fits elsewhere, the hold stays unused for the Play. The launcher's
  CEF pools and the runtime's own spills then have 8.75 GB less of the band.
- Another title's compatibility runtime keys now also reach release builds; no other entry
  has any.
