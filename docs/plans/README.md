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

| Plan | Tracking issue | Status (2026-10-19) |
| --- | --- | --- |
| [Performance review](2026-09-30-performance-review.md) | [PLA-79](https://linear.app/playportdev/issue/PLA-79) | Ledger reconciled 2026-10-13, updated 2026-10-19. Done: A1, MaxInst, x87, the FEX moves, the disk cache, CPU topology and item E (wine-pe 0044, PLA-325). A4, A5 and C5 superseded by 0100. Open: the A2 limiter and the rest, every cost unmeasured. |
| [KosmicKrisp FL12_2](2026-10-05-kosmickrisp-fl12_2.md) | [PLA-81](https://linear.app/playportdev/issue/PLA-81), [PLA-386](https://linear.app/playportdev/issue/PLA-386) | FL12_2 chunks 0–11 not started; the Witcher 3 DX12 candidate waits on PLA-43 (AVX). The RDR2 Vulkan work is merged (`db3d0a6`): RDR2 needs nothing from 12_2, and mesa 0037–0043 fix the KosmicKrisp defects its pipelines hit. RDR2's renderer is not yet run on the phone (PLA-386); PLA-397 is the fallback. |
| [Release simplification](2026-10-05-release-simplification.md) | [PLA-73](https://linear.app/playportdev/issue/PLA-73) | Not started. Inventory refreshed 2026-10-13. Since then, 0115 lets a `client` compatibility default (RDR2 only) through the release block; the next free decision number is 0118. The owner must still confirm that compatibility defaults apply in release. |
| [KosmicKrisp default](2026-10-06-kosmickrisp-default.md) | [PLA-77](https://linear.app/playportdev/issue/PLA-77) | Partly done (step 3): i386 DXVK d3d9/10/11 ship; i386 d3d8 and vkd3d-proton are missing. 0100 sets the direction; the x86-64 default is still DXMT. |
| [Madeira audit](2026-10-06-madeira-audit.md) | [PLA-75](https://linear.app/playportdev/issue/PLA-75) | Reconciled 2026-10-13 against madeira-unix 0143: T3 done, T12 and T13 partly done, 11 topics open. Not re-checked against 0144–0162: the donor pool (0148–0150), 0154, 0155, 0157 and 0160–0162 touch the same files (note in the plan). |
| [Vulkan performance](2026-10-06-vulkan-performance.md) | [PLA-72](https://linear.app/playportdev/issue/PLA-72) | Paused since 2026-10-08 and merged; six fixes kept; not at its exit criteria. The plan's last Progress entry is the handoff. |
| [KosmicKrisp GPU work against DXMT's](2026-10-23-kk-vs-dxmt-gpu-work.md) | [PLA-439](https://linear.app/playportdev/issue/PLA-439) | Written 2026-10-23 from desk research only: no build, no phone run, no capture. Ranks nine places where KosmicKrisp asks the GPU for work DXMT does not (memory backing, copies, load/store bookkeeping, sync, blending, shader precision, present path, per-pass Metal state, Vulkan-only robustness), with the queue and the gate for each. Not executed; PLA-72 keeps the exit criteria. |
| [Compatibility speedrun](2026-10-08-compat-speedrun.md) | [PLA-112](https://linear.app/playportdev/issue/PLA-112) | Phase 1 and the issue sweep are done and merged (decisions 0075–0104). What remains is the owner's library A–Z, from 9 Years of Shadows. |
| [On-screen controls, mapping and gyro](2026-10-09-touch-controls.md) | [PLA-13](https://linear.app/playportdev/issue/PLA-13) | Phases 1–3 done, signed off and merged (`631bd7f`); phases 4+ not started. Follow-ups: PLA-338, PLA-339, PLA-340. Design: `docs/design/2026-10-09-touch-controls/`. |
| [Steam client bridge](2026-10-12-steamclient-bridge.md) | [PLA-253](https://linear.app/playportdev/issue/PLA-253); phases PLA-255–266 | Decided 2026-10-13; no phase has started. One slice has shipped: the x86-64 `steamclient64.dll` and mode `client` for RDR2 alone (0115, PLA-398, [finished](finished.md#steam-bridge-for-rdr2)). Next: Phase 1 (PLA-257). |
| [Publisher launchers](2026-10-12-launchers.md) | [PLA-254](https://linear.app/playportdev/issue/PLA-254); PLA-267–278, 291–299 | Rockstar track only. Stage R done. Stage 0 reached Sign In with Playport's own CEF ([finished](finished.md#own-low-address-space-cef)). The Steam copy signs in and opens the main window, then ends on `0xc0000096` ([PLA-401](https://linear.app/playportdev/issue/PLA-401), parked). Merged (`dfc527f`). Ubisoft, EA and Battle.net not started. |
| [Red Dead Redemption 2](2026-10-12-rdr2.md) | [PLA-254](https://linear.app/playportdev/issue/PLA-254); PLA-268, 269, 276, 300, 301, 364 | Partly under way. Memory (PLA-216) is [done](finished.md#guest-ram-from-donor-processes). The Vulkan needs are fixed on the host (PLA-386). The game is installed and its launcher signs in, then stops (PLA-401), so the game itself has not started. Online is not pursued. |
| [ppsync](2026-10-21-ppsync.md) | [PLA-427](https://linear.app/playportdev/issue/PLA-427) | Merged to main on 2026-10-22, on by default (decision 0157, proposed); the owner's play and a `pp perf` comparison against fastsync are open |
| [KosmicKrisp Proton parity](2026-10-22-kk-proton-parity.md) | [PLA-431](https://linear.app/playportdev/issue/PLA-431) | `dev/kk-proton-parity` in main checkout, unmerged. B1/B3 phone smoke passed; B3 has 25 warm identifier hits. Initial A0 menu profiles inconclusive. KK 0121, DXVK 0006/0007, vkd3d 0005 diagnostics and offline parser are host-tested and independently accepted (parser fixes `bafeced`, `5a46a4a`). Probe IPA `74c0d54e…` installed in place; DXVK off/on menu smoke works, but device prep BLOCKED: 17 interleaved malformed records, 0 usable parser intervals. D3D12 unrun; settings restored, no gameplay. KK0122/0123 independent re-review ACCEPT. [Bounded retry](../evidence/2026-10-23-descriptor-probe-device-prep-retry.md): exact `689b9479…` upgraded in place; DXVK off/on first-frame+50 and live45/55s menus, but BLOCKED by2 native emission-failure poison records before banner (failure branch unknown),0 strict usable intervals. DXVK61 complete36-row captures conservatively rejected; no KK calibration/captures. Supervisor STOP after2 plays, D3D12 unrun, settings restored/explicit black. Read-only target audit found no ABI/constant bug; branch still unknown. Mesa0124 reason-coded poison independently ACCEPTED; parent matrix passed. [ONE diagnostic capture](../evidence/2026-10-24-descriptor-emission-reason-device.md): exact `aa32a361…` upgraded in place, first-frame+10 finalok; saved shot black, not menu proof. Branch observed: missing-append, regular mode33188, flags65541 lacks Darwin O_APPEND0x8, rowlen454; no syscall errno/write attempt. Underlying fd cause NOT fixed. Full strict parse exit1:0 usable,20 rejected intervals,21 complete36-row client captures rejected,2 native poison records; native banner/calibration UNOBSERVED. Restoration interrupted on owner reclaim: saved settings restored at earlier instants, last screenshot another foreground app, no final black/current-state confirmation. Host lock verified free; no active UI session or resumed script. PLA-440 next: host-only deterministic `#runtime`/`#graphicsoptions` routes and foreground/queue safety preparation before any newly authorized, announced UI batch. No black interlude then input or improvised scrolling; no arbitrary UI-session timer/gameplay limit. Checkpoint independent review pending; no further play/fix/measurement authorized. Original raw log remains invalid/unchanged. No measured descriptor-buffer benefit; A2 not started, gate retained. PLA-433–435 deferred. |

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

- **Guest RAM from donor processes** (2026-10-19): steps 1–5 done and merged; the 8 GB phone
  is PLA-355 and the unmeasured follow-ups are PLA-407. See
  [outcome](finished.md#guest-ram-from-donor-processes).
- **Proton ARM64 alignment** (2026-10-19): "Done when" met and merged (`c8095ce`); B4 waits for
  a title (PLA-391), Portal 2's performance follow-ups are PLA-406. See
  [outcome](finished.md#proton-arm64-alignment).
- **Own low-address-space CEF** (2026-10-19): stages A–D done, and the account signed in through
  the Steam copy; the pool head (PLA-399), distribution (PLA-372) and the launcher's fault
  (PLA-401) stay open. See [outcome](finished.md#own-low-address-space-cef).
- **Steam bridge for RDR2** (2026-10-19): goal passed (PLA-398 Done); PLA-401 and PLA-400 stay
  open. See [outcome](finished.md#steam-bridge-for-rdr2).
- **KosmicKrisp graphics pipeline library** (2026-10-22): G0–G6 done on `dev/kk-gpl-phone`
  (mesa 0096–0101, to be merged); decision 0158 keeps `MESA_KK_EXPERIMENTAL=gpl` off by default.
  PLA-429 measures an uncached title, D3D12 and GPU time; PLA-428, PLA-430 and PLA-425 stay
  open. See [outcome](finished.md#kosmickrisp-graphics-pipeline-library).

- **OpenGL through Zink:** chunks 1a–5 done 2026-10-11 (decisions 0087–0089); see
  [outcome and evidence](finished.md#opengl-through-zink). Remaining work is in
  PLA-181, PLA-184, PLA-186, PLA-189 and PLA-164.

[Finished plans](finished.md) is a historical outcome/link index, not an active
plan. Full removed plans remain in git history. Keep partial plans until mandatory
gates pass or remaining scope is explicitly handed to open linked issues. Removing
a completed run must not erase its evidence or imply its follow-ups passed.

This review changed documentation and tracking only: no plan implementation,
build, phone play, release draft or publication was performed.
