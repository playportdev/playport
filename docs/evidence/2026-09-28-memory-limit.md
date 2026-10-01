# The memory limit in Settings and at Play (runtime risks, item 7)

**Date:** 2026-09-28. **IPA:** `Playport-26.5-6a3b6dbe.ipa` (dev), sha256
`6a3b6dbebe14dbe500054953e6eb31ed31fed3395f376d689008ab10e3b479a1`, built
from `3e91530` (branch `fm/pp-rr-memlimit` on main `96fa472`). iPhone18,4
(11,734 MB of RAM), iOS 27.0, installed in place with `pp install`. The
runs below were one device-lock session:

```sh
pp phone lock -- sh -c 'pp install --no-build --ipa IPA &&
  pp ui --expect-ipa IPA --action open:settings --shot-each-action --until event:ui-done+8 --shot &&
  pp ui --expect-ipa IPA --play app-367520 --until first-frame+10 --shot &&
  pp ui --expect-ipa IPA --action set:memoryLimitSimulatedMB=3379 --action open:settings --action open:app-367520 --shot-each-action;
  pp ui --expect-ipa IPA --action set:memoryLimitSimulatedMB=2048 --action open:app-367520 --shot-each-action --play app-367520 --until done --shot'
```

| Run | Result |
| --- | --- |
| Settings | Memory section: limit 8.0 GB, Increased Memory Limit On, in use 32 MB, phone 11.5 GB, simulated limit Off (shot (screenshot not published)) |
| Hollow Knight play | `title: memory: limit 8192 MB, footprint 25 MB; the title needs 3200 MB (measured, 4000 MB recommended): fits`; JIT after 3.10 s, first frame +8.70 s, ran on 10 s (shot (screenshot not published)) |
| Simulated 3.3 GB | Settings shows 3.3 GB with the real 8.0 GB under it; Hollow Knight's page warns in orange under Play: "This game has used up to 3.1 GB of memory, and iOS lets Playport use 3.3 GB: iOS may close it." (shot (screenshot not published)) |
| Simulated 2 GB, Play | refused before JIT: `title: done … launch=refused memory=2048 need=3200`; the result screen reads "Not enough memory for Hollow Knight" and gives both numbers (shot (screenshot not published)); no crash report |

The next launch outside the session logged `ui: undo session …: restored
memoryLimitSimulatedMB`, so the simulated limit did not outlive the runs.

## What the phone showed

- **The limit moves with Game Mode.** Read at the app's start it was
  6,144 MB in two launches of the four (`memory: limit 6144 MB (footprint 3 MB)`),
  and 8,192 MB in the other two. At Play, and in the runtime's own `ml992`
  line, it was 8,192 MB every time (`os_proc_available_memory=7259 MB +
  phys_footprint=932 MB`). iOS turns Game Mode on a few seconds after the app
  comes to the front (its banner showed over Settings), and the limit rises
  with it. So Settings re-reads the limit every 2 s, and a Play whose limit is
  too low waits up to 5 s for the raise before it is refused. The Witcher 3
  (`memoryMB` 6246) would be refused at 6,144 MB without that wait.
- **The entitlement can be read.** `SecTaskCopyValueForEntitlement` (looked
  up with `dlsym`, HostIO `host_memory.c`) returned true for
  `increased-memory-limit`. The jetsam limit itself cannot be:
  `memorystatus_control(GET_MEMLIMIT_PROPERTIES)` fails with EPERM (the
  runtime's `ml993` line), so the limit is the available memory plus the
  footprint.
- **Hollow Knight's need.** The Metal HUD showed 2.91 GB of app memory at the
  title menu in this run and 3.04 GB in an earlier one on this branch; `pp perf`
  runs of 2026-09-26 recorded up to 3,119 MiB. `titles.json` gives it 3200 MB
  (the older 2.75 GB gameplay figure was below all of these). The Witcher 3
  keeps 6246 MB, the 6.1 GB footprint of
  [witcher3-profile](2026-09-26-witcher3-profile.md).

## Not checked on the phone

- A copy signed without the entitlement: the rules forbid re-signing the
  phone's app with another tool, so the low limit was simulated. The
  refusal and warning texts for a missing entitlement ("This copy of Playport
  was signed without …") were not shown.
- The release build (it compiles: `pp check --variant release`).
- A Witcher 3 play under the check.
