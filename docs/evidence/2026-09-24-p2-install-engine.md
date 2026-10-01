# Whole-title install engine: host and device acceptance

*The raw logs, tables and screenshots this record names were removed in the 2026-09-25 repository cleanup; they remain in git history.*

**Date:** 2026-09-24. **Tree:** the commit that adds this record (the install
engine is in `12017cd`; this commit optimises `SteamClientKit` in the app build
and logs the free-space pre-flight).
**Result:** `install 4020 --anonymous` (Garry's Mod Dedicated Server, depots
4021 and 4022, 6.90 GB, 2,355 files) completes with every file SHA-1-verified
on the Linux host at 59 MB/s (8 in flight) and 88 MB/s (16 in flight), and on
the phone at 14 to 15 MB/s. On the phone, an install killed mid-download
resumes with its journalled chunks re-hashed, the free-space pre-flight pauses
the job with a clear message, and verify finds and repair replaces a corrupted
and a truncated file. The serial sample installer this replaces ran at about
4 MB/s.

## 1. What ran

| | |
| --- | --- |
| Host | Linux workstation, `steamclient` built with `swift build -c release --build-system native` |
| Phone | iPhone18,4, iOS 27.0 (24A437), on Wi-Fi through netmuxd, screen locked, nobody at the phone |
| IPA | `Playport-26.5-08a126b5.ipa`, 655,577,517 bytes, sha256 `08a126b5a9c30f7153d2754183d16d19de41e170c6acacbb0f8e1cc33faca8a1`, upgraded in place |
| Title | app 4020, build 25375525, installdir `GarrysModDS`; depot 4021 gid 8155787835635873263 (6,653,060,875 bytes), depot 4022 gid 8703068137532896137 (243,438,208 bytes) |
| Session | anonymous CM logon; no account |

Depot selection kept 4021 and 4022, skipped 4023 (Linux) and skipped 1004 to
1006 (`depotfromapp` 1007 redistributables). The plan overlays the two
manifests into 2,355 files, 175 directories and 8,990 chunks, 8,884 of them
unique.

Every device run is one `harness/device/steam-device-run.py` launch
(`S1_MODE=steam`). The phone was never unlocked or touched: the app runs its
Steam mode while the screen is locked.

## 2. Host

Logs: `host/`.

| Run | In flight | Result |
| --- | --- | --- |
| `r1-resume-c8.log` | 8 | Resumed a stage stopped by `--cancel-after-chunks 300`: 1 journalled chunk re-hashed, 98 files already verified. 2,257 files verified in this run, 111.2 s, **59.4 MB/s**. Committed with one rename. |
| `r2-fresh-c16.log` | 16 | Fresh stage: 2,355 files verified, 8,884 chunks downloaded, 106 deduplicated, 78.0 s, **87.8 MB/s**. |

`swift test --build-system native` in `app/SteamClient`: 50 tests, 0 failures
(plan overlay, depot selection, journal replay after an interrupted run, and
truncated or corrupted staged files among them).

## 3. Phone

Transcripts (redacted, leak-checked): `device/`.
Runs 1 and 2 were stopped by killing the app, so they have no driver
transcript; their files are the app's own `steam-drive.log` lines.

### 3.1 The debug build was CPU-bound

`1-debug-build.txt`:
the first device run downloaded at **0.2 MB/s**. Each chunk request finished
in 100 to 200 ms, but the app sat at 530% CPU between them. xtool builds the
app in its default debug configuration, so `SteamClientKit`'s pure-Swift AES,
LZMA and SHA-1 ran at `-Onone`. `app/SteamClient/Package.swift` now compiles
`SteamClientKit` with `-O` in every configuration. The same stage then ran at
17 MB/s.

### 3.2 Install, kill, resume

- `2-optimised-killed.txt`:
  the optimised build resumed run 1's stage (59 chunk and 31 file records) and
  ran at 16 to 17 MB/s. The app was killed with `dvt kill` at 37.5%
  (4,019 of 8,825 chunks).
- `3-resume.txt`: the
  same command again. It replayed 4,177 chunk and 1,705 file records,
  **re-hashed 193 journalled chunks of unfinished files (0 rejected)**, and
  fetched the remaining 4,798 chunks: 282.7 s, **15.2 MB/s**, peak RSS
  119 MiB. All 2,355 files are SHA-1-verified; the tree was committed with one
  rename into `Documents/prefix/drive_c/Games/GarrysModDS`, next to the staged
  `Games/Hollow Knight`, which was not touched.
- `4-fresh-root.txt`:
  an uninterrupted install into a stand-in root (`--root Library/p2-spacetest`):
  8,884 chunks, 478.7 s, **14.3 MB/s**, all files verified. This run was meant
  to trigger the space pause with `--reserve-bytes 80000000000`, and did not:
  see 3.3.

### 3.3 Free-space pre-flight

`volumeAvailableCapacityForImportantUsage` reported 137.8 GB while lockdown's
`AmountDataAvailable` reported 76.8 GB: the "important usage" figure counts
space the system can purge. An 80 GB reserve therefore did not trip the
check. The engine now logs both sides of the pre-flight.

- `5-space-preflight.txt`:
  a fresh stage with a 10 TB reserve stops before the first chunk:
  `install: paused: not enough space: needs 10007.24 GB, 137.77 GB free; paused, staged work kept`.
- `6-partial-stage.txt`
  then `7-space-resume.txt`:
  a stage stopped after 300 chunks, resumed with the reserve set about 1 GB
  above the free space. It replays the journal (1 chunk re-hashed, 98 files
  verified) and pauses: `needs 138.50 GB, 137.36 GB free; paused, staged work kept`.

### 3.4 Verify and repair

On the committed install, `srcds.exe` had 16 bytes overwritten at offset 4096
(same size) and `bin/engine.dll` was truncated to half its size, both through
AFC.

- `8-verify-corrupt.txt`:
  `verify 4020` re-hashes 2,355 files (6.90 GB) in 8.3 s with no network and
  reports exactly those two as BAD.
- `9-repair.txt`:
  `verify 4020 --repair --anonymous` downloads their 6 chunks into a side
  stage, verifies them and renames each over the broken copy:
  `repair: 2 of 2 files replaced and re-verified; 0 still bad`.
- `10-verify-clean.txt`:
  `verify 4020` finds 0 bad files. The repaired files pulled back have the
  SHA-1 of the originals (`ed8f4959…` and `3f84fdd0…`).

## 4. Cleanup

After the runs the test install (`Games/GarrysModDS`), its install record and
its two retained manifests, and the stand-in root were deleted from the
container through AFC. `Games/Hollow Knight` is unchanged. The app was left
installed at this IPA.
