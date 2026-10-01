# 0029: Playport restarts itself after each game; the result screen is gone

**Status:** accepted, 2026-09-29. Narrows
[0027](0027-titles-as-children-of-a-session-root.md): the session root
stays (launchers still start child processes), but each app process now plays
one game. The evidence is in
[helper lifetime](../evidence/2026-09-29-helper-lifetime.md),
[CoreDevice relaunch without its client](../evidence/2026-09-29-coredevice-relaunch-without-client.md),
[self-relaunch from the phone](../evidence/2026-09-29-self-relaunch-from-the-phone.md),
[a Play across a relaunch](../evidence/2026-09-29-pending-play-across-a-relaunch.md) and
[the restart after a game](../evidence/2026-09-29-restart-after-a-game.md).

## Decision

- **After a game that used the runtime, Playport restarts itself.** Once the
  title's end is reported (the JIT pool was blessed in this process),
  `AppRestart` asks the phone's CoreDevice app service to launch Playport's
  own bundle with `terminateExisting`. The request goes over LocalDevVPN
  with the pairing file the JIT section keeps. The service ends this process
  and starts a new one on the library. It finishes the request after its
  sender is gone, so no helper has to outlive the app. A restart asked for
  in the background waits until the app is in front.
- **The session root flushes the registry** (`RegFlushKey`, which wine-unix
  0003 makes save every branch) before it reports a title's end, so nothing a
  game wrote is lost to the restart. Files are already on disk.
- **No result screen.** A clean exit (code 0) says nothing. A launch refused
  before the runtime started (memory, JIT, missing executable or backend,
  self-check) says why in an alert, and nothing restarts. A game that failed
  after starting (a crash code, the JIT pool running out) restarts too, and
  the new process shows why once, in an alert over the library. "Played for"
  and `Outcome.seconds` are removed.
- **If the restart fails** (LocalDevVPN down), the process stays, says why,
  and plays again only if the session root can take another title (0027);
  otherwise the game's page offers Close Playport.
- **idevice is built into the app** (`build/stages/idevice.sh`, a real
  `pins.lock` pin, the `pins.lock` Rust installed by
  `build/toolchain/rust.sh` under the build area). It is prelinked into one
  object that exports four calls, so its Rust runtime does not clash with
  GStreamer's. Its crates' notices are collected by `pp notices`.
- **The driver follows a run across the restart** (dev builds): the run's
  variables and the actions left go to `Documents/ui-continue.json`, and the
  new process continues them. `back:library` is gone.

## Why

A process runs one Wine session, one JIT pool and whatever threads a game
left. Resetting that inside the process (0027's pseudo-process reclamation, or
a full runtime reset) is a long list of state to prove clean. A new process
resets all of it, for about 0.5 s from the request to the new process's first
line, plus the next Play's JIT (about 3 s, as for any first Play).

## Costs and open items

- Every game switch needs LocalDevVPN, as every JIT already does.
- A game that never ends its process leaves the app on the game's surface.
  The Witcher 3's Exit did that on 2026-09-29, with every thread waiting on
  the wineserver after its window was gone. Neither a watchdog that ends such
  a game nor the deadlock's cause is done.
- The crash and refusal alerts have not been seen on the phone yet.
- The release build has not been run on the phone with this.
