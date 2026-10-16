# Rockstar Games Launcher: Stage 0 on the phone

**Date:** 2026-10-15. **Branch:** `dev/pla-291-rockstar-launcher`.
**Linear:** [PLA-365](https://linear.app/playportdev/issue/PLA-365) (step 1),
[PLA-254](https://linear.app/playportdev/issue/PLA-254),
[PLA-364](https://linear.app/playportdev/issue/PLA-364).
**Plan:** [publisher launchers](../plans/2026-10-12-launchers.md), Progress (Rockstar track), chunk 2.

Phone: iPhone18,4, iOS 27.0.1. Runs are under `$PLAYPORT_BUILD/ui-runs/`.

## Step 1: Rockstar's installers from Steam's depot (PLA-365)

### Desktop Steam's rule

Red Dead Redemption 2 (1174180) lists its depots in PICS (anonymous read, 2026-10-15):

| Depot | Fields | Desktop Steam |
| --- | --- | --- |
| 228987, 228990 | `depotfromapp` 228980, `sharedinstall` 1 | Steamworks Shared |
| 1174181–1174186 | own manifests | the game's folder |
| 1899671 | `depotfromapp` 1899670, no `sharedinstall`, its public manifest in the game's record | the game's folder |

App 1899670 is "RGL/SC", type Config, installdir `RGLSC`. A depot borrowed from another app
without `sharedinstall` 1 is therefore installed into the game's own folder, as desktop Steam
installed it for the owner (chunk 1).

### What changed

- **Depot selection.** `DepotInfo.isContentFromAnotherApp` covers both cases: another app's
  depot without `sharedinstall` 1, and Half-Life's depots that share Counter-Strike's folder,
  as before. Either one is content. Its key and manifest request code are asked for its source
  app.
- **Depots left out.** A `sharedinstall` depot of an app other than 228980 is still left out,
  with the new reason `shared install in app N's own folder (not installed)`.
- **Records from before.** A record written earlier gave every borrowed depot the old reason.
  Such an entry from an app other than 228980 is a depot to check again
  (`InstallReceipt.depotsToRecheck`):
  - the offline check (Game options › Check game files) reports "Content to check with
    Steam";
  - Repair from Steam then reads Steam's depot list at the record's build;
  - a depot the selection now installs joins the record, and only its files are downloaded.
- **Driver action.** `pp ui --action repair:ID` presses the page's Repair from Steam, after a
  `verify:` that did not pass.
- **Install scripts.** The new depot's `installscript_sdk.vdf` is flagged as an install script
  (flags 256) in its manifest, so the existing install-script path runs it with nothing new.

### On the phone (IPA `2a24887030e5ae1fbd580dcfb79b568fca3f6461474dc4f15aa3984d2e04df41`)

**Repair**, run `20261015T225700` (`verify:app-1174180`, then `repair:app-1174180`):

```
verify: 120 files, 128041489146 bytes, 0 bad, 0 unlisted, 157.7 s; depots to check with Steam: 1899671
  depot 1899671 joins the install: gid 3914969219305676290 size=239826989 (from app 1899670)
repair: depot(s) [1899671] added to the record, 3 files to download
stage: 3 files (3 SHA-1-verified now, ...), 239826989 bytes; 232 chunks downloaded (235632685 bytes) ... 9.5 s, 24.7 MB/s
repair: 3 of 3 files replaced and re-verified; 0 still bad
ui: repair app-1174180: 123 files OK after 171 s
```

The repair downloaded 235.6 MB; nothing else of the 128 GB install moved.

The depot holds:

- `Redistributables/Rockstar-Games-Launcher.exe` (111,419,512 B);
- `Redistributables/Social-Club-Setup.exe` (128,406,648 B);
- `installscript_sdk.vdf` (829 B), with two entries:
  - `240240`: `Social-Club-Setup.exe /silent`, HasRunKey `HKLM\Software\Rockstar Games\Steam\SDK`;
  - `101093031`: `Rockstar-Games-Launcher.exe /s /t`, HasRunKey
    `...\Steam\Launcher`, `Requirement_OS` `Is64BitWindows` 1.

**Play**, run `20261015T230510` (`play:app-1174180`):

- The library lists 4 prerequisites: the two VC++ 2017 entries (rerun once with this build after
  their earlier 0x666 failure), then `240240` and `101093031`.
- `Social-Club-Setup.exe /silent` exits 0 after 3 s, and its HasRunKey value is written.
- The launcher installer starts.

**The installer by hand**, run `20261015T230843` (Play, then the owner at the phone):

- The installer's pages appear through decision 0075's guest windows (`[guest-window] ... shown:
  1028x600`). The owner pressed through Language select, Welcome, Terms of Service, Choose
  install location and Installing by touch.
- The installer ran both VC++ 14.44 redistributables (WiX Burn) and put its files in
  `C:\Program Files\Rockstar Games\Launcher`.
- It then started `RockstarService.exe` (pseudo-process `00cc`). That process looped on write
  faults into its own code. FEX logged `Handled self-modifying code ... AV WRITE of 127644F47`,
  sampled 1 in 1,000, about 2,000 exceptions in all. The process then ended with
  `NtTerminateProcess(-1, 0xc0000005)`.
- The installer then showed `[msgbox] "Rockstar Games Launcher"`: "An error has occurred. Please
  make sure all instances of the Rockstar Games Launcher have been closed and try again. If you
  continue to see this error, please visit: https://support.rockstargames.com".
- The prefix has no `Rockstar Games\Launcher` key, so `PlayRDR2.exe` would still look for the
  installer.

In the first Play (`20261015T230510`) the same box came up before the language page. A console
window left by the VC++ 2017 `.cmd` stayed in the guest window layer over it.

### RockstarService.exe and the storm breaker (step 2, part 1)

The faulting store wrote 4 bytes at RVA 0x24F47 of `RockstarService.exe`. The service has a second
`.text` section, and its own code shares that 16 KiB host page. Each pass of its loop took a
self-modifying-code fault that FEX handled, then went on. The breaker (ml461, and madeira-unix
0119 for a child) counts identical `(thread, pc, address)` deliveries, so it ended the process at
2,000 passes. madeira-unix 0151 adds the thread's general registers to that key. FEX holds the x86
registers in host registers, so a pass that made progress no longer counts as a repeat.

With IPA `fb14fc653935ebfec9b6730bb409ef97c83a3ce9caad96953a01ef9bc7dea244`, run
`20261015T234109`, the owner pressed through the pages again. This time `PlayRDR2.exe` started
the installer, because the prerequisite was recorded as failed with this build. Results:

- The service's loop got through: `[smc] ml1055 147000 self-modifying writes handled so far` in
  about 28 s, and no `[host-fault]`.
- The installer's log (`ProgramData\Rockstar Games\Launcher\installer_log.txt`) shows where it
  stopped. Its files were written and both VC++ 14.44 setups exited 0, then:
  `Found service` / `Running install service action...` / `App launched: ...RockstarService.exe
  with args: install` / `Exit code: 1`.
- The cause is `[file-wfail] ... status=0xc0000034 ... name=\??\pipe\svcctl`: no SCM runs in the
  session. That is step 2's subject (PLA-275). The same `[msgbox]` followed; the screenshot shows
  it over the installer's Installing page.

Hollow Knight on `fb14fc65`, run `20261015T235413`: first frame at +11.22 s, ok.

## Step 2: Windows services for a flagged play (PLA-275, decision 0107)

Red Dead Redemption 2's play now starts services.exe: `windowsServices` is set in the
compatibility table. The session root logs `[service]` lines and stops the services before it
reports the title's end. Hollow Knight starts none.

| Run | IPA | What it showed |
| --- | --- | --- |
| `20261016T000630` | `c2c099e164bdd3367bb3cc16b241d32ded3ddcdd17b6160f9a856c30910a740e` | Hollow Knight: first frame +10.11 s, no `[service]` line |
| `20261016T000828` | `c2c099e1…` | RDR2, the owner pressing the pages: `[service] services.exe started, pid 40, its SCM listening after 78 ms`, `[service] RpcSs: listed, stopped`. The installer's log shows `RockstarService.exe with args: install` → `Exit code: 0`, then `[service] Rockstar Service: listed, stopped`, then its uninstall registry keys. It then created its desktop shortcut as `\Rockstar Games Launcher.lnk` (empty folder path), and its worker thread ended. The page stayed on Installing until Playport's 300 s prerequisite limit closed it. That forced close hit `Assertion failed: (process->job == job), function terminate_job` in the wineserver and ended the app |
| `20261016T002213` | `2966df7c6bf8cdc08f35636222ebacc6157ebf9d3851bbb0accdf374b7ea97b5` | Hollow Knight: first frame +9.22 s |
| `20261016T002413` | `2966df7c…` | RDR2: the installer exits 0 in 0.5 s (`Silent install mode`: the closed run had already written the launcher's keys). `PlayRDR2.exe` starts `Launcher.exe` (Steam mode). The launcher runs `RockstarService.exe start` three times. Each time services.exe starts the service process, which exits with `0xC0000001` at once: `[service] Rockstar Service: starting, pid 304` / `stopped, exit 1077`. The screen stays black, with no window and no present |

Two fixes went with the IPA `2966df7c`:

- **Profile folders.** wine_host's profile folders now include `Desktop`, the user's and
  ProgramData's `Start Menu\Programs\Startup`, and `Public\Desktop`. shell32 gives an empty
  path for an absent folder, which is where the installer's shortcut went.
- **Job termination.** wine-unix 0038: `terminate_job` walks the job from its head after each
  process. Ending the installer closed its handle to `winemenubuilder.exe`, which had already
  ended; the server then destroyed that process while it was the saved next entry. 0038 is not
  yet exercised on the phone, since no run since has needed a forced close.

### Where Stage 0 stands

- **Installed** in the phone's prefix:
  - the launcher's files, its registry (`InstallFolder`) and the `Rockstar Service` entry;
  - Social Club, via the SDK script.
- **Next blocker:** the service process exits with `0xC0000001` when the SCM starts it. Without it
  the launcher shows no sign-in page (code 135 in Stage R).
- **Not reached yet:** the launcher's window and D3D11 present (step 6). Steam mode also needs a
  Steam client (PLA-253), so Stage 0 opens `Launcher.exe` standalone (step 5).

### Not done in step 1

- The SCM (step 2).
- The Hollow Knight smoke play: Hollow Knight is not installed on the phone (the library holds
  only RDR2). Step 1 is not a runtime change; its gate is the RDR2 runs above and the host tests.
  Hollow Knight is installed before step 2.

## Chunk 3, step 1: Rockstar Service runs under services.exe (PLA-275)

**Cause of the `0xC0000001`.** In run `20261016T002413` each service process ended in
`arm64ec_process_init: pProcessInit -> c0000001` before its entry point, after `[atomic-alias]
LIVE: WINE_IOS_JIT_RX=<unset>` (all 6 such processes; every other process logs the pool's
addresses). services.exe builds a service's environment with `CreateEnvironmentBlock(token,
FALSE)`, from the registry alone, so the runtime's `WINE_IOS_JIT_RX/RW` never reached it, and FEX
refuses to start without them (fex 0007). `RockstarService.exe install`, run by the installer,
inherits its environment and so ran. Fix: wine-pe 0045, userenv's `CreateEnvironmentBlock` copies
the caller's `WINE_IOS_*` and `MADEIRA_*` variables.

**Then two limits** ([decision 0108](../decisions/0108-a-launchers-jit-pool-and-service-start-timeout.md)):

| Run | IPA | What it showed |
| --- | --- | --- |
| `20261016T004537` | `426b0d59ff90bdfb999c3e693578aa64c15bb1314c8ee2127af1a252def5c566` | Hollow Knight: first frame +9.97 s |
| `20261016T004627` | `426b0d59…` | RDR2: the service starts (`starting, pid 200`, FEX up) and runs its self-modifying loop (72k writes); services.exe ends it after its 10 s `ServicesPipeTimeout` (`process_send_start_message service L"Rockstar Service" failed to start`). The 512 MiB pool runs out (`exhausted=head`: head 204, tail 309 MiB; 9 `image map FAILED`); the next service start ends with `0xc0000135` |
| `20261016T005101` | `f9670d7ed7484af44dc90e14a0a04a8622f8f583eb5edb12157d0ba7a1d6f01d` | RDR2 with a 2-minute start timeout and the dev 896 MiB pool: `[service] Rockstar Service: running, pid 200`; the launcher's first window at +89.0 s; pool head 213, tail 481 MiB |
| `20261016T005959` | `021916352e9c88e5c5b2fd39dca06f84ad416f75ebc3bdd849b08a9bd7bd0747` | Hollow Knight: `jit pool: 512 MiB`, first frame +9.20 s |
| `20261016T010049` | `02191635…` | RDR2: `jit pool: 896 MiB for a memory limit of 8192 MB (the game's)`; `[service] Rockstar Service: starting, pid 240` → `running, pid 240`; first window at +15.8 s (FEX's cache warm). Pool after 150 s: head 219, tail 481 (465 live) MiB, room 197 MiB, 5 children |

The window `Launcher.exe` shows in Steam mode (940×318, `[guest-window] hwnd=0x1003e`) is a dark
dialog with a close button and one button, and no text. Launcher.exe loaded d3d11/dxgi (DXVK) for
it. Steam mode is not Stage 0's path (PLA-253); the standalone launcher is step 5's.

## Chunk 3, step 2: a forced close, and fault containment today (PLA-292, PLA-314)

Run `20261016T010654` (IPA `02191635…`): RDR2's play with Windows services, then the in-game
menu's Quit game about 4 minutes in (the driver's `menu:open` waited about 3 minutes on the
launcher's window). `session: title 2: WM_CLOSE to 1 windows of 2 processes` (PlayRDR2.exe and
Launcher.exe), then `still running after WM_CLOSE; ending it`. The job ended both processes with
no `terminate_job` assertion: wine-unix 0038 holds on a forced close. Then
`[service] Rockstar Service: stopped, exit 0` and `[service] services.exe and its services stopped
with the title in 331 ms (0 ended)`: 0107's stop at the title's end works. The outcome is
`exit=0x0000042b`, a forced end, and Playport restarted as after any title.

What a child pseudo-process's fault does today:

- a guest exception the guest leaves unhandled ends that process (NtTerminateProcess, ml937's
  `abort_process` tears down that pseudo-process only);
- a fault on a thread of a child that has exited ends that thread (madeira-unix 0118);
- a storm of 2,000 identical redeliveries in a live child ends that child with `c0000005`
  (0119), counted by the thread's registers too (0151);
- the remaining fatal host-fault paths in `signal_arm64_ios.c` (`bus_fatal`, the fatal SEGV
  path, the breaker's second storm) still end the app. The general case stays open in
  PLA-292 (and PLA-314 for the x86-64 killed waiter). A renderer killed on purpose is tested once
  CEF runs on the phone.

## Chunk 4, step 5: Settings › Launchers › Open (PLA-271, minimal)

Settings › Launchers (dev builds only until a launcher passes Stage 1) lists the Rockstar Games
Launcher from PlayportKit's `PublisherLauncher` table: "Installed" when the prefix's
`HKLM\Software\Wow6432Node\Rockstar Games\Launcher` `InstallFolder` names a folder on drive C
holding `Launcher.exe`, else "Not installed" with no Open. Open runs the same setup checks as a
Play, then a launch whose title is the launcher (`launcher-rockstar`): `Launcher.exe` with no
arguments (no `-steamAppId`), Windows services on, a JIT pool of 896 MiB, the Vulkan backend. The
driver's `open-launcher:rockstar` calls the same Open.

Run `20261016T012523` (IPA `9dfc1c0e52d91a733887655188f52423236ddc687f568525d3ed16afbe396bda`,
`open:settings#launchers`, `open-launcher:rockstar`, until first window +60 s):

- `launcher: open rockstar on vulkan: C:\Program Files\Rockstar Games\Launcher\Launcher.exe`;
  `title: jit pool: 896 MiB for a memory limit of 8192 MB (the game's)`;
  `[service] Rockstar Service: starting, pid 288` → `running, pid 288`.
- First window at +27.3 s: the launcher's 500×400 splash (the outlined R★ and a close button).
- It starts `LauncherPatcher.exe` (its update check), `ThirdParty\Crashpad\RockstarErrorHandler.exe`
  (twice) and Wine's `dxdiag /t …\Rockstar Games\Launcher\dxdiag.txt`. No `SocialClubHelper.exe`
  within the 60 s.
- Pool at the end: head 267, tail 545 (513 live) MiB, room 85 MiB, 7 children; band 3,683 MiB
  used of 16,384, 54 threads. The launcher's helpers alone take the pool that RDR2's
  Steam-mode play left at 197 MiB of room to 85, before any CEF process.

Hollow Knight on the same IPA (run `20261016T012433`): `jit pool: 512 MiB`, first frame +10.58 s.

## Chunk 4, step 4: the Chromium policy (PLA-277, decision 0109): in place, not exercised yet

madeira-unix 0152 gives every CEF browser (an image with `libcef.dll` beside it, no `--type=`)
`--in-process-gpu --disable-gpu --disable-gpu-compositing --js-flags=--jitless` at process creation
and logs `[chromium]` lines. IPA `1102672b13cb28383f0afe70572427d0d563d0cd9647ca5b6a9b3ef4cce293a3`:
Hollow Knight passes (run `20261016T013556`, first frame +10.64 s).

The Open run on it (`20261016T013646`, first window +27.6 s, then 300 s) started no
`SocialClubHelper.exe`, so no `[chromium]` line yet. The launcher's own log says why: version
1.0.109.3031 runs its first self-update (239.65 MB to build 1239), through Rockstar Service.
- **The service is far too slow.** Its worker thread took 860,645 guest `c0000005` exceptions and
  1,756,637 `NtProtectVirtualMemory` calls in about 330 s. The calls set PAGE_EXECUTE_READ on 16 KiB
  pages of its own code at `0x145b…`, a write-then-reprotect loop.
- **What each call costs:** madeira's `NtProtect-sync` scan of 162 JIT mappings, and 3 to 5 ERR
  lines (5.5 million log lines in the run).
- **What the launcher logs:** launcher↔service transactions time out after 60 to 158 s
  (`svc_transactionqueue`). Five update chunks fail with "Connection timed out waiting for
  response". The service then maps 400 MB of shared memory, and the splash stays.
- **Pool at 300 s:** head 230, tail 609 (593 live) MiB, room 58 MiB, 6 children. Band: 4,354 MiB
  used, 57 threads. No CEF process had started by then.

## Chunk 4: the self-update fails, and the pool runs out before CEF (stop)

Run `20261016T014751` (IPA `1102672b…`): Open, then first window +870 s. The phone was at
"thermal: serious" at the launch, and the first window came at +105.2 s. Result:
`pool=exhausted:head still-running after_s=957`.

**The launcher's log** (pulled from the prefix; it holds launcher tokens, so it stays under the
build area):
- **The update:** it resumes with 141.68 MB left of its update, so about 98 MB came down in the
  earlier runs. It maps the service's 400 MB shared memory.
- **The service dies:** Rockstar Service stops with `exit 1067` and is started again
  (`[service] Rockstar Service: running, pid 388`), and seven `RockstarService.exe` processes are
  started in all. Then `Service reports allocation failure: 2097152 bytes`, and "Failed to update
  the Rockstar Games Launcher (code 242)".
- **The screen:** the splash shows an update bar at about 5 % from 300 s to the end.
- No `SocialClubHelper.exe` was started, so there is no `[chromium]` line.

**Pool and band, sample by sample** (head / tail / room MiB, children):

| When | Head | Tail | Room | Children |
| --- | --- | --- | --- | --- |
| Before the first window | 202 | 481 | 214 | 6 |
| | 202 | 609 | 86 | 6 |
| After the first window | 224 | 609 | 64 | 6 |
| | 246 | 609 | 42 | 8 |
| | 246 | 625 | 26 | 9 |
| | 255 | 625 | 17 | 10 |
| End | 272 | 625 | 0 (`exhausted=head`, 25 refusals) | 10 |

- Eight `image map FAILED (pool exhausted)` lines came before the end.
- Band at the end: 5,432 MiB used of 16,384, 67 threads, 945 views.

**Rockstar Service's churn:**
- One service thread made 3,453,004 `NtProtectVirtualMemory` calls and took 1,785,277 guest
  `c0000005` exceptions in about 950 s. Two more threads made about 320,000 calls each.
- **The log:** 30.9 million lines (3.1 GB). On the phone, `s1-host.log` and its previous copy
  hold 4.6 GB of the container, and free space went down to 1.2 GB.
- **The tail:** it grows in 128 MiB steps (481 → 609 → 625 MiB) while the churn runs. FEX
  allocated the most code buffers on the churning service threads (4 or 5 each, "Failed to mprotect
  last page of code buffer"). That is consistent with FEX re-translating the service's rewritten
  code. This is an inference: nothing logs the tail per process.
