# Hollow Knight at native resolution: wine-11.18 against wine-11.4

**Date:** 2026-09-26. **Tree:** the commit that adds this record. It also
changes `pp perf --analyze` so that the table does not stop at the first 5 s
with no frame. **Builds:** dev IPAs `966167bd6066cafc35461298beb9bec4e01f5b7c8387c90ede78cbd9f5f8c50e`
(wine-11.18 pins, `e33f46e`) and `ab1928952d0a698fc52d8e374e49a4cff02bc79f3aaa585b1ae3618e79cbd98b`
(the last wine-11.4 build, `be6f560`). Both have the same FEX and DXMT pins. Each
was installed in place with `pp install --no-build --ipa`, and the phone was
left on the wine-11.18 IPA. **Phone:** iPhone Air (`iPhone18,4`), iOS 27.0,
over netmuxd Wi-Fi, charging. Neither run started cold: thermal pressure
reached 10 about 25 s after launch and 20 about 45 s after launch.

**Result:**

- **wine-11.18 is at parity with wine-11.4.** The same route gives the same
  frame rate, GPU time and per-thread work on both. The main thread does
  169 to 189 Mi/f in play on both builds.
- **Native-resolution gameplay runs at 25 to 30 FPS on both.** In King's Pass
  at 2736x1260 the Unity main thread (`0024`) is 99 % busy on the P cores and
  does about 175 million instructions per presented frame (Mi/f). No other
  thread is over 10 % busy. The GPU time is 12 to 13 ms a frame and rises to
  21.6 ms from about 140 s, as the GPU clocks down, but the frame interval
  stays at 33 ms. So the limit is the main thread, not the GPU.
- **That main-thread cost is about seven times the earlier record.** The
  [720-row gameplay record](2026-09-25-hk-720-gameplay.md) measured the main
  thread at 20 to 25 Mi/f in the same room (build `62e149af`, FEX-2609.1
  already in). On the main menu the thread now does 35 to 41 Mi/f, with or
  without `MADEIRA_QUIET=1 WINEDEBUG=-all`. Nothing tells the two causes apart
  yet: a regression between `62e149af` and `be6f560`, or the game's state
  (the save the route loads, or what the scripted pad leaves running).
  Finding this out comes before any GPU or thermal work: at 175 Mi/f, 120 FPS
  would need 21 G instructions a second from one thread.

## 1. Runs

`pp perf --secs S --settings '{}' --pad first-frame+35:hk-new-game --pad first-frame+90:hk-walk`.
Times are seconds from the first HUD line. The route loads King's Pass from
about t=100 s, which is a 10 s stretch with no presented frame.

| run | build | secs | menu t=15-25 | save slots t=45-90 | play t=110-135 | play t=140-200 |
|---|---|---|---|---|---|---|
| `w1118-native-gp` | 966167bd (11.18) | 300 | 120 FPS, GPU 6.8 ms | 90.5 FPS, P 2.38 GHz | 29.3 FPS, GPU 12.4 ms | 30.2 FPS, GPU 21.6 ms |
| `w114-native-gp` | ab192895 (11.4) | 200 | 97 FPS, GPU 7.0 ms | 83.1 FPS, P 2.02 GHz | 25.2 FPS, GPU 13.1 ms | 28.1 FPS, GPU 21.5 ms |
| `w1118-shots` | 966167bd | 140 | | | 22.5 FPS on the HUD at first-frame+130 (the Knight in King's Pass) | |
| `w1118-menu-quiet` | 966167bd, `MADEIRA_QUIET=1 WINEDEBUG=-all` | 40 | 115-120 FPS, main thread 35 Mi/f | | | |

The 11.4 run came about 6 min after the 11.18 run and started warmer. Its
CPMS budget was already held at 2,624 to 2,715 mW, while the 11.18 run
logged no budget, so its lower frame rates in the menu and on the save-slot
screen are not a difference between the builds.

`threads.txt`, in play:

| thread | 11.18 t=120 | 11.4 t=120 | 11.18 t=270 |
|---|---|---|---|
| `0024` main | 175 Mi/f, 99 %, P 0.99 | 187 Mi/f, 99 %, P 0.99 | 169 Mi/f |
| `00bc` / `00c0` (probably the audio mixer) | 27 Mi/f, 9 % | 32 Mi/f, 10 % | 27 Mi/f |
| `00b0` UnityGfxDeviceWorker | 16 Mi/f, 9 % | 16 Mi/f, 8 % | 16 Mi/f |
| `009c` dxmt-encode-thr | 6.4 Mi/f, 4 % | - | 6.3 Mi/f |
| all threads | 256 Mi/f | 278 Mi/f | 247 Mi/f |

The `[xp-api]` census has no spin in play: 1,000 to 2,700 yields a second
(against 25,000 to 31,000 a second while the menu loads) and 400 waits a
second.

## 2. Leads for the main thread

Follow-up: the main-thread cost was Mono's patched calls still going through
`mono_magic_trampoline`, because FEX's SMC write trap was never applied to
Mono's code pages. `madeira-unix` 0027 fixes it; see
[2026-09-26-hk-mono-trampoline.md](2026-09-26-hk-mono-trampoline.md).

- The start-up `[rip-profile]` (its 12 generations cover the first minute
  only, not play) puts 45 to 52 % of running guest samples at a return
  address in `mono-2.0-bdwgc.dll+0x283300`, after an import call. Its host
  PCs are in FEX's code cache. A profile of the main thread in play, with
  mono's export table to name the function, is the next measurement.
- Madeira `8c050d03` (in `be6f560`, after `62e149af`) moved host XInput into
  win32u. Hollow Knight polls its controllers from the main thread every
  frame, so the cost of one XInput poll is worth measuring.

## 3. Tooling fix

`pp perf --analyze` built its table by walking 5 s buckets up to the first
one with no metal-HUD line. The 10 s King's Pass load has none, so every
gameplay run was cut off at about t=100 s. A bucket with no frame is now a
0 FPS row, and the walk stops at the last HUD line (`tools/tests/test_perf.py`
`test_load_gap_does_not_end_the_table`).
