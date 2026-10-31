# RDR2: KosmicKrisp command memory, audio underruns and the CPU split (l19 diagnostics)

**Linear:** [PLA-364](https://linear.app/playportdev/issue/PLA-364) (RDR2),
[PLA-476](https://linear.app/playportdev/issue/PLA-476) (plan `docs/plans/2026-10-29-sc-stock-cef.md`).

Four log-only patches measure what the PLA-476 design reports ranked first (KosmicKrisp allocator design, RDR2
audio, RDR2 CPU cores). Nothing they add changes what the runtime does. One RDR2 run (l19) read them. M = measured
(log or code), I = inferred, U = unknown. Times are the `[xp]` log's wall clock.

## What was added

| Patch | Lines | Gate |
| --- | --- | --- |
| mesa 0131 | `[kk-cmd-census]`: every 30 s after a `[kk-mem]` line, the command buffers alive, how many hold a recording, their upload and allocator MiB; buckets by queue/application, level, usage (once, simultaneous, reusable), pool flags and state (recording, ended-unsubmitted, submitted-once, submitted-2+) with ages; reusable primaries' direct and replayed submits; released recordings by hold time. `[kk-upload]`: each `kk_pool_alloc`/`kk_pool_upload` call site's requests and bytes, and for requests over 128 KiB the bytes asked, the power-of-two heap bytes given and those still owned | `MESA_KK_DEBUG=memory` (dev app only) |
| madeira-unix 0240 | `[thr-prio]` keeps its 200-line limit per Windows process (first 64), with `pid=` | `WINEDEBUG` (release: `-all`) |
| madeira-unix 0241 | `ml1065` adds the stream, window, frames written and delivery %, render callbacks, short callbacks, missing frames, and the longest gap between ReleaseBuffers; a `getbuf-thread` line names each stream's first GetBuffer caller (Windows pid/tid, pthread id, Mach port, priority, base priority, QoS) | not under `MADEIRA_NO_DIAGNOSTICS` (release) |
| madeira-unix 0242 | `[xp]` ends with `usr=` and `sys=` (ms per tick) | no `[xp]` sampler in release |

Checks: `kk-cmd-census-test.c` (mock Metal; `build/stages/mesa.sh … hosttest`, all host tests pass), the WoW64
audio host test with the new helpers mocked, `./pp test` (all passed), `./pp build` (dev, verify 90 checks
passed), `./pp check --variant release` (compiles). Release stays quiet by the gates above (inspection).

## The run

IPA `5db127bd39db95ffc04be39e05371ca0f25c43ce24bb19fca1f9b66b740be03f` (dev, HEAD `9d00208`), installed in place.
`pp phone status` before: 80 %, on power, no JIT timeout. One locked session
(`agent-notes/pla476/l19.sh`), no `pp perf`, unattended mode on.

- **HK** (`$PLAYPORT_BUILD/ui-runs/20261030T215237-hk-p476l19`): `ok:true`, first frame +10.44 s,
  until first-frame+10.
- **RDR2 l19** (`$PLAYPORT_BUILD/ui-runs/20261030T215326-rdr2-p476l19`): `arm15.sh`, keys
  `env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1 env.PLAYPORT_SC_LAYOUT=1`, `STORY_BY=420 UNTIL=600 WAIT=900`.
  `ok:true`, until first-frame+600; `pp ui` pulled the host log (no network drop).
  - First frame 21:55:06, Story pressed 21:56:10. The game's helper got kinds 1–6 (as A); no helper died; 0 SC or
    launcher `NO GAP FITS` (the only one is the game's 8960 MiB walk).
  - **The heavy scene** (I: the cabin, by l17/l18's pattern; no screenshot landed in it): 21:57:51 to 21:58:33,
    17–20 fps at 28–33 ms GPU per frame. `[footprint]` 5849 → 7610 MB at its start (graphics 2132 → 3728 MB).
  - **Then a black screen with the R★ spinner to the end** (shots +310 to +678), 60 fps at 0.6 ms per frame, 0.7
    cores, silent audio. At 21:58:36 the log says `[game-sc] re-sign-in after end (steam-language)` and
    `re-sign-in after end: no headroom (7585 MB), restart stays refused` (0155). l17 and l18 logged no re-sign-in
    and held the cabin. I: the game waits for a Social Club sign-in that 0155 refused; not shown.
  - Peak 7631 MB. No Playport jetsam (no JetsamEvent; the syslog shows iOS ending `diagnosticd` and
    `remotepairingdeviced` on highwater at 21:58:35). Thermal nominal, fair from 21:56:29 to 22:00:39.

## KosmicKrisp command memory (mesa 0131)

**Who holds it (M).**

| `[kk-cmd-census]` | 21:57:29 (before the step) | 21:57:58 (heavy) | 21:58:58 → end (black screen) |
| --- | --- | --- | --- |
| buffers / not holding | 1715 / 669 | 1715 / 29 | 1715 / 29 |
| upload held | 65.5 MiB | 900.2 MiB | 1018.4 MiB |
| alloc-added by held recordings | 14.4 MiB | 14.5 MiB | 14.4 MiB |
| allocators | 40 / 158.0 MiB, largest 18.2 | 45 / 680.6 MiB, largest 101.0, 14 over 8 MiB | 45 / 750.8 MiB, largest 119.6 |
| app primary **once** (ONE_TIME), pool RESET, submitted-once | n=1023, 63.9 MiB | n=1545, 814.9 MiB; ages <1 s 1014, 1–10 s 220, 10–60 s 311 | n=1661, 1016.6 MiB; at the end 1152 older than 60 s |
| app primary once, ended-unsubmitted | – | n=119, 83.9 MiB | n=2, 0.2 MiB |
| app primary reusable | 6 submitted-once, 0.8 MiB | 5 + 1, 0.7 MiB | 5 + 1, 0.7 MiB |
| app primary simultaneous | 3 + 3, 0.8 MiB upload, 14.4 MiB allocator, >60 s | same | same |
| reusable-primary submits direct / replayed (total) | 8024 / 338 | 9344 / 338 | 33095 / 338 |

- `[kk-mem]` agrees: `command=` 67 → 879 MiB (21:58:18) → 1028 MiB, and the census's held upload is 1018 MiB of it.
  At the step, command BOs (+961 MiB) and allocators (+593 MiB) are 1.55 GB of the graphics ledger's +1.84 GB
  (21:57:45 → 21:58:43).
- During the heavy scene `[kk-gpu]` shows 2000–2400 begins/s, nearly all ONE_TIME, at 17–20 fps: about 110–120
  recordings a frame. Released recordings by hold since the first submit, by the end: 130180 under 1 s,
  68361 in 1–10 s, 680 in 10–60 s, 384 over 60 s.

**Who asks for it (M, `[kk-upload]` at the end).**

| Site | Calls | Requested | Large: count, asked, rounded | Live (owned now) |
| --- | --- | --- | --- | --- |
| `kk_upload_vertex_params:1215` (VS→TCS output) | 42506 | 19113.5 MiB | 34486, 18727.3, 31620.0 MiB | 416.5 MiB |
| `kk_upload_tess_params:1285` (TCS output, patches) | 42506 | 18716.3 MiB | 33684, 18268.2, 31869.5 MiB | 421.2 MiB |
| `kk_upload_descriptor_root:1334` | 2784176 | 5947.6 MiB | – | – |
| everything else | | < 70 MiB each | none | – |

- The two tessellation scratch sites own all 838 MiB of live large BOs. Their mean request is 0.54 MiB, which the
  power-of-two classes give a 1 MiB heap: 1.69–1.74 × the bytes asked.
- Both sites stop growing after 21:58:33 (`+0.0` per line): the black screen records no tessellated draws, and the
  1661 recordings keep their scratch.

**The design's hypotheses.**

- **"Every reusable primary is recorded twice" holds no memory in RDR2 (M).** RDR2 re-begins its few reusable
  primaries every frame: 33095 direct submits, 338 replays. They hold under 1 MiB. **2A would free nothing here.**
- **The holders are ONE_TIME primaries, submitted once, re-begun late (M).** About 1000–1660 of them hold the
  upload memory. They are held from their submit until RDR2 re-begins the buffer, mostly within 10 s while it
  renders, and indefinitely once it stops (1152 over 60 s). Design §3 step 2's condition ("ONE_TIME buffers reset
  late") is met.
- **Allocator high-water (M).** Live recordings account for 14.4 MiB of the 750.8 MiB in allocators. The rest is
  what the 45 allocators kept from recordings already released, unchanged for six minutes of a trivial frame:
  nothing resets them (`MESA_KK_BATCH2` is off for RDR2, decision 0152).
- **U:** which pools the 1661 holders are in, and whether RDR2 records in those pools again during the black
  screen (a pool-thread reclaim needs that).

## Audio (madeira-unix 0240, 0241)

**Underruns over time (M, slot 1, the polled main stream, 48 kHz).**

| Window end | Delivery | Short callbacks / callbacks | Missing frames | Longest ReleaseBuffer gap |
| --- | --- | --- | --- | --- |
| 21:55:24 → 21:57:44 (menus, Story load) | 97–101 % | 0–30 / 469 | 0–13056 | 17–43 ms (109 once) |
| 21:57:51 | 77 % | 191 / 468 | 108288 | 40 ms |
| 21:58:03 | 55 % | 373 / 469 | 213760 | 31 ms |
| 21:58:14 | 44 % | 469 / 469 | 270080 | 37 ms |
| 21:58:21 | 47 % | 452 / 469 | 257024 | 40 ms |
| 21:58:33 | 46 % | 455 / 469 | 261888 | 28 ms |
| 21:58:43 → end | 94–100 % | 0–59 / 469 | 0–29440 | 17–43 ms |

- Delivery falls with the heavy scene and returns when it ends, as in the owner's run, l12 and l14 (40–80 %).
- **No stall (M).** The longest ReleaseBuffer gap in the starved windows is 28–40 ms, the same as before. No
  window has a gap over 200 ms, so rdr2-audio cause 2 (compression stalls of 1–4 s) is not seen here.
- **The producer slows, it does not stop (M + I).** The driver's GetBuffer count (every stream; slot 1 is the only
  RDR2 stream then) falls from about 190/s to about 89/s (`get_render_buffer #33000` at 21:57:51 to `#36000` at
  21:58:25). I: the producer's loop gets about half the CPU it needs.

**Who produces it (M).** RDR2 is pid `035c`.

- Slot 1 (`0x151f9dec0`, flags 0, polled): first GetBuffer by tid `0360`, priority 15, base 15
  (TIME_CRITICAL), QoS `0x21` (USER_INTERACTIVE). `0360` sets every other thread's priority, so it is the main
  thread (I).
  - U: only the first caller is logged, so whether `0360` also feeds slot 1 later is not shown; a prefill from
    Initialize would look the same.
  - `[xp-t]` for `0360`: 398 ms/s before the step (321 P), 220 ms/s in it (8 P, 212 E).
- Slot 2 (event-driven, `0x800c0000`): first GetBuffer by `049c` (base 15); after the scene, a new stream by `063c`
  (base 15). Neither appears in `[xp-t]`'s busy threads.

**What RAGE asks for (M).** 86 `[thr-prio]` lines from pid `035c` (the limit was not reached): 17 TIME_CRITICAL
(base 15: `0360` itself, `03d8`, `0404`–`0418`, `0424`–`0434`, `0498`, `049c`, `0638`, `063c`), 5 at 2, 4 at 1,
37 at 0, 13 at −1, 5 at −2, 5 at −15. None reaches the kernel: `[xp-qos]` shows `0360` at UI 47/47 like every
guest thread. No `AvSetMmThreadCharacteristics` call (no avrt fixme).

## CPU: user and system time (madeira-unix 0242)

`[xp]` in 20 s buckets (M), in cores:

| Window | usr | sys | sys share | P | E | runnable | CPU W |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 21:57:12–21:57:52 (Story load, before the step) | 2.28–2.49 | 0.50–0.59 | 18–19 % | 1.39–1.57 | 1.39–1.51 | 6 | 1.2 |
| 21:57:56–21:58:33 (heavy scene, clamped) | 2.54–2.70 | 0.67–0.70 | 20.5–20.8 % | 0.02–0.11 | 3.10–3.38 | 27 | 0.38–0.42 |
| 21:58:56 → end (black screen) | 0.43–0.51 | 0.19–0.27 | 31–37 % | 0.14–0.23 | 0.41–0.62 | 1.5 | 0.22–0.34 |

- At the step, system time rises by 0.1–0.2 cores and its share by 2 points, while compressed memory goes from 1.08
  to 1.75–1.94 GB (3.8–4.5 GB after). Page-ins stay at 0–18/s.
- I: kernel work (faults, decompression) is not what takes the E cores at the step. The clamp itself (P 1.5 → 0.1,
  1.2 → 0.4 W, runnable 6 → 27) matches rdr2-cpu-cores' CLPC/CPMS reading.

## Recommendations (none implemented)

**KosmicKrisp: the retire-serial path, not 2A.**

- 2A changes nothing RDR2 holds.
- The memory is ONE_TIME recordings' upload BOs, and allocators that never reset. A ONE_TIME recording's BOs and
  its allocator hold are dead once its single submit completes.
- So: a per-queue completion serial (design §2's fallback, §3 step 2) that ends a ONE_TIME recording's holds at
  completion.
  - Its BOs go back to the pool.
  - Its allocator's holder count drops, so 0092's reset rules (owner thread only, taint for ended-unsubmitted,
    seal at 8 MiB, at most 4 unsealed) can reach zero.
- Expected (I): held upload 0.8–1.0 GB → the frames in flight (about 2–3 × 115 recordings × 0.6 MiB ≈
  0.15–0.2 GB), and allocators 0.75 GB → the design's 0.1–0.25 GB.
- Second: finer size classes for 256 KiB–2 MiB requests (or §3's slab ring). That is about 0.3 GB of the live
  tessellation scratch at today's 1.7× rounding (I).

Decisions it needs:

- (a) The locking design. The pool is externally synchronized and the holders' pools may not record again, so the
  release needs a per-command-buffer lock shared by completion, reset, begin and free, or a device-level retired
  list. The design's "pool thread only" rule alone may never run for these pools (U above).
- (b) Class `feature`, first behind `MESA_KK_EXPERIMENTAL`.
- (c) The default scope afterwards: all titles, or RDR2 under a 0152 amendment.
- (d) Whether 2A leaves the plan.
- (e) Whether the finer classes ship with it.

A census field for the holder's pool would answer U before (a).

**Audio: Option A (time-constraint policy plus the RemoteIO workgroup, from inside GetBuffer), gated on the
GetBuffer caller, with C1 hysteresis as a companion. Not B1.**

- The producer is throttled, not stalled, so more CPU share is what it lacks (A's premise).
- B1 (honour TIME_CRITICAL server-wide) would promote 17 RDR2 threads, the main thread among them. That is the
  widest change, with a likely fps cost.
- Before A: log the GetBuffer caller whenever it changes, not only the first. The gate must know whether the steady
  slot-1 producer is `0360` (the main thread) or a dedicated thread.

Decisions it needs: a new decision record on audio-thread scheduling (relates to 0162 and the perf-arms ECO/QoS
work), its scope (every WASAPI title or RDR2 first), the gate (the GetBuffer caller only, or only if it asked
TIME_CRITICAL), and whether C1 changes the driver's underrun semantics for every title. C2 (skipping `play_pos`)
stays rejected.

**CPU:** no new decision from the split; the clamp reading stands.

## Not shown

- The heavy scene's identity (no screenshot in it).
- Why l19 left it for a spinner while l17 and l18 held the cabin (the 0155 refusal is the only logged
  difference).
- Audio by ear.
- Gameplay or performance of any fix.

## Games observed

- Red Dead Redemption 2 (1174180): a dev diagnostics run on `5db127bd…`. Story was pressed and a heavy scene ran
  42 s at 17–20 fps with audio at 44–47 %. Then a black spinner followed to first-frame+600, after 0155 refused a
  Social Club re-sign-in. Peak 7631 MB, no jetsam. A dev experiment, no change to the compatibility status.
- Hollow Knight (367520): first-frame+10 smoke passed (+10.44 s).

## l22–l23: KosmicKrisp cmd_retire gate

**Linear:** [PLA-364](https://linear.app/playportdev/issue/PLA-364), [PLA-476](https://linear.app/playportdev/issue/PLA-476).
M = measured, I = inferred, U = unknown. Times are on the `[xp]` clock (≈ launch clock) unless a wall time is given.

**IPAs.** The gate: `6f1751c75fc731cd0f90ab779a70b2f899520d22dc060545ac85ee0239af4a2f` (dev, mesa 0132
`cmd_retire` and 0133 `cmd_bo_classes`, both opt-in). The baseline without the option:
`6b5be56936ad84eed375304e65f937ecfacf662c135ce50ee3124b26b924841d` (l20–l21, the same runtime without mesa
0132–0133; [probe evidence](2026-10-29-sc-stock-cef-probe.md#l20l21-decision-0169-gate)). l19's census above is the
earlier reference (`5db127bd…`).

**Runs.**

- **HK** on Vulkan, two locked sessions (`agent-notes/pla476/kkb/`):
  - Smoke off `$PLAYPORT_BUILD/ui-runs/20261030T233830-hk-kkb-off`: `ok:true`, first frame +11.49 s.
  - Smoke on `$PLAYPORT_BUILD/ui-runs/20261030T233918-hk-kkb-on`: `ok:true`, first frame +10.78 s; the log has
    `graphics options: MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes` and a `[kk-cmd-retire]` line.
  - Title menu only, no pads: `$PLAYPORT_BUILD/perf/kkr-hk-before` (23:40) and `…/kkr-hk-after` (00:06). The after
    run's per-frame columns (frame time, GPU ms, MiB) are empty in its summary, so only fps (60.0 both) and CPU
    (100 → 104 %) compare.
  - Gameplay pair (new game, then walking; pads at first-frame+25 and +80): `$PLAYPORT_BUILD/perf/kkr-hk-before-play`
    (00:14, off) then `…/kkr-hk-after-play` (00:19, on), 120 s each, thermal nominal in both.
- **RDR2** (`agent-notes/pla476/l22.sh`, lock session `a6d7333fb817`, rc 0, output `l22-lock.out`): `arm22.sh` = l20's
  `arm20.sh` (keys `env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1 env.PLAYPORT_SC_LAYOUT=1`, the game-SC end left
  unset under decision 0169, `STORY_BY=420 UNTIL=600 WAIT=900`) plus the title's Graphics options row
  `MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes`. 180 s idle between the runs. `pp phone status` at the lock:
  80 %, on power, 3.8 GB free.
  - **l22** `$PLAYPORT_BUILD/ui-runs/20261031T002951-rdr2-p476l22` (host log pulled by `pp ui`, `pull/s1-host.log`).
  - **l23** `$PLAYPORT_BUILD/ui-runs/20261031T003826-rdr2-p476l23` (`pp ui` pulled nothing; `pp phone log` put the
    host log in the same run's `pull/s1-host.log`).

### The option applied (M)

- l22 (log line 2537) and l23 (line 2535): `graphics options: DXVK_CONFIG=… MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes
  VKD3D_SHADER_CACHE_PATH=0`. l20 has the same line without the option and no `[kk-cmd-retire]` line.
- Every `[kk-cmd-census]` block in l22 and l23 has its `[kk-cmd-retire]` line: 7 of 7 in each (+4 to +218).

### Census and memory (M)

l22 time series (l23 follows the same course: allocators 107–177 MiB before the step). l20 (no option) beside it. Story was pressed at
+131 (l22), +125 (l23), +124 (l20); the cabin's load step starts when `fpMB` passes 7000: +236 (l22), +229 (l23),
+223 (l20), +238 (l21).

| `[xp]` | l22 held upload | l22 allocators (n / MiB, largest) | l22 `command=` (n/MiB) | l22 retired (cum.) | l22 tainted / destroyed | l20 held upload | l20 allocators | l20 `command=` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| +66 (title) | 0.0 | 26 / 19.1, 2.9 | 6/1 | 3294 (85.9 MiB) | 198 / 188 | 0.0 | 26 / 38.6 | 6/1 |
| +96 | 1.8 | 64 / 77.7, 12.5 | 22/3 | 5820 | 204 / 188 | – | – | – |
| +126 (Story) | 1.8 | 74 / 98.8, 12.5 | 25/3 | 9411 | 390 / 374 | – | – | – |
| +156 | 1.6 | 74 / 100.0 | 25/3 | 12867 | 390 / 374 | – | – | – |
| +186–188 | 1.6 | 74 / 140.1 | 25/3 | 17572 | 390 / 374 | 65.4 | 40 / 143.4, largest 16.4 | 533/67 |
| +216–218 (last census) | 1.8 | 74 / 171.8, 12.5 | 25/3 | 23439 (2069.8 MiB) | 390 / 374 | 65.5 | 40 / 143.4 | 533/67 |
| load step, `[kk-mem]` only | – | **190 / 1223.4** (+235); l23 152 / 865.2 (+228), **252 / 1911.5** (+240) | 287/80; l23 305/83 (+ pooled 198 / 260 MiB) | – | – | 856.8 (+247) | 45 / 766.5 (+237) | 1758/784 (+ pooled 214) |

- **Submitted-once buckets.** `app primary once pool=-+reset submitted-once` n=1022, `upload=0.0 alloc-added=0.0` in
  every census of l22 and l23 (+96 to +218). Baseline at +218: n=1023, 63.9 MiB; at +247 n=1545, 753.1 MiB; l19 1016.6.
  The ONE_TIME recordings' upload BOs are returned at completion, as designed.
- **Held upload** stays 1.6–1.8 MiB to +218 (l20 65.5, l19 900–1018 in the cabin). No census fell inside the load
  step (the census runs every 30 s; the runs died 6 s (l22) and 12 s (l23) into the step), so held upload *in the cabin* is not
  measured. `[kk-mem]` shows the command BOs instead: `command=` 80–83 MiB plus 198–260 MiB pooled, against 772–784
  plus 196–214 in l20–l21 at the same point (−0.6 to −0.7 GB).
- **Allocators.** Before the step: 74 allocators, 172–177 MiB, largest 12.5 MiB (l20 40 / 143 MiB, largest 16.4).
  In the step's first 6–12 s they grow to 190–252 allocators and **1.2–1.9 GB**: l20–l21 had 45 allocators and
  0.69–0.77 GB at the same point, l19 0.75 GB at its end. The design expected 0.1–0.25 GB. Net, command BOs plus
  allocators at the step: l23 2.25 GB against l20 1.77 GB and l21 1.66 GB.
- **I:** the retire path frees the BOs, but each sealed or tainted allocator is replaced by a new one, and a reset
  `MTL4CommandAllocator` keeps its backing memory. In the load burst the pools hold far more allocators (74 → 252),
  each near the 8 MiB seal, so allocator memory replaces the BO memory and adds to it. The largest allocator and the
  per-pool split in the step are U (no census there).
- **`[kk-upload]` rounding** on `kk_upload_vertex_params` / `kk_upload_tess_params` (the 0133 classes' target):
  **not measured**. Neither site ran before +218, and no census came after.
- `large-new` / `large-reuse` (l23 +240): 497 / 6983 in 12 s; not comparable with l20's cumulative counts.

### Faults (M)

- No `commit done error=` other than 0 (40 `commit done` lines each), no `MTLCommandBufferErrorDomain`, no GPU
  restart in either host log or in the captured syslog (l22 to 00:34:17, l23 to 00:42:45 wall). The only `IOGPU`
  strings are `[thread-sample]` stack frames (`IOGPUCommandQueueSubmitCommandBuffers`), as in l21.
- Tainted / destroyed in RDR2: 198 / 188 by the title, 390 / 374 by Story, then unchanged: no steady churn.
- HK on: tainted / destroyed grow to 6841 / 6837 in 120 s (about 57 a second). That equals the reusable-primary
  direct submits (6856) and the off run's `unsubmitted=` releases (6808): one allocator destroyed and replaced per
  frame. The design expected HK's taints near 0.

### Footprint and the graphics ledger (M)

| | l20 (off) | l21 (off) | **l22 (on)** | **l23 (on)** |
| --- | --- | --- | --- | --- |
| first frame / sign-in / Story | +76 / +96 / +124 | +80 / +100 / +128 | +75 / +112 / +131 | +77 / +96 / +125 |
| load step onset (`fpMB` ≥ 7000) | +223 | +238 | +236 | +229 |
| first 15 s of the step: `fpMB` max | 7718 | 7704 | 7783 | 8084 |
| first 15 s: `[footprint]` phys max | 7562 | 7683 | **7980** | **8084** (`fast` 8173) |
| first 15 s: graphics max | 3801 | 3833 | **4295** | **4311** |
| graphics, Story → +241: median / max | 1845 / 3832 | 1739 / 3833 | 1672 / 4295 | 1766 / 4311 |
| whole run: peak of 8192 | 7960 @+793 | 8006 @+651 | 7980 (died +242) | 8084 (died +241) |
| end | cabin to first-frame+600 | cabin to ≈ff+680 | **jetsam** | **app gone** (I: jetsam) |

- **Headroom gained: negative.** In the step's first 15 s the option costs +460–510 MB of graphics ledger and
  +300–520 MB of `[footprint]` phys against l20–l21. l23 passed l20–l21's whole-run peaks (7960 / 8006) 6 s into
  the step.

### Cabin: not reached; both runs ended by memory

- **l22 (M).** Footprint 7620 MB at +237.5 (`[fp-sample]` jump), `[footprint]` 7980 MB. The scene was invalidated at
  00:34:25.8 wall (≈ +242); syslog: `Process S1Probe [13761] killed by jetsam reason per-process-limit`
  (ReportSystemMemory, 00:34:56), `CORPSE: Capture Complete` at 00:34:59. `pp phone status` after: `app_pid` null.
- **l23 (M + I).** `fpMB` 8018 from +236.75, `[footprint]` peak 8084, `fast` 8173; the log stops at +239.7 with CPU
  near idle. The scene was invalidated at 00:42:57.2 wall (≈ +241). The syslog stream broke and restarted from
  00:42:45 and ended at 00:43:06, before iOS's memory report would come (l22's came 30 s after its exit); from
  00:43:08 the phone was not connected, and the crash listing failed. No jetsam line was captured. I: a
  per-process-limit jetsam like l22.
- **The screenshots (described, not published):** both runs show RDR2's black loading screen with the R★ spinner at
  +231/+232 s after launch, and the phone's Home Screen at +249/+250 s. Neither reached the cabin, so there is no
  cabin fps (l20–l21: 17.8 / 16.2).
- **Why `ok:false`, exit 1, "the app exited before the stop condition" with `until_reached: true` (M, code).**
  `tools/ui.py` sets `until_reached` when the until's anchor event matches (`until_hit["seen"]`, line 834); for
  `first-frame+600` that is the first frame, not first frame +600 s. Both runs saw the first frame, then the app
  exited at `after_s` 270.8 / 262.2, before the 600 s delay. This is not PLA-540 (l22: jetsam line and no app pid;
  l23: SpringBoard ended the app's scene, logged in the syslog, 11 s before the phone disconnected).
  Thermal reached serious in both (timeline).

### HK (M)

| Gameplay pair, window 85–120 s | fps | p99.9 ms | 25 ms hitches | GPU ms | CPU % | P % | CPU mW | MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| off (`kkr-hk-before-play`) | 59.1 | 70.9 | 45 | 8.72 | 95 | 66 | 532 | 3158 |
| on (`kkr-hk-after-play`) | 59.2 | 58.4 | 64 | 6.96 | 120 | 86 | 691 | 3048 |

- **Whole runs** (120 s each): fps mean 58.7 both; 25 / 50 / 100 ms hitches 321 / 17 / 3 off, 337 / 13 / 4 on; GPU
  mean 7.84 → 6.62 ms.
- **The extra 25 ms hitches are one burst (M).** On has 31 of its 59 window hitches in the 115–120 s bucket; off has
  15 in 105–110. The other buckets match (16/17, 1/1, 6/5, 3/3). Over 0–120 s the difference is +5 %. I: noise
  (scene events), not a per-frame cost.
- **The CPU rise is real and is not on Metal's completion threads (M).** `threads.txt` at 90 / 105 / 120 s:
  - off 94 / 82 / 88 %; on 113 / 109 / 103 %;
  - guest thread `00fc` (started by `0068`): on 10–11 %, 15–17 Mi/f; off, below the top 8 (≤ 2–3 %);
  - `00ec dxvk-cs`: 8–9 % → 15–16 %;
  - `0068` and `00f0 UnityGfxDeviceWorker` unchanged;
  - the native `m…` threads (where Metal runs completion handlers) stay at 3–6 % in both.
  The menu pair shows the same direction (100 → 104 %).
  I: the cost is on the recording side. The likeliest source is the per-frame allocator taint, destroy and
  replacement above. `retired` grows ~12.6 k per 30 s (45060 by the end, 3107 MiB) and frees nothing HK holds long.
- **Memory:** allocators 44 / 181 MiB off → 32 / 58–80 MiB on; process MiB −110 (M).
- **Repeat: needed** before any HK or all-title default. Run an interleaved pair (off, on, off, on) with the same
  pads, and read `threads.txt` for `00fc` and `00ec`. One sequential pair cannot separate order from effect.

### Verdict

- **The design's estimate is half met (M).** Held upload under 100 MiB: met before the step, and the command BOs at
  the step are 0.28–0.34 GB (from 0.97–1.0). Allocators 0.1–0.25 GB: **not met**. They reach 1.2–1.9 GB in the
  first seconds of the step, more than the BOs freed. The `[kk-upload]` rounding was not measured.
- **RDR2:** `cmd_retire,cmd_bo_classes` makes the cabin's load step **jetsam in both runs**, where l20–l21 without it
  held the cabin to first-frame+600. It is **not safe** as RDR2's per-title default, and not useful even opt-in for
  RDR2 until allocator growth is bounded. No GPU fault was seen, so the two untested Metal behaviours did not show a
  failure in ≈240 s.
- **Keep it opt-in, named only, default off (as built).** No title default changes. A 0152-style amendment is not
  proposed on this evidence; the owner decides.
- **Next (I):** bound the allocators, which needs an owner decision. Options:
  - reuse instead of replacing tainted allocators;
  - destroy, not reset, an allocator over a size, or cap allocators per pool;
  - shorten the census interval during the load step, to measure largest, pooled and rounding there.
  Then repeat l22 on the same protocol.

### The cause in the code, and mesa 0134–0135 (after l23)

M = read in the code, the SDK header or the l22–l23 / HK logs; I = inferred.

- **A Metal reset keeps an allocator's memory (M, SDK).** `MTL4CommandAllocator.h`: `reset` lets new command buffers
  "reuse its existing internal memory heaps", and `allocatedSize` is those heaps' size. In l22 the 74 allocators'
  `allocatedSize` sum only rose (98.8 → 100.0 → 140.1 → 171.8 MiB, +126 to +218) across 15,700 resets.
- **Why the count jumped (M, code; I for the step's exact course).** 0132's `kk_cmd_pool_end_allocator` seals at an
  End when `allocatedSize` passes 8 MiB. A reset sealed allocator was unsealed and taken, but its heaps stayed past
  8 MiB, so it sealed again at its next End: it took one recording at a time, never counted among the pool's four
  unsealed ones, and nothing destroyed it (only tainted ones were). Each allocator that once passed 8 MiB let the
  pool make another. `sealed=` rose 14 → 165 at a constant count of 74 before the step (re-seals). In the step
  (no census) the count went to 190–252, about 6.4–7.6 MiB each (I: the in-flight burst made new ones, which then
  stayed).
- **HK's one taint a frame (M, code and counts).** DXVK (`dxvk_cmdlist.cpp`) begins the next ExecBuffer (ONE_TIME)
  after each submission in `next()` and submits it only if `execCommands`; `DxvkCommandPool::reset` then resets the
  pool. That spare buffer encodes nothing, but KosmicKrisp began its Metal command buffer at `vkBeginCommandBuffer`,
  so its release without a commit tainted the allocator: `unsubmitted=` 6808 (off) and `tainted=` 6841 (on) in
  120 s, with `unsubmitted 0.0 MiB`. The reusable-primary submits (6856) are the WSI's present blit, recorded at
  each acquire (`wsi_common_metal.c`): the same once-a-frame rate, not the same buffers. A replayed reusable primary
  does not taint: its recording was committed at its first submit.
- **mesa 0134 (`cmd_retire` only):** a recording begins its Metal command buffer at its first encoder, so one that
  encodes nothing taints nothing (`unbegun=`); an idle sealed allocator is destroyed, not reset (`released=`); a pool
  keeps at most four idle ones (`trimmed=`) and makes at most eight, sharing a sealed one at the cap (`capped=`), and
  only past it when all eight record (`over-cap=`). An allocator begun in Metal and released uncommitted is still
  destroyed, never reset (IOGPU's form-1 fault).
- **mesa 0135 (dev, `MESA_KK_DEBUG=memory`):** `[kk-mem]` within a second, marked `| growing allocators+N command+M
  MiB`, when 8 allocators or 64 MiB of command BOs came since its last line; the census then every 5 s.
- **Host check (M):** `kk-cmd-retire-test.c` on the mock, whose reset now keeps the size and aborts on an allocator a
  command buffer was begun on and not committed: an RDR2-like load (40 frames × 12 recordings of 3 MiB) keeps one
  pool at ≤ 6 allocators, then 4 (15 MiB idle) after the drain, with 80 sealed ones destroyed. Dev IPA
  `d3be12c9b22161d470e13995919a96ab4f662d6a7f01f90a03fa3d6dabf88b2a` (90 checks); **not run on the phone**.

### Not shown

- Held upload, the largest allocator and `[kk-upload]` rounding inside the load step.
- A jetsam line for l23.
- Whether HK's CPU rise repeats.
- RDR2 gameplay with the option.

### Games observed (l22–l23)

- Red Dead Redemption 2 (1174180), dev `6f1751c7…` with `MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes`:
  - signed in and Story was pressed in both runs;
  - jetsam 6–12 s into the cabin's load step (l22 per-process-limit; l23 inferred), at 7980 / 8084 MB;
  - an opt-in dev experiment: no change to the compatibility status (the best known stays l20–l21 on `6b5be569…`
    without the option).
- Hollow Knight (367520), `6f1751c7…` on Vulkan:
  - the first-frame+10 smoke passed without the option (+11.49 s) and with it (+10.78 s);
  - the gameplay pair ran at 59 fps both ways, with CPU +25 points and 110 MiB less with the option.
