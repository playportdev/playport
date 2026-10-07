# Steam encrypted app ticket on the phone (decision 0017)

**Date:** 2026-10-07. **Plan:** [store game sign-in](../plans/finished.md#games-sign-in-to-their-store),
step 2. **Decisions:** [0017](../decisions/0017-encrypted-app-ticket.md) (accepted),
[0004](../decisions/0004-steam-session-boundary.md).
**Phone:** iPhone18,4, iOS 27.0, dev build, Steam signed in (the paired account). Driven
with `pp ui`, each sequence in one `pp phone lock` session.

**IPA:** `Playport-26.5-6b253ef0.ipa`, sha256
`6b253ef092603f34aee1c864e0ae6f637913b13507270d976f0e54ed72afcf33`, built from `bd490ac`
(clean). An earlier build, `9c692252…` from `e65f3f0`, is the first Hollow Knight play
below.

## What was run

| Run (`.work/ui-runs/`) | IPA | What | Result |
| --- | --- | --- | --- |
| `20261007T111332` | 9c692252 | Hollow Knight, `--until first-frame+10 --shot` | first frame +10.80 s; no ticket: Steam answered `EResult Fail` |
| `20261007T112156` | 6b253ef0 | the same, with the session in the game for the call | first frame +10.00 s, title menu on screen; no ticket: `EResult Fail` again |
| `20261007T112830` | 6b253ef0 | Among Us (945360), `--until first-frame+10 --shot` | ticket fetched, written, removed at exit; the game ended at 17 s (below) |
| `20261007T113217`, `…113322` | 6b253ef0 | Among Us again to `mark:game started+2`, then a kill and a start | the line went 21.9 s after it was written, before the kill: the launch's removal at the game's end (the next start found none) |
| `20261007T113616` | 6b253ef0 | a made-up ticket line put in Hollow Knight's `configs.user.ini` over AFC, the app killed, then started (`open:settings`) | removed at app start |

## The fetch and the line

Steam's log (`Documents/steam-drive.log`, redacted, the `[ticket]` lines):

    WARN [ticket] app 367520: no encrypted app ticket: ClientRequestEncryptedAppTicket 367520: EResult Fail
    INFO [ticket] app 945360: encrypted app ticket fetched, 143 bytes in 0.22 s

The app log (`pull/s1-host.log`) of the Among Us play:

    library: ticket: 0 removed at app start (4 Steam game(s) checked)
    title: steamapi: emulated: emulated (persona set, steamid set, 0 DLC)
    title: ticket: the encrypted app ticket (143 bytes) written to 1 configs.user.ini
    title: +16.08 s first frame
    title: ticket: removed from 1 configs.user.ini at exit
    title: done nonce=938d7375 exit=0xc000001d after_s=17

and of the Hollow Knight plays: `title: ticket: none; the emulator makes up its own`.

- **Hollow Knight gets no ticket.** Steam answers the request with `Fail`, both with the session
  in no game (`e65f3f0`) and in the game (`bd490ac`). Among Us, on the same session a minute
  later, gets one. So Steam issues tickets only for an app its publisher set up for them, and
  Hollow Knight is not one (an inference: Steam gives no reason). Hollow Knight plays as before.
- **Whether the session must be in the game** is not settled: Among Us was only tried with it
  in the game (`ClientGamesPlayed` for the call, then none). That is the state Steam's own client
  is in when a running game asks, so it stays.
- **The fetch costs** 0.22 s at Play, before the session closes.
- **The line.** A watcher reading the ini over AFC saw `ticket=` with 192 base64 characters
  (143 bytes) in `[user::general]` of `Among Us_Data/Plugins/x86_64/steam_settings/configs.user.ini`
  while the game ran, and saw it gone 18.6 s later, at the game's exit.
- **Removal at app start.** A made-up line (not a ticket) put into Hollow Knight's
  `configs.user.ini`, then a kill and a start: `library: ticket: 1 removed at app start (4 Steam
  game(s) checked)`, and the file is the emulator's settings again. Removal at sign-out is
  covered by the host tests only: signing out on the phone would end the paired session, which
  the owner pairs again.
- **Among Us ended at 17 s** (`0xc000001d`): an unhandled fault in CoreFoundation
  (`CFNumberGetValue`) on a game thread, after its EOS client had failed TLS to
  `api.epicgames.dev` (`unknown CA`), before any sign-in that could use the ticket. Nothing points
  at the ticket; the game had not been played on the phone before. It is a runtime issue for its
  own work.

## 0017's measurement: where the ticket is after a play

A scratch script (under `.work`, not committed) held the ticket in memory only: read from the ini
line over AFC (house arrest on the dev app's container, as `tools/afc.py` uses) while the game
ran, never printed or written. After the play it walked the whole container and read every file
modified since 120 s before the line was written (a file older than that cannot hold a ticket
that did not exist), searching each for the base64, its first 40 characters, the raw 143 bytes
and a 32-byte slice of them.

| After | Files walked | Bytes walked | Files read (modified since) | Hits |
| --- | --- | --- | --- | --- |
| the Among Us play that exited (`112830`) | 12,159 | 72.7 GB | 49 (35.7 MB) | **0** |
| the second Among Us play (`113217`) | 12,160 | 72.7 GB | 29 (5.6 MB) | **0** |

The files read include the game's `configs.user.ini` (after the removal), the prefix's registry
(`system.reg`, `user.reg`, `userdef.reg`), the game's own folder under `AppData/LocalLow`
(`Player.log`, its crash reporter's envelope and breadcrumbs, its settings), the DXVK and Mesa
shader caches, the app log, Steam's log, `run-events.jsonl` and the Steam service's state files
under `Library/Application Support/Playport/steam/` (cloud and stats records, the games list).
None holds the ticket. Not reachable over AFC: `SystemData` and the container's metadata plist
(iOS's, not the app's). Not measured: process memory (gbe_fork's two copies, the game's buffer),
and a file written and deleted during the play.

**Result:** after a play only the ini line held the ticket, and only while the game ran. No copy
outside it, so 0017 needs no per-game switch.
