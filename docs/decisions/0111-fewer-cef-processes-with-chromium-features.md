# 0111: A CEF browser runs its network and video capture services in its own process

**Status:** accepted, 2026-10-16, chosen by the owner (cut the CEF process tree with Chromium's
own switches). **Amends [0109](0109-chromium-switches-for-a-cef-browser.md)**: its switch set
only. [PLA-378](https://linear.app/playportdev/issue/PLA-378),
[PLA-370](https://linear.app/playportdev/issue/PLA-370),
[plan](../plans/2026-10-16-cef-low-va-build.md).

## Context

With fonts fixed, the Rockstar Games Launcher's Open on the phone reached Social Club's
`START_SIGN_IN`, then ran out of the 896 MiB JIT pool (0108) one second later
([evidence](../evidence/2026-10-16-cef-fonts-phone.md)):

- The tree had 13 processes. The pool head held 534 MB of builtin copies made for each process
  (`shell32` 87 MB over 9 processes, `libarm64ecfex` 64 MB and `kernelbase` 43 MB over 14
  each).
- The pool tail held 363 MB of FEX code: renderer 160 MiB, browser 144 MiB, network service
  96 MiB.
- The band peaked at 15,862 of 16,384 MB.

Each Chromium child process costs the pool its own builtin copies and FEX code buffers. Under
desktop Proton, the same build with 0109's switches runs 8 Chromium processes: the browser, the
network, storage, audio and video capture services, and 3 renderers.

This is what Chromium 143's source allows:

- **Network service.** It runs in the browser when the feature `NetworkServiceInProcess2` is on
  (`content/public/common/content_features.cc`). The recon's `NetworkServiceInProcess` was the
  pre-rename name, which is why it had no effect.
- **Video capture service.** It runs in the browser with `RunVideoCaptureServiceInBrowserProcess`.
- **Storage service.** It has no switch. It runs out of process unless `--single-process` is set,
  which breaks Social Club's UI.
- **Audio service.** It runs in the browser when `AudioServiceOutOfProcess` is turned off. But
  Social Club gives its children its own `--disable-features` value, so the value a browser is
  started with is lost (inferred from the children's command lines).
- **`--renderer-process-limit`.** It is a soft limit: each site keeps its own renderer, and
  Social Club fails with one renderer (0109).
- **V8's code range.** It is 512 MB for each isolate. No `--js-flags` flag sets it.

## Decision

- **Switches.** 0109's switch set gains one switch:
  `--enable-features=NetworkServiceInProcess2,RunVideoCaptureServiceInBrowserProcess`.
- **Scope.** It is added where and as 0109's four are (madeira-unix 0152): only to a CEF
  browser. If the app already passes an `--enable-features`, the app's own is kept as it wrote it
  and logged as kept.
- **Not added:**
  - `--renderer-process-limit=1`, which had no effect;
  - `--disable-site-isolation-trials`, which breaks Social Club's IPC;
  - `--disable-features=AudioServiceOutOfProcess`, which Social Club overrides.

## Consequences

- **Fewer processes.** Under desktop Proton, Social Club's tree goes from 8 Chromium processes to
  6, and the sign-in page still shows: Social Club reached `FINISHED` in 2.5 s, against 2.5 s
  before. CEF's PSS fell from 2,689 to 2,114 MiB and its threads from 207 to 175
  ([evidence](../evidence/2026-10-16-cef-fewer-processes-phone.md)).
- **Load moves into the browser.** The browser now does the network and video capture work, so
  its FEX code grows by what those services ran.
- **Still separate:** the storage and audio services and one renderer per site. The 512 MB V8
  code range per isolate (0110's build) is unchanged; reducing it would need a Chromium patch.
- **Other CEF apps.** Another CEF app gets the same set. A launcher that needs another set gets a
  new record, as 0109 says.
