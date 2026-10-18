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

## Chunk 5: what the service's loop is, and quieter logs (PLA-366)

**What the loop is** (host reading of run `20261016T013646`'s log, then run `20261016T023613`):
FEX's self-modifying-code tracking, not the guest calling `VirtualProtect`. The guest made only
1,040 `NtProtectVirtualMemory` calls of its own (`[inv-census]` "protect"). Each pass:

1. a guest store into its own RWX code faults (`c0000005`, a write, in FEX's code buffer);
2. FEX's `HandleRWXAccessViolation` invalidates the 16 KiB host page; the invalidation resets the
   thread's call-return stack (`VirtualDontNeed` of 16 MiB: the `mprotect_exec` on
   `FEXMem_CallRetStacks` each pass);
3. FEX untraps the page (`NtProtectVirtualMemory(addr, 1, PAGE_EXECUTE_READWRITE)`);
4. a block compiled again from that host page traps it again
   (`NtProtectVirtualMemory(page, 0x4000, PAGE_EXECUTE_READ)`), and the next store faults.

- Of 166,975 inline cases (the running block is in the written host page) in run
  `20261016T013646`, 121,804 (73 %) share only the 16 KiB host page, not the 4 KiB guest page:
  with 4 KiB pages they would not fault.
- The written addresses cycle over the same range (0x144390000–0x1443C8000) for the whole run: a
  protector that decrypts and re-encrypts its code, so the loop never ends by itself.
- Launcher.exe (about 57,000 writes per process) and the service's `start` helper process
  (147,000) do the same at a smaller rate.
- Madeira's NtProtect-sync scan costs little: for an image with no pool copy it compares the
  region with each of about 162 mappings and copies nothing. Its cost was its two log lines.

**The change** (`1fdc552`; IPA `60611f789bacdcfe74508dddd8d3a33fdf4c01df2c1004020ac7a978fe84448f`):
madeira-unix 0153 prints the `NtProtectVirtualMemory`, `NtProtect-sync` and `mprotect_exec`
lines for the first 64 calls of each and then every 65536th, with a `[protect-census]` line, and
logs `[jit-pool] tail of pid N` after each tail carve; wine-pe 0046 samples the `[rtcs] pre` line
of a write access violation the same way; fex 0045 samples FEX's inline self-modifying-code line
as ml1055 samples the others.

| | Run `20261016T013646` (IPA `1102672b…`) | Run `20261016T023613` (IPA `60611f78…`) |
| --- | --- | --- |
| Open, then | first window + 300 s | first window + 300 s |
| `s1-host.log` | 1,478 MB | 26 MB |
| Self-modifying writes in the 300 s after the first window | about 1,008,000 | about 619,000 (2,060 a second) |
| Invalidation, average | 58 µs | 30 µs |
| Call-return stack reset, average | 53 µs | 28 µs |
| Self-update | stalls | stalls after "Updating launcher..." (141.68 MB left), "Handshake with service timed out" |
| Pool at the end (head / tail / room MiB) | 272 / 625 / 0 at 950 s (`exhausted=head`) | 273 / 609 (449 live) / 15, not exhausted |

The per-pass cost fell, but the write rate did not rise. In the first run the service's writes
began after the first window; in the second, 228,000 came before it. The runs also differ in
heat, so the two rates are not a clean A/B.

**The tail per process** (run `20261016T023613`): the service (pid 228) holds 16, then 32, then
160, then 272 MiB in 3 code buffers, and its later carves reuse freed ones, so re-translation
does not grow the tail past that. The second Launcher.exe (pid 108) also holds 272 MiB, the first
(pid 68) 144 MiB, the service's helper (pid 128) 160 MiB. Two protected processes at 272 MiB each
leave 896 MiB about 15 MiB of room before any CEF process.

**What follows:** the writes have to stop faulting. Options: compile a host page that takes
many writes with FEX's per-instruction code checks (FullSMC) and leave it writable, which first
needs PLA-206's x86-64 FullSMC deadlock fixed; or turn `SMCChecks` off for `RockstarService.exe`
and `Launcher.exe` through FEX's per-executable AppConfig. The second is cheap, but a stale
translation would run if the protector ever wrote different code. Cutting the call-return stack
reset when the same host page is invalidated again was not taken: no evidence yet shows it is safe
to skip.

Hollow Knight (`app-367520`) on IPA `60611f78…`: first frame at +10.52 s (run
`20261016T023523`), title menu shown. The earlier build of the same code, IPA `60471856…`, before
its patches got their author line: +10.69 s (run `20261016T022813`).

## Chunk 7: Open with FEX's self-modifying-code checks off (PLA-271, PLA-367)

**The plumbing (PLA-271).** A dev build's Settings › Launchers › Open now takes the runtime keys
and FEX's inputs saved under `launcher-rockstar`, as a game's Play does (commit `fe39ed5`); the
page has a dev Runtime keys row, and `pp ui --settings launcher-rockstar:JSON` saves the same
settings (`07acf11`). The driver runs actions before `--settings`, so the settings go in an earlier
`pp ui` of the same `pp phone lock` session. Hollow Knight (`app-367520`): first frame +10.56 s on
IPA `8e5f2122…` (run `20261016T025849`) and +9.64 s on `0082f431…` (run `20261016T030301`),
title menu shown. The Launchers page with the row: runs `20261016T025939` and, after the key was
cleared, `20261016T031933` (None).

**The run.** IPA `0082f431300ecf0460fac68cc14a79f3af55c567a905ac2a54a8c346f24e5f2b`, run
`20261016T030415`: `env.FEX_SMCCHECKS=none` saved (run `20261016T030351`), then
`open-launcher:rockstar` to first window + 600 s. The log shows the key reaching the play
(`title: config: environment FEX_SMCCHECKS=none`); the phone reported thermal state serious at
launch. First window at +51.0 s (chunk 5: +88.3 s). The launcher stayed on its splash for the
whole 600 s; no crash, no `c000001d`, and the play ran until the driver ended it.

**The variable did not reach Rockstar Service.** FEX's `[inv-census]` line carries `smc_off`, and
the self-modifying-code lines name their thread:

| Process (pid) | Chunk 5, `mtrack` (`20261016T023613`) | This run, `none` |
| --- | --- | --- |
| session root (0x20), services.exe (0x28) | — | `smc_off=1` |
| Launcher.exe #1 (0x44) | SMC lines; 144 MiB tail | no SMC lines; 16 MiB tail |
| Launcher.exe #2 (0x6c) | SMC lines; 272 MiB tail | no SMC lines; 16 MiB tail |
| the service's `start` helper | SMC lines; 160 MiB tail | no SMC lines; 16 MiB tail |
| Rockstar Service (0xe8) | SMC lines; 272 MiB tail | `smc_off=0`; 1,538,807 write faults for the run; 256 MiB tail |

services.exe builds each service's environment block without inheriting
(`CreateEnvironmentBlock`), and wine-pe 0045 copies only `WINE_IOS_*` and `MADEIRA_*` into it.
So no `FEX_*` variable reaches a service: neither this key nor the launch's FEX profile
(`FEX_HOSTFEATURES`, the memory ordering).

**The pool.** After +15 s from the first window the pool did not change for the rest of the run:
head 224 MiB (196 live), tail 353 MiB (193 live), room 319 MiB, not exhausted (chunk 5: 273 / 609
(449 live) / 15 MiB). Band at the end: 4,469 MiB used of 16,384. With the checks off, each
Launcher.exe and the helper hold 16 MiB of tail instead of 144–272 MiB; the service alone holds
256 MiB.

**The self-update.** The launcher's log (kept under `$PLAYPORT_BUILD`, not here: it holds
BRANCHACCESS tokens) reads "No update", then "Applying downloaded self-update..." 20 s after it
started, then a background-service "Folder permissions operation failed" 6 s later, then nothing
for the rest of the run. The update was not applied; applying it goes through the service, which
still loops. "Handshake with service timed out" appeared again, 23 s after start, and "Handshake
received from service" 9 s later.

`env.FEX_SMCCHECKS=full` was not run: it would reach the service no more than `none` did. The
saved key was cleared at the next launch outside the session (`settings-restored
settings:launcher-rockstar`, run `20261016T031933`).

## Chunk 8: services get the launch's FEX variables; the launcher reaches CEF (PLA-367)

**The change.** wine-pe 0045 now copies the caller's `FEX_*` variables into the block
`CreateEnvironmentBlock` builds, as well as `WINE_IOS_*` and `MADEIRA_*` (commit `7213e77`). A
service therefore runs with the launch's FEX profile (`FEX_HOSTFEATURES`, the memory ordering,
`FEX_MAXINST`, `FEX_DISKCACHE`, `FEX_X87REDUCEDPRECISION`) and any dev runtime key, as the process
that started it does. Nothing in that profile is wrong for a service: these are the values its
launcher already runs with, and FEX keeps the disk cache off in a WoW64 process itself (patches/fex
0022). IPA `243d9b4be2311ae23731e6dffb648e3e5eb2215c364edddce2da7683ffb567be`. Hollow Knight
(`app-367520`) on it: first frame at +11.86 s (run `20261016T033003`; the shot at +10 s was still
black), then +10.40 s with the title menu (run `20261016T033115`).

**Open A, run `20261016T033304`** (`env.FEX_SMCCHECKS=none` saved by run `20261016T033234`, the
same lock session). The runtime and game started (+3.47 s, +3.90 s), but no first window came. The
launcher wrote no log, started no LauncherPatcher, and Rockstar Service was never started (listed,
stopped). The screen was black at 120, 300 and 480 s. The driver had no time cap, so the play ran
about 1,480 s before the app was ended with `pp phone kill`. The cause was not found.

**Open B, run `20261016T040029`** (key saved again in the same session; `--wait 900`). This time
the first window came at +10.41 s (chunk 7: +51.0 s). The processes started in this order:
Launcher.exe, LauncherPatcher, a second Launcher.exe, the service's `start` helper (exited 0),
Rockstar Service under the SCM, dxdiag, then SocialClubHelper 18 times.

- **The service got the key.** It produced no write-fault `[rtcs]` lines (chunk 7: 1,538,807) and no
  invalidation storm. Every one of the 28 processes ended with a 16 MiB JIT tail, 448 MiB in all.
- **The self-update no longer blocks.** The launcher's log (kept under `$PLAYPORT_BUILD`, not
  here) reads "Self-update not ready to apply yet", then "No self-update, continuing". Social Club
  2.4.0.240 matched the available version, and the launcher went on to its UI.
- **CEF starts, but its browser process crashes.** Each SocialClubHelper logged its `[chromium]`
  browser line (decision 0109: `--in-process-gpu --disable-gpu ...`). Each one then raised
  `c000001d` at the same guest address, chrome_elf.dll + 0x13A535. No renderer was started.
- **The launcher gave up.** At +82 s it logged "Social club UI in fail state... requesting
  shutdown" with `SC_INIT_ERR_WEBSITE_FAILED_LOAD` (category 3, code 17), "timed out loading both
  its online and offline content". The screenshot at 60 s shows the launcher's splash (the R-star
  logo and its close button).
- **Memory.** The crashed helpers stayed: the pool counted 26 children at the end. The app's
  footprint rose from about 3 GB to 7,966 MB (4,726 MB compressed), about 0.5 GB for each helper.
  The log stops at +143 s, while a helper was mapping libcef.dll (0xefbe000 bytes). The driver
  saw the app gone at about +310 s, and there was no crash report. A memory kill is likely but
  not confirmed.
- **The pool and the band.** At the end the 896 MiB pool had: head 346 MiB (251 live, 95 free),
  tail 129 MiB (97 live), and 422 MiB of room. Nothing was exhausted. Images 179. Band: 8,437 of
  16,384 MiB used.
- **libcef in the pool.** Each process maps libcef as its own x64 image view, with "no pool copy".
  The JIT pool holds neither an alias nor a copy of it.

**Not done.**
- The renderer kill (PLA-292): no renderer existed.
- The sign-in page: not reached.
- A second Open: not run. The crash loop that ends the app is deterministic: 18 helpers
  crashed at one address. A repeat would only push memory to the same limit again.

The key was cleared at the next launch outside the session: run `20261016T040724` shows the
Launchers page's Runtime keys row as None.

## Chunk 9: why CEF's browser dies, and why crashed helpers cost memory (PLA-369, PLA-368; stopped for the owner)

Host analysis only: no build, no phone run (the supervisor chose to stop here, as both fixes need an
owner decision). The inputs are run `20261016T040029`'s log (chunk 8, IPA `243d9b4b…`) and the
Social Club install. `chrome_elf.dll` is the same file on the phone and in chunk 1's scratch prefix:
sha256 `b46223f386643ba5cfe3152c5fa2bdd535e3b2d80e25e82073131889d8834a4e`, 1,822,840 bytes, image
base `0x180000000` (Chromium 143, decision 0109).

### PLA-369: PartitionAlloc cannot reserve its 32 GiB pool

**The trap is a deliberate crash, not a CPU feature.** `llvm-objdump -d chrome_elf.dll`:

```
; PartitionAddressSpace::Init (RVA 0x4d680)
18004d69b: movabsq $0x800000000, %rcx        ; size 32 GiB
18004d6a5: movq    %rcx, %rdx                ; alignment 32 GiB
18004d6a8: xorl    %r8d, %r8d
18004d6ab: movl    $0xfd, %r9d               ; inaccessible, PA's page tag
18004d6b1: callq   0x180059300               ; AllocPages (reserve)
18004d6bd: testq   %rax, %rax
18004d6c0: je      0x18004d7a8
18004d6c6: movabsq $0x400000000, %rsi        ; the BRP pool starts 16 GiB in
...
18004d7a8: callq   0x18013a4b0               ; HandlePoolAllocFailure
; HandlePoolAllocFailure (RVA 0x13a4b0)
18013a4c5: callq   0x180141710               ; the saved allocation error
18013a4ca: movl    %eax, %esi
18013a4d7: ...                               ; PA_DEBUG_DATA_ON_STACK("error", ...)
18013a4fc: cmpl    $0x5af, %esi              ; ERROR_COMMITMENT_LIMIT
18013a504: cmpl    $0x27b, %esi              ; ERROR_COMMITMENT_MINIMUM
18013a50c: callq   0x18013a540               ;   -> ...OutOfCommitCharge
18013a511: cmpl    $0x8, %esi                ; ERROR_NOT_ENOUGH_MEMORY
18013a516: callq   0x18013a520               ;   -> ...OutOfVASpace
18013a51b: int3 ; ud2                        ; PA_CHECK(false)
; HandlePoolAllocFailureOutOfVASpace (RVA 0x13a520)
18013a529: movl    $0x37, (%rcx)             ; no code folding
18013a52f: callq   0x18001ad70
18013a534: int3
18013a535: int3
18013a536: ud2
```

The phone log at the crash agrees: `RSI=0x8` (`ERROR_NOT_ENOUGH_MEMORY`), `R11=0xc0000017`
(`STATUS_NO_MEMORY`), guest return addresses chrome_elf + `0x13a51b` and + `0x4d7ad`, chrome_elf
at `0x73d3ad0000`. FEX raised `c000001d` for the trap and rethrew it as `80000003` at + `0x13A534`.
This runs while chrome_elf initialises, so the loader reported "chrome_elf.dll failed to
initialize" and the process ended with `0x80000003`. This matches Chromium's
`HandlePoolAllocFailure`: the error code says the address space ran out.

**Why the reservation fails.** All Windows allocations in the app share one 64 GB window,
`[0x7000000000, 0x8000000000)`; the task's `max_address` is `0x8000000000` (Witcher 3 setup
record, §2–3: no entitlement Playport can get raises it). PartitionAlloc wants 32 GiB at a
32 GiB-aligned address, so only `0x7000000000` and `0x7800000000` could take it. FEX's band holds
`[0x7c00000000, 0x8000000000)`, and the 896 MiB JIT pool sits at `0x700848c000` (the run's `vm:`
lines), so neither slot is free. Chromium makes this reservation in every process, so even one
free slot would serve only one of a browser, its renderers and its utility processes. Social
Club's UI fails under `--single-process` and with one renderer (decision 0109). The size is a
compile-time constant; no Chromium switch changes it. Under desktop Proton (chunk 1) the same
helper has Linux's 128 TiB, so the problem does not appear there.

**Options for the owner** (none is a Playport setting, so none was tried):

1. **A larger or separate address-space window per CEF process.** The ceiling cannot move: iOS
   gives this app 512 GB of addresses, of which 64 GB is usable. Every pseudo-process shares that
   window, and FEX runs x86-64 code at host addresses with no base to offset. The most the
   runtime could do is keep `[0x7000000000, 0x7800000000)` free for one 32 GiB reservation. That
   means moving the JIT pool (reserved inside the executable at start) and Wine's other
   allocations into the 16 GiB between `0x7800000000` and the band, or shrinking the band, for
   every title. Even then only one Chromium process at a time would fit, which is not enough for
   Social Club. Each renderer also needs V8's 4 GiB pointer cage. Cost: high. Risk: every title's
   memory layout. Outcome: CEF still cannot run.
2. **Patching PartitionAlloc's pool size in memory.** The size is not one value. The 8-byte
   `0x800000000` appears 27 times in chrome_elf.dll and 2,386 times in libcef.dll; its mask
   (`-0x800000000`) appears 1 and 31 times. These do not count shifts and smaller immediates.
   The pool mask is inlined into every PartitionAlloc pointer check. Any patch would be specific to
   one CEF build, which Rockstar updates on its own schedule. It would also change Rockstar's code
   at run time, which decision 0109 rules out for files, and raises the EULA and anti-tamper
   question. Cost: very high and fragile. It needs a policy decision before anyone tries it.
3. **Host CEF another way.** Possibilities:
   - **Avoid the UI.** The research routes (plan, research run `82cea138`) that avoid running
     the whole launcher during play. The sign-in still needs Social Club's web UI once.
   - **Show the sign-in elsewhere.** Draw the sign-in page through the app's own WKWebView,
     outside Wine. This is a new component and needs its own decision.
   - **Wait for Rockstar.** A CEF build whose Windows pools fit would need Rockstar to change it.
     It is not ours to change.

   Cost and outcome are unknown until one is chosen. Whatever the route, the game's own
   `socialclub.dll` also starts SocialClubHelper.

### PLA-368: helpers do end, but their memory is never given back

Chunk 8's reading that "the crashed helpers stayed" is wrong. In run `20261016T040029` each crashed
helper ended: `NtTerminateProcess(exit_code=0x80000003)`, then "abort_process: tearing down this
pseudo-process only (ml937)", then "child exited with code -2147483645". That happened 17 times, and
4 other children exited with 0. The pool's `children=26` counts the image copies children made in
the pool, not live processes.

What leaks is each dead child's memory. `process_exit_wrapper` (Madeira's
`build/ntdll-unix/server_ios.c`) releases only the following:
- the child's JIT-pool copies (`ios_jit_reclaim_process`);
- a fixed-base main image;
- its WoW64 window;
- its fd cache.

Wine's view tree is shared by all pseudo-processes, and `struct file_view` records no owner. So
nothing deletes an x86-64 child's views: its DLL images, heaps and reservations. Each helper had
mapped libcef.dll as its own 251 MB image view (`0xefbe000`; `[jit-pool] x64 image …: no pool
copy`), each at a new address (`0x72e0…`, `0x72ce…`, `0x72bb…`). That matches the footprint's
rise of about 250 MB per helper, from 3.2 GB to 7,966 MB. Every title whose children exit leaks
this way. It is not specific to crashes.

**Proposed fix, issue-ready ("Release an exited x86-64 child's views"):**
- **Owner.** Add `void *owner_peb` to `struct file_view` in `virtual_ios.c`. Set it in
  `create_view` from the calling pseudo-process (`ios_jit_current_peb()`). Session views
  (NULL owner) are never released.
  - Cross-process allocation and mapping (`NtAllocateVirtualMemory` or `NtMapViewOfSection` on
    another process's handle, such as a parent writing a child's parameters) must take the
    target's PEB, not the caller's. Check every such entry point first.
- **Release.** When the dead process's last thread is reclaimed, delete every view whose owner is
  its PEB, except `VPROT_SYSTEM` views, the FEX band and the JIT pool. Use the same rule as
  0139's WoW64 window: the window is retired at exit and torn down by the last thread's
  reclamation. Do not delete them in `process_exit_wrapper` itself: its thread is still running on
  its own stack and TEB, and laggard threads of the process may still be running in its memory.
  - The views must go through `delete_view`, so the page protection, the EC code bitmap and the
    tree stay consistent.
  - Section handles must be forgotten, not closed. 0139 explains why: the server has already
    closed them, and an `NtClose` on another process's thread closes that process's handles.
- **Tests.**
  - A host C test (`app/tests`) of the owner bookkeeping, if `virtual_ios.c`'s view tree can be
    built outside the app. Otherwise the childabort probe, run repeatedly on the phone, with the
    footprint staying flat.
  - A Hollow Knight first-frame gate.
  - A WiX/Burn chain and a Steam game with child processes, because these paths delete memory
    those children shared.
- **Risk.** The change touches every title that starts children. A wrong owner frees live memory
  and leads to host faults that end the app. That is why the work is an issue of its own, not
  part of this chunk.

This does not make CEF work: PLA-369 still stops each helper in DLL init. It removes the memory
death that ends the app, and a launcher's exited helpers and installers stop costing memory.

## Chunk 10: an exited child's views are released (PLA-368)

**The change, madeira-unix 0154.** A `struct file_view` now records `ios_owner_peb`. `create_view`
takes it from a thread-local scope. The scope is set only around `allocate_virtual_memory` and
`virtual_map_section`, which do the work of `NtAllocateVirtualMemory[Ex]` and
`NtMapViewOfSection[Ex]`. A call for another process already runs as an APC on a thread of the
target (`server_queue_process_apc`), so the owner is the target. The runtime's own views have no
owner and are never released: TEB blocks, thread data, thread stacks and the main image's fixed
base.

`process_exit_wrapper` queues an exited x86-64 child. Its views go once every thread of it in
`teb_list` has finished, meaning it reached the end of `pthread_exit_wrapper` or
`process_exit_wrapper`. The release happens on another process's thread, at the next thread
reclamation (`virtual_free_thread_data`) or TEB allocation, as 0139 does for the WoW64 window.
The private and image views go through `delete_view`, and their `wow64_mapping` is forgotten, not
closed.

These are kept and counted:
- views of other sections (shared memory a live process may have cached, such as win32u's
  session blocks);
- `VPROT_SYSTEM` views;
- anything in FEX's band `[0x7c00000000, 0x8000000000)`, the JIT pool or a WoW64 window;
- every view of an i386 child (its window is 0139's; its secondary threads are not in `teb_list`).

One `[view-owner]` line per exit gives the views and MB freed and kept, and the number of
finished threads. If its tables are full, a process keeps its views and that is logged.

No host C test: the patched `virtual_ios.c` exists only in the run tree, and `app/tests` builds
from `upstream/madeira`. The check is on the phone.

**Runs** (IPA `bf9175bf10f05a8248d4eed1d30a338ad5c6c0cd454701f51cd94ce45be1de7c`):

| Run | What | Outcome |
| --- | --- | --- |
| `20261016T083302` | Hollow Knight `app-367520 --until first-frame+10 --shot` | first frame +10.20 s, title menu shown |
| `20261016T083450` | `--settings launcher-rockstar:{"runtime":"env.FEX_SMCCHECKS=none"}` | saved |
| `20261016T083514` | `--action open-launcher:rockstar --until "mark:first window+240" --wait 600` | first window +10.43 s; ran to +250 s, no app crash |
| `20261016T083954` | `--settings launcher-rockstar:{}` | key cleared |
| `20261016T084018` | `--play dir-childabort-325` | refused: not a catalogued title (the library holds only Hollow Knight and RDR2) |

All five ran in one `pp phone lock` session. In the Open, 51 children exited: 47 with
`0x80000003`, the CEF helpers that still crash (PLA-369), and 4 with 0. There were 50
`[view-owner]` lines. A helper's line reads "freed 61 views (300 MB), kept 29 (142 MB); 2
finished thread(s)". The first, non-CEF children freed 30–49 MB each.

**Footprint** (`[xp]` `fpMB`):
- 3,028 MB at +12 s;
- 4,029 MB at +61 s;
- 4,410 MB at +157 s;
- 4,708 MB at +260 s, with a peak of 4,976 MB.

That is about 36 MB per exited helper. In chunk 8, without the fix, it was about 260 MB per
helper (3.2 GB to 7,966 MB with 18 helpers in 140 s).

**Not done:**
- The 142 MB kept per helper is not yet broken down by class (section views, band, pool), and the
  remaining climb is not explained.
- There was no regression play of a title whose children used to work. The childabort probe is
  not in the library.
