# Hollow Knight's main thread: Mono's patched calls kept going through the trampoline

**Date:** 2026-09-26. **Tree:** the commit that adds this record and
`patches/madeira-unix/0027`. **Build:** dev IPA
`5ed671643f57961a00c0eed3fe7753c6b17e64063b60e9d812f0db20f0c0d00e` (wine-11.18
pins plus 0027), installed in place. It is compared with `966167bd…` from the
[native baseline](2026-09-26-hk-native-baseline-wine-11.18.md), which is the same
tree without 0027. **Phone:** iPhone Air (`iPhone18,4`), iOS 27.0, charging. The
phone was not cool at launch: thermal pressure reached 10 at t=50 s.

**Result:** in King's Pass at native 2736x1260 the Unity main thread
(`0024`) drops from 175 to 22 Mi/f, and gameplay goes from 25 to 30 FPS to
62 to 71 FPS. On the main menu the thread drops from 35 to 41 Mi/f to 5.7 Mi/f
and from 99 % to 32 % busy. The earlier 720-row record measured 20 to 25 Mi/f
in the same room, so this change explains the whole sevenfold gap noted in the
baseline. Gameplay is now limited by the GPU (13 ms a frame, 94 % busy) and by
the E cores, because the scheduler moves the game off the P cores once the GPU
is busy. That is the next thing to fix.

## 1. Cause

- The baseline's `[thread-sample]` call chains for `0024` in play repeat
  `mono+0x37f72a → 0x37ee04 → 0x28458b → 0x37f49e → 0x14e1c2`. Strings in
  the pulled `mono-2.0-bdwgc.dll` name these functions: `mono_magic_trampoline`
  (0x37f690, which asserts `mono_thread_is_gc_unsafe_mode ()`),
  `common_call_trampoline` (0x37e3d0, `vtable_slot` and `generic_virtual` in
  `mini-trampolines.c`), the compiled-method lookup in `mini-runtime.c`
  (0x284360), and `jit-info.c`'s table search (0x14e0f0 and 0x14dee0). The
  FEX host code with the most samples (`0x14826da00`) is that binary search,
  with its hazard-pointer store and fence. So the main thread was entering
  the trampoline over and over, and each time found the method already
  compiled and patched the caller again.
- The patching is `mono_arch_patch_callsite`, whose `xchg` instructions are at
  `mono+0x4cada0` (the `mov r11, imm64` form) and `mono+0x4cae82` (the rel32
  form). FEX sees such a patch only through its SMC tracking. After it
  translates code from an RWX page it sets `PAGE_EXECUTE_READ` on the page,
  and the write fault is where `HandleRWXAccessViolation` drops the stale
  translation and where `DetectMonoBackpatcherBlock` turns the `xchg` into
  `MonoBackpatcherWrite`.
- Since `madeira-unix` 0019, a guest's own code range is mapped as the pool's
  RW side, writable on the host whenever it was mapped so. But Madeira's
  alias-ownership check in `mprotect_exec` (ml640) returns before applying any
  protection to an alias-owned range. FEX's `PAGE_EXECUTE_READ` was therefore
  never applied, the pages stayed writable, Mono's patches landed without a
  fault, and FEX kept running the translation that called the trampoline.
  The baseline log has no `[smc-trap]` line and no `[mono-site]` line. 0019
  came after the 720-row record's build, which is why that record did not
  have the cost.

## 2. Fix

`patches/madeira-unix/0027`: in the RW view, the ml640 early return now
applies write or no-write from the requested protection with `vm_protect`,
never host EXEC. A store to a trapped page takes 0003's `[smc-trap]` delivery,
and FEX invalidates the page and makes it writable again.

In the run with 0027, the log shows `[mono-site] ml712 FIRST detect
rip=… (mono+0x4cada0)`, which is the backpatcher `xchg` named above. There
were 2,816 `[smc-trap]` deliveries, all of them `guest access violation`, and
the first frame came at +11.16 s (+8.79 s in the pin-move play, on a cooler
phone). The screenshot at first-frame+150 shows the Knight in King's Pass,
correctly drawn.

## 3. Runs

`pp perf --secs 200 --settings '{}' --pad first-frame+35:hk-new-game --pad
first-frame+90:hk-walk --shot first-frame+150` (run `w1118-smcfix-gp`), the
same route as the baseline's `w1118-native-gp`:

| phase | baseline (966167bd) | with 0027 (5ed67164) |
|---|---|---|
| menu t=15-30 | 120 FPS, `0024` 35-41 Mi/f | 120 FPS, `0024` 5.7 Mi/f, 32 % busy |
| play t=110-200 | 25-30 FPS, GPU 12-22 ms, `0024` 175 Mi/f on P | 62-71 FPS, GPU 13 ms (94 % busy), `0024` 22 Mi/f, 88-92 % busy on E cores at 1.6-1.7 GHz |
| all threads in play | 256 Mi/f | 72-74 Mi/f |

The work that remains in play is about 1.5 G instructions a second on the
main thread, running on E cores, with a GPU frame of 13 ms. 120 FPS needs a
GPU frame under 8.3 ms at native resolution and the main thread back on a P
core.
