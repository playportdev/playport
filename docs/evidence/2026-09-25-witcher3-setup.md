# The Witcher 3 (1.32): workstation setup and the address-space wall

**Date:** 2026-09-25. **Tree:** this record's commit (adds `tools/phone-busy`,
the title's checksum list and this record). §1–§15: **no device run**; the
phone was in use by another session, and nothing there touched it. §16:
staged and launched twice on the shared phone in its idle gaps (iPhone Air,
iOS 27.0, netmuxd Wi-Fi), with the IPA sha256s given there.
**Patch numbers** are as merged onto main: the runs here used this branch's
own series, where `patches/madeira-unix` 0016 and 0017 were numbered 0015
and 0016 and `patches/dxmt` 0006 was 0005 (main's madeira-unix 0015
thread QoS and dxmt 0005 compile timing were not in these IPAs).
**Update (§16):** with `jumbo-mb = 32768`, 0016 and 0017 the 8 GB and 32 GB
reservations both succeed on the phone; the title now stops at D3D11 device
creation (a DXMT compute pipeline).
**Update (§17–§20):** with dxmt 0006 and the fixes in §17–§18 it reaches
gameplay at 30 fps (§19), Play from the library works on the phone, and the
Witcher 3 IPA was left installed for a player (§20).
**Update (§21):** the full player path, library Play with the app's own JIT
helper and no workstation debugger, runs the game; one of two such launches
crashed the app in the helper's teardown when Play overlapped the readiness
check.
**Result:** the title is ready to stage from the workstation; the known wall
to a first frame is a 32 GB address-space reservation; the paid
extended-virtual-addressing entitlement, the unlock an earlier attempt named,
does not lift it; Madeira already carries a boot-time holdback that may.

## 1. The title

| Field | Value |
| --- | --- |
| App / branch / build | 292030 / `classic` (patch 1.32, D3D11 only) / 3280809 |
| Depots | 23 (base content, common, English voice, x64 binaries, `witcher3.exe`, `metadata.store`, 16 free DLC, the unused 4.x launcher depot 370009); expansions 378648/378649 not installed |
| Executable, arguments | `bin\x64\witcher3.exe`, none (the root-level `REDprelauncher.exe` is x86-32 and is not run) |
| Architecture, graphics | x86-64 (every PE under `bin/`), Direct3D 11; four stream-output geometry shaders at the menu, which DXMT does not emulate |
| Steamworks | `bin\ddi\Steam.dll` loads `steam_api64` by path |
| Installed size | 41,585,389,035 B, 2,459 files |
| Checksum list | `harness/titles/witcher3-292030-3280809.sha256` (sha256 `2d5d5323…22e5af`), from `steam-manifest-check.py` against the 23 depotcache manifests; rerun on 2026-09-25: `install: 2459 files, 0 mismatched or extra, 0 missing`, exit 0, and a byte-identical list |
| Workstation copy | `$PLAYPORT_BUILD/titles/witcher3-292030-3280809` (read-only, a link to the existing verified copy); manifests in `$PLAYPORT_BUILD/titles/witcher3-depotcache` |

The five Wine builtins the title needs beyond the reference set (`vcomp110`,
`msvcp120`, `msvcp110`, `msvcr110`, `xaudio2_7`) are already bundled
(`EXTRA_PE` in `build/stage-artifacts.py`, `xaudio2_7`'s COM classes in
`app/tools/prefix-registry.py`).

## 2. The wall, from an earlier boot on the same runtime

An earlier build of this runtime (same Madeira allocator, `virtual_ios.c`)
staged the same copy on the same phone (iPhone Air, iOS 27.0) and started
`witcher3.exe` through `S1_MODE=title`. The loader, the relocations, the
imports and the TLS callbacks all worked. Then, in its first 100 ms and from
one call site, the game reserved **8 GB (granted), 32 GB (refused,
`STATUS_NO_MEMORY`) and 1.6 GB (granted)**, wrote through the NULL it got
back for the 32 GB, and exited `0xc0000005`. Peak footprint 1,272 MB; no
window, no frame.

The address space it had to fit in, from the `vm:` lines `wine_host.c`
logs at start-up:

| Range | What | Mach user tag |
| --- | --- | --- |
| `0x0..~0x100000000` | page zero (Wine reserves the low 4 GB) | |
| `0x180000000..0xfc0000000` | the dyld shared region | 32 (`VM_MEMORY_SHARED_PMAP`) |
| `0xfc0000000..0x7000000000` | the GPU carve-out, unmappable by the CPU | 31 (`VM_MEMORY_GUARD`) |
| `0x7000000000..0x8000000000` | **the only window for every Windows allocation (64 GB)** | |

`TASK_VM_INFO.max_address` is `0x8000000000`. At the refusal 47.9 GB was
free in the window, in three gaps of 7,072, 24,576 and 16,256 MB: before the
8 GB reservation there had been exactly one 32 GB hole, and the 8 GB landed at
its bottom.

## 3. Extended virtual addressing does not help

XNU grants the same "jumbo" map for any of several entitlements
(`bsd/kern/kern_exec.c`, `proc_apply_jit_and_vm_policies`):

    needs_jumbo_va = jit_entitled || IOTaskHasEntitlement(task,
        "com.apple.developer.kernel.extended-virtual-addressing") ||
        memorystatus_task_has_increased_memory_limit_entitlement(task) || …;
    if (needs_jumbo_va) vm_map_set_jumbo(get_task_map(task));

Playport already signs with `increased-memory-limit` (and its JIT is
debugger-granted), so it already has the jumbo map: the measured
`max_address=0x8000000000`. The only larger map is `vm_map_set_extra_jumbo`,
reached only through the private `com.apple.kernel.large-file-virtual-addressing`
entitlement. So the paid entitlement adds no address space for this title;
the wall has to be handled inside the 64 GB window.

## 4. The route inside the window

Madeira's allocator already has an opt-in **jumbo holdback**
(`virtual_ios.c`, `ios_jumbo_holdback_init`/`_take`, called from
`loader_ios.c` after the FEX arena is reserved): with `jumbo-mb = N` in
`madeira.cfg` it reserves N MB at the top of the largest free hole at boot,
before Wine's furniture can fragment it, and hands it to the first large
reservation the kernel cannot place (`[jumbo] kernel-pick reserve failed`
branch). `jumbo-keep-mb` lets smaller asks be carved off its top. It was
built for another title's single 8,960 MB reservation.

For this title the expected sequence with `jumbo-mb = 32768` is: the hold
takes the top 32 GB of the window; the 8 GB and 1.6 GB reservations still fit
below it (about 16 GB and 7 GB were free there); the 32 GB request fails the
kernel pick and is mapped at the hold. Not yet shown:

- that Wine's furniture and the FEX arena still fit with 32 GB held;
- what the game reserves next, and the per-thread address-space cost with
  about 66 threads (measured on host Wine at the menu);
- the ~6 GB physical ceiling, the FEX code buffer against a 28.8 MiB `.text`,
  and the four stream-output shaders.

`madeira.cfg` is one file for every title, and the other session tunes
Hollow Knight with it, so a W3 launch must set its keys just before and
restore the previous file just after. The runtime also takes the file's
directory from `MADEIRA_DOCS_DIR`, which would allow a per-title file later.

## 5. The phone is shared

`tools/phone-busy` tells whether another job is using the phone without
asking the phone ([DEVICE.md](../DEVICE.md#reaching-the-phone)): the device
lock, a running phone-driving process, a device run directory changed in the
last 10 minutes, and (informational, or a reason with `--strict`) another
agent session whose objective names the phone. On 2026-09-25 at 01:30 CEST
it reported idle with one claim, the Hollow Knight tuning session; at 01:40,
while that session ran a title, it reported busy on the lock, its
`title-device-run.py` and `pymobiledevice3 syslog`, and (with
`--dir lanes/perf`, where that session writes its runs) a run directory
changed 0 s before.

At 02:31 the default check reported idle while that session's
`lanes/perf/base1` had changed 45 s before: it was between two runs, and
lane run directories were only watched with `--dir`. `phone-busy` now
watches every `lanes/<lane>/<dir>` by default, except a lane's build trees
(`run`, `out`, `cache`, `scratch`, …, and any nested build root holding an
`inputs.local`), and it no longer follows symlinks when dating entries (a
lane's `cache` link otherwise took the shared cache's time). The same check
then reported busy on `lanes/perf/base1` and `lanes/perf/r720long`.

The Witcher 3 push is the longest phone job here (41.6 GB, one file of
6.5 GB: `content/content4/streaming.cache`, 48 files over 100 MB), and the
other session measures heat, which a long Wi-Fi transfer adds to. So the
push must be able to hand the phone back part-way. That session takes the
lock with `flock $PLAYPORT_BUILD/device.lock <job>` (at 02:46 its
`perf-run.py --vpad` run was under pid 3320744). A job that blocks in
flock(2) shows up in `/proc/locks` as a `->` line with the lock's inode, for
example `130: -> FLOCK ADVISORY WRITE <pid> 00:1c:31182325 0 EOF`. The
device field there (`00:1c`) differs from the file's `st_dev` on this btrfs
`/home` (0x34), so match the inode only. `tools/phone-busy --waiters` exits
1 while such a waiter exists. It was tried live on a scratch lock: exit 1
with `waiting: pid … flock t.lock true` while a second `flock` was blocked,
then exit 0 once the lock was free. `stage-title.py push --yield` polls it
every 10 s and stops within one 4 MB block (`--budget-s` sets a time limit
instead), exiting 3. The next run appends to a cut-short large file
instead of starting it again, and `--no-verify` skips re-hashing the local
41.6 GB. Tests: `test_waiters`, and `PushTest` against a stand-in AFC (a
stop in the middle of a file, then a rerun that opens it in append mode and
ends with the same bytes, renamed from `.partial`).

## 6. Host trace: the reservations are fixed sizes

A host Wine run (Wine 11.18, wined3d, headless gamescope, a fresh prefix
under `$PLAYPORT_BUILD/w3host` with the verified copy linked in as
`C:\Games\The Witcher 3`) with `WINEDEBUG=+virtual`, read with
`tools/wine-reserve-trace`, which lists every reservation of 16 MB or more.
`tools/wine-reserve-trace shim` builds an `LD_PRELOAD` library that makes
host Wine report `$FAKE_PHYS_MB` of physical memory; the game reads it
(`GlobalMemoryStatusEx`) just before its first large reservation.

Three 50 s runs, each reaching wined3d shader compilation (840 shader lines,
47 threads), with reported physical memory 31,692 MB (the host's own),
6,143 MB and 4,095 MB, gave **the same list, in the same order, every
time**:

| Reservation | Size | Committed at once |
| --- | ---: | --- |
| reserve | 8,192 MB | 2 MB steps later, about 600 MB in the first seconds |
| reserve | 32,768 MB | 1,600 MB at its base, straight after |
| reserve | 300 MB | all of it |
| reserve | 2,048 MB | 128 MB |
| reserve | 40 MB | all of it |
| reserve + commit | 72, 72, 52, 512 MB | all |
| reserve | 32.1 MB | all (one more is taken and released twice) |

Peak live large reservations: **44,088 MB**. So `totalphys` changes nothing
here and the phone will see the same 8 / 32 / 1.6 GB sequence as the earlier
boot. Against that boot's free space in the window just before the first
ask (7,072 + 32,768 + 16,256 = 56,096 MB), 44,088 MB leaves about 12 GB for
the runtime's own growth, but only if the 32 GB is still one hole when it is
asked for. That is what `jumbo-mb = 32768` is for: the hold takes the top
32 GB of the largest hole at boot, after the FEX arena; the 8 GB ask should
fit in the 16 GB hole (and is exactly `0x200000000`, the size Madeira's always-on
8 GB cage holdback at `0x7200000000` serves when the kernel pick fails); the
32 GB ask fails the kernel pick and takes the hold; the rest should fit in
what is left (untested on the phone). §8 corrects where the hold lands: at
the top of the address space it would take FEX's band. `jumbo-keep-mb` stays unset: nothing else asks for more than 2 GB.

Per-launch configuration without the shared file: Playport's host does not
set `MADEIRA_DOCS_DIR` (`wine_host.c` sets only `HOME` to the prefix), so a
driven run can pass `--env MADEIRA_DOCS_DIR=<container>/Documents/prefix/Documents/w3`
to `title-device-run.py` with its own `madeira.cfg` there, leaving the other
session's file untouched. The runtime also writes its FEX JIT dump and retire
trace there. The absolute container path comes from installation_proxy's
`Container` attribute. A Play from the library needs an app change instead:
the cohort entry has no per-title configuration yet, and its `executable`
must sit directly inside the install folder, while this title's is
`bin\x64\witcher3.exe`.

## 7. Per-title keys and the library entry (app change, not yet on the phone)

The app now carries both halves of step 2 below it (PlayportKit tests pass;
the S1Probe target compiles for iOS; no IPA was installed, since the phone
was in use):

- `titles.json` pins this title (decision 0005): `bin\x64\witcher3.exe`,
  no arguments, the 23 depots, the checksum list, and
  `"config": {"jumbo-mb": "32768"}`. Adoption finds an executable below the
  install folder, matching each component without case.
- A launch with keys (a cohort entry's `config`, or a driven launch's
  `TITLE_CFG`, `title-device-run.py --cfg KEY=VALUE`) writes
  `Documents/prefix/Documents/title-cfg/The Witcher 3/madeira.cfg` as the
  shared file followed by the keys, and sets `MADEIRA_DOCS_DIR` to that
  directory before `wine_host_init`. The shared file is never edited, and no
  container path is needed.

## 8. The holdback would have taken FEX's band (madeira-unix 0016)

Reading the earlier boot's log against Madeira's placement code showed that
`jumbo-mb = 32768` on its own would have stopped the title before its first
x64 instruction:

- The holdback runs in `loader_ios.c` before `load_ntdll`, and places its
  size at the top of the largest free hole below `max_address`. On this phone
  that hole is the top tail, `0x73ffff0000..0x8000000000` (49,152 MB, from
  the boot's `[va-gaps] (jit pool init)` walk), so a 32 GB hold would be
  `0x7800000000..0x8000000000`.
- FEX's host band is chosen later, by rpmalloc's selector
  (`patches/rpmalloc-port` 0009 and 0010): it tries
  `[0x7c00000000, 0x7fffffffff]` first (the boot's
  `[va-profile] ml706 SELECTED base=0x7c00000000`), then
  `0x0c00000000..0x0dffffffff` and a sweep of `0x0800000000..0x1000000000`.
  This phone refuses every address below 64 GB (`[va-profile] ml749 ... 32-63GB
  -> refused (kr=3)`), so with the top 16 GB held FEX finds no band
  (`ml755 FATAL: no FEX arena`). The holdback was built for a device whose
  ceiling is `0xfc0000000`, where the band is a low one and they never meet.

`patches/madeira-unix/0016` caps the holdback's hole walk at `0x7c00000000`
(a device whose ceiling is at or below that is unchanged). Expected layout on
this phone:

| Range | Holder |
| --- | --- |
| `0x7038004000..0x71ffe00000` (7,293 MB) | Wine's furniture, then the 1.6 GB / 2 GB / 300 MB asks |
| `0x7200000000..0x73ffff0000` | the 8 GB cage holdback (fixed) and furniture |
| `0x7400000000..0x7c00000000` | the 32 GB jumbo hold, then the 32 GB ask (the tail is 32 GB + 64 KB: 64 KB of slack, set by the cage's fixed end) |
| `0x7c00000000..0x8000000000` | FEX's band (about 106 MB used at the 32 GB ask), then the 8 GB ask by first fit, leaving FEX about 8 GB |

The patched `virtual_ios.c` compiles for iOS with the unix stage's own flags
and no new warnings, and the whole series applies to the pin with `git am -3`.
It is not in an IPA yet. The expected device log lines are `[jumbo-hold]
ceiling 0x8000000000 capped at 0x7c00000000`, `HELD 0x7400000000 +32768 MB`,
`[va-profile] ml706 SELECTED base=0x7c00000000`, then `[jumbo] kernel-pick
reserve failed ... size=0x800000000` followed by `ml997 mapped at the
holdback -> 0x7400000000`. A `NOT holding` line means something took the
64 KB of slack before the hold, and the fallback is the old failure, not a
new one.

## 9. The IPA with §7 and §8 (built, not installed)

**IPA:** `$PLAYPORT_BUILD/lanes/w3/out/20260925-021023-f82693a2/Playport-26.5-f82693a2.ipa`,
sha256 `f82693a2ddda3c63cca22505e3faf964e8ea43ecdfd3907747528f102be2d038`,
667,946,124 B; `verify-ipa` 59 checks passed. It carries `Titles/titles.json`
with the Witcher 3 entry and its checksum list, and the executable holds the
0016 log string `[jumbo-hold] ceiling 0x%llx capped at 0x7c00000000`.

How it was built, without touching another lane's trees:

- `run/unix` is a reflink copy (`cp -a --reflink=always`, under a second on
  btrfs) of `$PLAYPORT_BUILD/run/unix`. The copy's two absolute symlinks,
  `mythic/wine` and `ROOT/build`, still pointed into the original and were
  re-pointed at the copy; `shims` was rerun to rewrite the paths in `xcrun`.
- Rebuilding `libntdll_unix.a` in the copy *before* the patch gave the
  canonical hash `1e0dd09a…`, so this archive does not depend on the build
  root. Then `ntdll-unix-build.sh ROOT clones` applied the 15-patch series
  (`mythic/wine` must be a plain directory for that step: with the symlink
  in place `git diff` fails and `apply_series` reports "local changes"),
  and `unix-side-gaps.sh ROOT gnutls-config linktest` rebuilt ntdll:
  `0c6f2898…`, 1,781,464 B; the link test gives the expected result (the
  as-built wineserver `LINK FAIL` on its four duplicates, `-ws4` `LINK OK`).
  GnuTLS, win32u and wineserver were not rebuilt; their hashes are unchanged.
- `pe` and `xinput` link to `$PLAYPORT_BUILD/run`. `dxmt-*` and `fex` link
  to `lanes/profile-seed/run`: the shared `run/dxmt-patched` is still the
  pre-rebase Madeira DXMT (5 commits, not 3Shain main plus the port) and
  `run/fex` is an older FEX build, and staging them produced a smaller
  `d3d11.dll` and a different `libdxmt_combined.a`. `verify-ipa` does not
  catch that, because it checks the IPA against the `artifacts.tsv` the run
  has just rewritten.
- `build-from-pins --from stage`. Against the committed `artifacts.tsv`
  the run changed 9 rows: `libntdll_unix.a` (0016), `xtajit64.dll` (FEX
  embeds its build time) and seven DXMT PE DLLs, whose hashes depend on the
  tree they were built in. They match the `jit-builtin` lane's last IPA
  (`20260925-012105-28583f86`), which is built from the same trees. Only the
  `libntdll_unix.a` row is committed; the IPA's own record is
  `lanes/w3/artifacts-ipa.tsv`.

## 10. Documents and the phone's settings file

**The prefix had no `C:\users\playport\Documents`.** `wine_host.c` created
only the AppData folders, `Public` and `ProgramData` (the profile-seed
listing, `2026-09-25-profile-seed/drive-c-listings.txt`, has no Documents).
Witcher 3 looks up `CSIDL_PERSONAL` without `CSIDL_FLAG_CREATE`. A host run
with the prefix's Documents link moved away (`WINEDEBUG=trace+shell`) shows
the lookup fail:

    SHGetFolderPathAndSubDirW returning 0x80070003 (final path is L"C:\users\<user>\Documents")

The game carries on to shader compilation (840 lines, the same as with the
folder present), but without the folder it reads no `user.settings` and has
nowhere to write settings or saves. `seed_profile` now also creates
`C:\users\playport\Documents` and `C:\users\playport\Saved Games` on every
launch.

**Low settings from the game's own presets.** `harness/titles/witcher3-settings.py`
resolves the menu's "low" preset (`bin/config/r4game/user_config_matrix/pc/rendering.xml`
and `postprocess.xml`, each `Virtual_*` option expanded to its concrete
`[Group] Key=value` lines). It then adds the phone's own choices:
borderless at the guest's single display mode (`FullScreenMode=1`,
`Resolution="-1x-1"`, so `HOST_SCREEN` picks the render size), VSync off,
`[Engine] LimitFPS=30`, HairWorks off, `ConfigVersion=2`. The output is
committed as `harness/titles/witcher3-user.settings`, and `--check` confirms
the committed copy still matches the game's data. A 50 s host run with this
file as `Documents\The Witcher 3\user.settings` kept every key: the file the
game rewrote on start has 49 of the 58 with the same value, and leaves out
the other 9 because they equal the `bin/config/base/*.ini` defaults (the game
writes only non-default values). `stage-title.py put BUNDLE_ID LOCAL REMOTE` writes such a
file over AFC and reads it back.

## 11. The IPA with §10 (built, not installed)

**IPA:** `$PLAYPORT_BUILD/lanes/w3/out/20260925-022509-8b67860a/Playport-26.5-8b67860a.ipa`,
sha256 `8b67860a24ab10c3e18098dc1527edae1940c31d4211d6eddb5101672beaf6da`,
667,946,128 B; `verify-ipa` 60 checks passed. It is the §9 build (same lane,
same trees, `build-from-pins --from stage`, under 2 minutes) plus the
`seed_profile` change; the executable holds `users/playport/Saved Games`. The
run rewrote the same 8 tree-dependent rows as §9 and nothing else, so
`app/artifacts.tsv` is unchanged; the IPA's own record is
`lanes/w3/artifacts-ipa-8b67860a.tsv`. It replaces the §9 IPA.

## 12. A per-title screen for library Play, and its IPA (built, not installed)

Library Play rendered at the panel's native pixels, since only a driven
launch could set `HOST_SCREEN`, and Witcher 3 1.32 has no render-scale
setting: with `Resolution="-1x-1"` it renders at the guest's desktop size. A
cohort entry now has an optional `screen`, a `HOST_SCREEN` spec
(`native`, `<rows>`, `4:3`, `WxH`). `LaunchPlan.make` checks it
(`validScreen`; a bad spec throws `badScreen`), `TitleLaunch.start` passes it
to `TitleScreen.configure(title:)`, and `HOST_SCREEN` in the launch
environment still wins. The display line in `s1-host.log` then reads
`screen WxH (the title's screen 720)`. Witcher 3's entry has `"screen": "720"`,
the same size as the driven command in §17. The screen is configured once
per process, so it follows the first title launched; a debugger-attached
launch spends the process anyway.

Checks: PlayportKit `swift test --build-system native`, 18 tests (a new
`testScreenSpecsAreCheckedBeforeTheLaunch`, and the Witcher 3 and Hollow
Knight plans check `screen`); the S1Probe target compiles for iOS in the
scratch copy.

**IPA:** `$PLAYPORT_BUILD/lanes/w3/out/20260925-023049-66bc297c/Playport-26.5-66bc297c.ipa`,
sha256 `66bc297ccdf31c70ce62df039a0cbc4ee503cdb5de1ded5bc7221b0711b8a354`,
667,966,699 B; `verify-ipa` 60 checks passed. Same lane and trees as §11
(`build-from-pins --from stage`, under 2 minutes); its `Titles/titles.json`
has the `screen` key. The 8 tree-dependent rows equal §11's, so
`app/artifacts.tsv` is unchanged; the IPA's own record is
`lanes/w3/artifacts-ipa-66bc297c.tsv`. It replaces the §11 IPA.

## 13. The game's own xinput1_3.dll would hide the controller

`witcher3.exe` imports `XINPUT1_3.dll` statically, and the game ships
Microsoft's copy (9.18.944, 107,368 B, sha256 `756cad00…`) in `bin\x64`
beside it. The app loads its own XInput DLLs (`hio_xinput`, not Wine
builtins) as native from system32, through
`WINEDLLOVERRIDES=xinput1_1,…,xinput9_1_0=n` (`HostIO.swift`). Native search
tries the application folder before system32, so on the phone the game would
get Microsoft's DLL. That DLL looks for pads through SetupAPI and HID, and
there is no `winebus.sys` in this process, so the game would never see a
controller. It would still start, so the only sign would be a missing
controller.

Host check (Wine 11.18, the device's `WINEDLLOVERRIDES`, the app's
`xinput1_3.dll` copied into the host prefix's system32, `+loaddll`, logs in
`$PLAYPORT_BUILD/w3host/run8/xin-*.txt`):

| game folder | loaded |
|---|---|
| the verified copy | `C:\Games\The Witcher 3\bin\x64\XINPUT1_3.dll : native` (Microsoft's) |
| a symlink copy without `bin\x64\xinput1_3.dll` | `C:\windows\system32\XINPUT1_3.dll : native` (the app's) |

Both runs went on to load d3d11 and create the window. Neither a load-order
override nor KnownDLLs gets around this:
- An override on the full path (`…\bin\x64\xinput1_3=b` or `=`) is applied
  when the file is mapped, after the search has already picked the file. The
  load fails instead of moving on to system32 (unix `load_builtin` is called
  from `NtMapViewOfSection`). In any case, `WINEDLLOVERRIDES` treats spaces as
  separators.
- KnownDLLs sections are created by wineboot (`create_known_dlls`), and the
  app never runs wineboot.

So staging hides the file: `stage-title.py hide $BID
"Documents/prefix/drive_c/Games/The Witcher 3/bin/x64/xinput1_3.dll"` renames
it to `xinput1_3.dll.playport-hidden`. A rerun does nothing. `check` counts
the hidden copy as the listed file, so the checksum list still passes.
Windows loads its own system32 copy the same way when the game's copy is
missing.

On the first run, a pass looks like `Loaded L"C:\windows\system32\XINPUT1_3.dll"`
under `WINEDEBUG=+loaddll`, and a `hostio: controller … is XInput slot 0` line
followed by the game responding to the pad. A generic fix for titles installed
from the app itself (loading these five names from system32 first) would be a
loader patch and is not done here.

The same host run confirmed that the Steam build needs no Steam client: `steam_api64.dll` and
`bin\ddi\Steam.dll` load, `SteamAPI_Init` fails, both unload, and the game
goes on to play its opening cinematic (screenshots taken with
`gamescopectl screenshot` at 45 s and 3 min: the subtitled intro with a
"Space Skip" prompt).

## 14. One unattended runner for the device steps, and a disk guard

The phone steps below (§17) need about 42 GB of transfer and one ~10 minute
swap of the installed IPA, on a phone the Hollow Knight session uses back to
back. `harness/titles/witcher3-bringup.py` does them without a person:

- It runs push, check, place, hide, put, install, launch and restore in order
  and records each finished step in `$PLAYPORT_BUILD/lanes/w3/logs/bringup/state.json`
  (`logs` is one of the folders `tools/phone-busy` ignores, so the runner's
  own writes never make the phone look busy). A rerun continues from there.
- A hold starts only when `tools/phone-busy --quiet-min M` says idle and a
  non-blocking flock gets `device.lock`: 3 minutes of quiet for the push,
  which gives the phone back within 4 MB once another job queues (§5), and
  10 minutes for the rest. Before check, place, hide, put and install it asks
  `phone-busy --waiters` and gives the phone back if a job is queued.
- install, launch and restore run in one hold, so the other session never
  finds the Witcher 3 IPA installed: `restore` reinstalls the newest IPA in
  `lanes/perf/out` (their builds; `--restore-ipa` overrides), and it also runs
  when install or launch fails. A hold that died after install installs again
  before it launches. Each install closes the app first; `restore` also closes
  the title, which `title-device-run.py` leaves running.
- The launch is §17 step 2's command; its run folder is
  `logs/bringup/launch-<time>/`, and the state records the `title: done`
  line and the first `[jumbo` lines of `s1-host.log`.

`stage-title.py push` now also refuses to fill the phone. It reads
`AmountDataAvailable` once, and before each file it checks that the bytes it
has sent in this run plus that file would still leave `--reserve-gb` (default
8 GB) free. Otherwise it stops and exits 4, and the runner stops too. A full
disk would break the other session's runs as well as this one.

Tested with a stand-in phone (`tools/tests/test_witcher3_bringup.py`, 5
cases: order and resume across processes, a queued job before the swap, a busy
phone left alone, the disk guard, restore after a failed install, re-install
after a hold that died) and `test_title_staging.py` (the reserve stop and its
resumed rerun). `--dry-run` against the real paths printed every command with
the §12 IPA (66bc297c) and `lanes/perf/out/20260925-023907-d0164c01` as the
restore IPA.

Run it in the foreground (a gnhf iteration must not leave it running):

    timeout 3h harness/titles/witcher3-bringup.py --until 07:30

or `--stop-after put` to stage only.

## 15. Every shader the game ships converts offline

A shader that DXMT's converter (airconv) rejects, or trips an LLVM assertion
in (the device build has assertions on), costs a draw or the whole process
only once the title runs. `build/air-helpers/probe/title_shaders.py` now runs
a title's shaders through a Linux build of airconv at the pins, so that class
of failure is found on the workstation (`build/air-helpers/README.md`, "A
title's shaders"). For this title:

    build/air-helpers/probe/title_shaders.py ROOT/host/scan-port \
        $PLAYPORT_BUILD/titles/witcher3-292030-3280809 OUT \
        --match 'shader|\.fx11obj$' --llvm ROOT/llvm15/bin

| Kind | Unique shaders | Converted | AIR verified |
| --- | ---: | ---: | ---: |
| vertex | 6,550 | 6,550 | 6,550 |
| pixel | 1,718 | 1,718 | 1,718 |
| compute | 43 | 43 | 43 |
| geometry (both mesh halves) | 6 | 6 | — |
| hull (with a vertex shader) | 7 | 7 | — |
| domain (with a hull shader) | 67 | 67 | — |

8,391 unique containers from 46 files (`content0`'s three shader caches,
the `shader.cache` of `content1`–`5` and `8`–`12`, DLC2's
`furshader.cache` and 32 SpeedTree `.fx11obj` files), exit 0, about 8 s. airconv
is the dxmt pin plus `patches/dxmt-port` and `patches/dxmt` (the
`lanes/profile-seed` tree, `339017f`), built against the cached LLVM 15.0.7
with assertions on; the verifier is LLVM 15's `opt -verify` on each
standalone module, and a module with a use before its definition fails it.

What this does not cover:

- `content/patch1/shader.cache` and the other DLC caches hold no plain DXBC
  (compressed); patch 1.32's replacement shaders are among them.
- The real pairings of geometry, hull and domain shaders with their first
  stage, and each shader's real input layout and pixel-output state: a
  paired shader passes when it converts with any shader of the title.
- The device's Metal compiler, which turns this AIR into GPU code.
- The four geometry shaders the game creates with stream output (§1). They
  are geometry-shader bytecode, and DXMT emulates stream output only for
  vertex-shader bytecode with no rasterized stream, so they are created as
  plain geometry shaders (`CreateGeometryShaderWithStreamOutput: not
  supported, expect problem` in the log) and their stream output is lost.
  Their bodies convert above. What that costs on screen needs the phone.

The `host` stage's file list predated the DXMT rebase and no longer linked
(airconv now also has `dxbc_binding_rootsig`, `dxbc_binding_sm50` and
`simdgroup_implicit_membarrier`); it has them now, and it also builds
`scan-port`.

## 16. Staged on the phone, first launch, and the 8 GB ask (madeira-unix 0017)

**Staging (done).** `witcher3-bringup.py --stop-after put --push-budget-s 600`
started at 03:08, when the Hollow Knight session's last run folder had been
quiet for 3.5 minutes and the lock was free. The phone is on netmuxd Wi-Fi;
the push ran at about 77 MB/s (small files much slower: `content0/scripts`
is about 900 files in 30 s). At 03:16:56 it gave the phone back on its own:
that session's next `flock … perf-run.py --out lanes/perf/g720` had queued
on the lock (`phone-busy --waiters`), and the push stopped with 40.1 GB sent
in 521 s and 11 files left, part-way through `content/patch1/sounds.cache`.
That run then went ahead. After it the runner waited the 3 quiet minutes and
at 03:24 sent the last 1.46 GB (29 s; `resumed content/patch1/sounds.cache
at 662700032 of 1110520102 B`). `check` read back 9.3 GB (2,356 files and
the resumed file) with 0 bad and 0 unlisted of 2,459; `place`, `hide`
(`bin/x64/xinput1_3.dll.playport-hidden`) and `put` (the §10 settings)
followed. The phone reported 42.95 GB free before the last slice and
41.47 GB after it. The title is at `Documents/prefix/drive_c/Games/The
Witcher 3` in the app's container, where in-place installs leave it.

**Launch 1 (IPA 66bc297c, §12).** At 03:31 (10 quiet minutes) the runner
installed the Witcher 3 IPA, launched, and put the other session's IPA back.
`title: done exit=0xc0000005 after_s=0`. The log
(`lanes/w3/logs/bringup/launch-20260925-033142/pull/s1-host.log`, from the
line `[jumbo-hold] ceiling`) shows the §8 layout as predicted, then the part
§8 got wrong:

    [jumbo-hold] ml996 HELD 0x7400000000 +32768 MB PROT_NONE (no-overwrite) ...
    [jumbo] kernel-pick reserve failed (0xc0000017) for size=0x200000000 — top window is full
    [jumbo-hold] ml996 releasing the holdback 0x7400000000 +32768 MB for a 8192 MB request
    [jumbo-hold] ml997 mapped at the holdback -> 0x7400000000 size=0x200000000 st=0x0
    [jumbo] kernel-pick reserve failed (0xc0000017) for size=0x800000000 — top window is full
    [va-gaps] FREE 0x7038004000..0x71f4ef0000 = 7118 MB
    [va-gaps] FREE 0x7600000000..0x7c00000000 = 24576 MB
    [window]   run#0 0x7200000000 +0x1ffff0000 (8191 MB) prot=0 tag=0

then the 1.6 GB reserve at 0x7038010000 and a SEGV writing to address 0.
§8 expected the 8 GB ask to land in FEX's band; that band is now
`[fex-arena] ml799 RESERVED … registered FEX_ONLY -- generic placement cannot
allocate here`, so the kernel pick fails for the 8 GB too. The ml997 branch
then hands the jumbo hold to the first large ask that fits it, whatever its
size, and the 8 GB took the 32 GB hold. Madeira's ml433 cage holdback,
`0x7200000000 +0x1ffff0000`, exists for exactly one 8 GB ask, but it is
tried only in the hinted-retry branch, which an unhinted ask never reaches;
it sat unused.

**0017.** `patches/madeira-unix/0017`: when a jumbo hold exists, an
exactly-8 GB ask in the kernel-pick branch takes the cage stretch first.
It maps the full 8 GB at 0x7200000000 when the 64 KB above the cage is free
(it is: the jumbo hold starts at 0x7400000000), or else the 64 KB-short view
with an `ios_soft` tail, as ml433 does. Its log line is `[cage] 8 GB ask
served before the jumbo holdback -> 0x7200000000 size=0x200000000 st=0x0`.
Without `jumbo-mb` nothing changes. Expected layout: 8 GB at 0x7200000000,
the 32 GB at the hold (0x7400000000), and the 1.6 GB, 2 GB, 300 MB and the
smaller asks (about 4.8 GB in all, §6) in the 7 GB hole at 0x7038….
That hole also takes DLL images and thread stacks, so it is the next thing
to run out if anything does.

Built in the w3 lane (§9 recipe: `git am -3` of 0017 into `run/unix/mythic`
with `mythic/wine` briefly a plain directory, then `unix-side-gaps.sh ROOT
gnutls-config linktest`, which links as before): `libntdll_unix.a`
`1bb9d77e…`, 1,782,056 B, the only committed `artifacts.tsv` change. IPA
`$PLAYPORT_BUILD/lanes/w3/out/20260925-033844-3b14f1cb/Playport-26.5-3b14f1cb.ipa`,
sha256 `3b14f1cb52cb240c193d8c73214e92dfa41bbc1635bb21586a5f6eb86c288da0`,
`verify-ipa` 60 checks passed; its own record is
`lanes/w3/artifacts-ipa-3b14f1cb.tsv`.

**Runner fixes from this run.**

- The restore hung for 3 minutes. `close_app` took the last line of
  `dvt process-id-for-bundle-id` as the pid, but that is pymobiledevice3's
  "Trying again over a no-root userspace tunnel" warning, so the app (pid
  3574, left in front by the title) was never killed and the install waited
  behind it. A manual `dvt kill 3574` let it finish at 03:35:10. The pid is
  now the output line that is only a number (`running_pid`, tested with that
  warning).
- The restore IPA was wrong. The default was the newest IPA in
  `lanes/perf/out` (d0164c01, 02:39), but that session had since installed
  `fbdb311e` directly from its worktree's `app/xtool/S1Probe.ipa`, keeping a
  copy in `lanes/perf/ipa` (its `hk-vpad-gameplay` record names both). The
  device's app list cannot tell builds apart (CFBundleVersion is always
  1). The default is now the newest IPA under `lanes/perf` (not `run/`) or in
  another worktree's `app/xtool`, chosen when the restore runs rather than
  when the runner starts. This run's restore was fbdb311e, the right one.
- `--again` runs install, launch and restore once more (a new IPA);
  `--push-budget-s` ends each push slice so `--until` is checked between
  slices.
- The launch now gives the phone back too. That session's gaps between runs
  were 4 to 8 minutes from 03:40 to 04:05, so a 10-minute quiet window did
  not come, and a launch that cannot yield would make its next run wait for
  the whole title wait. `title-device-run.py` now runs in its own process
  group, and `phone-busy --waiters` is polled every 10 s; on a waiter the
  runner stops it, pulls `s1-host.log`, restores, and on the next hold
  installs and launches again. With that the launch uses the push's 3-minute
  quiet window (`--launch-quiet-min 3`). Tests: a launch cut short (restore
  runs in the same hold, the state keeps no swap step, the next hold swaps
  and launches again) and `run_yielding` against a real `sh` child.

**Launch 2 (IPA 3b14f1cb, with 0017), 04:11.** The address-space wall is
passed. From `launch-20260925-041113/pull/s1-host.log`:

    [jumbo] kernel-pick reserve failed (0xc0000017) for size=0x200000000 — top window is full
    [cage] 8 GB ask served before the jumbo holdback -> 0x7200000000 size=0x200000000 st=0x0
    [jumbo] kernel-pick reserve failed (0xc0000017) for size=0x800000000 — top window is full
    [jumbo-hold] ml996 releasing the holdback 0x7400000000 +32768 MB for a 32768 MB request
    [jumbo-hold] ml997 mapped at the holdback -> 0x7400000000 size=0x800000000 st=0x0

and the game commits its 1.6 GB at 0x7400000000, inside the 32 GB. It then
starts three worker threads, loads DXMT (`[iOS DXMT]
supportsBCTextureCompression = YES`, no `dxmt.conf`) and dies in the D3D11
device's first compute pipeline: `objc_msgSend` reads the wild pointer
`0x600000003d083b6a` inside `_MTLDevice_newComputePipelineState` (winemetal
unix call 29, `MTLDevice_newComputePipelineState` in
`src/winemetal/winemetal_thunks.c`), the thunk's
`assert(!status && "unix call failed")` at line 332 fires, and the CRT's
abort ends the process with `NtTerminateProcess(exit_code=0x3)`:
`title: done exit=0x00000003 after_s=0`. The guest call chain is in the
image mapped at `0x149550000`. Hollow Knight creates D3D11 devices through
the same DXMT and winemetal (the other session's lane links the same
`profile-seed` trees), so the bad handle most likely comes from something
this title does differently: the `WMTComputePipelineInfo` it passes, or the
function handle in it, for example a compute shader of the title's own
rather than one of DXMT's. That is the next thing to find.

The runner's restore then failed on a second bug of this iteration's own:
`close_app` passed the pid as an int in the command list. The Witcher 3
IPA stayed installed with the title's app in front for about a minute,
until the other session installed its own new build (`07d00cd1`) at 04:12;
a manual `dvt kill` of the app let that install finish. The pid is now a
string, and the state records the restore as done by that install.

## 17. Device creation: an uninitialized device handle (dxmt 0006), then the CRT mix

Three launches through the runner (`--again`), each inside a quiet gap of the
Hollow Knight session and each followed by a restore of that session's IPA.
Logs are under `$PLAYPORT_BUILD/lanes/w3/logs/bringup/launch-<time>/`.

**Where the bad handle was.** In launch 2's crash, `objc_msgSend` faults at
`_MTLDevice_newComputePipelineState+0x1b0`. Disassembled
(`llvm-objdump` of `obj/winemetal_unix.o`), that return address follows the
final `newComputePipelineStateWithDescriptor:` send, whose receiver is
`params->device`, so the wild value is the MTLDevice handle, not the
function. The guest call chain starts at `witcher3.exe+0x66c7`, a
feature-level probe: `CreateDXGIFactory` (the v0 IID
`7b7166ec-21c7-44ae-b21a-c9ae321ae369`), `EnumAdapters(0)`, then
`D3D11CreateDevice(adapter, UNKNOWN, 0, 0, NULL, 0, 7, NULL, &fl, NULL)`.
The wild value differs between launches (`0x600000003d083b6a`,
`0x6339080000000111`, `0x60a3a0ef80000`), so it is uninitialized memory,
not a fixed bad address.

**Launch 3 (04:28, IPA 3b14f1cb, `--pool-mb 896`).** Driven launches had
used the app's 384 MiB default pool (`LadderMode.defaultPoolMB`); every Hollow
Knight run and library Play use 896 MiB, and with 384 MiB the pool's RW alias
lands at `0x131000000`, below the shared cache, instead of at
`0x7000000000`. The runner now passes `--pool-mb 896` (`POOL_MB`,
`--pool-mb` to change it). Same crash with a new wild value, so the pool was
not the cause.

**Launch 4 (04:37, a trace build, IPA 8a09dee5, not kept).** A lane-only
DXMT build that logs the handle and its stack slot at each step of device
creation (`[dev-trace]`): the handle `0x15ad70fd0` is right from
`D3D11CoreCreateDevice` through the device, the command queue, the
source-compiled command library and all 13 `EmulatedCommandContext`
pipelines, and the crash comes after them. The next compute pipelines are
ClearUAV's. Its constructor builds ten through
`SimpleCommandContext<ArgumentEncodingContext>::getComputePipeline`, which
calls `ctx.device_.newComputePipelineState`. `ArgumentEncodingContext`
declares `device_` (and `queue_`) last, after `clear_uav_cmd`, and members
are initialized in declaration order: `device_` is read before it is set.
This is in DXMT at the pin (`src/dxmt/dxmt_context.hpp`), not in the port.
Where that heap memory happens to be zero the sends go to nil, succeed, and
every ClearUAV pipeline is silently nil, which is probably what Hollow Knight
gets. Witcher 3 has used and freed a lot of heap by then, so it gets garbage.

**0006.** `patches/dxmt/0006`: the two members are declared before the command
contexts and initialized first. Only the PE side changes (no winemetal
slot), so `libdxmt_combined.a` is unchanged. Built in the w3 lane: a reflink
copy of `profile-seed/run/dxmt-patched` at the four-patch series, `git am`
of 0006, `build-dxmt-patched.sh ROOT pe` (18 s), then `build-from-pins
--from stage`. IPA
`$PLAYPORT_BUILD/lanes/w3/out/20260925-044159-1146d420/Playport-26.5-1146d420.ipa`,
sha256 `1146d420a32ca59475548a2cc49f87be743b1320db283fb9fd274f5cca5d4bf2`,
`verify-ipa` 60 checks passed; its record is `lanes/w3/artifacts-ipa-1146d420.tsv`.

**Launch 5 (04:42, IPA 1146d420).** Device creation passes and the probe
returns. The game then runs for 11 s and exits `0xc0000005`. It loads
`bin\ddi\Steam.dll`, which imports `MSVCP110` and `MSVCR110`. `MSVCP110` is
the app's arm64ec Wine build from system32 (the game ships none), but
`MSVCR110` is already loaded from `bin\x64`: Microsoft's x64 CRT, which
`GFSDK_SSAO.win64.dll` pulled in earlier. That arm64ec `msvcp110` then
jumps to its own image base: `pc` is `msvcp110.dll+0x0` (it executes
`MZ`, `insn=0x00785a4d`), from the return address `+0x7b0f0`, just after a
`bl #memcpy` into msvcr110 in `_Yarn_char_op_assign_cstr`. After the handled
fault the game creates a second D3D11 device, then dies in `dbghelp.dll` on a
pointer made of text (`0x3a315f5f3a3a6474`, "td::__1:"). Host Wine does not
hit this because its builtin `msvcp110` is x86-64 like the game's CRT. The
app already ships an arm64ec `msvcr110.dll` for this title (EXTRA_PE), so
the fix needs no rebuild: hide the game's copy as §13 hides its
`xinput1_3.dll`. `stage-title.py hide` now takes several files, and the
runner's `hide` step hides both (`HIDE`); `--again` reruns `hide`, which is a
no-op for a file already hidden.

**Launch 6 (05:23, IPA 1146d420, `msvcr110.dll` hidden).** The runner's
`hide` step renamed `bin/x64/msvcr110.dll` (and found `xinput1_3.dll` already
hidden). `MSVCR110.dll` now loads with a different module hash
(`msvcr110.dll-8c1bb77998ded878`, the app's arm64ec build), and the game
goes past launch 5's crash: both D3D11 devices, `Steam.dll`, `MSVCP110.dll`
and `steam_api64.dll` load, eight threads run, and the game reads
`bin\x64\commandline.txt`, `Documents\The Witcher 3\gamesaves\` (it
exists) and `bin\config\`, with no fault. The run was cut short 13 s in,
when the Hollow Knight session queued its next run; the runner gave the phone
back and put that session's IPA back (`lanes/perf/ipa/qos1.ipa`).

**Launch 7 (05:32, same IPA).** With `msvcr110.dll` hidden the `msvcp110`
fault is gone. The game dies 6 s in, in the second fault of launch 5:
`dbghelp.dll+0x1eb6c`, which is `dwarf2_fill_attr` (Wine's arm64ec
`dbghelp.dll`, disassembled), reading a pointer made of text. Just before, the
log is full of `fixme:dbghelp_dwarf:... in ctx(...,L"d3d11")`: the game loads
module symbols at start-up, and Wine's DWARF reader crashes on DXMT's
`d3d11.dll`, a meson debug build whose DWARF 4 (`llvm-dwarfdump`) is about
31 MB of libc++-heavy C++.

## 18. Two more fixes, and the game renders

**DXMT without DWARF.** `build/build-dxmt-patched.sh` `pe` now copies the four
DXMT DLLs out of the meson trees with `llvm-strip --strip-debug`: the same
code, without the `.debug_*` sections (arm64ec `d3d11.dll` 36.1 MB to
10.4 MB). Wine's `dbghelp` also reads `DBGHELP_DWARF_VERSION` (2 to 4; a unit
of a newer version is skipped), which would skip every DWARF 4 unit of every
module, but only for a driven launch, since the app sets no per-title
environment. IPA e3735fa6 (not kept).

**Launch 8 (05:41, IPA e3735fa6).** Past `dbghelp` (it goes on to look for
`E:\R4.Vanilla\bin\x64\witcher3.pdb`). Three D3D11 devices, the first
shaders (DXMT logs `CreateGeometryShaderWithStreamOutput: not supported`
seven times, the stream-output geometry shaders of §15), and at 16 s:

    wine: Call from 000000011C6B5680 to unimplemented function XINPUT1_3.dll.2, aborting

`witcher3.exe` imports `XINPUT1_3.dll` by ordinal only: 2 (`XInputGetState`)
and 3 (`XInputSetState`). The app's own `xinput1_3.dll`
(`build/build-xinput.py`) listed its exports without ordinals except
`XInputGetStateEx @100 NONAME`, and the linker then numbered all of them from
100 (`objdump -p`: "Ordinal Base 100"), so ordinals 2 and 3 did not exist. The
game's crash handler then read all 31 threads' contexts and exited with
`0x80000100`. `build-xinput.py` now gives `xinput1_3` and `xinput1_4` the
ordinals of Wine's specs, which are Microsoft's (2 `XInputGetState` to 8
`XInputGetKeystroke`, 10 `XInputGetAudioDeviceIds` in 1_4, 100
`XInputGetStateEx`). Both builds are byte-identical, `--test` passes under
host Wine, and the two `P6-xinput` rows of `app/artifacts.tsv` change. This
applies to any title that imports XInput by ordinal, not only this one.

**IPA 6b59256d** (0006, stripped DXMT, the new XInput DLLs):
`$PLAYPORT_BUILD/lanes/w3/out/20260925-054542-6b59256d/Playport-26.5-6b59256d.ipa`,
sha256 `6b59256ddb9f2ce9028464cae62466cf3e9487c6679011acf7437cf516bce213`,
`verify-ipa` 60 checks passed; its record is `lanes/w3/artifacts-ipa-6b59256d.tsv`.
The lane's `run/xinput` is now its own directory (it was a link to the shared
`run/xinput`, which the other lanes use).

**Launches 9 to 11 (05:56, 06:12, 06:16).** The game no longer exits. Each
run went on until the Hollow Knight session queued its next run and the runner
gave the phone back: 263 s, 107 s and 16 s. Launch 9 presented 7,408 frames
in 247 s, from 4 s after device creation: 30.0 fps, the cap in the §10
settings file, with 112 to 144 draws per frame and no exception besides
`OutputDebugString` (`0x40010006`, `0x4001000a`). The log does not show what
is on screen (the intro, the menu or a loading screen); a screenshot or a
longer run is needed for that.

## 19. In the game: Kaer Morhen at 30 fps with a pad (launch 12)

**Scripted pad and screenshots.** The Hollow Knight session's branch added a
scripted game controller (`HIO_VPAD`, `harness/device/vpad.py`, its commit
b565aa4). The same change is now on this branch (the app's `VirtualPad`, its
HostIOKit tests and `vpad.py`; not its Hollow Knight scripts or evidence), and
`witcher3-bringup.py` gained `--shot S` (a `dvt screenshot` S seconds into the
launch) and `--vpad S:SCRIPT` (push a script then; the launch gets
`HIO_VPAD=vpad.txt`). `harness/titles/witcher3-vpad/` holds two scripts: A
presses to skip the opening cinematic, and A presses through the new-game
prompts.

**IPA 23584060** (6b59256d plus the pad):
`$PLAYPORT_BUILD/lanes/w3/out/20260925-062736-23584060/Playport-26.5-23584060.ipa`,
sha256 `235840602b70ed2d09e4d2f5a2692f79f6807eaa47c2fab4d8c5ae442c021322`,
`verify-ipa` 60 checks passed; its record is `lanes/w3/artifacts-ipa-23584060.tsv`.

**Launch 12 (07:23, 300 s, not cut short).** `--launch-quiet-min 2`, shots at
25 to 260 s, `skip.txt` at 105 s and `new-game.txt` at 165 s. The pad did not
start at rest: `Documents/vpad.txt` still held a looping 12-step script (d-pad
left and right, A, X) from a Hollow Knight run, and `VirtualPad` plays whatever
the file holds from its first frame. That script's presses took the game through
its screens by themselves:

| time | on screen (`docs/evidence/2026-09-25-witcher3-setup/`) |
|---|---|
| 25 s | the legal screen with an Xbox `X Skip` prompt, so the game sees the XInput pad (`launch12-shot-0025s.jpg`) |
| 50 s | black, `X Skip`: the skipped cinematic and loading |
| 75 s | **gameplay**: Geralt in Kaer Morhen (the prologue dream), the tutorial's Camera box, quest text, minimap, pad button prompts; HUD 29.2 fps, GPU 14.7 ms (`launch12-shot-0075s.jpg`) |
| 125 to 260 s | same room, the camera moved; HUD 29.9 to 30.0 fps, frame interval 33.3 ms, GPU 34.6 to 34.8 ms, app memory 6.15 GB, Metal 826 MB (`launch12-shot-0260s.jpg`) |

The run presented 8,672 frames in about 294 s (29.5 fps with the loading
screens; the 30 fps cap in gameplay), about 1,270 draws per frame in the game,
and no exception. The app's resident memory settled at 6.15 GB with 2.4 GB
still available. Two limits show: the GPU time (34.7 ms at 1564x720) is at
the 33.3 ms the cap allows, so the GPU would limit an uncapped run; and the
guest reads `KUSER_SHARED_DATA` (0x7ffe0320, the tick count) through Madeira's
subfloor handler (`[subfloor] ml956 serviced 32769 access(es)`, one mach
exception each), about 16 per frame.

The runner now writes a rest script to `Documents/vpad.txt` at the start of
any launch with `--vpad`, so a leftover file cannot drive the game. The 125 s
shot is not kept: it carries a personal notification banner.

## 20. Library Play on the phone, and the hand-over (07:34)

At 07:32 the Hollow Knight session had ended: its gnhf process was gone,
`lanes/perf` had last changed at 07:20, `tools/phone-busy --quiet-min 10`
said idle and no job was queued on `device.lock`. In one hold
(`flock -n device.lock`, script and logs in `lanes/w3/logs/handoff/`) the
Witcher 3 IPA 23584060 (sha256 `235840602b70…c021322`, §19) was installed
and the title started through the product UI, the path a player's Play takes:
`harness/device/ui-device-run.py --play app-292030 --title-wait 240`
(`S1_MODE=ui`, `UI_ACTIONS=play:app-292030`; only the JIT attach comes from
the workstation). No `HIO_VPAD`, no `TITLE_CFG`, no `HOST_SCREEN`: everything
came from the library entry.

| `s1-host.log` | what it shows |
|---|---|
| `library: adopted 2 title(s): Hollow Knight [Ready], The Witcher 3: Wild Hunt [Ready]` | the staged folder is adopted from `titles.json` |
| `library: play … Games\The Witcher 3\bin\x64\witcher3.exe` | the nested executable resolves (working directory `bin\x64`) |
| `title: config: MADEIRA_DOCS_DIR=…/title-cfg/The Witcher 3 with jumbo-mb = 32768` | the per-title key, without touching the shared madeira.cfg |
| `title: display: screen 1564x720 (the title's screen 720)` | the entry's `screen` |
| `JIT pool rx=0x119000000 rw=0x7000000000 size=0x38000000`, `pool 896 MiB` | the in-app launch's pool size |
| `[jumbo-hold] ceiling 0x8000000000 capped at 0x7c00000000`, `HELD 0x7400000000 +32768 MB` | 0016 on the library path |

The game played its opening cinematic at 29.99 fps (frame interval 33.35 ms,
app memory 4.06 GB) for the whole 240 s wait, then the app was closed
(`dvt kill`). With no controller connected the skip prompt reads `Space Skip`
(`libraryplay-shot-0060s.jpg`); launch 12's pad made it `X Skip`. So a player
needs a Bluetooth controller (or keyboard): the game has no touch input.

**Left on the phone:** the Witcher 3 IPA 23584060, not closed over by any
other build (provisioning valid to 2026-10-02); the app closed; the staged
game with its two hidden DLLs and the low settings file; and launch 12's
checkpoint `gamesaves\CheckPoint_53db8_7ea46000_158b2d4.sav` (07:24, Kaer
Morhen), so Continue in the main menu should resume the prologue.

## 21. The player's path: library Play with the built-in JIT helper (07:41–07:55)

§20's Play still took its JIT from the workstation's debugger (`S1_MODE`
launches do). A player's Home Screen Play uses the app's own helper extension
instead. `ui-device-run.py` gained `--jit builtIn` (`S1_JIT=builtIn`, as
`title-device-run.py --jit` has): the product UI's Play with the built-in
helper and no activation tool. The phone was idle (`tools/phone-busy` idle,
no waiters; the Hollow Knight session gone), the pairing file was in
`Documents/StikJIT/pairingFile.plist`, and IPA 23584060 was still installed.
Each run was one `flock -n device.lock` hold that closed the app at the end
(`lanes/w3/logs/builtinjit/run.sh`).

| run | readiness vs Play | result |
|---|---|---|
| 1 (07:41, pid 4568) | the readiness check (helper 4569) replied `ready, TXM present` just after `jit: asking the built-in helper to attach` | **app crashed** 2 s after launch (`S1Probe-2026-09-25-074139.ips`); no enable helper started, the Home Screen stayed in front, no `title: done` line |
| 2 (07:52, pid 4633) | the same overlap | enable helper 4635 attached, blessed the 896 MiB pool at 0x119000000, detached; `acquire(896 MiB) via builtIn -> 0 after 3.24 s`; `wine_host_run_exe -> 0`; `title: done … running after_s=180`, 5,280 presents (144 draws each, the intro) |

Run 2 is the whole player path with nothing from the workstation but the
launch: catalogue, per-title `jumbo-mb`, the 720-row screen, built-in JIT and
the game running for 180 s.

**Run 1's crash.** `EXC_BAD_ACCESS` (`KERN_INVALID_ADDRESS` 0x2f6e6250b20) on
the `playport.builtin-jit` queue:

```text
objc_release < _Block_object_dispose < … < _Block_release
  < -[_NSXPCDistantObject dealloc] < -[EXExtensionContextImplementation invalidate]
  < -[EXExtensionContextImplementation dealloc] < AutoreleasePoolPage::releaseUntil
  < objc_autoreleasePoolPop < _dispatch_last_resort_autorelease_pool_pop < _dispatch_lane_invoke
```

The readiness helper had replied and `withHelper` had ended it (`stop()`:
connection invalidated, `_kill:` SIGKILL, listener invalidated). The queue's
autorelease pool then released the extension's context, whose XPC proxy
released a block holding an object that was already freed. The other
thread was `JitProvider.requestBuiltIn` logging its wait. None of the phone's
seven older S1Probe crash reports has this stack. So this is a race in ending a helper, seen once in two
launches where Play came while the readiness check was still running. A
player who opens the app and taps Play at once can meet it: the check runs
when the tabs appear and takes about 2 s once the DDI is mounted (longer
after a reboot). A likely fix is to drain the helper call's autoreleased
objects in an `autoreleasepool` before `stop()`, so the framework does the
context's last release itself; it was not built, because a JIT change needs
its own device runs and the installed IPA works.

## 22. Next, in order

1. Play it by hand: connect a Bluetooth controller, open Playport from the
   Home Screen, Library, The Witcher 3, Play (JIT from the built-in helper,
   `docs/DEVICE.md` "JIT without the workstation"). Wait until Settings' JIT
   section shows `ready (TXM present)` (a few seconds) before Play, which
   avoids §21's crash; if the app closes right after Play, open it and Play
   again. Skip the cinematic with X, then Continue.
2. If the frame rate drops outdoors (White Orchard), lower the entry's
   `screen` (for example `600`): the GPU is already at the 30 fps budget indoors.
3. If another session installs its own IPA again, reinstall 23584060 (or a
   build carrying 0016, 0017, dxmt 0006, the stripped DXMT DLLs and the XInput
   ordinals) before playing: the Hollow Knight builds have none of them.
4. Fix §21's helper-teardown race (an `autoreleasepool` around the helper
   call in `BuiltInJit.withHelper`, before `stop()`) and check it with
   repeated `ui-device-run.py --play app-292030 --jit builtIn` launches.
