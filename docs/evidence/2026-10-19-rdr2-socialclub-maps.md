# 2026-10-19: RDR2 with the image fallback and the holds limited: socialclub.dll maps and the game starts its Social Club; parking works

**Linear:** PLA-418, PLA-417, PLA-416, PLA-409, PLA-413. **Decisions:** 0128, 0129 (0125–0127).

## Builds and runs

| IPA sha256 | HEAD | Run | What |
| --- | --- | --- | --- |
| `08e92d2b34d685689d05eca7cafc3a7f923c29cbd556af6d943ccb212c285948` | f106a3b | `20261019T182706` | Hollow Knight `--until first-frame+10 --shot`: first frame at +10.13 s |
| same | same | `20261019T182804` | RDR2 `--action set:donorPoolMB=auto --play app-1174180 --until first-frame+600 --wait 1500 --screenshot-after 240 --screenshot-after 600 --shot`, device log kept |

- **The session.** Both runs ran in one `pp phone lock` session. The battery was at 74 % and not
  charging, with 4.7 GB free.
- **The build** has madeira-unix 0170 (decision 0128), 0171 (decision 0129), and 0169 with the
  `__ulock_wait2` parking from 171cc03.

## RDR2, run `20261019T182804`

**Not representative after +240 s.** At +240.3 s someone tapped the box's OK button: the host log
has a touch at (758,390) on the "Error" window. The tooling pressed nothing. The owner then put the
app in the background. The host log shows three times the task was suspended (`[susp] TASK WAS
SUSPENDED/STALLED`, `hostio: main queue has not run`), on the game's clock:

| Suspended | Length |
| --- | --- |
| about +244 s to +280 s (18:32:20–18:32:57) | 36 s |
| about +539 s to +574 s (18:37:16–18:37:51) | 34 s |
| about +611 s to the stop at +705 s (18:38:28–18:40:02) | 93 s |

Only the first 240 s are a clean play.

**What showed:**
- The first frame came at +96.3 s.
- At +98.4 s a box went over the game: PlayRDR2.exe's `MessageBoxIndirectW`, caption "Error",
  text "Unable to launch game, please try reinstalling the game." with OK and Help buttons. This
  is the box 0125 accepts. PlayRDR2 opens it when Launcher.exe ends.
- It is the only message box in the log. The 240 s screenshot shows only that box, on black.
- After the tap, PlayRDR2.exe exited 0. Its `MessageBoxIndirectW` returned 1, IDOK.
- The game kept presenting at about 55 frames a second to the end. The 600 s screenshot, taken
  between the second and third suspensions, shows the game's view as a blue horizontal band on
  black, under the touch controls. The game's Social Club error screen from run
  `20261019T173829` does not show in any screenshot.
- The stop screenshot shows another app: the Playport app was in the background.
- No sign-in was logged.

**socialclub.dll mapped below the ceiling. The 0128 fallback was not needed.**
- RDR2.exe (thread 0428) mapped it at 0x73f97b0000 at about +100 s (log line 124272).
- There is no `[va-ceiling] image` line, and the whole log has one `[va-scan] FAILED` line: RDR2's
  8,960 MB reservation.
- The cage hold is gone: `[cage] no holdback: no cage-hold for this title`.
- The guest window held 10,366 of 15,232 MB at +336 s, with 4,871 MB free. In run
  `20261019T173829` it held 15,143 MB, 8,191 MB of it the cage hold.

**The game's own SocialClubHelper started.** At about +107 s RDR2.exe created
`SocialClubHelper.exe` (pid 0x5a8, `NtCreateUserProcess` at line 127875). It ran to the stop with 45
threads, and the launcher end did not count it as a restart.

**Parking and teardown (0127, 0169):**
- 19 threads were parked (`[proc-end] parked`), and none was refused: there is no `[proc-end] not
  parked` line. In run `20261019T173829` all 22 attempts were refused.
- All four processes the launcher end ended were torn down at about +98 s:

| pid | process | freed (MB) | kept (MB) | finished threads | parked threads |
| --- | --- | --- | --- | --- | --- |
| 0x70 | Launcher.exe | image 68, private 116, L1 154, pool 125 | 867 | 73 | 5 |
| 0x7c | RockstarErrorHandler.exe | image 17, private 6, spans 60, callret 32, L1 16, band 88, pool 31 | 4 | 9 | 0 |
| 0x1b4 | SocialClubHelper.exe, browser | image 301, private 64, L1 94, pool 170 | 1,088 | 37 | 11 |
| 0x284 | SocialClubHelper.exe, renderer | image 284, private 3,052, spans 353, callret 68, L1 36, band 238, pool 152 | 41 | 19 | 0 |

  A process with a parked thread keeps its views in FEX's band (all but the L1 caches) and the
  views the parked registers name. That is most of the "kept" column.
- Two CEF children the launcher killed itself were also torn down earlier:
  - pid 0x2d4 freed about 3.8 GB;
  - pid 0x338 freed about 3.1 GB, kept 733 MB, with 1 parked thread.

**The 8,960 MB hold (0129).** No request took it.
- The runtime held 0x79d0000000 +8,960 MB at boot.
- The three CEF 2 GB pools landed by their hints: 0x7200000000 and 0x7280000000, in the window the
  cage hold used to fill, and 0x7680000000.
- RDR2's 8,960 MB reservation was placed above the ceiling at 0x7420000000 by the usual
  `[va-ceiling]` fallback, before the hold was asked.
- RDR2's 1,175 MB reservation went to 0x7218be0000.
- There is no `[jumbo-hold] keeping` line: no smaller request reached the hold.

**Footprint** (`[xp]` `fpMB`):
- 3,793 MB at the first frame;
- 4,954 MB at +99 s;
- a peak of 6,030 MB at about +160 s;
- about 5,830 MB from +200 s to the stop: `[footprint] … (peak 5983)`.

The limit is 8,192 MB. Run `20261019T173829` sat at 7,090 MB.

**JIT pool (896 MiB):** at the result, head 295 MB (170 live), tail 481 MB (241 live), room 121 MB.
There was no exhaustion and no refusal.

**FEX band:** 6,093 MB peak with 298 threads. 5,498 MB was in use at the stop, with nothing refused.

**Device log.** In `.work/agent-notes/pla418/run1/rdr2/` (private).
- The app was not killed.
- At 18:38:28 runningboardd moved it to `Default Inactive (6144)`, the background limit, and at
  18:40:02 back to `Hard Games_Entitled (8192)`. This confirms the third suspension.
- The JetsamEvent at 18:28:57 lists S1Probe as active and frontmost, not killed; the processes it
  killed were others.

## Follow-ups

- **Run again without backgrounding.** Show what the game does once PlayRDR2's box is gone: its
  Social Club and sign-in, and whether the blue band is a loading screen.
- **The 8,960 MB hold sat unused.** RDR2's reservation now fits above the ceiling without it. The
  hold only takes 8.75 GB of the band.
- **Parked processes keep their band views,** about 2 GB across the launcher's three processes.
