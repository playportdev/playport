# Agents share the phone: device check (decision 0016)

**Date:** 2026-09-27. **IPA:** `Playport-26.5-4a135450.ipa` (dev), sha256
`4a135450399bcb56a69e85bb549a35ff94d754d677712e90a895943353df5c17`, built in
the `shared-phone` worktree (`.work/worktrees/shared-phone`) from `e51550a`
(branch rebased on main `9fe90a3`). iPhone18,4, iOS 27.0, netmuxd over Wi-Fi.
Each step was its own `pp` command and so took the device lock on its own, as
another agent's command would.

| Step | Command | Result |
| --- | --- | --- |
| 0 | `pp ui --action open:settings` in the worktree, the main checkout's IPA (`eb29878`) on the phone | refused, exit 1, before any launch: "the phone has …Playport's IPA (eb29878, …), not this checkout's" |
| 1 | `pp phone lock -- sh -c 'pp install --no-build --ipa … && pp ui --play app-367520 --until first-frame+10 --shot'` | installed in place under the session's lock, then played in the same session |
| 2 | (the play) | JIT after 4.03 s, runtime +4.14 s, game +4.16 s, first frame +9.48 s, ran on 10 s; `result` carries the IPA's sha256 |
| 3 | session A: `pp ui --action set:metalHUD=true --action open:settings --shot-each-action --expect-ipa …` | ok; log `ui: set metalHUD = true` |
| 4 | session B: `pp ui --action open:settings --shot-each-action` | ok; log `ui: undo session c661a35ca339: restored metalHUD`, event `app:settings-restored` keys `[metalHUD]` |
| 5 | `pp ui --action open:settings` from a second worktree (`pp worktree add`, same commit) | refused, exit 1, before any launch: "the phone has …/shared-phone's IPA (e51550a, …), not this checkout's" |

After the check `pp phone status` showed no holder and the install record
naming the `shared-phone` worktree. Not checked on the phone: two agents
waiting on each other for the lock at the same moment (host tests cover it),
`--settings` undo (same code path as `set:`, not run), and the netmuxd restart
guard (the phone answered each time, so no restart was attempted).
