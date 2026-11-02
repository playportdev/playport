# RDR2: KosmicKrisp command memory, audio underruns and the CPU split (l19 diagnostics)

**Linear:** [PLA-364](https://linear.app/playportdev/issue/PLA-364) (RDR2),
[PLA-476](https://linear.app/playportdev/issue/PLA-476) (plan `PLA-476`).

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

## Audio gate (decision 0172)

**Linear:** [PLA-364](https://linear.app/playportdev/issue/PLA-364). Chunk C's phone gate: the audio producer in real
time ([decision 0172](../decisions/0172-audio-producer-runs-real-time-in-its-own-work-interval.md)).
IPA `Playport-26.5-58432f76.ipa`, sha256
`58432f76fa07cb2308cff7745e2c0d529cbbe133f874fc7a8eff3c309d2a0441` (dev). Installed with
`pp install --ipa …` at 00:53:27 (upgrade in place). `pp phone status` before and after each session showed that sha.
Every `pp ui`/`pp perf` call passed `--expect-ipa`. Phone iPhone18,4, iOS 27.2, on the charger, 80 % for the whole night.
M = measured, I = inferred.

Off arm = Runtime keys `env.MADEIRA_AUDIO_RT=0 env.MADEIRA_AUDIO_REFILL=0`; on arm = the IPA's defaults.

### Runs

| Session | Run | Dir |
| --- | --- | --- |
| 1 | HK smoke (on) | `$PLAYPORT_BUILD/ui-runs/20261031T005331-hk-aud-smoke` |
| 1 | HK perf off1, on1, on2, off2 | `$PLAYPORT_BUILD/perf/hk-aud-{off1,on1,on2,off2}` |
| 2 | RDR2 p476aud-off (arm20) | `$PLAYPORT_BUILD/ui-runs/20261031T020806-rdr2-p476aud-off`, notes `.work/agent-notes/pla476/p476aud-off` |
| 2 | RDR2 p476aud-on (arm20) | `$PLAYPORT_BUILD/ui-runs/20261031T022731-rdr2-p476aud-on` (log pulled by hand into `pull-manual/`), notes `.work/agent-notes/pla476/p476aud-on` |
| 3 | W3 perf off, on | `$PLAYPORT_BUILD/perf/w3-aud-{off,on}`: **not run**, see below |

Analysis scripts and outputs: `.work/agent-notes/pla476/chunkC/` (`an.py`, `an-off.txt`, `an-on.txt`, `xp.py`, `heavy.py`).

### Hollow Knight (367520)

- Smoke (on arm): `ok:true`, first frame at +11.28 s, until first-frame+10 (M). This only shows the first frame was seen.
- `pp perf --compare … --window 60:150` (M):

| run | fps | p50 | p99 | p99.9 | h25 | h50 | h100 | gpu ms | cpu % | P% | E% | sys mW | MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| off1 | 59.6 | 16.67 | 25.01 | 45.85 | 94 | 5 | 2 | 8.06 | 104.7 | 70.0 | 34.8 | 2853 | 3162 |
| on1 | 59.6 | 16.67 | 25.01 | 41.68 | 272 | 5 | 2 | 7.74 | 101.2 | 62.4 | 38.9 | 2722 | 3157 |
| on2 | 59.6 | 16.67 | 25.01 | 41.68 | 134 | 4 | 1 | 7.81 | 104.8 | 70.6 | 34.3 | 2724 | 3168 |
| off2 | 59.7 | 16.67 | 25.01 | 29.18 | 188 | 3 | 1 | 7.92 | 104.4 | 68.9 | 35.4 | 2535 | 3163 |

  Whole-run fps_mean 59.0 / 59.0 / 58.3 / 59.0. All four started nominal, with no pressure level logged (M).
- **The pads reached gameplay** (no `--shot` in these runs).
  - M: every run logs `vpad: script 1 loaded: 64 steps` and `script 2 loaded: 86 steps`, then `done` for both:
    150 steps.
  - M: each run has the same signature as the gameplay baseline `kkr-hk-before-play`, 10 s later because the pads
    are at +35/+90 instead of +25/+80:
    - a load hitch after hk-new-game (on1 500 ms at t=45; baseline 525 ms at t=35) with a JIT burst of about
      5300–6100/s;
    - GPU rising to 9.1–9.9 ms/frame;
    - after hk-walk, the same 425.15 ms room-transition hitch (on1 t=105; baseline t=95).
  - I: gameplay, not a menu.
  - The window GPU% (56–59 % against the baseline's 62.8 %) is not a like-for-like comparison: the baseline ran
    `graphics:vulkan` on another IPA with different pad times, and the 60–150 window covers a different stretch of
    the walk.
- **Verdict:** no measurable fps or tail change. The h25 counts (94–272) are spread within each arm and overlap
  between arms. h50/h100 are the same (I).
- **Audio (M):**
  - The off arms log both off lines; there are no `rt` lines.
  - The on arms log `getbuf-producer … win_tid=00f8 … switches=1`, then `rt promote stream=… win_tid=00f8 kr=0` and
    `rt join win_tid=00f8 own interval`. The prefill caller is `getbuf-thread win_tid=0068` with 4800 frames.
  - About 85 `rt producer win_tid=00f8 cpu=0% interval=1 cycles=… cycle_errors=0` lines appear per run, about 51 cycles/s.
  - No `rt refused`, `rt reassert`, join refusal, `AudioWorkIntervalCreate failed` or `cycle_errors>0`.
  - No `rt demote`: `pp perf` ends the app, so there is no teardown in the log.
  - **FMOD's thread `00f8` is promoted** (M).
  - Slot 0 delivered 99–100 % with 0 short callbacks on every arm, on or off (M).

### Red Dead Redemption 2 (1174180): the heavy scene

Arm20, keys `env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1 env.PLAYPORT_SC_LAYOUT=1` (plus the off keys), with no
graphicsOptions, `STORY_BY=420 UNTIL=600 WAIT=900`, and 3 minutes idle between the arms.

| | off | on |
| --- | --- | --- |
| thermal at launch (M) | nominal → fair +98 s → serious at the Story load | **serious at launch** |
| first frame / Story press (M) | 02:09:58 / 02:15:11 | 02:30:39 / 02:31:19 |
| heavy scene (M: fps drop, footprint ≥ 7.4 GB) | 02:17:06 → end 02:23 (ff+600) | 02:33:28 → 02:39:06 (last log line) |
| clamp in the scene (M, `[xp]`) | P 0.03, E 3.11 cores, E 1.14 GHz, 0.34 W | P 0.02, E 3.22 cores, E 1.12 GHz, 0.33 W |
| scene fps, mean of `[frames]` (M) | 15.98 over 346 s | 15.33 over 325 s (**−4.1 %**) |
| 16-frame block mean ft: median / p95 / max (M) | 60.1 / 79.3 / 290 ms | 63.1 / 83.9 / 165 ms |
| slot-1 delivery in the scene, mean of the 10 s windows (M) | **41.4 %** (35–61 %), 15 794 short callbacks | **96.9 %** (66–100 %), 490 short callbacks |
| slot-1 longest ReleaseBuffer gap in the scene (M) | 47–101 ms (253 once) | 17–77 ms in the clean windows, **393–1547 ms** in the 9 dipped ones |
| peak `[footprint]` (M) | 7787 MB | 7863 MB |
| memory warning (syslog) / jetsam (M) | 1 / none | 1 (02:33:35) / none |
| cabin held (M off from shots; I on) | yes: shots +635 to +880 show Arthur at the cabin | yes, by the log: 15–16.6 fps and 7.5–7.9 GB to 02:39:06, `app_pid` alive at 02:36:26 and 02:38; I ended it at 02:40 with `pp phone kill`. No screenshot after +276 (the loading screen) |

**Slot 1 over time (M, 10 s windows).**
- **Off:**
  - Before the scene (menus and the Story load, 02:10–02:14:25): 82–99 %, with 13–181 short callbacks per window.
  - From the Story load to 02:16:55: 87–100 %.
  - In the scene (02:17:15 → 02:22:55): 35–61 %, nearly every callback short (437–470 / 469).
- **On:**
  - Before the scene: 99–100 %, with 0 short callbacks except 4 at 02:32:57.
  - In the scene, 02:33:37 → 02:35:07: 100 %, 0 short callbacks.
  - Then 9 of 22 windows dip: 93, 96, 89, 94, **66**, 84, 95, 91, 95, 97, 98 %. Each dip has a ReleaseBuffer gap of
    0.3–1.5 s; the others are at 100 %.

**The `[ios_audio]` lines, on arm (M):**
- Slot 0: the launcher's stream (`Rockstar Games Launcher`, `getbuf-thread win_tid=00a4`). It had no
  producer line, so it was never promoted.
- Slot 1:
  - The main thread `0360` is only the 4800-frame prefill (`getbuf-thread`).
  - **The steady producer is `0428`** (`getbuf-producer … win_tid=0428 … priority=15 base=15 frames=256 switches=1`).
  - Then `rt promote … win_tid=0428 kr=0` and `rt join win_tid=0428 own interval`.
  - The off arm names the same producer `0428`.
  - In the scene, 0428's guard reads cpu=20–32 %, 3–14 % before it. No reading is near 80 %.
- Slot 2 (event-driven):
  - `getbuf-producer win_tid=049c switches=0`, then `rt promote … kr=0` and `rt join`.
  - 15 lines `rt producer win_tid=049c cpu=0%`. Then the stream's windows and rt lines end (02:31:16, as in the off arm's
    slot 2 at 02:15:09).
  - **No `rt demote` line for 049c.** U: was the stream stopped or released without a logged demotion, or did it just stop
    being polled? The log does not say.
- **None** of `rt refused`, `rt reassert`, join refusal, `AudioWorkIntervalCreate failed`, `kr≠0` or
  `cycle_errors>0`. 266 `rt producer` lines; `cycle_errors` 0 throughout.
- **Refill (C1):** no per-episode line exists in the log. The episodes are visible only as `short_callbacks`/`underrun_frames`
  (which now count frames not played). No separate C1 count was measured.

**The dips (I).**
- They are not the throttling that 0172 targets. The off arm's starvation is every callback short with gaps of 50–100 ms.
  The on arm's dips are a few windows with one long gap.
- They coincide with whole-process stalls:
  - Our own 250 ms `[xp]` sampler ran with dt of 1.3–19 s (02:33:44 → 02:36:10, 13.4 s at 02:36:10);
  - a memory warning (02:33:35), ~7.7–7.8 GB footprint with 2.1 GB compressed, and `limit_remaining` 389 MB;
  - the phone's syslog and lockdown connection dropping (02:33:35, 02:35:05–02:35:45, `GetProhibited`).
- The off arm's sampler also stretched (median dt 1.6 s in the scene), so this memory/clamp state is shared. The on
  arm's long gaps may be memory stalls hitting a producer that no longer starves the rest of the time. Not separated here.

**`pp ui` result of the on arm (M):** `ok:false`, "the app exited before the stop condition" at 02:35:30.
- The app was **not** gone: `pp phone status` gave `app_pid 14976` at 02:36:26 and 02:38.
- No app events reached the workstation after 02:32:26, and the syslog stream failed repeatedly from 02:35:05.
- The pull got nothing (`pull/` empty). The log was pulled by hand with `pp phone log` at 02:39.
- I: a lost device connection, read as an exit. This is a tooling issue, separate from the audio change.

**Verdicts (RDR2):**
- Slot 1 ≥ 95 % in the clamp: **pass on the mean** (96.9 % against 41.4 % off). **9 of 22 windows below 95 %**
  (min 66 %), all with 0.3–1.5 s stalls. A strict per-window reading fails.
- Steady slot-1 producer named: **`0428`**, not `0360`.
- No `rt refused`: pass. cycle_errors 0: pass.
- fps no worse than ~10 %: **pass**, −4.1 %. The on arm started at thermal serious, the off arm at nominal.
- No new jetsam: pass (peak 7863 against 7787 MB, below l22/l23's 7980/8084).
- Cabin held: off M, on I (no screenshot in the scene).
- One run per arm and an unequal thermal start: the fps comparison is weak.

### The Witcher 3 (292030): not run

Both `pp perf` arms ended at once with `action=settings:app-292030 refused: app-292030 is not a catalogued title` (M).
The title is not in the app's library on the phone, so nothing launched; there is no frame-interval data. The
off arm first waited the full `--cool-max 20` (pressure still 20 after 28 min of rest, after RDR2). `hud:off` was applied
after.

### Not checked

No listening test (the owner's cabin listen), so whether the sound is right is not known. W3 is not covered. RDR2 has one run per arm.

### Games observed (audio gate)

- Hollow Knight (367520), dev `58432f76…` on its defaults: the first-frame+10 smoke passed (+11.28 s); four
  gameplay `pp perf` runs at 59.6–59.7 fps with the producer off and on.
- Red Dead Redemption 2 (1174180), dev `58432f76…` on `arm20.sh`: the cabin's heavy scene ran in both arms (off to
  first-frame+600 by shots; on to 02:39 by the log), slot-1 audio 41.4 % off against 96.9 % on, no jetsam. A dev
  experiment: no change to the compatibility status.
- The Witcher 3 (292030): not launched (not in the phone's library).

## l24: KosmicKrisp cmd_retire with the allocator bound

**Linear:** [PLA-364](https://linear.app/playportdev/issue/PLA-364), [PLA-476](https://linear.app/playportdev/issue/PLA-476).
M = measured, I = inferred, U = unknown. RDR2 times are on the `[xp]` clock (≈ launch clock) unless a wall time is given.

**IPA.** `d3be12c9b22161d470e13995919a96ab4f662d6a7f01f90a03fa3d6dabf88b2a` (dev; mesa 0134–0135 on top of
0132–0133, all only with `cmd_retire`). Installed with `pp install --no-build --ipa …` at 03:18:33 (upgrade in place,
container kept); `pp phone status` showed that sha at each session's start and end, and every `pp ui`/`pp perf` call
passed `--expect-ipa`. 80 %, on power. This IPA also carries decision 0172's audio producer (on by default), which
l20–l21 (`6b5be569…`) did not: the audio gate above measured no memory saving from it (peak 7863 on against 7787 MB
off), so it is not counted as a cause below (I).

**Runs.** Scripts and analysis in `.work/agent-notes/pla476/` (`l24-s1.sh`, `l24-s1b.sh`, `l24.sh` = `l22.sh` with
the new IPA, `arm22.sh` unchanged; `l24-analysis/an24.py`, outputs `an-l20.txt`, `an-l21.txt`, `an-l24.txt`,
`an-l25.txt`).

| Session | Run | Dir |
| --- | --- | --- |
| 1 | HK smoke, Vulkan with the option | `$PLAYPORT_BUILD/ui-runs/20261031T031837-hk-kkb2-on` |
| 1 | HK perf off1, on1, off2, on2 (03:20–03:51) | `$PLAYPORT_BUILD/perf/kkb2-hk-{off1,on1,off2,on2}` |
| 1b | HK perf off2-r (off2 logged `Metal HUD off`: no per-frame columns) | `$PLAYPORT_BUILD/perf/kkb2-hk-off2-r` |
| 2 | RDR2 l24 (after 600 s idle) | `$PLAYPORT_BUILD/ui-runs/20261031T041043-rdr2-p476l24` |
| 2 | RDR2 l25 (repeat, after 180 s idle) | `$PLAYPORT_BUILD/ui-runs/20261031T042918-rdr2-p476l25` |

RDR2 protocol: `arm22.sh` = l20's `arm20.sh` (keys `env.PLAYPORT_CEF_SWAP=0 env.PLAYPORT_SC_SINGLE=1
env.PLAYPORT_SC_LAYOUT=1`, `STORY_BY=420 UNTIL=600 WAIT=900`) plus the Graphics options row
`MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes`. Both host logs were pulled by `pp ui` (`pull/s1-host.log`).

### Hollow Knight (367520), Vulkan (M)

- Smoke with the option: `ok:true`, first frame +10.91 s (this shows the first frame only).
- `pp perf --compare … --window 85:120` (each run 120 s, `--cool 5`, pads at first-frame+25 `hk-new-game` and +80
  `hk-walk`; all four started thermal nominal; every run logs both vpad scripts loaded):

| run | fps | p99.9 ms | h25 | h50 | h100 | GPU ms | CPU % | P % | E % | CPU mW | MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| off1 | 59.2 | 54.19 | 91 | 3 | 1 | 7.24 | 104.3 | 75.0 | 29.0 | 635 | 3155 |
| on1 | 59.1 | 50.02 | 100 | 3 | 1 | 6.77 | 105.1 | 71.9 | 33.3 | 608 | 3152 |
| on2 | 59.2 | 41.68 | 65 | 2 | 1 | 7.27 | 107.1 | 75.9 | 31.3 | 615 | 3171 |
| off2-r | 59.1 | 50.02 | 60 | 3 | 1 | 8.91 | 110.6 | 78.3 | 32.3 | 618 | 3160 |

  Order: off1, on1, (off2: HUD off, fps 59.0 only), on2, off2-r. Whole-run fps 58.7 in all five; fps per 30 s
  identical within 0.3.
- **Threads** (`threads.txt` at 90 / 105 / 120 s): total 91–98 % (off1), 92–97 (on1), 91–99 (on2), 97–104 (off2-r).
  Guest `00fc` 9–12 %, 14–21 Mi/f and `00ec dxvk-cs` 8–9 %, 4.7–6.7 Mi/f in **all four** arms. l22's on run had
  `dxvk-cs` at 15–16 % and CPU 103–113 %; that rise is gone (M). `00fc` was below the top 8 in l22's off run and is
  10–12 % in both arms here (M); why it differs from l22's off run is U.
- **Retire counters, on1 / on2 (M):** `tainted=0 destroyed=0` to the end (l22: 6841 / 6837, one a frame);
  `released=0`, `trimmed=19` / `20`, `capped=0`, `over-cap=0`, `pool-max=5`, `sealed=0`. `unbegun` grows 5403 /
  5400 per 30 s census, about **3 per frame** at 59 fps (the recipe expected about 1). Allocators 41 / 166–167 MiB
  (off 43 / 181 MiB), largest 4.5 MiB. No `commit done error=` other than 0 (40 lines each).
- **Verdict (HK):** no fps, tail or CPU difference across the two interleaved pairs; taints are 0. The l22 CPU cost
  (+25 points) does not repeat (I: it was the per-frame taint path that 0134 removed).

### RDR2 (1174180): census and memory (M)

| | l20 (off, `6b5be569…`) | l21 (off) | **l24 (on)** | **l25 (on)** |
| --- | --- | --- | --- | --- |
| thermal | nominal → serious | nominal → serious | nominal → fair +111 → serious +405 | **serious at launch** |
| first frame / Story press | +76 / +124 | +80 / +128 | +75 / +139 | +99 / +153 |
| load step onset: `fpMB` ≥ 7000 (first `growing` line in the step) | +223 | +238 | +244 (+238) | +277 (+272) |
| allocators before the step (n / MiB, largest) | 40 / 143 | – | 72 / 189, 4.9 | 72 / 170, 4.9 |
| allocators in the cabin (n; MiB median / max, `[kk-mem]` from +330) | 45; 868 / 870 | 45; 803 / 818 | **112; 933 / 1038** | **111–112; 888 / 1014** |
| `command=` / pooled MiB in the cabin (median) | 867 / 145 | 888 / 142 | **81 / 257** | **82 / 256** |
| allocators + command + pooled (median / max) | 1877 / 2034 | 1819 / 1991 | **1270 / 1373** | **1229 / 1352** |
| held upload, last census | 848 MiB (largest 142.8) | – | **69 MiB** (largest 24.1) | **74 MiB** (24.1) |
| `[kk-upload]` total, end: asked → rounded MiB (live) | 467 097 → 788 460 (×1.69; live 733) | – | 396 248 → 487 491 (**×1.23**; live 55) | 338 771 → 417 572 (**×1.23**; live 60) |
| `kk_upload_tess_params` asked → rounded | 230 650 → 395 360 (×1.71) | – | 195 665 → 250 583 (**×1.28**) | 167 284 → 215 683 (×1.29) |
| `[footprint]` phys peak | 7930 @+701 | 7996 @+476 | **7175** @+695 | **7250** @+800 |
| `fpMB` peak (of 8192) | 7960 @+793 | 7976 @+464 (8006 by the l22 table) | **7163** @+454 | **7290** @+744 |
| graphics in the cabin, min / median / max | 3823 / 3947 / 4130 | 3704 / 3906 / 4116 | 3232 / 3334 / 3456 | 3215 / 3315 / 3409 |
| compressed in the cabin, median | 4338 | 4262 | 2472 | 2359 |
| fps, Story+150 → +350 (`[frames]`) | 17.4 | 13.7 | 16.2 | 13.8 |
| fps, Story+150 → end | 17.8 | 13.9 (log to +494) | 15.8 | 14.3 |

- **The early lines (M).** `growing` `[kk-mem]` lines came at +25.5 (allocators +12), at the first frame (+25), and
  in the step at +238.1 (`allocators+23 command+12 MiB`, 95 / 320 MiB) and +238.8 (`allocators+17 command+273 MiB`,
  112 / 857 MiB); l25 the same at +271.9 / +272.8 (95 / 299, then 112 / 789 MiB). An off-cycle census came with the
  first one (`s=11.3` / `s=12.3`: 95 allocators, largest 11.2 MiB, 4 over 8 MiB, held upload 14 MiB). **The census
  did not then run every 5 s (M):** the next came at the usual 30 s (`s=31.1`), and `[kk-mem]` lines every ~10 s.
  The count reached 112 within 0.7 s of the step and stayed there to the end (111–112).
- **The bound held (M).** `pool-max=8` from the first in-step census, `over-cap=0` throughout, `tainted=0
  destroyed=0`. In the cabin, l24 to +778: `released=22870` (idle sealed ones destroyed), `capped=461581` (a
  recording shared a pool's allocator at the cap), `sealed=22910`, `trimmed=633` (all before the step), `reset=35150`.
  About 42 allocators destroyed and remade a second at a constant 112 (I: 14 pools × 8). `largest` 22–26 MiB,
  38–40 over 8 MiB.
- **What the saving is (M + I).** The allocator count is bounded (112 against l22–l23's 190–252 and 1.2–1.9 GB), but
  allocator memory in the cabin is **0.89–0.93 GB median, 1.0 GB max**: at or above l20–l21's 0.80–0.87 GB, and far
  from the design's 0.1–0.25 GB. The gain is in the command BOs: `command=` 81 MiB against 867–888, held upload
  69–74 MiB against 848, and `[kk-upload]` rounding ×1.23 against ×1.69 (0133's classes). Net command memory is
  about **0.6 GB lower** (1.23–1.27 against 1.82–1.88 GB median).
- `unbegun` grows with `unsubmitted=` in RDR2 too (611 651 at +778 in l24): recordings that encode nothing no longer
  reach Metal.

### Footprint and headroom (M)

- Peak 7175 / 7250 MB (`[footprint]`), 7163 / 7290 MB (`fpMB`) of 8192, against l20–l21's 7960 / 8006: **headroom
  gained about 0.7–0.8 GB** (about 1.0 GB left, from 0.19–0.23). Graphics in the cabin is about 0.6 GB lower
  (median 3315–3334 against 3906–3947) and compressed about 1.9 GB lower.
- One memory warning each (syslog `Received memory warning`, l24 04:15:11 and l25 04:35:41, both at the step); no
  `per-process-limit` or other jetsam line in either syslog, no `JetsamEvent` report pulled.

### Cabin, fps and faults

- **Cabin held to first-frame+600 in both (M).** `pp ui` `ok:true`, `why: until first-frame+600`, exit 0; the app
  was alive to the end (no early-exit fallback ran). Screenshots (described, not published): l24 from +256 to +792
  and l25 from +365 to +838 show Arthur standing on the snowy cabin porch by the window; l25's +274 is the black loading screen with the spinner.
- **fps (M; comparison I).** Story+150 → +350: 16.2 (l24) and 13.8 (l25, serious at launch) against 17.4 (l20) and
  13.7 (l21). The spread between runs of one arm is larger than the difference between arms: no fps change is
  shown either way.
- **GPU faults (M).** No `commit done error=` other than 0 (40 `commit done` lines each), no
  `MTLCommandBufferErrorDomain`, no GPU restart, in the host logs or syslogs. The syslogs do carry kernel
  `IOGPUFamily <FAULT>: IOGPUCommandDescriptor::prepare … preparedBytes != requiredBytes` lines: 11 543 (l24) and
  10 448 (l25). They are not new: l20 has 60 853, l21 10 357, l17 60 256, the audio gate 15 344–41 495, and l22–l23
  17 / 93 (the l22–l23 section above missed these in its syslog check). I: a kernel wiring-accounting notice that
  every RDR2 run shows, not a fault of this change. This was read after the session; l25 ran on the automatic check
  (commit errors, `MTLCommandBufferErrorDomain`, GPU restart).

### Verdict

- **The option now cuts RDR2's peak (M):** two runs held the cabin to first-frame+600 with peaks 0.7–0.8 GB below
  l20–l21, where l22–l23 (without the bound) died 6–12 s into the step. No GPU fault beyond the baseline's kernel
  notices; HK unchanged with taints at 0.
- **The allocator bound is half the story (M):** the count is capped at 112 and stays there, but allocator memory
  is still about 0.9 GB (design 0.1–0.25 GB); the saving comes from the retired command BOs and the upload rounding.
  The 5 s census did not run. About 42 allocators a second are destroyed and remade in the cabin, with no measured
  fps cost.
- **Recommendation (the owner decides):** `MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes` is a candidate for RDR2's
  per-title default: it is the first change since l12 that gives RDR2 back headroom, and two runs is the same evidence
  l20–l21 gave decision 0169. Making it the default needs a new decision or an amendment (as 0152 did for a
  per-title row). Before that, worth weighing: one run started at thermal serious; no listening or gameplay past the
  cabin; and the remaining 0.9 GB of allocators is a further target (smaller seal or cap, or destroy instead of reset
  above a size), which needs its own owner decision.

### Not shown

- Gameplay past the cabin, or a run past first-frame+600, with the option.
- Allocator memory per pool, and why 14 pools reach their cap (the census lists totals only).
- Whether HK's `00fc` difference from l22's off run is real.
- Any title other than HK and RDR2 with the option.

### Games observed (l24–l25)

- Red Dead Redemption 2 (1174180), dev `d3be12c9…` with `MESA_KK_EXPERIMENTAL=cmd_retire,cmd_bo_classes` on
  `arm20.sh`'s keys: signed in, Story pressed, the cabin held to first-frame+600 in both runs at 14–16 fps, peak
  7175 / 7250 MB, no jetsam. A dev experiment with an opt-in option: no change to the compatibility status unless the
  owner makes it RDR2's default.
- Hollow Knight (367520), dev `d3be12c9…` on Vulkan: first-frame+10 smoke passed with the option (+10.91 s); five
  gameplay `pp perf` runs at 59 fps, no difference with the option.
