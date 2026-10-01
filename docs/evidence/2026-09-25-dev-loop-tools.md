# The dev loop's tools: `pp`, stage digests, lanes, driven-launch events

**Date:** 2026-09-25. **Tree:** branch `devloop-tools` on `f32cf4f`.
**IPA:** `Playport-26.5-9ca36c54.ipa` (dev, lane `devloop`), sha256
`9ca36c5454e12e4cc30c640d4920f654a611719fd45e6f39404b8202fe5de4e4`.
**Phone:** iPhone18,4, iOS 27.0, netmuxd Wi-Fi.

What changed and why: the sessions of 2026-09-24 and 2026-09-25 lost most of
their test time to full rebuilds, stale shared trees, hand-written device
scripts, fixed waits, polling loops and an unclear phone lock. `pp` replaces
those with one entry point (AGENTS.md).

## Build

| Case | Time |
| --- | --- |
| First build in a new lane (every tree) | 11 min (15:02:11 to 15:13:12) |
| Nothing changed (`pp build`: every tree, stage and guests skipped) | 12 s |
| `pp check` (unsigned compile of the staged app) | 4.6 s |
| Release after dev (only `guests`, `app`, `verify` run) | 46 s |
| A Swift change, built and installed (`pp install`) | about 45 s |

`verify-ipa`: 61 checks (dev), 64 (release), none failed.

`check_series` now compares a tree's commits with its series by patch-id.
Against the shared `run/` of this morning it passed `unix/wine`, `pe`, `fex`,
`rpmalloc` and `dxmt`, and caught `unix/mythic` as stale against the current
`patches/madeira-unix`, which the old commit count could miss.

## Phone

| Step | Result |
| --- | --- |
| `pp install --no-build` | installed in place in 14 s; a second run skipped the transfer (same sha256) |
| `pp play hk --until first-frame+10 --shot` | JIT 3.25 s, game start +3.38 s, first frame +12.63 s; screenshot of the menu at 120 fps; app ended; 55 s from the command to its result |
| `pp ui --action open:settings --action set:metalHUD=true --action open:app-367520 --shot-each-action` | each screenshot shows its action's screen (the app waits for the driver's `ui-step-<n>`) |
| `pp gate --steps ladder,g2,title` (`harness/device/gate.py`) | ladder 6/6 (no regression against the FEX rebase record), G2 3/3 unattended, Hollow Knight reached its menu |
| `pp gate --steps title` with the smoke stopping at `first-frame+60` | reached its menu in 1 min 46 s, from 5 min 50 s with the fixed 300 s wait |

The first `pp play` run showed that the app's own `title:` lines written after
the runtime started could vanish from `s1-host.log`: the `first frame` mark was
in `run-events.jsonl` but not in the log. `AppLog.append` now goes through
`host_log`, which writes through stderr once the runtime owns fd 2, as HostIO's
lines already did; the next run's log had `title: +12.59 s first frame`.
Before this, a timeline grep could pick up an older launch's first-frame line.
