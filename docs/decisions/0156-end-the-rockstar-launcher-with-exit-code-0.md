# 0156: The launcher's end gives Launcher.exe exit code 0, so PlayRDR2 shows no box

**Status:** accepted, 2026-10-21: option (a) of the PlayRDR2 box analysis, approved by the supervisor.
Amends [0125](0125-end-the-whole-rockstar-launcher-at-the-games-first-frame.md) ("PlayRDR2's
dialog is accepted") and [0130](0130-end-the-rockstar-launcher-at-the-games-sign-in-or-near-the-memory-limit.md).
[PLA-413](https://linear.app/playportdev/issue/PLA-413). Not yet shown on the phone.

## Context

- **Why the box appears.** Rockstar's Steam stub `PlayRDR2.exe` starts `Launcher.exe` with
  `ShellExecuteExW`, waits on it with no timeout, and reads its exit code
  (`GetExitCodeProcess`). If the code is not 0, it shows "Unable to launch game, please try
  reinstalling the game." (`MessageBoxIndirectW`, style `0x45030`, caption "Error"). Pressing OK
  takes the same path out as a successful launch. Read from the stub's disassembly.
- **What the end did.** The session root ended every launcher process with
  `TerminateProcess(h, ERROR_PROCESS_ABORTED)`, and Wine's server gives a process the code its
  last thread had. So `PlayRDR2.exe` read 1067 and showed the box.
- **The logs agree.** In the 61 runs of 2026-10-21, each of the 44 RDR2 runs with a
  `[launcher] ending` line had the box, right after `end ended Launcher.exe`. One run had no end
  and no box. The only box without an end followed a launcher crash (`abort_process
  … status=0xc0000005`), before RDR2.exe had started.
- **The box costs something.** Under 0076, while it is up, the game's pads are held at rest and
  a pad A is taken by the box, so it takes the controller away from a running game until the
  player presses OK.
- **On Windows and under Proton** nothing kills the launcher. When a person quits it, it exits
  with 0, and the stub shows nothing.

## Decision

- **`Launcher.exe` ends with exit code 0.** The other processes of the launcher's tree
  (`RockstarErrorHandler.exe`, the launcher's `SocialClubHelper.exe` processes) still end with
  `ERROR_PROCESS_ABORTED` (1067). `pp_launcher_end_code` in `app/SessionRoot/launcher_end.h`
  picks the code by the process's name. This applies to both the end and its "once more" step.
- **The line names the code:** `[launcher] end ended Launcher.exe pid N (exit code 0)`.
- **The exit code is confirmed.** Wine writes a terminate's code into the threads only when it is
  not 0. With 0, each thread keeps its own code, which is 0 unless the thread died of a server
  protocol error during the end (then 1). There is no way to change a code once the process has
  exited. So after the whole step, the root waits up to 1 s for each `Launcher.exe` it ended
  with 0 and logs the code it exited with:
  - `[launcher] end: Launcher.exe pid N exited with code C`;
  - if C is not 0, the line adds that PlayRDR2.exe will show its box;
  - if it has not exited by then, the line says its code is not known.
- **The box stays for a genuine failure.** When the launcher crashes or exits by itself, its
  code is its own, and `PlayRDR2.exe` still shows the box. Only Playport's own deliberate end
  changes.
- **Unchanged:** which processes are ended and in which order, the restarts, the trigger
  (0130, 0140), the game's own Social Club end, dev and release builds alike. No UI, setting,
  environment switch or launch mode (0012).

## Costs and risks

- **PlayRDR2.exe now exits silently** at the end, as on Windows when a person quits the
  launcher. The title's exit code is PlayRDR2's, 0 on both paths, so it does not change.
- **The rare non-zero code.** If a launcher thread dies of a protocol error during the end, the
  code can still be 1 and the box still appears; the confirmation line shows that case.
- **The wait.** The control's reply comes up to 1 s later; the app waits 5 s for it.
- **Other Rockstar stubs.** `PlayGTAV.exe` is likely the same stub. That is not checked, and
  today only RDR2's Play ends the launcher.
