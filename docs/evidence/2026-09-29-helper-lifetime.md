# How long the JIT helper outlives the app

**Date:** 2026-09-29. **Question:** a cold relaunch that the app's own JIT helper
requests (kill Playport, launch it again) has to outlive the app, because the
helper is an NSExtension the app started (`BuiltInJit.swift`). For how long
does it? **Result:** about 20 to 50 ms. iOS tears down the extension's context
as soon as the host's connections drop, and launchd ends the helper with
SIGTERM, whether the app ended by `exit(0)` or by SIGKILL. A plain helper cannot
send a request after the app is gone, and cannot wait for one to finish.

## Method

The dev build's Settings has a Probes section (`app/Sources/S1Probe/Dev/HelperLifetimeProbe.swift`);
the UI driver runs it with `pp ui --action probe:helper-exit` or `probe:helper-kill`.
The app starts the helper as a Play does and calls `JITHelping.lifetimeProbe`,
but does not end it (`_kill:`). The helper then:

- appends a line every 50 ms to a file in its own Library, unbuffered, so a line
  that was written survives the process's death;
- logs when its connection to the app drops;
- then runs one StikJIT `prepareDevice`, to see whether a device-service call
  still works after the app is gone.

2 s later the app writes its own end time and ends itself. The next launch
(`probe:helper-report`) reads the helper's file back into `s1-host.log`. Device
syslog was captured alongside with `pymobiledevice3 syslog live`. Both clocks are
the phone's wall clock in ms.

IPA `Playport-26.5-3c59019b.ipa` (dev, from an uncommitted tree on `4d32bfd`), sha256
`3c59019b531b200c9e1bf9ec9c7d43c160521403df24e900aeddb15211e8a99e`; iPhone18,4, iOS 27.0.

## Results

| Host end | Helper sees its connection drop | Helper's last line | Helper's end (launchd) | `prepareDevice` after the host |
| --- | --- | --- | --- | --- |
| `exit(0)` | +6 ms (interrupted) | +15 ms (`checking the tunnel`) | +48 ms, SIGTERM | never finished |
| SIGKILL | +9 ms (interrupted) | +19 ms (`checking the tunnel`) | +33 ms, SIGTERM | never finished |

Each run logged 42 ticks with the app alive (2.05 s) and none after the app's end.

The syslog for the `exit(0)` run, trimmed (the helper was pid 13809, the app 13806):

```
13:03:47.7917 S1Probe[13806]      CoreAnalytics: Entering exit handler.
13:03:47.7997 PlayportJIT[13809]  libxpc: ... calling out to event handler with XPC_ERROR_CONNECTION_INTERRUPTED
13:03:47.8000 pkd[207]            client 13806 is dead
13:03:47.8008 PlayportJIT[13809]  ExtensionFoundation: tearing down context in extension due to invalidation
13:03:47.8009 PlayportJIT[13809]  PlugInKit: host connection from pid 13806 invalidated
13:03:47.8009 PlayportJIT[13809]  libxpc: 'com.apple.NSExtensionContext': Transaction released
13:03:47.8141 SpringBoard         PlayportJIT:13809 Now flagged as pending exit for reason: workspace client connection invalidated
13:03:47.8401 runningboardd       xpcservice<...PlayportJIT([app<...playport>:13806])>:13809 termination reported by launchd (2, 15, 15)
13:03:47.8410 SpringBoard         PlayportJIT:13809 Process exited: ... domain:signal(2) code:SIGTERM(15)
```

runningboardd tracks the helper as `xpcservice<…PlayportJIT([app<…>:13806])>`, an
identity bound to the host's PID, from its launch on.

## What it means for the cold-relaunch routes

- **Kill, then launch through the JIT script's debugserver session (`k`, then `A`/`vRun`):
  ruled out.** Once the app is killed, the helper has about 20 ms before its
  context is torn down, and it is SIGTERMed about 20 ms later. A second
  device-service operation cannot be sent and answered in that time.
- **One combined launch request (CoreDevice `launchapplication` with
  `terminateExisting`) from the helper:** possible only if the phone's service
  carries the request through after the connection of the client that sent it
  drops. That client is the helper, and it dies about 30 to 50 ms after the app
  goes. This probe does not answer that question; it shows that nothing in the
  helper can wait for, or retry, the launch.
- **A helper that holds on does not live longer (probe 0b, below).** The helper's
  launchd job is scoped to the app's. iOS removes it together with the app's,
  whatever the helper does.

## Probe 0b: the helper holds its own transaction and ignores SIGTERM

`probe:helper-kill-hold`: before the app ends, the helper calls `xpc_transaction_begin`
(looked up with `dlsym`: the SDK marks it unavailable on iOS; it resolved), sets
SIGTERM to `SIG_IGN`, and logs each SIGTERM from a dispatch signal source. IPA
`Playport-26.5-efe80a5c.ipa` (dev), sha256
`efe80a5c5b351a9a9063af636988662e9f923b1c1a146c1a8e9a9dfe7854a50a`. The app ended by SIGKILL.

| Host SIGKILL | Connection drop | SIGTERM (ignored) | Last tick | Helper's end (launchd) |
| --- | --- | --- | --- | --- |
| 0 | +10 ms | +22 ms | +33 ms | SIGKILL |

The SIGTERM came *earlier* than in probe 0, so it is not the idle-exit one. In the
syslog, runningboardd removes the app's launchd job as the app dies, and the
helper's SIGTERM, then SIGKILL, follow it:

```
13:19:10.3840 PlayportJIT    (helper's own file) SIGTERM received (ignored)
13:19:10.3857 runningboardd  [app<...playport>:13846] termination reported by launchd (2, 9, 9)
13:19:10.3861 runningboardd  Removing launch job for: [app<...playport>:13846]
13:19:10.3863 runningboardd  <OSLaunchdJob | handle=...>: remove succeeded
13:19:10.3950 PlayportJIT    (helper's own file) tick 43 since-host-gone=23ms: the last line
13:19:10.4406 runningboardd  xpcservice<...PlayportJIT([app<...>:13846])>:13849 termination reported by launchd (2, 9, 9)
```

(The helper's lines are from its file, in the same wall clock. runningboardd
reports the helper's end some 45 ms after its last tick.)

So the extension cannot outlive its host by any means inside the extension.
Whether the app itself or its helper sends a relaunch request, the process that
sends it is gone within about 30 ms of the app's end. Everything then depends on
the phone's service finishing a combined request after its client's connection
drops. It does: [CoreDevice finishes a terminate-and-relaunch after its client
has gone](2026-09-29-coredevice-relaunch-without-client.md).
