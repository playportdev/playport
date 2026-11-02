# 0173: Rockstar's launcher, and so RDR2, runs KosmicKrisp's command-memory retire path by default

**Status:** accepted, 2026-10-31, by the owner (PLA-476, PLA-364), without a further phone run. Amends
[0169](0169-social-club-on-rockstars-cef-in-the-stock-cef-layout.md)'s costs (B alive for the whole play).
[Evidence](../evidence/2026-10-30-rdr2-kk-audio-diagnostics.md#l24-kosmickrisp-cmd_retire-with-the-allocator-bound),
[plan](https://linear.app/playportdev/issue/PLA-476).

## Context

- Under 0169 the game's own Social Club helper stays alive, and RDR2's cabin load peaked at 7,960 / 8,006 MB of
  8,192 (l20–l21). On the chunk-4 dev IPA `61b54bfd…` with no keys, one of two runs held the cabin
  (`.work/ui-runs/20261031T195324-rdr2-p605m1`) and one exited about 1.5 min after the cabin's first frame at a
  7,766 MB peak (`…/20261031T200932-rdr2-p605m2`; I: jetsam).
- With `MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes` (mesa 0132–0135) l24–l25 held the cabin to first-frame+600
  at 7,175 / 7,250 MB, about 0.7–0.8 GB below l20–l21, at equal fps; Hollow Knight's interleaved pairs were equal
  in fps, tail and CPU.

## Decision

- `PublisherLauncher.rockstar`'s graphics environment carries `MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes`, so
  its Open and every Play that starts it (RDR2) run the retire path and the finer large-BO classes, in both builds
  (a release build keeps the launcher's graphics environment). A dev build's own `MESA_KK_EXPERIMENTAL` for the game
  replaces it. Every other title is unchanged: the option stays opt-in by name.

## Costs and risks

- Not run on the phone in this form (the owner's call: reopen PLA-605 if RDR2's cabin load fails again). l24–l25
  set the option through the game's Graphics options row, which reaches the same session environment.
- Allocators still hold about 0.9 GB at the step (capped at 112); the census after the step did not run (0135 gap).
