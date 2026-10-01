# CoreDevice finishes a terminate-and-relaunch after its client has gone

**Date:** 2026-09-29. **Question:** a relaunch that Playport requests for itself is
sent by a process that dies within about 30 ms of the app's end. The app itself
dies, and so does its JIT helper
([helper lifetime](2026-09-29-helper-lifetime.md)). Does the phone's service
finish CoreDevice `launchapplication` with `terminateExisting` once the
connection that sent it has closed? **Result:** yes. `dtappserviced` saw its
client disconnect 16 to 22 ms after the request, before it had terminated the
old app. It logged the peer error, then terminated the old app and launched the
new one anyway, in front, in about 230 ms. The same happened in all three trials
in which the request arrived.

## Method

These trials ran from the workstation. The client was a short script under
pymobiledevice3's own Python (kept in `$PLAYPORT_BUILD/probe0/relaunch.py`, not
committed: it is a measurement, not a way into the app). It opens the no-root
userspace RSD tunnel and sends the request `AppServiceService.launch_application`
builds (`com.apple.coredevice.feature.launchapplication`,
`terminateExisting: true`, Playport's bundle ID) with `send_request`, and never
reads the reply. Then, depending on the mode, it:

- `--reply`: reads the reply (the control);
- `--after-ms N`: exits the process N ms after the send;
- `--after-ms N --close`: closes the RemoteXPC connection N ms after the send
  (the FIN follows the request's bytes), then exits 2 s later.

Before each trial, `pp ui --action open:installed --leave-running` left the app
running on its library page. After it, CoreDevice `list-processes` showed the
app's PID at +1, +3 and +8 s, and `pp phone shot` took a screenshot. Each trial
ran under one `pp phone lock`, with device syslog captured. IPA
`Playport-26.5-efe80a5c.ipa` (dev), sha256
`efe80a5c5b351a9a9063af636988662e9f923b1c1a146c1a8e9a9dfe7854a50a`; iPhone18,4, iOS 27.0.

## Results

Times are from the device syslog, relative to `dtappserviced` receiving the request
(`Invoking action (type=LaunchActionImplementation …)`).

| Client | Service sees the client go | Old app terminated | `Launching app` | New app's job | Old → new PID |
| --- | --- | --- | --- | --- | --- |
| waits for the reply (control) | never (the action replied at +249 ms) | +28 ms | +93 ms | +238 ms | 13879 → 13885 |
| exits 0 ms after the send | the request never arrived (see below) | not terminated | none | none | 13888, unchanged |
| exits 50 ms after the send | about +675 ms (the tunnel's teardown) | +33 ms | +65 ms | +228 ms | 13894 → 13899 |
| exits 150 ms after the send | about +700 ms | +23 ms | +69 ms | +237 ms | 13902 → 13907 |
| **closes 20 ms after the send** | **+22 ms** | +22 ms | +71 ms | +223 ms | 13910 → 13915 |
| **closes 0 ms after the send** | **+16 ms** | +24 ms | +54 ms | +231 ms | 13921 → 13926 |

- **Exit at 0 ms:** `dtappserviced` got the connection's handshake (HELO, PING) but
  never the request. The userspace TCP stack had not sent it before the process
  exited. So this trial says nothing about the service.
- **Exit at 50 and 150 ms:** the service completed, but the phone saw the drop only
  about 0.6 s later, after the launch. The userspace tunnel's teardown over the
  network is slow. On the phone, a killed app's socket closes at once, so these
  two trials are weaker than the close trials.
- **Close at 0 or 20 ms: the case that matters.** `dtappserviced` read the FIN
  and cancelled the connection ("Header read returned without data,
  disconnecting", "Canceling with error 57"). It then logged "Received error from
  peer connection", and only after that were the old app's assertions removed.
  The action carried on: "Launching app", runningboardd's "Creating and launching
  job", and at the end "Received reply from action (type=LaunchActionImplementation)",
  a reply with nowhere to go.

The close-at-0 trial, trimmed (team prefix removed):

```
13:34:44.5255 dtappserviced  Invoking action (type=LaunchActionImplementation, ...)
13:34:44.5420 dtappserviced  [RemoteXPC] Header read returned without data, disconnecting
13:34:44.5490 dtappserviced  <ERROR> startListening(...): Received error from peer connection
13:34:44.5499 runningboardd  Removing assertions for terminated process: [app<...playport>:13921]
13:34:44.5799 dtappserviced  Launching app <private> with options: <private>
13:34:44.7570 runningboardd  Creating and launching job for: app<...playport>
13:34:44.7715 dtappserviced  Received reply from action (type=LaunchActionImplementation, ...)
```

The screenshots after the control and the close trials show the new app in front,
on its library page.

## What it means

The decisive unknown of the cold-relaunch design
(`$PLAYPORT_BUILD/research/multigame-alternatives.md`) is answered for the service:
**a combined request survives the death of its sender**. So Playport can relaunch
itself if it, or its helper, can send that one request. It needs no process that
outlives the app, and no second operation after the kill.

Still unmeasured:

- **Sending the request from the phone.** It has to go over LocalDevVPN's loopback
  tunnel with the pairing file, as StikJIT's connections do. The shipped StikJIT
  binary does not contain the operation (the research doc's route 1 or 2). Those
  requests reach the same `dtappserviced`, but whether the RSD handshake and this
  service work from on-device is not yet shown.
- **Who sends it.** The app itself could send it, since the operation needs no
  debugger. That would leave the helper out entirely.
- **The new process:** whether it gets JIT from its own helper as a Home Screen
  launch does, and how long a full cycle takes (Play on B through B's first frame).
- **The environment:** `terminateExisting` with the app in front and a game
  running; the release build; the phone locked or the app in the background.
