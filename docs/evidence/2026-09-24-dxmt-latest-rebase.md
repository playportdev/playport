# DXMT on upstream: Madeira's port rebased onto 3Shain/dxmt main

**Date:** 2026-09-24. **Decision:** [0007](../decisions/0007-dxmt-on-upstream.md).
**Result:** Madeira's DXMT port and Playport's series build on upstream DXMT `main`.
On the phone the ladder passes **6/6**, the three unattended G2 probes pass,
and Hollow Knight reaches its main menu on the new DXMT (HUD:
`DXMT D3D11 FL_11_1 v0.80-291-g33901`) at about 87 fps. **Not verified:**
gameplay past the menu (no one was at the phone to play).

## 1. What moved

| | Before | After |
| --- | --- | --- |
| DXMT base | Madeira `research/dxmt` = willfaust/dxmt `ios-port` `0cb976618700`, on 3Shain/dxmt `a3a6e8f5` (v0.73+45, 2026-03-07) | 3Shain/dxmt `main` `7c8dee1c2d73415301ceb7d1fa810861cef4cd67` (2026-09-17), 327 upstream commits later |
| Madeira's port | the fork's 44 commits, built as the pin | `patches/dxmt-port`: 43 rebased commits + 1 regeneration commit |
| Playport's series | `patches/dxmt` 0001-0004 | `patches/dxmt` 0002-0004 (0001 superseded) |
| winemetal unix table | 140 slots, Playport's `newLibraryWithSource` at 139 | 150 slots: upstream's 0-145 (its `newLibraryWithSource` at 144), Madeira's 146-149 |
| unix slice | 20 objects | 23 objects (upstream's `dxbc_binding_sm50`, `dxbc_binding_rootsig`, `transforms/simdgroup_implicit_membarrier`) |
| Upstream licence | MIT | LGPL-2.1-or-later (upstream `ec357fd`, 2026-04-25, after v0.80); see §5 |

**Why `main`, not v0.80.** v0.80 (2026-04-23) was the latest release, but 244
commits and five months behind `main`, and the ask is the latest DXMT.
Upstream's CI builds `main` on every push. The cost is that `main` carries
unreleased work (a D3D12 front end, residency sets, heaps, counter pools),
which is exactly where the port collided.

`pins.lock` gains a `dxmt-port` row (`0cb97661`): build-from-pins now checks
Madeira's `research/dxmt` gitlink against it, so a Madeira DXMT update stops
the build until it is re-ported.

## 2. The rebase

`git rebase origin/main` of `ios-port` (44 non-merge commits since the merge
base) with `merge.conflictstyle=zdiff3`, every conflict resolved by reading
both sides. 33 commits applied cleanly; 11 needed a real three-way
resolution; 1 became empty. The trial in the fork-tracking scout counted 10
conflicting commits with its "fork side wins" shortcut; the real replay had
11, because the shortcut hid a follow-on conflict (commit 25).

Each patch in `patches/dxmt-port` carries `Madeira-commit:` (its original)
and `Rebased: clean` or `Rebased: resolved`.

| # | Madeira commit | Conflict | Resolution |
| --- | --- | --- | --- |
| 3 | `77f5d3f` headless WSI + iOS Present | upstream gated `should_exit_fs` on `handle_alt_tab_` | kept the fork's `DXMT_IOS` `false`, upstream's expression in the `#else` |
| 6 | `7ffb682` detect ARM64EC | upstream `db4720e` already excludes arm64ec from `DXMT_ARCH_X86` | took upstream's `util_bit.hpp`; kept the fork's meson install-dir routing |
| 7 | `0e70244` drop `SV_CULL_DISTANCE` | upstream `fd809f8` implements cull distance as a user varying | took upstream in all three stages; **the commit became empty and was dropped** |
| 19 | `bc6d4c7` BC1/BC3 decode | upstream added the LGPL header to `dxmt_resource_initializer.cpp` | header plus the fork's `#include <memory>` |
| 21 | `d6bd546` Full BCn decode, Book of the Dead retention (6 files) | upstream replaced per-UAV counter buffers with a suballocated counter pool, made allocations `final` with `free()` instead of destructors, added heap-placed buffers/textures and per-subresource fence trackers, and moved textures into `TResourceBase::texture_` | took upstream's structure; moved the fork's memory-census refund into `free()` (skipped for heap-placed allocations, which the census never charged); kept the fork's physical BC mip clamp on `texture_` with the keyed-mutex constructors; `initWithData` keeps upstream's new format-flags argument |
| 25 | `59c1739` Mythic→Madeira rename | the rename inside the comment dropped with commit 7 | took upstream |
| 26 | `984270d` licensing boundary | upstream added its own `CONTRIBUTING.md` | the fork's licensing text first, upstream's rules kept verbatim below it |
| 29 | `ee72717` mesh-pipeline classification | upstream added per-stage fence waits, named binding indices and emulated stream-output bindings | all of upstream's bindings; only the object/mesh block wrapped in the fork's `d3d11.noMeshShaders` gate |
| 37 | `40b84f8` remote Metal daemon | upstream appended 19 unix calls to both dispatch tables | upstream's list, with the fork's `_rmg_` guard on the one entry it routes |
| 39 | `5925f5d` remote transport | both sides appended calls at slots 127+ with explicit numbers; three names collide | see §3 |
| 40 | `b3075b2` draft converter exception | `CONTRIBUTING.md` again | the fork's new paragraph in its section |
| 42 | `4c86e09` runtime control bridge (7 files) | airconv argument enum 8 taken by upstream's root signature; both sides implemented SM5.1 constant-buffer operands; upstream made the video-memory-budget notification return `S_OK`; slots again | see §3; took upstream's SM5.1 operand; kept Madeira's `DXGI_ERROR_UNSUPPORTED` default for the budget notification (Madeira measured that `S_OK` with an event that never fires hangs RDR2); `SM50_SHADER_PSO_VERTEX_INTERFACE` renumbered 8→10 |

### Compile-time follow-ups folded into the commits that caused them

The rebased tree did not build as merged. Each fix went into the Madeira
commit that introduced the code (autosquash), so every patch stays
self-contained:

- commit 42: the fork's texture→buffer blit read the dropped `options` field
  (§3); back to the plain pitch check, since aspect copies now use upstream's
  dedicated command;
- `401629f` (FRAME_STATS): upstream fixed the spelling of
  `present_lantency_interval` → `present_latency_interval`;
- `53010c5` (BC upload decode): upstream replaced
  `DXMT_ENCODER_RESOURCE_ACESS_WRITE` with `ResourceAccess::Write`.

## 3. What the textual merge did not catch

1. **The winemetal unix-call ABI.** Slots are numbered by hand on the PE side
   (`UNIX_CALL(N)`) and by position in the unix table. Upstream used 127-145;
   Madeira used 127-138 for its own calls. Commit 39 conflicted on the table,
   but commit 42's new thunks (`UNIX_CALL(134)`..`(138)`) **merged cleanly** and
   would have called upstream's `removeAllocations`, `removeAllAllocations`,
   `commit`, `addResidencySet` and `newHeap`. Resolution:
   - upstream's slots keep their numbers;
   - Madeira's residency-set and heap calls became PE-side wrappers over
     upstream's calls (`addAllocation`, `removeAllocation`,
     `newPlacementHeap`, `newTextureAtOffset`), or were replaced by
     upstream's where the names collide (`newResidencySet`, `commit`,
     `addResidencySet`, `heapTextureSizeAndAlign`);
   - Madeira's remote-mode behaviour moved into upstream's unix bodies;
   - Madeira's remaining calls were renumbered: `madeira_ir_convert` 146,
     `newRenderPipelineStateVD` 147, `newGeometryEmulationPipelineState` 148,
     `madeira_ctl` 149.

   `gen_remote_guard.py` and `gen_api_names.py` were rerun (port patch 0044).
   A script mapped every `UNIX_CALL(N)` to table entry N for all 150 slots:
   the only mismatch is upstream's own `WMTCopyAllDevices`/`MTLCopyAllDevices`
   alias. Madeira's `madeira_d3d12.dll`, which Playport does not build or
   ship, uses the old numbers and would need rebuilding against this header.
2. **An uninitialised blit option.** Commit 42 added an `options` field to
   the existing texture→buffer blit command and passed it to Metal. The d3d11
   writers never set it, and the command heap is not zeroed, so d3d11
   readbacks would have passed garbage `MTLBlitOption` bits. Upstream had
   added a separate `CopyFromTextureToBufferWithBlitOption` command, so the
   field was dropped.
3. **A shader include.** Upstream's `dxmt_command.metal` now
   `#include`s `dxmt_command_constants.hpp`. Playport compiles that file on
   the device with `newLibraryWithSource`, which has no include path, so
   dxmt 0003 now inlines quoted includes at build time
   (`src/dxmt/inline_metal_includes.py`). The file also contains non-ASCII
   text, which upstream's `NSASCIIStringEncoding` decoding would reject; 0003
   decodes UTF-8.

The build also needed:

- upstream's three new airconv translation units in the unix slice;
- a native file in place of the deleted `build-osx.txt`;
- guards so that upstream's new native macOS parts (airconv, `winemetal.so`,
  the native DXBCParser), now configured for aarch64 cross builds too, are
  skipped when no Apple toolchain is present.

## 4. Playport's series

- **0001** (regenerate `wmt_remote_guard.h`): superseded by port patch 0044
  and deleted.
- **0002** (background GPU gate): applied cleanly.
- **0004** (`madeira_cfg.h` beside the tree): applied cleanly.
- **0003** (compile `dxmt_command.metal` on the device): rewritten. Upstream
  now has `MTLDevice_newLibraryWithSource` itself (slot 144, `2a767c4`), so
  0003 no longer adds a slot. It carries only what differs:
  - the offline compiler's options (Metal 3.2, fast math) and UTF-8 decoding
    in upstream's unix body;
  - the remote-mode route;
  - the include inlining;
  - the `xcrun`-optional meson guards.

`verify-ipa.py` now checks a 150-slot table with
`_MTLDevice_newLibraryWithSource` at 144, and checks that the include-inlined
source (sha256 `78cc2261…`) is embedded once in each `d3d11.dll`.

The AIR helper proof's `ref` check now allows upstream `0606575`'s respelling
of `air_tessellation.metal`'s one threadgroup atomic add (the same relaxed,
threadgroup-scope `fetch_add`), so the hand-ported IR stays valid unchanged.

## 5. Licence

Upstream DXMT relicensed from MIT to LGPL-2.1-or-later (`ec357fd`,
2026-04-25; MIT kept as `LICENSE.OLD`). The DXMT code Playport ships is now
LGPL upstream plus Madeira's GPL-3.0-or-later changes, and the unix slice is
statically linked, which brings the same relinking duty Wine's unix side
already has. `docs/LICENSING.md` and `docs/NOTICES.md` are updated and
`notices-assemble.sh` copies `COPYING.LIB` and `LICENSE.OLD`.

`LICENSE-EXCEPTION.md`'s statement of what it does not cover now says
upstream DXMT code is LGPL-2.1-or-later (it said MIT). That is a factual
correction; the permission itself is unchanged.

Madeira's `LICENSE-MADEIRA.md` in the DXMT tree still says the upstream
licence is MIT. It is Madeira's file and is left untouched; the discrepancy is
recorded here.

## 6. Build

The gate IPA was built with the tree of commit `67f5cae`. The series
hashes in [`build/provenance.txt`](2026-09-24-dxmt-latest-rebase/build/provenance.txt)
equal that commit's `patches/dxmt` and `patches/dxmt-port`.

- **IPA:** `Playport-26.5-88e79e40.ipa`, 660,130,205 bytes, sha256
  `88e79e40349262abeb722f15ec9f54138faa503087ed09ab2b6a9bc9e2d4f152`.
- **verify-ipa:** 50 checks, 0 failures
  ([`build/verify.log`](2026-09-24-dxmt-latest-rebase/build/verify.log)). It
  saw a 150-slot unix table with `_MTLDevice_newLibraryWithSource` at 144,
  the export and import in both PE sets, and the embedded include-inlined
  source.
- **Slot map:** [`build/check-slots.txt`](2026-09-24-dxmt-latest-rebase/build/check-slots.txt),
  from [`check-slots.py`](2026-09-24-dxmt-latest-rebase/build/check-slots.py)
  run on the patched tree.
- **Where it was built.** The build ran in a separate `$PLAYPORT_BUILD`
  (`$PLAYPORT_BUILD/lanes/dxmt-rebase`), because other lanes were using the
  shared `$PLAYPORT_BUILD/run`.
  - The Wine PE DLLs and the crypto statics embed their build root, so a
    from-clean build there changed 237 unrelated `app/artifacts.tsv` rows and
    both `build/generated` manifests, with every size unchanged.
  - The recorded build therefore hardlinked the shared run's `unix` and `pe`
    trees (built at the canonical root, equal to the committed records) and
    ran `build-from-pins --from fex`
    ([`build/build-from-pins.log`](2026-09-24-dxmt-latest-rebase/build/build-from-pins.log)).
  - The only record changes are the P5-dxmt and P5-dxmt-pe rows and FEX's
    `xtajit64.dll`, which embeds its build time.
- **From-clean run.** In that directory, a from-clean `build-from-pins`
  built `unix`, `pe` and `fex`, then stopped at `dxmt` on the build problems
  in §3. After the fixes, `--from dxmt` completed through `verify` (49
  checks, 0 failures; the `--same-device-as` comparison was skipped because
  that directory had no earlier IPA). No single uninterrupted from-clean run
  of the final tree was made.

## 7. Device

iPhone Air (`iPhone18,4`), iOS 27.0, over netmuxd Wi-Fi.

- **Install.** Upgraded in place (`apps install`, the container kept) after
  firstmate cleared the phone. The previous build on it was another lane's.
- **G1 ladder: pass, 6/6.** [`ladder/`](2026-09-24-dxmt-latest-rebase/ladder/).
  - Cold start 5.493 s (0.237 s excluding activation).
  - Peak RSS 1,235 MB, steady 1,230.6 MB; minimum available memory 6,956 MB.
  - Main-thread maximum stall 0.1 ms.
  - These are essentially the bootstrap's numbers (5.614 s, 1,235 MB,
    1,230.4 MB, 6,956 MB, 0.1 ms).
- **G2: the three unattended probes pass.**
  [`g2/`](2026-09-24-dxmt-latest-rebase/g2/). `g2-graphics/1` (D3D11 through
  the new DXMT), `g2-audio/1` and `g2-input/1` all pass. `g2-session/1` and
  `g2-pad/1` need a person and were not run, so G2 as a whole still has no
  verdict, as at bootstrap.
- **Hollow Knight: reaches the main menu.**
  - The command was `harness/device/title-device-run.py --pool-mb 896 --wait 240
    'Games\Hollow Knight\hollow_knight.exe' -logFile 'C:\hollow_knight-player.log'`.
  - Key lines are in [`hollow-knight/`](2026-09-24-dxmt-latest-rebase/hollow-knight/).
  - Activation took 5.37 s; `wine_host_run_exe -> 0`.
  - Unity came up on `Apple A19 Pro GPU` under Direct3D 11.0 [level 11.1] and
    loaded the saved language.
  - The screen showed the title menu, animated, with the Metal HUD at
    86.7 fps, GPU 12.15 ms, frame interval 11.53 ms, 601.67 MB Metal and
    2.93 GB for the app. Upstream DXMT's own HUD metric names the build as
    `v0.80-291-g33901` (screen-menu.jpg (screenshot not published)).
  - About 23,000 presents over the 240 s, with no abort, no unimplemented
    winemetal call, no command-library error and no DXMT assertion in the
    launch's log.
  - The launch was ended by `--wait` (the harness kills the title).
- **Findings.**
  - Unity logs `GpuFence::Create(): Failed to create ID3D11Fence, error
    0x80004005`. The bootstrap's Hollow Knight runs log the same line, so it
    is not from this change.
  - The Metal HUD now shows upstream DXMT's custom-metrics line (upstream
    `654f547`).
- **Not done.** No play session past the menu: no one was at the phone. King's
  Pass gameplay (the bootstrap's played scene) exercises more of DXMT than
  the menu does. An attended session is the remaining verification.

## 8. Cost, against the scout's estimate

The scout sized the DXMT rebase at 1-3 agent-days plus title
re-verification. This first rebase took one crewmate session (about
2.5 hours of wall time, device gates included), but its size is better
measured by what it needed:

- 11 genuine three-way resolutions;
- 3 semantic breaks no conflict marker showed (§3), one of which (the slot
  ABI) would have built cleanly and called the wrong Metal functions at run
  time;
- 3 upstream renames that broke compilation of merged code;
- 4 build-system changes (new sources, a deleted native file, native macOS
  parts now configured for aarch64, the shader include);
- a licence change.

None of it needed device-only debugging this time. The ladder, G2 and the
menu passed on the first install.

The ongoing cost is structural rather than a one-off:

- DXMT upstream and Madeira both append winemetal calls, so every
  resync must reconcile the slot tables by hand;
- every Madeira DXMT change now arrives as a diff to re-port rather than a
  gitlink bump;
- `upstream-sync` can never auto-merge a DXMT move.
