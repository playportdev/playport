# RDR2 performance ports from Madeira: host build, switches and the phone A/B plan (PLA-364)

**Linear:** PLA-364 (RDR2 gameplay CPU). **Source:** the Madeira RDR2 survey's top-10 table, items
6, 7 and 8, and its prerequisite (GPU time per frame).
**IPA:** dev `Playport-26.5-fe87df4e.ipa`, sha256
`fe87df4e0bb263ba7833d684acf083c5ca3bb3b01e477dd2e792d7802de9c0c1` (side worktree build, below).

**Phone gates not run.** Built and checked on the host only, in the side worktree
`.work/worktrees/perfports` (decision 0117). Neither the Hollow Knight gate nor RDR2 has run on this
IPA; nothing here is a measured gain.

## 1. What is ported, and each switch

| Patch | What | Switch | Default |
| --- | --- | --- | --- |
| mesa 0080 | `[kk-gpu]` about once a second: completed command buffers' GPU time (`gpu`, and `busy` with overlaps counted once, with its share of the interval), `cbs`, `frames`/`fps` (submits that present a drawable), `gpu/frame`, `acquire` (blocked in `nextDrawable`), `present-wait` (in `vkWaitForPresentKHR`), `submit` (driver queue-submit CPU time); a `final` line at the queue's end | `MESA_KK_DEBUG=gpu` | on in dev (`WineHostRuntime.swift` now sets `compile,memory,gpu`), off in release |
| fex 0056 | SMC-path plain stores decided without the backpatch lock (Madeira FEX `34466b2`) | `MADEIRA_FEX_SMC_FASTPATH` | on (as Madeira) |
| fex 0057 | guest calls into ARM64EC code leave with `blr`; EnterEC enters an L1 hit with `ret` (`1e77191`) | `MADEIRA_FEX_EC_RET` | on (as Madeira) |
| fex 0058 | the loop top loads the EC code bitmap pointer from the frame (`d2b623f`) | `MADEIRA_FEX_EC_BITMAP_CACHE` | on (as Madeira) |
| fex 0059 | `ExitFunctionECJit`, a lean ExitFunctionEC for JIT exits (`58a152b`) | `MADEIRA_FEX_EC_EXIT_LEAN` | on when AFP is off and the PLA-401 call ring is off (as Madeira, plus the ring); RDR2's compatibility default turns AFP off, so it is on for RDR2 |
| madeira-unix 0200 | the pool warmer's census period as a key, the walk's time in `[phys-map]`, `[xp-names]` for busy native threads (`dfb565c`) | `MADEIRA_WARMER_SWEEP_CYCLES` | 150 (unchanged: Playport already ran the censuses every ~5 min; Madeira's default 30 would be more often) |
| madeira-unix 0201 | the pool warmer and the stale-pointer healer move themselves to utility QoS (`740473a`) | `env.MADEIRA_ECO_NATIVE=1` | off (as Madeira) |
| wine-unix 0200 | a thread calling `vkQueuePresentKHR` registers the `[xp]` presenting role P, as DXMT's present thread does | none (diagnostics) | always |
| madeira-unix 0202 | the CPU power governor: ECO on/off to hold process CPU power at a target while a game presents (`3930d18`) | `env.MADEIRA_POWER_GOV_MW=<mW>` (band `MADEIRA_POWER_GOV_BAND_MJ`, 1000) | off (as Madeira) |

Not ported: FEX `813bc99` (`CALLRET_ELIDE`; fex 0006 relies on the call-ret stack) and `e8cc982`
(Launcher.exe branch history). The simpler "ECO until the game's first present after sign-in" rule
was not built: the governor covers it once it has a present signal, which wine-unix 0200 gives it.

**What differs from Madeira's commits:**
- fex 0057 lands on our call-ret stack: the EC call path never pushed a call-ret entry and EnterEC on
  iOS never popped one, switch on or off, so the stack is untouched.
- fex 0059's frame offsets are 3856/3864/3872 (Madeira 4080–4096: its frame has the guest branch
  history we did not take); `static_assert`s check them and the object's disassembly shows
  `ldr x17, [x28, #0xf10]`, `ldr w17, [x28, #0x5e8]`. It also honours `IosXpFexOn` (fex 0011) at
  each 64th call and is not installed while `FEX_EC_CALL_RING` is armed. The log line gains `ring=`.
- madeira-unix 0202 learns that a game presents from a role-P thread running in an `[xp]` sample,
  not from Madeira's `[bg-qos]` game note (`4e20535`, not ported). Before wine-unix 0200 only DXMT
  set role P, so a Vulkan game never activated it. The governor runs inside the `[xp]` sampler: a
  release build (`MADEIRA_NO_DIAGNOSTICS`) never governs.
- **ECO risk:** Madeira's records note that ECO crashed GTA V while loading (bcd 449). The governor
  switches ECO only while a game presents. A loading screen that presents counts as presenting.

## 2. Host checks

- `build/stages/mesa.sh $PLAYPORT_BUILD/run/mesa host hosttest`: passed. New `check_gpu_log` runs
  three buffer copies in a child with `MESA_KK_DEBUG=gpu`. The mock now gives each command buffer
  2 ms of GPU time. The child's final line was `[kk-gpu] 0.00 s final: frames=0 fps=0.0 gpu=6.0 ms
  busy=6.0 ms (12113%) cbs=3 ...`. The percentage is meaningless over a 0.00 s interval. The mock has
  no WSI, so `frames`, `acquire` and `present-wait` stay 0 on the host.
- `./pp build` (dev): every stage passed, `verify-ipa` passed 89 checks. The FEX `static_assert`s on
  the frame offsets compiled.
- `./pp test` (full; Swift changed): all passed, Swift's 356 tests included.
- **Build records.** Only four rows change: `xtajit64.dll`, `xtajit.dll`, `libntdll_unix.a` and
  `libwin32u_unix.a`. They are path-independent. With the new series entries taken out, the copy
  rebuilt all four to main's committed rows. It then rebuilt them to these values with the entries
  back. The copy's `libdxmt_combined.a` and `libidevice_ffi.a` rows keep main's values (0117).
- Not host-tested: the FEX emitter and stub changes run nowhere but the phone. Madeira's own host
  checks (unicorn and an AArch64 interpreter) are not in this repository.

## 3. Phone A/B plan (for the main checkout)

**Gate first.** Run Hollow Knight first frame+10 on this IPA, with FEX 0056–0059 on by default.
The FEX patches change every x64→EC transition and Hollow Knight runs AFP on, so `EC_EXIT_LEAN` is
off for it. If the gate fails, rerun it with `env.MADEIRA_FEX_EC_RET=0` and then
`env.MADEIRA_FEX_EC_BITMAP_CACHE=0` to find the patch.

**Every RDR2 arm.** Use the same save and spot and the same Resolution Scale, and the compatibility
defaults (AFP off). Play past the thermal clamp: compare only once `thermal:` has reached `serious`
and stayed there, at a matched spot, for at least 60 s. Do not compare GPU ms while vsync-capped at
60. For each arm, grep the run's log and take the medians over that window:
- `[kk-gpu]`: `fps`, `busy` %, `gpu/frame`, `acquire`, `present-wait`. Busy near 100 % with
  `acquire` high means GPU-bound. Low busy with fps under the cap means the CPU side limits.
- `[xp] `: `cpu=`, `P=`/`E=` ms, `GHz P=/E=`, `mJ=` per sample, and the `P` role thread (now the
  Vulkan presenting thread); `[xp-api]` for x64→EC calls a second.
- the FEX lines once per process: `FEX: ec-ret-v1`, `ec-bitmap-cache-v1`, `ec-exit-lean-v1 ...
  afp=0`, `smc-store-fastpath-v1`.
- `thermal:`; for the governor arm also `[power-gov]` and `[eco]`; for ECO-native `[eco-native]`.

**Order** (one change per arm, against arm A):
1. **A, baseline:** this IPA, defaults. It also settles CPU- against GPU-bound (`[kk-gpu]`).
2. **B, FEX transitions off:** `env.MADEIRA_FEX_EC_RET=0 env.MADEIRA_FEX_EC_BITMAP_CACHE=0
   env.MADEIRA_FEX_EC_EXIT_LEAN=0`. Compare `[xp-api]` x64→EC per second and the game thread's
   `Minst`/IPC and fps. Split them one at a time only if B differs from A.
3. **C, helper QoS:** `env.MADEIRA_ECO_NATIVE=1`. Look for `[eco-native] pool-warmer` and
   `wine-stale-heal`, then compare the warmer's P-core share in `[xp-t]` (now named by
   `[xp-names]`) and fps.
4. **D, warmer censuses:** `env.MADEIRA_WARMER_SWEEP_CYCLES=100000`, which leaves only the two
   early censuses. Read A's `[phys-map] ... (walk N ms` first: if the walks are short, skip D.
5. **E, governor:** `env.MADEIRA_POWER_GOV_MW=2300` (about the clamp's knee). This arm is about
   time to clamp, not sustained fps. Compare the time from the first present to `thermal: serious`
   and the fps over the first 2–3 minutes of play. Read `[power-gov]` for the ECO share. Watch the
   loading screens for a crash (GTA V's ECO crash).

A Graphics-options `MESA_KK_DEBUG=` replaces the dev set: if one is used, name `gpu` in it.

## 4. Where it was built

- Side worktree `.work/worktrees/perfports`, branch `perfports`, from main `03c4efa`. The copy made
  reflinks of main's `cache`, `inputs` and `run` and of `cef-src/notices` and `cef-src/out-stage-c`,
  then rewrote the paths (0117: 3,077 text files, 2 symlinks, 86 RUNPATHs). It deleted
  `run/mesa/{ios,ios-gl}` and every meson build directory first.
- **Main's `.work` was not written by the copy.** A marker was touched before the copy. Afterwards
  `find <main>/.work -path '*/worktrees' -prune -o -newer <marker> -print` listed 27,200 entries,
  all the main session's own: its build at 17:12–17:18 under `run`, `out`, `phone`, `ui-runs`,
  `install-runs` and agent notes. No listed text file names the copy's path.
