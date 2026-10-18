# Social Club's late children in the Rockstar launcher's Open (PLA-394)

**Linear:** [PLA-394](https://linear.app/playportdev/issue/PLA-394),
[PLA-385](https://linear.app/playportdev/issue/PLA-385),
[PLA-370](https://linear.app/playportdev/issue/PLA-370).
**Plan:** [low-VA CEF](../plans/2026-10-16-cef-low-va-build.md).
**Decision:** [0114](../decisions/0114-trim-social-clubs-chromium-and-the-launchers-threads.md)
(amended). Branch `dev/pla-291-rockstar-launcher`.

**Question:** The launcher's Open fits the 896 MiB JIT pool only some of the time. Every child
process copies its builtins into the pool's head. Which children start after Social Club's
browser, why, and which can go?

## The two earlier Opens

Children are the `spawn_process: creating child thread for` lines of each run's host log
(`$PLAYPORT_BUILD/ui-runs/<run>/pull/s1-host.log`). Pool numbers are the `pool:` lines (head
size / live; tail size / live, in MiB) just before each spawn; times are seconds after the game
started, from the run's events.

| Child (spawner) | `20261017T201653` (IPA `73dc65fc…`) | `20261018T075924` (IPA `7582a206…`) |
| --- | --- | --- |
| services, Launcher, RockstarErrorHandler, LauncherPatcher, Launcher (2nd) | ≤ 6 s | ≤ 6 s |
| RockstarService ×2, dxdiag | 8–22 s | 8–22 s |
| SocialClubHelper browser (launcher) | ≤ 40 s; pool 311/241, 113/97 | ≤ 33 s; pool **433/433, 161/161** |
| renderer 1, 2 (browser) | 43, 45 s; both live | 42 s; the 2nd fails `c0000017` |
| renderer 3 and 7 more attempts (browser) | 54–75 s; all fail after the head ran out at 54 s | 2 attempts fail |
| rpcss (services) / dllhost (browser) | 19 / 18, 95–114 s, all fail | rpcss ×1 at 42 s, fails |
| Unzipper utility (browser) | ×10, 95–111 s, all fail | — |
| on_device_model utility (browser) | ×1, 116 s, fails | — |
| browser | lives to the end | ends itself (`0x80000003`) at 42 s |

**Why `20261018T075924` ran out before the page.** Its first four exits never finished. The
first Launcher.exe, RockstarErrorHandler, `RockstarService start` and dxdiag each called
`NtTerminateProcess`, then faulted in `libarm64ecfex.dll+0x1d46c`
(`FEXCore::Context::ContextImpl::CompileBlock`, a load at null+0x48), and Wine gave up on the
thread (`[exc-stack] cannot deliver exception … aborting thread`, host log lines 15209, 16519,
32643, 41109). No `exit_process` followed, so the pool reclaimed none of them until 56829. In
`20261017T201653` the same four exits reclaimed about 190 MiB of head (`RECLAIM` lines 12045,
12440, 29749, 38078). None of the other 25 launcher Opens since 2026-10-15 shows this fault. It is
FEX's, outside this change.

**What each late child is** (pinned Chromium, `$PLAYPORT_BUILD/cef-src/src`):

- **rpcss / dllhost.** The dllhost's argument `{4991D34B-80A1-4291-83B6-3328366B9097}` is
  `CLSID_BackgroundCopyManager` (BITS; Wine `dlls/qmgr/qmgr.rgs:10`). The browser's
  `ThreadPoolBackgroundWorker` (tid 0228) asks COM for it; Wine's combase first needs RpcSs, so the
  service manager starts `rpcss.exe` (`Failed to start RpcSs service`, line 69345), then the client
  starts the surrogate. The caller is the component updater's BITS downloader
  (`components/update_client/background_downloader_win.cc:386`); one pair per attempt.
  The one rpcss in `075924` is different: the browser's COM STA thread could not load
  `netprofm.dll` in process (`c0000017`, line 57514) and COM tried a local server instead.
- **Unzipper.** The component updater unpacks what it downloads with `unzip::LaunchUnzipper`
  (`chrome/browser/component_updater/chrome_component_updater_configurator.cc:240`). It registers
  its components unless `--disable-component-update` is given
  (`chrome/browser/chrome_browser_main.cc:1790-1793`) and starts a minute after the browser
  (`components/component_updater/configurator_impl.cc:60`). Social Club does not pass the switch.
- **on_device_model.** The optimization guide's on-device model service
  (`chrome/browser/optimization_guide/model_execution/optimization_guide_global_state.cc:186-216`),
  on by default on Windows (`components/optimization_guide/core/optimization_guide_features.cc:99-105`).
- **`pdh.dll` in the browser.** The performance manager's `PageResourceMonitor` and
  `CpuHealthTracker` sample system CPU through `system_cpu::CpuProbe`; on Windows that is
  `CpuProbeWin` (`components/system_cpu/cpu_probe.cc:26-36`), whose PDH queries delay-load
  `pdh.dll` (`build/config/win/BUILD.gn:433`) on a `ThreadPoolForegroundWorker` as sampling starts
  (`components/performance_manager/metrics/page_resource_monitor.cc:194-204`). In `075924` that
  load failed (`c0000017`, line 57397) and Chromium ended the browser.
- **The renderers.** Desktop Proton also runs three (run `trim384-sway`): the spare renderer is
  already off (`--disable-features=SpareRendererForSitePerProcess` on every renderer), so they are
  the page's sites under site isolation, which stays (0109). The phone's later attempts are the
  third renderer being retried after the head ran out; they die at once.

Desktop `trim384-sway` started none of rpcss-on-demand (Proton runs rpcss from the prefix's boot),
dllhost, Unzipper or on_device_model in its five-second samples.

## Change

Compiled defaults, as in 0114 (Social Club replaces `--disable-features`):

- `patches/cef` 0002: the Windows browser appends `--disable-component-update` after the
  application's `OnBeforeCommandLineProcessing`.
- `patches/chromium` 0015: `OptimizationGuideOnDeviceModel` is off on Windows. With it off,
  `NeedsPerformanceClassUpdate` is false, so no performance-class evaluation runs
  (`components/optimization_guide/core/model_execution/performance_class.cc:38-41`).
- `patches/chromium` 0016: `CpuProbe::Create` returns no probe on Windows; every caller handles
  that already.

The renderers, site isolation, FEX, the pool and rpmalloc are unchanged. The incremental build
rebuilt 10 edges; only `libcef.dll` changed: `b8a810eb…` →
`b22e4e188bc3e5c3bc365a4dae542ecb7be06734e230eb2bcd961153a36c9678`. The replay check reproduces the
25 touched files (125 patches, 430 files, no mismatch). Per the owner, no desktop Proton run was
made for this change.
