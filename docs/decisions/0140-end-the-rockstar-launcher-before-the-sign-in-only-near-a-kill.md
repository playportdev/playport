# 0140: Before RDR2's sign-in, the launcher ends for memory only 400 MB below the limit

**Status:** accepted, 2026-10-20, approved by the supervisor for the owner (PLA-413, PLA-364).
Amends [0130](0130-end-the-rockstar-launcher-at-the-games-sign-in-or-near-the-memory-limit.md)
(the end before the sign-in at the limit less 1,200 MB). Dev and release alike.

## Context

- **0130 ends the launcher's tree at the game's sign-in, or earlier at the limit less 1,200 MB**,
  so its memory is freed before iOS ends the app.
- **An early end leaves the game signed out.** In runs `20261020T125218-rdr2-s4` and
  `20261020T142311-rdr2-f1` the footprint reached 7,027 and 7,020 MB of the 8,192 MB limit 16–19 s
  before the game's sign-in line, the app ended the launcher and its Social Club helpers, and the
  game showed "Not signed in" (s4: the Story tab offered to buy the game). In s5 and s6, which
  signed in, the footprint at the sign-in was 5.5–5.6 GB and the memory end never fired.
- **f1 ran about 1.3 GB higher than s6 before the sign-in** (internal memory; graphics alike),
  with the same game settings. Why is open.
- **After f1's end the footprint fell to 6.2 GB and peaked at 6.98 GB** until the sign-in: in
  that run the launcher could have stayed.

## Decision

- **Before the sign-in the memory end comes at the limit less 400 MB** (7,792 MB of 8,192 MB;
  `LauncherEndTrigger.beforeSignInHeadroomMB`). Its log line gives the footprint, and a second line
  the reason (iOS would end the app; the game may then not sign in).
- **The sign-in trigger is unchanged**, and so is the dev end of the game's own Social Club after
  the sign-in (0133, still at the limit less 1,200 MB).

## Not chosen

- **No memory end before the sign-in at all:** a footprint burst before the sign-in (up to
  1.2 GB in 1–2 s, 0130's context) would be an 8 GB kill of the whole app.
- **Keep 0130's 1,200 MB and only stop a run that shows "Not signed in":** whether a run signs in
  would depend on how high that run's footprint happens to go.

## Costs and risks

0130 chose 1,200 MB to cover one burst between two one-second readings; 400 MB does not. A burst
in the last 400 MB before the sign-in is a kill instead of a signed-out game.
