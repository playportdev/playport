# 0141: A dev build ends RDR2's own Social Club no sooner than 120 s after its sign-in

**Status:** accepted, 2026-10-20, as the supervisor's direction for the owner (PLA-413): the
end and the refusal wait for the game's own sign-in. Amends
[0133](0133-a-dev-build-may-end-rdr2s-own-social-club-after-its-sign-in.md). Dev only, like 0133.

## Context

- **0133's end comes at the first one-second slice after the sign-in whose footprint is within
  1,200 MB of the limit.** In s5, s6 and e3b that was 144–155 s after the sign-in, and the game
  went on into Story.
- **In run `20261020T143924-rdr2-f2` the footprint was already over it at the sign-in** (7,018 MB
  at +113.5 s): the root ended the game's helper 1.2 s after its Social Club log said it had signed
  in online. The helper's channels broke, its log went to `FAILED` and `Signed out.`, 0138 refused
  the game's two later helper starts, and the game stayed on a black loading screen for 8 minutes
  until the run was ended.

## Decision

- **The end waits at least 120 s after the sign-in line** (`LauncherEndTrigger.gameSocialClubAfterSignInS`),
  then comes at the first slice within 1,200 MB of the limit, as before.
- 0138's refusal is unchanged: it refuses only the game's helper starts after the first, so the
  helper that signs in always runs; with the end held back it lives through the sign-in's aftermath.

## Costs and risks

The game's helper pair (about 550 MB) stays for those 120 s. A footprint that reaches the limit in
that window is a kill: the launcher's end (0140) has already freed its memory by then.
