# FEX's `yield-os`/`wait-os` PAUSE: Witcher 3's spinners are its dispatchers, not RenderThread (PLA-462)

**Linear:** [PLA-462](https://linear.app/playportdev/issue/PLA-462), parent
[PLA-455](https://linear.app/playportdev/issue/PLA-455).
**Change:** `patches/fex` 0084, commit `be544a8`; follow-ups § 5 (fex 0085–0087, madeira-unix 0223;
matrix IPA `f7f28f40`).
**Dev IPA:** `Playport-26.5-df7b13bc.ipa`, sha256
`df7b13bc8c960de306c5cbe4638378a9805ac7cead1fb27512e8fa8f6ef91b5e`.
Built on Linux; the Mac was used only for host execution of the emitter test and a Mach-trap probe.

## Result

- `MADEIRA_FEX_PAUSE=yield-os[:K]` is available, opt-in. The counter, trap cadence and preserved
  x0/x16/NZCV were checked by running the emitted sequence on an arm64 Mac. Both K=64 and K=256
  reached Witcher 3 gameplay on the phone.
- **No default change.** K=256's single run has a better mean and tail than the single YIELD run,
  but battery charge, thermal budgets and camera positions differ. K=64's mean is worse under a
  tighter clamp. This is a pilot, not the rested/hot interleaved acceptance matrix of PLA-462/0163.
- **The core-use goal is not established.** RenderThread still uses 65–71% of a core in the
  sustained windows, against 68% under YIELD. This does not demonstrate that it gave up its E core.
- **Matrix (§ 5.1), with trap telemetry:** `yield-os` traps average 47–133 µs, so they really do
  leave the core. But the threads that spin are RenderDispatcher1/2, which spend 61–78% of their
  time in traps. RenderThread spends 7–26% there and still uses about 63–73% of a core in every arm.
  `yield-os:256` and `wait-os:128:200` keep the tail no worse than YIELD with no FPS gain;
  `wait-os:128:50` is worse. No default change.
- The ARM64EC ntdll's QPC already reads the generic timer inline on its steady-state path; no QPC
  change was made.

## 1. What 0084 does

The ARM64EC iOS frontend parses `MADEIRA_FEX_PAUSE` before emitting code:

| Value | Behaviour |
| --- | --- |
| Unset, `yield`, or unrecognised | Existing ARM YIELD |
| `wfe`, `isb` | Existing 0083 modes |
| `yield-os` | Yield to the scheduler every 128 PAUSEs |
| `yield-os:K` | Every K PAUSEs; decimal K in 1–4095 |

Each guest frame has a zero-initialised `IosPauseCount`, appended after the existing iOS fields so
no existing assembly offsets move. Each PAUSE increments it. Before K, the emitted code stores the
count and executes YIELD. At K, it stores zero and executes Darwin's raw `swtch_pri` Mach trap:
`svc #0x80` with x16 = −59. There is no Wine syscall transition or C helper call. The sequence saves
and restores x0 (a guest register in FEX's ARM64EC layout) and x16 in FEX scratch registers; SUB and
CBZ test the count without setting NZCV, which holds guest flags.

This counts **cumulative PAUSEs since the last trap**, not consecutive PAUSE instructions or elapsed
spin time. It neither identifies a particular lock nor resets when a spin loop exits. It affects
all translated x64 PAUSEs in the process, not native ARM64EC code's own waits.

The existing disk-cache key includes the whole variable, including K (`IosCodegenSwitches.h`);
the machine bucket also includes FEX's patched build revision. The log records the effective mode
and count, e.g. `FEX: pause mode=3 after=256 (yield-os:256)`. An invalid K falls back to YIELD.

### Why a Mach trap

Apple's published XNU sources show:
- [`syscall_sw.c`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/syscall_sw.c):
  Mach trap 59 is `swtch_pri`, with no arguments consumed.
- [`syscall_subr.c`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/syscall_subr.c):
  `swtch_pri` returns immediately if `thread_should_yield` is false. Otherwise it depresses the
  thread's priority and yields; its continuation aborts the depression before returning to user space.
- [`bsd_arm64.c`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/arm64/bsd_arm64.c):
  the Mach syscall return writes x0, unlike Unix syscall error handling. The emitted code restores x0.

This is a real scheduler yield, not a fixed sleep and not WFE. It does not guarantee how long the
caller stays off-core. Its boolean return queries whether another thread is runnable, not whether
one particular context switch happened. The raw trap number/ABI is a Darwin-specific dependency.

## 2. Host checks

**Linux:**
- `./pp test --quick`: passed, including the name/secret/pin/series checks and host tests.
- `./pp build`: passed, 90 IPA checks, zero failed. `app/artifacts.tsv` was committed with 0084.
- `tools/tests/test_fex_pause_yield_os.py` compiles the parser directly from the patch and checks
  unset, existing modes, default K, boundaries and invalid values. It also compiles the new emission
  header with FEX's actual CodeEmitter and disassembles the words with `llvm-mc` for K=1, 64 and 4095:
  correct branches/trap number, saves/restores, and no flag-setting instruction.
- The emitter check needs `$PLAYPORT_BUILD/run/fex`; it skips without a FEX build tree. The parser
  check does not. This is not a full Linux FEX execution/ASM test suite.

**Mac:** M1 Pro, macOS 27.2, mirrored patch and FEX headers under `$PLAYPORT_BUILD/pla462`:
- `python3 -m unittest -v tools/tests/test_fex_pause_yield_os.py` with `PLAYPORT_BUILD` naming that
  fixture: parser and native execution passed; disassembly skipped there because `llvm-mc` was absent.
- The emitted sequence ran 57 PAUSEs at K=1 (57 traps), 157 at K=3 (52), and 6407 at K=128 (50).
  The count incremented/reset at K and x0/x16/all 16 NZCV combinations were preserved.
- Separate raw-trap probe `$PLAYPORT_BUILD/pla462/abi.c`: 200,000 idle traps, about 0.30 µs each;
  20,000 with twice as many busy workers as CPU cores, about 52.39 µs each. No mismatches in the
  tested GPRs (x1–x8, x10–x15, x17, x19–x28), four representative vector values, or NZCV. This
  checks current macOS behaviour, not every register on every Darwin version.

Full Swift tests and release-variant verification were not run for this runtime-only patch.

## 3. Phone pilot

iPhone18,4, iOS 27.0.1. Upgrade in place, unattended, no charger. The owner chose one 150 s run per
arm rather than the full matrix. CPU sampling was on in all three. Before each arm `--cool 8
--cool-max 20` waited for the rest interval and logged pressure zero; all launched at Nominal. This
is not proof of a cold phone. Order: YIELD, K=64, K=256.

```sh
./pp perf --title app-292030 --secs 150 --cool 8 --cool-max 20 --cpu-prof \
  --settings '{"runtime":"short-reserve-mb=6144 env.MADEIRA_FEX_PAUSE=MODE"}' \
  --pad first-frame+10:witcher3-continue --pad first-frame+50:witcher3-walk \
  --shot first-frame+60 --shot first-frame+140 \
  --expect-ipa df7b13bc8c960de306c5cbe4638378a9805ac7cead1fb27512e8fa8f6ef91b5e \
  --out .work/perf/pla462-ARM
```

`MODE` is `yield`, `yield-os:64`, or `yield-os:256`. The game's menus initially create 1302x600
swapchains; gameplay creates 1564x720 in all three (`[kk-wsi] create chain` and the HUD). Each run
loads the Kaer Morhen save and the pad walks. The +140 s screenshots show different final positions:
YIELD faces a bright window, K=64 faces the fireplace/Yennefer, K=256 faces a room divider. The same
input script did **not** make the final views identical. Nobody played manually.

+60..150 s (`pp perf --compare ... --window 60:150`; >100/>150 and max from `hitches.txt` in that
window, rather than the whole-run summary):

| Mode / run suffix | FPS | p99 ms | p99.9 ms | >100 ms | >150 ms | max ms | GPU ms | min budget mW | battery |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| YIELD / `yield` | 24.4 | 75.03 | 350.13 | 14 | 6 | 425.15 | 32.84 | 1688 | 57→54% |
| K=64 / `os64` | 19.7 | 83.36 | 383.47 | 6 | 4 | 400.14 | 30.53 | 660 | 53→49% |
| K=256 / `os256-retry` | 25.9 | 66.69 | 391.81 | 5 | 3 | 408.48 | 30.79 | 769 | 47→43% |

Directories are `.work/perf/pla462-SUFFIX`. First frame was +21.33, +21.16 and +21.32 s respectively;
all completed first-frame+150, and the FEX log confirms mode 0, mode 3/64, and mode 3/256. YIELD
reached Fair, both yield-os arms Serious. P-core use in the window is only 0.3–2% of one core.

An earlier K=256 attempt (`.work/perf/pla462-os256`) was cancelled **before settings or Play** because
Playport left foreground. Input stopped. The owner explicitly authorised resumption; only the fresh
`os256-retry` is scored. The failed attempt and its logs remain intact.

### Thread use and profiles

Means of the six 15 s `threads.txt` windows starting at +60..135 s; CPU percent is of one core:

| Thread | YIELD | K=64 | K=256 |
| --- | ---: | ---: | ---: |
| RenderThread | 68.3% | 64.8% | 70.5% |
| MainThread | 35.2% | 33.2% | 36.0% |
| RenderDispatcher1 | 26.5% | 21.8% | 22.0% |
| RenderDispatcher2 | 25.0% | 21.5% | 20.8% |

The three `profile.txt` files are retained. In K=64's profile the command-ring area
`witcher3.exe+0x1c69d00` remains prominent, while QPC's share is lower. These are sampled running
threads across the whole run, not a controlled measure of time saved. A raw trap inside JIT code
also need not appear as ``libsystem_kernel.dylib`swtch_pri`` (which already appears in the YIELD
baseline through other runtime paths). Neither a profile percentage nor the log's selected mode
counts how often the new trap actually descheduled a phone thread.

### Hollow Knight smoke

On the same IPA, with `env.MADEIRA_FEX_PAUSE=yield-os:64`, Vulkan (DXVK/KosmicKrisp), the scripted
pad connected before Play:

- `.work/pla462/hk-smoke`: first frame +12.37 s, completed first-frame+10. Its stop screenshot is
  black, so this run alone did not show the menu.
- Owner-approved longer recheck `.work/pla462/hk-smoke30`: first frame +12.43 s, completed
  first-frame+30; `screen-stop.png` shows the normal title menu. The log confirms mode 3/64.

Both final result events are successful, with no JIT-pool exhaustion or runtime-limit hits. The
longer run shows the black frame was not a permanent failure to reach the menu; it does not
establish why the earlier screenshot was black. These are smoke checks, not gameplay or a startup
performance comparison. The phone was left in unattended black-screen mode after testing.

## 4. QPC variant: already user-mode

The Linux disassembly of the shipped ARM64EC `ntdll.dll` agrees with `dlls/ntdll/time.c`:

```sh
llvm-objdump -d --no-show-raw-insn \
  --disassemble-symbols='#RtlQueryPerformanceCounter' \
  app/Sources/S1Probe/Runtime/arm64ec-windows/ntdll.dll
```

`#RtlQueryPerformanceCounter+0x40` is `isb; mrs x19, CNTVCT_EL0`. With an initialised frequency and a
sync less than one second old, it loads the offset, converts the timer with integer division and
returns; it does not call the Unix side or loop waiting for a resync writer. The slow/roughly
once-per-second resync calls `NtQueryPerformanceCounter`. Initialisation reads `CNTFRQ_EL0`.
The guest's x64→ARM64EC call, ISB, conversions and optional diagnostic counter work remain. There
may be scope to make these cheaper, but there is no steady-state QPC syscall to remove, and a
cheaper busy loop alone would not give the core back. No QPC option was changed in this pilot.

## 5. Follow-up on the workstation: trap telemetry and `wait-os`

Built on Linux only; **neither change has run on the phone** yet.

**Telemetry** (`patches/fex` 0085, `patches/madeira-unix` 0223). The trap path now reads `CNTVCT_EL0`
before and after the trap and adds to three per-thread frame counters: traps, traps under 48 ticks
(meant as 2 µs at 24 MHz, but see § 5.2), and ticks inside them. It uses only x0/x16, which are already saved, and SUB/LSR
rather than a compare, so NZCV is still untouched. The YIELD path is unchanged. Under a `yield-os` or
`wait-os` setting, the `[xp]` sampler reads them through TEB+0x1788 → CPU area+0x30 (offsets pinned by
static_asserts in FEX's `Module.cpp`) and logs `[xp-pause] HH:MM:SS.mmm -TID:traps/short/ms` per tick.
`pp perf` adds `yield-os N/s long P% in-trap Q%` to each thread's `threads.txt` row (`yield_os` in
`summary.json`). "Long" means the kernel took the thread off its core for 2 µs or more. This is the
scheduler evidence § 3 lacked.

**`wait-os[:K[:U]]`** (`patches/fex` 0086), mode 4. Every K-th PAUSE (default 128) is the raw Mach
trap `thread_switch(MACH_PORT_NULL, SWITCH_OPTION_DISPATCH_CONTENTION, U)`: `svc #0x80`, x16 = −61,
x1 = 3, x2 = U µs (default 50, range 1–5000). In XNU's
[`syscall_subr.c`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/syscall_subr.c)
that option does `assert_wait_timeout(..., U, NSEC_PER_USEC)` and blocks, whether or not anything
else is runnable. It is libdispatch's contention back-off. Unlike `swtch_pri`, it frees (or idles)
the core for U µs. The cost is up to U µs of extra latency when the awaited store arrives
mid-wait. x1/x2 (guest registers) are saved in TMP3/TMP4. The same counters time the wait.

**Host checks.** `tools/tests/test_fex_pause_yield_os.py` reconstructs each header through every
later patch in the series. It checks the parser (now including `wait-os` defaults, bounds and
malformed values) and disassembles the emitted sequences for `yield-os` K = 1/64/4095 and `wait-os`
(1,1), (128,50), (4095,5000), (64,65535). The arm64-Mac execution test now also checks x1/x2 and that
a wait is never short and averages at least U, but **it was not run**: no Mac took part in this
step. `./pp test --quick` and `./pp build` passed: dev IPA `Playport-26.5-f7f28f40.ipa`, sha256
`f7f28f407eea7bc4790e655b598b677d6f8454b95ca744381957ed874e5347f7`, not installed.

### Phone: Hollow Knight smoke

Upgraded in place to `f7f28f40` (charger connected, 68%). `.work/pla462/hk-waitos`, with
`env.MADEIRA_FEX_PAUSE=wait-os:128:50` and the scripted pad: first frame +12.31 s, completed
first-frame+30. Its stop screenshot shows the normal title menu, and the log has
`FEX: pause mode=4 after=128 usec=50`. This is a smoke check, not gameplay.

The telemetry works on the phone: 136 `[xp-pause]` lines, 9,524 traps. As logged, they averaged
3.44 ms each, but that figure is wrong by a unit: see § 5.2. Read at the phone's timer rate, each is
about 83 µs, at least the 50 µs asked for.

### 5.1 The Witcher 3 matrix

Same IPA `f7f28f40`, same command as § 3 with `--out .work/perf/pla462m-SUFFIX`, under one
`pp phone lock` (`.work/pla462/matrix.sh`). **Charger connected throughout** (battery 80% at every
run), unlike § 3. Nobody played manually; the § 3 pad script ran in every run.

- **Rested:** each run waited `--cool 8 --cool-max 20` and had `--cpu-prof`. Order: YIELD,
  `yield-os:256`, `wait-os:128:50`, `wait-os:128:200`. All launched at Nominal.
- **Hot:** straight after, back to back, no `--cpu-prof`, reverse order. All launched at Serious.

Every run reached gameplay (`1564x720`; first frame +21.1…+23.1 s), and the FEX log confirms each
run's mode. One sample, the hot `wait-os:50` +140 s screenshot, shows Kaer Morhen gameplay.

+60..150 s (`pp perf --compare … --window 60:150`; >100/>150 and max from `hitches.txt`):

| Run | FPS | p99 ms | p99.9 ms | >100 ms | >150 ms | max ms | GPU ms | CPU mW |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| rested YIELD `r-yield` | 24.5 | 66.69 | 358.46 | 7 | 6 | 400.1 | 32.85 | 321 |
| rested `yield-os:256` `r-os256` | 23.7 | 75.03 | 350.13 | 3 | 3 | 375.1 | 32.98 | 312 |
| rested `wait-os:128:50` `r-w50` | 22.3 | 83.36 | 325.12 | 15 | 6 | 383.5 | 27.91 | 278 |
| rested `wait-os:128:200` `r-w200` | 24.0 | 75.03 | 375.13 | 5 | 3 | 425.1 | 33.92 | 291 |
| hot `wait-os:128:200` `h-w200` | 24.4 | 75.03 | 358.46 | 5 | 3 | 483.5 | 33.40 | 330 |
| hot `wait-os:128:50` `h-w50` | 19.3 | 108.37 | 483.51 | 27 | 9 | 741.9 | 30.68 | 480 |
| hot `yield-os:256` `h-os256` | 20.6 | 75.03 | 433.49 | 4 | 4 | 616.9 | 40.03 | 189 |
| hot YIELD `h-yield` | 21.3 | 75.03 | 516.85 | 12 | 6 | 541.9 | 38.55 | 202 |

Each arm has one run per condition, and the hot block's order confounds heat with mode: `h-w200`
ran first, with the most budget left. **Read it as:**

- `wait-os:128:50` is worse on both phones: lower FPS and the most long frames (15 and 27 over
  100 ms).
- `yield-os:256` and `wait-os:128:200` have **tails no worse than YIELD** (3–5 frames over 100 ms
  against 7–12; 3–4 over 150 ms against 6). Their means are within 0.5–0.9 fps of YIELD's, except
  hot `wait-os:200` (+3.1), which ran first.
- Neither is a mean-FPS win, and none of this is enough to change a default.

**Where the traps go** (`[xp-pause]` re-read at 1 GHz by `.work/pla462/xpause-fix.py`, +60..150 s;
traps/s, mean time per trap, % of one core inside traps):

| Run | RenderDispatcher1 | RenderDispatcher2 | RenderThread |
| --- | --- | --- | --- |
| r-os256 | 8116/s, 76 µs, 62% | 7974/s, 78 µs, 62% | 4252/s, 47 µs, 20% |
| h-os256 | 5570/s, 110 µs, 61% | 5621/s, 108 µs, 61% | 1991/s, 133 µs, 26% |
| r-w50 | 5755/s, 121 µs, 70% | 5784/s, 121 µs, 70% | 648/s, 110 µs, 7% |
| r-w200 | 2115/s, 353 µs, 75% | 2117/s, 352 µs, 75% | 265/s, 294 µs, 8% |
| h-w200 | 2176/s, 356 µs, 78% | 2173/s, 351 µs, 76% | 257/s, 307 µs, 8% |
| h-w50 | 5554/s, 128 µs, 71% | 5607/s, 128 µs, 72% | 768/s, 109 µs, 8% |

- **`yield-os` does leave the core.** An idle `swtch_pri` returns in about 0.3 µs; here the mean is
  47–133 µs, so the kernel ran something else. `wait-os` waits are longer than U, as expected:
  50 µs → about 120 µs, 200 µs → about 350 µs.
- **The spinners are RenderDispatcher1/2, not RenderThread.** The dispatchers spend 61–78% of their
  time in traps. RenderThread spends only 7–26%, yet uses about 63–73% of a core in every arm:

| Thread CPU % of a core (`threads.txt`) | r-yield | r-os256 | r-w50 | r-w200 | h-w200 | h-w50 | h-os256 | h-yield |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| RenderThread | 68.2 | 65.5 | 70.8 | 69.5 | 68.0 | 72.5 | 63.3 | 68.2 |
| RenderDispatcher1 | 25.8 | 21.5 | 24.8 | 22.8 | 20.7 | 23.5 | 24.7 | 31.5 |

So the RenderThread core use that PLA-462 set out to cut is mostly not its PAUSE spin. The
dispatchers' fence polling does yield, but freeing that time did not raise FPS: the frame stays
bounded by RenderThread's own work and the GPU (GPU busy 74–89%).

### 5.2 A unit bug in 0085/0223, fixed in fex 0087

`[xp-pause]` as logged said a thread spent 13 s inside its traps in a 0.3 s tick, and that a
`wait-os:128:200` trap lasted 14.5 ms. 0085 timed traps with `CNTVCT_EL0`, while 0223 converted the
ticks at `mach_absolute_time`'s 24 MHz (timebase 125/3). The phone's generic timer runs about 41.67×
faster, consistent with the 1 GHz Armv8.6 fixes. That factor puts every `wait-os` trap at or above
its U, and the busiest dispatcher at about 100% of a tick. The same mismatch made the 48-tick "short"
threshold 48 ns, so no trap ever counted as short: the logged long/short split is meaningless and is
not used above. The 1 GHz figure is inferred from these runs, not read from the phone.

- **fex 0087:** ProcessInit reads `CNTFRQ_EL0`, sets the threshold to 2 µs of it
  (`FEX::Ios::PauseShortTicks`, clamped to 1–4095), and logs `short-ticks=` and `cntfrq=`.
- **madeira-unix 0223 (amended):** converts at `CNTFRQ_EL0`, logs `[xp-pause] armed: …, cntfrq N Hz`,
  and skips a thread's delta after a failed read.

Built as dev IPA `3a1133c2` (not installed). The next phone run's log will show the actual `cntfrq`.

## 6. Remaining gates

- **No default change.** The Witcher 3 keeps `short-reserve-mb=6144` with ordinary YIELD
  (decision 0163). Hollow Knight remains Works; The Witcher 3 remains Playable with issues.
- `yield-os:256` and `wait-os:128:200` passed 0163's tail criterion in single runs per condition.
  They gave no FPS gain, and the matrix showed RenderThread's core use is mostly not its spin. A
  per-title default would need repeated, order-balanced runs and a reason to want it, such as power.
  The `CPU mW` column is not comparable across the hot block's order.
- RenderThread's own work (`kk_UpdateDescriptorSets_impl`, AGX encoding, `kk_draw`, per the
  2026-10-28 trace breakdown) is the lever for its core, not PAUSE.
- The fixed telemetry (fex 0087) and the `wait-os` Darwin execution test have not yet run on the
  phone or a Mac respectively.
