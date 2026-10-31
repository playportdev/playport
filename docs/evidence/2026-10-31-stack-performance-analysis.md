# Stack performance on iOS: KosmicKrisp, FEX, Wine and the rest — gathered evidence (PLA-541)

**Linear:** [PLA-541](https://linear.app/playportdev/issue/PLA-541). **Purpose:** the data a spec will be written from.
This record gathers and checks; it proposes no fixes and changes no default.
**Question:** where does the stack spend CPU it should not (bugs, or a design that does not fit the phone), how far is
KosmicKrisp (KK) behind DXMT and what explains it, and how far is the phone from its raw power?

**Device:** iPhone Air (iPhone18,4), iOS 27.2, external power at 80 %. **IPA:** dev
`2435c5ba13b527243bd570874cc06462466f391bbfa27d515a1a865b1ef973f3` (branch `dev/pla-541-stack-perf`, commits
`09e9325`, `85c863d` on `183d085`): the build every 2026-10-31 run used unless a row names `d3be12c9`
(`d3be12c9…`, `074e49a`, the build installed before). **Mac:** macOS 27.2, Xcode 27.1 (decision 0165).

**How it was gathered.**
- **Code reading:** 13 analysis items over the built trees and the patch series. They covered KosmicKrisp's command
  recording, descriptors, compiler, sync and memory; all 105 `patches/mesa` patches; DXVK and vkd3d-proton feature fit;
  FEX; Wine; plus two syntheses of earlier evidence, a re-cut of the Mac's earlier traces and a raw-power reference.
  Ten of the headline claims were then checked by separate refutation passes; corrections from those are folded in
  below. Notes per item: `$PLAYPORT_BUILD/agent-notes/pla541/*.md`.
- **Phone, 2026-10-31** (`$PLAYPORT_BUILD/perf/pla541/`, Hollow Knight `app-367520`, King's Pass route
  `hk-new-game` at first frame +25, `hk-walk` at +80, 130 s, cooled 15–25 min):
  - session 1: KK levers one run each, a DXMT run, two KK controls, HUD arms;
  - session 3: a clean DXMT/KK ABBA with no HUD loaded, `--cpu-prof` and `--pass-prof` per backend;
  - Mac: Time Profiler (720/60) and Metal System Trace (native, uncapped) per backend
    (`.work/gpu-runs/pla541/` on the Mac).
- Witcher 2 (broken, PLA-478) was uninstalled first: free space went from 3.69 to 23.5 GB, so FEX's disk cache is no
  longer deleted before each launch (finding C1).

**Not gathered:** a serial GPU-counter replay of the two King's Pass captures (`pla439-dxmt-2`, `pla439-vk-1`):
`gpucapture` does not list the phone unless it is cabled to the Mac. It was on the network only.

## Part A. The phone's raw power against what games get

Reference figures are from web sources (URLs in `$PLAYPORT_BUILD/agent-notes/pla541/raw-power.md`); ratios are ±50 %.

| | iPhone Air (A19 Pro, 5-core GPU) | Steam Deck |
|---|---|---|
| CPU | 2 P cores at 4.26 GHz + 4 E cores at about 2.6 GHz; Geekbench 6: 3029 / 8441 | about 1300 / 4400 |
| GPU | about 2.07 TFLOPS FP32; 3DMark Steel Nomad Light 1738, stability 73–81 % | 1678 |
| Memory | about 68 GB/s (LPDDR5X; reported, not confirmed by Apple) | 88 GB/s |
| Sustained | whole phone 4.2–4.6 W in throttled play | |

- **GPU:** roughly a Steam Deck at peak, about 0.8 of one sustained.
- **CPU:** once the SoC's power budget (CPMS) clamps — at 51–62 s in every native run today, `budget_first_s` — the
  game runs on the 4 E cores, at 0.8–1.7 GHz. That is about 0.4–0.6 of a Deck before FEX's translation cost and
  0.25–0.4 after it [INFERENCE].

**Gap per title**, from earlier evidence (GPU time × peak TFLOPS against a reference device):

| Title (backend) | Observed | Reference | Gap | Limited by |
|---|---|---|---|---|
| Death's Door (DXMT) | 39.9 fps mean at 1564×720, GPU 25–30 ms (10-06) | Switch 1 about 30 fps at about 720p on 0.16–0.39 TFLOPS | about 3–4× on the GPU | GPU |
| Hollow Knight (DXMT) | 5.1 ms GPU at 720 rows, 2.5 ms of it fixed (09-25) | Switch 1 holds 720p60 on 0.157 TFLOPS | about 3–4× on the GPU | GPU fixed cost |
| RDR2 (KK) | 16.6 fps, 26 ms GPU, GPU 43 % busy, 640×360 internal (10-21) | Deck 45 fps at 800p Low | about 2.7× in fps | CPU under the clamp |
| The Witcher 3 4.x (vkd3d + KK) | 17.8 fps hot, 44 ms GPU (10-27/28) | Deck about 30–40 fps at 800p Low | about 1.7–2.2× in fps | CPU, then GPU |

Pattern:
- Light titles lose on fixed GPU cost per frame.
- Heavy titles are CPU-bound once the clamp leaves only the E cores.
- No title reaches the phone's sustained GPU.

## Part B. KosmicKrisp against DXMT, measured today

### B1. Clean ABBA (session 3; no HUD loaded in any arm; FEX cache warm)

Native panel, uncapped:

| Run | fps 30–75 s | fps 85–125 s | Million instructions per frame (30–75) | Tiler % (30–75) | Energy per frame, mJ (30–75) | First fps drop |
|---|---|---|---|---|---|---|
| vk-1 | 100.1 | 73.4 | 56.3 | 80.0 | 88.0 | 55 s |
| dxmt-1 | 117.4 | 87.1 | 45.0 | 58.1 | 63.8 | 85 s |
| dxmt-2 | 117.3 | 84.6 | 44.7 | 55.9 | 66.1 | 80 s |
| vk-2 | 102.8 | 74.7 | 54.2 | 68.1 | 85.5 | 60 s |

- **Speed:** KK runs 12–14 % slower in both windows. Whole-run mean fps is 90.5/91.8 against 104.5/102.3.
- **CPU:** KK does +23 % instructions per frame.
- **Energy:** +33 % per frame before the clamp, +12–28 % after it.
- **Tiler:** busy 68–80 % against 56–58 %.
- **Clamp:** the budget arrives at about the same time for both (51–62 s), but KK's fps falls 25 s earlier.
- **Same picture as before:** this matches the 10-22 cooled ABBA (GPU +18.6 %, instructions +22 %). The gap did not
  move in nine days of patches.

### B2. Metal System Trace (Mac; native, uncapped, a 10 s window from first frame +90)

| | DXMT | KK |
|---|---|---|
| displayed fps | 74.6 | 59.8 |
| GPU busy (union of intervals) | 62.9 % | 51.7 % |
| GPU busy per displayed frame | 8.42 ms | 8.65 ms |
| vertex / fragment / compute per frame | 0.53 / 6.81 / 1.53 ms | 0.36 / 7.16 / 1.13 ms |
| sum of channels against union | 6.418 s vs 6.092 s: **0.33 s (5 %) overlapped** | 5.418 s vs 5.418 s: **no overlap** |
| encoders per second | 2624 (35 a frame) | 1914 (32 a frame) |
| longest displayed interval | 91.7 ms | 1033.7 ms |
| GPU performance state | Minimum 4.4 s, Medium 2.4 s | Minimum 4.1 s, Medium 2.8 s |

- **GPU cost per frame:** in this window it is within 3 % between the backends, and the GPU is half idle in both.
  The KK fps deficit here is therefore not GPU time. It is how the frames are paced and fed: the CPU, plus the 1 s
  stall.
- **Overlap:** DXMT's encoders overlap. KK's never do, which matches the earlier HK (3.748 vs 3.747 s) and W3
  (6.22 vs 6.23 s) traces. Cause in code: B4.1.

### B3. KosmicKrisp switches (session 1; one run each; the IPA's `patches/mesa` 0140–0143)

GPU time is KK's own timestamps (`[kk-gpu] gpu/frame`), which do not depend on the HUD.

| Arm | Switch | GPU ms/frame early → late | fps late |
|---|---|---|---|
| ctrl-1 | none | 6.08 → 10.06 | 87.5 |
| ctrl-2 | none | 6.00 → 10.16 | 82.8 |
| private | `MESA_KK_EXPERIMENTAL=private_memory` | 6.06 → 9.67 | 82.1 |
| devvis | `barrier_device_vis` | 6.08 → 10.40 | 88.1 |
| narrow | `narrow_barriers` | 6.06 → 9.99 | 89.0 |
| noquad | `no_quad_merge_block` | 6.02 → 9.31 | 84.4 |
| wa2 | `MESA_KK_DISABLE_WORKAROUNDS=2` | 6.07 → 10.29 | 86.7 |

- **Result:** none of the switches moves GPU time outside the spread of the two controls. Tiler share stayed
  71–81 % in every KK arm, against 55 % for DXMT in the same session.
- **Hollow Knight only:** the effect of each switch on The Witcher 3 or RDR2 (compute-heavy, many passes) is
  unmeasured.
- **`private_memory` is the weakest result:** nothing in the log shows the private heaps were used (`[kk-mem]` is
  identical to the control). A capture is needed to confirm it.
- **Each switch reached KK:** `title: graphics options: MESA_KK_…` appears in each log.

### B4. What KosmicKrisp asks of the GPU and CPU that DXMT does not (code, checked)

Paths are under `src/kosmickrisp/` of the mesa run tree.

1. **Every encoder ends with an all-stages barrier, ResourceAlias visibility** (`vulkan/kk_cmd_buffer.c:821-848` →
   `bridge/mtl_encoder.m:26-35`, with upstream's "probably overkill" TODO).
   - A Vulkan barrier recorded outside an encoder is a no-op (`:1033`), so ordering comes only from these.
   - DXMT uses per-resource fences and an encoder optimiser that reorders and merges passes
     (`dxmt_context.cpp:980-984, 1332-1489`).
   - Measured: no GPU overlap (B2).
   - `narrow_barriers` still leaves 96 % of render encoders waiting at vertex, and compute ends stay all→all.
2. **Encoder count.** The Witcher 3 runs 201–236 encoders a frame (121–148 render, 76–90 compute).
   - 63–66 of the compute encoders are empty or copy-only.
   - There are 47–54 render → copy → render runs a frame where both render passes have the same attachments.
   - 99–122 render encoders hold ≤2 draws.
   - The GPU idles 0.48–0.96 ms a frame between encoders (`$PLAYPORT_BUILD/perf/pla466-w3-pass-prof`).
   - Every copy gets its own compute encoder, where DXMT uses blit encoders.
   - Clears are separate passes, never folded into the next one (`vulkan/kk_cmd_clear.c:46-131`).
   - Any driver compute inside a render pass splits it with a store and a reload (`kk_cmd_buffer.c:786-798`):
     tessellation, geometry shaders, unrolled draws, conditional rendering.
3. **Metal's CPU per encoder.**
   - A Mac probe found Metal's submission CPU scales with encoders (about 7 µs each) and command buffers (about 3 µs
     each), not with commits.
   - The W3 trace had `IOGPUCommandQueueSubmitCommandBuffers` at about 4.3 ms of E-core CPU per frame on GCD threads
     (an upper bound; recorded with tracing on).
   - KK commits 8 command buffers per HK frame, 3 of them empty, against DXMT's 2. The W3 frame has about 20.
4. **Shaders.** Counts are from RDR2's phone MSL dump.
   - **No load vectorising.** There is no `nir_opt_load_store_vectorize`: 98,149 single-word storage-buffer reads,
     each inside its own bounds-check branch, and 101,923 single-word checked uniform reads, against 12,320 vector
     loads.
   - **Math mode.** Every comparison sits in a `math_mode(safe)` block: 128,869, about 70 % of them integer.
   - **Quad merging.** Fragment shaders that need quad helpers read `[[barycentric_coord]]` behind a never-true select
     so Metal will not merge triangles into shared quads: 550 of 584 in RDR2. The reason is Vulkan's per-primitive
     derivatives (Vulkan-Portability #54). DXMT does not do this. B3's `noquad` arm on HK: no change.
   - **Texture access.** A texture access is 3 chained loads plus a null-check branch; a sampler is 4, two of them
     `coherent device`. DXMT needs 1 for either.
   - **Workaround 6** (`coherent device` on every vertex- and compute-stage memory access, mesa 0030) has never been
     measured on a compute-heavy title.
   - **Workaround 2.** Its 64-bit loop counter is forced on for Apple10: 3,770 loops in 479 RDR2 files. Without
     mesa 0142, `MESA_KK_DISABLE_WORKAROUNDS=2` could not turn it off (`kk_physical_device.c:1266`).
   - **W3 spills.** Encoders that spill registers take 35.6 % of W3's GPU time
     (`2026-10-28-witcher3-trace-breakdown.md`).
5. **Pipeline creation.**
   - KK writes MSL text and Metal compiles it; DXMT hands Metal AIR bitcode.
   - 54 % of the MSL bytes are filler (indentation, up-front declarations, pragmas).
   - Translation costs 8–10.5 ms of CPU per shader. W3: `translated=368 (3863 ms)`.
   - Cold-cache stalls: HK 2.9 s, Portal 2 3.0 s (MSL 4.0), and 5.5–5.8 s across 37–39 HK pipelines in the 10-22
     GPL run.
   - Blend and write masks are compiled into fragment shaders, which multiplies variants: 580 MSL from 384 SPIR-V in
     RDR2 fragment, 561 from 201 vertex.
   - The shader cache is keyed on the build ID, so every app update recompiles everything.
6. **Present.** Three passes follow the final colour write against DXMT's one: DXVK's swap-chain blit, then KK's
   WSI blit to the drawable, about 27.6 MB a frame at native resolution (`wsi_common_metal.c:480-629`). Two submits
   per present, because the blit queue is the app's only queue (`kk_wsi.c:117-126`).
7. **Memory.**
   - Every allocation is shared storage in a sparse placement heap with a whole-heap buffer alias
     (`kk_private.h:47-50`, `bridge/mtl_heap.m:23-26`, `kk_bo.c:113-124`). DXMT has 56 of 57 private standalone
     textures, and its GPU-driver memory is 0.35–0.39 GB against KK's 1.08 GB.
   - Command allocators are never destroyed or trimmed on the default path, so they hold their high-water mark:
     181 MiB HK, 442 MiB W3, 751 MiB RDR2 (`kk_cmd_pool.c:573`; a reset would not free it either). The opt-in fix is
     PLA-364 / PLA-476.
   - The idle large-BO cache is capped per pool, with no device-wide bound: 216 MiB idle in W3.
   - Descriptors are 64 B each. vkd3d-proton's `HOST_ONLY` heaps still become resident Metal heaps: 161 MiB W3,
     201–202 MiB RDR2 (`kk_descriptor_set.c:586`).
8. **Descriptor CPU is small.**
   - HK DXVK: 0.038 ms a frame. W3: about 0.6 ms a frame, about 1 % of the frame.
   - The full 2,240 B root table is re-uploaded on every state change, and `setAddress` is called on every draw even
     when the address is unchanged.
   - A pool reset walks every set: 593 µs mean, 837 µs max on `dxvk-cs`.

### B5. CPU per frame by layer (session 3 `--cpu-prof`, 720/60; Mac Time Profiler, 720/60, cool)

- **Guest code dominates.** x64 JIT code is 70.3 % of running samples on KK and 74.0 % on DXMT. KK as a library is
  1.0 %, Apple's AGX driver 1.2 % (DXMT 0.6 %), xtajit64 4.0–4.1 %.
- **Same app CPU on both.** The Mac Time Profiler gives about 0.99 cores for KK against 1.05 for DXMT. KK inclusive is
  7.5 % of app samples, IOGPU 6.7 % against 4.4 %.
- **Unity's time-wait thread spins.**
  - In both backends one thread spends 11.6 % (KK) and 12.0 % (DXMT) of all app samples in the 256-byte bucket
    `UnityPlayer.dll+173f100`, at 97–98 % on S cores in the Mac trace.
  - In a 2026-10-05 copy of the DLL that bucket holds a QPC-to-microseconds helper and a waitable-timer sleep: a
    `CreateWaitableTimerEx` cached in TLS, then `SetWaitableTimer` and an alertable wait.
  - It is running guest code, not waiting: a sleep-until loop that keeps falling through [INFERENCE: the DLL copy may
    not match the phone's build exactly].
  - Same class as W3's QPC spin (PLA-462).
- **System cost while tools run.** `diagnosticd` takes 8.7–9.0 % of all phone samples during a `pp ui` run (log
  streaming of the dev build's output), `backboardd` 5.7–7.2 % and `audiomxd` 3.6–4.0 %: CPU the phone spends while
  the game plays under the tools.

### B6. The Metal HUD

- **What the app does:** it set `MTL_HUD_ENABLED=1` at every start, release builds included (`HostIO.swift:759`), so
  Apple's `libMetalMetricsInterpose` was loaded even with the HUD hidden. The Time Profiler upper bound was 0.53 ms a
  frame on HK.
- **Today's measurement:** with the HUD loaded and logging (dev build, Settings on), KK's submit thread spent
  19.0–22.9 ms a second against 8.2–9.6 ms without it. The guest-plus-host instruction count was 60–62 against
  51–54 million per frame (session 1 arms).
- **Loaded but hidden is still not isolated.** The `d3be12c9` arm (`hud-old-1`) started with a cold FEX cache
  (42,471 misses), so its 76.4 against 74.3 million instructions per frame cannot be used.
- **Interaction found:** with `85c863d` the HUD loads only when the setting is on at app start. `pp perf` sets the
  setting in its own launch and undoes it at the next app start, so the HUD was loaded on alternate runs in session 1.
  `pp perf` arms are only comparable when every arm uses `--no-hud`.

## Part C. CPU work that is a bug or a poor fit for the phone

Every row was checked in code. "Measured" means from a run log or trace; otherwise it is the code fact.

| # | Layer | Finding | Size | Class |
|---|---|---|---|---|
| C1 | App | FEX's disk cache is deleted before every launch when under 10 GB is free (`EmulatorCache.swift:40, 87-101`, decision 0056); 8 of 8 recent HK logs, 39 of 43 overall | cold: 42k blocks compiled by +115 s against ≤13 warm; first frame up to about 1 s later | design on a full phone; it made earlier perf runs cold |
| C2 | App/Wine | A 0.94 GB JIT pool dump is written on every launch after an unhandled fault at `ntdll.dll+0x1b05c` (PLA-446) | about 1 GB of flash a launch; 191 ms of system CPU at +0.58 s | bug |
| C3 | Wine | `get_inproc_sync_fd` is the most frequent server request in W3: 9.9–11.4 a frame of 21–23; failed lookups are not cached (`dlls/ntdll/unix/sync.c:800-846`); `req298` confirmed against the protocol enum | 2.6–4.2 ms of thread time a frame at 0.26–0.42 ms a round trip | missing cache |
| C4 | Wine | Round trips are about 10× slower under the clamp: 25 µs with P cores, 0.3–0.4 ms on E cores, 1.2–1.5 ms for RDR2's `redTask` threads; the server thread is user-interactive like every guest thread (`wine_host.c:1517`) | wake latency 5 µs → 80–266 µs | poor fit (priorities) |
| C5 | Wine | The wineserver loop wakes at least 1,000 times a second (1 ms tick, `fd_ios.c:1409`) and tries a read on every client fd each pass: 8–11k syscalls a second in HK against 600–900 requests | about 1.5–3 % of an E core [INFERENCE]; keeps a core awake | poor fit |
| C6 | Wine | Sync diagnostics run on every wait with counters off: a scan of up to 512 slots (16 KB) in `ios_alert_waiter_slot` (`sync.c:4743-4764`, slots never freed), a clock read and shared stores; the storm detector on every alerted return; a global atomic per alert (`:5102`) | about 10k waits/s in W3; µs per wait when contended [INFERENCE] | diagnostics on the hot path |
| C7 | Wine | QueryPerformanceCounter is a syscall per call: 69.6k/s in W3, 43–57k/s in RDR2; RtlQueryPerformanceCounter is 350–787k x64→EC transitions/s in W3 | 3.5–7 % of a core [INFERENCE] | poor fit; the fast path is off because RDR2 went black with it |
| C8 | Wine | `GetTickCount`/`timeGetTime` cost about 3 faults each; a split 16K page is never undone; `VirtualProtect` is 12–15 µs against 0.7 µs on desktop | load time, GC | poor fit (16K pages) |
| C9 | Wine | Every guest thread is user-interactive; no Windows priority reaches the kernel (`sync.c:1320`); DXVK's six compiler threads asking for LOWEST also run at UI 47/47 | contention during compile bursts | poor fit |
| C10 | Wine | The pool warmer runs in release every 2 s: touches about 34k pages, 4 test allocations, `malloc_zone_check(NULL)` (heap lock) | periodic | diagnostics in release |
| C11 | FEX | AVX/AVX2/FMA3/BMI1/2/F16C are reported to every x86-64 guest with no way off (`Source/Windows/Common/CPUFeatures.cpp:87`, fex-port 0064; the iOS branch ignores `disableavx`). 256-bit ops run as two 128-bit halves through memory; PDEP/PEXT as loops of up to 64 | unmeasured | poor fit |
| C12 | FEX | Every guest CALL and RET carries 7 extra instructions on ARM64EC: an x17 reload and writeback (native returns clobber x17) plus a 5-instruction bounds guard (iOS ignores `PAGE_NOACCESS`) (`BranchOps.cpp:184-226, 266-285, 314-345`; fex-port 0022, 0024, 0036, 0047, fex 0055) | uncounted; [INFERENCE] 5–10 % of JIT instructions | port overhead |
| C13 | FEX | x86 ordering: every non-stack integer load is `LDAPUR`+NOP, every store NOP+`STLUR`; the base cost was never measured (turning it off hangs HK) | vector ordering alone +4–5 % instructions | poor fit (no TSO) |
| C14 | FEX | The hand-built feature list leaves out FRINTTS, ECV, DotProd, RPRES, I8MM, WFxT | ≤1 % of instructions [INFERENCE] | missing |
| C15 | FEX | A Wine syscall (`NtFlushInstructionCache`) for every compiled block (`JIT.cpp:28-31`) | about 138k compiles a run | startup, hitches |
| C16 | Guest | Spin waits: W3's RenderThread spins on QPC/PAUSE at 63–73 % of a core (PLA-462); Unity's time-wait thread in HK at about 12 % of samples (B5). PAUSE is YIELD, a no-op on Apple cores | as given | poor fit |
| C17 | KK | Metal submission CPU per encoder (B4.3): W3 up to about 4.3 ms a frame on E cores | as given | poor fit |
| C18 | App | The Metal HUD's interposer is loaded on every start (B6) | ≤0.53 ms a frame HK; submit thread +10–13 ms/s with it shown | design |
| C19 | App | The session `control` file is opened every 50 ms; the memory census `mincore` runs on the game's main thread; case-insensitive lookups do two full directory scans per missing file under a global lock (PLA-461/468 class) | 0.46 + 0.15 + 0.78 ms a frame in HK (Mac trace) | design |
| C20 | KK (dev only) | `MESA_KK_DEBUG=compile,memory,gpu` is on in every dev build (`WineHostRuntime.swift:58`): atomics per draw, a census lock on the submit thread, a print and flush under the lock Metal's completion threads need | estimated under 0.05 ms a frame; every dev perf number includes it | measurement bias |

Already fixed, for context: the adapter-table and NSI probes (PLA-460/461), the critical-section fast path
(wine-pe 0050), wineserver reads (madeira-unix 0175), the residency commit per submit (mesa 0129), lossless
compression on TYPELESS targets (mesa 0019 v2), present-wait pacing (mesa 0018).

## Part D. Correctness defects found in code (not perf, checked)

| # | Where | Defect | Reach |
|---|---|---|---|
| D1 | KK, mesa 0005 | Indexed indirect draws with a geometry shader (dynamic or static indexed shape) pull the vertex shader's indices from the GS output buffer: `draw.index.gpu.addr` is overwritten at `kk_cmd_draw.c:2311/2323` before use at `:2347` | `DrawIndexedInstancedIndirect` + GS |
| D2 | KK | Position invariance ignored: DXVK marks it (`dxbc_io_map.cpp:880…`), KK emits no `[[invariant]]` and no `preserveInvariance` | depth pre-pass + EQUAL test can z-fight |
| D3 | KK | `root.set_dynamic_buffer_start` never written (`kk_cmd_buffer.c:1076-1141`; HoneyKrisp/NVK write it) | GPL only (off by default) |
| D4 | KK | `kk_sync` `wait_many = NULL`: a wait-any over more than one fence or semaphore busy-spins (`vk_sync.c:412-423`) | native Vulkan titles; not DXVK/vkd3d |
| D5 | KK | `kk_timeline_wait` ignores `WAIT_PENDING` though it advertises it | over-waits on rare paths |
| D6 | KK, mesa 0062 | The known-fail list persists across launches and returns `VK_ERROR_INVALID_SHADER_NV`, not a legal result there | a build lost to jetsam can fail for good |
| D7 | KK | Metal pipelines never declare a depth or stencil pixel format (`d_format`/`s_format` written, never read) | API validation |
| D8 | Wine | The per-process fd cache never reuses slots (`server_ios.c:3463-3511`): the 65th pseudo-process ever made shares one fallback cache, and handle→fd entries can collide across processes; the log says "uncached (correct, just slower)" | long sessions with many child processes |
| D9 | Wine | The Mach exception thread takes the main memory lock with a blocking lock (`virtual_ios.c:19986`): a holder that faults deadlocks | the 0102 JWE probe hit it |
| D10 | Wine | Audio position timestamps use `mach_absolute_time`, QPC uses `mach_continuous_time` (`audio_null_ios.c:1770`, `sync.c:102`) | A/V drift after every suspend |
| D11 | Wine | The first audio stream fixes the device format: a mono first stream makes later stereo play left-only; rate mismatch is resampled nearest-neighbour; more than 2 channels dropped | per title |
| D12 | FEX | After the Mono backpatcher helper, x18 is read without the iOS TEB lookup (`MiscOps.cpp:430-433`); x18 is 0 on iOS | HK and other Mono titles: an emulated page-zero fault per backpatch |

## Part E. What is still open as data

1. **KK's tiler share.** KK's tiler is busy 68–81 % against DXMT's 55–58 % with GPU time per frame within 3 %. No
   counter breakdown yet. The serial replay of `pla439-vk-1` and `pla439-dxmt-2` needs the phone cabled to the Mac.
2. **Private storage.** Whether the private heaps engaged in the `private_memory` arm: a capture's resource list.
3. **Heavier titles.** The switches and the barrier question on The Witcher 3 and RDR2 (not installed / long route).
4. **Base costs never counted:** x86 memory ordering, AVX, the CALL/RET guard.
5. **The KK 1,033 ms stall** in the native Metal System Trace window: its cause.
6. **The hidden-but-loaded HUD** in isolation, which needs a launch-environment arm.

## Data

- Phone runs: `$PLAYPORT_BUILD/perf/pla541/` (session 1: `hud-*`, `nat-*`; session 3: `nh-nat-*`, `prof-cpu-*`,
  `prof-pass-*`); session scripts and logs: `$PLAYPORT_BUILD/agent-notes/pla541/s1.sh`, `s3.sh`, `s2.sh` and their
  `.log`.
- Mac: `.work/gpu-runs/pla541/` (`tp-hk-60-{dxmt,vulkan}`, `mst-hk-nat-{dxmt,vulkan}` with `x/` exports and
  `mst-summary.txt`, `tpsum.txt`, `tpsym.txt`); the failed first attempt (Xcode could not reach the phone) is in
  `pla541-failed-1`.
- Code-analysis notes: `$PLAYPORT_BUILD/agent-notes/pla541/` (`kk-cmd`, `kk-desc`, `kk-compiler`, `kk-sync-mem`,
  `kk-patch-audit` with its full 105-row table, `vk-layers`, `fex-code`, `wine-code`, `ev-cpu`, `ev-kk-dxmt`,
  `mac-artifacts`, `raw-power`, `device-recipe`).
