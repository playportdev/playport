# Kingdom Come: Deliverance and helper-owned memory

**Date:** 2026-10-03. Isolated `research/extended-memory` worktree, runtime
integration at `a2c7d61`, based on main `2f2240e`. iPhone18,4, iOS 27.0.
**IPA:** `Playport-26.5-05971459.ipa`, SHA256
`0597145977ce4ee7770ef6fe8a9b79071fe2651eaabfab05ed19fb8af2d10905`.
The app was already installed; no uninstall or container replacement.

This follows the [original KCD memory measurements](2026-10-01-kcd-memory.md)
and the [Hollow Knight helper-backing proof](2026-10-03-fex-helper-memory.md).
The old KCD evidence matters: reporting less RAM/VRAM did **not** shrink its
actual allocations; the demonstrated lever was reducing the JIT pool from
896 to 512 MiB (decision 0036).

## FEX-only comparison

All paths below are worktree-relative. A local orchestration script uses
only existing `pp ui`, `pp pad` and read-only phone commands. Each run holds
one device-lock session throughout:

- Set `helperOwnedFEXMemory` off/on through the UI driver; Play `app-379430`
  with the scripted pad. No per-game launch setting is overridden.
- After first frame, B presses skip the logos/history introduction.
- Screenshot and OCR the menu's New Game / Load Game / Settings labels
  before pressing A on the highlighted Continue. No blind fixed-delay A.
- Wait 45 seconds and take a loaded screenshot; push existing `kcd-walk`.
- The UI reads usage at Play+110, +170 and +230 seconds and opens the
  in-game menu. Both runs then stop normally. There are about 80 seconds
  of walking after the loaded screenshot.
- Wait two minutes before each measured launch. Both start at nominal
  thermal state and reach fair/serious during the run: this is not a
  controlled performance comparison or a sustained-pressure test.

| Measurement | FEX off | FEX on |
| --- | ---: | ---: |
| Directory | `.work/kcd-fex-off-2` | `.work/kcd-fex-on` |
| First frame after Play | 25.23 s | 25.40 s |
| Recognized menu, from orchestration start | 109.00 s | 108.84 s |
| Peak app footprint (`[xp] fpMB`, MiB) | 7,468 | 7,554 |
| App footprint at Play+230 | 7,777,495,568 B | 7,855,909,296 B |
| Helper footprint at Play+230 | no broker | 86,951,656 B |
| Helper mapping requests at Play+230 | none | 346 |
| Cumulative requested backing at Play+230 | none | 2,615 MiB |
| Refusals/fallbacks | none | 0 |

Both result events are `ok: true`; JIT self-checks pass. Both use the same
512 MiB pool: head 182 MiB, tail 161 MiB, room 170 MiB, no exhaustion.
Both loaded screenshots show the same Rattay courtyard, NPC and buildings;
stop screenshots show the in-game menu over the world after walking.
Logs: `run/pull/s1-host.log`, `run/events.jsonl`, `game-log/kcd.log`.
Screenshots remain local, not published.

The game's own logs in **both** runs report **8,192 MiB physical RAM** and
**1,536 MiB dedicated video memory**, Machine class 1. We did not raise
advertised budgets as part of this comparison.

**Result: no demonstrated peak-footprint improvement.** The on run's peak
was 86 MiB higher in this single pair, despite roughly 75 MiB of data being
charged to the helper above its ordinary baseline. Allocation/streaming
variance can overwhelm that small redistribution; this does not establish
that the broker itself increases memory by 86 MiB. Requested backing is
cumulative virtual size, not resident memory or reclaimed app footprint.
FEX-only backing is too small a target to claim it solves KCD's memory limit.

## Calibration run excluded

`.work/kcd-fex-off` reached the actual main menu, but OCR misread the
highlighted Continue word. The orchestrator deliberately did not press A,
timed out, and sent SIGTERM to its UI driver, which ended the app. It was a
test-harness recognition failure, not a game crash or jetsam result. The
measured pair above uses the other menu labels to recognize that screen.

Checks: no app/runtime code changed for these runs. Existing dev/release
verification and full host tests apply to the tested IPA; the new evidence
passed the names and secrets gates.
