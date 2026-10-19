# 2026-10-19: RDR2 rerun with a warm pipeline cache: no loading bar, but Social Club error 18, so no sign-in and no launcher end

**Linear:** PLA-409, PLA-413, PLA-364. **Decisions:** 0130 (amending 0125; 0127).

## Build and run

| IPA sha256 | HEAD | Run | What |
| --- | --- | --- | --- |
| `7b43aedf9e64cd52e81546cd8144f3f93b74513718f427679a4b408f34fe81d6` | c146a2a | `20261019T201131` | RDR2 `--action set:donorPoolMB=auto --play app-1174180 --until first-frame+900 --wait 1800`, a screenshot every 60 s from 60 to 900 s and at the stop, device log kept |

- **Nothing changed** from run `20261019T194156`
  ([evidence](2026-10-19-rdr2-launcher-end-at-sign-in.md)): the same IPA, already installed, so no
  install. The Hollow Knight gate was not rerun: this IPA passed it in run `20261019T194056`.
- **The phone:** battery 80 % at the start and the end (on external power at the end); 5.9 GB free at both.
- **Nobody pressed anything.** PlayRDR2's box never appeared, so the owner had nothing to tap.
- **Raw data** is private, under `$PLAYPORT_BUILD`:
  - `ui-runs/20261019T201131/`: the host log, the events and the screenshots;
  - `agent-notes/pla413/run0130b/`: the device log, the phone status, and the game's and the
    launcher's Social Club logs pulled after the run.

**Times** are wall-clock (the phone's). The app's `title:` clock puts the title's start at about
20:11:49.5 (first frame at +82.9 s).

## Confounder: the same Steam account on a desktop

A parallel desktop test signed the same Steam account into desktop Steam at 20:11:46, about 3 s
before the title started. Desktop Steam was logged off as "Logged In Elsewhere" at 20:12:57. The
phone's logs show no sign that its own session was affected:
- **Steam client:** no `[cm] connection closed`, reconnect, `[auth]` or log-off line. The only
  Steam lines are the nine `[ticket]` ones, all successful. The launcher's ticket was acked by Steam
  at 20:11:58.7 and checked by a server (`EAuthSessionResponse 0 (OK)`) at 20:12:36.3. The game's
  two tickets were made and acked at 20:13:10.5–10.8.
- **The launcher was online:** it signed in online at about 20:12:37. The game's Social Club log
  has `Received user info request from launcher (launcher in online mode …)`. The launcher logged
  the game instance as `Offline: online`.
- **No offline lines:** neither log has `Game launch is in offline mode` or `Launcher is not signed
  in online`.
- **What is not shown:** the phone's client logs a closed connection, but not a server log-off
  message on a connection that stays open. So a server-side effect at 20:12:57 cannot be fully
  ruled out.
- **The desktop variant** without the layer showed the same error 18, with the launcher offline
  there (the parallel test).

So error 18 does not follow from the Steam overlap.

## What happened

| Time | Footprint (MB) | What |
| --- | --- | --- |
| 20:11:55 | 1,967 | PlayRDR2.exe, then Launcher.exe |
| 20:12:19 | 2,824 | the launcher loads `socialclub.dll`; its browser and three renderers start (to 20:12:29) |
| about 20:12:37 | 3,774 | the launcher signs in online (its log) |
| 20:12:39–40 | 3,781 | two of the launcher's SocialClubHelper processes end (not 0130) and are torn down: `kept 564 MB` and `kept 478 MB`, 3 threads parked |
| 20:12:46 | 3,494 | RDR2.exe starts |
| 20:13:11 | 3,948 | the game's DXVK and vkd3d-proton devices |
| 20:13:12.4 | 4,028 | **first frame** (+82.9 s; run `20261019T194156`: +93 s) |
| 20:13:13.9–15.5 | 4,028 → 5,572 | **3,136 pipelines read from the cache, 0 translated**: `translated=0 (0 ms) deserialized=3136 (1774 ms) metal=1723 ms` |
| 20:13:16.1 | 5,634–5,678 | **RDR2.exe loads `socialclub.dll`** (+1 min 27 s from the start; run `20261019T194156`: +618 s) |
| 20:13:16.5 | | the game's log: `SDK fully initialized`, then `[ERROR] SocialClubVulkanLayer.dll not loaded.` |
| 20:13:17.0 | 5,480 | `SocialClubVulkanLayer.dll`, `SocialClubD3D12Renderer.dll` and libcef are mapped into RDR2.exe and not run (below) |
| about 20:13:21.5 | 5,644 | **the game reaches `rgsc_gameinst_0`**: `Connection state changed from offline to online`, `OnChannelConnected - rgsc_gameinst_0 (remoteProcessId 112)` (Launcher.exe), `Received user info request from launcher (launcher in online mode …)` |
| about 20:13:22 | 5,667 | the game's log: `Game instance connected`, its last line. The launcher's log: `Game instance initialized`, `Offline: online`, its last line |
| 20:13:25–28 | 5,674 → 6,089 | the last rise |
| by 20:13:46 | 6,056 | **the screen shows "SOCIAL CLUB ERROR"** (below) |
| 20:13:59 | **6,254** | peak (`[xp]`); then flat at 6,05x–6,09x MB to the stop |
| 20:28:19 | 6,080 | the stop (first frame + 900 s): `[footprint] phys=6080 MB (peak 6200)`, compressed 1,969 MB, graphics 1,548 MB |

## The pipeline cache was warm

- **Every pipeline came from the cache:** KosmicKrisp read 3,136, as many as in run
  `20261019T185116`, and translated none. That took 1.77 s, 1.72 s of it building the Metal
  pipelines. There was no loading bar.
- **The cache:** Mesa's disk cache in the app's `Library/Caches/kosmickrisp/mesa_shader_cache`
  (multi-file), size limit 1 GB (`wine_host.c`).
- **The key:** mesa 0015 keys it on the driver's build ID, the GPU family, the MSL version, the
  disabled workarounds and forced robustness. On iOS the build ID is the Mach-O `LC_UUID` of
  `KosmicKrisp.framework`.
- **The IPA hash is not in the key:**
  - the framework's `LC_UUID` is the same (`4c4c44f5…ec52`) in IPA `08e92d2b…` (warm in run
    `20261019T185116`) and IPA `7b43aedf…` (cold in run `20261019T194156`);
  - only the files differ, by their signatures.
- **So why run `20261019T194156` was cold is not explained** (1,858 translated, 190 read). Neither
  the key nor the IPA explains it. Not checked: whether Mesa's 1 GB limit evicted RDR2's entries,
  or whether iOS purged `Library/Caches` between the runs. Settings › Storage shows the cache size.

## Social Club

- **`SocialClubVulkanLayer.dll` is mapped, never loaded as a layer:**
  - At 20:13:17.0 it is mapped into RDR2.exe. `SocialClubD3D12Renderer.dll` is mapped at the same
    address right after it, so the first was already unmapped.
  - The launcher does the same at 20:12:19.1, when its log validates the Social Club dependency
    versions.
  - Neither DLL, and not the game's libcef either, gets the FEX `Load module` line that every x64
    image that runs here gets (RDR2.exe, `socialclub.dll`, `steam_api64.dll`, SocialClubHelper.exe).
    The same holds in run `20261019T194156`.
  - So these maps are the SDK's version check. The earlier evidence's "mapped into RDR2.exe … the
    first time in a phone run" is a version read, not a load.
- **The SDK still logs `SocialClubVulkanLayer.dll not loaded.`**, 22 ms after `SDK fully
  initialized`, before any channel connects.
- **The ticket and sign-in:**
  - The game reached `rgsc_gameinst_0`, and the launcher answered as online.
  - There was no ticket hand-off line after that.
  - The game's log has no `Signed in online`, and the app logged no `launcher: the game signed in`.
- **`Entering State` lines:**
  - the game's `socialclub.log` (7,154 bytes): **none**;
  - the launcher's `socialclub_launcher.log`: 7, which are `WAIT_BROWSER_WINDOW`, `LOADING`,
    `WAITING_FOR_PAGE_LOAD`, `WAITING_FOR_PAGE_READY`, `PAGE_READY`, `START_SIGN_IN`, `FINISHED`.
- **The game did not start its own SocialClubHelper.** No process was created after
  crashpad_handler.exe at 20:13:04. In run `20261019T194156` it started one only after the
  launcher's end.

## The end (0130)

**None.** The game never signed in, and no footprint reading reached the 6,992 MB threshold: the
peak was 6,254 MB, 738 MB below it. The only `launcher: footprint` lines were 6,214 MB at +123.3 s
and 6,200 MB at +124.4 s. No `[launcher]` end line, no restart; the app ended no process of the launcher
tree. With no end, PlayRDR2.exe showed no "Unable to launch game" box. There was no kill:
the device log has no JetsamEvent for this run (the day's two are from 14:51 and 18:28).

## Other counters at the stop

- **JIT pool (896 MiB):** head 285 MB (270 live), tail 481 MB (433 live), room 131 MB, `exhausted=none`.
- **FEX band:** 16,384 MB, peak 5,668 MB with 269 threads, `refused=0`.
- **Donor pool:** served 4,486 MB in 6,558 commits, refused 3.
- **The app stayed in the foreground:** no `[susp]` or `main queue has not run` line.

## The screens (images stay in the run directory)

- **60 s (20:12:46):** the launcher's dark start window, with the Rockstar logo and window buttons.
- **120 s (20:13:46) to the stop:** the same image each time (identical files):
  - the game's own error screen on black, titled "SOCIAL CLUB ERROR";
  - its text: "Social Club failed to initialize graphics device. Error code: 18. Press OK to visit
    Rockstar Games Customer Support to help resolve this issue. Press CANCEL to exit.";
  - Accept/Cancel prompts at the bottom right, under the touch controls.
- **When error 18 appeared** is between the SDK's "not loaded" line (20:13:16.5) and the 120 s
  shot; nothing finer is shown. The Steam overlap window (20:11:46–20:12:57) ended before the game
  loaded its Social Club.

## How far the game got

With a warm cache RDR2.exe reached its first frame at +83 s and loaded its Social Club 4 s later.
That Social Club initialised, did not load its Vulkan layer, and reached the online launcher's
game channel. Then the game stopped at Social Club error 18 ("failed to initialize graphics
device") and did not sign in; that screen stayed for 15 minutes. No menu was reached. Footprint
6.1–6.25 GB with the whole launcher tree kept.

## The ~1.6 GB the four ended processes kept in run `20261019T194156`

- **The `[proc-end]` `kept` figure is committed bytes:** it is the size of the views a teardown
  leaves, not their footprint. The line has one total, not split by kind (0169's
  `ppe_release_view`).
- **The kept total was 1,580 MB:** Launcher.exe 0x70 716 MB (6 threads parked),
  SocialClubHelper 0x1b4 821 MB (11 parked), the renderer 0x28c 39 MB, RockstarErrorHandler
  0x7c 4 MB.
- **Kept views lose their owner and count as the runtime's.** In the `[proc-mem]` samples either
  side of the end, the runtime row's FEX band grew from 1,188 to 2,559 MB committed (+1,371 MB).
  Before the end, the band of 0x70 was 593 MB and of 0x1b4 779 MB (1,372 MB).
- **So about 1.37 GB is the FEX band of the two processes with parked threads.** With a thread
  parked, 0169 frees only the L1 caches of a process's band: the rpmalloc spans, call-return
  stacks and other band views stay, as the parked threads' FEX state names them. The other
  ~0.2 GB is views their saved registers point into, or kept ranges.
- **Its footprint share is much smaller.** Just before the end these two band shares were 251 MB
  resident and 132 MB compressed: about 0.38 GB of footprint, not 1.6 GB.
- **The same happens before the game starts.** The two SocialClubHelper processes that the launcher
  itself ends at about 20:12:39 keep 564 + 478 MB here (665 + 600 MB in run `20261019T194156`).
  They have 3 parked threads.

## Follow-ups

- **Error 18 now blocks the sign-in,** before memory does. Next: the Social Club SDK's Vulkan
  layer, which it reports "not loaded" in every run and never runs. That is the parallel
  `SocialClubVulkanLayer.dll` research, and the desktop shows the same error.
- **0130's threshold was not tested.** The hand-off never came, and the peak stayed 738 MB under it.
- **Why run `20261019T194156`'s cache was cold** is open (above).
