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
| `f7bfed851d70e448d157cb4adf6dcccb257c7fd228f9d3e9dc009d62b49bd127` | + madeira-unix 0177 and decision 0138 (dev switch, off by default) | not run (superseded by the next build) | none |
| `62cea69c0c81f75d924cf3c3b9e0f9d80735838191e9616b934675416785eff5` | + mesa 0060–0062 (decision 0139) | passed (`…T125123`, `…T130013`) | `…T125218-rdr2-s4` (shader translation run), `…T130113-rdr2-s5`, both with `--action set:refuseGameSocialClubRestart=true` and graphics option `MESA_KK_DUMP_MSL_MIN_KB=1024` |

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
- **On the phone:** s3 ended at 13 helper starts (section 3). In s5 (section 5) the game asked
  for its helper 260 times more and no `proc-socket table FULL` line came, but those starts were
  refused at creation (decision 0138), so they took no entry: 0176's reuse is covered by the host
  test, not yet by a run with 56 live-then-ended children.

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

## 5. s5: 25 minutes after first frame, no memory kill (0176, 0177/0138, mesa 0060–0062)

Run `…T130113-rdr2-s5` reached its stop condition (first frame +1,500 s) with the app alive
(`ok: true`). Story was selected at 13:04:12; gameplay (HUD, minimap) from about 13:06 to the
stop at 13:28, of which 13:10–13:26 was the game's pause menu and Settings (section 6). The left
stick moved the view (screenshot change 17–109 per cycle, `mover.log`), not seated.

| | r3 (`82b9cd29`) | s5 |
| --- | --- | --- |
| end | 8,192 MB limit after ~2.5 min of gameplay | the run's stop, 22 min after Story |
| footprint, gameplay at scale 1/2 | 7.9 GB at the kill | 7.15–7.33 GB (13:06–13:10) |
| footprint, menus | | 7.05–7.10 GB, level for 13 min |
| footprint, gameplay at scale 1/1 | | 7.39–7.47 GB, peak 7,864 MB at the switch |
| graphics (`[footprint]`) | ~3.1 GB | 2.9–3.1 GB at 1/2, 3.15–3.27 GB at 1/1 |
| presents/s, gameplay | 10–18 | 15.7–22.0 at 1/2, 12.8–21.5 at 1/1; menus 41–46 |
| wineserver thread cpu (mean / p50 / max) | 75 / 85 / 89 % (e3b) | 39 / 41 / 72 %; `read_request` 8 % of its PROF-BT samples |
| game helper starts | 30 ended in 153 s (e3b) | 2 ended after the sign-in, then 260 refused at creation (`[game-sc] refused … start 260`) |
| `[kk-compile] FAIL` | | 0 (3,455 pipelines from the cache) |
| MTLCompilerService `killing_highwater_process` | 11 | 0 |
| thermal | | fair at launch, serious later |

- **The compile levers:** s4, the first launch after mesa 0060's build ID change, translated
  1,986 shaders (45.6 s) and built 13.0 s of Metal with no failure and no MTLCompilerService
  highwater kill; s1, the same 1,986 translations without 0060, had 15. No MSL of 1 MB or more was
  dumped (`Library/Caches/kk-dump` absent after s4 and s5).
- **s4's memory trigger:** the translation pushed the footprint to 7,027 MB at +134 s, before the
  game's Social Club sign-in, so decision 0130 ended the launcher and its helpers. The game then
  had no Story entitlement: its landing page offered "Buy Red Dead Redemption 2 Story Mode" on A,
  and the landing script's A opened the Social Club overlay, which showed "Disconnected from
  Rockstar Games Launcher"; nothing else was pressed and the run was ended. The landing script now
  reads the screen and presses nothing when it shows Buy, Purchase or Store.
- **Saves after s5** (against `pla413c/save-backup-0`): the manual slot `SRDR30000` is unchanged;
  the autosave `SRDR30015`, `ProfileSettings`, `Player`, `cfg.dat` and `cloudsavedata.dat`
  changed (the game's own autosave and settings; in s2 the owner answered a cloud-save mismatch by
  keeping the local saves).

## 6. The stretch is the same at Resolution Scale Off

In s5 the game's Settings › Graphics › Resolution Scale went from 1/2 (×0.500) to Off, applied and
confirmed; the game recreated its window and swap chain (1280×720 at (317,167)). Back in
gameplay at the same cabin, the 3D was as stretched horizontally as at 1/2, now sharper; the HUD
and minimap stayed right. The stretch is not the half-resolution path or its upscale: with the
desktop reference ([rdr2-desktop-reference](2026-10-20-rdr2-desktop-reference.md): ×3.50
horizontally, the phone's projection P00 ≈ 4.02 against the desktop's 1.1486), the game's camera
aspect is wrong (about 0.507). KosmicKrisp's surface reports an identity `currentTransform`
(`wsi_common_metal.c`), so a Vulkan pre-rotation is not it. The game's `system.xml` stays at
Resolution Scale Off after this run.

## 7. s6: 14 minutes of gameplay with the stick at Resolution Scale Off, no memory kill

Run `…T133438-rdr2-s6` (IPA `62cea69c`, the same settings as s5, no Settings visit): Story at
13:37:54, the left stick pushed for 20 s in every ~35 s from 13:40:27 (13 cycles; the view changed
in each, no stand-up prompt was seen), gameplay until 13:54:52, when the run was ended from the
workstation: a supervision script read one `pp phone status` without the app's pid and ended
the run, while the host log shows the game still presenting (`[frames]` 13:54:52) and no jetsam
line for the app. Not a memory kill; the script now needs three such reads in a row.

- **Footprint:** 6.8–7.25 GB through the 14 minutes, peak 7,650 MB (graphics 2.8–3.2 GB,
  compressed 3.7–4.1 GB); level while moving.
- **Presents/s:** 17.7–25.4 per minute of gameplay (13.5 in the first minute), 42–50 on the
  landing page.
- **Wineserver thread:** mean 30 %, p50 16 %, max 70 % of its `[thread-sample]`s.
- **Social Club:** 170 helper starts refused at creation; no `proc-socket table FULL`.
- **Compiler:** no `[kk-compile] FAIL`, no MTLCompilerService highwater kill.
- **Thermal:** nominal at launch, then fair, then serious.
- **GPU wiring:** from 13:39:42 the kernel logged 644 `IOGPUCommandDescriptor::prepare …
  preparedBytes != requiredBytes` faults for the app (required about 2.4–2.5 GB, `maxWired`
  8,589,950,976); the game kept drawing.
