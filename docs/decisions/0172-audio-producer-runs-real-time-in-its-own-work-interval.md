# 0172: A render stream's producer thread runs real-time in its own work interval, and a starved stream plays whole callbacks

**Status:** accepted, 2026-10-30, by the owner (PLA-364, found in PLA-476's l19). Option A of the audio
design, with the owner's choice of an own work interval over the RemoteIO unit's workgroup, and C1. Relates to
[0162](0162-the-witcher-3-pause-as-wfe.md) and [0163](0163-the-witcher-3-keeps-yield.md) (how the clamp and
spinning threads take a core, and the measure for a runtime default), and to
[0091](0091-compat-default-keys-merge.md) (the Runtime keys that turn it off). No earlier record covers guest
thread QoS or ECO. [Evidence](../evidence/2026-10-30-rdr2-kk-audio-diagnostics.md#audio-madeira-unix-0240-0241).
Built in madeira-unix 0244–0246. Not yet measured on the phone.

## Context

- **RDR2's sound is slowed and holed in its heavy scenes.** In l19's clamped scene slot 1 delivered 44–47 % of
  real time. Every callback was short, and no ReleaseBuffer gap was over 40 ms: the producer is throttled, not
  stalled.
- **Nothing raises it.** Every guest thread runs timeshare at USER_INTERACTIVE, and 13–37 of them wait for an E
  core. No Windows priority reaches the kernel: RAGE asks TIME_CRITICAL for 17 threads, and all stay at UI 47.
- **The driver plays every frame late, never drops one.** A short callback plays what it has and leaves the rest
  of it silent, so at 46 % each 21 ms callback is about 10 ms of sound, then a hole.
- **The first GetBuffer caller is not the producer.** In Hollow Knight and RDR2 it is a 4800-frame prefill by
  the main thread before Start. HK's mixer is FMOD's thread, which asks MMCSS for "Audio".
- **Apple's guidance** (`AudioToolbox/AudioWorkInterval.h`): a thread at the audio device's I/O cadence joins
  the device's workgroup. A real-time thread at its own cadence creates its own interval with
  `AudioWorkIntervalCreate` and marks each cycle with `os_workgroup_interval_start`/`finish`. A WASAPI producer
  polls or waits at its own cadence, so it is the second kind.

## Decision

- **The gate: the steady caller of a started stream.** A thread becomes a render stream's producer on its 32nd
  GetBuffer in a row while the stream is started, and the stream must be mixed into the RemoteIO unit. Calls
  before Start (a prefill) never count, and the count starts again at each Start. Alternating callers qualify
  nobody.
- **Real-time policy.** The producer gets `THREAD_TIME_CONSTRAINT_POLICY`: period 10 ms (the device period the
  driver reports), computation 5 ms, constraint 10 ms, preemptible.
- **Its own work interval.** The producer joins an interval of its own (`AudioWorkIntervalCreate`, Mach
  absolute clock), one per producer thread: a thread is in one workgroup at a time, and one thread may feed
  two streams. It is the interval's only member, and it marks each cycle itself:
  - a successful GetBuffer starts a cycle, with the deadline 10 ms later (the policy's constraint);
  - its ReleaseBuffer finishes it.

  The copy between the two calls takes far less than 10 ms, so a deadline is missed only when the producer
  cannot get a core inside its own cycle. A deadline from the ring's padding was not taken: it would be missed in
  every clamped scene and ask for frequency under the thermal clamp that starves the producer.
- **Teardown.**
  - The driver holds a send right to the producer's thread (`mach_thread_self`), freed with its record, so
    the port name is never reused for another thread while the driver can use it.
  - Stop, Release, process end (0127's ended pseudo-processes) or a new producer demote the old one at once,
    from whichever thread calls them, through that right.
  - The interval is joined, marked and left only on the producer itself. A demoted producer finishes its open
    cycle and leaves at its next GetBuffer or ReleaseBuffer, or at its exit (a pthread key destructor, which
    also releases the interval). If the caller of Stop or Release is the producer, it leaves at once.
- **The CPU guard.** Every 2 s the producer reads its own CPU time:
  - above 80 % of one core since the last check, it is demoted for good (`rt refused`): a thread that holds a
    core is not a mixer;
  - a policy found reset (an ECO QoS change, or anything else) is set again, under the lock a demotion takes,
    so a demotion from another thread is never undone.
- **C1, the underrun hysteresis.** A stream short in 2 of its last 8 callbacks plays what it has, then nothing
  until max(one callback, 20 ms) of its frames are queued (capped at half its ring), or for at most 3
  callbacks.
  - Its position holds while it waits, as on any underrun, and nothing is dropped.
  - A stream that is never short, or short once in 8 callbacks, plays exactly as before.
  - Skipping the position ahead (C2) stays rejected.
- **Every WASAPI title, dev and release.** No title's compatibility default turns either off.
- **The off switches.** Runtime keys `env.MADEIRA_AUDIO_RT=0` (no promotion) and `env.MADEIRA_AUDIO_REFILL=0`
  (no C1). Both are read once per process at the driver's attach, and each logs a line when set.
- **Not taken.** Windows thread priorities stay unapplied (B1: it would promote 17 RDR2 threads, the main thread
  among them). MMCSS (avrt) stays a stub.
- **Logging.**
  - Always: `rt promote` when the policy is refused, `rt refused` (the guard), `rt join … refused`, an
    interval that cannot be created, and the two off lines.
  - Only without `MADEIRA_NO_DIAGNOSTICS` (dev): `getbuf-producer`, ml1065's `caller_switches=`/`producer=`,
    `rt promote`, `rt demote`, `rt join`, `rt reassert`, and the 2 s `rt producer … cpu= interval= cycles=
    cycle_errors=` line.

## Costs and risks

- **A main thread that is also a stream's producer runs real-time.** While runnable it preempts every timeshare
  thread on its core, up to one core. The guard bounds that, and XNU's fail-safe puts a thread that runs too
  long without blocking back to timeshare, which is today's state.
- **Spinning on real time.** An RT producer that spins (critical-section spin counts, FEX PAUSE as YIELD per
  0163) burns its computation. The guard or the fail-safe is the remedy. Waiting on a UI-47 holder costs what it
  costs today.
- **Frequency and heat.** The interval lets CLPC see the producer's cycles; what it does with one member's
  missed deadlines on this phone is unknown. Time to the clamp, CPU W and fps after it are watched in the gate.
- **The clock after repeated underruns.** It stalls up to about 3 callbacks (≈64 ms at 1024 frames) longer per
  episode, and padding reads higher while it waits. ml1065's `underrun_frames` now means frames a callback did not
  play, not frames it lacked. A healthy title with clustered transient shorts gets one gap of up to 64 ms instead
  of a few short holes.
- **N streams, N RT threads.** One per stream at most: RDR2 and Portal 2 have two.
- **A parked thread** (0127) never leaves its interval; it is its own interval, so nothing else is affected.

## Evidence needed

- Before/after on one IPA, arms off (`env.MADEIRA_AUDIO_RT=0 env.MADEIRA_AUDIO_REFILL=0`) and on, alternating:
  HK `pp perf` and first-frame+10; the RDR2 heavy scene (the steady slot-1 producer named, slot 1 ≥ 95 % in the
  clamp, no `rt refused`, fps no worse than about 10 %, no new jetsam); The Witcher 3 `pp perf` judged on the
  frame-interval tail as 0163 asks. Then an owner listen in RDR2's cabin.
