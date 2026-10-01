# The Witcher 3 at Low, uncapped: heat, memory, CPU and GPU

Status: measurement. The results changed three things: `pp perf` now carries
each power budget forward and waits for the phone to cool, madeira-unix 0028
adds a busiest-thread sampling profiler, and fex 0005 makes FEX's AFP switch
work on iOS. Measured on dev IPA sha256
`5725c03c569ef25f3a5f6ca027f9cedb5e75d09583a91a3c934c9eb0d9db2204`
(`pp install` on 2026-09-26 14:33).

The phone was an iPhone Air (A19 Pro: 2 P and 4 E cores, 12 GB), iOS 27.0,
unplugged from 14:05 on.

The game was The Witcher 3 1.32 (app-292030), set through its own Options menu
with the pad:
- Graphics preset Low, HairWorks off, VSync off, Maximum Frames Per Second
  Unlimited;
- every postprocessing option off;
- 1954x900, the title's launch setting.

Every run was
`pp perf --title app-292030 --secs 200 --pad first-frame+10:witcher3-continue --pad first-frame+50:witcher3-walk`,
with Continue loading the Kaer Morhen save and Geralt walking the room from
about 50 s. Table rows are the gameplay window, t = 60–200 s.

## 0. The pad (wine-pe 0007)

Main's c7071e2 replaced Playport's `hio_xinput` with Wine's builtin XInput
DLLs, which read the host controller snapshot, and dropped the `xinput=n`
override. The Witcher 3 ships Microsoft's `xinput1_3.dll` in `bin\x64` and
imports it statically, and the loader took that copy (image size 0x1e000).
That copy finds pads through SetupAPI and HID, which see nothing here, so the
skip prompt read `Space Skip` and the pad did nothing.

- **A load-order override cannot fix it.** `WINEDLLOVERRIDES=xinput1_3=b`
  does not help, because Madeira's iOS loader never substitutes a builtin for
  a mapped file: `load_builtin` returns `STATUS_IMAGE_ALREADY_LOADED`.
- **The fix.** wine-pe 0007 opens the five XInput names from system32 before
  the search path, as a KnownDLL would.
- **The result.** With it the log loads a different `XINPUT1_3.dll`
  (`xinput1_3.dll-1e6d917407e497ba`). The pad drives the main menu, the
  Options pages, the dialogue skips and walking, and the prompts show pad
  buttons (`.work/scratch/w3d/p2.png` onward, not kept).

## 1. The earlier runs measured heat, not the game

Two runs on the same build and route were recorded before the phone was
unplugged. `w3-low-base` started hot and plugged in, and `w3-dpfv-on` started
cooler:

| run | CPMS client 9 | P-core share | median FPS |
|---|---|---|---|
| w3-low-base | 1119 → 660 mW at t ≈ 40 s, then held | 0 % from t = 40 s to the end | 15.3 |
| w3-dpfv-on | 2054 → 660 mW over the run | 150–185 % | 25.1 |

At client 9's floor, 660 mW, the scheduler parks both P cores. The game then
runs on the four E cores at 1.0–1.4 GHz, and the GPU waits for the CPU.

The kernel logs a client's budget only when it changes. `pp perf`'s budget
column took the minimum of the lines inside each bucket, so it printed 2.2 W
(client 0) while client 9 sat at its floor.

- **Fixed:** each client now holds its last value until its next line.
  `summary.json` gains `budget_clients_end`, and `thermal_start` /
  `thermal_states` from the app's new `title: thermal:` lines
  (ProcessInfo.thermalState at the launch and at each change).
- **`--cool`** now also waits until thermalmonitord's last pressure level is
  0. A follower keeps its lines for an hour after each run in
  `$PLAYPORT_BUILD/thermal-follow.log`.
- **Charging adds heat.** During `w3-low-base` the phone drew 5.8 W from the
  charger, 2.5 W of it into the battery.

Every run below started at thermal state `nominal` with pressure 0, at least
15 minutes after the previous run, unplugged. Each stayed at pressure 10
(`fair`), and the P cores stayed in use.

## 2. Memory

The app's limit is 8 GB, not the phone's 12 GB. The runtime logs it at start:
`os_proc_available_memory=7264 MB + phys_footprint=927 MB = 8192 MB (hw.memsize says 11734 MB)`,
with the increased-memory-limit entitlement. The Metal HUD's "Available
Memory" is what remains before the kernel kills the app, not free RAM.

The phys footprint stays flat at 6.1 GB through gameplay, so no leak shows.
The `[phys-map]` bands (dirty MB) break down as follows:

| band | dirty | what |
|---|---|---|
| guest, 0x70..0x74 | ~1.7 GB | the game's heap |
| pa, 0x74..0x7c | ~1.15 GB | the game's 32 GB `jumbo-mb` reservation: its 128 MB arenas; ~370 MB of it compressed or swapped |
| JIT pool | 896 MB | every page dirty from blessing |
| Metal (tag 100 and the driver) | ~0.35–0.9 GB | |
| fex | ~0.3 GB | |
| hostlow | ~0.2 GB | Wine and the libraries |

The JIT pool uses about 357 MB at peak: 213 MB of image copies at its head,
and 144 MB of FEX code buffers from its tail (`[jit-pool] tail` lines).
Hollow Knight uses less. A 512 MB pool (`TitleMode` fixes 896) would return
about 380 MB of headroom. It was not changed: it is headroom, not speed.

## 3. CPU: where the busiest threads spend their time

**The profiler.** madeira-unix 0028 adds it: `WINE_IOS_PROF=1` in a title's
launch settings.
- Every 15 s, a 3 s burst samples the six busiest threads at about 1 kHz while
  they run, walking the frame-pointer chain.
- `pp perf` writes `profile.txt` for such a run (tools/sampleprof.py),
  symbolised against the staged DLLs.
- An `x64:` row names the guest address of the last exit from JIT code (the
  FEX frame's RIP), so it is a call site, not a hot loop. The class, thread and
  native rows are exact.

`w3-afp-on` recorded 36k samples:

| class | % | notes |
|---|---|---|
| x64-JIT | 48.0 | the game's code as compiled by FEX |
| libsystem_kernel | 22.9 | mostly `read`/`write`, the wineserver pipes |
| xtajit64.dll (FEX's runtime) | 13.4 | ExitFunctionEC's FPCR write 8.3 %, the alias lookup `ios_ec_xlate_loop` 1.9 % |
| d3d11.dll (DXMT) | 9.5 | |
| ntdll | 2.1 | QueryPerformanceCounter 1.4 % |

The threads were:
- RenderThread, 48 %;
- the in-process wineserver, 18 %, with the same
  `wineserver_main starting … on thread m…` id;
- the game's main thread, 16 %;
- four `red Task Thread`s, 2–6 % each.

The wineserver answers 6,500–13,000 requests/s. 98 % of them are `select`,
`release_semaphore` and `event_op` (`[srv-req]`). Madeira's in-process sync
would take them off the server, but it is off by default (madeira-unix 0014:
named-pipe reads return 0 bytes with it on).

## 4. AFP off (fex 0005)

FEX's iOS branch of `CPUFeatures::FetchHostFeatures` hard-codes
`SupportsAFP = true` and returns before `OverrideFeatures`. The notes that
come with Madeira found this in RDR2 (§111–112), but never fixed it:
`FEX_HOSTFEATURES` was read and ignored. fex 0005 honours `disableafp` and
logs `FEX: iOS host AFP=`.

| run | AFP | FPS | GPU ms | GPU busy | CPU mW | samples | ExitFunctionEC |
|---|---|---|---|---|---|---|---|
| w3-afp-on | 1 | 30.1 | 35.4 | 94 % | 901 | 35,992 | 8.3 % |
| w3-afp-off | 0 | 30.3 | 35.1 | 95 % | 868 | 30,612 | < 1 % |

With AFP off:
- the FPCR write leaves the profile;
- the busiest threads run about 15 % fewer samples;
- CPU power drops about 4 %;
- the frame rate does not change, because the GPU limits it.

AFP stays on by default: without it, MXCSR.DAZ is not applied.

## 5. GPU: the limit when the phone is cool

In every cool run the GPU is 94–95 % busy at about 35 ms a frame, which gives
30 fps. `DXMT_PASS_PROF=1` shows these gameplay frames (`w3-depth-on`, six
frames, about 1,000–1,150 draws and 75–90 render passes each):

| ms/frame | passes | what |
|---|---|---|
| 6.3 | 5.2 compute | lighting and similar |
| 4.1 | 3 | 1954x900 RGBA16F + D32S8, 10+ draws (forward and transparent) |
| 2.9 | 1 | 1954x900 RGBA8 cleared, 2 draws / 6 primitives: one expensive full-screen pixel shader |
| 3.5 | 3 | G-buffer: 3 RGBA8 targets + D32S8 |
| 1.5 frag + vertex | 3–4 | 1024² Depth32Float shadow maps, 1–2.7 M primitives each |
| ~5 | ~24 | other full-screen passes, 0.2–0.5 ms each |
| ~0.9 | 5.5 | blits |

**Depth compression is ruled out.** Every scene pass loads and stores D32S8.
A build with an opt-out of pixelFormatView on depth/stencil textures
(`DXMT_DEPTH_PFV=0`) measured 34.7 ms against 34.9 ms (`w3-depth-off`,
`w3-depth-on`), so depth compression does not matter here. That patch was
dropped.

## 6. Next

1. The 2.9 ms two-draw pass and the compute dispatches: identify their shaders
   and compare the converted AIR with what the DXBC asks for.
2. The render resolution: 1954x900 against the cohort's 720 rows, measured the
   same way.
3. CPU, for heat and for when the P cores park:
   - in-process sync for this title, a measured run first;
   - the linear `ios_ec_xlate` alias walk on every x64 → ARM64EC exit.
