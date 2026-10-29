# Social Club on Rockstar's own CEF: single-process in both builds, no Playport CEF build

**Linear:** [PLA-476](https://linear.app/playportdev/issue/PLA-476). Related:
[PLA-364](https://linear.app/playportdev/issue/PLA-364) (RDR2),
[PLA-475](https://linear.app/playportdev/issue/PLA-475) (0.5.0, held for this),
[PLA-372](https://linear.app/playportdev/issue/PLA-372) (CEF payload distribution, to be cancelled),
[PLA-254](https://linear.app/playportdev/issue/PLA-254) (publisher launchers).

**Status:** chunks 0 and 1 done 2026-10-29; chunk 2 remains **not passed** ([evidence](../evidence/2026-10-29-sc-stock-cef-probe.md)). Owner approved the initial layout port, not a change to retained-view policy. The early-image startup increment (wine-pe 0055) is independently accepted on dev IPA `3fd1145d`: l4 passes HK first-frame+10 and positively shows the game's helper registering kernel32 and reaching allocator startup beyond l3's NOEXEC. It then fails metadata allocation because the launcher's helper left a referenced view retained. Story ends at a black spinner, not the cabin; no gameplay/memory acceptance or safe replacement geometry is established. **Next:** obtain an owner-approved design for safe subsequent-helper allocation while preserving retained references under 0132/0143; do not clear, free or overwrite kept slots. No new runtime work or phone input is queued.

**Runner checkpoint (history):** resuming from clean `241990e` on branch `dev/pla-476-sc-stock-cef` in the main checkout; no merge or push performed by this continuation. The previously recorded writer is not active and left no report or tracked changes. Models confirmed for this invocation: hard `openai-codex/gpt-6.1-sol:high`, easy `openai-codex/gpt-6.1-sol:medium`.

**Current checkpoint:** `e7ae7d1` committed the accepted startup increment, tests, records and evidence. Branch remains unmerged and unpushed by this continuation. **Running:** none. Read-only researcher `921188b6-da68-49c2-b949-0d279d2e4bbf` finished the comparison; report copied to `.work/agent-notes/pla476/reports/retained-slot-design-comparison.md`. Supervisor executed its pure interval-check appendix successfully against current constants. No writer or phone session is active; no runtime/policy changes authorized.

**Finished startup checkpoint:** finalization writer `b64e1c09-bb78-497a-bc56-123991c02f4c`, model `openai-codex/gpt-6.1-sol:high`, from `7439797` (supervisor metadata added in `5ac72f8`); documentation reconciliation, focused checks and commit of the accepted startup increment only, no new implementation, build or phone input. Report `.work/agent-notes/pla476/reports/startup-finalize.md`. Read-only reviewer `b341b1bf-a6cb-4ad6-b8ce-4427ef7449a3` finished with no findings and accepts the startup increment only: l4's game helper registers kernel32 and reaches allocator startup, then fails metadata allocation. Review copied to `.work/agent-notes/pla476/reports/startup-candidate-review.md`. Writer `05e6db69-1b5d-4260-9ae6-ab86f5423693` previously finished blocked at phone preflight; its documentation/retention-test checkpoint is `31bd282`, report `.work/agent-notes/pla476/reports/chunk2-helper-restart.md`. Its early-image patch, startup test, series entry and four build records are now accepted together with the l4 evidence, not as overall chunk 2. Full tests and dev build already passed (90/90 IPA checks).

**Owner direction:** compare both genuinely disjoint placement and safe parked-thread lifetime/cleanup, then present an evidence-backed design. This authorizes investigation only, not a retention-policy change or runtime implementation. Use the confirmed hard model `openai-codex/gpt-6.1-sol:high` for research.

**Comparison outcome (research, not implementation approval):** a second complete bank preserving current capacities does not fit the existing resource envelopes, and only two 32-GiB-aligned core starts exist (`0x7000000000`, `0x7800000000`). Six slots total 20992 MiB; l4 blocks kind-3 capacity 6400 MiB, l2 blocks kinds 1/3/5 capacity 11520 MiB. Blocked slot capacity is **not** a measured surviving-view extent; exact inventory remains necessary. The supervisor ran the report's interval assertions successfully. Recycling deleted slots already works; it does not solve retained references. Smaller/finer future views or borrowed furniture space remain unproved and do not establish a solution to retained core prefixes.

**Recommended next investigation:** a prospective helper-scoped wait-detach/quiescence proof **before** teardown, preserving the existing fail-closed retention fallback. The current PE wait queue has stack nodes and shared wake/unlink races; an i386 handshake is precedent, not proof of an x64 exit path. Archived parked threads must never be resumed after code/registry retirement. A safe native terminal boundary, FEX/TLS/callback drain and actual completion acknowledgement remain unproved. No sleeps, cancellation, ledger clearing or moving saved pointers qualifies. Owner approval of a proof stage is not approval to implement a retention-policy change; a new owner-approved ADR is required before changing 0127/0132/0134/0143 contracts. Exact surviving views, waiter attribution and helper-overlap reconstruction are focused prerequisites. Cleanup cannot solve simultaneously live helpers; that overlap must be established. Upstream's delay-based reaper is not a quiescence proof for Playport's forever-parked threads.

**Ordered queue:** (1) owner decides whether to authorize this prospective lifetime proof stage or restrict work to placement-only investigation; (2) only after approval, resolve the remaining chunk-2 allocator/browser, Story cabin, no-Social-Club/launcher-`NO GAP FITS`/soft-grant and 7343 MB ±10% memory gates; (3) consider chunks 3–6 in their documented order, all under PLA-476. Chunk 3 still requires owner approval if needed; 0.5.0 remains held.

**Phone checkpoint:** connected discovery was restored by guarded `python3 tools/phonelib.py netmuxd-restart` (stale workstation service); preflight then found one network phone, battery 80%, 3 GB free. There is no current prerequisite blocker. The exact-IPA l4 session (`.work/agent-notes/pla476/l4.sh`, SHA-256 `3fd1145d5b6e59db874083a716ee5d10af685eb476fa4e1ff03c866129348a5e`) completed exit 0 with lock released: in-place install, HK first-frame+10 passed (`.work/ui-runs/20261029T220635-hk-p476l4`, first frame +10.58 s), RDR2 first-frame+420 (`.work/ui-runs/20261029T220726-rdr2-p476l4`). Independent analysis accepted only the bounded startup gates; the RDR2 wait-condition success is not Story success. No more phone input is queued.

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
`3fd1145d`, 90 verification checks). Initial no-phone preflight was a historical blocker, since resolved by
the guarded netmuxd restart. On that exact IPA, l4 passes HK first-frame+10 and positively shows the game's
helper (PID `0528`, PEB `0x701af34000`, tracker `0x11a5b4d80`) registering kernel32 intervals covering
`0x73fba465e0`, advancing through TLS into allocator startup, then receiving five metadata refusals and a
guest `0x80000003` breakpoint. No NOEXEC remains. Independent review found no issues and accepted these two
bounded startup gates; this does **not** accept allocator/browser startup or overall chunk 2.

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

A new decision (next free number; 0165 is the last). It:
- supersedes 0110;
- amends 0150: on by default, in release; the page-bridge exception unchanged;
- amends 0153: what RDR2 runs with in both builds, and the layout from chunk 2.

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
