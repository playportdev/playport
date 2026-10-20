**Linear:** PLA-413, PLA-364

# 2026-10-20: RDR2 stops drawing at the 56th Social Club helper start (madeira-unix 0176), and the first phone runs of the pending set and the compile logging

**Follows:** [rdr2-gameplay-memory](2026-10-20-rdr2-gameplay-memory.md) (IPA `3569a44c`, run e4).
**Brought in:** madeira-unix 0175 (decision [0136](../decisions/0136-the-wineserver-reads-only-marked-request-fds.md),
[wineserver-pending-set](2026-10-20-wineserver-pending-set.md)); mesa 0052 and 0053 and decision
[0137](../decisions/0137-graphics-options-set-any-variable.md) ([kk-compile-levers](2026-10-20-kk-compile-levers.md)).
**Change:** madeira-unix 0176 (`pp_proc_sockets.h`, test `tools/tests/test_proc_sockets.py`).

The phone was on external power at 80 %, with 4.7–5.6 GB free; the owner was at the phone for
part of s2. Every RDR2 run used `--pad --action set:donorPoolMB=auto --action
set:endGameSocialClubAfterSignIn=true --settings 'app-1174180:{"aspect":"16:9"}'`, Story only,
Story selected by the landing-page script. Runs are under `$PLAYPORT_BUILD/ui-runs/`; scripts,
screenshots and device logs under `$PLAYPORT_BUILD/agent-notes/pla413e/` (never committed).

## Builds and runs

| IPA sha256 | What | Hollow Knight first frame +10 | RDR2 runs |
| --- | --- | --- | --- |
| `a076ca1985d38a4731f0bdfb51a27e0cfd15f05a193b63822e6739ae2d66100d` | main + srvpoll (0175) + kkcompile (0052, 0053) | passed (`ui-runs/20261020T105019`; `[srv-pending] MADEIRA_SRV_PENDING=1`) | `…T105836-rdr2-s1`; `…T112521-rdr2-s2` with runtime `env.MADEIRA_SRV_PENDING=0` |
| `e843d571ef5c19b50889712bc4386fea8987065304d7a08e98d4c27061a403c5` | + madeira-unix 0176 | passed (`…T115140`) | `…T115239-rdr2-s3` |
| `f7bfed851d70e448d157cb4adf6dcccb257c7fd228f9d3e9dc009d62b49bd127` | + madeira-unix 0177 and decision 0138 (dev switch, off by default) | not run yet (phone paused for a desktop reference run) | none yet |

A Steam check on `a076ca19` (`…T105608`: Games, then Settings › Accounts) showed Steam signed in;
the wineserver does not run there, so the log has no `[srv-poll]` line at all.

## 1. The game stops drawing at the 56th helper start (madeira-unix 0176)

- **What showed:** s1 and s2 both stopped drawing a few minutes into Story: the screen did not
  change for over 5 min (s2 from 11:34:28), the app's run events stopped, the `[frames]` count
  stopped at 11:34:22, and `[cpu-split]` showed no guest thread running. The process stayed alive.
- **The cause:** right before it, the game's 56th `SocialClubHelper.exe` start (the session root
  ends each restart, decision 0135; the game restarts it about every 5 s) logged
  `[Wine child] proc-socket table FULL (64)!` and then `wine client error:0: version mismatch
  172/964`. It was the session's 65th child: `ios_register_proc_socket` took the next of the 64
  entries and never one given back at an exit, so the child had no master socket of its own and
  spoke on another process's. s1 shows the same lines at its own 56th helper start.
- **The fix:** a registration claims the lowest free entry (with a placeholder until its socket is
  in place); readers scan up to the high-water mark, at most 64; an exit and a teardown give an
  entry back with one compare-and-swap, reading the socket first, so one of them closes it, never a
  later child's socket in a reused entry. The host test runs 1,000 start/end pairs in a 4-entry
  table, and 8 threads × 20,000 start/end pairs under ThreadSanitizer.
- **Not yet shown on the phone:** s3 ended at 13 helper starts (section 3), before the 56th.

## 2. The pending set (0175) and the compile logging (0052) on RDR2

| run | first frame | wineserver thread cpu (`[thread-sample]` mean / p50 / max) | PROF-BT `read_request` share | `[kk-compile] FAIL` | MTLCompilerService `killing_highwater_process` |
| --- | --- | --- | --- | --- | --- |
| r3/e3b (before, `ac3ceac7`) | 112 s | 75 / 85 / 89 % | 62 % | (no logging) | r3: 11 |
| s1 (pending on) | 420 s | 24 / 19 / 66 % (includes the hang) | 5 % | 0 | 15 |
| s2 (pending off) | ~130 s | 58 / 75 / 88 % | 56 % | 0 | 13 |
| s3 (pending on) | 85 s | 46 / 57 / 70 % | 8 % | 0 | 0 (4.5 min run) |

- **The A/B (s1 against s2, the same IPA, the same scene; per-minute `[xp-t]` and `[frames]`):**
  in 3D gameplay the wineserver took 14.1 % of a core with the pending set (s1, 11:09–11:12:44)
  against 40.6 % without it (s2, 11:30:30–11:34:22) and 46.5 % in r3; a request's round trip was
  0.14 ms against 0.32–0.33 ms; the game presented 20.6 frames/s against 14.6 (s2) and 14.2 (r3),
  with 6 hitches over 1.5 s against 22. The pending set stays on.
- With the pending set the wineserver thread spends 78–79 % of its samples waiting instead of
  23–31 %, and `read_request` drops from over half its samples to 5–8 %.
- s1's 420 s to first frame was not the pending set: s3, with it on, reached first frame in 85 s.
  In s1 the requests ran at a steady ~9,500/s with no `lock_file`/`unlock_file` (the game's loading
  in e3b) from 60 to 390 s while a 129×129 window was redrawn: the launcher waited.
- The heartbeat's `found=` line is logged every 50,000 loop passes; the pending set makes far
  fewer passes, and none of these runs logged one.
- No Metal build failed. s1 translated 1,986 shaders (25.3 s), s2 and s3 deserialized about 3,450
  from the cache (1.9 s) with 1.8 s of Metal builds.

## 3. s3: the per-process limit during the Story load

s3 was killed by jetsam (`per-process-limit`, 11:57:17), 2 min after Story was selected, before
gameplay: the footprint rose from 6.6 to 7.5 GB in its last 30 s (internal 5.6 GB, graphics
2.1 GB), the same loading peak that ended e2b and e3b. s2 had loaded past it with internal
3.4 GB. This run says nothing about 0176.

## 4. The stretched 3D (not yet tested at 1/1)

s1–s3 ran at Resolution Scale 1/2 (`system.xml` `scalingMode kSettingScale_Mode1o2`, windowed
1280×720, unchanged since e4): the owner saw the 3D still too wide in s2, with the HUD right. The
logs show the guest screen 1280×720 (`title: display: screen 1280x720 (the title's screen
16:9@720)`), the swap chain 1280×720, the layer 2736×1260 (aspect-fitted, as the screenshots
show: the 3D fills a 16:9 box). The game's window is 1280×720 client at (317,167) (`[win-pos]
hwnd=0x100b4 vis={317,167,1597,887}`): centred as on a 1920×1080 screen, with only its top-left
963×553 on the 1280×720 screen. The 1/1 comparison and a GPU capture are still to do.
