# The Steam API emulator: build and first plays

**Date:** 2026-09-27. **Kind:** workstation build, host tests and plays on the
phone (iPhone18,4, iOS 27.0), dev variant.
**Tree:** gbe_fork `7103add7ca6ef3ef8353279219880068f2494fc8` (tag
`release-2026_09_27`) plus `patches/gbe` 0001–0002; Abseil `20250512.1`
(`76bb24329e8bf5f39704eb10d21b9a80befa7c81`); built by
`build/stages/steamapi.sh` with llvm-mingw 20260922.
**Plan:** [phase 1 of the Steam plan](../plans/2026-09-27-steam-for-games.md).

## Build

- **gbe_fork's regular `steam_api` builds on Linux with llvm-mingw** for
  x86-64 (`steam_api64.dll`, 8.4 MB) and i386 (`steam_api.dll`, 8.7 MB). It
  links all its dependencies statically (libssq, zlib, Mbed TLS, curl,
  protobuf with Abseil, Opus, PortAudio, SDL 3). The DLLs import only system
  DLLs Wine ships (the UCRT API sets, kernel32, advapi32, ws2_32, bcrypt,
  dbghelp, iphlpapi, ole32, setupapi, shell32, user32, winmm, xinput1_3,
  ntdll). They export 1282 names, among them `SteamAPI_Init`,
  `SteamAPI_RunCallbacks` and `SteamInternal_CreateInterface`.
- **What had to change** is in `patches/gbe`, both `linux-build`:
  1. `crash_printer/win.cpp` includes `<DbgHelp.h>`, and MinGW's header is
     `dbghelp.h`.
  2. The premake script, for a Windows target built on another host:
     - premake's gcc toolset adds `-L/usr/lib64` and `-L/usr/lib32`, so lld
       linked the host's ELF `libc++.a` ("unknown file type");
     - `-Wl,--exclude-libs,ALL` is an option lld's COFF driver rejects;
     - the import libraries are named in mixed case, and MinGW's are lower
       case;
     - MinGW's SDL 3 static library is `libSDL3.a`, not `SDL3-static`;
     - the system libraries MSVC takes from `#pragma comment(lib)` (ole32,
       setupapi, shell32, uuid, winpthread) have to be named.
- **Generated sources and Abseil.** The generated protobuf sources need a
  `protoc` of the same release (34.1). The system's 36.1 is not that, so the
  stage builds one for the host from the same archive. Protobuf's CMake
  downloads Abseil from GitHub when it finds none, and the host build had
  quietly taken the system's. Both builds now use the pinned tag from a cache
  mirror with `FETCHCONTENT_FULLY_DISCONNECTED`, and `CMakeCache.txt` shows
  `absl_SOURCE_DIR` at that checkout.
- **Reproducible in one build area.** A second build from scratch gave the same
  sha256 for both DLLs. Abseil and protobuf keep `__FILE__`, and
  `verify-ipa`'s path check failed on 135 and 152 build paths until the stage
  mapped its root (`-ffile-prefix-map`).
- **The IPA** passes `verify-ipa` (66 checks), including the three new
  `steamapi` ones: native DLLs (no Wine builtin mark), the right machine, and
  the three exports.
- **Stage time:** about 2 min 50 s (host protoc, the deps for both arches, both
  DLLs).

## Host tests

- `pp test --swift app/SteamClient`: 105 tests pass, 11 of them new. They cover
  apply, idempotence, restore, a kill between the rename and the copy, a DLL
  of the wrong machine, a missing emulator, the mode, the settings files, the
  owned-DLC intersection, verify and repair through a swap (Steam manifests
  and sha256 lists), and the service's profile and launch settings.
- `pp test --swift app/PlayportKit`: 27 tests pass (the new `steamAPI` launch
  setting).
- `tools/tests/test_ui.py`: 8 pass (`open:ID#SECTION`).

## On the phone

| IPA sha256 | Title | Steam API | Result |
| --- | --- | --- | --- |
| `284c46264dc58fd33021cd638809170716c1c952c74e9ec4cd6530d3c4aaef42` | Hollow Knight | emulator | first frame at +10.10 s, ran on to +10 s |
| same | Hollow Knight | the game's own | first frame at +10.18 s, ran on to +10 s |
| `af8defcee1adb05522db1b7460db0c1f1508ce2ee298c6bbbbfccddf2eda8f64` | Hollow Knight | emulator, profile fetched | first frame at +9.19 s, ran on to +15 s |
| same | En Garde! | the game's own | game started at +3.63 s, no frame in 18 min (stopped by hand) |
| `ab47b5891b6d04def50dfd9ad88806e5c068d048cba772baed127cd5944e4315` | En Garde! | emulator | game started at +4.38 s, no frame in the 4 min wait |

- **Hollow Knight talks to the emulator.** Its own player log
  (`C:\hollow_knight-player.log`) from the emulated play shows `Steam
  initializing`, `Steam logged in as <the account's persona name>`, `Selected
  online subsystem SteamOnlineSubsystem` and `Steam stats received.` That is
  gbe_fork answering, x86-64 under FEX, with the persona name the service
  fetched with `ClientRequestFriendData`.
- **The launch applies the mode.** Each play logs `title: steamapi: <mode>:
  <state>` and emits a `steamapi` run event. The game page's Steam section
  (`open:app-367520#steam`) showed the folder going from "The game's own" to
  "Playport's emulator" and back.
- **The profile needs the session up.** A page opened while a restore was
  still running fetched nothing: the fetch was tied to the page's first
  appearance. It now runs again once the account is signed in, and the next
  run showed the persona name and "None owned" for DLC.
- **En Garde! is not a phase 1 title.** Its shipping executable is wrapped in
  Steam DRM (`steamdrmp.dll`, SteamStub; see
  [the Vulkan record](2026-09-26-vulkan-d3d11-d3d12.md)), which checks for a
  running Steam before the game's code runs. The emulated play swapped the DLL
  (`steamapi: emulated: emulated`) and still drew nothing. It is phase 2's
  target.

## Not checked

- An i386 title (`steam_api.dll`): no 32-bit title is installed.
- A title that owns DLC, and a game that fails without Steam but carries no
  SteamStub.
- The release variant on the phone (it compiles: `pp check --variant release`).

## Phase 3: achievements and stats

IPA `773587944e5e95d826578e34d21d2bb69336fc8fb691e485e466c50c641032f4`.

- **Read.** Opening Hollow Knight's page synced it: `ClientGetUserStats`
  returned its schema (63 achievements, no stats) and the account's state,
  0 unlocked. The Steam log reads `app 367520: 0/63 achievements on Steam;
  sent 0 unlock(s) and 0 stat(s), 0 to the emulator`. Nothing was stored: the
  emulator had no save for any game yet.
- **Launch.** The next play wrote `achievements.json` (68 KB) and `stats.json`
  into `steam_settings/` beside `steam_api64.dll`, and reached its first frame
  at +9.59 s.
- **Host tests:** `pp test --swift app/SteamClient`, 124 pass (one skip, the
  real-sample SteamStub test). They cover the schema parse, the emulator's
  files, the sync plan, and the service's sync against a fake Steam: an
  unlock sent, Steam's unlocks and stats to the save, the stat baseline, a
  first sync that sends no stat, a refused stat, and sign-out.
- **Not shown:** an achievement unlocked during a play reaching the account.
  It needs a real unlock, which the scripted plays do not reach, and it
  changes the account's profile.

## Phase 4: Steam Cloud (2026-09-28)

IPAs `8d2a10bebadc621b1f7343cd4e2e31383829070eb4c5ec3c95bda24a9424ecd8`
(first sync) and `fce0cbc4b07fd33f4ff642da0e706e08a58d15f0f1ebb8785f3825ce5b3dd0da`
(clearer choices, the upload).

- **First sync at app start**, for every played game (times UTC):
  - The Witcher 3: `41 on Steam, 49 on the phone; 40 down, 0 up, 9 conflict(s)`.
    The 40 downloads are PC saves the phone lacked, added to `gamesaves`.
    No `Cloud Backups` folder was created, so no file was replaced.
  - Hollow Knight: `0 on Steam, 3 on the phone; 3 conflict(s)`. Its three
    saves were never uploaded unasked.
  - En Garde!: `4 on Steam, 4 on the phone`, all equal: nothing moved.
- **The page** listed Hollow Knight's three saves with their sizes and times,
  and "none" on Steam. For a file Steam lacks, "Keep Steam's" read as
  nonsense, so the choices became "Send to Steam" and "Keep it off Steam".
- **The upload.** The player tapped "Send to Steam" on each of Hollow
  Knight's three saves. Each sync uploaded one file, which the next
  changelist listed:
  - 22:07:39: 0 on Steam, 1 up, 2 conflicts left;
  - 22:07:43: 1 on Steam, 1 up, 1 left;
  - 22:07:46: 2 on Steam, 1 up, none left.

  None failed: the batch, the upload blocks' PUTs and the commits all
  succeeded.
- **The Witcher 3's DLC**: the page lists its 19 owned DLC by name, the first
  real check of the phase 1 DLC list.
- **Seen from a PC:** the player's PC shows Hollow Knight's three cloud
  saves after the upload.
- **Not shown yet:** a download of a changed file with its backup, and a
  conflict settled either way.
