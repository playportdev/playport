# FEX on upstream: Madeira's port rebased onto FEX-Emu FEX-2609.1

**Date:** 2026-09-24. **Decision:** [0008](../decisions/0008-fex-on-upstream.md).
**Result:** Madeira's FEX port, its rpmalloc changes and Playport's FEX series
build on FEX-Emu FEX-2609.1. On the phone the ladder passes **6/6**, the
three unattended G2 probes pass, and Hollow Knight loads a save and is played
with a controller for four minutes on the new FEX (about 79 presents a
second). **Not verified:** anything that needs a person beyond that session
(`g2-session`, `g2-pad`); a second title; Madeira's native iOS FEXCore build,
which Playport does not build.

## 1. What moved

| | Before | After |
| --- | --- | --- |
| FEX base | Madeira `FEX` = willfaust/FEX `ios-port-2607` `0f8edf8f6383`, on FEX-Emu `1cc4b93e` (FEX-2607) | FEX-Emu/FEX **FEX-2609.1** `9fbdc00bd6401aff3b32d79e78ff98b8a13e4dcf` (2026-09-21), 591 upstream commits later |
| Madeira's FEX port | the fork's 64 commits, built as the pin | `patches/fex-port`: 62 rebased commits + 1 adaptation commit |
| rpmalloc | willfaust/rpmalloc `ios-madeira` `1f271c0c` (the fork's gitlink) | FEX-Emu/rpmalloc `09142d72` (FEX-2609.1's gitlink) + `patches/rpmalloc-port` (16 rebased commits) |
| Playport's series | `patches/fex` 0001-0002 | `patches/fex` 0001 (refreshed) and 0002 (unchanged) |
| `xtajit64.dll` | 5,388,800 bytes | 5,494,272 bytes; same exports, six new ntdll imports (`NtCreateThreadEx`, `NtLockFile`, `NtUnlockFile`, `NtTerminateThread`, `NtUnmapViewOfSection`, `NtWaitForSingleObject`, from upstream's thread helper and disk cache) |

**Why the release, not `main`.** FEX-Emu tags a release each month.
FEX-2609.1 was three days old and 122 commits behind `main`, and a monthly tag
gives the next rebase a fixed target (FEX-2610). Its one change since
FEX-2609 fixes the Linux syscall instruction, which the Windows build does not
use. DXMT chose `main` because its latest release was five months old.

`pins.lock` gains `fex-port` (`0f8edf8f`) and `rpmalloc-port` (`1f271c0c`):
build-from-pins now checks Madeira's `FEX` gitlink and that FEX's
`External/rpmalloc` gitlink against them, and `tools/upstream-sync` holds when
either moves. Its dry run on the current Madeira pin replays every series
clean.

## 2. The rebase

`git rebase FEX-2609.1` of `ios-port-2607` (64 non-merge commits since the
merge base) with `merge.conflictstyle=zdiff3`, every conflict resolved by
reading both sides, then `git range-diff` of the whole port against the
original to review every auto-merged hunk. Each patch in `patches/fex-port`
carries `Madeira-commit:` (its original) and `Rebased: clean` or
`Rebased: resolved`.

- 16 commits had real content conflicts (below).
- 3 more needed compile fixes against changed upstream APIs (§3).
- 14 commits carried an `External/rpmalloc` gitlink bump. Those bumps are
  not in the port series: rpmalloc is its own series now (§4). Two commits
  (`b9e9a97` "bump rpmalloc to the ml490/ml492 poison-log sink",
  `54d7ab4` "Advance rpmalloc to its committed state") held nothing else and
  became empty.
- The rest applied clean. The fork-scout trial counted 7 conflicting commits
  with its "fork side wins" shortcut; the real replay had 16, because taking
  the fork's side hides the later conflicts in the same files.

| # | Madeira commit | Conflict | Resolution |
| --- | --- | --- | --- |
| 1 | `fce78ce` iOS/ARM64 port (squash) | upstream split `DecodeInstructionsAtEntry` into `SetupDecodeInstructionsAtEntry` + `DecodeLoop`, moved the code buffer into `SharedCodeBufferManager.cpp` (`d2c92808f`) and made JIT space an atomic bump (`6734c9ed3`); `PrctlUtils.h`, `Allocator.cpp` reshaped | the port's `__linux__`/`__APPLE__` split kept on upstream's code; its debug logs moved to the equivalent new anchors; the Apple W^X `SetWriteOffset` restore placed before the copy on upstream's allocation path. The squash's Linux-side `Allocator.cpp` body was pre-2607 upstream code (an old VA probe, a dropped `MADV_DONTDUMP`), not iOS work: upstream's kept. The upstream Windows allocator branch the squash deleted (and Madeira's `c781104` later restored) was kept |
| 11 | `f37a518` console IO | upstream `WriteFile` gained an overlapped byte offset | the port's stderr mirror, with upstream's offset |
| 24 | `707f213` callret bounds guard | log suppressions at moved lines | applied at the new locations |
| 25 | `61f11e3` dual-map fast-write | the code-buffer copy moved to the atomic allocation | `FEX_IOS_HOST` write-offset restore and the `[DUAL_MAP_SANITY]` probe on the allocated range; on the phone it prints `RWCursor = RXCursor + WriteOffset` as designed |
| 27 | `b648df3` LookupCache shrink | `PassManager(ctx)`, `InsertRegisterAllocationPass` gone, `CreateThread()` lost its RIP/SP arguments | upstream's calls with the port's thread-init step markers |
| 29 | `c781104` adapt to FEX-2607 | its Windows allocator branch already present | upstream's (which also installs the rpmalloc name hook), with the port's comment |
| 30 | `412d121` no-op FEXUnixLib on iOS | upstream removed the legacy path and added `MapFile` (disk-cache reads) | the forced old-method init and the no-ops on upstream's functions; `MapFile` no-op'd too |
| 37 | `49a7b55` #52 pool-alias | upstream sets `CONFIG_APP_FILENAME`/`CONFIG_APP_CONFIG_NAME` after logging init | both |
| 41 | `b8368fe` footprint reclaim | the code-buffer constructor moved | the exec-alloc degrade ladder in `SharedCodeBufferManager.cpp`, before upstream computes the buffer end from the (possibly degraded) size |
| 42 | `90a3015` #60/ml411 read-file lock release | upstream `179b442` no longer holds `CodeInvalidationMutex`/`ThreadCreationMutex` across `NtReadFile` (it invalidates after the read), except for P5R.exe | see §3.2 |
| 43 | `156653c` JIT-lock family #74/#75/#80 | upstream removed `CodeBufferWriteMutex` and `LatestOffset` | see §3.1 |
| 47 | `2e6bbec` exact guest RIP | the port deletes its stderr mirror (a stack smash, ml572) | deleted; upstream's offset kept |
| 48 | `d6d4975` lock release at exit, IR repair | both sides appended to `PassManager.cpp` | both; the port's `ResetCallRetStack` on upstream's allocation path |
| 55 | `ac555dd` Mythic → Madeira rename | renamed lines had moved | upstream's lines with the same case-preserving rename (zero "mythic" left, as in the original) |
| 58 | `38dddb3` allocator and call-return hardening | the same two upstream calls as 37 and 27 | both kept; the null-thread unwind on upstream's `CreateThread()` |
| 62 | `89db11f` sweep retry, pool placement | `MAX_CODE_SIZE` and `StartLargerCodeBuffer` moved | applied in `SharedCodeBufferManager.cpp` (128 MB on iOS, straight to the maximum on growth) |

## 3. What the textual merge did not catch

### 3.1 The JIT code buffer lost its lock

Madeira's largest hardening (#74/#75, commit 43) is built around
`CodeBufferWriteMutex`: a TEB ownership stamp so a dead-holder reaper can
release it, a self-nesting grant, a bounded acquire in delivery mode.
Upstream `6734c9ed3` removed that mutex: JIT space is now claimed with a
compare-and-swap bump (`AllocateCodeBufferInSharedCache`). Resolution:

- The stamp, self-nesting and bounded acquire were **dropped**: there is no
  lock left to die holding, re-enter or deadlock through.
- The delivery-mode (ml455) refusals still matter and moved into the new
  allocation function: a compile during guest exception delivery never
  rewires or swaps buffers, and fails that one compile instead.
- The #75 generation machinery was ported: `LatestMutex` now lives in
  `SharedCodeBufferManager` and, with upstream's mutex gone, is the only thing
  serialising `GetLatest`/`AllocateNew`; the per-thread migrate lock, the
  pool-tail sweep and the 32→128 MB sizing followed. On the phone:
  `[gen] alloc#2 size=0x8000000` and `[gen-sweep] … migrated=39`.
- Git auto-merged the ml455 "return unpublished" early exit **after**
  upstream's reordered publication block, where it would have published
  delivery-mode code (the deadlock it exists to avoid). It was moved back in
  front, and a disk-cache lookup (which publishes on a hit) is skipped in
  that mode.

### 3.2 An auto-merge that would have disabled SMC invalidation

Commit 42 rewrote `BTCpu64NotifyReadFile` to release its locks before any
early return, with an unconditional `if (After) { release; return; }` head.
Git merged that head cleanly into upstream's new function, whose after-read
path is where upstream now invalidates translated code overwritten by a
file read. The merge would have skipped that invalidation for every read.
Resolution: the release-first mirror applies only when a lock is actually
held (upstream's P5R path); every other read still invalidates.

### 3.3 Guest exceptions are raised differently upstream

Upstream `064a6e96c` raises every guest exception through `NtRaiseException`
(so that Windows sends a debug event) instead of returning into
`KiUserExceptionDispatcher`. The iOS ntdll (Madeira's replaced
`signal_arm64_ios.c`/`thread_ios.c` on wine-11.4) and Madeira's
exception-path fixes were built around the return path, and no debugger
attaches on the phone, so port patch 0063 keeps it for first-chance
exceptions on `FEX_IOS_HOST`; only upstream's non-continuable raise
(`d704bd3ce`, `__fastfail`) uses the syscall. Madeira's ml341 pool-alias RIP
fix, which had merged against the removed `Args` frame, now rewrites the
guest context instead.

### 3.4 Smaller breaks

- Compile fixes, folded into the commits that introduced the code:
  `HostFeatures` lost `DCacheLineSize`/`ICacheLineSize` for a packed
  `DCacheLineLog2` (the hand-rolled iOS features, `16cae73`); `IR::Dump`
  takes an `ostringstream` (the IR capture, `d6d4975`); upstream's switch to
  explicit `*W` Win32 calls (`GetModuleHandleW`, `d21da24`); the sweep read a
  counter that moved files (`156653c`); `Args` in the exception path
  (`b64c4c2`, §3.3).
- Port patch 0063 also routes upstream's new disk-cache code copy
  (`LoadCachedCode`, off by default) through the JIT pool's RW alias, and
  gives upstream's new `NtRaiseExceptionNative` the unprefixed alias the
  port's other native syscall wrappers carry (without it the object bound a
  linker-made exit thunk).
- A debug log landed in the wrong function in commit 1 (git placed it inside
  `DetectDataMasks`); moved out.
- `patches/fex` 0001: upstream now includes `<cstdlib>` itself, so the
  3-way merge produced a duplicate include; the refreshed patch drops its own.

## 4. rpmalloc

FEX-2609 calls rpmalloc's new `rp_name_hook` (FEX-Emu/rpmalloc `09142d7`,
"Support naming VMA regions on Windows"), which Madeira's rpmalloc fork
lacks, so FEX could not stay on the fork's rpmalloc. Madeira's 16 rpmalloc
commits were rebased onto FEX-2609.1's gitlink: 13 clean, 3 resolved, all on
the same line (`os_mmap`'s Windows fallback). The port's iOS band-pinned
`VirtualAlloc2` path is unchanged; the non-iOS fallback keeps upstream's
`MEM_TOP_DOWN`, and upstream's `os_set_page_name` runs after either path. The
net difference from Madeira's rpmalloc head is exactly upstream's two commits.

## 5. Build

- **Tree.** Superproject `af0e1c7` plus the `build-dxmt-combined.sh` guard
  and docs committed in `df2e5a4`; the series hashes are in
  [`build/provenance.txt`](2026-09-24-fex-latest-rebase/build/provenance.txt).
- **IPA:** `Playport-26.5-c2f7472d.ipa`, 660,694,421 bytes, sha256
  `c2f7472d0ad184f0075f28a33775379a288d2187e01562aad9ad6efd5eb5273f`.
- **verify-ipa:** 49 checks, 0 failures
  ([`build/verify.log`](2026-09-24-fex-latest-rebase/build/verify.log)).
- **Where.** A lane `$PLAYPORT_BUILD` (`$PLAYPORT_BUILD/lanes/fex-rebase/pb`)
  with the shared run's `pe` and `unix` hardlinked and `--from fex`
  ([`build/build-from-pins.log`](2026-09-24-fex-latest-rebase/build/build-from-pins.log);
  the first run was stopped in the dxmt stage, see below). The record changes
  are FEX's `xtajit64.dll` row and the DXMT PE rows, whose bytes depend on
  the build root (same sizes), as in the DXMT lane.
- **A shared-cache mistake, repaired.** The lane's `cache/` was a symlink to
  the shared cache. `build-dxmt-combined.sh` configured the LLVM iOS build
  directory through the symlinked path, so CMake re-recorded the shared
  `llvm-ios-15.0.7` under the lane path and ninja began rebuilding it. The run
  was stopped, the shared build directory was reconfigured at its canonical
  path and rebuilt to "no work to do", and the script now resolves the path
  (`realpath`), so a symlinked lane cache reuses it.
- **Madeira's native iOS FEXCore build** (`build/fex-ios`, `__APPLE__` code
  paths), which Playport does not build or ship, was resolved in good faith
  but not compiled.

## 6. Device

iPhone Air (`iPhone18,4`), iOS 27.0, over netmuxd Wi-Fi, all under the shared
`device.lock`. Installed in place (`apps install`, container kept).

- **New FEX on the phone:** every launch logs
  `[build-id] xtajit64 rev=ml908 compiled Sep 24 2026 22:05:15`, this lane's
  build. (The ladder's backend label `madeira:fex-0f8edf8f6+…` is a fixed
  string in `ladder.py` and LadderKit, not read from the binary.) After the
  device gate that identity was corrected to name the FEX-Emu pin plus
  fex-port: `madeira:fex-9fbdc00bd+fex-port-0f8edf8f6+…`. The constant is
  compiled into the app, so the gated IPA (`c2f7472d…`) differs from this
  branch's head only by the backend identity and revision strings
  (`madeiraBackendID` in LadderKit and `ladder.py`, and LadderMode
  `backendRevision`). The recorded
  `ladder/w2-results.jsonl` still carries the old label, as it was run.
- **G1 ladder: pass, 6/6.** [`ladder/`](2026-09-24-fex-latest-rebase/ladder/).
  Cold start 5.404 s (0.246 s excluding activation); peak RSS 1,250 MB,
  steady 1,245.6 MB; minimum available memory 6,941 MB; main-thread maximum
  stall 0.2 ms. The DXMT record had 5.493 s, 1,235 MB, 1,230.6 MB, 6,956 MB
  and 0.1 ms: about 15 MB more resident memory on FEX-2609.
- **G2: the three unattended probes pass** (`g2-graphics/1`, `g2-audio/1`,
  `g2-input/1`). [`g2/`](2026-09-24-fex-latest-rebase/g2/). `g2-session/1`
  and `g2-pad/1` need a person and were not run, so G2 as a whole still has no
  verdict.
- **Hollow Knight: loads a save and is played.**
  [`hollow-knight/`](2026-09-24-fex-latest-rebase/hollow-knight/).
  - `title-device-run.py --pool-mb 896 --wait 240 'Games\Hollow Knight\hollow_knight.exe' -logFile 'C:\hollow_knight-player.log'`;
    activation 5.46 s, `wine_host_run_exe -> 0`, ended by `--wait` (the
    harness kills the title).
  - Unity on `Apple A19 Pro GPU`, Direct3D 11.0 [level 11.1]; the save's
    scene loaded (63,361 objects) and the player log shows nail strikes and
    running, with 457 non-idle controller reports in the host log: someone
    was at the phone with the pad.
  - 19,408 presents in 245 s (about 79 a second); 142,754 JIT compiles, 99%
    lookup hit rate by the end; no crash, abort or unpublished-compile bail
    (the `[fault-class]` lines are Madeira's routine census of emulated
    stores to write-protected code pages).
- **Findings.** Unity's `GpuFence::Create` failure and the
  `JsonSharedData.Save` empty-path exception are in the bootstrap's runs too.
  No new failure signature.
- **Device-only debugging:** none was needed. The ladder, G2 and the title
  passed on the first install.

## 7. Cost, against the scout's estimate

The scout sized a FEX rebase at 2-4 agent-days plus open-ended device
debugging, from a trial that counted 7 conflicting commits. This one took one
crewmate session (about four hours of wall time, device gates included).
What it needed:

- 16 real three-way resolutions (the trial saw 7), 3 compile-only fixes and
  a second rebase (rpmalloc, 3 resolutions) that the trial did not show;
- three semantic breaks no conflict marker showed (§3.1-3.3), two of which
  git had "resolved" silently in a harmful way: a deadlock guard moved behind
  the code it guards, and SMC invalidation after file reads disabled;
- one deliberate divergence from upstream on iOS (exception delivery, §3.3);
- dropping part of Madeira's hardening because upstream removed what it
  guarded (§3.1).

The device budget went unused this time, but the risk moved rather than
disappeared: §3.1 and §3.3 change the code Madeira spent July and August
debugging on the phone, and one Unity title plus the ladder does not
exercise the Steam/Chromium thread storms those fixes came from.

The ongoing cost is structural:

- every FEX release is a hand rebase of about 60 commits whose most
  iOS-specific code sits in the files upstream changes most (the JIT, the
  code buffer, the ARM64EC frontend);
- every Madeira FEX or rpmalloc change arrives as a diff to re-port;
- upstream-sync can never auto-merge a FEX move.
