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
| [Performance review](2026-09-30-performance-review.md) | [PLA-79](https://linear.app/playportdev/issue/PLA-79) | Partial; reconcile historical hypotheses against implemented defaults and current code. |
| [KosmicKrisp FL12_2](2026-10-05-kosmickrisp-fl12_2.md) | [PLA-81](https://linear.app/playportdev/issue/PLA-81) | Research-only draft promoted from `.work/plans/`; refresh old capability/pin assumptions before execution. |
| [Proton ARM64 alignment](2026-10-05-proton-arm64-alignment.md) | [PLA-76](https://linear.app/playportdev/issue/PLA-76) | Partial; pins moved/held or superseded, alignment and Portal 2 follow-ups remain. |
| [Release simplification](2026-10-05-release-simplification.md) | [PLA-73](https://linear.app/playportdev/issue/PLA-73) | Open; shared filtering and release checks remain; old decision number is taken. |
| [KosmicKrisp default](2026-10-06-kosmickrisp-default.md) | [PLA-77](https://linear.app/playportdev/issue/PLA-77) | Open/partial; full i386 set and DXMT retirement are not done. |
| [Madeira audit](2026-10-06-madeira-audit.md) | [PLA-75](https://linear.app/playportdev/issue/PLA-75) | Partial; pure-x64 pool copies and NSI tables addressed, other dives remain. |
| [PC import, GOG and Epic](2026-10-06-pc-import-gog-epic.md) | [PLA-80](https://linear.app/playportdev/issue/PLA-80); implementation PLA-14/15/16 | Implementation landed, but required phone checks and deferred work remain; closed implementation issues are not the remaining-work tracker. |
| [Vulkan performance](2026-10-06-vulkan-performance.md) | [PLA-72](https://linear.app/playportdev/issue/PLA-72) | Paused 2026-10-08 on `vulkan-performance-2` (unmerged): six fixes kept (present path, tiler off, no present wait, compression-keeping texture usage, PLA-93 freeze deferral); not at exit. Handoff: the plan's last Progress entry. |
| [Reported games without owning them](2026-10-07-compat-testing-without-owning.md) | [PLA-12](https://linear.app/playportdev/issue/PLA-12), with its existing game/feature issues | Open; reuse the existing umbrella, no duplicate. |
| [Runtime DLL coverage](2026-10-07-runtime-dll-coverage.md) | [PLA-78](https://linear.app/playportdev/issue/PLA-78) | Not started; exact-build census is a hard pre-staging gate. |

Status here records the review, not live issue state. Linear is authoritative for
what to do next. Overlapping performance/alignment/audit plans must share findings,
not schedule the same fix independently.

## Build-area drafts reviewed

- **KosmicKrisp FL12_2:** unfinished and distinct from backend migration. Promoted
  the research plan above, removed private inventory/storage/pricing assumptions,
  and linked PLA-81 to PLA-77/PLA-76/PLA-72. The original Mesa move is already
  reflected in current pins; capability proposals still need validation.
- **PC import, GOG and Epic:** removed the stale `.work/plans/` duplicate. The
  version here contains later owner decisions (Local imports stay Local, no
  installers) and progress/evidence. PLA-80 already tracks remaining work; no
  duplicate issue or discarded requirement was revived.

Neither build-area draft was a completed execution run. Their local copies were
removed after review; raw private FL12_2 research remains in `.work/scratch/fl122/`.

## Completed runs removed

- **Guest VA exhaustion:** the fix and final regression gates passed; see
  [outcome and evidence](finished.md#guest-address-space-exhaustion). Separate
  cache and VA-layout work stays in PLA-76/PLA-75.
- **Store-game sign-in:** the implementation run ended and its open follow-ups
  already have issues; see [outcome and evidence](finished.md#games-sign-in-to-their-store).
  Release was not completed: [PLA-74](https://linear.app/playportdev/issue/PLA-74)
  now tracks that handoff.

[Finished plans](finished.md) is a historical outcome/link index, not an active
plan. Full removed plans remain in git history. Keep partial plans until mandatory
gates pass or remaining scope is explicitly handed to open linked issues. Removing
a completed run must not erase its evidence or imply its follow-ups passed.

This review changed documentation and tracking only: no plan implementation,
build, phone play, release draft or publication was performed.
