# Social Club on Rockstar's own CEF: single-process in both builds, no Playport CEF build

**Linear:** [PLA-476](https://linear.app/playportdev/issue/PLA-476). Related:
[PLA-364](https://linear.app/playportdev/issue/PLA-364) (RDR2),
[PLA-475](https://linear.app/playportdev/issue/PLA-475) (0.5.0, held for this),
[PLA-372](https://linear.app/playportdev/issue/PLA-372) (CEF payload distribution, to be cancelled),
[PLA-254](https://linear.app/playportdev/issue/PLA-254) (publisher launchers).

**Status** (resume here; run log is in a PLA-476 Linear comment):

- Branch `dev/pla-476-sc-stock-cef`, unmerged and unpushed (HEAD: see `git log`).
- Chunks 0 and 1 done. Chunk 2 **not passed** ([evidence](../evidence/2026-10-29-sc-stock-cef-probe.md)):
  0224–0226 give the opt-in layout; wine-pe 0055 (early-image replay,
  [PLA-481](https://linear.app/playportdev/issue/PLA-481), Done) is an accepted increment (HK first-frame+10,
  game helper reaches allocator startup). The launcher helper's retained kind-3 view (l2–l6) is no longer kept:
  [decision 0166](../decisions/0166-detach-a-parked-threads-wait-then-unpin-its-view.md) (owner, 2026-10-30)
  detaches a parked thread's alert wait at teardown and frees a view only that wait named (l7). Kept views are still
  never cleared, freed or overwritten by any other path. **Blocker now:** memory: l7 reached Story's loading and
  was ended by iOS at the 8192 MB limit.
- **Measured (l5, 2026-10-30, IPA `b5ee00eb…`, `.work/ui-runs/20261030T104925-rdr2-p476l5`):** only kind 3
  (ELF_META) is kept, as its whole 6400 MiB view, pinned by one parked thread's wait address. It has 72.4 MiB
  committed, highest end 170.5 MiB. Kinds 1, 2, 4, 5 and 6 are freed and held again. The game's helper gets
  kind 1 and then fails **only** on the ELF_META refusal (`chrome_elf.dll failed to initialize`). Story stays on a
  black spinner. Peak 6307 MB, no jetsam. l2's kind 1/5 retention did not recur.
- **Owner decision 2026-10-30 (approved):** a disjoint 1 GiB second ELF_META slot, real
  `[0x79c0000000, 0x7a00000000)` (RW-alias cap slack), for a later helper when kind 3 is owned by another PEB.
  It comes with a slot-aware `ppsc_access` (real-range containment wins, a straddle across real ranges is
  refused, possible metadata overflow is logged; PLA-482). Opt-in layout only; 0132/0143 unchanged. The
  lifetime/quiescence proof stays deferred.
- The Risks stop rule is no longer near-triggered for the l3–l5 shape. 0.5.0 stays held.
- Build-records gap found on the way: [PLA-484](https://linear.app/playportdev/issue/PLA-484).
- **Measured (l6, 2026-10-30, IPA `d9612e9c…`, `.work/ui-runs/20261030T113719-rdr2-p476l6`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l6-the-second-metadata-slot)):** the game's helper gets
  `grant kind=7` (ELF_META2) after kind 1, chrome_elf initialises, and libcef gets kinds 2 and 4. libcef then
  commits at `0x7400002000` (A's kept kind-3 view, base `0x7400000000` in its registers), is refused, CHECKs and
  exits; the game shows Social Club error 17. In A the same commits landed in its own kind 3. Kind 7 is now
  ELF_META2; a refused reserve logs `kind=8`.
- **Ordered queue:** (1) review-fix writer chunk **done** in `ad295c7` (0225–0227, `wine_host.c`, 0055 `Class:`
  `ios-port`, [PLA-482](https://linear.app/playportdev/issue/PLA-482) diagnostics, retained-extent §5 diagnostics;
  [PLA-480](https://linear.app/playportdev/issue/PLA-480) smoke on RDR2 dev defaults, Witcher 3 not installed;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#review-fixes)); its host tests for `pp_sc_vm.h` and
  `pp_sc_access.h` were integrated in `29dfb45`, and review-2 fixes landed in `e3334ec` (IPA `fc42b29e…`, HK
  `.work/ui-runs/20261030T112027`); (2) **done** in `6213817`: madeira-unix 0228, the second ELF_META slot and
  slot-aware access, HK first-frame+10 passed (`.work/ui-runs/20261030T113629-hk-p476l6`) and RDR2 l6;
  (3) superseded by decision 0166 and l7 (the game's helper now gets kind 3 itself); it was: find on the workstation where libcef's `0x7400000000` comes from (libcef RVA `0x1ea580b` and
  the code that sets `R14`) before any new slot geometry, then the remaining chunk-2 gates. Chunk-2 gates after
  l6: the game's helper reaches allocator/browser startup — **partly** (chrome_elf initialises, libcef does not);
  Story cabin — **not passed** (SC error 17, no Story tab); no SC/launcher `NO GAP FITS` or soft grant — **not
  passed** (none from the game's helper and no soft grant, but the launcher helper's 26 V8 `NO GAP FITS` remain);
  7343 MB ±10 % — **not comparable** (peak 6328 MB without the cabin); (4) chunks 3–6, all under PLA-476.
  Chunk 3 needs owner approval if required; 0.5.0 held.
- **Measured (l7, 2026-10-30, IPA `5b38a50b…`, `.work/ui-runs/20261030T122917-rdr2-p476l7`;
  [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#l7-wait-detach-decision-0166)):** decision 0166 in
  `9611a34` (madeira-unix 0229, wine-unix 0202). A's teardown detached tid 0200's wait (`node=unlinked`) and freed
  kind 3; no other parked address named it (the older-thread gap is closed for this run); kinds 1–6 held again. The
  game's helper got kind 3 itself and kinds 1, 2, 4–6, with no refusal; its browser ran; the Story tab came and was
  pressed (+134 s). Story's loading then grew the footprint to the 8192 MB limit and iOS ended the app at +238 s
  (jetsam, no crash). HK first-frame+10 passed (`20261030T122623-hk-p476l7`); The Witcher 2 unchanged
  (`20261030T122712-w2-p476l7`).
- **Chunk-2 gates after l7:**

  | Gate | l7 |
  | --- | --- |
  | HK first-frame+10 | passed |
  | The game's helper reaches allocator/browser startup | passed (kind 3 granted, no refusal, compositor running) |
  | The game signs in, Story is pressed | passed |
  | Story reaches the cabin | **not passed** (jetsam at 8192 MB in Story's loading) |
  | No SC/launcher `NO GAP FITS` or soft grant | **not passed** (26 V8 probe lines each from A and B, 36 i386 `dllhost.exe` WoW64-window failures; no soft grant) |
  | Peak within 7343 MB ±10 % | **not passed** (the 8192 MB limit) |

- **Ordered queue now:** (1) the memory of Story's load with the game's own Social Club running (the 0133/0153
  end came at +224.4 s, 120 s after sign-in, too late), then the `dllhost.exe` window failures and the V8 probes;
  (2) chunks 3–6, all under PLA-476. Chunk 5's decision is now partly covered by
  [0166](../decisions/0166-detach-a-parked-threads-wait-then-unpin-its-view.md) (the retention part of the layout);
  the rest of chunk 5 stays. 0.5.0 held.
- Phone: no session active. Reports: `.work/agent-notes/pla476/reports/`.

## Why

The 0.5.0 release IPA (`e21a5af8`, from `a124f27`) cannot start Red Dead Redemption 2. Dev IPAs
could. The only difference on that path is Playport's CEF 143.0.14 build
([0110](../decisions/0110-own-cef-build-for-a-clients-cef.md)). Its payload ships in the dev IPA
only (`stage-artifacts.py`, `pp verify --variant release`), because PLA-372 has not been done.

The owner's release run on 2026-10-29 (`.work/rdr2-release-log/playport.log`):

- `[cef-swap] Playport's CEF 143.0.14 is not in this build … every client's CEF is left alone`.
- Rockstar's `libcef.dll` (`0xefbe000`, align `0x1000`) is loaded. The helper's browser asks for
  32 GB reservations, which dev runs never made: there, three 2 GB reservations came from Playport's
  low-VA build.
- `NO GAP FITS size=0x800010000`. The soft-pool fallback "grants" `0x7400000000 +32 GB` and then
  releases it (`[bigres-free] 0x7400000000 +32768MB`). That range held 32 MB of live
  `Launcher.exe` memory.
- The launcher writes into the released range in `vk_common_CreateComputePipelines`
  (`[store-noalias] … NO pool/anon alias`). It exits `-536870904` (`0xE0000008`), and
  PlayRDR2.exe shows "Unable to launch game".

Shipping Playport's CEF build needs PLA-372's source and relinking work, a 4–8 h rebuild for each
Social Club CEF update, and a Chromium with no security fixes. The owner's decision (2026-10-29):
drop it, and run Rockstar's own CEF the way willfaust/Madeira does.

## Scope (owner, 2026-10-29)

**In.**
- Social Club's helper on Rockstar's own CEF, as willfaust/Madeira runs it:
  - single-process with the page bridge: madeira-unix 0190, decision
    [0150](../decisions/0150-dev-single-process-social-club.md), today dev-only and off;
  - the address-space room its PartitionAlloc pools need.
- Removing Playport's CEF build entirely.
- Holding 0.5.0 until a release build signs in and plays.

**Unchanged.** Every other Social Club and launcher policy:
- the launcher's end at the game's sign-in or near the limit (0124, 0130, 0140);
- the game's Social Club end and restart refusal (0133, 0138, 0141);
- the crash-reporter block (`PLAYPORT_SC_BLOCK_CRASHPAD`);
- the Chromium switches (0109, 0111, 0114);
- 0153's defaults: services, the 896 MiB pool, the Khronos loader, the Steam client,
  `jumbo-mb=8960`.

**Out.**
- Any Madeira knob beyond what this needs.
- Any patch to Rockstar code other than 0150's page bridge. 0150's guard stays: the exact helper
  build, the 48 SHA-256 ranges, and a multi-process fallback on mismatch.

## What upstream does that Playport's port left out

0190 ported upstream's `0f40502`/`fcfb69a`/`293cd39` single-process and page-bridge code. It left
out what upstream relies on for a *stock* CEF
([evidence](../evidence/2026-10-20-sc-single-process.md#left-out-of-the-port-and-why)), because
0110's build made it unnecessary:

1. **PartitionAlloc room** (`env.MADEIRA_SC_PA_POOLS = 1|2`, `virtual_ios.c`). `chrome_elf.dll`
   reserves its core pools as 32 GB on a 32 GB boundary.
   - Layout 1 moves FEX's arena to `0x7d00000000` (12 GB) and keeps `0x7c00000000 +4 GB` free, so
     the reservation lands at `0x7800000000`.
   - Layout 2 also places libcef's pools, its metadata and Oilpan's cage. It moves the JIT pool's
     RW alias to `0x7900000000`.
   - `MADEIRA_RDR2_VA_HOLD` (layout 2 only) holds `[0x75d0000000, 0x7800000000)` from boot for
     RDR2.exe's 8960 MB reservation.
   - Upstream's RDR2 list runs layout 2 with the hold.
2. **No libcef in the game.** A process with `socialclub.dll` that is not the helper gets no
   JIT-pool copy of `libcef.dll`, so its load fails (`ios_sc_cef_refuse`; `MADEIRA_SC_GAME_CEF = 1`
   keeps it). The game's overlay then runs only in the helper.
3. **On by default.** `MADEIRA_SC_CEF` defaults to 1. The single-process run is not opt-in.

At plan opening, none of the single-process A/B runs (scA1, x3, x4, xs1) had run Rockstar's CEF:
every one had `[cef-swap] … matches`. The a2 and l1–l4 probes below now exercise stock CEF; their
results do not yet satisfy chunk 2.

The soft-pool fallback releasing a range other processes still use
([audit](2026-10-06-madeira-audit.md), the `[soft-pool] GRANTED soft` topic) is a separate
runtime bug: [PLA-477](https://linear.app/playportdev/issue/PLA-477). This plan only stops Social Club from reaching it.

## Chunks

Each chunk is committed once its checks pass (AGENTS.md). Phone gates run in the main checkout. Every
runtime change gets a Hollow Knight first frame+10 (`app-367520`).

### 0. Bookkeeping (no build)

**Done 2026-10-29:** PLA-477 filed (the soft-pool bug); PLA-364 and PLA-475 commented, 0.5.0 held.

### 1. Dev probe: single-process on Rockstar's CEF, nothing else changed

- **Goal.** See how far 0190 gets with stock CEF before porting anything else.
- **Change.** A dev-only runtime key, `env.PLAYPORT_CEF_SWAP=0`, that makes
  `playport_cef_swap_path` return NULL. It is removed with the swap in chunk 4.
- **Runs.** Two RDR2 Plays on one dev IPA, with RDR2's defaults and Story via `landing.py`, as xs1:
  - **a1:** `env.PLAYPORT_CEF_SWAP=0` alone (reproduces the release failure in dev; expected
    "Unable to launch game");
  - **a2:** `env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1`.
- **Read.**
  - the `[sc-single]`/`[sc-rph]` counts (the table in the 0150 evidence);
  - every `[jumbo#]`, `NO GAP FITS`, `[soft-pool]` and `[bigres-free]` line from a
    `SocialClubHelper.exe` or `Launcher.exe` PEB;
  - whether the launcher's page loads and whether the game signs in;
  - the footprint peak.
- **Outcome.** Evidence record `docs/evidence/2026-10-2x-sc-stock-cef-probe.md`, and the decision
  for chunk 2:
  - If a2 signs in with no `NO GAP FITS` and no soft-pool grant, chunk 2 shrinks to a guard
    (fail a ≥16 GB reservation from a Social Club PEB instead of soft-granting it).
  - Otherwise port the layout.

### 2. PartitionAlloc room for Rockstar's CEF (likely the hard chunk)

**Implementation progress:** madeira-unix 0224 introduces a pure geometry and request-classification
header, with host tests in `tools/tests/test_sc_layout.py`. It allocates nothing and is not yet
connected to the runtime. Tests cover disjoint real ranges, the 8960 MiB game hold, the 15 GiB FEX
arena, overflow-safe bounds, reservation ordering and refusal to give one helper another helper's
remaining slots. madeira-unix 0225 adds the boot holds (all-or-nothing, only with the host's ownership marker and the
RW alias at `0x7900000000`) and 0226 routes the verified helper's reservations into the slots:
chrome_elf.dll's and libcef.dll's PartitionAlloc pools, their metadata, Oilpan's cage and V8's 8 GB
sandbox step (`NtAllocateVirtualMemoryEx`). Any other reservation of 16 GB or more from the helper
fails instead of reaching the soft-pool grant. Commits, protects and frees inside a slot's real range
are allowed only for its owner. A grant is released whole, by its owner or at its owner's exit through
the existing process teardown, and the slot is held again. The helper is told a 2 TB
`HighestUserAddress` (report only) so V8 takes its partial sandbox.

**Accepted bounded startup increment:** wine-pe 0055 replays already-loaded images through ntdll's existing
guarded notification after successful emulator initialisation, bypassing ImageTracker's exclusive code-lock
path. In l3, `kernel32.dll!LoadLibraryExW` (`+0x365e0`) was never registered in the helper's FEX tracker;
the decoder's NOEXEC trampoline caused the reported NULL read. `tools/tests/test_arm64ec_early_images.py`
covers early dependencies, main/ntdll/queued maps, duplicates and failed init. `test_sc_layout.py` also locks
down the existing refusal to reclaim kept or foreign views. Full `pp test` and the dev build passed (IPA
`3fd1145d`, 90 verification checks). On that exact IPA, l4 passes HK first-frame+10 and positively shows the game's
helper (PID `0528`, PEB `0x701af34000`, tracker `0x11a5b4d80`) registering kernel32 intervals covering
`0x73fba465e0`, advancing through TLS into allocator startup, then receiving five metadata refusals and a
guest `0x80000003` breakpoint. No NOEXEC remains. These two bounded startup gates are accepted; this does **not** accept allocator/browser startup or overall chunk 2.

**Slot reuse is blocked, not fixed:** l3's parked tid `0204` waits at `0x740007c3e0` inside the retained metadata
view; l2's tid `0208` waits at `0x74000483e0`; l4 again retains kind 3 with parked tid `0204` waiting at
`0x740002c3e0` inside its real metadata view. Decisions 0132/0143 keep the whole view unchanged, even after its
process exits and teardown takes its view ownership for the runtime. Clearing the slot ledger or overwriting
that range would violate the retention rule. No retention, termination, sign-in or launcher policy was changed;
no alternate geometry was selected. The [evidence](../evidence/2026-10-29-sc-stock-cef-probe.md#host-follow-up-early-images-and-the-retained-slot-blocker)
records the design constraints. The overall cabin/7343 MB ±10% gate remains **not passed**.

The host (`wine_host.c`) holds `[0x7000000000, +1.5 GiB)` from exec. In a2's log iOS had already put
a 74 MiB tag-87 region at `0x7000000000` by pool time, so a hold taken then can never get the
address. A layout play keeps the bottom 256 MiB; every other play gets the JIT RW alias mapped fixed
at `0x7000000000`, where Madeira put it and where ntdll's floor formula expects it. This changes every
game's placement slightly (the alias was at `0x7007130000` before), so the Hollow Knight gate covers it.

Opt-in: runtime key `env.PLAYPORT_SC_LAYOUT=1` (with `env.PLAYPORT_SC_SINGLE=1`; the probe key
`env.PLAYPORT_CEF_SWAP=0` until chunk 4).

**Established blocker: subsequent helpers.** The slots serve one helper at a time; a second helper is refused
while the first owns them, including when teardown preserves a referenced view. l4's game's helper now reaches
its pools but cannot acquire metadata; later restarts are refused by existing 0138 policy. Moving the launcher's
end or changing restart/retention policy is not authorised by the startup acceptance. No safe replacement
geometry is established. Reported Chromium ranges overlap intentionally; only owned **real** ranges may be
committed or released. Upstream's diagnostic-only overflow warnings are not sufficient ownership enforcement
for this port.

- Port upstream's layout from `0f40502` (and `e50981f` for the RDR2 hold) as madeira-unix patches,
  each with `Class:`, `Evidence:` and `Offered-upstream:` trailers.
- **It cannot be copied as is.** Playport's map is not upstream's:
  - madeira-unix 0083–0085 removed the CEF-only placement code;
  - the jumbo holdback (`jumbo-mb`, 0126);
  - the donor pool (0153);
  - short reservations (0222);
  - the audit's T10 constants (`0x73ffff0000`, `ios_spill_cap`, `ios_is_arena_addr`).
- Start from the probe's actual reservation list and use the least layout that fits it:
  layout 1 if `chrome_elf`'s 32 GB pool is the only one; layout 2 only for what a2 shows.
- **Keep these out of it:**
  - Hollow Knight and every non-Social-Club title: the layout applies only to a Play whose launcher
    is `PublisherLauncher.rockstar`, or only from the first `SocialClubHelper.exe`, whichever the
    probe shows is enough;
  - RDR2.exe's 8960 MB reservation, held today by `jumbo-mb=8960`, which must still be granted.
- **Host tests.** Port upstream's `check-pool-placement` and `check-sc-grant-growth` to
  `tools/tests`, against Playport's constants.
- **Phone.** HK first frame+10; RDR2 a2 again. The gate: the game signs in, Story reaches the
  cabin, there is no `NO GAP FITS` or soft-pool grant from a Social Club or launcher PEB, and the
  peak is within xs1's 7343 MB ± 10 %.

### 3. The game's libcef (only if chunk 1/2 shows it)

The xs1 log shows `libcef.dll` mapped in the game's process too (with Playport's build). If on
stock CEF the game's own load reserves pools that do not fit, port `ios_sc_cef_refuse`. **Ask the
owner first:** it is a refused DLL load in the game, and 0150 excluded it. Otherwise skip.

### 4. Single-process in both builds; remove Playport's CEF

- **0190's gate.** `playport_sc_single_enabled` is on by default and in release:
  - `PLAYPORT_SC_SINGLE=0` turns it off (dev runtime key);
  - `app/tests/sc_single_test.c` is changed to match (the release gate test becomes a default-on
    test);
  - the exact-build guard and the multi-process fallback stay.
- **Remove:**
  - `patches/wine-unix/0039` and its series entry;
  - `app/Sources/WineHost/cef_swap.c` and `include/cef_swap.h`;
  - `app/tests/cef_swap_test.c`;
  - `app/Sources/S1Probe/Runtime/cef/`, and the `Runtime/cef` line in `app/xtool.yml`;
  - `build/cef/` and `build/pipeline`'s `stage-payload.py` call;
  - `stage-artifacts.py`'s CEF line;
  - `patches/cef/` and `patches/chromium/`;
  - the `cef` and `chromium` rows in `pins.lock`;
  - the CEF parts of `pp sync`, `pp source`, notices and `verify-ipa.py` (keep a check that fails
    *any* IPA carrying a CEF payload);
  - the chunk-1 key.
- **Keep:**
  - the `[chromium]` switch code (0109, 0111, 0114): it serves Rockstar's CEF too;
  - the PLA-447 heuristic.
- **After it.**
  - `pp test`, `pp names`, `pp secrets`, `pp build` (dev) and `pp build --variant release`, then
    `pp verify` on both.
  - Commit the changed build records.
  - Delete `.work/cef-src` only after chunk 6 passes, and ask first: it is 150–200 GB and the only
    rebuild route.
- **Linear.** Cancel PLA-372 and PLA-382 with a pointer here. Update PLA-426's CEF part.

### 5. Decision record

A new decision (next free number; 0166 is the last). The retention of a launcher helper's slot view is already
decided by [0166](../decisions/0166-detach-a-parked-threads-wait-then-unpin-its-view.md). It:
- supersedes 0110;
- amends 0150: on by default, in release; the page-bridge exception unchanged;
- amends 0153: what RDR2 runs with in both builds, and the layout from chunk 2;
- records the every-play low hold at `0x7000000000` (+1.5 GiB from exec) and the fixed JIT RW alias there
  ([PLA-480](https://linear.app/playportdev/issue/PLA-480)).

Update `docs/decisions/README.md`, `ARCHITECTURE.md`, `BUILDING.md`, `LICENSING.md`, `NOTICES.md`
and `DISTRIBUTION.md` where they name the CEF payload, and `docs/plans/finished.md` /
`docs/plans/README.md`.

### 6. Gates, then 0.5.0

- **Dev IPA.** HK first frame+10. Three RDR2 runs to Story +60 s (sign-in time, peak, jetsam, the
  `[sc-single]` counts). Compare with xs1 and d2–d5.
- **Release IPA.** `pp build --variant release`; the owner installs it and plays RDR2 to Story
  (decision 0068: no automated release tests). Pull `playport.log` afterwards for the same lines.
- **Records.**
  - evidence record with both IPAs' sha256;
  - PLA-364 **Status:**/**Best known:**;
  - `site/compatibility/games.json` if the status changes;
  - re-read `docs/releases/0.5.0.md`'s RDR2 section (it names Playport's CEF nowhere, but check the
    memory and sign-in numbers).
- **Then.** Rebuild the release draft from the new HEAD (`pp release 0.5.0`) for the owner's
  sign-off (PLA-475).

## Risks

- **Rockstar's CEF single-process may not fit even with the layout.** Upstream's GTA V and RDR2
  runs used a different pool layout (pool-split/mid/low), swap images and other settings Playport
  lacks.
  - If chunk 2 cannot place the pools, stop and report. Keeping Playport's CEF in release (PLA-372)
    is then the fallback, and that is the owner's call.
- **Single-process merges fault domains.** x4 (single-process with the game's helper alive) was
  jetsammed at 8120 MB. The game's Social Club end (0133/0141) is what kept xs1 under the limit; it
  stays on.
- **xs1's black spinner after the helper's end** (one run). The defaults never showed it, so chunk 6
  needs three runs, not one.
- **A Social Club update** changes the helper's hashes. 0190 then falls back to multi-process, which
  on stock CEF fails as release does today. Today a CEF update breaks the swap the same way, so this
  is no regression, but it should be visible: the fallback line goes into the launch message's log
  reason.
