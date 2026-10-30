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
