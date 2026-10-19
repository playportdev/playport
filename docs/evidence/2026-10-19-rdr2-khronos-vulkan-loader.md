# 2026-10-19: RDR2 with the Khronos Vulkan loader loads its Social Club layer and signs in, with no error 18; the screen is still the blue band

**Linear:** PLA-420, PLA-409, PLA-364. **Decisions:** 0131 (0130, 0107).

## Builds and runs

| IPA sha256 | HEAD | Run | What |
| --- | --- | --- | --- |
| `a60a55e132de464ebc330c090588e3f2342f77897b52220da760986dc7d8000d` | ca9d735 | `20261019T210620` | Hollow Knight gate (`--play app-367520 --until first-frame+10 --shot`), right after `pp install --no-build` |
| same | same | `20261019T210854` | RDR2 `--action set:donorPoolMB=auto --play app-1174180 --until first-frame+900 --wait 1800`, a screenshot every 60 s from 60 to 900 s and at the stop, device log kept |

- **The build:**
  - the Khronos Vulkan-Loader v1.4.363 for arm64ec (`Runtime/vulkan-loader/arm64ec-windows/vulkan-1.dll`, sha256 `db87edae…`, 762,880 bytes);
  - winevulkan's `winevulkan.json`;
  - RDR2's compatibility default `khronosVulkanLoader`;
  - the seed's `Khronos\Vulkan\Drivers` value (decision 0131).
- **The phone:**
  - before the gate: 80 %, 5.8 GB free;
  - before RDR2: 79 % and not charging, 5.8 GB free;
  - after: 73 %, 5.3 GB free.
- **Nobody pressed anything from the workstation.** PlayRDR2's "Unable to launch game" box was up from +92.62 s to +98.77 s and was closed by a tap on the phone.
- **The phone prefix already had the layer's registration** before the run. It was read with `pp phone pull Documents/prefix/system.reg`, and only the Khronos lines were looked at:
  - `[Software\\Khronos\\Vulkan\\ExplicitLayers]` and its `Wow6432Node` twin both name `C:\Program Files\Rockstar Games\Social Club\SocialClubVulkanLayer.json`;
  - there was no `Drivers` key.
- **Raw data** is private, under `$PLAYPORT_BUILD`:
  - `ui-runs/20261019T210620/` and `ui-runs/20261019T210854/`: host logs, events and screenshots;
  - `agent-notes/pla420/rdr2run/`: the device log, the phone status, and the Social Club logs pulled after the run.

## Hollow Knight keeps Wine's loader

- First frame at +8.83 s; the JIT pool head is 48 MiB, with no exhaustion.
- The session's new line shows system32 linked to Wine's builtin:
  `system32: vulkan-1.dll -> arm64ec-windows/vulkan-1.dll sha256 02fb7f44cc9b4a2e`.
  That is the `Runtime/arm64ec-windows/vulkan-1.dll` row of `app/artifacts.tsv`.
- The overlay line: `system32: 7 links from overlays vulkan over them (vulkan 7)`.
- The seeded `Drivers` key changes nothing for a title on Wine's `vulkan-1`.

## RDR2: the loader and the layer

**The loader is in place for the whole session:**
- `graphics: vulkan; vulkan loader: Khronos`;
- `WINEDLLPATH=…/vulkan-loader:…/vulkan:…`;
- `system32: 9 links from overlays vulkan,vulkan-loader over them (vulkan 7, vulkan-loader 2)`;
- `system32: vulkan-1.dll -> vulkan-loader/arm64ec-windows/vulkan-1.dll sha256 db87edae47763dc5`.

**Where `vulkan-1.dll` loaded:**
- system32's `vulkan-1.dll` loaded as module hash `vulkan-1.dll-2c12586892dd345b`, an ARM64EC image of 0xa5000, in:
  - Launcher.exe (thread `0074`);
  - another launcher process (`00bc`);
  - RDR2.exe (`041c`, at 21:10:2x).
- The launcher's CEF GPU process (`0210`) loaded its own x64 `Social Club\vulkan-1.dll`, as before.

**The layer loaded:**
- `D 41C Load module SocialClubVulkanLayer.dll (socialclubvulkanlayer.dll-0242196c5391a325)` at 21:10:26.7.
- That is in RDR2.exe, before its `socialclub.dll` (21:10:30.1), the same order as on desktop Proton.
- In every earlier phone run the layer was only version-mapped.

**No loader errors:**
- The loader's DllMain loads system32's `dxgi.dll` (DXVK's) in each process that loads it; DXVK only logs `CreateDXGIFactory2: Ignoring flags`.
- No `D3DKMT`, `cfgmgr32`, `VK_ERROR` or loader error line appears.
- `fixme:vulkan` shows only the known `VK_TIME_DOMAIN_QUERY_PERFORMANCE_COUNTER_EXT` lines.

## RDR2: the Social Club SDK signs in

The game's `socialclub.log` (123 lines; times are ms from the SDK's start; profile and account values left out):

| SDK ms | Line |
| --- | --- |
| 363 | dependency check lists `Vulkan Renderer Layer … 2.4.0.240` |
| 365 | `SDK fully initialized` |
| 384 | `Entering State: 'WAIT_BROWSER'`. There is no `SocialClubVulkanLayer.dll not loaded.` line |
| 5,052 | `OnChannelConnected - rgsc_gameinst_0` (the launcher), `launcher in online mode` |
| 5,484–5,492 | `Game instance connected`, `Browser available`, `WAIT_IPC` |
| 5,551–5,848 | `WAIT_BROWSER_WINDOW`, `LOADING`, `WAITING_FOR_PAGE_LOAD` |
| 8,746 | `OnChannelError() - rgsc_gameinst_0`. This is the 0130 end below |
| 9,297–11,608 | `Browser failed during Social Club UI page load`, `falling back to offline site`, then `FAILED` |
| 11,611–12,969 | `WAIT_BROWSER` again, a new browser subprocess, `Browser available` |
| 13,003 | `IPC system failed to connect to launcher, loading UI.`, `Reloading into offline mode` |
| 15,005 | `LoadUrl` of the local `ui\scui\default.html` |
| 18,158–19,421 | `WAITING_FOR_PAGE_READY`, `PAGE_READY`, `START_SIGN_IN`, `FINISHED` |
| 19,464 | **`Successfully imported Launcher ticket`**, `Not signed in - attempting to sign in` |
| 19,700 | `Syncing friends.`, `Syncing achievements.` |
| 21,753 | **`Signed in online to profile: …`** |

- **The state machine counts:** 16 `Entering State` lines. Run `20261019T201131` had 0.
- **The app's watcher:** it logged `launcher: the game signed in at +102.1 s` (21:10:54).
- **The game's own helpers:** RDR2.exe started its own SocialClubHelper processes, remote process ids 1464 and 1668 in the SDK's channel lines.

## The 0130 launcher end

- **Trigger:** the memory safety, not the sign-in.
  - At +86.7 s (21:10:38.6) the footprint read 7,193 MB, over the 6,992 MB threshold.
  - That was 3.3 s after `Game instance connected` and before any ticket line.
  - The session root ended Launcher.exe (pid 112), RockstarErrorHandler.exe (124) and three SocialClubHelper.exe (436, 644, 1400). It kept RDR2.exe (1048) and crashpad_handler.exe (1064).
- **Effect on the SDK:**
  - its first UI load failed with the launcher's channel;
  - it reloaded offline;
  - it still imported the launcher's ticket and signed in online 13 s later.

  The owner's desktop log shows the same pattern, signing in with the launcher already gone.
- **The box:** PlayRDR2.exe showed "Unable to launch game, please try reinstalling the game." at +92.62 s, as 0125/0130 expect.

## Footprint, pool and frame rate

**Footprint:**
- `[xp]` `fpMB` peaked at **8,140 MB** at 21:11:30 (+139 s). That is 52 MB under the 8,192 MB limit.
- After the end it went on rising: 6,982 MB, then 7,703 MB by +96.5 s, as the game's Social Club UI and helpers loaded.
- At the stop: `phys=7739 MB (peak 7825)`, compressed 2,242 MB, graphics 1,597 MB.
- No JetsamEvent for this run; the device's two reports of the day are from 14:51 and 18:28.

**Pools:**
- JIT pool (896 MiB): head 302 MB (188 live), tail 545 MB (465 live), room 50 MB, `exhausted=none`.
- FEX band: peak 7,186 MB, 364 threads, `refused=0`.

**Pipeline cache:** warm. `[kk-compile] totals translated=0 deserialized=3136`.

**Frame rate:**
- 49,728 frames from 21:10:28.3 to 21:25:36.6, **54.7 fps**.
- Per minute: 50.7 in the first minute, then 54.6–55.3.
- This is the same rate as run `20261019T185116` without the loader, so the layer's present hook costs nothing visible at this rate.

**Activity after sign-in:** file reads fell to 0–2 MB a minute from minute 5. CPU was about 220 % of one core.

## The screens (images stay in the run directory)

- **60 s:** the launcher's dark start window with the Rockstar logo.
- **120 s to 900 s and the stop:** the same file each time (sha256 `753b7c63…`). It is the blue band of run `20261019T185116`:
  - a flat blue strip across the full width, centred, on black;
  - under the touch controls;
  - no text.
- **No Social Club error screen at any point.**

## How far the game got

- **Done this time:**
  - the Khronos loader loaded `SocialClubVulkanLayer.dll`;
  - the SDK's UI state machine ran;
  - error 18 is gone;
  - the game imported the launcher's ticket and **signed in online**, about 102 s after the title's start.
- **Not done:** the game did not leave the blue band in the 15 minutes after its first frame. It was presenting at 55 fps with almost no file reads.
- **Not checked:** what the game waits for after sign-in. Neither is whether the layer's overlay draws anything, or would draw if given input.
- **Memory:** the footprint came within 52 MB of the limit.
