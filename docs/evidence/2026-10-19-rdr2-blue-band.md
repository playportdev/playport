# 2026-10-19: RDR2 in the foreground for 15 minutes: the blue band is a still frame while the game's Social Club waits with no sign-in

**Linear:** PLA-409, PLA-413, PLA-364. **Decisions:** 0125 (0124, 0127–0129).

## Builds and runs

| IPA sha256 | HEAD | Run | What |
| --- | --- | --- | --- |
| `08e92d2b34d685689d05eca7cafc3a7f923c29cbd556af6d943ccb212c285948` | f106a3b | `20261019T182706` | Hollow Knight gate from the [previous session](2026-10-19-rdr2-socialclub-maps.md): first frame at +10.13 s. Not rerun, because the IPA was the same |
| same | same | `20261019T185116` | RDR2 `--action set:donorPoolMB=auto --play app-1174180 --until first-frame+900 --wait 1800`, a screenshot every 60 s from 60 to 900 s and at the stop, device log kept |

- **Nothing changed** from run `20261019T182804`. The phone already had this IPA, so `pp install --no-build` sent nothing.
- **The phone:** battery 66 % and not charging at the start, 64 % and charging at the end; 4.5 GB free.
- **The owner** tapped OK on PlayRDR2's box and kept the app in the foreground. The tooling pressed nothing.
- **Raw data** is private, under `$PLAYPORT_BUILD`:
  - `ui-runs/20261019T185116/`: the host log, the events and the screenshots;
  - `agent-notes/pla418/run2/`: the device log, the phone status and the Social Club logs pulled after the run.

## The whole play was in the foreground

- **Host log:** no `[susp]` or `main queue has not run` line.
- **Device log:** runningboardd set the app to `Hard Games_Entitled (8192)` at 18:51:25. It never set the app's limit back to `Default Inactive` until the app was ended at 19:08:16, the stop.
  - The other `Default Inactive` lines are the JIT extension's.
  - The one `Background` visibility line, at 18:51:24, is the keyboard's scene.
- **Analysis:** all 1,004 s, start to stop, were in the foreground. No period is left out.

## What showed

Times are from the title's start.
- **Timeline:**
  - The first frame came at +91.65 s.
  - PlayRDR2.exe's "Unable to launch game" box was up from +94.31 s to +96.18 s.
  - The owner's tap at (754,382) closed it, and `MessageBoxIndirectW` returned IDOK.
  - It was the only dialog of the run.
- **The 60 s screenshot:** the launcher's dark start window, with the Rockstar logo.
- **Every screenshot from 120 s to 900 s, and the stop one, is the same file** (sha256 `436fdbb9…`). It shows:
  - a blue band across the full width of the screen, on black, under the touch controls;
  - the band takes up rows 298–439 of 737, centred vertically;
  - its colour is a flat (0, 0, 241), with one-pixel edges of (0, 0, 251) and (0, 0, 65);
  - no text, no logo and no spinner.
- **The game never changed what it showed** for about 13.5 minutes.

## The blue band: a still frame, not a loading screen or a rendering fault

**Presenting.**
- **Rate:** the game kept presenting, 49,920 frames from 18:53:05.4 to 19:08:15.7, about 55 frames a second.
- **Which game:** it is RDR2.exe (pid 0x418), not the launcher.
- **Swapchain:** Vulkan through winevulkan to KosmicKrisp (`Apple A19 Pro GPU (KosmicKrisp 26.2.99)`), 3 images.
  - `[kk-wsi] present … layer=2736x1260 chain=1280x720`;
  - the game's window is `Red Dead Redemption 2`, 1280x720.
- **Translation layers:**
  - RDR2 also made vkd3d-proton D3D12 devices four times while it started (feature probes).
  - DXVK made a D3D9Ex device.
  - Neither presents, and no DXMT or MoltenVK line appears.
- **No GPU errors:** no validation, `VK_ERROR`, device-lost or shader-compile error appears.
- **Shaders:** `[kk-compile]` deserialized 3,136 pipelines by about +96 s and logged nothing after that. The game stopped making pipelines once the band was up.

**File reads** (`[xp]` `rdKB`, per minute of the app's clock):

| Minute | Read |
| --- | --- |
| 0–1 (launcher start) | 601 MB |
| 1–2 (game start) | 1,566 MB |
| 2–3 | 9 MB |
| 3–4 | 0.6 MB |
| 4–5 | 7 MB |
| 5–6 | 120 MB, about +300 s: the game's Social Club helper starting a renderer (below) |
| 6–16 | under 1 MB a minute, and 0 in four of the minutes |

**Threads.**
- **CPU:** about 2 cores from +180 s to the stop. Most of it is the wineserver thread answering `select`, `release_mutex` and `release_semaphore`. RDR2's busiest thread (0x494) made about 300–650 server requests a second (350–785 per 1.2 s `[srv-t]` window), in a wait loop.
- **Game threads:** RDR2.exe has 57–71 threads. No Bink, audio-client or streaming worker is named, only:
  - `dxvk-*` and `dxvk-adapter-0`;
  - `wine_dsound_mixer` ×2 and `wine_mmdevapi_notification`;
  - dinput, xinput and threadpool.
- **The desktop comparison:** in [the desktop Story play](2026-10-15-rdr2-launcher-in-game.md), RDR2.exe had 120 threads, including eight `BinkAsy` and `Bink Snd` video threads.

**Conclusion.**
- **Not a loading screen:** the game reads nothing, compiles nothing and shows no progress.
- **Not the legal or splash screen:** those carry text.
- **No rendering fault in the logs:** there are no Vulkan errors, presents are steady, and the image is constant.
- **What it is:** the band is the one frame the game keeps presenting while it waits.
- **Inferred, not shown:** that it waits for its Social Club (below).
- **Not checked:** whether the band is what the game meant to draw. A Metal frame capture would show it.

## Sign-in: the game's Social Club never signed in

The Social Club logs were pulled from the prefix after the run. Only fixed texts are quoted, and the profile name is left out.

**The launcher signed in.**
- Its `socialclub_launcher.log` has `Signed in online to profile …` at +21.9 s of its log.
- It has `UpdateAutoSignInData: …: false` and `DeleteAutoSignInData: … failed`: the account has no saved auto-sign-in.

**The game's log** (`socialclub.log`, rewritten at 18:53:06):
- `Running title: rdr2`, `Platform: Steam`, `Launcher Mode: false`, `Autologin/Transfer Supported: 1`;
- `SDK fully initialized` at +0.24 s;
- **`[ERROR] SocialClubVulkanLayer.dll not loaded.`** at +0.25 s;
- `Connection state changed from offline to online` at +4.7 s;
- **five `OnChannelError() - rgsc_gameinst_0`** from +4.7 s to +6.5 s: no launcher was serving the game channel;
- `OnChannelConnected - rgsc_ipc_418_channel_0 (remoteProcessId 1428)` and `Browser subprocess running and connected` at +9.0 s;
- **then nothing**: no `Signed in online`, no `IPC system failed to connect to launcher, loading UI`. The app logged no `launcher: the game signed in` line.

**The order, on the app's clock:**

| Time | What |
| --- | --- |
| 18:53:03.2 | the game's first present |
| 18:53:05.4–05.5 | the launcher end (0125): Launcher.exe, its error handler and two SocialClubHelper.exe ended; RDR2.exe and crashpad_handler kept |
| 18:53:06.4 | RDR2.exe maps `socialclub.dll` (0x73f97b0000) |
| 18:53:10–12 | the game's Social Club asks for `rgsc_gameinst_0`: gone |
| 18:53:13.4 | RDR2.exe starts its own SocialClubHelper.exe (pid 0x594, about 46 threads, with `--off-screen-rendering`) |
| about 18:56:42 | that helper starts one `--type=renderer` child (pid 0x67c). It exits by itself, status 0, within about 3 s. No other child starts |

**What this means.**
- **On desktop**, the game's `socialclub.dll` gets its ticket from the launcher over `rgsc_gameinst_0`. In [the desktop play](2026-10-15-rdr2-launcher-in-game.md), after Launcher.exe was ended, the game "signed in online again with the ticket it already held".
- **Here the launcher ended about 1 s before the game's `socialclub.dll` loaded**, so the game never got a ticket.
- **The account has no saved auto-sign-in**, so the game can only sign in through its own Social Club UI.
- **That UI is the overlay.** It renders through `SocialClubVulkanLayer.dll`, which is not loaded. On desktop, RDR2.exe had that DLL among its modules.
- **Inferred:** the game waits for a sign-in it cannot complete and cannot show.

## Memory, pool, band

- **Footprint:**
  - `fpMB` peaked at 6,341 MB at about +309 s, the renderer start;
  - from +360 s it was flat at 6,225–6,230 MB;
  - `[footprint] phys=6230 MB (peak 6335)`, with graphics at 1,558 MB;
  - the limit is 8,192 MB, and there was no memory-limit kill.
- **Device log:** no new JetsamEvent; the newest is the 18:28:57 one from the earlier session.
- **Donor pool:** it served 4,534 MB in 6,459 commits and refused one, of 443 MB.
- **JIT pool (896 MiB):** head 317 MB (172 live), tail 465 MB (385 live), room 115 MB, `exhausted=none`.
- **FEX band:** 16,384 MB, peak 6,191 MB with 315 threads, 5,760 MB in use at the stop, `refused=0`.
- **The launcher end (0125, 0127):**
  - 4 processes ended and 2 kept;
  - 19 threads parked, none refused;
  - all four ended processes torn down, as in run `20261019T182804`.
- **Restarts:** none was logged. The game's own helper is not counted as one.

## How far the game got

RDR2.exe started, presented its first frame and loaded its Social Club SDK. It then showed one still blue frame for the rest of the play, about 15 minutes. It never signed in, and it did not reach a menu or a loading screen with progress.

## Follow-ups

- **The launcher end comes before the game takes its ticket.**
  - 0125 ends the launcher at the first frame.
  - The game loads `socialclub.dll` after its first frame and asks the launcher for the ticket a few seconds later.
  - The end has to wait for that hand-off, not for the first frame.
  - 0124's trigger, the game's `Signed in online` line, is the hand-off's end.
  - That needs a decision amending 0125.
- **`SocialClubVulkanLayer.dll` is not loaded** into RDR2's Vulkan instance on the phone, so the game's own Social Club UI cannot show. Whether winevulkan loads it on desktop Proton, and how, is to be checked on the host first.
- **The band itself:** a `pp gpu capture` of one frame would show whether it is what the game draws.
