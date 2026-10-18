# FEX profiles for child processes: per-process config in one Mach process (source reading)

**Date:** 2026-10-17. **Linear:** [PLA-76](https://linear.app/playportdev/issue/PLA-76),
alignment item B4. **Kind:** a source reading and a design. There was no build, no
install and no phone run: this was done in a host-only side copy (decision 0069).
**Trees read:**
- Playport at 634c81c.
- FEX `fex` 3648ee97 with `patches/fex-port` and `patches/fex` applied by `git am`. Paths
  below are in that patched tree.
- WineHQ wine-11.19 (`wine` pin 455e350).
- ValveSoftware/Proton bleeding-edge 47c39230.

## 1. How Playport passes FEX settings today

1. `LibraryModel` computes one `FEXProfile.launch` for the executable the launch runs
   (`app/Sources/S1Probe/UI/LibraryModel.swift:337`).
   - It matches the game's Proton entry against that executable's base name
     (`FEXProfile.swift:157-160`).
   - It returns every value as `FEX_<NAME>`: the four ordering keys, the entry's honoured
     keys, `MaxInst`, `X87ReducedPrecision` and `DiskCache` (`FEXProfile.swift:223-250`).
2. `LaunchCoordinator.applyEnvironment` runs after the runtime and the session root have
   started (`LaunchCoordinator.swift:258-283`, called at `:475`). It does two things:
   - It `setenv`s these values into the app's unix environment.
   - It returns them as the title's environment.
3. That environment travels as a session request to `wine_host_session_launch`
   (`WineHostRuntime.swift:125-127`, `wine_host.c:1516-1598`).
4. The session root then builds the title's Windows environment block: its own block with
   the request's variables replacing same-named entries. It passes that block to
   `CreateProcessW` (`app/SessionRoot/playport-session.c:398-426`).
5. Prerequisite installers get the same environment (`runPrerequisites(r, environment:)`,
   `LaunchCoordinator.swift:496`).
6. The game's own children inherit the title's block through Wine's `CreateProcess`. Each
   child therefore carries the launched executable's resolved `FEX_*` values.

So the values are environment variables. They are fixed once per launch, for the
executable the app runs, and inherited unchanged by every child.

## 2. How FEX loads its configuration, per pseudo-process

**Each pseudo-process has its own emulator copy.**
- Every pseudo-process that runs x86 code loads its own copy of `xtajit64.dll` (ARM64EC)
  or `xtajit.dll` (WoW64), with its own data
  (`patches/madeira-unix/0044-virtual-give-each-pseudo-process-s-emulator-its-own-.patch`;
  ARCHITECTURE.md, JIT pool use: a child takes "its own copies of every image it loads").
- So `FEXCore::Config`'s layers, the CRT environment snapshot and the `Context` are all
  per pseudo-process.

**ARM64EC.**
- `ProcessInit` (`Source/Windows/ARM64EC/Module.cpp:882`) runs once per pseudo-process.
  At `:927-934` it:
  1. takes the executable's path from that process's loader data
     (`LdrGetDllFullName(nullptr)`, `Source/Windows/Common/Module.h:9-24`);
  2. reduces it to its base name at the last `\` (`Module.h:43-45`);
  3. calls `FEX::Config::LoadConfig(AppConfigName, _environ, …)`.
- On the iOS ARM64EC build, `_environ` and `getenv` are ucrtbase's: FEX's own CRT is left
  out (`Source/Windows/Common/CRT/CMakeLists.txt:1-10`, `CRT_iOS.cpp`).
- ucrtbase's `DllMain` runs before `ProcessInit`
  (`patches/wine-port/0005-loader-process_attach-xtajit64-dependency-tree-befor.patch`).
  So `_environ` is that pseudo-process's own PEB environment.

**WoW64.**
- `BTCpuProcessInit` (`Source/Windows/WOW64/Module.cpp:658-668`) does the same.
- It reads the environment through FEX's own CRT, which snapshots the PEB environment
  (`Source/Windows/Common/CRT/Misc.cpp:19-74`; patches/fex 0015).

**`LoadConfig`** (`Source/Common/Config.cpp:485-526`) adds these layers, lowest first
(`FEXCore/include/FEXCore/Config/Config.h:51-61`):
1. the global and the main `Config.json`;
2. the `AppConfig/<exe>.json` files, plus `Steam_<SteamAppId>_<exe>.json`;
3. **`FEX_APP_CONFIG`** (`LAYER_USER_OVERRIDE`, `:512-523`);
4. **the environment** (`LAYER_ENVIRONMENT`, `:283-344`).

How a file layer is read:
- `FEX_APP_CONFIG` is loaded only when the file exists (`:519`). A missing file is
  silently skipped.
- The file's `AppOverrides` are matched against the process's own name. The first matching
  pattern is applied after the file's `Config` block (`:55-81`).
- A file without a `Config` object is ignored whole, `AppOverrides` included (`:44-49`).
- On Windows, FEX opens files through the CRT (`access`, `std::ifstream`). A DOS path
  works. Wine also accepts an absolute unix path (`dlls/ntdll/path.c:694`), which is what
  Proton passes.
- `FEX_APP_CONFIG_LOCATION` only moves the main config directory (`:663-675`).

**Per-process values: yes.**
- `X87ReducedPrecision`, `TSOEnabled` and the other ordering keys, `Multiblock` and
  `MaxInst` are read from each process's own config: `FEX_CONFIG_OPT`, e.g.
  `FEXCore/Source/Interface/Core/Frontend.cpp:75`.
- Each process already logs its own `FEX: TSO config …` line
  (`Source/Windows/Common/TSOHandlerConfig.h:47`; fex-port 0045).
- The disk cache keys a process's bucket on its serialized config
  (`FEXCore/Source/Interface/Core/DiskCache.cpp:448-475`), so different values per
  process keep separate databases.
- So `FEX_APP_CONFIG` with `AppOverrides` works in one Mach process as it does under
  Proton. Each pseudo-process matches its own executable name.

**The obstacle is ours.** The environment layer sits above `FEX_APP_CONFIG`, and Playport
exports every value, `X87ReducedPrecision` included, into an environment that each child
inherits. A `setup*` entry in an app-config file would therefore be masked in every
process. Proton itself puts these values in files and exports only `FEX_DISKCACHE`
(`proton` `init_session`, `generate_fex_app_config`).

## 3. Design (not implemented)

**Transport: Proton's.**
- A per-launch app-config file named by `FEX_APP_CONFIG` in the launch environment, so
  every child inherits the name. Each process's FEX picks its own `AppOverrides` entry.
- Only the keys a game's profile entries set move out of the environment:
  - The launch's base value (Proton's global, today `X87ReducedPrecision=1`, decision
    0048) goes into the file's `Config`.
  - The entries go into `AppOverrides`, in Proton's order.
- A key the game's page chose stays in the environment. It still wins for every process,
  as today, and is left out of the file.
- A game without entries gets no file and an unchanged environment. Today that is every
  game but The Witcher 3 (292030).

**Changes, when implemented:**
1. **PlayportKit `FEXProfile`:**
   - Add `Launch.appConfig: String?`, the file's JSON. It is nil when the game has no
     entries, or when the page chose every key the entries set.
   - `launch(…)` drops those keys from `environment` and writes them into the JSON.
   - The JSON is built by hand: FEX takes the first matching pattern in file order, and
     `JSONSerialization` does not keep order. It always has a `Config` object.
   - `x87Reduced`, `maxInst` and the ordering keep reporting the launched executable's
     value.
   - The file header (`FEXProfile.swift:30-33`) changes with it.
2. **App, `LaunchCoordinator.applyEnvironment`** (`LaunchCoordinator.swift:265-283`):
   - Write `appConfig` to `prefix/drive_c/users/playport/AppData/Local/playport/fex-app-config.json`.
     It stays outside `fex-emu`, because `EmulatorCache.clear()` removes that whole
     directory (`EmulatorCache.swift:53-56`).
   - Set `FEX_APP_CONFIG=C:\users\playport\AppData\Local\playport\fex-app-config.json`.
   - Remove a stale file when there is no `appConfig`.
   - Log the entries, e.g. `fex: app config setup*: x87reduced=0 (FEX_APP_CONFIG, every process)`.
3. **A `patches/fex` patch:** each process logs its name and its effective values next to
   its `FEX: TSO config` line: app name, `x87reduced`, `maxinst`, `multiblock`, and
   whether the app config was loaded.
   - FEX says nothing when the file is missing.
   - This line is how the phone shows a child's values (decision 0021's "find and read").
4. **UI** (developer rows, `GameDetailView.swift:976-988`): the x87 picker's footer names
   the game's child entries ("80-bit for `setup*`, the game's profile"). This is display
   only; decision 0012 needs no new entry point.
5. **A decision record** extending 0021 (draft below).

**Host tests** (`FEXProfileTests`):
- 292030 with `witcher3.exe`: `FEX_X87REDUCEDPRECISION` is absent from the environment.
  The JSON parses with `Config.X87ReducedPrecision = "1"` and
  `AppOverrides["setup*"].X87ReducedPrecision = "0"`, and `x87Reduced` is true.
- `setup.exe` launched directly: the same file, and `x87Reduced` is false.
- With the page's x87 chosen: the variable is back in the environment and `appConfig` is
  nil.
- 367520: `appConfig` is nil and the environment equals today's.
- The JSON always has `Config`, and its patterns are in Proton's order.

**Phone checks (owed, main checkout, after a build):**
1. The runtime gate: Hollow Knight (367520) to first frame+10. Its FEX lines are unchanged
   and there is no `FEX_APP_CONFIG`.
2. The Witcher 3 (292030) to first frame+10. The new FEX line for `witcher3.exe` reads
   `x87reduced=1` with the app config loaded.
3. A 292030 child named `setup*` reads `x87reduced=0`. Which binary that is, and whether it
   runs under Playport at all, is not known:
   - The app runs `witcher3.exe` directly, and the receipt skips REDprelauncher
     ([2026-10-02](2026-10-02-witcher3-executable.md)).
   - Proton's commit (c8557782, 2026-07-17) does not name the binary.
   - Find it in the installed depot first.

**Why it is not implemented.**
- It changes what `witcher3.exe` itself receives: the variable goes away, and the value
  comes from a file FEX has never been shown to read on the phone.
- It needs the runtime wiring, a FEX log patch and the phone runs above.
- No played title has a child with an entry. A PlayportKit part that nothing calls would
  be dead code.
- Implement it when a played title needs a child entry, or with B6: Proton puts Steam's
  `STEAM_FEX_TSOENABLED` and `STEAM_FEX_MULTIBLOCK` in the same file's `Config`.

## Draft decision record (at implementation)

> **0NNN: Proton's per-executable FEX entries reach every process through a per-launch
> app config.** Extends [0021](../decisions/0021-fex-ordering-per-game.md).
> A launch whose game has entries in `FEXProfile.protonApps` writes them, in Proton's
> order, to a FEX app-config file and names it in `FEX_APP_CONFIG`, as Proton's
> `generate_fex_app_config` does. The keys those entries set leave the environment, and
> Proton's global value for each goes into the file's `Config`. Each pseudo-process loads
> its own copy of the emulator, reads that file and matches its own executable name. A
> value the game's page chose stays an environment variable and applies to every process.
> **Why:** FEX's environment layer is above `FEX_APP_CONFIG` and children inherit the
> environment, so 0021's transport applied an entry only to the executable the app
> launched. **Costs:** the value for an executable without a page choice now depends on a
> file being read; a missing file falls back to FEX's built-in default without a word from
> FEX, so each process logs its effective values. Supersedes 0021's cost line on child
> processes.

## Seen in passing (not B4)

The title config's `env.FEX_*` keys are exported before the runtime starts
(`LaunchCoordinator.swift:369-373`). The launch's `FEX_*` values then replace them, both
in the unix environment (`:278`) and in the title's block (`playport-session.c:405-415`).
From the source, decision 0021's "a `FEX_*` variable the player sets … wins" therefore
holds only for `FEX_HOSTFEATURES`. This was not checked on the phone.
