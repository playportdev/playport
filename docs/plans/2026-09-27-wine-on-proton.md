# Plan: Wine from Valve's Proton branch

**Date:** 2026-09-27. **Kind:** plan, carried out on 2026-09-28: step 0
chose B, so the base stays WineHQ and Valve's wanted commits are
`patches/wine-valve` ([decision 0018](../decisions/0018-valve-wine-as-a-series.md),
[evidence](../evidence/2026-09-28-wine-proton-rebase.md)). **Pins read:** `wine`
7b3fff7 (wine-11.18), `wine-port` 723d1bf, `madeira` 8c050d0, as in `pins.lock`;
ValveSoftware/wine `proton_11.0` at dc26e61 (2026-08-03).

## Goal

Build Wine from ValveSoftware/wine `proton_11.0`, the Wine that Proton 11 ships
and that Valve tests on ARM64 (Steam Frame), instead of from a WineHQ
development release. We would get Valve's game fixes and its ARM64EC and FEX
work: cooperative suspend, FEX's WoW64 and ARM64EC DLL names, AVX and SVE state
for ARM64EC, and per-game hacks. The rest of the stack stays as it is: DXMT, the
Vulkan backend, FEX and our unix side.

This plan replaces [0013](../decisions/0013-wine-on-upstream.md)'s "the base is the
latest development release", so it needs a new decision record (step 6).

## What the move is

| | Now | After |
| --- | --- | --- |
| `wine` pin | WineHQ wine-11.18 | ValveSoftware/wine `proton_11.0` commit |
| Base Wine version | 11.18 (development) | **11.0** (stable) plus 1453 Valve commits |
| `patches/wine-port` | Madeira's fork (56 commits from wine-11.4) plus follow-ups, 65 patches | the same, rebased again |
| `madeira-port` patches at the end of `patches/madeira-unix` | the `*_ios.c` replacements, ported from 11.4 **up** to 11.18 | ported **down** to 11.0, plus Valve's changes to the files they replace |

**Every Valve branch is based on Wine 11.0:** `proton_11.0`, `experimental_11.0`
and `bleeding-edge` all have `VERSION` 11.0. The move therefore goes back 18
development releases from our base, and 4 releases below the Wine that
Madeira's fork was written against. The 0013 rebase showed what that costs:
upstream moved per-thread state into `struct thread_data`, the main image into
`main_module`, image mapping onto `pe_mapping_info`, and the arm64 server
context into split blocks. The replacements have to be ported back across all
of that.

Valve's 1453 commits land in the places we replace wholesale:

| Directory | Valve commits |
| --- | --- |
| `dlls/ntdll` (of which `unix/`) | 197 (147) |
| `dlls/win32u` | 135 |
| `dlls/winegstreamer` | 115 (clashes with our Media Foundation video work) |
| `dlls/winex11.drv` | 95 (unused here) |
| `dlls/kernelbase` | 62 |
| `server` | 52 |

341 of the commits are marked `HACK`. A Valve change to a file that a `*_ios.c`
replacement overrides is silently lost unless it is carried into the
replacement by hand.

## Steps

### 0. Measure before committing to the base (one day, desk only)

1. Sort Valve's commits into these classes:
   - PE-only game fixes: they apply as they are.
   - fsync and ntsync: Linux kernel only, left out or compiled out.
   - winex11, winewayland, evdev and hidraw: unused.
   - ARM64EC and FEX: wanted.
   - Changes to files the `*_ios.c` replacements override: must be ported by hand.
   - winegstreamer.
2. Count the last class and the ARM64EC/FEX class, in lines.
3. Try `git rebase --onto proton_11.0` for `patches/wine-port` in a scratch tree
   and count the conflicts.

**Checkpoint.** Choose between:

- **A, the base is `proton_11.0`** (this plan), or
- **B, stay on WineHQ and carry a `patches/wine-valve` series** of the Valve
  commits from the wanted classes, cherry-picked onto wine-11.18. B keeps
  0013's forward-only direction and our video work, and needs only a
  cherry-pick when Valve fixes something. It gives up Valve's untested hacks in
  the lost-by-replacement class.

Take A when the replacement class is small and the ARM64EC/FEX work depends on
the rest of Valve's tree. Otherwise take B, and record the numbers either way.

### 1. Pins and fetch

- Change the `wine` row in `pins.lock` to ValveSoftware/wine, branch
  `proton_11.0`, with a commit. Update the header comment and the mirror in
  `$PLAYPORT_BUILD/cache`.
- `wine-port` still records Madeira's `madeira-lgpl` commit, and the build's
  gitlink check stays as it is.

### 2. Rebase `patches/wine-port`

- Rebase one Madeira commit at a time onto the new base, keeping each
  `Madeira-commit:` trailer.
- Check every auto-merged hunk against both sides with `git range-diff` (AGENTS.md).
- Where Valve already carries an equivalent of a Madeira ARM64EC change, drop the
  Madeira patch and record which Valve commit replaces it.

### 3. Port the replacements down (`madeira-port`)

1. Port each `*_ios.c` in `build/ntdll-unix`, `build/win32u-unix` and
   `build/wineserver` from its 11.18 form to 11.0 by reading it against upstream,
   as the 0013 rebase did.
2. Then apply, by hand, every Valve commit from step 0 that touches the file the
   replacement overrides. This includes Valve's ARM64EC cooperative suspend and
   its RtlRaiseException caller context.
3. Build with `-Wimplicit-function-declaration` and `-Wint-conversion` as errors.
4. Compare the archives' undefined-symbol set with the last 11.18 build (0013).

### 4. `wine-unix`, `wine-pe` and Valve's Linux parts

- Reapply `patches/wine-unix` (6) and `patches/wine-pe` (9).
- Keep fsync and ntsync out of the iOS build: `inproc_sync` must fall back to
  server-side sync. Check that no `futex_waitv` or `/dev/ntsync` probe runs on
  Darwin.
- Configure with `--enable-archs=arm64ec,aarch64` as now. Valve builds `i386`
  too; add it only when WoW64 is decided on its own.
- Check the FEX DLL names Valve's commit "Use FEX wow64/ARM64EC dll names"
  expects against what `build/stages/fex.sh` produces.
- Valve's "HACK: Use x86 mono on aarch64" decides which Wine Mono a .NET game
  gets. Check it against what the app ships.
- winegstreamer: re-port our Media Foundation and static GStreamer patches onto
  Valve's 115 winegstreamer commits.

### 5. Build and phone gate

- Run `pp build --clean`. Commit the new `app/artifacts.tsv` and
  `build/generated/wine-pe-*.tsv` from `.work/run`.
- `pp ui --play app-367520 --until first-frame+10 --shot` on DXMT, then again
  with the Vulkan backend (`set:`).
- Play the video case from [hk-video](../evidence/2026-09-26-hk-video.md).
- `pp perf --secs 180 --pad first-frame+25:hk-new-game` against
  [the 11.18 baseline](../evidence/2026-09-26-hk-native-baseline-wine-11.18.md).
  Neither the first frame nor the frame times may get worse.
- Write an evidence record `docs/evidence/<date>-wine-proton-rebase.md` with
  the IPA's sha256, the conflict counts and the measured numbers.

### 6. Records

- Write decision 0017, "Wine from Valve's Proton branch", superseding 0013's
  choice of base. It records the direction change (a stable base with Valve's
  series, not the latest development release) and how the pin moves: when Valve
  moves `proton_11.0` (each Proton 11 point release), and again at Proton 12
  on Wine 12.
- Update AGENTS.md (the pins rule), ARCHITECTURE.md (patch series) and the
  `pins.lock` comment.
- Add Valve's Wine to NOTICES.md and LICENSING.md. It is LGPL like upstream.

## Risks

- **Going backwards costs as much as 0013 did, or more.** The replacements are
  about 92k lines, and each Valve change to a replaced file is extra work that
  git will not show.
- **Our winegstreamer video work is on 11.18** and has to be redone on Valve's
  different tree.
- **Valve's ARM64 testing is on Linux with a 4K-page kernel and FEX's Linux
  paths** (TSO, unaligned atomics, the stats shm; some of those were reverted).
  Not all of it will apply to Darwin.
- **Later Wine fixes arrive late.** They reach us only when Valve backports them
  or rebases for Proton 12.

## Not in this plan

Proton's Steam pieces (`lsteamclient`, `steam.exe`, `vrclient`) are in the
Proton repository, not in Valve's Wine, and cannot work here: `lsteamclient`
loads the native Steam client's library, which does not exist on iOS. Games'
Steam needs are covered by [the Steam for games plan](2026-09-27-steam-for-games.md).
