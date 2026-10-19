# 0129: The jumbo hold serves only the title's own reservation, and the cage hold has its own key

**Status:** accepted, 2026-10-19, chosen by the owner (PLA-417); the cage key approved by the
supervisor as a correction of 0126's side effect. Amends
[0126](0126-hold-rdr2s-address-space-from-the-start.md). Not yet shown on the phone. The Witcher 3
was not re-run on the phone.

## Context

In run `20261019T173829` ([evidence](../evidence/2026-10-19-rdr2-whole-launcher-end.md)), two
things about 0126 showed up.

- **The jumbo hold went to the wrong request.** 0126's 8,960 MB hold (`jumbo-mb`, ml996) was taken
  by a CEF renderer's 2 GB pool, because `take()` hands the hold to the first large request that
  fits. RDR2's own 8,960 MB reservation still succeeded above the ceiling, but only because a
  torn-down CEF child had freed its 2 GB pool there.
- **jumbo-mb also switched on the ml433 cage hold.** That hold is 8,191 MB of the guest window at
  0x7200000000, kept for an 8 GB V8/cppgc cage ask. It was reserved for any title with
  `jumbo-mb`. RDR2 never asks for 8 GB, so the hold took half of the 15,232 MB window for the
  whole run. The rest of the window filled at +94 s, and `socialclub.dll` could not map
  ([0128](0128-an-image-maps-above-the-furniture-ceiling-when-the-window-is-full.md)).
  - Before 0126, in run `20261019T161557`, there was no cage hold and the DLL mapped.
  - The Witcher 3 needs the cage hold: it asks for 8 GB, then 32 GB.

## Decision

- **The jumbo hold.** Only a reservation of the held size (`jumbo-mb`) takes it. A larger one
  never fit, so in practice the request must equal the held size. For RDR2 that is its own
  8,960 MB reservation.
  - A smaller request is placed as if there were no hold.
  - The first eight such requests each log `[jumbo-hold] keeping the holdback … from a N MB
    request`.
  - The ml1029 carve (`jumbo-keep-mb`) is unchanged; no title sets it.
- **The cage hold** has its own `madeira.cfg` key, `cage-hold`, and no longer follows `jumbo-mb`.
  - The Witcher 3's cohort entry sets `cage-hold=1` next to `jumbo-mb=32768`, so its holds are as
    before.
  - RDR2 sets only `jumbo-mb=8960` and holds no cage.
  - Without the key, the runtime logs `[cage] no holdback: no cage-hold for this title`.
- **Where:** madeira-unix 0171 and `pp_jumbo_hold.h`, with `tools/tests/test_jumbo_hold.py`.

## Costs and risks

- **A smaller request can fail.** A request that used to fall back on the hold (as the CEF pool
  did) is now placed elsewhere. When nothing else fits, it fails. The `[jumbo]` and `[va-band]`
  lines name it.
- **The Witcher 3 depends on its entry.** Its holds now rest on `cage-hold` in its entry, not
  checked on the phone. Any other title that wants the cage needs the key too.
