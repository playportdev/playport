# Our low-address-space CEF 143.0.14, under desktop Proton (PLA-370 stage C)

**Date:** 2026-10-16 (build 15:09–18:03, runs 18:07–18:14). **Branch:** `dev/pla-291-rockstar-launcher`
(from `860e23d`). **Linear:** [PLA-370](https://linear.app/playportdev/issue/PLA-370). **Plan:**
[low-VA CEF](../plans/2026-10-16-cef-low-va-build.md), stage C. **Decision:**
[0110](../decisions/0110-own-cef-build-for-a-clients-cef.md).

Host only: no phone, no `pp` build, no sign-in, no game. Rockstar's binaries were not analysed; only
the launcher's behaviour and logs were observed. Sources are marked **[M]** measured here, **[S]** read in
Chromium source, **[I]** inference.

## Answer

- **The build works [M].** The low-address-space configuration of CEF 143.0.14 built for Windows x64 on
  Linux: 76,653 ninja steps, exit 0, no failed step after one arg fix. It needed one source change, a
  PartitionAlloc pool-size flag.
- **Social Club accepts it [M].** Swapped in for Social Club's CEF files under desktop Proton, the
  launcher reached its sign-in page. This held both with no extra switches and with decision 0109's
  switches. There was no `SC_INIT_ERR` and no crash in any CEF process.
- **The address space fits [M].** With no switches the 9-process tree holds **10.1 GiB** of
  reservations of 64 MiB or more, against the stock build's 5,079 GiB, most of it the renderers' 1,320 GiB sandbox placeholders.
  - Every non-renderer process holds none.
  - Each renderer holds 2.9–4.4 GiB.
  - The largest single reservation is 2 GiB, aligned to 2 GiB.
  - A first-fit packing puts the whole tree into [0x70, 0x7c) with up to 36 GiB taken by Wine below it.
- The phone is not checked here. Images (libcef.dll is 245 MiB, mapped per process), smaller
  reservations and committed memory come on top; stage D measures them.

## Build

**Arguments.** The stage B args (`is_official_build=true`, `chrome_pgo_phase=0`,
`use_v8_context_snapshot=true`, Windows x64, xwin CRT and SDK 10.0.26100) plus:

| Arg | Value | Note |
| --- | --- | --- |
| `use_partition_alloc_as_malloc` | false | the plan |
| `enable_backup_ref_ptr_support` | false | the plan |
| `move_metadata_outside_gigacage` | false | the plan. `enable_move_metadata_outside_gigacage_trial` follows it to false |
| `v8_enable_sandbox` | false | the plan. `v8_build_config.json`: `sandbox` false |
| `v8_enable_pointer_compression` | false | the plan. `v8_build_config.json`: `pointer_compression` false |
| `cppgc_enable_caged_heap` | false | the plan. `cppgc_enable_pointer_compression` follows it to false |
| `partition_alloc_low_va` | true | new, from the source patch below |
| `use_allocator_shim` | false | build fix, explained below |

- `gn args --list` confirms every value, and `gn gen` passed (35,966 targets).
- CEF's argument generator overrides none of these on Windows, and nothing asserts against them [S].
  CEF itself sets the first two to false for its Linux official builds.
- The output directory is separate: `out/Release_GN_x64_lowva`. The stage B outputs
  (`out/Release_GN_x64` and the swap tree `out-stage-b`) are unchanged; libcef is still `c321c8a5…`.

**The source patch (scratch diff 008).** It adds a PartitionAlloc GN arg and buildflag,
`partition_alloc_low_va`, default false. Its branch comes first in `partition_alloc_constants.h`, so
`kPoolMaxSize` becomes 1 GiB. Without the flag the configuration is unchanged.

- The glued regular+BRP block becomes 2 GiB, aligned to 2 GiB, instead of 32 GiB aligned to 32 GiB.
- The configurable pool's minimum (1 GiB) still holds, and no static assert changes.

**What the stock 16 GiB regions were [S].** Each PartitionAlloc instance makes a second, unaligned
reservation: the external metadata region. Its size is `max(core pool, configurable pool)`, which is
`kPoolMaxSize`, 16 GiB (`partition_address_space.h:298-304`).

- `move_metadata_outside_gigacage=false` removes it; metadata then lives in the super pages.
- gin's configurable pool exists only inside the V8 sandbox (`gin/v8_initializer.cc:606-631`), so
  with the sandbox off it is gone too.

**The build fix.** The first build stopped on two files, both from the allocator shim's Windows-heap
path:

- `allocator_shim_default_dispatch_to_winheap.cc` fills a dispatch table that has gained fields.
- `memory_win.cc` calls `allocator_shim::UncheckedAlignedAlloc`, which is declared only with PartitionAlloc as malloc.

Chromium never builds the shim without PartitionAlloc-as-malloc on Windows: its Windows debug and
component builds turn the shim off (`build_overrides/partition_alloc.gni`). We do the same with
`use_allocator_shim=false`, so malloc is the CRT heap.

Turning V8's sandbox and pointer compression off needed no fix. The iOS-shaped sandbox fallback is not
needed.

**Outputs** (`$PLAYPORT_BUILD/cef-src/out-stage-c`; 233 files, list in `cef-src/logs/out-stage-c.sha256`):

| File | Size | sha256 |
| --- | --- | --- |
| Release/libcef.dll | 256,374,784 | a07bb71d9f92f35222a7f2f19e778183167eb332beb4fcb655dca2aa62c19c9e |
| Release/chrome_elf.dll | 1,259,520 | 6ceaf1f1afa9dd96d8ec2b9082c3fe6e180c3960e3cc579bc13abf7c1aa67367 |
| Release/v8_context_snapshot.bin | 902,716 | ab1090ad4b547fbd8047001f657ca1af6c15d871ccfbb40ff76b2b708f0ad99f |
| Release/libEGL.dll | 491,520 | a2d1f7efdbe4ecb3c7f6b1d6f12be47ff05105b4005401a1cffd0ba2ce6dcb5f |
| Release/libGLESv2.dll | 8,459,776 | 91c201d398e97db086280c9389f6791de0b02a0f268866495047e17cc6c4e455 |
| Release/vk_swiftshader.dll | 5,469,696 | 551e17c046552b2bda183f7694cd5ce5341ff92a33441895fcf7b5c6a0b324b4 |
| Release/vulkan-1.dll | 917,504 | 12c4cfd49fda76475cde9f95e4df6aaae5dda234c2736ac237b73f7fd7b191b2 |

- resources.pak, chrome_100/200_percent.pak, icudtl.dat and the 220 locales are byte-identical to
  stage B's.
- libcef and chrome_elf are PE32+ x86-64 DLLs. Their export names (244 and 29) and imports match
  stage B's.
- The snapshot is larger than stage B's (711,346 bytes), as expected without pointer compression.

## Swap test

The procedure is stage B's ([CEF swap test](2026-10-16-cef-swap-test.md#our-stock-args-build-in-place-of-social-clubs-pla-370-stage-b-exit)):

- Proton 10.0 on sway, with `lsteamclient`/`steamclient`/`steamclient64` disabled;
- an empty `STEAM_COMPAT_CLIENT_INSTALL_PATH` and `TMPDIR` under `$PLAYPORT_BUILD`;
- the owner's-Steam guard;
- `WINEDEBUG=+pid,+virtual,+process,+loaddll`.

The trace filter now records every reservation of 64 MiB or more (it was 1 GiB).

The scratch prefix's Social Club folder matched its 81-file sha256 list before the runs. We copied in
our libcef, chrome_elf, snapshot, ANGLE, SwiftShader, vulkan-1, paks, ICU and locales, and kept
Social Club's d3dcompiler/dxcompiler/dxil and the Rockstar files. Afterwards the originals were put back,
and the list matched again (81 files). The original prefix was not touched.

| Run | Switches | Sign-in page | Social Club states (ms from SDK start) | Launcher: Init phase 3 → WaitForWindow / Active |
| --- | --- | --- | --- | --- |
| lowva1 | none | yes, in all 5 screenshots (30–150 s) | `WAIT_BROWSER_WINDOW` 45 → connected 314 → `LOADING` 480 → `WAITING_FOR_PAGE_READY` 2,319 → `PAGE_READY` 2,471 → `FINISHED` 2,483 | 2.5 s / 4.0 s |
| lowva-0109 | `--in-process-gpu --disable-gpu --disable-gpu-compositing --js-flags=--jitless` | yes, in all 5 screenshots | `WAIT_BROWSER_WINDOW` 41 → connected 310 → `LOADING` 474 → `WAITING_FOR_PAGE_READY` 2,296 → `PAGE_READY` 2,414 → `FINISHED` 2,426 | 2.5 s / 3.6 s |

- The switches went in through stage R's measurement wrapper, which adds them to the browser's command
  line (as in the [recon](2026-10-15-rockstar-launcher-recon.md)). The renderers' command lines carry
  `--js-flags=--jitless`. The wrapper was removed afterwards.
- The module list reads "Chromium Embedded Framework (…\libcef.dll) - 143.0.14.0", and there is no
  `SC_INIT_ERR`.
- The screenshots show the Rockstar logo, "Sign In" with the Email and Password fields, and the cookie
  notice with "Accept all cookies", "Reject all" and "Cookie settings". They are kept under
  `$PLAYPORT_BUILD`. We did not sign in.
- The page was ready about 20 times sooner than in the stage B runs (51.8 s). We did not establish
  why. The one stage R log also shows about 2.5 s, so the page's network load, not the build, is the
  likely cause [I].
- **Process tree.**
  - lowva1: the same 9 processes as stock (browser, GPU, network, storage, audio, video capture and
    3 renderers), plus the short-lived `ProcessorMetrics` utility and the GPU-info process.
  - lowva-0109: no GPU process, so 8 at steady state, plus `ProcessorMetrics`.
  - Our libcef.dll loaded natively 11 and 9 times.
- **Errors.** No exception, breakpoint or backtrace appeared in any CEF process. The `err:` lines are
  the usual prefix noise (openxr, ntlm/kerberos, RoGetActivationFactory, ole marshal, ZwLoadDriver).
  The one stack overflow is Proton's `xalia.exe`, as in the earlier runs.

## Reservations of 64 MiB or more (+virtual)

The table shows sizes in MiB. Alignment is the observed alignment of the address. Every listed
reservation came after libcef.dll loaded.

| Process | Held at the end | Total |
| --- | --- | --- |
| browser, GPU, network, storage, audio, video capture, ProcessorMetrics, GPU-info | **none** | 0 |
| renderer 1 | 2,048 @2 GiB; 256 and 128 (`MEM_RESERVE_PLACEHOLDER`); 512 (a worker's 512 MiB was released) | 2.88 GiB |
| renderer 2 | 2,048 @2 GiB; 256; 128; 512 | 2.88 GiB |
| renderer 3 | 2,048 @8 GiB; 256; 128; 4 × 512 | 4.38 GiB |
| **tree (9 processes)** | | **10.12 GiB** |

The 0109 run has the same reservations, with the same 2.88 / 2.88 / 4.38 GiB, also 10.12 GiB.
`--js-flags=--jitless` does not remove the 512 MiB regions.

What each region is:
- **2 GiB:** PartitionAlloc's glued pools [S]. Only renderers create a PartitionAlloc root, for Blink's
  and gin's partitions. Its address is aligned to 2 GiB.
- **512 MiB per V8 isolate:** the code range. Without pointer compression each isolate gets its own
  (`kMaximalCodeRangeSize`, `globals.h:476-479`). The first try is at a hint near libcef's image and
  fails; it then lands anywhere, with 64 KiB alignment. Each web worker adds one, which is why
  renderer 3 holds four [S][I].
- **256 MiB and 128 MiB placeholders:** by size, V8's JSDispatchTable (`globals.h:561`) and code
  pointer table (`v8-internal.h:804`) [I].
- **Gone:** the 32 GiB pools and 16 GiB metadata in every process, the renderers' cppgc cage
  (32 GiB), the 1,320 GiB sandbox placeholder with its 4 and 16 GiB carves, and the 1 GiB trusted range.

**Against the budget.** The phone's Windows window is [0x70, 0x80) × 2^32; FEX uses [0x7c, 0x80), so 48 GiB
are usable, beside Wine.

- The tree's large reservations total 10.1 GiB. The only aligned demand is one 2 GiB-aligned 2 GiB
  block per renderer.
- If a renderer's 2 GiB request misses its hints, PartitionAlloc reserves size + alignment, so it
  needs a 4 GiB hole for a moment.
- First-fit packing into [0x70, 0x7c) (`vtotals.py`, aligned blocks first, a 1 GiB-or-larger block
  aligned to its size) fits with 0, 8, 16, 24, 32 or 36 GiB of Wine placed at 0x70. 1.9 GiB are left
  at 36 GiB.
- That is within the plan's estimate (about 2.5 GiB per renderer and 0–2 GiB per other process).
  The renderers cost a little more, because of the code ranges.
- Not in this count:
  - DLL images, libcef.dll above all (245 MiB per process: about 2.2 GiB for 9 copies, unless the
    image is shared);
  - reservations under 64 MiB;
  - thread stacks;
  - the 0.5 GiB code range of each further worker;
  - Wine's and FEX's own use.
- If the code ranges matter on the phone, shrinking them is another source change: the size is the
  embedder's `ResourceConstraints` code-range size, not a V8 flag [S][I].

## Not checked

- The phone: footprint, image sharing, FEX start-up time against Social Club's 30 s timeout
  ([PLA-371](https://linear.app/playportdev/issue/PLA-371)), and whether V8's code range finds room.
- Behaviour beyond the sign-in page. With 1 GiB pools a renderer's PartitionAlloc heap is limited to
  1 GiB per pool.
- IPA delivery and loader substitution: stage D below formalizes the inputs only.

## Stage D slice 1: formal build inputs (host only)

The stage A–C scratch changes are now one `patches/cef` format-patch and six
`patches/chromium` format-patches, with the required trailers. The Chromium series
applies **after CEF's 107 stock patches**; nested ANGLE/Dawn changes use paths rooted
at Chromium src and remain DEPS-pinned. CEF and Chromium now have `pins.lock` rows.
`build/cef/README.md` records the replay order and standalone build adapters.

Validation (no changes to the live CEF build tree or outputs):

- Reconstructed the post-stock-patch baseline of the touched files in scratch,
  then applied each formal patch in order: **14/14 files byte-identical** to the
  stage C sources (2 CEF, 12 Chromium/ANGLE/Dawn).
- Composed each series as a single diff and ran `git apply --reverse --check`
  against the live tree: passed. Passing multiple overlapping patches to one
  `git apply --check` does not model sequential application, so the composed
  diff is used for this read-only check; forward replay checks each patch.
- Committed GN settings equal stage C's, apart from the two local layout paths
  generated by the wrapper. No real GN/ninja build or layout generator was run.
- `build/generated/cef-143.0.14.sha256`: all **233 files**, **347,103,077 bytes**,
  verified against `out-stage-c`. Record sha256:
  `9572ae94dd7faae01a8875a3db29e31515aaae7484adf7900b68e317143e9f93`.
  Runtime files excluding the import library total **347,037,585 bytes**; this
  is not an IPA growth measurement.
- New host tests cover payload success, missing/mismatched files, malformed,
  empty, duplicate and unsafe record paths, wrapper producer exit statuses,
  argument generation and discovery of the two new patch-series directories.
  Focused tests: 52 passed. `pp test --quick`, `pp names`, `pp secrets` passed.
- The owner approved a narrow name-gate exception for the two exact upstream
  GN argument/helper tokens inside these two patch series only. Both `pp names`
  and the source-payload audit use the shared rule. Tests cover index/commit and
  archive paths: the retired name, other prefix words, token suffixes and uses
  outside these series still fail. Patch applications pass `--whitespace=error`;
  non-patch files pass `git diff --check` (format-patch blank context lines are
  not trailing-whitespace defects in upstream source).

No payload is packed yet, and no runtime code changed. Required CEF/Chromium
notices are not in the stage C output record and must be supplied before dev
packing. Release delivery is not approved. No IPA, Hollow Knight or phone Open
was run in this slice; there is no phone result or IPA hash for it.
