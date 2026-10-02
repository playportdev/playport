# Launcher feasibility: child processes work; launcher chains remain unvalidated

## Conclusion and scope

**64-bit launchers are possible in principle.** The runtime already starts
Windows child pseudo-processes, gives them windows and waits for them. A launcher
that starts a game is not inherently disallowed by iOS's one-process constraint.
The explanation in the catalogue comments and the earlier
[Witcher record](2026-10-02-witcher3-executable.md) was incorrect and is corrected.

**This is a local source/binary audit, not a successful real-launcher play.**
No launcher was enabled, installed or executed, no runtime patch or selection
policy changed, and no online sources were used. The installed files and IPA,
current patched Madeira trees, and prior phone evidence were inspected.

IPA inspected: `.work/out/20261002-155157-e0960e4e/Playport-26.5-e0960e4e.ipa`

SHA256: `e0960e4e8c10365f619848ff510a6d2904e9891685e8e8504d823923d7d449b1`

## What is already supported

- **Child startup, windows, waits and exceptions.** Madeira-unix 0039–0044
  repair the port's TEB/PEB setup, process identity, wait cleanup, desktop/GDI
  ownership and per-process JIT aliases. [Child-process evidence](2026-09-28-child-process.md)
  includes two child windows whose timers ran and whose exit codes reached the
  parent. Its initial Hollow Knight-child crash preceded the alias fix;
  [decision 0027](../decisions/0027-titles-as-children-of-a-session-root.md)
  records the subsequent working game-child path. Today **every game is already
  a child of `playport-session.exe`**.
- **Launcher lifetime.** `app/SessionRoot/playport-session.c` creates the selected
  EXE suspended, assigns it to a job, resumes it and waits for both that EXE and
  the job to end. A parent exiting while its game is alive does not normally end
  the session. The root also owns the desktop and shared GDI table. Decision
  [0030](../decisions/0030-one-title-per-process.md) deliberately kept these
  facilities for launchers; one title per app process does not mean one Windows
  executable per title.
- **No REDlauncher/Unreal-wide spawn ban.** The current
  `run/unix/mythic/build/ntdll-unix/process_ios.c` blocks named optional Steam
  helpers and UnityCrashHandler64, and separately alters Steam's webhelper.
  REDprelauncher and ordinary Unreal bootstraps are not in that gate.
- **Measured multi-child execution.** [Launcher stress](2026-09-28-launcher-stress.md)
  started, waited for and reclaimed lightweight child code buffers on the phone.
  That synthetic program is no longer shipped (0035); its historical results
  establish process machinery, not commercial-launcher compatibility.

## What prevents simply removing the bypass

### 1. Windows GUI presentation is not integrated into the product launch flow

Madeira's `Winios.m` contains a GDI/DIB-to-CALayer desktop compositor, and
`build/win32u-unix/driver_ios.c` has the corresponding window surfaces. Both
are gated by `MADEIRA_DESKTOP=1`. Playport's normal launch does not enable that
path. `app/Sources/WinIOS/IOSDisplayShim.m` normally gives DXMT one fullscreen
Metal layer; its desktop branch instead supplies a layer per HWND.

`GameSurfaceView` and `PacedMetalLayer` in `HostIO.swift`, plus
`LaunchCoordinator.swift`, signal the first frame only when the fullscreen
Metal layer gets a drawable. `TitleMode.swift`/`LaunchViews.swift` keep the
launch cover up until then. A native GDI launcher can have a live window yet
never cause that signal. Enabling the old desktop environment gate by itself
is not a product solution: the compositor attaches its own view above the
window, can cover the game's Metal view, and its per-window layers are not
`PacedMetalLayer` instances.

Needed: a product-hosted launcher surface, a first-visible-GDI-frame event,
correct view/focus/input routing, and a tested transition to the game's Metal
surface. The existing key/mouse/touch bridge is useful, but controller-only
launchers need navigation/text input too. No new environment-only entry point.

### 2. Installer and dependency coverage is a separate requirement

Wine builds many more DLLs/programs than the IPA stages. The inspected IPA and
the phone's `windows/system32` contain **no `msiexec.exe`, `msi.dll` or
`dcomp.dll`**, although all three exist in the full Wine PE build records.
Finding them in `build/generated/wine-pe-*.tsv` is not evidence they ship.
MSVC 140 runtime DLLs and `winhttp.dll` do ship.

An MSI-based launcher installer therefore lacks its normal installer executable
in this prefix. Staging it and its dependency closure is only a starting point:
custom actions, registry installation, services, browser runtimes and updates
still need validation. Do not run an installer that mutates the player's shared
prefix just to discover this gap.

### 3. Browser launchers have additional, non-universal workarounds

Madeira's current Steam-webhelper path forces single-process Chromium, refuses
its additional `--type=` children and defaults V8 to interpreted (`--jitless`)
execution. The code comments describe constrained PartitionAlloc/V8 address
space and prior browser/JIT failures. These rules match **steamwebhelper.exe**,
not arbitrary CEF, Electron or QtWebEngine helpers. They are not proof another
browser version will work, nor safe switches to apply to every launcher.

The [stress record](2026-09-28-launcher-stress.md) also observed stale execution
after guest code was rewritten and flushed. It has not been revalidated by this
audit. A browser's self-modifying/JIT code warrants a specific test, not an
assumption that ordinary executable translation covers it.

### 4. Process/memory constraints remain

- x86-32/WoW64 children cannot run with iOS's low 4 GiB reserved; inspect every
  EXE in a launcher chain, not just its first 64-bit bootstrap.
- All guests share one Mach process: a crashing helper can take down the app.
- The current blessed pool is **512 MiB** (0036). The old synthetic children
  used about 19.6 MiB of image head and 16 MiB of initial code tail each; actual
  launchers vary widely. Dead image head was not reused in the historical stress
  runs. A browser-heavy launcher plus a game may not fit. Old 896 MiB capacity
  numbers are not today's budget.
- The root currently reports the **selected parent's** exit code after its job
  empties. A launcher exiting 0 can mask a failing game child's exit. The
  no-job fallback also waits only for the selected parent. Test error reporting,
  job assignment, detached children and game lifetime before enabling a chain.
- Graphics routing occurs before runtime start. Inspecting a launcher alone
  cannot determine the API of the game it later chooses. Existing per-game
  backend overrides can select Vulkan, but automatic target/API selection for
  a launcher is a further requirement; it must not infer DX12 from every EXE
  shipped with that title.

## The actual installed REDprelauncher

Read-only phone inspection found:

- `REDprelauncher.exe`: **PE32+ x86-64**, 1,360,848 bytes. It is not a 32-bit
  blocker in this installation. No `REDlauncher.exe` is present in the game
  root; the inspected profile's Local AppData contains Microsoft and Playport,
  not an installed REDlauncher. There is no `Program Files` directory.
- Direct imports include Qt5Core, Qt5Network, PocoFoundation/PocoJSON, MSVC
  runtime DLLs and `QProcess::start` / `startDetached`. These imports demonstrate
  launch plumbing, not successful execution under our Wine port.
- The directory ships `REDlauncher-5.5.0.5.msi` (696,250,368 bytes), and the
  prelauncher contains the explicit installer path `c:\\Windows\\System32\\msiexec.exe`,
  absent from the inspected prefix. Strings describe checking/installing/verifying REDlauncher, waiting
  for it, and falling back to the game if installation/verification/launch
  fails; they also name a `launcher-skip` option. We did not execute it to
  establish exact argument syntax or whether fallback succeeds.
- Its launcher configuration lists only the DX12 game. This audit inspected
  that file for launcher context; **Direct3D detection does not consume it**.
- The game itself still has the separate pre-first-frame AVX blocker from the
  [Witcher record](2026-10-02-witcher3-executable.md). Even a working launcher
  would not establish that this build plays.

Raw imports, strings and pulled EXEs stay in `.work/witcher-directory-check/`;
IPA/system32 inventories stay in `.work/launcher-inspection/`. No proprietary
binaries, container paths or raw logs are committed.

## Recommended next experiment (not implemented)

1. Add a **product UI executable choice** in Game options, keeping direct-game
   discovery as Default and validating paths inside the title. It must identify
   launcher versus game, preserve arguments/working directory and give the
   existing backend override; no terminal launch mode or receipt editing.
2. Start with an installed **small 64-bit bootstrap** (for example an Unreal
   bootstrap), not a browser installer. Prove launcher → game → first frame →
   game exit, including a launcher that exits early, with correct job/error
   reporting and the same 512 MiB pool. Retain the direct-game fallback.
3. Integrate a GDI launcher view and its visible-frame/focus handoff through the
   UI, then test one native GUI launcher. Do not resurrect a shipped synthetic
   dev title without a new record (0035).
4. Only then audit a browser/installer chain's actual binaries, missing staged
   modules and memory needs. Installing REDlauncher needs explicit permission
   to change the shared prefix and a recovery plan that preserves games/saves.

The research result is **feasible for limited 64-bit chains, not universal
launcher support today**. The bypass remains until a concrete chain is shown
working on the phone through the product UI.

## Checks on this chunk

Only comments and documentation changed. `./pp test --quick`, catalogue Swift
regressions, `pp names`, `pp secrets` and `git diff --check` passed. No new
launcher phone run: the findings above must not be presented as one.
