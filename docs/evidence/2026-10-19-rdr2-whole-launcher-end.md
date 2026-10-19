# 2026-10-19: RDR2 with the whole launcher ended at the first frame, and terminated processes torn down

**Linear:** PLA-416, PLA-417, PLA-409, PLA-413. **Decisions:** 0125, 0126, 0127.

## Builds and runs

| IPA sha256 | HEAD | Run | What |
| --- | --- | --- | --- |
| `cd0b0d12e96b372aa256b7c37483772be4b84c9a3bc502fecffb6cccd9522387` | 9831657 | `20261019T173116` | Hollow Knight gate: **failed**. The app ended right after the session root's first thread started ("wineserver crashed"); no first frame |
| `99d12fba8acd83e1ec969687b08cfc4cce48c0849c4e587e4b9c7e3c1e725fd2` | 9831657 + the first fix below | `20261019T173731` | Hollow Knight `--until first-frame+10 --shot`: first frame at +8.58 s |
| same | same | `20261019T173829` | RDR2 `--action set:donorPoolMB=auto --play app-1174180 --until first-frame+600 --wait 1500 --screenshot-after 240 --screenshot-after 600 --shot`, device log kept |

The two runs that passed ran in one `pp phone lock` session. Battery was 80 %, with 4.7 GB free.

**The gate failure.** madeira-unix 0169's first cut mirrored a thread's host-section depth through
`get_thread_data()`. Uninterrupted sections are taken before `thread_data_key` exists, and then
`pthread_getspecific(0)` returns Darwin's `pthread_self` slot. The write landed in the pthread
structure. The fix, committed in 171cc03, writes only through a TEB found with an initialized
key; the build after it passed the gate.

## RDR2, run `20261019T173829`

**Outcome.** The app ran to first-frame+600 with no memory-limit kill.
- The game's first frame came at +95 s. The launcher end ran at +90 s on the app's clock (the
  first 2 s slice after the frame).
- Screenshots at 240 s, 600 s and the stop (described here; the images stay in the run
  directory) show the game's own "SOCIAL CLUB ERROR" screen: "Social Club failed to
  initialize. Error code: 4. Press OK to view an online support article … Press CANCEL to
  exit". It has Accept and Cancel prompts. Nothing was pressed.
- No sign-in: the app logged no `launcher: the game signed in` line.

**Why Social Club failed.** RDR2.exe never loaded `socialclub.dll`. At +95 s (log lines
125253–125271) its thread 0420 tried three times:
- `virtual_map_image … socialclub.dll status=c0000017 size=601000`;
- each try came after `[va-scan] FAILED window=0x10000..0x73ffff0000 size=0x601000 …
  errno=17(File exists)`;
- then `load_dll [dll-missing] … socialclub.dll status=c0000017`.

From +94 s the guest window below the furniture ceiling was full. 139 `[va-scan] FAILED` lines
followed:
- private allocations went above the ceiling (`[va-ceiling] … placed at 0x74…`);
- an image has no such fallback, so the 6 MB DLL failed.

So:
- the game started no Social Club helper of its own;
- it never opened the launcher's pipe;
- no `rgsc_gameinst` name appears in the log. The only `rgsc` lines are the launcher's
  `RGSCSystemTray` window and its `\??\pipe\chrome.rgsc_launcher_0` open at line 33846, both
  before the end.

RockstarService (pid 0x118) exited by itself at line 129264, after the end. Its views were
released by 0154 (`[view-owner] … freed 37 views (33 MB)`). Whether the game would also fail
with the launcher alive and the DLL mapped is not shown: in run `20261019T161557` the DLL mapped
and the app hit the memory limit.

**The launcher end (0125).**
- **The end.** At line 122580: "the game's first frame: ending the launcher, its error handler
  and its Social Club helpers, never the game". The root ended Launcher.exe pid 112,
  RockstarErrorHandler.exe pid 124, and SocialClubHelper.exe pids 440 and 648. It kept RDR2.exe
  pid 1052 and crashpad_handler.exe pid 1068: "4 ended, 2 kept as the game's, of 7 processes".
- **Dialogs.**
  - PlayRDR2.exe (pid 0x64): `MessageBoxIndirectW` caption "Error", text "Unable to launch
    game, please try reinstalling the game." (accepted by 0125);
  - the game's own Social Club error screen above.
  - Before the end the launcher showed its windows "Rockstar Games Launcher" and "Rockstar
    Games - Sign In" (hidden again after about 7 s), then a 1280x600 launcher window.
- **Restarts.** None: no `[launcher] restart` line, and the job's completion port was set (no
  "no job messages" line). The app was stopped with the title running, so the end-of-title
  summary line was not written.

**Teardown of terminated processes (0127).** There are two `[proc-end]` lines:
- **pid 0x2d8**, a CEF child the launcher's browser terminated itself at about +62 s (line
  67603). Before 0169 such a child leaked everything.
  `freed image=284 private=3101 spans=315 callret=60 l1=32 band_other=216 pool=88 MB, kept 45
  MB; 17 finished, 0 parked`.
- **pid 0x7c, RockstarErrorHandler.exe**, after the end:
  `freed image=17 private=6 spans=61 callret=32 l1=16 band_other=88 pool=31 MB, kept 4 MB; 9
  finished, 0 parked`.

Launcher.exe (0x70), the browser helper (0x1b8) and the renderer helper (0x288) were **not**
torn down. They kept live threads in in-process waits, and parking refused every one of them:
- 22 `[proc-end] not parked tid=…: not blocked in __ulock_wait` lines; 18 of these threads gave
  up as `[async-abort] … STILL RUNNING` after about 64 s.
- The threads belong to pids 0x70 (5), 0x1b8 (11), 0x288 (2), 0x7c, 0xb4, 0x118 and 0x33c (1 each).
  None is RDR2.exe's (0x41c) or its crash handler's (0x42c).
- The cause: `futex_wait` uses `os_sync_wait_on_address`, which is the `__ulock_wait2` system
  call (x16 = 544) on this iOS, and 0169's first cut accepted only `__ulock_wait` (515). Commit
  171cc03 accepts both. It also logs `insn`, `x16`, `x0`, the host sections and the FEX stamps
  with each refusal. That build (`1e7873c5…`) has not been on the phone.

**`[proc-mem]` (MiB committed/resident/compressed), before and after the end:**

| pid | +86 s (line 116760) | +158 s (line 130721) | +684 s (line 171072) |
| --- | --- | --- | --- |
| 0x70 Launcher.exe | 78 threads; image 68/29/25, private 124/22/28, fex 1022/111/9 | 5 threads, the same memory | 5 threads, fex 950/73/43 |
| 0x7c RockstarErrorHandler.exe | 9 threads; fex 222/0/30 | gone (torn down) | gone |
| 0x1b8 SocialClubHelper (browser) | 49 threads; image 316/160/26, private 94/62/0, fex 981/330/29 | 11 threads, fex 1093/222/128 | 11 threads, image 316/2/45, fex 1093/122/227 |
| 0x288 SocialClubHelper (renderer) | 18 threads; image 284/148/16, private 158/122/2, fex 509/210/20 | 1 thread, the same memory | 1 thread |
| 0x41c RDR2.exe | 7 threads; private 840/51/0 | 61 threads; private 2334/1293/436, fex 1151/184/32 | 61 threads; private 2334/1209/521 |
| all | 9559/2173/359 | 12173/2564/1140 | 11907/2285/1399 |

The launcher side kept about 3.0 GB committed after the end, most of it compressed by the stop.
The proof that killed memory is freed is therefore the two `[proc-end]` lines, not these
three processes.

**Footprint** (`[xp]` `fpMB`):
- 3,856 MB at +54 s;
- 3,558 MB at +58 s, after pid 0x2d8's teardown;
- 3,790 MB at +89.6 s, the first frame and the end;
- 5,463 MB at +94.9 s and 7,088 MB at +109 s, while the game loaded;
- flat at about 7,074 MB to the stop: `[footprint] phys=7077 MB (peak 7090) compressed=1808 MB`.

The limit is 8,192 MB.

**JIT pool (896 MiB):**
- `room_mb` was 812 at the game's start, 135 at line 72991 and 116 at line 80446;
- at the stop: head 321 (309 live), tail 481 (465 live), room 94 MB;
- no exhaustion, no tail refusal.

**The 8,960 MB hold (0126).**
- The runtime held `0x79d0000000 +8960 MB` at boot.
- A CEF renderer's 2 GB pool (`[jumbo#3]`, peb 0x141408000), whose hinted placements failed,
  took it (`releasing the holdback … for a 2048 MB request`).
- RDR2.exe's own 8,960 MB reservation (`[jumbo#5]`) still succeeded, above the ceiling at
  `0x7680000000` (`[va-ceiling]`), after pid 0x2d8's teardown had freed its 2 GB pool at
  `0x7780000000`.
- No `[va-band]` line: no jumbo reservation failed.
- `take()` hands the hold to any request that fits, not only to the game's.

**Device log.** In `.work/agent-notes/pla416/run7/rdr2/` (private). It holds no memory-limit or
jetsam line for the app, only CPU-wakes and CPU-usage resource notices (17:38:54, 17:40:55). One
JetsamEvent report for the day was pulled.

## Follow-ups

- Run RDR2 again with commit 171cc03's parking. The launcher's stuck threads should park, and
  its three processes should be torn down.
- An image cannot map once the window below the furniture ceiling is full. RDR2's
  `socialclub.dll` failed that way at +95 s. Private memory spills above the ceiling; images do
  not.
- The 0126 hold is taken by the first request that fits (here a CEF 2 GB pool), not by RDR2's
  8,960 MB one.
- A process that exits by itself (0154) still keeps its views in FEX's band (0127).
- Ending the launcher at the first frame leaves the game without Social Club in this run: either
  the DLL's mapping fails (above), or the game also needs the launcher. Not yet shown which.
