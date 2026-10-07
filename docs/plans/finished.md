# Finished plans

Plans that were carried out were removed from the tree on 2026-10-06. Each is in
git history (`git log --diff-filter=D -- docs/plans/ docs/PORTAL2-PLAN.md` names the
commit; `git show COMMIT^:PATH` prints the plan). What each one settled is in the
decisions and evidence it links; the items still open are listed here so they are
not lost.

## En Garde!

`plans/2026-09-27-en-garde.md`. Done 2026-09-30: the game plays
([evidence](../evidence/2026-09-30-en-garde.md)); the plan's steps were not needed.

## Steam for games

`plans/2026-09-27-steam-for-games.md`. Phase 1, gbe_fork's `steam_api` in place of
the game's ([evidence](../evidence/2026-09-27-gbe-steam-api-build.md),
[ARCHITECTURE.md](../ARCHITECTURE.md), "For games"); phase 2, SteamStub 3.1 x64
removed; phase 3, achievements and stats read and synced; phase 4, Steam Cloud.

Open: phase 3 has sent no unlock yet. Phase 5 (encrypted app tickets) is done
in the [store game sign-in plan](2026-10-06-store-game-auth.md), step 2
([decision 0017](../decisions/0017-encrypted-app-ticket.md), accepted); a game
whose online login checks the ticket is still to be found.

## Wine from Valve's Proton branch

`plans/2026-09-27-wine-on-proton.md`. Done 2026-09-28: the base stays WineHQ and
Valve's wanted commits are `patches/wine-valve`
([decision 0018](../decisions/0018-valve-wine-as-a-series.md),
[evidence](../evidence/2026-09-28-wine-proton-rebase.md)); 0049 later moved the
picks to Valve's bleeding-edge.

## Runtime risks

`plans/2026-09-27-runtime-risks.md`. Settled by decisions
[0019](../decisions/0019-jit-pool-sized-from-the-limit.md),
[0021](../decisions/0021-fex-ordering-per-game.md),
[0023](../decisions/0023-in-process-sync-stays-off.md),
[0024](../decisions/0024-dxvk-picks-its-compiler-threads.md) and
[0026](../decisions/0026-a-dev-test-title-for-the-jit-pool.md), with the
2026-09-28 evidence (launcher stress, mode A, FEX band, runtime limits, server
sync, StikJIT pin cost). Open when the plan was removed:

- JIT across iOS updates: DEVICE.md names the tested iOS versions.
- The JIT pool: the .NET (Mono) stress; each cohort title's high-water mark;
  exhaustion with its own outcome instead of a crash.
- In-process sync: a measured per-frame server-call count before it is
  reconsidered (0023).
- Address space: a DXVK game past the menu with default thread counts (Hollow
  Knight on Vulkan froze in the menu or at Start Game).
- Constants found by trial: mode A explained in ARCHITECTURE.md, the self-check
  in the result event.
- The memory entitlement: Settings shows the limit, and a low limit gives a clear
  message instead of a jetsam kill (see also
  [the signers plan](#increased-memory-limit-through-sidestore-getmoreram)).
- Smaller items in Wine's `virtual_ios.c` and `signal_arm64_ios.c`: W+X requests
  silently losing WRITE; x18 trampolines out of branch range left to fault; the
  4096-entry anonymous-alias table; split-lock atomics that are not atomic
  (logged, a known limit). [Runtime limits](../evidence/2026-09-28-runtime-limits.md)
  records what no measured title reaches.

## The gamepad-first UI

`plans/2026-09-28-gamepad-ui.md`. Done on the phone with the driver's presses
([decision 0034](../decisions/0034-a-gamepad-first-ui.md),
[evidence](../evidence/2026-09-30-gamepad-ui.md)). Open: 0034's "Costs and open
items", which need a person at the phone.

## Performance follow-up after the runtime audit

`plans/2026-09-28-performance-follow-up.md`. Closed 2026-09-30: 720 rows at 60 FPS
is every game's default; FEX MaxInst then stayed at 5000 (0055 later made it 500);
release measurement producers are off in the release app; the Wine PE set is
staged without DWARF. Evidence: `2026-09-29-hk-gameplay-baseline`,
`2026-09-29-pe-debug-strip`, `2026-09-29-release-counters`,
`2026-09-30-hk-maxinst`, `2026-09-30-witcher3-counters-maxinst`,
`2026-09-30-witcher3-small-pool`. Open: helper QoS (step 4, not run); the pool's
sizing by a long-session capacity test; The Witcher 3's dbghelp start-up and a
symbolised `--cpu-prof` profile on the stripped PE set; the `[xp-api]` sampler,
which no longer finds the game process's PE counters. The
[performance review](2026-09-30-performance-review.md) carries on from here.

## Self-contained JIT setup for a tester

`plans/2026-09-30-pairing-file-for-testers.md`. Same-phone pairing and the
automatic setup (Pair again, then Play) passed on iOS 27.0
([decision 0033](../decisions/0033-on-device-pairing.md),
[evidence](../evidence/2026-09-30-on-device-pairing.md)). Open: a first run with no
pairing, and the release variant, on the phone. Risks it named: the credentials
over LocalDevVPN rather than Wi-Fi onboarding; `beginBackgroundTask`'s finite
time; the pairing protocol changing in an iOS point release; re-signing changing
Keychain access groups, so setup must be able to make new credentials.

## Open-source publication and the first IPA

`plans/open-source-release.md`. Done: the source is public at
`playportdev/playport` and releases are made by `pp release`
(decisions [0037](../decisions/0037-ipas-on-github-releases.md) to
[0043](../decisions/0043-published-as-the-playport-authors.md) and
[0050](../decisions/0050-release-reuses-the-build.md);
[DISTRIBUTION.md](../DISTRIBUTION.md) is the procedure). Not for now: a donation
page (0039); when one comes, read the processor's terms for what it shows of the
recipient's name (0043).

## Dependency strategy

`plans/2026-10-05-dependency-strategy.md`. Order rows 1–3 done
([0049](../decisions/0049-latest-pins.md),
[0052](../decisions/0052-madeira-reconciliation.md),
[0053](../decisions/0053-carrying-model.md)); rows 4 and 5 superseded by
[0054](../decisions/0054-madeira-frozen.md), Madeira frozen at `8c050d0`. The
`madeira-main` branch stays unmerged as a reference. Open: a public mirror of the
frozen commits needs a new decision (0054 says why there is none).

## Portal 2

`docs/PORTAL2-PLAN.md`. Milestones 1–3 reached and the branch closed by the owner
on 2026-10-05: menu, gameplay by pad, portals, save and load, Steam Cloud, audio
([decision 0047](../decisions/0047-i386-titles-on-vulkan.md);
[gameplay evidence](../evidence/2026-10-04-portal2-gameplay.md) and the other
`portal2-*` records). `build/guest32/` keeps the early 32-bit experiment's notes.
Open for "fully playable":

- Fonts: the owner's distribution review of the Tahoma fallback faces
  (`build/app-notices.json` is `unreviewed`) before an IPA is given to anyone.
- Progress past one chamber through an elevator, by a person playing.
- Headroom under heat, hitches and footprint growth: moved to
  [the Proton alignment plan](2026-10-05-proton-arm64-alignment.md#portal-2-performance-follow-ups).
- The hint glyph follows the last device used; a retired window's final teardown
  has not been seen on the phone.

## Removed without being carried out

These plans were removed on 2026-10-06 without being carried out. Their open
items are below.

### Hollow Knight leads from the first GPU captures

`plans/2026-09-29-hollow-knight-gpu-leads.md`. These were leads from King's Pass
GPU captures and Metal validation on DXMT
([metal-tools-without-a-mac](../evidence/2026-09-29-metal-tools-without-a-mac.md)).
None is a measured cause. They are DXMT-specific, and the
[Vulkan performance plan](2026-10-06-vulkan-performance.md) compares KosmicKrisp
captures of the same scene with DXMT's. Open:

- **NaN interpolants.** Shader validation reported 52,970 `INF or NAN detected in
  interpolant` findings from 12 vertex shaders, in nearly every frame. Each is
  either the game's own maths or a fault in DXMT's translation.
- **Redundant Metal state and unused bindings** set by DXMT's encoder: about 40
  redundant stencil-reference sets a frame, and 3–4 unused buffer bindings per
  draw. The CPU cost is not measured.
- **Grab-pass copies.** There are four full-screen colour copies a frame (15 % of
  GPU time), and the colour and depth reloads after them take 41 %. That share
  needs counters.
- **Clear-only depth passes:** two a frame, about 0.05 ms.
- **Frames of exactly 25.01 ms** (501 of 8,819) and 29.18 ms at a 60 FPS cap,
  measured with capture on. The [performance review](2026-09-30-performance-review.md)
  (A2) suspects the limiter's sleep.
- **Fences:** 168 fence waits a frame, and whether they leave the GPU idle
  between encoders.

### Increased Memory Limit through SideStore (GetMoreRam)

`plans/2026-10-01-memory-entitlement-signers.md`. This was a research plan from
reading the source. Nothing was signed or installed. SideSign keeps
`increasedMemoryLimit` out of a free team's features, so SideStore never turns
on the App ID capability (SideStore issue #1616).
[DISTRIBUTION.md](../DISTRIBUTION.md#6-signing-tools-and-the-memory-limit) and the
README recommend signers that keep the capability, and GetMoreRam for SideStore.
None of it has been tested here. Open:

- whether GetMoreRam turns the capability on for a free team's App ID that
  SideStore made, and whether a SideStore reinstall then carries it;
- whether it survives SideStore's weekly refresh, and a refresh after expiry;
- whether the JIT helper extension is still signed, and every Play still gets JIT;
- AltStore Classic 2.3 on a free team.

Each result goes in an evidence record and in DISTRIBUTION.md's signer table.
