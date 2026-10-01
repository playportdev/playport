# 0022: A game that ran the JIT pool out is stopped inside the app

**Status:** accepted, 2026-09-28. Changes one rule of
[0019](0019-jit-pool-sized-from-the-limit.md): a game still running 10 s
after the pool ran out used to end only the launch, with the game running on
behind the result screen; now the game is stopped. The rest of 0019 stands.
The runs are in the [evidence record](../evidence/2026-09-28-jit-pool-stop.md).

## Decision

- A launch whose game is still running 10 s after the pool ran out stops the
  game inside the app's process (`wine_host_stop`): it shuts down the guest's
  end of the game's socket to the wineserver for writing, and, if the game has
  not ended a second later, the wineserver's end for reading. The wineserver
  reads the EOF as the process's death, as it does when a pseudo-process
  exits (Madeira `process_exit_wrapper` closes the same socket), and kills
  every thread of it: a thread waiting on the server is woken and ends at
  once, any other at its next server call. Once the game's main thread has
  ended, the launch stops the wineserver as after an exit.
- The app stays open, on the result screen: "*title* ran out of JIT memory …,
  so Playport stopped the game". Back to library, Settings and the other tabs
  work as after any game. Another Play still needs Playport closed and
  reopened, as after every game: the pool cannot be blessed again in this
  process.
- If the game has not ended 10 s after the stop, it is left running
  (`still-running`), and the result screen says that Playport could not stop
  it and to close Playport. The app does not close itself.
- The result line is `pool=exhausted:<part> stopped after_s=N` (or
  `still-running`). A `title: stop:` line says whether the game ended, and
  how long after the stop.

## Why

**In-process, because it works and keeps the app.** On the phone the stop
ended Hollow Knight in under 5 ms in 8 of 9 runs: the app went from about
75 % CPU to 2 %, no frame was presented after it, and the driver went on to
the library and Settings. The fallback the task allowed, a controlled exit of
the app, would have made the player reopen Playport by hand (an iOS app
cannot relaunch itself), which is what the result screen already asked.

**It is the runtime's own way a process dies.** In the one-process runtime a
Windows process is a set of threads and one socket to the wineserver, which
already treats that socket's EOF as the process dying and ends its threads as
Wine ends a killed thread. No Wine, Madeira or FEX patch is needed: the stop
is in `wine_host.c`. A killed process's main thread leaves through
`pthread_exit`, not through the `exit()` longjmp a normal exit takes, so
`guest_thread` marks its end with a cleanup handler, which counts only after
a stop (a game's main thread may end on its own while the process goes on).
The one run that was not stopped came from an IPA whose `wine_host.c` lines
did not reach the log, so why is not known; making those lines reach it is
a separate follow-up, not part of this change. The second step, the
wineserver's end of the socket, is kept as a deliberate safeguard for a
shutdown of the guest's end that did not take; the evidence does not show it
is needed: it never fired on the final IPAs.

**The alternatives do less.** Stopping the wineserver under a running game
leaves the game's threads running until each blocks on a server call, and a
thread that renders without one runs on. Suspending the game's threads with
Mach calls stops them anywhere, including inside `malloc` or a lock the app's
own threads take next, which could hang the app. A wineserver-side kill of
every process would also end processes the game started, but needs a Wine
and a Madeira patch, and for threads not waiting on the server it relies on
`SIGQUIT` through `__pthread_kill`, which Madeira found iOS does not deliver
(its wineserver `mach_ios.c`, for `SIGUSR1`).

## What it costs, and what is left

- **Threads parked inside the process stay.** A thread waiting on something
  other than the wineserver (Unity's 21 job workers, its loading threads,
  DXMT's encode and finish threads) is not woken by the kill and stays
  parked, taking no CPU. The game's main thread and its render thread end,
  which is what stops the game. With `inproc-sync` on (off by default), the
  game's own waits would be of this kind too.
- **What the game held stays held**: its memory (about 1.65 GB for Hollow
  Knight), its Metal objects and its part of the pool are not given back, as
  after a normal exit, because the session process lives as long as the app.
- **Processes the game started are not stopped.** They have their own
  sockets, which the app does not hold. No cohort title starts one (0019).
- The stop is used only when the pool ran out. A *Stop game* control for any
  running game could use the same call; none is built.
