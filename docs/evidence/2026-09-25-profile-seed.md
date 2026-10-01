# Guest user profile: Hollow Knight's persistent-data path resolves and is written

*The raw logs, tables and screenshots this record names were removed in the 2026-09-25 repository cleanup; they remain in git history.*

**Date:** 2026-09-24/25. **Tree:** the commits that add the profile seed
(`wine_host.c` `seed_profile`, `PROFILE` in `app/tools/prefix-registry.py`) and
the value top-up in `prefix_registry.c`; this record's commit adds only this
record, its files and the docs.
**Result:** before the change the prefix had no `C:\users` at all, and Hollow
Knight's `JsonSharedData.Save` threw `ArgumentException: Path cannot be the
empty string` at start-up, the same empty persistent-data path its
`DesktopPlatform.WriteSaveSlot` hits on Save and Quit. After it, the game
created `C:\users\playport\AppData\LocalLow\Team Cherry\Hollow Knight` and
wrote `shared.dat` (with its `.bak`) and `AppConfig.ini` there, with no
exception. The ladder passes 6/6 and the three unattended G2 probes pass on
both builds. The in-game Save and Quit round trip was not driven: it needs a
person with the controller (§5).

## 1. Cause

The app never runs wineboot, which creates the profile directories and the
`HKCU\Volatile Environment` values ntdll turns into `%USERPROFILE%`,
`%APPDATA%` and `%LOCALAPPDATA%` (`dlls/ntdll/unix/env.c`
`add_registry_environment`). shell32 still derives the known-folder paths
from `ProfilesDirectory` and the user name, but a lookup without
`CSIDL_FLAG_CREATE`/`KF_FLAG_CREATE` fails with `ERROR_PATH_NOT_FOUND` when the
directory is absent (`dlls/shell32/shellpath.c`
`SHGetFolderPathAndSubDirW`). Unity asks for `FOLDERID_LocalAppDataLow` that
way, so its persistent-data path was empty.

## 2. Change

- `wine_host_init`, shared by every launch mode, sets `USER=playport` (ntdll's
  Windows user name) and creates `C:\users\playport\AppData\{Local,LocalLow,Roaming}`,
  `C:\users\Public` and `C:\ProgramData` when missing.
- The registry seed carries `ProfileList` (`ProfilesDirectory`, `ProgramData`,
  `Public`), the AppData `User Shell Folders` and the `Volatile Environment`
  (`USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `HOMEDRIVE`, `HOMEPATH`, `USERNAME`).
- **Found on the device, fixed in the second build:** a prefix that has run
  anything already has those keys, empty. ntdll's `open_hkcu_key` is an
  `NtCreateKey`, so every process creates `Environment` and `Volatile
  Environment`, and shell32 creates `User Shell Folders` and `ProfileList` on
  first use. The key-level merge skipped them (`user.reg: 4 of 4 seed keys
  present`), so the first build made the directories but left the
  environment unset. `prefix_registry_seed` now appends, for a key the hive
  has, a second section with only the values it lacks, which wineserver merges
  on load; a value the prefix holds is never changed. The two device builds
  applied this top-up to every seed key; the tree now applies it only to the
  profile sections, which the seed marks with a `;; playport:top-up` line, and
  leaves every other key the prefix has untouched, as before.
  `app/tools/prefix-registry-check.sh` checks both on the host wineserver.

## 3. Build and device

- **IPAs:** `Playport-26.5-673202fa.ipa` (sha256
  `673202facba29df273a3173acfc5ea167b79f8264688af2cfb1324427c233ec0`, first
  change) and `Playport-26.5-60363743.ipa` (sha256
  `60363743f6e5d4bf8ddec09a1b6e5eca9a9bab865e562d4dd79da17c4e6ecfb8`, with the
  value top-up), both `build/build-from-pins --from stage` against trees at
  the current pins, verify-ipa 50 checks, 0 failures. Their DXMT and FEX
  hashes differ from `app/artifacts.tsv` (those builds depend on the build
  root); only the registry rows are recorded. Each was installed in place, so
  the existing prefix and the staged Hollow Knight were kept.
- **Before:** the build installed at the time, from another lane, with no
  profile seed.
- **Phone:** iPhone Air (`iPhone18,4`), iOS 27.0, over netmuxd Wi-Fi, every
  command under `flock $PLAYPORT_BUILD/device.lock`.
- **Hollow Knight:** `harness/device/title-device-run.py --pool-mb 896
  --title-wait 120 'Games\Hollow Knight\hollow_knight.exe' -logFile
  'C:\hollow_knight-player.log'`, no one at the phone: the game reached its
  menus and the app stopped waiting at 120 s. In the before run and the first
  after run the harness's own `--out DIR` was passed after the executable and
  reached the game as two extra arguments. Unity ignores them, and the 00:20 run
  had none.

## 4. Results

| Launch | Build | `C:\users` | `JsonSharedData.Save` | Seed log |
| --- | --- | --- | --- | --- |
| 23:53 | before | absent | `ArgumentException` (empty path) | `2 of 2 seed keys present` |
| 00:02 | 673202fa | `playport\AppData\…` created; `LocalLow\Team Cherry\Hollow Knight\shared.dat`, `AppConfig.ini` written | no exception | `4 of 4 seed keys present` (profile values not added) |
| 00:18 | 60363743 | as above | (run cut short, §6) | `9 values added to 2 present keys`, `2 values added to 1 present keys` |
| 00:20 | 60363743 | as above, plus `shared.dat.bak` | no exception | `present with their values` |

Files:
- `before-player-key-lines.txt`:
  the exception, from `Directory.CreateDirectory` under `JsonSharedData.Save`.
- `after-player-key-lines.txt`:
  the same log section on both builds, with no exception.
- `drive-c-listings.txt`:
  `C:\` and `C:\users` before and after (AFC listings of the container).
- `prefix-hive-sections-after.txt`:
  the device prefix's `Volatile Environment`, `User Shell Folders` and
  `ProfileList` after the top-up, as wineserver saved them.
- `s1-host-key-lines.txt`:
  `wine_host`'s profile and seed lines for every launch in the window.
- `gates.txt`: ladder 6/6 pass on both
  builds (final: cold start 5.764 s, peak RSS 1,328 MB, main-thread maximum
  stall 0.3 ms); G2 `g2-graphics/1`, `g2-audio/1`, `g2-input/1` pass,
  `g2-session/1` and `g2-pad/1` not tested (they need a person), as in the
  bootstrap record.

## 5. Not verified

- **Save and Quit round trip.** Pausing, Save and Quit, relaunching and
  loading the slot needs a person with the controller; the harness cannot
  inject input. This run shows the path that call fails on now resolves and
  is writable, not that a slot round-trips. Follow-up: an attended run
  that saves, relaunches and loads, then lists `user1.dat` under `LocalLow`.
- **The environment inside the guest.** The hive now holds the values ntdll
  reads into every process's environment; no probe printed `%USERPROFILE%`
  (the bundle has no `cmd.exe`).

## 6. Incidents

- At 00:19 the workstation killed `S1Probe` while the harness was waiting on
  the 00:18 launch, taking it for the app left in front by the previous run,
  which had held up the install. That launch produced no result; the 00:20
  launch replaced it. The lane's device script now closes the app itself
  before an install and after each title run.
