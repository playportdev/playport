# Finished plans

Completed plan runs are removed from the tree; the first cleanup was 2026-10-06.
Each is in git history (`git log --diff-filter=D -- docs/plans/ docs/PORTAL2-PLAN.md`
names the commit; `git show COMMIT^:PATH` prints the plan). Outcomes live in the
linked decisions and evidence. This is a historical index, not an active plan or
backlog: Linear tracks remaining work; [active plans](README.md) link their issues.

## En Garde!

`plans/2026-09-27-en-garde.md`. Done 2026-09-30: the game plays
([evidence](../evidence/2026-09-30-en-garde.md)); the plan's steps were not needed.

## Steam for games

`plans/2026-09-27-steam-for-games.md`. Phase 1, gbe_fork's `steam_api` in place of
the game's ([evidence](../evidence/2026-09-27-gbe-steam-api-build.md),
[ARCHITECTURE.md](../ARCHITECTURE.md), "For games"); phase 2, SteamStub 3.1 x64
removed; phase 3, achievements and stats read and synced; phase 4, Steam Cloud.

Open: phase 3 has sent no unlock yet. Phase 5 (encrypted app tickets) is done
in the [finished store game sign-in plan](#games-sign-in-to-their-store), step 2
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

## Guest address-space exhaustion

`plans/2026-10-06-guest-va-exhaustion.md`. Done 2026-10-06: madeira-unix 0082
makes the clamped scan escape above the ceiling; 0083–0085 remove the unused CEF
holds and steer reserve-only arenas from their first allocation. Death's Door
runs into gameplay, with Hollow Knight, Portal 2 and (on the final IPA, disk cache
off) The Witcher 3 as regressions. [Evidence](../evidence/2026-10-06-guest-va-exhaustion.md)
holds the two IPA hashes and results. The plan's header understated the final
Witcher check; the evidence records it.

Separate residuals were not part of that fix: warm disk-cache crashes (PLA-76,
with the games' PLA-42/PLA-43 records), low-VA executable placement and the jumbo
hold/steering overlap (PLA-75's VA audit). Death's Door's current result is PLA-46.
No new phone play was performed while removing the plan.

## Games sign in to their store

`plans/2026-10-06-store-game-auth.md`. The implementation run finished
2026-10-07; release was handed to the owner, not shipped. Epic exchange codes,
ownership tokens, JSON manifests and the URL panel (0059, 0064), Steam encrypted
and live session tickets (0017, 0062), and the local GOG Galaxy service (0063)
landed with their runtime fixes. Snakebird's EOS signs in, Valheim signs in to
PlayFab on DXMT with a server-checked ticket, and Moonscars' Galaxy SDK signs in.
[Final gates](../evidence/2026-10-07-store-game-auth.md),
[NSI follow-up](../evidence/2026-10-07-nsi-adapters.md) and
[Epic deployment-ID follow-up](../evidence/2026-10-07-epic-deployment-id.md)
record results, IPA hashes and limits. The full design and numbered steps remain
in git history; deleting the plan does not claim every follow-up is complete.

**Release handoff:** [PLA-74](https://linear.app/playportdev/issue/PLA-74) tracks
0.4.0 notes, the release build and draft; the release app is the owner's sign-off
([decision 0068](../decisions/0068-release-owner-signoff.md)), not a replay of these gates.
**Open implementation/checks:** PLA-50 (full SSPI port), PLA-41 (JWE), PLA-39
(Among Us), PLA-54 (Monster Train), PLA-59 (Static-body diagnostic gate), PLA-60
(GOG offline queue, split SDK and writes), PLA-62 (Steam session and sign-out),
PLA-63 (pool-image unmap), PLA-64 (i386 URL opener and manual checks), PLA-65
(Vulkan shared video; keep Valheim on DXMT). PLA-57, PLA-58, PLA-61 and PLA-71
have their completed fixes in Linear. Store import/install gates and cloud
follow-ups remain in PLA-80 ([PC import, GOG and Epic](#pc-import-gog-and-epic)).

## OpenGL through Zink

`plans/2026-10-11-opengl-zink.md` ([PLA-162](https://linear.app/playportdev/issue/PLA-162)). Done
2026-10-11 on branch `dev/pla-152-gdi-windows`. Windows OpenGL games run on Mesa's Zink over
KosmicKrisp, built for iOS from the KosmicKrisp tree and reached through win32u's EGL backend and
Wine's opengl32 unix thunks, at OpenGL 3.3, for x86-64 and i386
([ARCHITECTURE.md](../ARCHITECTURE.md#opengl)).
- **Decisions:** [0087](../decisions/0087-opengl-through-zink-on-the-host.md) (the host-side route,
  the 3.3 ceiling), [0088](../decisions/0088-opengl-window-surfaces-and-pacing.md) (surfaces at the
  first make-current, the layer handed between windows, the game layer's frame limit) and
  [0089](../decisions/0089-opengl-i386-route-gate.md) (the i386 gate: 8.42 ms against 16 ms, so the
  host-side route serves i386).
- **Evidence:**
  - [the frameworks](../evidence/2026-10-11-mesa-gl-ios-build.md);
  - [the route](../evidence/2026-10-11-opengl-zink-route.md);
  - [WGL completeness](../evidence/2026-10-11-opengl-wgl-completeness.md), where Neverwinter Nights:
    Enhanced Edition reaches gameplay at about 50 FPS;
  - [i386](../evidence/2026-10-11-opengl-i386.md);
  - [GoldSrc](../evidence/2026-10-11-opengl-goldsrc.md): Counter-Strike reaches de_dust2 at 59.7 FPS
    against the 60 limit, and Half-Life reaches c1a0. That run also needed `patches/madeira-unix`
    0117, a WoW64 image-placement fix.
- **Not carried out:**
  - Chunk 0, a "not supported yet" message, was skipped by the owner.
  - The Isaac and Geometry Dash proxies are not on the test account.
  - DDNet and Teeworlds are not on the test account either.
- **Open, in Linear:**
  - PLA-181: custom border colours, off by default.
  - PLA-184: a crash when an MSAA context is rebound.
  - PLA-186: the in-game screenshot finds no frame on KosmicKrisp.
  - PLA-189: persistent maps on i386.
  - PLA-164: the GoldSrc `-soft` fault.
  - The titles' own issues: PLA-22, PLA-25, PLA-31, PLA-32, PLA-183, PLA-187.
  - The owner's review of the Mesa GL notices edit (`build/app-notices.json`, part `MesaGL`) was
    still pending when chunk 1a ended.

## PC import, GOG and Epic

`plans/2026-10-06-pc-import-gog-epic.md` ([PLA-80](https://linear.app/playportdev/issue/PLA-80);
implementation PLA-14, PLA-15, PLA-16). Implemented 2026-10-06 and merged; removed 2026-10-13
with its remaining phone checks and deferred scope handed to PLA-80.
- **Phase 0:** the store-neutral core `app/ContentKit`, store identity on catalogue, library,
  queue and routes, Settings › Accounts (decisions
  [0057](../decisions/0057-store-identity.md), [0058](../decisions/0058-store-sessions.md)).
- **Phase 1, Local import:** a folder or `.zip` from Files becomes a Local game; a store's launch
  record in the folder only gives the executable and arguments. Installers are not run (1.5
  dropped by the owner).
- **Phase 2, GOG** (`app/GOGClient`) and **Phase 3, Epic** (`app/EpicClient`): sign-in, library,
  install, update, verify and repair; Epic titles that need online sign-in or another launcher are
  refused. Epic online sign-in (3.6) was later done in
  [games sign in to their store](#games-sign-in-to-their-store).
- **Evidence:** [PC import and GOG](../evidence/2026-10-06-pc-import-and-gog.md),
  [Epic Games](../evidence/2026-10-06-epic-games.md); the Epic update check fix
  ([PLA-69](../evidence/2026-10-13-epic-update-check.md)).
- **Open, in PLA-80:** phone checks of a `.zip` import, a hand pick in Files, the Executable and
  Name rows and icon art; GOG repair and uninstall; Epic update, repair and uninstall. Deferred:
  the "Run with Steam's game ID" hint (1.2), GOG and Epic cloud saves (2.4, 3.7). GOG Galaxy
  queue, split SDK and writes are PLA-60; the Local import's exe pick and its `_CommonRedist`
  are PLA-322 and PLA-323.

## Runtime DLL coverage

`plans/2026-10-07-runtime-dll-coverage.md` ([PLA-78](https://linear.app/playportdev/issue/PLA-78)).
Done 2026-10-08, merged (`5fc71ff`); removed 2026-10-13. The runtime stages every Wine module
Proton ships, for arm64ec, aarch64 and i386 (16-bit included), selected from
`build/generated/wine-pe-*.tsv` with Playport's replacements winning; no census gate.
- **Decisions:** [0070](../decisions/0070-wine-modules-proton-parity.md),
  [0071](../decisions/0071-wine-modules-full-proton-set.md),
  [0072](../decisions/0072-seed-wic-registration-64-bit-classes.md) (WIC's run-time registration in
  the seed).
- **Evidence:** [Proton DLL parity](../evidence/2026-10-08-proton-dll-parity.md) (inventory against
  Proton, sizes, phone checks), [WoW64 registry](../evidence/2026-10-08-wow64-registry.md).
- **Done since, elsewhere:** Wine Mono ships (PLA-125, [0077](../decisions/0077-ship-wine-mono.md));
  DXVK's i386 `d3d11`, `dxgi` and `d3d10core` ship (PLA-150).
- **Open, in [PLA-324](https://linear.app/playportdev/issue/PLA-324):** Proton's own components
  (fonts, Gecko, vkd3d-proton i386, dxvk-nvapi, ICU, speech data) wait for the owner; the census,
  export catalogue, page warnings, feature confirmations and IPA deflate are optional. Wine Mono's
  size is PLA-155.

## Testing reported games without owning them

`plans/2026-10-07-compat-testing-without-owning.md` ([PLA-12](https://linear.app/playportdev/issue/PLA-12)). Closed 2026-10-13 in the
compat speedrun's triage (sweep 15a): every reported title has its own Compatibility issue, so
the umbrella tracked nothing they do not.
- **The failure classes it named:**
  - class 0 (i386 `opengl32`, PLA-107) and class F (detection, PLA-9) are fixed;
  - class A (OpenGL) runs through Zink (PLA-162);
  - class C (i386 D3D10/11) is built;
  - class E (launchers) is [PLA-266](https://linear.app/playportdev/issue/PLA-266) under the
    [launcher plan](2026-10-12-launchers.md).
- **Its unbuilt tracks are issues of their own:**
  - [PLA-316](https://linear.app/playportdev/issue/PLA-316): `pp compat profile`;
  - [PLA-317](https://linear.app/playportdev/issue/PLA-317): free-licence Add to library;
  - [PLA-318](https://linear.app/playportdev/issue/PLA-318): the probe set;
  - [PLA-33](https://linear.app/playportdev/issue/PLA-33): the game's own logs in Report a problem;
  - [PLA-319](https://linear.app/playportdev/issue/PLA-319): the release detailed-log switch, decided by the owner, not scheduled;
  - [PLA-11](https://linear.app/playportdev/issue/PLA-11): LiveContainer and Madeira A/B.

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

A source reading on 2026-10-05 (branch `research/extended-memory`, not merged)
added three points:

- A SideSign fix was offered upstream (SideStore/SideSign#4, linked from
  #1616). It puts the capability in the free features and sends the
  `bundleIdCapabilities` request GetMoreRam sends.
- Impactor asks for every capability named in the binary's entitlements.
- `PlayportJIT.appex` is signed with the memory entitlement too, so a SideStore
  install without it lowers both processes' limits.

The runtime alternative that needs no entitlement is now
[the donor-memory plan](2026-10-12-donor-memory.md) (PLA-216).
