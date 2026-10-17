# Plans and Linear

Linear (team PLA) is Playport's tracker for everything. Plans hold designs and
execution gates, not a separate backlog. Search before creating an issue; link
its ID/URL in the plan and the plan's repository path in the issue. Update Linear
with progress, blockers, evidence and follow-ups as work proceeds (AGENTS.md).
A game's issue alone does not cover a broader runtime/tooling implementation.
The rule includes draft plans under `.work/plans/`: track them when written,
then promote a scrubbed version to `docs/plans/` before execution. Private research
and account inventories stay in `.work`, not in the plan or Linear.

## Active plans after review

| Plan | Tracking issue | Review outcome |
| --- | --- | --- |
| [Performance review](2026-09-30-performance-review.md) | [PLA-79](https://linear.app/playportdev/issue/PLA-79) | Reconciled 2026-10-13 (item ledger in the plan): A1, MaxInst, x87 and FEX main done; A4/A5/C5 superseded by 0100; item E done (wine-pe 0044, PLA-325); A2 limiter and the rest open. |
| [KosmicKrisp FL12_2](2026-10-05-kosmickrisp-fl12_2.md) | [PLA-81](https://linear.app/playportdev/issue/PLA-81), [PLA-386](https://linear.app/playportdev/issue/PLA-386) | Research only, refreshed 2026-10-13: pins unchanged, no patch changes a 12_1/12_2 input; Witcher 3 DX12 candidate blocked on PLA-43 (AVX). 2026-10-17: RDR2's Vulkan needs measured (none from 12_2); host-only chunks V0–V4 on `dev/pla-386-rdr2-vulkan-kk` (side copy) done on the host: replay harness, mesa 0037 (undefined image: RDR2 replay 151 crashes → 0), 0038 (pipeline-statistics pools), 0039 (8-sample pipelines), sampled multisample arrays (no patch); not checked on the phone. |
| [Proton ARM64 alignment](2026-10-05-proton-arm64-alignment.md) | [PLA-76](https://linear.app/playportdev/issue/PLA-76) | Reconciled 2026-10-13: step 1, A0–A2, B2, B5 done (A2 via the killed-thread/suspend series); B1 blocked (0056); B3, B4, B6, B7, the C table and Portal 2 follow-ups open. |
| [Release simplification](2026-10-05-release-simplification.md) | [PLA-73](https://linear.app/playportdev/issue/PLA-73) | Not started; inventory refreshed 2026-10-13 (new settings classified, release gate per 0068, Steam API vs bridge D7). Owner to confirm: compatibility defaults apply in release. |
| [KosmicKrisp default](2026-10-06-kosmickrisp-default.md) | [PLA-77](https://linear.app/playportdev/issue/PLA-77) | Partly done (step 3): i386 DXVK d3d9/10/11 ship; i386 d3d8 and vkd3d-proton missing; Valheim no longer needs DXMT (0101/0102); direction set by 0100; x86-64 default still DXMT. |
| [Madeira audit](2026-10-06-madeira-audit.md) | [PLA-75](https://linear.app/playportdev/issue/PLA-75) | Reconciled 2026-10-13 against madeira-unix 0143: T3 done, T12/T13 partly, 11 topics open (ledger in the plan); coordinate T4/T10 with PLA-216. |
| [Vulkan performance](2026-10-06-vulkan-performance.md) | [PLA-72](https://linear.app/playportdev/issue/PLA-72) | Paused 2026-10-08, merged to `main`: six fixes kept (present path, tiler off, no present wait, compression-keeping texture usage, PLA-93 freeze deferral); not at exit. Reviewed 2026-10-13: PLA-93 and PLA-65 Done, mesa changes since listed, nothing measured. Handoff: the plan's last Progress entry. |
| [Compatibility speedrun](2026-10-08-compat-speedrun.md) | [PLA-112](https://linear.app/playportdev/issue/PLA-112) | Phase 1 and the issue sweep done and merged into `main` (2026-10-13; decisions 0075–0104, history in the plan's git log). Remaining: the owner's library A–Z from 9 Years of Shadows. |
| [On-screen controls, mapping and gyro](2026-10-09-touch-controls.md) | [PLA-13](https://linear.app/playportdev/issue/PLA-13) | Phases 1–3 done and signed off by the owner (2026-10-13, merged to `main` in `631bd7f`); phases 4+ not started; design in `docs/design/2026-10-09-touch-controls/`. |
| [Steam client bridge](2026-10-12-steamclient-bridge.md) | [PLA-253](https://linear.app/playportdev/issue/PLA-253); phases PLA-255–266 | Written 2026-10-12, not started; option B (the game's own `steam_api`, a guest `steamclient` forwarding to the Swift client); owner decided D1–D10 on 2026-10-13 (D7: emulator removed once the bridge is proven; D9: CS2 with bots in Phase 5); next is Phase 1 |
| [Steam bridge for RDR2](2026-10-18-steam-bridge-rdr2.md) | [PLA-398](https://linear.app/playportdev/issue/PLA-398) (PLA-253) | Written 2026-10-18 with every decision approved by the owner (0115). Goal reached and passed: on Vulkan the Steam copy initialises Steam through Playport's client, signs in to Social Club and shows the launcher's main window ([evidence](../evidence/2026-10-18-steam-bridge-rdr2.md)). Stopped 2026-10-18: the launcher then halts on a HLT ([PLA-401](https://linear.app/playportdev/issue/PLA-401), parked; [evidence](../evidence/2026-10-18-rockstar-generated-fault.md)) |
| [Publisher launchers](2026-10-12-launchers.md) | [PLA-254](https://linear.app/playportdev/issue/PLA-254); PLA-267–278, 291–299 | Written 2026-10-12, not started; Chromium hosting, then Rockstar, Ubisoft, EA, Battle.net; owner decided D1–D10 as recommended on 2026-10-13; 2026-10-15: Rockstar track first; Stage R for the Rockstar launcher done without the game ([evidence](../evidence/2026-10-15-rockstar-launcher-recon.md)), Stage 0 on the phone proposed next (PLA-291) |
| [Red Dead Redemption 2](2026-10-12-rdr2.md) | [PLA-254](https://linear.app/playportdev/issue/PLA-254); PLA-268, 269, 276, 279, 300, 301 | Feasibility plan 2026-10-12, not started; owner decided D1–D7 as recommended on 2026-10-13; Story mode depends on donor memory (PLA-216); Online not pursued |
| [Own low-address-space CEF](2026-10-16-cef-low-va-build.md) | [PLA-370](https://linear.app/playportdev/issue/PLA-370) | Stage D done: the launcher Open shows Social Club's Sign In with text, 3/3 ([evidence](../evidence/2026-10-18-pool-tail.md)); remaining pool head pressure is PLA-399. Owner sign-in (Stage E) not done. |
| [Guest RAM from donor processes](2026-10-12-donor-memory.md) | [PLA-216](https://linear.app/playportdev/issue/PLA-216) | Written 2026-10-12 on branch `research/extended-memory` (unmerged, rebased onto main); the helper-RAM probe and madeira-unix 0147/0148 kept (0147 removed in step 3), the per-allocation broker removed. Step 1 passed 2026-10-14: after the donor helper ends, 4096 MiB stays mapped, verified and outside the app's footprint for both variants ([evidence](../evidence/2026-10-14-donor-memory.md)). Step 2 (entitled) 2026-10-14: two donors gave 6400 MiB, verified, and survived a minute in the background; the phone's free RAM, not the app's limit, is the wall ([evidence](../evidence/2026-10-14-donor-memory-scale.md)). Step 3 2026-10-14: a dev setting takes a pool at Play and serves 0148 from it (0147 removed); Hollow Knight with 4 GiB reached first frame within noise, 400 MiB served ([evidence](../evidence/2026-10-14-donor-pool-at-play.md)). Step 4 (Kingdom Come) 2026-10-14: after the PLA-350 Steam API fix, both runs loaded Rattay. Peak `fpMB` was 7,914 with the pool off and 7,217 with it on, and unmatched stayed 0. The pool stopped serving after the load: its bump allocator needs whole objects free ([evidence](../evidence/2026-10-14-donor-pool-kcd.md)). Pool reuse inside an object 2026-10-14: best fit with memset of reused pages; refused stayed 0, peak 7,783 off vs 7,201 on (−582, bounded by the ~700 MiB live set), Rattay loaded, no crash ([evidence](../evidence/2026-10-14-donor-pool-reuse.md)). Small commits 2026-10-14: a census (madeira-unix 0149) showed 3.4 GB of KCD's footprint was guest RW filled by commits under 1 MiB; 0150 backs those too, and peak `fpMB` fell from 7,682 off to 3,884 on (−3,798), refused 0, unmatched 0, Rattay loaded ([evidence](../evidence/2026-10-14-donor-pool-widen.md)). Long run 2026-10-14: KCD 32 min with the pool on, peak `fpMB` 4,007 and flat, no jetsam, refused/unmatched/detaches 0; the scripted HK A/B and the detach probe were not run ([evidence](../evidence/2026-10-14-donor-pool-measure.md)). Auto sizing 2026-10-14 (PLA-351): Off/Auto from P − L, off under 1 GiB; on the 12 GB phone at Play Auto takes no pool (P 4,440 vs L 8,191), and the helper is entitled with a 6,139 MiB limit ([evidence](../evidence/2026-10-14-donor-pool-auto.md)). Memory plan 2026-10-14 (PLA-352): guest RAM and the DXMT video budget from one reading of the limit at Play (8,192 / 1,536 MiB on the reference phone, as before; less guest RAM at ≤ 6 GiB); the budget-change event and DXVK clamp are opt-in; DXVK reports an 8 GiB heap ([evidence](../evidence/2026-10-14-memory-plan.md)). Follow-ups 2026-10-15: the scripted HK A/B matched in steady play, but the pool run's scene loads were 1.5–2.2 s longer (one pair); the detach probe is still not run, since pp cannot copy `protect.exe` to the phone ([evidence](../evidence/2026-10-15-donor-pool-followups.md)). Auto from the headroom 2026-10-15 (PLA-351): RAM − 2 GiB − the spare floor − min(L, 4 GiB), 4,096 MiB on the 12 GB phone, growth stops on low memory; the HK load gap was a cold Metal cache, not the pool; `MADV_ZERO` cut KCD's zeroing from 93 to 16 ms per GiB; KCD 600 s on Auto with no jetsam, peak `fpMB` 4,292 ([evidence](../evidence/2026-10-15-donor-pool-auto-headroom.md)). Step 5 2026-10-15 (PLA-354): no-copy Metal buffers over pool memory work and cost no footprint (1 GiB: +19 vs +1,020 MiB); DXMT 0012 `gpu-pool-buffers`, off by default; KCD at Auto gains nothing, since the pool is already full; KosmicKrisp already has host-pointer import, but nothing uses it ([evidence](../evidence/2026-10-15-donor-pool-gpu.md)). Detach probe 2026-10-15: `pp phone put` (import inbox only) put `protect.exe` on the phone; with 4096 its `exec-rw` detached 128 host pages and every call into the copied code returned its value, map failures 0 ([evidence](../evidence/2026-10-15-donor-pool-copyback.md)). Vulkan clamp 2026-10-15 (PLA-353): mesa 0036 caps KosmicKrisp's heap budget at the plan under `vulkan-vram-plan = 1` (off by default; heap size kept); HK on Vulkan reads `Budget: 1.50 GiB` instead of 6.1 GiB and reaches first frame ([evidence](../evidence/2026-10-15-vulkan-clamp.md)). Decision 0106 2026-10-15 (PLA-355, PLA-362, PLA-363): the 8 GB row in full (no clamp within 512 MiB), the Vulkan clamp on by default (HK plays as before), and 30 whole-object purges with 0 stale pages and no leak ([evidence](../evidence/2026-10-15-donor-pool-purge.md)). |

Status here records the review, not live issue state. Linear is authoritative for
what to do next. Overlapping performance/alignment/audit plans must share findings,
not schedule the same fix independently.

## Build-area drafts reviewed

- **KosmicKrisp FL12_2:** unfinished and distinct from backend migration. Promoted
  the research plan above, removed private inventory/storage/pricing assumptions,
  and linked PLA-81 to PLA-77/PLA-76/PLA-72. The original Mesa move is already
  reflected in current pins; capability proposals still need validation.
- **PC import, GOG and Epic:** removed the stale `.work/plans/` duplicate; the plan
  itself was later finished and removed (below).

Neither build-area draft was a completed execution run. Their local copies were
removed after review; raw private FL12_2 research remains in `.work/scratch/fl122/`.

## Completed runs removed

- **Guest VA exhaustion:** the fix and final regression gates passed; see
  [outcome and evidence](finished.md#guest-address-space-exhaustion). Separate
  cache and VA-layout work stays in PLA-76/PLA-75.
- **Store-game sign-in:** the implementation run ended and its open follow-ups
  already have issues; see [outcome and evidence](finished.md#games-sign-in-to-their-store).
  The release handoff (PLA-74) is closed; v0.4.0 is tagged.

- **PC import, GOG and Epic** (2026-10-13): implemented and merged; its phone checks
  and deferred scope are PLA-80. See [outcome](finished.md#pc-import-gog-and-epic).
- **Runtime DLL coverage** (2026-10-13): staging merged (0070–0072); Proton's own
  components and the optional follow-ups are PLA-324. See
  [outcome](finished.md#runtime-dll-coverage).

- **OpenGL through Zink:** chunks 1a–5 done 2026-10-11 (decisions 0087–0089); see
  [outcome and evidence](finished.md#opengl-through-zink). Remaining work is in
  PLA-181, PLA-184, PLA-186, PLA-189 and PLA-164.

[Finished plans](finished.md) is a historical outcome/link index, not an active
plan. Full removed plans remain in git history. Keep partial plans until mandatory
gates pass or remaining scope is explicitly handed to open linked issues. Removing
a completed run must not erase its evidence or imply its follow-ups passed.

This review changed documentation and tracking only: no plan implementation,
build, phone play, release draft or publication was performed.
