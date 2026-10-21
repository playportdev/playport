# The launcher's end gives Launcher.exe exit code 0 (decision 0156)

**Linear:** PLA-413. **Decision:** [0156](../decisions/0156-end-the-rockstar-launcher-with-exit-code-0.md).
**IPA:** dev, built in the side worktree `.work/worktrees/launcher0` (decision 0117) on branch
`launcher0` from main `aa2ce25`: `Playport-26.5-c3a8e653.ipa`, sha256
`c3a8e6532de37e093bac3f6016e457df9599652aa8137f4c351545e3949e7151`, `verify-ipa` 88 checks passed.
After the fast-forward into main (`5257e75`), main's build gave `Playport-26.5-41431327.ipa`, sha256
`414313273a71b9841c0d70a93f9fe7e68d1e023a19c80e94453accf46eed5957` (`verify-ipa` 89 checks passed,
no build record changed); every phone run below used that.

**Phone result (section 5): passed in 2 of 2 RDR2 Story runs.** `Launcher.exe` ended with exit code
0 and exited with 0, PlayRDR2.exe showed no "Unable to launch game" box, the game ran on, and the
pad started Story with no press on a box. The owner also confirmed on the phone that RDR2 now starts
without the popup.

## 1. The cause

Rockstar's Steam stub `PlayRDR2.exe` (sha256 `028db16c…483d`) starts `Launcher.exe` with
`ShellExecuteExW` and waits on it with no timeout. Its launch function returns
`GetExitCodeProcess(…) == 0`. If that is false, it calls `MessageBoxIndirectW` with style
`0x45030`, caption "Error" and the text "Unable to launch game, please try reinstalling the game.".
Read from its disassembly (`0x140003340`, the wait at `0x140003408`, the test at `0x140003452`).

The session root ended `Launcher.exe` with `TerminateProcess(h, ERROR_PROCESS_ABORTED)`. Wine's
server writes a terminate's code into every thread when it is not 0, and the process takes its
last thread's code (`server/process.c`, `terminate_process` and `remove_process_thread`). So the
stub read 1067. In the 61 runs of 2026-10-21, each of the 44 RDR2 runs with a `[launcher] ending`
line had the box, within the same end step (run ra1: about 200 log lines after `end ended
Launcher.exe`). The runs without an end
had no box, except one where the launcher had crashed (`status=0xc0000005`).

## 2. What changed

| Where | What |
| --- | --- |
| `app/SessionRoot/launcher_end.h` | `pp_launcher_end_code(p, i)`: 0 for `Launcher.exe` (any case), `PP_LAUNCHER_END_ABORTED` (1067, `ERROR_PROCESS_ABORTED`) for every other process. |
| `app/SessionRoot/playport-session.c`, `end_launcher` | Each process ends with that code, both in the end and in its "once more" step. The line now names it: `[launcher] end ended Launcher.exe pid N (exit code 0)`. A process ended with 0 is opened with `SYNCHRONIZE` and `PROCESS_QUERY_LIMITED_INFORMATION` too. After the whole step (so the helpers are not delayed), the root waits up to 1 s for each one, and logs `[launcher] end: Launcher.exe pid N exited with code C`. If C is not 0, the line adds that PlayRDR2.exe will show its box; if the process has not exited, the line says its code is not known. |
| `app/tests/launcher_end_test.c` | On the PlayRDR2 tree: `Launcher.exe` gets 0, `RockstarErrorHandler.exe` and the launcher's two `SocialClubHelper.exe` get 1067, and `LAUNCHER.exe` gets 0. |
| decisions | 0156; 0125 and 0130 point to it; README row. `docs/ARCHITECTURE.md`, "The launcher's end". |
| `app/artifacts.tsv` | `playport-session.exe`, 45,056 B, `5809fa88…`. It contains no `/home/` path. |

**The exit code 0 is not forced.** With 0, Wine leaves each thread's own code. That code is 0 unless
the thread died of a server protocol error (`server/request.c`, which sets 1). A process's code
cannot be changed after it exits, so the root only confirms it. The confirmation line makes the
rare case visible.

## 3. Host checks

- `./pp build` (dev): passed, IPA above. The first build stopped at `build/cef/stage-payload.py`
  because the copy lacked `.work/cef-src/out-stage-c`. After a reflink of it (0117 lists it), the
  second build passed.
- `./pp test`: all passed, including `C test launcher end: ok`.
- `./pp names`, `./pp secrets`: clean.
- The build also changed the rows of `lib/libdxmt_combined.a` and `lib/libidevice_ffi.a`. 0117 lists
  both as rebuilt from the copy's path, so they keep main's values. Main's build after the move
  confirms the session row: main's `./pp build` reproduced `5809fa88…` and changed no record.
- **Isolation:** `find <main>/.work -path '*/worktrees' -prune -o -newer <marker> -print` lists 7
  entries, all under `.work/gpu-reference/rdr2/`, from another session. None names the copy.

## 4. The phone check

Run in the main checkout, after the move (results in section 5):

1. The Hollow Knight gate: `./pp ui --play app-367520 --until first-frame+10 --shot`. It passes if the
   game shows its first frame.
2. RDR2, past the sign-in end:
   `./pp ui --play app-1174180 --until first-frame+300 --shot`, or the run's launcher mark plus 60 s.

It passes if:
- `[launcher] end ended Launcher.exe pid N (exit code 0)` is in the host log, followed by
  `[launcher] end: Launcher.exe pid N exited with code 0`;
- there is no `[msgbox] … Unable to launch game` line and no `dialog shown` mark;
- the game keeps running after the end;
- the pad drives it without `dialog-ok2.py`.

## 5. Phone results (main, IPA `41431327`)

Phone: 80 %, on external power, 4.0–5.7 GB free before each run; unattended mode on.

**Hollow Knight gate:** `pp install --no-build`, then `pp ui --play app-367520 --until first-frame+10
--shot` in one lock session. First frame at +11.0 s; the screenshot shows the title menu (Start
Game, Options, …). Run directory `.work/ui-runs/20261021T220729`.

**RDR2 Story** with the defaults (`qarm.sh NAME ''`, `RUN_IPA=41431327`, `UNTIL=600`, aspect 16:9,
no stick input). The PlayRDR2 box watcher (`dialog-ok2.py`) ran as a safety net in a no-press mode:
it only logged a box it saw, and it saw none. The landing script started watching at the first
frame (there was no box to close) and pressed A once on the Story tab; it pressed nothing else.

| Run | First frame | Launcher end lines | Box | Landing | Played to | Last screenshot | Peak footprint | Jetsam |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| lb1 (`20261021T220845-rdr2-lb1`) | +82.5 s | sign-in at +104.8 s; `end ended Launcher.exe pid 112 (exit code 0)`, then `end: Launcher.exe pid 112 exited with code 0` | none | two dark screenshots, then the landing with Story already selected (ff +34 s); A at ff +44 s, Story loaded | first frame +600 | the cabin, Arthur on the bed | 7652 MB | none |
| lb2 (`20261021T222231-rdr2-lb2`) | +94.4 s | sign-in at +122.8 s; the same two lines, pid 112 | none | the same: Story selected at ff +39 s; A at ff +52 s | first frame +600 | the cabin, Arthur on the bed | 7253 MB | none |

In both host logs: the launcher's other processes (its three `SocialClubHelper.exe`) ended with
1067, `RDR2.exe` and its `crashpad_handler.exe` were kept, `end done: 4 ended, 2 kept as the game's,
of 7 processes in the job`. No `[msgbox]` line, no "Unable to launch game" text, no `dialog shown`
mark in the run's events, and no box screenshot. The app ran to the end of each run (the watchdog
saw the same app pid throughout), with no crash or `JetsamEvent` report pulled.

**The Story landing without the box press:** the landing shows with the Story tab already selected
(its red underline), about 35–40 s after the first frame, before any press; the only press needed
is A. Before decision 0156 the scripted A on the box came first and the landing followed; now the
landing comes with nothing to dismiss.
