# Our own low-address-space CEF for Social Club

**Linear:** [PLA-370](https://linear.app/playportdev/issue/PLA-370) (blocks
[PLA-369](https://linear.app/playportdev/issue/PLA-369); parent
[PLA-254](https://linear.app/playportdev/issue/PLA-254)).
**Decision:** [0110](../decisions/0110-own-cef-build-for-a-clients-cef.md) (accepted).
**Status:** written 2026-10-16; the owner approved it the same day, with D1–D6 as recommended. Stage A is next.

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
- At load time (madeira-unix), when a process's `libcef.dll` beside its image has the exact built
  version, the loader maps Playport's `libcef.dll` and `chrome_elf.dll` instead, along with the
  data files that must match: the snapshot, `resources.pak`, ICU and locales. Every case logs a
  `[cef-swap]` line; any other version is left alone.
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
| D2 | Add CEF and Chromium as pinned components with patch series (`pins.lock`, `patches/cef`, `patches/chromium`) | Yes; same model as Wine, FEX and DXMT |
| D3 | Delivery: ship the CEF payload in the IPA (about +300 MB uncompressed; compressed size to be measured) or make it an optional part of the IPA built only for dev until Stage D passes | Dev-only payload until Stage D passes, then decide for release by size |
| D4 | Security: Social Club's pages run without the V8 sandbox, on an unsupported branch | Accept for Rockstar's own pages only. The substitution covers only the exact client version, and the client loads only Rockstar's sites |
| D5 | Updates: rebuild for each Social Club CEF version; the launcher is broken between an update and the rebuild | Accept; record each rebuild as evidence |
| D6 | You sign in on the phone at Stage E | As before: in person; agents never hold the password |

## Progress

- 2026-10-16: the owner approved D1–D6 as recommended. The xwin licence is still to be accepted by the owner in person at stage A step 2. Stage A started.
- 2026-10-16: stage A bootstrap checked out depot_tools and CEF `dd46a3761`, completed the pinned Chromium/Windows-deps sync with a disk watchdog, and fetched xwin 0.10.0. Owner licence acceptance remains pending; toolchain layout and `gn gen` have not run. Successor commands and live-process records: `.work/agent-notes/pla370-cef/PROGRESS.md`.
- 2026-10-16: the owner accepted the Microsoft licence in person and ran the xwin splat command. It wrote the CRT and SDK (644 MB) to `$PLAYPORT_BUILD/cef-src/tools/xwin-sdk`.

## Risks

- The untested build combination may need several Chromium patches, or prove too costly.
- xwin is not supported by Chromium or CEF; missing pieces (ATL, redistributables, `.asm` files) may
  need workarounds.
- Wine's placement may fragment the 2 GiB-aligned holes the pools need.
- Footprint: each process maps its own copy of `libcef.dll` (about 240 MB), and 9 processes on the
  phone may exceed the memory limit even when the address space fits. Stage D measures this.
  Sharing one image is a follow-up.
- Rockstar may change CEF versions often.
