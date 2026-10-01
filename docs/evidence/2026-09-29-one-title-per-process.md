# One title per app process, on the phone

**Date:** 2026-09-29. **Change:** [decision 0030](../decisions/0030-one-title-per-process.md).
The session root starts one title and idles, and a game that ran the JIT pool
out is no longer stopped inside the app. **Result:**

- PoolStress, then Hollow Knight, in one driven run across the restart:
  PoolStress started 9 child processes and exited 0 after 26 s. The root
  waited for its job, flushed the registry and reported the exit. Playport
  restarted in 487 ms, and Hollow Knight, in a new process with a new JIT pool
  (2.96 s), drew its first frame 8.80 s after Play and ran on to +10 s.
- Hollow Knight with the simulated pool at 240 MiB ran the head out, drew its
  first frame at 7.62 s and went on running. 10 s later the launch ended
  without it (`pool=exhausted:head still-running after_s=16`). Playport
  restarted in 533 ms, which ended the game, and the new process showed
  *Hollow Knight ran out of JIT memory* over Settings
  (screenshot (screenshot not published)).
- At 184 MiB, the size the earlier stop record used, Hollow Knight fails to
  load at once (`pool=exhausted:head exit=0xc0000135 after_s=0`) and does
  not run on. Playport restarted and showed the same alert.
- Not run: a restart that fails (LocalDevVPN down), where a Play is refused
  with `session=spent` and the game's page offers Close Playport.

IPA `Playport-26.5-2e4167a9.ipa` (dev), sha256
`2e4167a9a3ed833ce3221fffe3c33910d9d49017d7023c704c3882db2c718010`; iPhone18,4,
iOS 27.0.

## Runs

```sh
./pp phone lock -- sh -c './pp install --no-build && ./pp ui --action play:dir-poolstress --play app-367520 --until first-frame+10 --shot'
./pp ui --action set:jitPoolSimulatedMB=184 --action play:app-367520 --action open:settings --shot-each-action
./pp ui --action set:jitPoolSimulatedMB=240 --action play:app-367520 --action open:settings --shot-each-action
```

The session root's lines from the first run, per process:

```
session: title 1: C:\Games\PoolStress\pool-stress.exe in C:\Games\PoolStress, 0 arguments, 5 variables
session: title 1: started, pid 40
session: title 1: ended, exit code 0 after 26074 ms
session: title 1: registry flush 0 in 1 ms
restart: new process pid 14577, 487 ms after pid 14567 asked
session: title 1: C:\Games\Hollow Knight\hollow_knight.exe in C:\Games\Hollow Knight, 8 arguments, 8 variables
session: title 1: started, pid 40
```

The two simulated-pool runs report `ok: false`, as `pp ui` reports every run
that ran the pool out.
