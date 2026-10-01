# The restart after a game, on the phone

**Date:** 2026-09-29. **Change:** [decision 0029](../decisions/0029-restart-after-each-game.md).
When a game that used the runtime ends, the session root flushes the registry,
Playport asks CoreDevice to restart it, and the new process opens on the
library. **Result:**

- A clean exit restarted to the library with no alert, in 540 to 623 ms from
  the request to the new process.
- A driven run went on across the restart and played the next game to its
  first frame.
- Hollow Knight, closed by the person at the phone, restarted the same way.
- The Witcher 3's Exit never ended its process, so nothing restarted: the app
  stayed on the game's black surface until it was ended.
- The crash and refusal alerts were not seen: the test meant to produce a
  crash hung instead (below).

IPA `Playport-26.5-fb52c8d6.ipa` (dev), sha256
`fb52c8d6483d91ed141a8e134cdab169ebb4d9117adfce5791dc4fda79af70f7`; iPhone18,4,
iOS 27.0.

## Runs

| Run | What happened |
| --- | --- |
| `pp ui --action play:dir-poolstress --action play:app-367520 --until first-frame+10` | PoolStress ended with code 0 after 26 s. The root logged `registry flush 0 in 0 ms`, and the continuation took `play:app-367520`. The tunnel and RSD took +11 to +152 ms, the request was sent at +153 ms, and the new process (14249 → 14260) logged 540 ms after the request. Hollow Knight's first frame came 9.19 s after Play. The run was ok. |
| `pp ui --play dir-poolstress` | Exit code 0, registry flushed, request sent at +223 ms, new process (14274 → 14284) after 623 ms. A screenshot 8 s later shows the library, with no alert. |
| `pp ui --settings 'dir-poolstress:{"arguments":"child 0"}' --play dir-poolstress` (meant to exit with code 4) | Wrong test: in `child` mode PoolStress waits for its parent's events, so it never exited, and the app stayed on the game's surface until `pp phone kill`. |
| The person at the phone: Hollow Knight, closed, then The Witcher 3, Exit from its menu | Hollow Knight: exit code 0, registry flushed, new process 464 ms after the request. The Witcher 3 reached its menu (first frame at +19.4 s). After Exit it destroyed its window (`no foreground window (fg=0x0)`), but its process never ended. Every thread, including its task threads, FAudio's and mmdevapi's, was waiting on the wineserver (`wait_select_reply`), so no end was reported and nothing restarted. |

Run directories: `$PLAYPORT_BUILD/restart/20260929-143537` and
`$PLAYPORT_BUILD/restart/user-test`.

## Open

- **A game whose process does not end.** The Witcher 3's Exit left the app on
  its surface. Whether it deadlocked the same way before this change is not
  known: no earlier run let it exit. There are two ways out, and neither is
  done: find the deadlock, or have the root end a game that has closed every
  window and not exited within a grace period.
- **The alerts.** A crash after start (restart, then an alert over the library),
  a refusal before the runtime starts (an alert, no restart) and a failed restart.
- **The release build** on the phone.
