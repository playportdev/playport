# Playport relaunches itself from the phone

**Date:** 2026-09-29. **Question:** can the app send the combined CoreDevice
request itself, and does the phone then replace it? The workstation has shown
that the phone's service finishes `launchapplication` with `terminateExisting`
after its client has gone
([CoreDevice finishes a terminate-and-relaunch after its client has gone](2026-09-29-coredevice-relaunch-without-client.md)).
Here Playport sends the request itself, over LocalDevVPN, with the pairing file
its JIT section keeps. This is route 1 of the cold-relaunch research.
**Result:** yes, in 4 of 4 trials. The old process is replaced and the new one
comes up in front, on its library page. From the button to the new process's
first line of code took 425 to 628 ms. No debugger and no JIT helper are
involved: the app sends the request from its own process.

## What was built (a spike, outside the pipeline)

- **idevice's C FFI for iOS**, a static library. It is built at the `idevice`
  commit `pins.lock` records as notice-only (`d32c8189`), with only the features
  the chain needs:
  `cargo rustc --release --target aarch64-apple-ios --no-default-features --features ring,tcp,core_device,core_device_proxy,tunnel_tcp_stack,rsd --crate-type staticlib`.
  - Toolchain: Rust 1.98.1 from a self-contained rustup under `$PLAYPORT_BUILD/toolchain/rust`,
    since the system's Rust has no iOS std.
  - C and assembly for `ring`: the system clang, with `-target arm64-apple-ios17.0`
    and xtool's iPhoneOS 26.5 SDK as `SDKROOT`.
  - Linker: clang with `-fuse-ld=lld`. A dependency, `plist_ffi`, also builds a cdylib.
  - `--remap-path-prefix` for the toolchain, the registry and the source, and
    `-ffile-prefix-map` for the C: without them, `verify-ipa.py` fails 350 home
    paths in the executable.

  The resulting `libidevice_ffi.a` is copied by hand to `app/Staged/lib/`.
- **`app/Sources/DevRelaunch`** (C, dev builds only, and only with
  `PLAYPORT_IDEVICE=1`). It declares the four FFI calls it uses and runs them in
  StikJIT's order:
  1. `rp_pairing_file_from_bytes`;
  2. `tunnel_create_rppairing` to `10.7.0.1:49152`, which gives the tunnel's TCP
     adapter and the RSD handshake;
  3. `app_service_connect_rsd`;
  4. `app_service_launch_app` for the app's own bundle, with `kill_existing = 1`.

  The pairing file is an RP pairing file (keys `identifier`, `private_key`,
  `public_key`, `alt_irk`), not a lockdown pairing record. The lockdown and
  CoreDeviceProxy route cannot use it: the first trial failed there.
- **`app/Sources/S1Probe/Dev/SelfRelaunch.swift`**: Settings' Probes section gets
  **Relaunch Playport (CoreDevice)**, and the UI driver `probe:relaunch`. Before
  sending, the app writes `Documents/relaunch-request.txt` (the time and its
  PID). The next process logs the gap at its init (`relaunch: new process …`).

The executable is 6.7 MiB larger with idevice (dev, `-Onone`).

## Results

IPA `Playport-26.5-f6f92c5a.ipa` (dev, `PLAYPORT_IDEVICE` built in), sha256
`f6f92c5a99a5485dd1dc1b473c2dd60075343fe461070c87a7e15a970eae078c`, plus one earlier
trial on `87a54fe8…` (identical chain; it logged the bundle ID, which was
removed). iPhone18,4, iOS 27.0, LocalDevVPN connected. Each trial:
`pp ui --action probe:relaunch --leave-running`, then CoreDevice
`list-processes` at +2, +4 and +8 s, a screenshot, and the app's log.

| Trial | Tunnel + RSD | App service | Sent | New process's init | Old → new PID |
| --- | --- | --- | --- | --- | --- |
| 1 (`87a54fe8`) | +3 → +140 ms | +148 ms | +149 ms | +425 ms | 13964 → 13967 |
| 2 | +4 → +122 ms | +124 ms | +124 ms | +541 ms | 13977 → 13980 |
| 3 | +1 → +190 ms | +192 ms | +192 ms | +628 ms | 13987 → 13990 |
| 4 | +4 → +174 ms | +184 ms | +184 ms | +547 ms | 13998 → 14001 |

Times are from the button (the chain's start), from the app's own log. The new
process's line compares its clock with the time the old process wrote. The app
stayed on the new PID at +8 s each time. The screenshots show the new process
in front, on the Installed tab.

The service's side of trial 1, from the device syslog (team prefix removed):

```
13:48:14.0455 dtappserviced  Invoking action (type=LaunchActionImplementation, ...)
13:48:14.0607 runningboardd  Removing assertions for terminated process: [app<...playport>:13964]
13:48:14.1885 dtappserviced  Launching app <private> with options: <private>
13:48:14.2864 runningboardd  Creating and launching job for: app<...playport>
13:48:14.3072 dtappserviced  Received reply from action (type=LaunchActionImplementation, ...)
```

About 0.15 s of each cycle is the RemotePairing tunnel, 0.02 s for the old
app's end, and 0.25 s for the launch. How long the new process takes to show
its first frame of UI was not measured.

## Costs of making it real

- **A Rust stage.** It needs a Rust toolchain with an iOS std in `pp setup`, a
  build stage, and a real `idevice` pin in place of the notice-only one. Moving
  that pin then needs `pp sync`-style care.
- **Two Rust runtimes in one executable.** `libwinegstreamer_unix.a` already
  carries one: `ld` warns `duplicate symbol '_rust_eh_personality'` and keeps
  one. The spike ran with that. Whether it matters if either side unwinds a panic
  has not been checked, and a stage must settle it (one crate that links both,
  or a renamed symbol).
- **A second copy of idevice** beside StikJIT's, in the helper. Size: 6.7 MiB in
  the app's executable.
- **Every game switch depends on the VPN.** The relaunch needs LocalDevVPN
  connected, as the JIT does for every launch already.

## Not yet shown

- **A Play in the new process.** The pending-Play continuation, JIT from the new
  process's own helper, and B's first frame. The relaunched process started as a
  Home Screen launch does, with no environment, so a driven Play needs that
  continuation (or the request's `environmentVariables`) first.
- **Relaunching from a running game**, where the old process holds a Wine
  session, a blessed JIT pool and GPU work, rather than the library page.
- **The release build, the phone locked, the app in the background.**
