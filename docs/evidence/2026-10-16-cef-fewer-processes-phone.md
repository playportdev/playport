# 2026-10-16: Social Club's network and video capture run in the CEF browser; the JIT pool and the band still fill (PLA-378)

**Linear:** [PLA-378](https://linear.app/playportdev/issue/PLA-378), for
[PLA-370](https://linear.app/playportdev/issue/PLA-370) stage D. Plan:
[CEF low-VA build](../plans/2026-10-16-cef-low-va-build.md). Decision:
[0111](../decisions/0111-fewer-cef-processes-with-chromium-features.md), which amends 0109 by the
owner's choice.
**Change:** `patches/madeira-unix` 0156 (after 0152). A CEF browser also gets
`--enable-features=NetworkServiceInProcess2,RunVideoCaptureServiceInBrowserProcess`.
**Question:** Which of Chromium 143's own switches cut Social Club's process tree? With them, does
the Rockstar Games Launcher's Open fit the 896 MiB JIT pool and the 16 GiB band and reach the
sign-in page?

- **IPA:** dev, sha256 `887442a3cc4d1df4b782dcc77a6e9f3833c4e9fbe5dc2a2f63f344600c7a2f2a`, built
  from `ae4d7cb` (branch `dev/pla-291-rockstar-launcher`); `verify-ipa` 87 passed.
- **Phone:** iPhone18,4, iOS 27.0.1, at 80 % with 4.2 GB free. The owner was attended.
- [M] measured, [S] read in Chromium 143.0.7499.193's source, [I] inferred.

## Result

- **The switch works on the phone [M].**
  - The browser's `[chromium]` line lists the new feature switch after 0109's four.
  - No network service and no video capture service started. Before the pool filled, the
    browser's children were the storage service, two renderers and the audio service.
- **Social Club loaded its UI and kept its browser longer [M].** It reached `START_SIGN_IN` and
  `FINISHED` at 8.2 s, as in the previous Open. This time it did not log "Main browser connection
  lost".
- **The sign-in page was not on screen [M].** The session ended at +65 s on a full JIT pool.
- **Hollow Knight still works [M].** Its first frame came at +9.98 s, and the screenshot shows the
  title menu.

## Chromium 143's switches [S]

| Process | Switch or feature | In M143 |
| --- | --- | --- |
| Network service | `--enable-features=NetworkServiceInProcess2` | Feature `kNetworkServiceInProcess`, named `"NetworkServiceInProcess2"` (`content/public/common/content_features.cc:631-632`), read by `IsInProcessNetworkServiceImpl` (`content/browser/network/network_service_util_internal.cc:45-64`). The recon's `NetworkServiceInProcess` is not that name, so it had no effect. |
| Video capture service | `--enable-features=RunVideoCaptureServiceInBrowserProcess` | `content_features.cc:900-901`, `:1399-1409` |
| Audio service | `--disable-features=AudioServiceOutOfProcess` | `content_features.cc:108`. Social Club overrides this switch (below). |
| Storage service | none | Out of process unless `--single-process` is set or the user-data directory is empty (`content/browser/storage_partition_impl.cc:239-276`). `--single-process` breaks Social Club's UI. |
| Renderers | `--renderer-process-limit=1` | A soft limit: a renderer is reused only when one suits the site (`content/browser/renderer_host/render_process_host_impl.cc:1429`, `:5119-5149`). Site isolation keeps sites apart. `--disable-site-isolation-trials` gives one renderer, which breaks Social Club's IPC (code 161; the [recon](2026-10-15-rockstar-launcher-recon.md)). |

- **CEF passes `--disable-features` on, merging its own entries in**
  (`cef/libcef/common/chrome/chrome_main_delegate_cef.cc:362-377`). But Social Club's children
  carry only `--disable-features=SpareRendererForSitePerProcess`, without CEF's own entries.
  So Social Club replaces the value after CEF merges it [I, from command lines only].
- **V8's code range:**
  - With pointer compression off (0110's build), each isolate reserves its own code range
    (`v8/src/heap/heap.cc:5948-5965`).
  - Its size is `min(512 MB, ullTotalVirtual / 8)`, set by gin (`gin/isolate_holder.cc:191`,
    `v8/src/api/api.cc:535-549`).
  - No V8 flag sets it, so `--js-flags` cannot reduce it.
  - Under `--jitless`, V8 needs no code range (`Isolate::RequiresCodeRange`,
    `v8/src/execution/isolate.cc:7659`), but gin's non-zero size reserves one anyway.

## Desktop Proton first [M]

Stage C's swap was used: the low-VA build (0110) in a scratch prefix's Social Club folder, with the
Stage R wrapper adding the switches. Each run lasted 150 s, under sway. Afterwards the originals were
restored, and the folder's 81 files match their hashes.

| Switches | Chromium processes | Sign-in page | `FINISHED` | CEF PSS / threads at 150 s |
| --- | --- | --- | --- | --- |
| 0109 (stage C) | 8: browser, network, storage, audio, video capture, 3 renderers | yes | 2.5 s | 2,689 MiB / 207 |
| 0109 + `--enable-features=NetworkServiceInProcess2,RunVideoCaptureServiceInBrowserProcess` + `--disable-features=AudioServiceOutOfProcess` | 6: browser, storage, audio, 3 renderers | yes, 30–150 s | 2.5 s | 2,114 MiB / 175 |
| the same + `--renderer-process-limit=1` | 6, still 3 renderers | yes | 2.3 s | 2,092 MiB / 176 |

- With the features on, the browser's main thread holds the sockets.
- The audio service still started, because its `--disable-features` value was replaced.
- 0111 therefore adds only the `--enable-features` switch.

## Phone Open [M]

One lock session: the launcher setting `env.FEX_SMCCHECKS=none`, then Open, then the setting
cleared.

- **Social Club states** (ms from SDK start):
  - `WAIT_BROWSER_WINDOW` 188; browser connected 799;
  - `LOADING` 3251; `WAITING_FOR_PAGE_LOAD` 3291;
  - first renderer channel connected 5629;
  - `WAITING_FOR_PAGE_READY` 7828;
  - `PAGE_READY` and `START_SIGN_IN` 8218, `FINISHED` 8222;
  - second renderer channel connected 10313, channel error 14019.
- **Screenshots:**
  - 30 s: Playport's loading screen ("Starting the game…");
  - 60 s: the launcher's first window (+30.5 s), all black;
  - 150 s, 230 s and stop: Playport's alert "Rockstar Games Launcher ran out of JIT memory".
- **Process tree when the pool filled:**
  - the session root, `services.exe`;
  - `Launcher.exe` with its crash handler, `LauncherPatcher.exe`, `RockstarService.exe`;
  - the CEF browser, its storage service and two renderers.
  - Earlier, the first `Launcher.exe`, its crash handler, the first `RockstarService.exe` and a
    `dxdiag /t` had already exited.
  - The first audio service could not load `xtajit64.dll`, because the pool was full. The browser
    then started the audio service about 50 more times, and each start failed the same way. Later,
    `rpcss.exe` and a ProcessorMetrics utility also started.
- **JIT pool (896 MiB):**
  - head 524 MB (446 live), tail 373 MB (321 live), room 0;
  - 346 images, 15 children, `head_exhausted=89`, `tail_refused=12`, `exhausted=head`.
  - Head copies made by each live process (cumulative): `Launcher.exe` 97 MiB, the browser 78,
    the storage service and each renderer 54, `LauncherPatcher` 46, `RockstarService` 37, the
    crash handler 26, the root 20, `services.exe` 16.
  - Tail when the pool filled: the browser 144 MiB, renderer 1 68 (peak 96), renderer 2 52
    (peak 112), the storage service 32, and the other processes 16 each.
- **Band:** peak 16,227 / 16,384 MB, used 15,844, largest free 32 MB, `refused=1`, 200 threads.
- **Footprint:** peak 6,169 MB.
- **Comparison with the previous Open ([fonts](2026-10-16-cef-fonts-phone.md)):**
  - Before: 13 processes, the browser lost at 9.1 s, band peak 15,862 MB, footprint 5,849 MB.
  - Now: no network service. Renderer 2 lived and took 112 MiB of tail and its own address-space
    reservations, so the pool and the band filled anyway.

## V8 code range correction [M]

The previous record counted renderer 1's `[bigres]` lines as 8 V8 code ranges of 512 MB. Each code
range is in fact four requests, which is V8's Windows `OS::Allocate` retrying:
- a hint near the previous range, refused with `c0000018`;
- two random hints outside the band, refused with `c000000d`;
- no hint, which succeeds.

In this run, renderer 1 made 8 such requests and 6 were refused, so it held two code ranges.
For renderer 2's 4 requests the log has no refusal lines, so its count is not established.
The `[bigres]` total counts requests, including refused ones.

## Not done

No sign-in, and no Red Dead Redemption 2 or Online. Rockstar's logs and the phone's screenshots
stay in the build area.
