# Large command BO reuse: host lifetime tests and Witcher 3

**Linear:** [PLA-464](https://linear.app/playportdev/issue/PLA-464)

## Baseline and regression

The [Witcher 3 Metal trace](2026-10-28-witcher3-trace-breakdown.md#3-kosmickrisps-command-buffer-heaps)
identified fresh Metal heaps for command allocations above 128 KiB, destroyed
on command-buffer reset: about 74 heaps/s and 176 MB/s in that trace.

The initial version of `build/mesa-host-test/kk-cmd-pool-test.c`, linked to the
unchanged mock driver's actual archives, reproduced this without a GPU:

```sh
python3 build/mesa-host-test/run-cmd-pool-test.py .work/run/mesa/hosttest/build
```

It failed the assertion that a command BO remains after resetting a recording
with one 208 KiB allocation. Log: `$PLAYPORT_BUILD/pla-464-red.log`.
This is a deterministic resource-lifetime repro, not a frame-rate baseline.

## Change

Mesa patch 0128 routes large `kk_pool_alloc` allocations through the owning
command pool. Idle BOs use seven power-of-two classes, 256 KiB through 16 MiB.
Allocation takes the smallest available sufficient class, or creates the
requested class; larger requests bypass the cache without class rounding.
Reset, implicit Begin reset, and free return BOs only when the recording no
longer owns them. End and submission do not return them. Vulkan's command-pool
external synchronization covers the cache.

Actual heap bytes in the idle cache are capped at **64 MiB per command pool**.
Returning BOs evicts the least recently returned/used idle BOs first, across
classes. Active recordings are outside this cap. A failed fresh device-memory
allocation empties the idle cache and retries once. Trim, pool destruction and
release-resources pool reset empty the idle cache. The small-BO free count is
also initialized and reset on trim, and its existing 32-BO cap is enforced
without the previous off-by-one.

Pooled BOs stay in the device residency set. `[kk-mem]` separates their live
count/MiB as `command-pooled`, included once in `bos`; active and small command
BOs remain `command`. `large-new` and `large-reuse` count successful new large
BOs and cache hits cumulatively. These counters share the existing process-wide
census scope: `command-pooled` can exceed 64 MiB across multiple command pools.
They do not count all other Metal allocations. Class rounding can also increase
the active allocation footprint.

## Host checks

Passed on Linux:

- `build/mesa-host-test/run.sh .work/run/mesa/mesa .work/run/mesa/host
  .work/run/mesa/hosttest`: full mock Metal/KosmicKrisp, NIR, descriptor and
  Zink/EGL host suite, exit 0. The command-pool regression checks all class
  boundaries, 100 stable reset/reuses without residency deltas, live-recording
  and pool isolation, cross-class LRU and the exact byte cap, trim,
  reset/free/Begin/destruction, alignment-driven class selection, oversize
  bypass, OOM eviction/retry and command-buffer error propagation. The
  32-small-BO cap is checked before and after trim. It observes real driver
  state and BO identities, not a separate allocator model. At the cap its
  census reads `command-pooled=4/64`; every BO count/byte category returns to
  zero after destruction. This is not Vulkan CTS or GPU execution.
- `./pp test --quick`, then full `./pp test` including Swift: all passed.
- `./pp check`: passed after restaging the verified local CEF payload with
  `python3 build/cef/stage-payload.py`. The first attempt compiled/linked but
  failed packing the missing generated dev CEF directory, the existing
  [PLA-382](https://linear.app/playportdev/issue/PLA-382), not a Mesa failure.
  No CEF source fix is part of this change.
- `./pp build`: signed dev IPA, **90 checks passed, 0 failed**:
  `.work/out/20261028-185100-51de9407/Playport-26.5-51de9407.ipa`, SHA-256
  `51de94075d296b76b9363398eb1157ead1466c9f5971511e02fedb0cb811530a`.

The first full mock-suite attempt found an incorrect regression expectation:
this mock uses 256-byte Metal heap alignment, not 16 KiB. Correcting the
oversize expectation made the focused test pass; production code was unchanged.

## Phone runs

Linux reached the phone over the network; no Mac or Instruments run was needed.
iPhone18,4, iOS 27.0.1, 80% charge and external power for both W3 runs. The app
was upgraded in place; its container was retained. Settings were session-scoped.

| Run | IPA SHA-256 | Result |
| --- | --- | --- |
| W3 before, `.work/perf/pla464-base-memory` | `cb61f71d8bce1ad9ab399f3bacbcdb8942239e6a65aee46058112bd48d50a00a` | First frame +19.03 s; UI run completed first-frame+150; Kaer Morhen gameplay in both screenshots. See analysis recovery below. |
| HK, `.work/ui-runs/pla464-hk-vulkan` | `51de94075d296b76b9363398eb1157ead1466c9f5971511e02fedb0cb811530a` | Explicit Vulkan (DXVK), first frame +11.27 s; first-frame+10 passed; normal title menu in `screen-stop.png`. Smoke, not gameplay/performance proof. |
| W3 after, `.work/perf/pla464-pooled-memory` | `51de94075d296b76b9363398eb1157ead1466c9f5971511e02fedb0cb811530a` | First frame +19.40 s; first-frame+150 and perf analysis passed, exit 0; Kaer Morhen gameplay in both screenshots. |

Both W3 runs use the PLA-455 Continue/walk recipe, no CPU sampling:

```sh
./pp perf --title app-292030 --secs 150 \
  --settings '{"graphicsOptions":"MESA_KK_DEBUG=memory"}' \
  --pad first-frame+10:witcher3-continue \
  --pad first-frame+50:witcher3-walk \
  --shot first-frame+60 --shot first-frame+140 \
  --out RUN --expect-ipa SHA256
```

The original baseline perf producer exited 1 on analysis, not during play:
my earlier `--dry-run` had appended a fake `launched` event with PID 0 into the
same output directory. The analyzer selected its nonce instead of the real
launch. Original files are preserved. The derived directory
`.work/perf/pla464-base-memory-analysis` removes **only the first two rows** of
its copied `run/events.jsonl` (the dry launch and `dry_run=true` result).
Its `analysis-provenance.txt` records the operation. `pp perf --analyze` on
that copy exits 0. All comparisons below use that copy. The real UI result
in the original is `ok=true`, `until_reached=true`, first-frame+150.

The first combined install/HK shell command also had a quoting error: install
succeeded, but UI argument validation rejected the settings JSON before launch.
The corrected standalone HK command passed. No game failure is attributed to it.

## Allocation result and memory cost

The pooled run ends with **81 new large BOs and 12,979 reuses**. Its last four
10-second census samples hold `large-new=81`, while `large-reuse` advances
9,575 → 10,711 → 11,851 → 12,979: **no new large BOs over roughly 30 seconds**,
while the game keeps recording work. This verifies warm reuse on the phone,
not merely lower live-allocation counts. The host test separately verifies
that reuse and return do not dirty the residency set.

Those last samples have aggregate `command-pooled` 201, 203, 213 and 203 MiB
(54–57 idle BOs), across the game's command pools. This is **not** a 64 MiB
device-wide cache; the limit is per pool, checked by the host regression.
The phone census does not expose individual pools. There was no device-memory
allocation failure in this play; longer gameplay and other scenes are untested.

The memory trade-off is visible. Mean app footprint over the comparison window
rises about **185 MiB**, consistent in scale with the retained cache. End
screenshots show Metal HUD app memory about **6.12 → 6.30 GB**, with available
memory **2.47 → 2.29 GB**. These are different camera positions, so not every
byte of the difference can be attributed to pooling.

## Performance: descriptive, not a sustained win claim

```sh
./pp perf --compare .work/perf/pla464-base-memory-analysis \
  .work/perf/pla464-pooled-memory --window 60:150 --json
```

Saved comparison: `$PLAYPORT_BUILD/pla-464-comparison.json`.

| +60..150 s | Before | Pooled |
| --- | ---: | ---: |
| FPS | 23.8 | 25.5 |
| p99 frame time, ms | 75.03 | 75.03 |
| p99.9 frame time, ms | 350.13 | 250.09 |
| frames ≥100 ms | 3 | 6 |
| GPU time/frame, ms | 33.46 | 31.20 |
| CPU million instructions/frame | 317.3 | 299.8 |
| mean app footprint, MiB | 5826.46 | 6011.90 |
| minimum power budget, mW | 1688 | 769 |

The script landed at different character/camera positions: the baseline's
+140 screenshot has Geralt close to the camera, the pooled run's is farther
back and shows a different view of the room. Thermal budgets also differ.
Do **not** claim a controlled FPS or hitch improvement: p99 is unchanged,
≥100 ms frames increase, and a single pair is insufficient. The directly
verified result is **large-command-heap reuse after warm-up**, at a measurable
retained-memory cost. Residency commit scheduling remains PLA-465.

## Limits and handoff

- No fresh Metal System Trace was taken; this does not measure kernel heap
  allocation CPU cost or total residency-set churn from other resources.
- Host tests record GS/tessellation pipelines and W3 exercises the shared
  large-allocation path. HK provides a DXVK launch smoke. No additional DXVK
  GS/tessellation gameplay gate was run: the known KCD compatibility entry
  says it is not installed, and no other installed title's use of those
  stages was established. No extra title was downloaded for this change.
- The cache is bounded per pool, not globally or by memory-pressure signals.
  Future content, more command pools and oversize requests can change its cost.
- PLA-42 and PLA-43 have the latest phone results. Site statuses remain in
  sync: HK **Works**, W3 **Playable with issues**; their prior best-known
  gameplay results are retained. Screenshots stay in the run directories.
- Phone sessions finished, no queued inputs remain, and the device lock is
  released. The candidate IPA remains installed. No performance defaults or
  game compatibility status was promoted based on this pair.
