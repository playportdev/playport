# KosmicKrisp residency commits: additions at allocation, removals in batches (PLA-465)

**Linear:** [PLA-465](https://linear.app/playportdev/issue/PLA-465) (this work), parent
[PLA-455](https://linear.app/playportdev/issue/PLA-455); follows PLA-464 (large command BO pool).
**Change:** `patches/mesa` 0129.
**IPAs (dev):**
- measured: `Playport-26.5-72d2e117.ipa`, sha256
  `72d2e117614f7fabdc6e080c67729140c33095f3a1554d1ed32214efe9af80d2` (HEAD `e4c813f`);
- final 0129 (`[kk-residency]` only when something changed), smoke-checked only:
  `Playport-26.5-fecaccea.ipa`, sha256
  `fecaccea26c5b41d01569ffd117217092b4c95112f8a286f15f8ae12b8a67dd1`.

**Result:**
- After PLA-464 the Witcher 3 residency set hardly changes in play. Over the last 90 s of each run
  there were 17–69 additions and 0–2 removals.
- Upstream's commit at every submit still ran **31,482 and 36,607 times** in those 90 s, on the
  queue threads: 158 and 161 ms in total, 9 commits over 1 ms each, the longest 2.9 ms.
- Under 0129 the same window has **17 and 69 commits** (4.8 and 17.2 ms in total, longest 1.4 ms).
  They run on the allocating threads, not the queue threads.
- **No frame-rate or hitch change is attributable to it.** Long frames (300–420 ms) remain in both
  arms, at the same counts. In these runs no commit was near 200 ms: the two 212/229 ms commits of the
  [trace](2026-10-28-witcher3-trace-breakdown.md#4-residency-set-commits) did not recur, under
  either arm.

## 1. What Metal does (Mac)

Checked on the Mac (M1 Pro, macOS 27.2) with a 500-allocation, about 2.5 GiB set attached to an
MTL4 command queue. The probes are `$PLAYPORT_BUILD/pla465/rs.m` and `rs2.m`, built with
`clang -fobjc-arc -O2 … -framework Metal -framework Foundation`.

- **A commit costs roughly in proportion to the bytes added.** Add one heap and commit:

  | Heap | Add + commit |
  | --- | --- |
  | 256 KiB | 15 µs |
  | 2 MiB | 64 µs |
  | 8 MiB | 224 µs |
  | 32 MiB | 0.9 ms |
  | 128 MiB | 4.7 ms |

  A commit after removals takes 0.3–0.6 µs, and one after 16 removals 2 µs. A commit without a change
  is about 0.
- **`requestResidency`** took 80 ms the first time and about 1 µs after that.
- **A removed allocation stays alive, held by the set, until the next commit.** After
  `removeAllocation` without a commit, a weak reference to the heap was still live. It was released
  at the commit. An allocation added and never committed is likewise held until it is removed.

So deferring a removal's commit holds the freed memory a little longer, and never frees memory still
in the set. An addition must be committed before a submit that uses it.

The phone's IOGPU may differ in scale, but the phone counters below agree in kind: under 0129 the
commits after removals are rare and cheap.

## 2. The change (mesa 0129)

- **Additions.** `kk_device_add_{heap,buffer}_to_residency_set` commits the set and requests residency
  before `kk_alloc_bo`, or an import in `kk_AllocateMemory`, returns. A submit that uses the
  allocation happens after that, so `kk_device_make_resources_resident` commits nothing for
  additions. The commit's cost falls on the allocating thread, which already pays for `newHeap`.
- **Removals.** Removals wait until they hold 64 MiB or the oldest is 1 s old. A submit then commits
  them, without waiting on a commit another thread is running. Any addition's commit takes them too.
- **No heap.** When Metal gives no heap, `kk_alloc_bo` commits the waiting removals, which releases
  them, and tries once more.
- **A/B switch.** `MESA_KK_RESIDENCY=submit` restores upstream's commit at every submit. With
  `MESA_KK_BATCH2`'s `residency` item (0091), it commits only after a change.
- **Counter.** `MESA_KK_DEBUG=memory` (on in dev builds) logs `[kk-residency]` about once a second:
  additions, removals, commits for additions and for removals alone, their total and longest time,
  those over 1 ms, and the removals still waiting.
  - The runs below used the first build of the counter, which printed every second.
  - The committed 0129 prints only an interval in which the set changed or was committed, so a dev
    run's log stays quiet in steady play. That build is §4's final IPA, smoke-checked only.

## 3. Host checks

- **Mock-driver suite.** `build/mesa-host-test/run.sh .work/run/mesa/mesa .work/run/mesa/host
  .work/run/mesa/hosttest` passed, including the new `kk-residency-test.c`. That test links the real
  driver's archives on mock Metal and checks:
  - an addition is committed at allocation, and a submit then commits nothing;
  - a removal waits through 100 submits under the limits;
  - an addition's commit takes waiting removals;
  - the 1 s and 64 MiB limits;
  - no heap: a commit and one retry, and a failure when nothing is waiting;
  - `submit` mode with and without the batch2 item.

  The mock's residency set does nothing, so this checks the scheduling only. The command-pool test's
  OOM cases now commit waiting removals first, so that its eviction path is still what is tested.
- **`./pp test --quick`** passed.
- **`./pp build`**: 90 checks passed, 0 failed (the IPA above). It changed no build records.

## 4. Phone

iPhone18,4, iOS 27.0.1, on battery (80 % → 73 %), app upgraded in place.

**Hollow Knight**, explicit Vulkan (DXVK/KosmicKrisp) with `MESA_KK_DEBUG=memory`:
- first frame +10.22 s, `first-frame+10` passed, normal title menu in `screen-stop.png`
  (`.work/ui-runs/pla465-hk-vulkan`);
- with defaults (DXMT): +10.01 s, passed (`.work/ui-runs/pla465-hk`).

On the final IPA `fecaccea…`, also explicitly Vulkan:
- first frame +10.32 s, `first-frame+10` passed, title menu (`.work/ui-runs/pla465-hk-vulkan-final`);
- six `[kk-residency]` lines in the whole run, all at startup.

These are smoke checks only.

**The Witcher 3 4.x** (D3D12, vkd3d-proton/KosmicKrisp), the PLA-455 recipe, in the order
alloc-1, submit-1, submit-2, alloc-2:

```sh
./pp perf --title app-292030 --secs 150 --cool 8 --cool-max 20 \
  --settings '{"graphicsOptions":"MESA_KK_DEBUG=memory[ MESA_KK_RESIDENCY=submit]"}' \
  --pad first-frame+10:witcher3-continue --pad first-frame+50:witcher3-walk \
  --shot first-frame+60 --shot first-frame+140 --out .work/perf/pla465-ARM-N \
  --expect-ipa 72d2e117…
```

All four runs reached Kaer Morhen gameplay and completed. Window +60..150 s
(`pp perf --compare … --window 60:150`; `[kk-residency]` sums over each run's last 90 lines):

| Run | fps | p99 ms | p99.9 ms | ≥100 ms | >150 ms | max ms | footprint MiB | adds | removes | commits | commit ms | >1 ms | longest ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| alloc-1 | 24.8 | 66.69 | 300.11 | 4 | 3 | 400 | 6088 | 69 | 0 | 69 | 17.2 | 1 | 1.4 |
| submit-1 | 21.5 | 75.03 | 366.80 | 9 | 4 | 417 | 6035 | 33 | 0 | 31,482 | 158.4 | 9 | 2.9 |
| submit-2 | 24.6 | 66.69 | 366.80 | 3 | 3 | 375 | 6077 | 60 | 1 | 36,607 | 161.4 | 9 | 2.2 |
| alloc-2 | 24.9 | 66.69 | 358.46 | 3 | 3 | 375 | 6024 | 17 | 2 | 17 | 4.8 | 0 | 1.0 |

- **Commits.** Under `submit`, the commits are about 350–400 a second, as in the trace. Each is
  cheap: 5 µs on average.
- **Commit time.** 0129 removes about 160 ms of queue-thread commit time per 90 s: 0.2 % of one
  thread. It does not show in frame rate. Submit-1's lower fps came with its different power budget
  (2,199 mW against 769), and submit-2 matches the alloc runs.
- **Long frames.** The 300–420 ms frames occur under both arms, at the same counts, and none of the
  alloc runs' commits exceeded 1.4 ms in the window. So they have another cause.
- **Startup.** The longest per-second commit was 37 ms (alloc) and 22 ms (submit), during loading,
  when about 100–250 allocations are added.
- **Memory.** The footprint does not change measurably (6024–6088 MiB, both arms). Removals waited
  briefly: at most 6 (0.8 MiB) waited at a time in either alloc run.

## 5. Limits

- **The 200 ms commits.** The trace's 212/229 ms commits were not reproduced, under either arm.
  These runs were not traced under Instruments, and the trace ran in the Serious thermal state. If
  they recur, they now fall on an allocating thread, not a queue submit. The Mac System Trace of
  step 4 is not needed on this evidence.
- **Small samples.** Two runs per arm, on battery, with different power budgets. No frame-rate or
  hitch claim is made.
- **RDR2 not run.** The memory-tight title, where `MESA_KK_BATCH2=1` once went past the limit
  (decision 0152), was not run on this IPA. The change holds at most 64 MiB or 1 s of freed memory
  longer.
- **Only The Witcher 3 measured.** No other KosmicKrisp title was measured beyond the Hollow Knight
  smoke check.
