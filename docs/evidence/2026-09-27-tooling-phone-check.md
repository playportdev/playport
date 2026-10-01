# Tooling changes checked on the phone

**Date:** 2026-09-27. **IPA:** dev `Playport-26.5-6b86f63e.ipa`, sha256
`6b86f63e28aec36d23637699631420a63c23bebe65c3e421f1b7bf7c5f44d9be` (the
reproducible build of [reproducible-build](2026-09-27-reproducible-build.md):
the smaller unix archives). Phone: iPhone18,4, iOS 27.0, over the network, on
battery (53 % to 48 %).

What was run (`.work/session-review/phone-test.sh`), and what it showed:

| Check | Result |
| --- | --- |
| `pp phone status` | a `battery` block (`pct` 53, `external_power` false, `charging` false) |
| `pp install --no-build` | installed in 39 s, upgrade in place |
| `pp phone ls Documents`, `…/prefix/drive_c` | 8 entries each, directories with a trailing `/` |
| `pp phone pull` of a directory | refused, pointing at `pp phone ls` |
| `pp phone pull` of a missing file | refused: "is not in the app's container" |
| Hollow Knight, `pp ui --play app-367520 --until first-frame+10 --shot` | JIT after 3.77 s, first frame at +10.53 s; `argv.txt` in the run directory |
| `pp ui --action open:settings --shot-each-action` | ok |
| `pp pad wait-still` on the main menu | settled after 4.6 s (difference 0.24 against the 1.5 threshold) |
| `pp perf --secs 20 --cool 0`, then `--compare` | 111 fps mean, 120 median; `summary.json` has `battery_start_pct` 50, `battery_end_pct` 50, `charger` false; `run.json` written |
| SIGTERM to `pp ui` mid-play (`timeout --preserve-status -s TERM 40`) | exit 143, `why: "terminated"`, `app_ended: true`; `pp phone status` shows no app pid |
| SIGTERM to `pp perf` | exit 143, `why: "terminated"`; no app left running |
| a waiter behind `pp phone lock -- sleep 75` | `lock-wait` with the holder's `cmd`, repeated at 60 s with `waited_s` |

The first SIGTERM run failed: `pp` ran `tools/ui.py` as a child and did not pass
the signal on, so the app kept running and no result line came. `pp` now
replaces itself with the tool it starts (`handoff` in `pp`), and the second run
above is after that change.

Not checked: the `jit-unreachable` exit (it needs LocalDevVPN off on the phone).
