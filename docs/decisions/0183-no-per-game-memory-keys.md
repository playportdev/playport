# 0183: No per-game memory keys

**Status:** accepted, 2026-11-12, by the owner (the grilling session behind spec
[PLA-835](https://linear.app/playportdev/issue/PLA-835)). Amends
[0180](0180-elastic-reservations.md), [0163](0163-the-witcher-3-keeps-yield.md),
[0169](0169-social-club-on-rockstars-cef-in-the-stock-cef-layout.md),
[0126](0126-hold-rdr2s-address-space-from-the-start.md) and
[0129](0129-the-holds-serve-only-their-own-request.md). Supersedes 0180's rule that The Witcher 3
1.32's cohort entry keeps `jumbo-mb=32768 cage-hold=1` until a phone run without them reaches Kaer
Morhen, and the "Mechanisms kept" of 0180 and of its spec
[PLA-799](https://linear.app/playportdev/issue/PLA-799). PLA-835's tickets build it; until a ticket
lands, the keys it removes stay as built, and no part of it is shown on the phone yet.

## Context

- **Every memory key was set after its game had failed for players.** A game nobody here has tried
  gets no key, so it fails the same way, and a player is the one who finds the missing key.
- **Keys interact.** [0153](0153-rdr2s-settings-are-every-games-defaults.md) made RDR2's 8,960 MB
  hold every game's, and [0179](0179-the-jumbo-hold-is-rdr2s-own-again.md) found it starving
  Mewgenics' 1 GiB pools. A key decides by title what should depend on what the game does.
- **0180 removed two keys and kept the rest.** Elastic reservations place The Witcher 3 4.x's 64 and
  32 GiB asks and RDR2's 8,960 MB ask with no key. The Witcher 3 1.32 kept its keys, since its
  phone run without them stalled on Loading, and the jumbo hold, the cage hold and the Social Club
  layout's slots stayed so that a title could get a key back.
- **Memory keys on 2026-11-12:**
  - The Witcher 3 1.32's cohort entry: `jumbo-mb=32768 cage-hold=1` (0129).
  - RDR2's compatibility entry: `vram-mb=2304 env.PLAYPORT_VK_HEAP_MB=2304`
    ([0142](0142-rdr2-owner-test-defaults-heap-size-semaphores-and-afp.md) as amended), and
    `everyGame`'s fixed `env.PLAYPORT_VK_HEAP_MB=3072` (0153).
  - Rockstar's launcher: `env.PLAYPORT_SC_LAYOUT=1`, which holds the Social Club layout's ranges,
    about 30 GiB, from boot in every Play it starts (0169), and its own `jitPoolMB`.
  - A cohort entry's `memoryMB`: a Play on a phone whose limit is lower is refused.
  - Proposed: per-title JIT pool sizes for RDR2 ([PLA-549](https://linear.app/playportdev/issue/PLA-549))
    and SANABI ([PLA-810](https://linear.app/playportdev/issue/PLA-810)).

## Decision

- **No per-game memory key.** No compatibility entry, cohort entry, launcher or `everyGame` default
  carries a key that reserves, places, commits or sizes guest memory: an address-space hold or its
  size, a layout switched on by title or launcher, a video memory or heap figure, a title's JIT pool
  size, a stored memory need. Every game, 32-bit and 64-bit, runs under one memory layout.
- **An exception is decided by a property the runtime observes, never by title or launcher.** A
  hinted ask, an aligned ask, a verified Rockstar bootstrap's hash and an image's large-address-aware
  flag are such properties; 0180's never-shrunk asks are exceptions of this kind.
- **A new exception needs its own decision record**, saying why no general rule replaces it.
- **`avail-phys-cef-mb` is not a per-game key and stays.** It applies to the Social Club helper
  process in every game ([0168](0168-social-clubs-helper-is-told-little-available-memory.md)).
- **What replaces each key** (PLA-835's tickets):
  - The Witcher 3 1.32's keys: the cause of its Loading stall confirmed on the phone, then natural
    alignment for very large reservations ([PLA-837](https://linear.app/playportdev/issue/PLA-837),
    [PLA-838](https://linear.app/playportdev/issue/PLA-838)). The keys go when that rule plays it,
    not after a run without any rule.
  - The jumbo hold, the cage hold and the short-reserve path are deleted with their keys and
    tests; the configuration check refuses the keys, and a check fails any entry, cohort title,
    launcher or `everyGame` default that carries a memory key
    ([PLA-843](https://linear.app/playportdev/issue/PLA-843)). No title can get a hold back.
  - The Social Club layout engages when what the Play starts is a Rockstar bootstrap verified by hash,
    not when Rockstar's launcher starts the Play
    ([PLA-840](https://linear.app/playportdev/issue/PLA-840); the owner's decision there of
    2026-11-12): a game whose install folder holds one (RDR2's Steam copy: `PlayRDR2.exe` and
    `Redistributables/Rockstar-Games-Launcher.exe`), or the launcher's Open of a verified
    `Launcher.exe`. The helper itself cannot decide it: it is in the shared prefix, missing until the
    launcher's first run, and the layout is decided before the runtime starts (0169's amendment note).
    Any other Play holds no Social Club range, and the configuration check refuses an
    `env.PLAYPORT_SC_LAYOUT` key. The layout shrinks to the anchors its window forces,
    and the rest is claimed at the helper's first ask; ELF_META2 and RDR2's 8,960 MiB game hold go
    ([PLA-841](https://linear.app/playportdev/issue/PLA-841),
    [PLA-842](https://linear.app/playportdev/issue/PLA-842)).
  - A 32-bit game's WoW64 window is placed by the elastic policy
    ([PLA-839](https://linear.app/playportdev/issue/PLA-839)). It stays 4 GiB for every image (the
    owner on PLA-839, 2026-11-12): FEX zero-extends a guest pointer over all of it, and
    large-address-aware only bounds allocations inside it, as before.
  - One video figure from the phone's memory plan row
    ([0105](0105-memory-defaults-per-phone.md), [0106](0106-8gb-row-in-full-and-vulkan-plan-default.md))
    for every game, in place of RDR2's entry and `everyGame`'s fixed heap
    ([PLA-845](https://linear.app/playportdev/issue/PLA-845)). The plan's V is DXGI's report and
    KosmicKrisp's heap size and budget; the configuration check (PlayportKit `TitleConfig`) refuses
    the plan's keys (`totalphys`, `vram-mb`, `vulkan-vram-plan`) and its variables
    (`MADEIRA_TOTAL_PHYS_MB`, `PLAYPORT_VRAM_MB`, `PLAYPORT_VK_HEAP_MB`, `PLAYPORT_VK_BUDGET_MB`) as any
    title's key. The shared madeira.cfg's keys still win over the plan, the same in every game. RDR2
    needs less than the 12 GB row's 3,072: its run l11 was killed on Story's first load there
    ([0142](0142-rdr2-owner-test-defaults-heap-size-semaphores-and-afp.md)'s amendment), and it was
    proven on 2,304. So that row's V is 2,304 for every game; no phone has run the row since, and a
    12 GB phone's check of it is owed. The 8 GB row's 2,048 is under RDR2's figure already.
  - One JIT pool, the same size in every Play, whose untouched pages cost nothing, in place of
    per-title sizes ([PLA-846](https://linear.app/playportdev/issue/PLA-846),
    [0184](0184-one-jit-pool-whose-untouched-pages-cost-nothing.md)).
  - Play is never refused for a stored memory figure: `memoryMB` goes, and a game ended for memory
    has its page say so at the next app start
    ([PLA-847](https://linear.app/playportdev/issue/PLA-847)). Since PLA-847 nothing refuses a Play
    for memory, and the memory-kill note, that Play's peak and the limit, is an observation of the
    Play, never a stored requirement or a reason to refuse or size the next one.
- **Unchanged.** Per-game keys that are not about memory (`FEX_HOSTFEATURES`, the graphics backend,
  controls); the memory plan's table (0105), but for the 12 GB row's V (PLA-845's rule, above), and
  the donor pool's sizing; the iOS low hold at exec
  in every Play; madeira-unix 0236's refusal of V8's reserve ladder, which runs before the elastic
  policy.

## Costs and risks

- **No per-title way out.** A game the general rules do not serve fails until a rule serves it or a
  decision record adds an exception by property. A key goes only in the ticket whose phone gate
  plays its title without it: the forced 8 GB row, 3 to 5 minutes into gameplay, no refusal from the
  elastic policy, no helper death.
- **A fix for one game changes every game's layout.** Hollow Knight's first-frame+10 gates each
  runtime change, and each milestone's sweep plays the problem titles on one IPA with games that
  already worked (Death's Door, Portal 2, Kingdom Come: Deliverance).
- **The Social Club layout follows the bootstrap's hash.** A bootstrap Playport has not verified (a
  Steam update of `PlayRDR2.exe`, a launcher self-update) gets no layout until its hashes join the
  table; a dev build logs them. The helper keeps [0150](0150-dev-single-process-social-club.md)'s
  guard for single-process.
