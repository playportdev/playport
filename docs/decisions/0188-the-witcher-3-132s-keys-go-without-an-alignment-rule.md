# 0188: The Witcher 3 1.32's memory keys go without an alignment rule

**Status:** accepted by the owner, 2026-11-13. Built ahead of acceptance by
[PLA-838](https://linear.app/playportdev/issue/PLA-838) (commit `ab4a6b16`, spec
[PLA-835](https://linear.app/playportdev/issue/PLA-835)). Supersedes one line of
[0183](0183-no-per-game-memory-keys.md), "The keys go when that rule plays it, not after a run without
any rule", for The Witcher 3 1.32; the rest of 0183 stands. 0183's line already superseded
[0180](0180-elastic-reservations.md)'s rule that 1.32 keeps its keys.

## Context

- **0183 tied 1.32's keys to a rule.** Its cohort entry carried `jumbo-mb=32768 cage-hold=1`
  ([0129](0129-the-holds-serve-only-their-own-request.md)), because a run without them stalled on
  Loading (`pla802-witcher3`) and a run with them reached Kaer Morhen (`pla802-witcher3-keys`), one
  run each. 0183 let the keys go only once natural alignment for very large reservations played it
  ([PLA-837](https://linear.app/playportdev/issue/PLA-837) to confirm the cause, PLA-838 to build the
  rule).
- **PLA-837 found another cause.** On IPA `bee5165c` every 1.32 run stalled on Loading, the cohort's
  keys included (`pla837-keyed-control`, `pla837-keyed-newgame3`), so placement did not decide it. The
  copy, 1.32 (branch `classic`) downloaded over 4.x, failed its page's Verify on one file,
  `content/metadata.store`, the index of the game's content bundles (`pla837-verify`), and the page's
  Repair restored it (`pla837-repair`). On the repaired copy with no key
  (`$PLAYPORT_BUILD/ui-runs/pla837-nokey-repaired`: IPA `671ca956`, the forced 8 GB row) the 8 GB pool
  landed at `0x707c000000`, the 32 GB pool at `0x73ffff0000`, the unaligned address of the old stall,
  and the 2 GB pool at `0x727c000000`; Continue loaded Kaer Morhen, and the walk ran at 18 to 23 fps to
  first-frame+145.
- **So the stall was a corrupt file**, which [PLA-850](https://linear.app/playportdev/issue/PLA-850)
  follows up, not where the pools land. An alignment rule would answer a cause the runs ruled out, and
  0183 allows an exception only for a property the runtime observes, which 1.32 has not shown it needs.

## Decision

- **The Witcher 3 1.32 has no memory key, and no natural-alignment rule is written for it.** Its
  pools are placed as any game's, by [0180](0180-elastic-reservations.md)'s elastic policy.
- **The host replay keeps the no-key run's pools** as a regression case
  (`tools/tests/fixtures/elastic/witcher3-132-phone.json`, `tools/tests/test_elastic_reserve.py`):
  placed where the phone put them, whole, with no lend or short grant.
- **Its phone gate is 0183's**, the run above repeated on the milestone sweep's IPA (PLA-838); until it
  has run, 1.32 without keys rests on the one repaired-copy run.

## Costs and risks

- **One run.** The no-key result is one Play on a repaired copy; the stall it replaces was one Play
  too. Whether the old `pla802-witcher3` copy also had a bad `metadata.store` is unknown: no Verify ran
  then.
- **No per-title way back.** If 1.32 turns out to need aligned pools on some layout, it fails until a
  rule by property is decided (0183); the replay fixture shows a change in where its pools land.
