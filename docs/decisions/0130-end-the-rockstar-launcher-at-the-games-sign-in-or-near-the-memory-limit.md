# 0130: RDR2's Play ends the whole Rockstar launcher tree at the game's sign-in, or before it near the memory limit

**Status:** accepted, 2026-10-19, chosen by the owner (PLA-409, PLA-413); the headroom and the field
name approved by the supervisor. Amends
[0125](0125-end-the-whole-rockstar-launcher-at-the-games-first-frame.md): the trigger is the
game's sign-in again, as in [0124](0124-end-the-rockstar-launcher-after-the-games-sign-in.md), with
a memory safety. Everything else in 0125 stays. Not yet shown on the phone.

## Context

In run `20261019T185116` ([evidence](../evidence/2026-10-19-rdr2-blue-band.md)), 0125 ended the
launcher at the game's first frame, about 1 s before RDR2.exe loaded `socialclub.dll`. The game's
Social Club then found the launcher's ticket channel `rgsc_gameinst_0` gone (five
`OnChannelError`), never signed in, and showed one still blue frame for 15 minutes.

Memory is lower than when 0125 was chosen:
- libcef is shared (16 KiB relink);
- terminated processes are torn down and their stuck waiters parked (0127);
- the cage hold is gone (0129);
- the footprint peaked at 6.3 GB with the launcher ended.

It can still grow fast. The runtime's `[xp]` `fpMB` lines of runs `20261019T153520` to
`20261019T185116` show:
- 110–180 MB/s over 20 s windows while the game loads;
- single bursts of up to 1.2 GB in 1–2 s, at the game's first frame and at its `socialclub.dll`
  and libcef load;
- the end freeing about 500 MB within a second (run `20261019T185116`, 5,221 to 4,719 MB).

In run `20261019T161557`, with the launcher's `Launcher.exe` alive, the footprint went from 6.1
to 7.3 GB in under 2 s at the game's Social Club load, sat near 7.8 GB, and a last jump of 374 MB
reached the 8,192 MB limit.

## Decision

- **The sign-in ends the launcher.** The whole tree stays alive until the game's own Social Club
  log (`Documents/Rockstar Games/Social Club/socialclub.log` under the prefix user's profile, not
  the launcher's `socialclub_launcher.log` beside it) has this Play's first `Signed in online to
  profile` line (`GameSignIn.Watch`, as 0124). Then `LaunchCoordinator` sends
  `PP_CONTROL_END_LAUNCHER` once, and the root ends the whole tree in one step, as 0125 does.
- **The memory safety.** Until the end, the wait loop reads the app's phys footprint (task_info,
  the counter of the runtime's `fpMB`) every second. When it reaches the limit
  (`os_proc_available_memory()` plus the footprint) less 1,200 MB, 6,992 MB at 8,192 MB, the tree
  ends then anyway, with a `launcher: the footprint reached …` line (`LauncherEndTrigger`).
  - 1,200 MB covers one measured burst between two readings and the second the end takes.
  - A limit iOS does not report never triggers it.
  - It is not tied to the game's first frame.
- **The margin is logged.** Each reading within 2,000 MB of the limit is a `launcher: footprint …`
  line, until the end and for 10 s after it. A sign-in after a memory end is still logged.
- **The field is `endLauncherAfterSignIn` again**, 0124's name. It stays compatibility-only:
  `over()` never takes it from a person. A value saved under 0125's `endLauncherAtFirstFrame` is
  not read.
- **Unchanged from 0125:**
  - never RDR2.exe or a process whose parent chain reaches it, so the game's own
    `SocialClubHelper.exe` is never ended;
  - restarts are counted from the job's messages, and the first still running is ended once more;
  - RockstarService ends by itself;
  - dev and release builds alike.
- **The root's line** no longer names the first frame: `[launcher] ending the launcher, its error
  handler and its Social Club helpers, never the game`. The app's `title: launcher:` line gives the
  trigger. The control still carries no names or arg.

## Costs and risks

- **The safety can come before the hand-off.** If the footprint reaches the threshold before the
  game takes its ticket over `rgsc_gameinst_0`, the end loses the sign-in, as in run
  `20261019T185116`. The next phone run shows which comes first.
- **A burst larger than 1,200 MB** between two readings can still reach the limit before the end.
- **The wait loop** runs in 1 s slices while the end is pending and for 10 s after; the pool,
  band and `[proc-mem]` samples stay about every 2 s.
- **0012:** no UI, environment switch or driver entry point.
