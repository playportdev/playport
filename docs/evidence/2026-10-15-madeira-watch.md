# Madeira watch: useful discoveries since the October 6 review

**Date:** 2026-10-15. **Linear:** [PLA-356](https://linear.app/playportdev/issue/PLA-356).
**Kind:** source research, not a build, benchmark or compatibility result. No phone runs.

## Scope and baseline

- Last full local watch: `.work/sync/watch-bbbf8d0e/WATCH.md`, generated October 6,
  through Madeira `bbbf8d0e20fd` (an October 4 commit). Later Playport research, particularly
  the October 12 launcher/RDR2 plans, already knew some of the ideas below.
- Latest public main inspected: [`279fd0f83170425db002fe25d6bd62f6355f497d`](https://github.com/willfaust/Madeira/commit/279fd0f83170425db002fe25d6bd62f6355f497d),
  October 14 UTC / October 15 in its recorded +08 timezone. There are **116 first-parent
  commits since the previous watch**, not 116 independent fixes: several are pin updates,
  binary rebuilds or merges that only record already-squashed PRs as merged.
- Latest release remains [v0.1.3](https://github.com/willfaust/Madeira/releases/tag/v0.1.3),
  published October 3. New main and open PRs must not be described as released features.
- Playport comparison: `ffaf752`, branch `research/extended-memory`, frozen Madeira
  `8c050d0`, committed patches and existing assembled source. Donor-memory and memory-budget
  work on this branch is **not yet main/released**. No pins or runtime files changed here.
- Scratch/source extracts: `.work/research/madeira-20261015/`. The new watch output is
  `.work/sync/watch-279fd0f8/WATCH.md` and `watch.tsv`. Its counts are from the frozen pin,
  not the previous watch; they include non-first-parent history and are not unique-fix counts.

Public PR bodies, commit messages and source were read directly through GitHub and the local
watch mirrors. Upstream device numbers below are their reports, not independently reproduced
measurements. GitHub Discussions is disabled. The native D3D12 README's milestone narrative is
historical (including statements that work is not committed); recent code and PRs supersede it.
Search summaries were not used as evidence: one incorrectly said there was no MetalFX work.

## Recommendation

Keep the frozen base. **Port narrowly selected correctness fixes first; investigate server and
FEX overhead next; borrow the upscaling design for Vulkan.** Their heavy-game results are useful
leads, but do not justify replacing our graphics backend or adopting their memory policy wholesale.

### 1. Correctness gaps visible in our source

| Finding and upstream source | Current Playport comparison | Tracking |
| --- | --- | --- |
| [`#248` §4](https://github.com/willfaust/Madeira/pull/248): `TlsFree` clears the same-numbered slot in other pseudo-processes. Contributor traced a CEF browser's null V8 isolate to a child unloading a DLL. **Open PR**, exact branch host-tested, device evidence from contributor builds. | `virtual_clear_tls_index` still walks shared `teb_list` without a caller-PEB filter, in both normal and expansion-slot branches. Need a cross-process probe and our WoW64 pointer handling preserved. | [PLA-357](https://linear.app/playportdev/issue/PLA-357) |
| `#248` §3: the initial process sets the shared `process_exiting` flag, after which Wine's mutex helpers skip locking across the session. | `ios_process_exiting_ptr()` still returns `&process_exiting` for the initial/no-slot process; `unix_private.h` still skips lock/unlock when it is true. Dangerous for launcher-stub exits while children continue. A private root flag must be reviewed with crash/lock ownership, not patched in isolation. | [PLA-360](https://linear.app/playportdev/issue/PLA-360) |
| `#248` §7: recycled `(poll slot, fd)` keeps its old INET verdict, so a TCP connect can receive fake readiness; two-stage `realloc` failure can also leave a dangling cache pointer. | Both patterns remain in `ios_fd_is_inet` in `build/wineserver/fd_ios.c`. Upstream reports 15 false completions in 768 pre-fix rounds versus none in 1,024 post-fix rounds; allocation-failure evidence is host-only. | [PLA-358](https://linear.app/playportdev/issue/PLA-358) |
| Merged [`#267`](https://github.com/willfaust/Madeira/pull/267), `da4f496`: stack-free x18 trampolines and correct ADD/SUB matching. An x64-to-ARM64EC callee can have SP 8 mod 16, making a trampoline's SP-based scratch save fault. | Our patcher still emits SP-based saves and uses the `0x5F` matcher that excludes SUB. Preserve our MOV-xzr, bitmap and trampoline-page fixes. Include follow-up [`10c7781`](https://github.com/willfaust/Madeira/commit/10c7781d6a793dca8a81d2459a939e5850ec642d): a preempted x18 TSD load must receive the TEB itself, not a TEB field. | [PLA-359](https://linear.app/playportdev/issue/PLA-359) |

These are **confirmed source patterns, not newly reproduced Playport failures**. The linked
issues separate them from this research; no fixes were implemented.

Other `#248` topics merit the existing [PLA-75](https://linear.app/playportdev/issue/PLA-75)
audit: zeroing never-committed subpages during decommit, global rather than per-thread
stuck-fault counts (our handler still has a static `stuck_n`), and kernel/server output into
RWX aliases. Our 0124 already retires anonymous aliases on release; that does not establish
that `read`/`recv`/server-reply destinations are safe. Do not import the whole PR over our
substantially changed fault/protection code.

### 2. Wineserver work is the best broad performance lead

Merged [`#294`](https://github.com/willfaust/Madeira/pull/294), `daf2ca3`, reports a
352-thread game/launcher session driving the server to about **90% CPU at 10k requests/s**,
with roughly 1,500 poll users. Coalescing wakeups alone did not help: reading every client
fd on every pass was the expensive part.

Their changes:

- A thread-ID doorbell selects request fds; periodic full scans still handle exits and sockets.
- Repeated unchanged `ClipCursor` calls no longer notify the foreground thread. Their game
  issued up to 2,400 `set_cursor` requests/s.
- `get_handle_fd` returns an `F_DUPFD_CLOEXEC` descriptor in its reply, avoiding SCM_RIGHTS
  between threads that already share one descriptor table.
- Rate-limited per-fd logging. Direct execution of selected requests on the client thread is
  **separately opt-in**, under the server lock, and deserves its own reentrancy review.

Our source still uses `ios_wineserver_wake` and the old scan. This is directly relevant to
PLA-75 T1, irrespective of graphics backend. No quantitative post-fix Playport gain is known.

Also merged: [Wine `#33`](https://github.com/willfaust/wine/pull/33), `549b8f1`, answers three
simple file-information classes with one `fstat`, skipping irrelevant extended-attribute
queries. Their D3D12 cache queried about 940 sizes/s, costing about 1,880 unnecessary xattr
calls/s. Useful mechanism, but our cache traffic differs; measure before expecting that gain.

### 3. FEX: promising savings, with a material difference from Playport

Merged [FEX `#19`](https://github.com/willfaust/FEX/pull/19), `2ee1437`, reduces each thread's
call-return reservation **16 MiB → 8 MiB**, preserving its 2–6 MiB live window and 4 MiB reset
point. With around 260 translated threads, upstream reports arena use falling from 85–91%
(and allocation failure) to 70–76%. This saves **address-space reservation**, not necessarily
8 MiB of resident RAM per thread. Our constant remains 16 MiB. The full-reservation clear
still exists, so this is not a complete solution to PLA-75 T2's reset cost.

Merged [FEX `#18`](https://github.com/willfaust/FEX/pull/18), `011b4be`, combines SMC-store
fast paths and leaner x64/ARM64EC transitions. Their emitted-code count goes **132 → 84
instructions per round trip**, with AFP off and L1 hits; this is not a measured FPS gain.

**Do not copy its call-return elision unchanged.** Their justification is that the predictor
is unused. Playport [`fex/0006`](../../patches/fex/0006-JIT-trust-the-call-return-prediction-on-iOS-again.patch)
deliberately restores it, with historical Hollow Knight measurements of 7% fewer main-thread
instructions and 5% fewer total instructions/frame. Evaluate independent EC-transition
optimizations against that implementation. New FEX frame fields/offsets and suspension stamps
also need coordinated review. Both leads are recorded on PLA-75.

### 4. Launchers: more concrete experience, not a turnkey transplant

Merged [`#285`](https://github.com/willfaust/Madeira/pull/285), `61dce1d`, reports GTA V
Enhanced and RDR2 with Rockstar Launcher/Social Club. It includes single-process Chromium
handling, more than 256 TEB trampolines, reclaim of exited processes' FEX buffers, placement
failure memoization, larger reservation layouts, and child-window visibility fixes.

Useful product/performance observation: a **hidden launcher kept rendering 44–60 FPS**, using
about 0.4 CPU core while the game was CPU-bound at 17 FPS. Their hidden-layer cap defaults to
10 FPS. That is worth remembering when our launcher path exists; it is not a reason to throttle
the foreground game or all background threads indiscriminately.

Merged [`#284`](https://github.com/willfaust/Madeira/pull/284), `d3b8625`, targets alias pushes
at the owning emulator and reserves capacity when draining foreign mappings. Our 0044 already
has per-process callbacks and 0141/fex0039 retire dead aliases, but we still broadcast live
images. This is a concrete source for [PLA-313](https://linear.app/playportdev/issue/PLA-313),
not a replacement for our retirement work. Include acquire-load follow-up `ce2e1f1` in review.

Caution: [`#304`](https://github.com/willfaust/Madeira/pull/304), `48c4b3f`, lets a timer waiting
100 ms precede endless paint traffic. Their installer repainted 219 times/s and never advanced
its timer-driven status page. But this **changes Windows message priority**, and the commit
explicitly lacks a recorded device run of the finished installer. Treat it as a diagnostic
lead; investigate the repaint cause before adopting globally.

[Wine `#39`](https://github.com/willfaust/wine/pull/39) works around a DXMT texture missing
`IDXGISurface1` for Direct2D DC rendering. That explains a launcher crash on their route; it
does not establish a missing feature on ours. Vulkan/Proton parity remains the target.

These references are attached to [PLA-254](https://linear.app/playportdev/issue/PLA-254);
its existing launcher/RDR2 work should use them rather than create a parallel plan.

### 5. MetalFX is real; generic frame generation is not established

Merged October 6: [`#195`](https://github.com/willfaust/Madeira/pull/195), `1e6cb88`, adds
**Off / 1.5× / 2× MetalFX spatial upscaling per game**. D3D11 uses DXMT's existing scaler;
their native D3D12 path creates the scaler/output texture with the swapchain, scales before
present, releases on resize, and falls back if unavailable. Reports include Crysis, God of War
and Ghost of Tsushima device play. Spatial scaling costs a pass and a larger output texture;
it improves low-resolution presentation, not free performance.

Our DXMT source already has the float `d3d11.metalSpatialUpscaleFactor` and
`DXMT_METALFX_SPATIAL_SWAPCHAIN` gate, but the app has no player setting.
**Decision [0100](../decisions/0100-vulkan-is-the-direction.md) excludes a new DXMT-only feature.**
Borrow the user-facing controls, fallback and resource-lifetime design for the Vulkan route.
Tracked in [PLA-126](https://linear.app/playportdev/issue/PLA-126).

Today's open [`#337`](https://github.com/willfaust/Madeira/pull/337) fixes a diagnostic stack
scan crashing an FSR3 presenter thread; contributor builds then ran it for minutes.
Open [`#341`](https://github.com/willfaust/Madeira/pull/341) addresses generated-frame black
squares and `MipLevels=0` interpretation, but keeps the fix opt-in while its GPU cost is
understood. This is **game-integrated FSR3**, not proof of a general Playport-style toggle that
can generate frames for arbitrary games.

The native D3D12 backend has clearly advanced beyond its old README's textured cube: merged
[`#280`](https://github.com/willfaust/Madeira/pull/280) covers shader caching, batched encoding,
indirect tessellation, reduction samplers and typed-buffer fixes. Open
[`#340`](https://github.com/willfaust/Madeira/pull/340) reports Horizon Forbidden West's
12-byte float3 views needing 16-byte copies and costly copy-table refreshes. These are useful
Metal constraints and profiling examples, not drop-in fixes for vkd3d/KosmicKrisp. We still do
not ship their converter/runtime; [LICENSING.md](../LICENSING.md) and decision 0100 remain binding.

### 6. Their memory experiments reinforce caution about file backing

Open [`#219`](https://github.com/willfaust/Madeira/pull/219) reports Ori on an A16 iPad with
a roughly 4 GB app limit. File backing caused 0.3–18 s stalls: APFS hole punching under
`virtual_mutex`, dirty dead-page writeback, and page-crossing SIMD-store kernel livelocks.
Deferred punching and dirty-page discard plus store handling reportedly improved play to
about 43 FPS, but **10–20 s GC pauses remained**. This is not a general solved swap tier.

Open [`#342`](https://github.com/willfaust/Madeira/pull/342) is especially relevant to our
current memory research. Moving six 256 MB DEFAULT GPU buffers into file-backed no-copy
storage reduced reported peak footprint from about 7.5–7.8 GB to **6,052 MB**, but GPU time
**tripled to 48–57 ms** about 20 s into play. They excluded it from recommended settings.
The wire/size-cap/residency/heat variants and fence-poll backoff are explicitly untested on
device. Their thermal/E-core experiments are not proven universal defaults either.

Our donor pool has a different backing mechanism; this is not evidence it has the same fault.
It is evidence that footprint alone is insufficient: measure residency, page faults, GPU time,
scene loads and sustained play. Keep the file tier conditional under
[PLA-268](https://linear.app/playportdev/issue/PLA-268). Current-branch pool/budget work
([PLA-216](https://linear.app/playportdev/issue/PLA-216), PLA-352/353/354) must be distinguished
from shipping Playport when comparing capabilities.

## Things we should not count as new gaps

- **Pure x64 images without pool copies:** ours is 0090; their #285 makes it opt-in.
- **App-local x64 ucrtbase:** ours is wine-pe 0034; their #286 addresses the same hazard.
- **Wine DLL coverage:** our all-built-modules staging landed in `77e125e`; their new DLL-farm
  work and still-open wintypes PR are not proof that Playport is missing those DLLs.
- **Wine Mono, visible GDI launchers, prerequisites from Play, display-mode emulation and
  OpenGL/Zink:** already implemented here (decisions 0075–0079, 0087–0089, 0097). Their
  equivalent feature/PR titles are not a to-do list for us.
- **Budget-change events:** their new DXMT #30 overlaps the opt-in event on our current
  memory branch; compare semantics and evidence rather than add a second implementation.
- **Smaller shader caches/less diagnostic traffic:** useful general ideas, but Playport has
  its own shader-cache and release-log work. Their shader pipeline and cache workload differ.

## Verification and boundaries

`./pp sync` completed with exit 0: 425 commits across the watched component histories touch
built paths since the frozen pins; no pin moved. It also reported 32 newer Valve Wine commits,
which were outside this Madeira review. `./pp test --quick` completed with exit 0 (including
name/secret/pin/patch checks and host tests; Swift omitted). Local report links and
`git diff --check` passed.

This review checked public source/commit/PR evidence against the frozen base, committed
Playport patches and current assembled files. It did not replay candidate patches, build an
IPA, run upstream host harnesses or play any games. Thus there is no new IPA hash or game
compatibility entry. Upstream successes are not Playport compatibility claims.

Four source-backed correctness findings are split into PLA-357–360. Existing PLA-75, PLA-126,
PLA-254, PLA-268 and PLA-313 hold the remaining scoped follow-ups. No pin move is proposed.
