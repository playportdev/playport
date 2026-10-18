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

## The phone

IPA `0f8b3ff5e96e461cfdb618bc0d6f394207af7c2e871def80e61e61766595420c` (`./pp build` exit 0, 87
checks; its `libcef.dll` is `b22e4e18…`), one `pp phone lock` session on battery (18 %, not
charging; the owner said go on).

- **Hollow Knight `20261018T083148`:** first frame +9.03 s; the stop screenshot shows the title
  menu (Start Game, Options, Achievements, Extras, Quit Game) with the touch controls.
- **Open `20261018T083301`:** no first window. The run ended at its 600 s bound
  (`no stop condition within --wait`); every screenshot (45, 60, 90, 150, 240 s) is black. The
  setting was set and cleared (`set_rc=0`, `clear_rc=0`).

Social Club never started, so the change was not exercised. The launcher hung earlier:

- As in `20261018T075924`, the first Launcher.exe's exit faulted in `libarm64ecfex.dll+0x1d46c`
  (`CompileBlock`, null+0x48; host log lines 13229–14618) and so did RockstarErrorHandler's
  (14749–15867). Neither reached `exit_process`.
- The second Launcher.exe's main thread (00a0) stopped after `vkd3d_instance_init`, during the
  launcher's own D3D12 query (its `launcher.log` never opened). From 60 s to the end it waits
  on `0x10b528d78` (`[waiters] tid=00a0 … age=606s`). That address is 0x50 into the first
  Launcher's FEX code tracker (`tracker=0x10b528d28`, thread 0048), not its own
  (`0x114040d28`): it waits on the dead process's FEX state, which the aborted thread
  presumably left locked.
- The pool was not the limit: head 262 MiB, tail 113 MiB, no exhaustion; the band peaked at
  2,062 MB.

Two Opens in a row now hit this exit fault, and no launcher Open before 2026-10-18 did. Without a
working Open, whether the late children are gone and whether Tahoma brings the page's text
(PLA-385) are both untested. The fault is FEX's; FEX is the owner's call.

## The same Open with FEX's disk cache off: the sign-in page with its text

The exit fault appeared only when FEX's disk cache for the build was warm. The first `[diskcache]`
line of the first Launcher.exe:

| Open | `[diskcache]` hits / misses | exit faults (`cannot deliver exception`) |
|---|---|---|
| `20261017T191412` | 43 / 2,027 (cold) | 0 |
| `20261017T201653` | 43 / 2,027 (cold) | 0 |
| `20261018T075924` | 3,915 / 91 (warm) | 4 |
| `20261018T083301` | 4,095 / 1 (warm) | 2 |

Open `20261018T085305` ran the same installed IPA (`0f8b3ff5e96e461cfdb618bc0d6f394207af7c2e871def80e61e61766595420c`)
with the launcher's settings `{"runtime":"env.FEX_SMCCHECKS=none","diskCache":false}`, set and cleared
in one lock session (`set_rc=0 open_rc=0 clear_rc=0`). Battery 16 %, not charging.

- No exit fault. First window at +30.28 s; the run reached first window+240.
- Children: services, Launcher.exe ×2, RockstarErrorHandler ×2, LauncherPatcher, RockstarService ×2,
  the CEF browser and 6 renderer starts. No dxdiag, rpcss, dllhost, Unzipper or on_device_model.
- Screenshots:
  - 45 s: the launcher's "Connecting to Rockstar Games Services".
  - 60 s: the Social Club page's background, a faint R★ and the footer text "© 2026 ROCKSTAR GAMES |
    PRIVACY POLICY | TERMS OF SERVICE | COOKIE SETTINGS".
  - 90, 150 and 240 s: the **Sign In form with its text**: the heading "Sign In", the Email and
    Password placeholders, the "Auto Sign In" checkbox, and the cookie notice with its paragraph,
    "ACCEPT ALL COOKIES", "REJECT ALL" and "COOKIE SETTINGS".
- The pool still ran out later (head 454/476 MiB, tail 421 MiB, head exhausted ×40, tail
  refused ×13, one tail_fatal), from renderer restarts; the form stayed up to the end. The band
  peaked at 12,174 MB (163 threads).

So with the disk cache off, the Tahoma fallback (chromium 0014) draws the page's text, and the
late children of the component updater, the on-device model and the CPU probe are gone. The exit
fault with a warm disk cache is a FEX bug, tracked separately; it was not changed here.

## The launcher's disk cache off by default (`81082f9`)

IPA `e89750a1d131b1a2658a5174ed45150b5331aa838225c7c7a958b986f4c0c2bc`. One lock session; battery 12 %, not
charging. The launcher's saved settings carried only `env.FEX_SMCCHECKS=none`, so the entry's new
default chose the disk cache.

- Hollow Knight (`20261018T090836`): first frame +8.97 s.
- Open `20261018T090949`: no `[diskcache]` lines and no exit fault, so the default took effect. But the
  pool ran out before the page: head 480 MiB, tail 417 MiB, head exhausted ×80, at 13 children
  (dxdiag ran this time). Renderers died with `c0000017`/`c000001d`, and at 62 s the launcher exited on
  its own (exit 0). Every screenshot was black or the run's end. No Sign In page.

With the disk cache off, one Open of two showed the Sign In page (`20261018T085305`) and one ran out of
pool first (`20261018T090949`). Each held about 420 MiB of FEX code buffers (the tail). The Open still
fits the 896 MiB pool only some of the time.
