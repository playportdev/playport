# 2026-10-19: RDR2 with the launcher kept until the game's sign-in: the memory safety ends it first, 3 s after the game reaches the launcher

**Linear:** PLA-409, PLA-413, PLA-364. **Decisions:** 0130 (amending 0125; 0124, 0127).

## Builds and runs

| IPA sha256 | HEAD | Run | What |
| --- | --- | --- | --- |
| `7b43aedf9e64cd52e81546cd8144f3f93b74513718f427679a4b408f34fe81d6` | c146a2a | `20261019T194056` | Hollow Knight `--play app-367520 --until first-frame+10 --shot`: first frame at +11.67 s. Passed |
| same | same | `20261019T194156` | RDR2 `--action set:donorPoolMB=auto --play app-1174180 --until first-frame+900 --wait 1800`, a screenshot every 60 s from 60 to 900 s and at the stop, device log kept |

- **One `pp phone lock` session:** install in place, the gate, then RDR2.
- **The phone:** battery 80 % on external power at the start and the end; 6.6 GB free at the start, 6.0 GB at the end.
- **The tooling pressed nothing.** PlayRDR2's box was not tapped during this run (below).
- **Raw data** is private, under `$PLAYPORT_BUILD`:
  - `ui-runs/20261019T194156/`: the host log, the events and the screenshots;
  - `agent-notes/pla413/run0130/`: the device log, the phone status, and the game's `socialclub.log` pulled after the run.

**Times** below are wall-clock (the phone's), or `+N s` from the game's start on the app's clock
(`title: launcher:` lines). The driver's timeline counts from the surface, about 5.6 s earlier.

## Where the game's Social Club log is

`Documents/prefix/drive_c/users/playport/Documents/Rockstar Games/Social Club/` on the phone holds
both logs, side by side:
- the game's `socialclub.log` (`Launcher Mode: false`, `Running title: rdr2`): 7,654 bytes
  before the run, 8,186 after;
- the launcher's `socialclub_launcher.log`.

So the file and the directory 0130 watches are the game's; only the file name differs from the
launcher's. At the title's start the app logged `its log holds 7654 bytes of an earlier start`, the
size of run `20261019T185116`'s game log. The game rewrote it at 19:52:31.

## What happened

| Time | App clock | What |
| --- | --- | --- |
| 19:42:13 | +0 s | the game starts (PlayRDR2.exe, then the launcher) |
| 19:42:20–52 | +7 to +39 s | the launcher loads `socialclub.dll` and starts its Social Club browser and renderers |
| 19:43:02 | +49 s | RDR2.exe maps |
| 19:43:47 | +93 s | the game's first frame |
| 19:43:47–19:52:30 | +93 to +617 s | a black screen with a loading bar along the bottom that fills slowly: about 30 % at the 120 s shot, 97 % at the 600 s one. The game translates 1,858 Vulkan pipelines (KosmicKrisp: `translated=1858`, `deserialized=190`). In run `20261019T185116` all 3,136 had been read from the cache, with no bar |
| 19:52:31.6 | +618 s | RDR2.exe maps `socialclub.dll`. Its log: `SDK fully initialized`, then `[ERROR] SocialClubVulkanLayer.dll not loaded.` |
| 19:52:32.2 | +619 s | RDR2.exe maps libcef and `SocialClubVulkanLayer.dll` (after the SDK's error line) |
| about 19:52:37 | about +624 s | the game's log: `Connection state changed from offline to online`, `OnChannelConnected - rgsc_gameinst_0 (remoteProcessId 112)` (Launcher.exe), `Game instance connected` |
| 19:52:39.9–40.8 | +626 s | the footprint jumps from 5,752 MB to 7,111 MB in about 1 s |
| 19:52:40.5 | +626.9 s | **the memory safety ends the launcher**: `launcher: the footprint reached 7111 MB of the 8192 MB limit before the game's sign-in; ending the launcher at +626.9 s to free its memory` |
| from about 19:52:40 | | the game's log: six `OnChannelError() - rgsc_gameinst_0` |
| 19:52:41 | +627 s | PlayRDR2.exe's "Unable to launch game, please try reinstalling the game." box (`MessageBoxIndirectW`, caption "Error") |
| 19:52:43 | +629 s | RDR2.exe starts its own SocialClubHelper.exe. The game's log ends with `OnChannelConnected - rgsc_ipc_420_channel_0` and `Browser subprocess running and connected` |
| to 19:59:02 | to the stop (+1,008 s) | the box covers the screen; no further game log line |

## Did the game sign in?

**No.**
- The game's log has no `Signed in online` line, and the app logged no `launcher: the game signed in` line.
- **The game reached the launcher this time.** Its Social Club connected to `rgsc_gameinst_0`,
  served by Launcher.exe (pid 112, 0x70), and logged `Game instance connected`. In run
  `20261019T185116` that channel was gone and only `OnChannelError` came.
- **The ticket did not arrive** in the ~3 s between `Game instance connected` and the end. The
  memory safety fired during the game's Social Club load, before the hand-off, as decision 0130's
  costs foresaw. After the end the channel errored, and the game went no further than in run
  `20261019T185116`.

## The end (0130)

- **Trigger:** memory, not sign-in. The first footprint reading at or above the 6,992 MB threshold
  (8,192 − 1,200) was 7,111 MB, at +626.9 s. No reading before it was within 2,000 MB of the limit:
  the reading a second earlier was below 6,192 MB.
- **What ended:** the root logged `[launcher] ending the launcher, its error handler and its Social
  Club helpers, never the game`. It ended Launcher.exe pid 112, RockstarErrorHandler.exe pid 124,
  and SocialClubHelper.exe pids 436 and 652. It kept RDR2.exe pid 1056 and crashpad_handler.exe
  pid 1072: `4 ended, 2 kept as the game's, of 7 processes in the job`.
- **Teardown (0127):** all four were torn down (`[proc-end] … killed`): pid 0x70 (6 threads
  parked), 0x7c, 0x1b4 (11 parked), and the renderer 0x28c. Over the whole run 22 threads were
  parked, 17 of them at this end, and none was refused.
- **Restarts:** none, and no `[launcher] restart` line. The app was stopped with the title running,
  so the end-of-title summary was not written.

## Footprint (`[xp]` `fpMB`)

Times here are the runtime's `[xp]` clock, about 0.9 s ahead of the app's.

| When | MB |
| --- | --- |
| +30 s (launcher) | 3,033 |
| +90 s (just before the first frame) | 3,970 |
| +120 s | 5,127 |
| +120 to +600 s, while the pipelines were translated | 5,127 to 5,652, about 1 MB/s |
| +618 s, the game's `socialclub.dll` load | 5,294 to 5,385 |
| +626.4 s | 5,752 |
| +627.5 s | 6,954 |
| **+628.1 s, peak before the end** | **7,111** (the reading that fired the end) |
| +628.4 to +629.2 s, after the end | 6,723, then 6,686: about 425 MB freed |
| +633 to +635 s, the game's own helper and libcef | 7,100 to 7,258 |
| to the stop | flat at 7,227–7,255; `[footprint] phys=7227 MB (peak 7255)`, compressed 2,317 MB, graphics 1,553 MB |

- **No memory-limit kill.** The device log has no JetsamEvent for this run; the only two from
  the day are earlier ones.
- **The jump that fired the end** was +1.2 GB in about 1 s, the burst size 0130's headroom was chosen for.
- **After the end** the footprint still rose 570 MB, as the game's own Social Club helper and its
  libcef started. The peak for the whole run was 7,261 MB, 931 MB under the limit.
- **The `launcher: footprint …` lines** after the end were 6,688, 6,755, 7,011, 7,161, 7,147,
  7,257, 7,248 and 7,248 MB.

## Other counters at the stop

- **JIT pool (896 MiB):** head 297 MB (171 live), tail 465 MB (241 live), room 134 MB, `exhausted=none`.
- **FEX band:** 16,384 MB, peak 5,854 MB with 279 threads, `refused=0`.
- **Donor pool:** served 3,368 MB in 6,656 commits, refused 4.
- **The app stayed in the foreground:** the host log has no `[susp]` or `main queue has not run`
  line, and a footprint of 7.25 GB with no kill means the 8,192 MB limit held.

## The screens (images stay in the run directory)

- **60 s:** the launcher's dark start window, with the Rockstar logo and window buttons.
- **120 to 600 s:** black, under the touch controls, with a thin loading bar along the bottom
  (x 173–1427 of 1600) filling left to right: to x 554 at 120 s, 644 at 300 s, 945 at 420 s,
  1228 at 540 s and 1388 at 600 s. There is no text or logo.
- **660 s to the stop:** the same image each time. It is PlayRDR2.exe's box: caption "Error",
  "Unable to launch game, please try reinstalling the game.", with OK and Help buttons, on black.
  The game is behind it.

## How far the game got

RDR2.exe ran its first-start pipeline translation behind a loading bar for about 8.5 minutes. It
then loaded its Social Club and reached the launcher's game channel. The memory safety ended the
launcher about 3 s later, before the ticket hand-off, and the game did not sign in. From +627 s to
the stop PlayRDR2's box covered the screen. Whether the game behind it showed the still blue frame
of run `20261019T185116` or anything else is not shown. No menu was reached.

## Follow-ups

- **The threshold fires during the game's Social Club load, before the hand-off.**
  - The game's `socialclub.dll`, libcef and Vulkan layer load together, and the footprint goes
    from 5.75 to 7.1 GB in about a second.
  - The ticket comes some seconds after `Game instance connected`. How long is not shown on the
    phone.
  - Either the threshold rises, which risks the limit (the next readings after the end peaked at
    7,258 MB, with the launcher already gone), or the launcher's footprint at that point must fall.
  - The four torn-down processes still kept about 1.6 GB between them (`[proc-end] … kept`: 716, 821, 39 and 4 MB).
  - That needs an owner decision.
- **The pipeline cache was cold for the new IPA** (190 of about 2,050 pipelines read from the
  cache). Probably the cache is keyed to the app build; not checked. A second run on the same IPA
  should reach `socialclub.dll` soon after the first frame, as run `20261019T185116` did.
- **`SocialClubVulkanLayer.dll` was mapped into RDR2.exe** at +619 s. This is the first time in a
  phone run, though it came after the SDK had already logged that the layer was not loaded.
  This belongs to the parallel `SocialClubVulkanLayer.dll` research.
- **PlayRDR2's box was not tapped** in this run, so it covered the game to the stop.
