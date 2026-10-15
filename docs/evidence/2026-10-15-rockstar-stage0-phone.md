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
