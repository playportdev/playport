# 0180: Elastic reservations: an untouched reservation tail is lent when a placement fails

**Status:** accepted, 2026-11-02, by the owner: the fix must be general, with no per-game
settings, and per-game address-space keys go where the general rule makes them unnecessary
(spec [PLA-799](https://linear.app/playportdev/issue/PLA-799); Mewgenics
[PLA-769](https://linear.app/playportdev/issue/PLA-769), GitHub #66; The Witcher 3 4.x
[PLA-452](https://linear.app/playportdev/issue/PLA-452)). Not yet shown on the phone: the runtime
lands in [PLA-802](https://linear.app/playportdev/issue/PLA-802), its policy module in
[PLA-801](https://linear.app/playportdev/issue/PLA-801). Amends
[0126](0126-hold-rdr2s-address-space-from-the-start.md),
[0129](0129-the-holds-serve-only-their-own-request.md),
[0163](0163-the-witcher-3-keeps-yield.md) (`app-292030`'s row) and
[0179](0179-the-jumbo-hold-is-rdr2s-own-again.md) for the keys it removes. It replaces
madeira-unix 0222's short-reserve path
([evidence](../evidence/2026-10-27-witcher3-short-reserve.md)).
[Evidence](../evidence/2026-11-02-elastic-reservations.md).

## Context

- **The guest's address space is small.** Windows gives a 64-bit process 128 TB of user address
  space. On the phone the guest gets roughly the top 64 GB of the app's 512 GiB map (about 47 GB
  of it usable); the kernel keeps the rest, and no entitlement a free team can sign raises it.
- **Every reservation costs its full size.** The Madeira layer backs each `MEM_RESERVE` with a
  host mapping of its full size. A game that reserves far more than it commits fills the window
  with reservations that hold almost no memory. The next reservation fails with
  `STATUS_NO_MEMORY`; games rarely check it and write through the NULL.
- **Known cases.**
  - Mewgenics (686060) reserves 1 GiB per object-class pool and commits at most 6.9 MB of any.
    On the phone it died at its 34th pool on 0.5.0, and after its 42nd pool, when a 21 MB
    reservation failed, once 0179 removed every game's 8,960 MB hold (run `20261102T152055`).
  - The Witcher 3 4.x reserves 16, 64 and 32 GiB pools; it runs only because its entry sets
    `short-reserve-mb=6144` (madeira-unix 0222).
  - RDR2's `jumbo-mb=8960` and The Witcher 3 1.32's `jumbo-mb=32768 cage-hold=1` pin address
    space for one game each. Each was set after its game failed.
- **The failure is rare.** In 46 executables' phone logs (474 logs), only Mewgenics, The
  Witcher 3 4.x and RDR2's Play (its Social Club helper's 5,119 MB asks) hit a failed placement;
  43 never did.

## Decision

- **Lending only after a placement fails.** While there is room, every reservation gets its full
  size, as today: a game that never runs out keeps identical addresses and timing. When a
  placement fails, the runtime takes back the untouched upper part of the large plain reservation
  with the most lendable room, then retries.
  - Donors are unhinted, reserve-only views of 256 MiB or more, not held, not committed to their
    top.
  - A donor keeps `max(2 × committed height, committed height + 64 MiB)` plus the guard. Its view
    shrinks in Wine's view tracking, and its claim (the size the guest believes it holds) is
    remembered.
- **Short grants with a 32 MiB inaccessible guard.** An unhinted reserve-only ask from 1 GiB up to
  twice the guest window that cannot be placed whole gets a real view sized from free space (half
  the largest gap outside every live claim, minus the guard, rounded to 64 KiB, at least 64 MiB),
  placed top-down below earlier claims, else after lending. The caller is told it got its full
  size, as 0222's short grants do. A larger ask fails as today.
  - Every shortened view and short grant has a 32 MiB `PROT_NONE` guard above it. A game that
    ignores a refused commit faults at its own pool's end, never in a neighbour.
- **Growth in place, and honest refusal.** A commit reaching the guard or the claim beyond it grows
  the view in place, doubling, with a no-overwrite fixed mapping, the guard moving up. When the
  space above is taken, the commit returns `STATUS_NO_MEMORY` and is logged. A commit is matched
  to the view that owns it first, then to a claim covering it; it is never served inside another
  view.
- **Exceptions are decided by property, never by title.** These are never shrunk: hinted asks,
  aligned asks, placeholders and `…Ex` asks with address requirements, `zero_bits`/limited asks,
  commit-at-reserve asks, asks served by a hold (jumbo hold, cage hold), and asks the Social Club
  layout ([0169](0169-social-club-on-rockstars-cef-in-the-stock-cef-layout.md)) routes; its router
  runs first. Chromium/V8 pools, which depend on their exact extents, stay truthful.
- **One log tag** covers lend, grant, grow and refuse, with the address, real size, claim and
  committed height; a refusal also names what blocked growth. Counted, rate-limited, in release
  builds at the level of `[alloc-fail]`.
- **The rule replaces madeira-unix 0222's short-reserve path.** The `short-reserve-mb` key and its
  fixed-N grant go; 0222's ordering, guard semantics and commit matching carry over. From PR #84
  (lean reserves, not merged) it takes the elastic flag on the view, the commit-path check, the
  guard and the overflow line, not its per-title key or fixed size.
- **Keys removed** (in [PLA-802](https://linear.app/playportdev/issue/PLA-802)):
  - The Witcher 3 4.x (`app-292030`): `short-reserve-mb=6144` (0163's row).
  - RDR2 (`app-1174180`): `jumbo-mb=8960` (0126, 0179). Shipped Plays use the Social Club layout,
    which places its own game slot and ignores the key; in six off-layout runs the 8,960 MB
    reservation was placed outside the hold.
  - The Witcher 3 1.32's cohort entry: `jumbo-mb=32768 cage-hold=1` (0129), only after a phone
    run without them reaches Kaer Morhen with its 32 GB ask placed whole, or short with at least
    4 GB usable, and no refused commit. Until that run the keys stay.
- **Mechanisms kept.** The jumbo hold, the cage hold and the Social Club layout's slots stay in the
  runtime, so a title can get a key back without a runtime change.
- **Relation to the PLA-631 chain.** Lending is not PLA-675's reclaim: it never releases a view the
  guest holds, it shortens one, keeps its claim and refuses honestly. `VirtualQuery` on a
  shortened view reports the real view, never the tail beyond it as the guest's (PLA-690).
- **Where:** the policy is madeira-unix 0289's `pp_elastic.h`, a pure header the glue calls
  (PLA-801), replayed against phone traces by `tools/tests/test_elastic_reserve.py`
  (`tools/tests/fixtures/elastic/`). Live claims are the extents promised beyond a shortened view's
  real part. Once a placement has failed, an unhinted reserve-only ask of 256 MiB or more is placed
  outside every live claim while room there allows, so a later pool lands inside an earlier claim
  only in room lending freed. Every ask the Social Club layout's router sees (layout held, verified
  helper) is the layout's, including the helper's 5,119 MB asks it passes through: they fail as
  today.

## Departure from Windows

On Windows a reservation's whole range is the caller's until it frees it, and a commit inside it
fails only for lack of commit charge. Here, under address-space pressure, a reservation's
untouched tail may be lent away, and a later commit there is refused with `STATUS_NO_MEMORY`.

This is accepted because the alternative is worse for the same games: today the next reservation
fails outright and the game writes through NULL. Games that reserve far more than they commit
never reach the lent tail (Mewgenics' pools commit at most 6.9 MB of 1 GiB), and growth in place
serves a pool that does, while the space above is free. A game whose pool still outgrows its room
gets its own out-of-memory path, never another pool's memory.

## Costs and risks

- **A long Mewgenics session can still run out.** About 490 pools fit in the guest's ~47 GB (980
  with a 16 MiB keep floor), against 71 seen in five minutes on a desktop and 2,246 pool classes
  in the executable. The game ignores a refused commit, so that remains a crash, logged as a
  refusal.
- **A refused commit is a new failure mode** for a game that would have committed deep into a
  lent tail. The log names it; the hold keys can come back per title.
- **Elastic reservations cannot create memory:** games that genuinely commit tens of GB are out of
  scope.
- **Open measurements** (closed by PLA-802): RDR2's commit depth into its 8,960 MB pool beyond the
  first minute; a phone log of The Witcher 3 1.32 on this runtime; how a game reacts to
  `VirtualQuery` on a shortened view.
