# 0133: A dev build may end RDR2's own Social Club helpers after the game's sign-in

**Status:** accepted, 2026-10-20, as a dev experiment, approved by the supervisor for the owner
(PLA-413); the end waits 120 s or more after the sign-in since
[0141](0141-end-rdr2s-own-social-club-no-sooner-than-120-s-after-its-sign-in.md). Amends [0130](0130-end-the-rockstar-launcher-at-the-games-sign-in-or-near-the-memory-limit.md),
which never ends the game's own `SocialClubHelper.exe`. It is not a compatibility default: it may
become one for RDR2 only after a run shows the game going on without a blocking Social Club error
and without an exit.

## Context

- **The Story load ends at the memory limit.** RDR2's Story load reaches the 8,192 MB limit
  (jetsam `ActiveHard`), also with the game's own Texture Quality at Low. At Low the run reached the
  intro's first title card and was ended there, with graphics at 2,787 MB and about 5.0 GB besides
  (run `20261020T025750-rdr2-low1`).
- **Two levers did not help.** A smaller `totalphys` (6,144) and a smaller video budget (`vram-mb`
  2,048) left the end unchanged.
- **The game's own Social Club stays alive.** It is a CEF pair, `SocialClubHelper.exe` under
  RDR2.exe and its renderer, and it holds about 530 MB resident plus compressed (`[proc-mem]`) at
  the kill. That is the largest single part left that is not the game's own heap or graphics.

## Decision

- **The control.** A new session control, `PP_CONTROL_END_GAME_SOCIAL_CLUB`
  (`session_protocol.h`), makes the session root end the game's own Social Club helpers once.
  - It ends every `SocialClubHelper.exe` in the title's job whose parent chain reaches
    RDR2.exe (`pp_game_social_club`, `launcher_end.h`).
  - It never ends RDR2.exe or any other image.
  - Each process is logged as a `[game-sc]` line.
  - The game starts a new browser about 1 s after the end (runs `20261020T034248-rdr2-sc2`
    and `20261020T035333-rdr2-adv`), and with it the memory comes back. So the first 8 later
    starts of those images are ended once more as the job reports them, and any after that are
    logged and left running. The title's end gives their count.
- **The trigger.** The control is sent once, after the game's `Signed in online to profile`
  line (the trigger of 0130's launcher end, `LauncherEnd`), at the first wait slice whose phys
  footprint is within 0130's 1,200 MB of the limit (6,992 MB at 8,192). Until then the slices
  read the footprint each second.
  - Why not at the sign-in: the game starts its own helper only after it. In run
    `20261020T033304-rdr2-sc1`, the control at the sign-in found none, and the browser started
    1.0 s later, its renderer 4.9 s later.
  - Near the limit is also after the game's start-up use of Social Club: its sign-in and the
    cloud-file step before the Story's world load.
  - The control applies only to a Play whose launcher ends at the sign-in: RDR2.
- **Where it is on.** A dev build's Settings › Developer › End the game's Social Club
  (experiment) turns it on; it is off by default. The UserDefaults key is
  `endGameSocialClubAfterSignIn`, and `pp ui --action set:endGameSocialClubAfterSignIn=true`
  sets it (decision 0012). A release build never sends the control.

## Costs and risks

- **The overlay.** With the game's Social Club browser gone, its overlay (the Home button's
  Social Club pages, sign-in prompts) cannot show.
- **Cloud saves.** Rockstar's cloud-save sync (`cloudsavedata.dat`) may fail or stay behind the
  phone's saves.
- **The game's IPC to Social Club.** The game may wait on the dead helper, show a Social Club
  error, start a new helper (logged as a `[game-sc]` start), or end.
- **Saves are checked.** Before the first run with it on, the save directory
  (`Documents/Rockstar Games/Red Dead Redemption 2/Profiles/…`) is backed up under the build area
  with its hashes. After each run, its files, sizes and times are compared with the backup.

## What the runs showed

See the [evidence](../evidence/2026-10-20-rdr2-story-memory-levers.md), section 3.
- **The end works.** It frees about 480 MB in a second: the footprint went 7,385→6,903 MB in run
  `20261020T035333-rdr2-adv`.
- **The game takes it back.** It starts a new browser within about a second, and the Story load
  goes on growing. Every run still ended at the 8,192 MB limit, 70–100 s after the end.
- **No Social Club error box showed**, and the save slots are unchanged. Whether the game would
  go on without its Social Club is not shown.
- **A known gap:** a restart that the job reports before the process list has it is not named, so
  it is left running (run `20261020T043106-rdr2-sc4`, inference).
- **So the control stays a dev experiment:** no compatibility default.
