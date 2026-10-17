# Our own low-address-space CEF for Social Club

**Linear:** [PLA-370](https://linear.app/playportdev/issue/PLA-370) (blocks
[PLA-369](https://linear.app/playportdev/issue/PLA-369); parent
[PLA-254](https://linear.app/playportdev/issue/PLA-254)).
**Decision:** [0110](../decisions/0110-own-cef-build-for-a-clients-cef.md) (accepted).
**Status:** stages A–C passed. Stage D delivery and substitution work; Social Club reaches `FINISHED`, but the sign-in page is not yet visible because the JIT pool and band fill. Latest evidence: [fewer processes](../evidence/2026-10-16-cef-fewer-processes-phone.md).

## Current handoff and ordered queue

- **Checkout:** `dev/pla-291-rockstar-launcher`, baseline `9192531`, not merged or pushed.
- **Completed:** `ae4d7cb` / `9192531`, decision 0111, [PLA-378](https://linear.app/playportdev/issue/PLA-378): network and video capture in-process. Desktop sign-in works (8 → 6 CEF processes). Phone IPA `887442a3…`, Open `20261016T203152`: `FINISHED` at 8.2 s, then pool exhaustion (head 524 MB / tail 373 MB); band peak 16,227 MB. Hollow Knight first frame +9.98 s (`20261016T203027`).
- **Owner-approved next work:** V8 code-range patch **and** launcher-only FEX helper cap; no shared-code redesign or larger pool. Implementation initially `openai-codex/gpt-6-astra:high`; after its quota failure the owner explicitly selected `openai-codex/gpt-6.1-sol:high` to finish PLA-379 and continue PLA-380. Focused fresh-context reviews also use 6.1 Sol high. Stop and report quota failures; do not silently substitute models.
- **Ordered queue:**
  1. [PLA-379](https://linear.app/playportdev/issue/PLA-379): omit unused V8 code ranges for jitless isolates in our CEF; incremental build and desktop swap/reservation checks. Preserve non-jitless behavior and update matching payload records. No phone run in this chunk.
  2. Focused review, then [PLA-380](https://linear.app/playportdev/issue/PLA-380): launcher-only per-helper FEX code-buffer cap (initial target about 32 MiB, subject to safe allocator semantics); record the decision and keep game defaults unchanged.
  3. Build/install and Hollow Knight on the exact IPA; one bounded Rockstar Open with both changes. Stop for a new blocker, no sign-in or RDR2. Stage E still needs the owner in person.
- **Handoff after quota failure:** resumed Astra run `7de608f9-9793-42a9-a173-71ec9389d36c` stopped mid-PLA-379. No implementation commit yet. It left Chromium patch 0007 and its series entry uncommitted. No matching build, probe or desktop-run process remained at supervisor inspection. Owner selected 6.1 Sol high for the successor; run ID to be recorded by that writer. PLA-380 remains queued.
- **Recovery and partial validation:** the abandoned libcef record edit was discarded after saving its diff. Private reconstruction reproduced 422 files from pins, 107 CEF stock patches and the formal series; the rebuilt baseline reproduced approved libcef `a07bb71d…`. Patched incremental build exited 0. Native allocation checks report baseline jitless holds 512 MiB, patched jitless 0, non-jitless 512 MiB in both; five upstream resource-constraints tests passed. These are worker-reported, awaiting review. No JavaScript execution claim (the host harness trapped on execution even for baseline). SnapshotCreator test setup failures are not runtime acceptance. Baseline and original-files controls under Xvfb failed before renderers (`C0000094`); sway was reported restored by owner but comparison is not yet done. Matching new payload assembly/records, desktop acceptance, evidence and commits remain. See `.work/agent-notes/pla370-cef/PROGRESS.md` and `.work/agent-notes/pla379-recovery/`.
- **Phone:** attended at the last run, 80% charge and 4.2 GB free then; recheck before device work. Latest installed IPA `887442a3…`. RDR2 and Hollow Knight remain installed; never uninstall. Launcher runtime setting was cleared after the run; LocalDevVPN failures require the owner. No unattended-mode change requested.
- **Build-area handoff:** `.work/agent-notes/pla370-cef/PROGRESS.md`, `reports/pla378-fewer-processes.md`; [PLA-377](https://linear.app/playportdev/issue/PLA-377) research at `.work/agent-notes/pla377-pool-copies/report.md` (read-only findings, no sharing implementation approved).

**Counting correction:** PLA-374's eight 512 MB V8 allocation requests included failed retries; renderer 1 held two code ranges, not eight. Savings must be measured from successful held reservations.

## Goal

Social Club's Chromium (CEF 143.0.14) runs on the phone. That covers the Rockstar Games
Launcher's UI up to its sign-in page, and later RDR2's in-game overlay. The route is a same-revision
CEF built by Playport, loaded in place of Rockstar's. Rockstar's files are unchanged, and nothing is
patched in memory.

## What is known

- **The phone.** Every CEF process reserves 2 × 32 GiB aligned pools plus 2 × 16 GiB. Renderers add
  a third pool and a 1,320 GiB V8 sandbox placeholder. The phone's usable window is about 48 GiB
  ([chunk 9](../evidence/2026-10-15-rockstar-stage0-phone.md),
  [swap test](../evidence/2026-10-16-cef-swap-test.md)).
- **The tree at the sign-in page:** browser, GPU, network, storage, audio and video capture, plus
  3 renderers. That is 9 processes, or 8 with 0109's switches (GPU in-process). The game's own
  Social Club runs 5.
- **Acceptance.** A stock CEF of the same version, swapped in under desktop Proton, reached the
  sign-in page, and nothing refused it.
- **The configuration** (research in `$PLAYPORT_BUILD/agent-notes/pla254-rockstar/reports/research-pla369-cef-opensource.md`):
  - `kPoolMaxSize` at 1 GiB, through a source patch;
  - `use_partition_alloc_as_malloc=false`, `enable_backup_ref_ptr_support=false` and
    `move_metadata_outside_gigacage=false`;
  - `v8_enable_sandbox=false`, `v8_enable_pointer_compression=false` and
    `cppgc_enable_caged_heap=false`.

  That should cost about 2.5 GiB per renderer and 0–2 GiB per other process, so 13 processes need
  15–29 GiB. Nobody tests this combination on Windows x64.

## Stages

Each stage ends with a commit, evidence and Linear updates. Stages A–C are host-only.

**A. Toolchain and sources.**
1. depot_tools, then the CEF 7499 checkout at `gdd46a37` with its Chromium `143.0.7499.193`, under
   `.work/cef-src`. It needs 150–200 GB; 662 GB are free.
2. xwin downloads the MSVC CRT and the Windows SDK 10.0.26100, after the owner accepts Microsoft's
   licence in person.
3. Build the `win_sdk/bin/SetEnv.x64.json` layout Chromium's `setup_toolchain.py` reads.
4. Patch CEF's automation, build-argument and gclient-hook scripts so they target `win` from a
   Linux host.

Exit: `gn gen` succeeds for a stock-args Windows x64 CEF.

**B. A stock-args build, to prove the toolchain.**
- Build `libcef.dll`, `chrome_elf.dll` and the data files with CEF's default args, which takes
  4–8 h.
- Then rerun the swap test with our build in place of Spotify's.

Exit: the launcher reaches its sign-in page under desktop Proton with our stock build. If it fails,
the fault is in the toolchain, not in Rockstar's acceptance.

**C. The low-address-space build.**
- The settings and patch above, in `patches/chromium/` and `patches/cef/` with the usual trailers.
  The pins go in `pins.lock`; adding the component is part of accepting 0110.
- Fix what the untested combination breaks, each fix as a patch.
- Under desktop Proton, using the swap-test procedure: the sign-in page is reached, and a
  `+virtual` trace shows every process's large reservations fit the budget.

Exit: the trace totals for the 9-process tree fit within 48 GiB, less Wine's use, with 2 GiB-aligned
holes. If 1 GiB pools run out of memory on the launcher's pages, use 2 GiB.

**D. Playport loads it.**
- At open time (patches/wine-unix, Wine's `dlls/ntdll/unix/file.c`), when the `libcef.dll` in a
  CEF file's directory has the exact built version, the file is opened from Playport's build
  instead: `libcef.dll` and `chrome_elf.dll` along with the data files that must match: the
  snapshot, the paks, ICU and locales (and the GL/Vulkan DLLs). Every case logs a `[cef-swap]`
  line; any other version is left alone. As built, the hook is in Wine's file layer rather than
  Madeira's loader (madeira-unix), because both the DLL images and the memory-mapped data files
  are opened by name there; a swap at section creation would leave the handle, and the size
  Chromium reads from it, on the client's file. The guard is `app/Sources/WineHost/cef_swap.c`.
- Delivery is the open question D3 below.
- A host test for the version guard.
- The Hollow Knight gate.

Exit: the phone's Open reaches the Social Club sign-in page. Record the pool, band and footprint per
process, and whether libcef's image is shared or copied per process.

**E. On to the game.** The owner signs in on the phone (D6). Then the launchers plan resumes at
Stage 1/2 (PLA-295): RDR2's own Social Club through the same substitution, and closing the launcher
at hand-off.

**Prerequisite outside this plan.** The self-update needs the FEX self-modifying-code fix (PLA-367:
the PLA-206 deadlock, then FullSMC for hot pages, the owner's choice). Until then, phone runs use
the dev-only `env.FEX_SMCCHECKS=none`.

## Owner decisions

| | Question | Recommendation |
| --- | --- | --- |
| D1 | Accept decision 0110: our own CEF build, loaded in place of a client's of the exact same version | Accept, so stages A–C can run |
| D2 | Add CEF and Chromium as pinned components with patch series (`pins.lock`, `patches/cef`, `patches/chromium`) | Yes; pins and format-patch series, but as built CEF is a separately verified prebuilt input, not checked out or replayed by `pp build` or `pp sync` (`build/cef/README.md`). |
| D3 | Delivery: ship the CEF payload in the IPA (about +300 MB uncompressed; compressed size to be measured) or make it an optional part of the IPA built only for dev until Stage D passes | Owner-only dev payload until Stage D passes, then decide for release by size. Not yet distributable: [PLA-372](https://linear.app/playportdev/issue/PLA-372) must add CEF/Chromium and their series to `pp source` and meet the rebuild/FFmpeg relinking duties before any release or tester copy ([LICENSING](../LICENSING.md), [DISTRIBUTION](../DISTRIBUTION.md)). |
| D4 | Security: Social Club's pages run without the V8 sandbox, on an unsupported branch | Accept for Rockstar's own pages only. The substitution covers only the exact client version, and the client loads only Rockstar's sites |
| D5 | Updates: rebuild for each Social Club CEF version; the launcher is broken between an update and the rebuild | Accept; record each rebuild as evidence |
| D6 | You sign in on the phone at Stage E | As before: in person; agents never hold the password |

## Progress

- 2026-10-16: the owner approved D1–D6 as recommended. The xwin licence is still to be accepted by the owner in person at stage A step 2. Stage A started.
- 2026-10-16: stage A bootstrap checked out depot_tools and CEF `dd46a3761`, completed the pinned Chromium/Windows-deps sync with a disk watchdog, and fetched xwin 0.10.0. Owner licence acceptance remains pending; toolchain layout and `gn gen` have not run. Successor commands and live-process records: `.work/agent-notes/pla370-cef/PROGRESS.md`.
- 2026-10-16: the owner accepted the Microsoft licence in person and ran the xwin splat command. It wrote the CRT and SDK (644 MB) to `$PLAYPORT_BUILD/cef-src/tools/xwin-sdk`.

- 2026-10-16: stage A passed: Windows x64 official-mode project generation (35,979 targets) and a one-object CRT/SDK compile-and-link smoke test succeeded on Linux. Scratch toolchain adapters and exact arguments are under `$PLAYPORT_BUILD/agent-notes/pla370-cef/`; PGO is off, the context snapshot is on, and stage B has not started.
- 2026-10-16: stage B built the stock Windows x64 CEF on Linux with ninja exit 0. It needed five more scratch adapters: rc include flags, empty UCRT warning macros, `/ignore:4099`, no Dawn dxcompiler build dependency, and gperf plus a clean python venv.
  - libcef.dll and chrome_elf.dll are PE32+ x64. Their export names and imported DLL names match the stock distribution's.
  - The data files are built. icudtl.dat is identical; resources.pak lacks only the WebUI code cache, which upstream disables on cross-builds.
  - The swap-test tree is `$PLAYPORT_BUILD/cef-src/out-stage-b`. Nothing has run yet.
- 2026-10-16: stage B passed its exit test. Under desktop Proton, with our build in place of Social Club's CEF files, the launcher reached its sign-in page: the same UI states, process tree and reservation shape as the stock build, no `SC_INIT_ERR`, and `FINISHED` 51.8 s after init phase 3 (stock 50.7 s, original 47.6 s). Evidence: [CEF swap test](../evidence/2026-10-16-cef-swap-test.md#our-stock-args-build-in-place-of-social-clubs-pla-370-stage-b-exit).
- 2026-10-16: stage C passed on the desktop. The low-address-space build (the plan's six args, a `partition_alloc_low_va` PartitionAlloc flag for 1 GiB pools, and `use_allocator_shim=false`, because the shim without PartitionAlloc-as-malloc does not compile on Windows) built with ninja exit 0.
  - Swapped in under desktop Proton, it reached the sign-in page both without switches and with 0109's switches.
  - The 9-process tree holds 10.1 GiB of reservations of 64 MiB or more: none outside the renderers, 2.9–4.4 GiB per renderer, the largest 2 GiB aligned to 2 GiB.
  - Evidence: [low-VA CEF build](../evidence/2026-10-16-cef-low-va-build.md).

- 2026-10-16: stage D slice 1 formalized the stage A–C sources: CEF/Chromium pins, one CEF and six Chromium format-patches (including DEPS-pinned ANGLE/Dawn), and the separate cross-build adapters under `build/cef/`. Replay reproduces all 14 touched source files byte-for-byte. `build/generated/cef-143.0.14.sha256` records the 233-file prebuilt input; its verifier and host tests pass, as does `pp test --quick`. Packing, required notices, the loader swap, IPA measurement, Hollow Knight and phone Open are not done. No runtime or phone changes in this slice.
- 2026-10-16: stage D slice 2 packs the verified payload into the dev IPA only (`Runtime/cef/143.0.14/`, the import library omitted; `pp verify` checks its exact set in dev and rejects it in release and `--distribution`), with notices generated from the pinned tree: Chromium's credits, CEF's BSD licence, FFmpeg's licence and LGPL-2.1, and a build notice on the statically linked MSVC CRT. Review findings F1–F11 of `654c954` are fixed. Not distributable until PLA-372.
- 2026-10-16: stage D on the phone (dev IPA `2eefce7e…`, +151 MB compressed). Wine's file layer (wine-unix 0039) opens Playport's CEF files in place of Social Club's after an exact 143.0.14.0 version check. Hollow Knight still reaches its first frame. In the Open, the helpers got past `chrome_elf.dll`, and Social Club reached `LOADING` and `WAITING_FOR_PAGE_LOAD`. Then the browser and its services ended in a stack overflow after a null-pointer fault in Wine's `secur32` (no LSA pipe), so the sign-in page was not reached. Evidence: [CEF on the phone](../evidence/2026-10-16-cef-low-va-phone.md).
- 2026-10-16: PLA-373: the `secur32` fault came from a full FEX alias table. Wine pushes every process's images to every emulator, whose table held 256 against Wine's 512, so the CEF services' late `secur32` delay-load thunks could not be translated. `patches/fex` 0046 and madeira-unix 0155 set both tables to 1024 and keep them in step. On the phone (dev IPA `a2a89967…`, Hollow Knight first frame +10.17 s), the services now pass `secur32`. The sign-in page is still not reached: the browser's main thread overflows its stack in Chromium's default-font recursion when Skia can create no typeface. Evidence: [alias table on the phone](../evidence/2026-10-16-alias-table-cap-phone.md).
- 2026-10-16: PLA-374: Skia found no typeface because Wine's DirectWrite collection was empty on the phone. Wine's `dwrite` reads only the files named in the HKLM `Fonts` key, and the prefix seed named no TrueType face; the shipped Tahoma faces were only linked into `C:\windows\fonts` for GDI. The seed now registers both faces. On the phone (dev IPA `6ff8e726…`, Hollow Knight first frame +10.18 s), the browser starts its services and two renderers, d2d draws text without failures, and Social Club reaches `PAGE_READY`, `START_SIGN_IN` and `FINISHED` at 8.2 s. It loses the browser 1 s later, when the second renderer finds the 896 MiB JIT pool full, so the sign-in page was not seen on screen. Evidence: [CEF fonts on the phone](../evidence/2026-10-16-cef-fonts-phone.md).
- 2026-10-16: PLA-378 (owner's choice, decision 0111): a CEF browser also gets `--enable-features=NetworkServiceInProcess2,RunVideoCaptureServiceInBrowserProcess` (madeira-unix 0156). Under desktop Proton, Social Club runs 6 Chromium processes instead of 8 and still shows its sign-in page; storage and audio have no usable switch, and `--renderer-process-limit=1` has no effect. On the phone (dev IPA `887442a3…`, Hollow Knight first frame +9.98 s), the network and video capture services are gone and Social Club reaches `FINISHED` at 8.2 s without losing its browser. But the second renderer now lives, and the 896 MiB pool fills again (head 524 MB, tail 373 MB), as does the band (peak 16,227 / 16,384 MB). The first audio service cannot load and is restarted about 50 times. The sign-in page was not on screen. Evidence: [fewer CEF processes on the phone](../evidence/2026-10-16-cef-fewer-processes-phone.md).

## Risks

- **V8's sandbox must be off on the phone, not just for cost.** Stock V8 checks
  `CHECK_LT(kSandboxSize, address_space_limit)` (`v8/src/sandbox/sandbox.cc:114`). The limit comes
  from the reported top of the address space, which ml990 clamps to 512 GiB, so the 1 TiB sandbox
  aborts every renderer before V8's partial-reservation fallback.
  - If `v8_enable_sandbox=false` proves unbuildable, the fallback is a V8 source patch in our build
    (the iOS shape, `kSandboxSizeLog2 = 34`, with an 8 GiB partial reservation, at least 8 GiB per
    renderer). It is not a Wine shim hiding `VirtualAlloc2`/`MapViewOfFile3`/`UnmapViewOfFile2`:
    that leaves PartitionAlloc untouched and still trips the check.
  - Review: `$PLAYPORT_BUILD/agent-notes/pla370-cef/reports/review-external-v8-fallback.md`.
- **Rockstar's ~30 s browser timeout** counts from "Init phase 3"
  ([PLA-371](https://linear.app/playportdev/issue/PLA-371)). The helper has to start under FEX
  within it. If Stage D times out at `WAIT_BROWSER_WINDOW`, check helper start-up first, including
  `MMDeviceEnumerator` activation (ValveSoftware/Proton#3291).
  - The phone also shows an unexplained 39 s pre-init gap.
  - If 0109's `--disable-gpu` path fails to render, the alternative is
    `--use-gl=angle --use-angle=swiftshader`.
- The untested build combination may need several Chromium patches, or prove too costly.
- xwin is not supported by Chromium or CEF; missing pieces (ATL, redistributables, `.asm` files) may
  need workarounds.
- Wine's placement may fragment the 2 GiB-aligned holes the pools need.
- Footprint: each process maps its own copy of `libcef.dll` (about 240 MB), and 9 processes on the
  phone may exceed the memory limit even when the address space fits. Stage D measures this.
  Sharing one image is a follow-up.
- Rockstar may change CEF versions often.
