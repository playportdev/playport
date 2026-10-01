# Plan: performance follow-up after the runtime audit

**Date:** 2026-09-28. **Status:** closed 2026-09-30. Each step's **Progress**
line has its outcome:

| step | outcome |
|---|---|
| 1. gameplay baseline | five modes, one run each; **720 rows at 60 FPS is now every game's default** (`LaunchSettings`). Not yet seen on the phone: the build could not be signed at closing (the phone had dropped off the signing team) |
| 2. FEX MaxInst | 500 changes nothing on Hollow Knight or The Witcher 3; FEX's 5000 stays. The game page keeps a Block size setting |
| 3. release measurement producers | off in the release app through `ios_counters_on`; no measurable cost or gain in either title |
| 4. helper QoS | not run |
| 5. memory | the Wine PE set is staged without DWARF (Hollow Knight's pool head 203 → 132 MiB, the IPA 753 → 437 MB); The Witcher 3 ran five minutes in a 384 MiB pool; the pool's sizing is unchanged |

Not done, for a later plan: step 4; the pool sizing (a long-session capacity
test); The Witcher 3's dbghelp start-up and a symbolised `--cpu-prof` profile
on the stripped PE set; the `[xp-api]` sampler, which no longer finds the game
process's PE counters (the counters record).
**Audited tree:** `63beae7`, whose only changes from the review's `5596288`
are build records. **Scope:** Hollow Knight first-use hitches, sustained
power, release diagnostic overhead and JIT memory. Use The Witcher 3 as a
second workload where specified; do not generalize one title's result.

## What the audit established

| Finding | What is established | What is not |
| --- | --- | --- |
| Native/free-running presentation | Hollow Knight has no title resolution override; the fallback is native pixels and frame limit 0. On the reference phone, native is 3.74 times the pixels of 1280×720. | A sustainable 720/60, 900/60 or 900/120 product default has not been measured. The older 300-second 720-row result was a menu test, not sustained gameplay. |
| FEX MaxInst | The pinned default is 5000; `FEXProfile.swift` records but deliberately does not apply Proton's global 500. | Smaller blocks have not been shown to reduce this cohort's hitches or power. |
| Release diagnostics | `MADEIRA_NO_DIAGNOSTICS` stops samplers, but hot Wine counters, the QPC histogram and server-request timing remain active. | Their frame-time and power cost has not been isolated. |
| Helper QoS | An older 720-row experiment reduced CPU power from about 1.9 W to 1.55 W. | A safe global policy: the same experiment worsened periodic stalls from about 25 ms to 33–42 ms. |
| Allocator serialization | The FEX/rpmalloc wrappers retain the recursive spinlock. | A dominant performance cost: a lock-off A/B already measured no Hollow Knight improvement. This is not a lock on every host allocation. |
| Call-return resets | Each reset covers a 16 MiB virtual region. | A dominant hitch source: measured resets averaged about 27 µs, totalled 0.63–0.72 seconds per run and peaked at 2.3 ms. |
| Server synchronization | Madsync stays off because blocked waits do not correctly service system APCs. | A demonstrated cohort FPS gain: Hollow Knight's main-thread round trips were 0.8% of its time; the tested Witcher 3 workload stayed GPU-bound with sync on. |
| JIT pool | Blessing makes pool size a resident cost; current sizing already spans 512–896 MiB according to the memory limit. | That 512 MiB suffices for long sessions, additional titles or child processes. |
| Swift and Metal HUD | The release app does not automatically gain optimized Swift; HUD machinery is enabled even when hidden. SteamClient separately opts into `-O`. | A measured thermal or frame-time benefit from changing either. |

The review's implementation concerns are useful, but its P0 ranking and its
conclusion that remaining work is overwhelmingly CPU-side are not supported
by the complete evidence. Native-resolution runs still implicate GPU,
memory and fabric power as well as CPU work.

## Measurement rules for every experiment

- Drive launches, settings and gameplay through the app UI (`pp ui`,
  `pp perf`). No alternate launch path or pushed configuration files.
- Hold the shared device lock across each install-and-run sequence. Record
  the installed IPA SHA256, source revision, variant and resolved settings.
- Fix the title/save, scripted route, resolution, cap and diagnostic mode.
  Measure actual guest dimensions: Playport's 720-row mode preserves aspect
  ratio (1564×720 on the reference phone), not necessarily 1280×720.
- Use comparable thermal starts and charging conditions. Prefer battery
  runs; record battery range, thermal pressure and cooldown. Check cooling
  telemetry is live rather than relying on an old follower's last value.
- Change one variable at a time. Use repeated A/B/B/A blocks where practical;
  expand repetitions if the difference is within observed run-to-run spread.
- Separate launch, first-use/scene-load, steady gameplay and throttled
  windows. Define cold/warm state explicitly; do not mix them in one result.
- Record frame-time p99/p99.9 and counts at ≥25/50/100 ms, throughput,
  instructions/frame, CPU and whole-phone power, GPU time, thermal onset,
  footprint, JIT-pool high water and crashes/corruption indicators as relevant.
  Do not substitute average FPS or instruction count for power or tail latency.
- Keep measurement overhead equal across variants. If disabling a producer
  removes a metric, use an independent source or a separate attribution run;
  do not silently re-enable the work under test.
- Commit sanitized evidence with IPA hashes, run locations, limitations and
  a keep/reject decision. Run `pp secrets` before committing evidence.

## 1. Establish a current gameplay baseline

**First.** Reproduce Hollow Knight's scripted play on the current runtime,
not just its menu, at native/free-running and 720-row/free-running. Then
measure candidate 720-row/60 and 900-row/60 modes; test 900-row/120 only as a
separate high-refresh candidate. Include at least ten minutes of gameplay
for a sustained-mode candidate, and extend if power or thermals are still
changing. Keep first-use hitch tests separate from these endurance runs.

Relevant code: `LaunchSettings.swift`, `LaunchPlan.swift`, `TitleScreen.swift`,
`HostIO.swift` and `app/PlayportKit/Titles/titles.json`.

**Done when:** there is a reproducible GPU-light baseline for CPU experiments
and evidence for any proposed title default, including image quality, pacing,
power and late-run performance. Do not change defaults merely to match an
external configuration. Native/high-refresh can remain an explicit choice.

**Progress (2026-09-29):** each of the five modes ran once
([record](../evidence/2026-09-29-hk-gameplay-baseline.md)), on new-game starts
(`tools/pad/hk-new-slot.txt`): slot 1's save moves as runs die or rest in it.
Neither free-running mode holds 120 FPS past the walk. Both 60 caps hold 60
for ten minutes with no frame over 50 ms. 720/60 raises no thermal pressure,
at 2.8 W for the whole phone. **Decided (2026-09-30):** 720 rows at 60 FPS is
the default for every game with nothing set (`LaunchSettings.defaultScreen`,
`defaultFrameLimit`). Native and free-running stay a choice in Settings or on a
game's page. No further baseline passes are planned.

## 2. A/B FEX MaxInst

Use the baseline above and the game page's **Block size** (x86 emulator
section; `LaunchSettings.maxInst`, `pp ui --settings 'app-367520:{"maxInst":500}'`).
The per-game environment settings this step first named were removed in #41.
The effective value is in FEX's `[mono-cfg] … MaxInst=` line for a Mono title.
Start with `FEX_MAXINST=500` versus `5000`, keeping multiblock enabled.
Verify the effective runtime value rather than just the launch request. If
the result warrants it, add `1000` and `2000`.

Measure compile time, first-use tails, translations, steady-state work/power
and code-buffer rollover. Smaller blocks can reduce compilation bursts while
increasing dispatch/chaining costs; neither block count nor start time alone
settles the choice. Check both Hollow Knight and The Witcher 3 before proposing
a global default.

**Confound:** `FEX_MULTIBLOCK=0` also disables Hollow Knight's Mono optimization
path, which requires multiblock and MaxInst ≥500. A later multiblock-off test
is a combined diagnostic experiment, not an isolated block-compilation A/B.
Do not change x87 precision or memory ordering in this sweep.

**Progress (2026-09-30):** Hollow Knight at 720/60, 500 against 5000, A/B/B/A
([record](../evidence/2026-09-30-hk-maxinst.md)): the same compiles, work per
frame, CPU power and tails. So 5000 stays for it. A quick check on The Witcher 3
(one run each, [record](../evidence/2026-09-30-witcher3-counters-maxinst.md)),
with both P cores busy, agrees.

**Done when:** repeated runs support a per-title/global setting or retaining
5000, with no correctness regression and an explicit steady-state tradeoff.

## 3. Remove release measurement producers, then measure

Audit all producers, not only sampler startup:

- `patches/wine-port/0054`: sync/event/wait/yield/delay counters, contention
  timing, QPC histogram and thread-alert instrumentation;
- `patches/madeira-unix/0037`: server-request and pending-wait timing;
- related producers reached when `MADEIRA_NO_DIAGNOSTICS=1`.

Preserve the fast CNTVCT QPC implementation and actual synchronization,
adaptive-yield and ECO behavior. Some critical-section history is already
compiled out. QPC's TID-hashed histogram uses plain updates; do not describe
it as one shared atomic counter or use the old syscall profile as its cost.

**Choose the build design first.** Dev and release currently share native
artifacts (decision 0009). A cached runtime diagnostic flag preserves that
model and permits release-equivalent measurements in the dev app. Compile-time
removal instead requires separate native artifacts, stage digests, staging
and verification, and a new decision if changing that architecture. The app's
`PLAYPORT_RELEASE` condition does not automatically apply to Wine. Avoid
per-call environment lookups and allocation-dependent early initialization.

**Audit (2026-09-29, patched trees of `a2f29a31`).** Every consumer below is a
line the samplers print (`[xp-api]`, `[srv]`/`[srv-t]`, `[sync-census]`), and
0018 does not start those samplers under `MADEIRA_NO_DIAGNOSTICS`. So in the
release app each producer's work is read by nothing.

| Producer | Where (series) | Hot path, cost per call | Keep |
| --- | --- | --- | --- |
| x64→EC call counter; every 64th target into a ring | FEX `Module.S` (`fex-port` 0061) | every x64→EC transition: `ldadd` on one of 16 sp-sharded lines, a second `ldadd` and a store for every 64th call | nothing |
| FPCR-write and EC→x64 counters | FEX `Module.S` (`fex-port` 0061) | `stadd` on a sharded line per event | the FPCR write itself |
| QPC gap histogram | PE `time.c` (`wine-port` 0054) | every `QueryPerformanceCounter`: TID read, plain stores into a TID-hashed slot | the CNTVCT fast path |
| critical-section contention: count, `cntvct` wait timing, 6-bucket histogram, ring | PE `sync.c` (0054) | contended enters only (already slow): about 5 atomics | the lock |
| spin-acquired and wake counters | PE `sync.c` (0054) | one global atomic per spin acquisition or contended leave | the lock |
| WaitOnAddress, WakeSingle/All counters | PE `sync.c` (0054) | one global atomic per call | the wait |
| Set/Reset/PulseEvent, Wait{Single,Multiple}, zero-timeout counters | unix `sync.c` (0054) | 1–3 global atomics per call | nothing |
| yield and delay counters, delay histogram | unix `sync.c` (0054) | 1–2 global atomics per call | the adaptive-yield streak, ECO poll |
| `ios_qpc_syscalls` | unix `sync.c` (0054) | global atomic per slow QPC (once a second per thread) | nothing |
| alert wake/wait counters; wake stamp and wake-latency histogram | unix `sync.c` (0054) | each futex alert: global atomic, `mach_absolute_time` and a store; each wake: a timer read and three atomics | alert-spin (default 0) |
| server round-trip census | `server_ios.c` (`madeira-unix` 0037) | every server request: 2 `mach_absolute_time`, a TEB-hash probe, 2 plain adds; every blocked select: 2 timer reads | nothing |
| `ios_srv_req_count` | `server_ios.c` (Madeira) | plain add per request | nothing |
| `ios_affinity_sets` | `thread_ios.c` (Madeira) | atomic per affinity set (rare) | the set |
| DXMT `[shader-time]` timer, FEX disk-cache census, FEX SMC counters | dxmt 0005, fex 0003/0004 | compile or invalidation time only (cold) | — |

**Progress (2026-09-29):** a cached flag, `ios_counters_on`, gates all of these.
Dev and release keep sharing their artifacts, and a dev A/B uses Settings'
Diagnostics, Runtime counters, or `pp perf --no-counters`
([record](../evidence/2026-09-29-release-counters.md)). Played on the phone.
An on/off A/B at 720/60 found no difference within 1 % in work, CPU power or
tails, so the counters' cost is too small to resolve there. So did a quick
Witcher 3 check with both P cores busy ([record](../evidence/2026-09-30-witcher3-counters-maxinst.md)).

The x64→EC counter is the busiest producer. The earlier list missed it. The
loader's export channel for a cached flag exists:
`load_ntdll_functions` (and the ec-child path) writes PE ntdll data exports
(`ios_teb_tsd_offset`) before `LdrInitializeThunk`, so before any guest code.
FEX already imports `ios_teb_tsd_offset` from ntdll the same way.

**Done when:** source inspection confirms disabled producers do not perform
the measurements, enabled diagnostics still work, host checks and release
verification pass, and controlled device runs quantify the effect. Report
zero or inconclusive benefit honestly; log-volume reduction is not a CPU
measurement.

## 4. Re-test a title-specific helper-QoS policy

On the current runtime, compare default QoS with selected named helpers at
utility, keeping the game's frame-critical thread unchanged. Separate
render/encode workers from genuinely background workers rather than treating
all named helpers as interchangeable. Resolve precedence between named-thread
overrides and later ECO-generation updates before proposing a shipped policy.

Measure whole-phone power and hitch tails as well as CPU power. QoS is a
scheduler hint, not guaranteed core affinity. Repeat at the intended title
resolution/cap; a saving at 720 rows does not establish sustainable native/120.

**Done when:** a per-title policy has repeatable benefits without unacceptable
tail-latency or loading regressions. Keep the existing policy if the measured
power saving trades away responsiveness. Do not ship an indiscriminate global
utility override.

**Progress:** not run; the plan closed without it.

## 5. Reduce memory cost separately

Retain adaptive sizing and exhaustion handling. Test 512/640 MiB against the
current allocation on long cohort routes, watching head/tail growth, alias
entries, code-buffer shrink/rollover and exhaustion. The short-run high-water
marks alone do not establish safe capacity for a whole game or launcher.

Investigate stripping PE debug sections with symbols retained separately.
The earlier build had 40.5 MiB of debug sections within 160 MiB of copied Wine
images; remeasure actual image/pool size after stripping rather than assuming
file-size savings equal runtime savings. Check loading, relocation and
symbolication remain usable.

**Progress (2026-09-29):** the Wine PE set is staged without its DWARF
(`build/stages/wine-pe-strip.py`). Across the 56 runtime images Hollow Knight
loads, that is 64.5 MiB less `SizeOfImage` to copy into the pool, and the COFF
symbols stay ([record](../evidence/2026-09-29-pe-debug-strip.md)). Hollow
Knight's pool head is 132 MiB against 203. The Witcher 3 ran five minutes in a
384 MiB pool ([record](../evidence/2026-09-30-witcher3-small-pool.md)): it used
318 MiB, played the same, and the app's footprint was 970 MiB smaller. One room
of one save does not establish the capacity a long session needs.

**Done when:** measured resident savings and adequate runtime headroom justify
a sizing/staging change. Recheck both cohort titles and release packaging.
Smaller pools must not silently reduce FEX's useful code-buffer capacity.

## Deferred work and reopening criteria

| Work | Reopen when |
| --- | --- |
| Remove the rpmalloc lock | Allocation-free, sampled contention/hold timing implicates it, or a repeatable workload shows a lock-off benefit. Retain the TEB identity fix; test thread teardown, concurrent allocation and exception re-entry. The previous no-gain A/B is not proof of correctness without the lock. |
| Redesign call-return resets | Controlled timing correlates reset bursts with material frame stalls. Preserve invalidation safety and restored call-return prediction; virtual-byte totals alone are insufficient. |
| Madsync/APC redesign | A frame-limiting thread spends roughly >5% of its time in server round trips with GPU headroom, or a reproducible power benefit justifies the correctness work. Follow decision 0023; do not enable madsync while silent APC/I/O failures remain. |
| Swift `-O`, hidden HUD initialization | Profiling or an isolated A/B establishes meaningful overhead. Preserve optional HUD usability and distinguish the app shell from already optimized packages. |
| FEX cache policy/disk cache | New evidence isolates cache behavior; account for the prior warm-cache allocator crash and lack of demonstrated hitch improvement. |
| Further DXMT work | GPU time, bandwidth or whole-phone power measurements identify a remaining cost. The compression fix does not rule out GPU/fabric work. |

## Evidence and decisions to carry forward

- [Patch A/B: allocator lock, DXMT build and return prediction](../evidence/2026-09-27-patch-ab.md)
- [First-run stutter: reset timing, disk cache and AOT](../evidence/2026-09-26-first-run-stutter.md)
- [FEX configuration and memory ordering](../evidence/2026-09-28-fex-memory-ordering.md)
- [Release logging experiment](../evidence/2026-09-25-release-build.md)
- [Helper QoS, including periodic stalls](../evidence/2026-09-25-hk-thread-qos.md)
- [720-row gameplay](../evidence/2026-09-25-hk-720-gameplay.md)
- [Lossless compression](../evidence/2026-09-26-hk-lossless-compression.md)
- [Whole-phone power and thermal budgets](../evidence/2026-09-26-hk-power-budget.md)
- [Server-sync measurements](../evidence/2026-09-28-server-sync.md), [decision 0023](../decisions/0023-in-process-sync-stays-off.md)
- [JIT pool sizing and high-water marks](../evidence/2026-09-28-jit-pool.md), [exhaustion stop](../evidence/2026-09-28-jit-pool-stop.md)
- [Shared dev/release runtime: decision 0009](../decisions/0009-dev-and-release-builds.md)

Implementation remains subject to the repository's patch-series rules. Each
runtime change needs host checks and a UI-driven phone play; a performance
claim additionally needs the controlled measurement above. This plan changes
no existing defaults or decisions by itself.
