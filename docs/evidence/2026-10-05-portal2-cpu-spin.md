# Portal 2: where the CPU goes, and x87 at 64-bit precision

## Result

- **The cost was x87 software floating point, not spin-waiting.** Portal 2's
  `engine.dll` does its vector math on the x87 stack (`fsqrt`, `fdivp`, `fmul`
  in its hottest loops, e.g. rva `0x124b00`). By default FEX runs each such
  instruction at 80 bits as a call into software floating point. With FEX's
  `X87ReducedPrecision=1`, Proton's global value, now taken for every game
  (decision [0048](../decisions/0048-x87-reduced-precision-global.md)):

  | Scripted play, t = 95–135 s | baseline `p2y-base` | 64-bit x87 `p2y-final` |
  | --- | --- | --- |
  | FPS | 60.0 | 60.0 |
  | main thread `002c` | 40 % of a core, 24.3 Mi/f | 28 % of a core, 14.9 Mi/f |
  | all threads | 76.6 Mi/f | 67.4 Mi/f |
  | process CPU (P / E) | 122 % (82 / 40) | 119 % (47 / 71) |
  | CPU power (`[xp]` mJ) | 558 mW | 407 mW |

  The uncommitted per-game build `p2y-x87` measured the same: 15.1 Mi/f on the
  main thread and 344 mW. So the main thread does 39 % less work a frame, the P
  cluster's load roughly halves and the CPU draws 27–38 % less power, at the same
  frame rate. Mi/f is million instructions a frame.
- **No spin loop was found.** Each candidate was checked:
  - **The runtime's adaptive yield** (`NtYieldExecution`, madeira ml1063).
    `[xp-api]` counts 140–900 yields a second in play, none of them slept, and 0
    `NtDelayExecution` (`Sleep(0)`) calls. That is too little to cost anything.
  - **Wine's alert waits.** `[sync-census]` shows 0 spin tries.
  - **FEX's x86 `PAUSE`.** FEX emits ARM `YIELD` for it, which Apple's cores
    retire like a NOP. A FEX patch emitting `ISB` instead changed nothing:
    74.1 against 74.7 Mi/f and 123 against 121 % CPU in Portal 2 (`p2y-isb`),
    and 67.5 against 68.3 Mi/f and 570 against 571 mW in Hollow Knight
    (`hky-isb`). It was dropped.
  - **DXVK.** Its spinlocks yield after 200 probes, and its only long spin
    waits on a pipeline that another thread is compiling.
- **The human E-core stretch was a heavier scene.** In
  `p2-human-720-after` at t = 285–300 s, the work a frame rose in every thread.
  The main thread rose 1.4–2.1×, `dxvk-cs` 1.9–2.9×, the job thread `0094`
  1.7–2.4× and the in-process wineserver 1.0–1.4×. `dxvk-cs` and the server do
  not spin, so this was more work, not waiting. At t = 255 s, on the E cores
  alone, the work was the same as in normal play (96.5 Mi/f).

## Where the CPU goes (before)

Per thread (`threads.txt`, `p2y-base`, scripted walk at 60 FPS, 74.7 Mi/f in all):

| Thread | Share of a core | Mi/f |
| --- | --- | --- |
| `002c` (main: game, client, material system) | 40 % | 23.9 |
| `0054` `dxvk-cs` | 16 % | 9.5 |
| native: the in-process wineserver `main_loop` | 10 % | 7.5 |
| `0024` | 3 % | 4.8 |
| native: second busiest | 6 % | 4.6 |
| `0094` (job thread) | 6 % | 4.5 |

The samples (`pp perf --cpu-prof`, runs `p2y-prof-before` and
`p2y-prof-x86c`, 8,000–9,600 samples of the busiest threads):

- **By thread:** the main thread 54–56 %, `dxvk-cs` 11–14 %, the wineserver
  12–13 %.
- **By class:** FEX-compiled guest code 38–43 % and system calls 31–34 %. FEX's
  own `xtajit.dll` is 5.5–6 %, which includes its x87 software floating point
  (`softfloat_roundPackToExtF80`, `f128_mul`, `extF80_mul`), and
  `wow64win.dll` 4 %.
- **By leaf:** `read` is 7–8 %, the wineserver's replies (about 49 requests a
  frame). The loading samples are `fstatat`, `getattrlistat` and `openat`;
  `swtch_pri` (`sched_yield`) is 0.4–2 %.
- **In the main thread's guest code,** the hottest blocks are `engine.dll`
  rva `0x124b00`/`0x124b40`, `0x15c440` and `0xe1ac0`. Each calls out of the
  block into FEX's x87 helpers.

## The profiler (madeira-unix 0079, diagnostics)

The sampler (`WINE_IOS_PROF=1`, Settings' Diagnostics, dev builds) named
guest code only through the 64-bit loader list, so every i386 sample stayed an
anonymous `x64-JIT`. It now keys an i386 sample by its EIP, taken from the
running block's host-pc table rather than the frame's stale RIP, and keys a
helper called from a block by the caller's EIP. `tools/sampleprof.py` names
the module from the log's i386 image lines, symbolises Wine's i386 DLLs and
DXVK's `d3d9.dll`, and adds a `guest-thread` table. One limit remains: each
burst prints only the top 45 entries of a table, so the flat tail of guest
code is under-counted.

## Checks

- **Screenshots.** In `p2y-final` (+20, +66, +76, +84, +110 s) and
  `p2y-portals` (+76 to +92 s):
  - the main menu and its lighting;
  - The Cold Boot's start, with shadows and light shafts, the portal gun, the
    crosshair, the HUD hint and GLaDOS's subtitles;
  - the gun firing against an unportalable wall, with its spark particles.

  Nothing was misdrawn. No portal was placed: the scripted shots hit
  unportalable surfaces. Looking through a placed portal is left to the
  human play.
- **Faults.** `p2y-final` logs the same 36 exception lines and 311 `err:seh`
  lines as `p2y-base`, all of them the handler set-up.
- **Hollow Knight.** `pp ui --play app-367520 --until first-frame+10 --shot`
  reached its first frame at +9.90 s and ran on, with `x87reduced=1` in its
  `fex:` line. `pp perf --secs 100 --pad first-frame+25:hk-new-game --pad
  first-frame+45:hk-walk`, t = 40–105 s:

  | Run | FPS | CPU (P / E) | CPU power | Mi/f |
  | --- | --- | --- | --- | --- |
  | `hky-base` | 59.5 | 117 % (86 / 31) | 571 mW | 68.3 |
  | `hky-final` | 59.6 | 115 % (84 / 31) | 551 mW | 69.3 |

  It is unchanged, as expected: Unity's x86-64 code does little x87.

Every run started at thermal `nominal` and stayed there, met no CPMS budget
and ran on battery, at 69 % down to 50 % charge.

Final IPA: `.work/out/20261005-102959-f4c8079a/Playport-26.5-f4c8079a.ipa` (dev),
SHA256 `f4c8079aa02433ccfa63e4d32460cb53518c0d2b9f0c4e43e5a829ab56501ab0`.
It passes its 78 IPA checks and is installed.

## Human play on the final IPA

`pp perf --title app-620 --secs 300 --settings '{"screen":"720"}'`, played by
the owner with a controller (portals, tunnels, one death and reload), IPA
`f4c8079a`, run `p2-human-720-x87`, against the three earlier 720p human plays:

| Run | FPS mean | p10 | median | lowest budget |
| --- | --- | --- | --- | --- |
| `p2-human-720` | 56.5 | 50.0 | 59.4 | 769 mW |
| `p2-human-720-qos` | 56.2 | 46.5 | 59.9 | 769 mW |
| `p2-human-720-x87` | **58.4** | **53.8** | **60.0** | 769 mW |

- At the 769 mW budget (from 235 s) it held 60 FPS to about 275 s, where the
  earlier plays fell to 44–51 FPS at the same stage. The P cores were still
  taken away in the last 25 s (P 8–20 %), at 51–55 FPS.
- Hitches over 150 ms: the level load (30–41 s) and the death's reload
  (148–154 s, up to 575 ms), as before.
- **Portals:** the owner placed portals and looked through them. Rendering,
  portal views and physics looked right with x87 at 64-bit precision.
- Battery went from 41 % to 38 %, not charging.

## Runs

| Run | IPA | What |
| --- | --- | --- |
| `p2y-prof-before`, `-x86`, `-x86b`, `-x86c` | `61647727`, then 0079's drafts | `--cpu-prof`, `p2-cold-boot` at +30, `p2-walk` at +70, `--secs 140` |
| `p2y-base` | `9de43e3a` (0079) | the same without `--cpu-prof`: the baseline |
| `p2y-isb` | `f792cda7` (+ FEX PAUSE as ISB) | the same |
| `p2y-x87` | `8d75f9dd` (draft, x87 for app 620 only) | the same |
| `p2y-final` | `f4c8079a` | the same, `p2-walk` at +88, five screenshots |
| `p2y-portals` | `f4c8079a` | `--secs 95`, a portal-firing pad, four screenshots |
| `p2-human-720-x87` | `f4c8079a` | the owner's 300 s play, above |
| `hky-base`, `hky-isb`, `hky-final` | `9de43e3a`, `f792cda7`, `f4c8079a` | Hollow Knight, as above |
