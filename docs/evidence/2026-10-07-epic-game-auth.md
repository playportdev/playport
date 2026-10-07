# Epic games start signed in, on the phone (decision 0059)

**Date:** 2026-10-07. **Plan:** [store game sign-in](../plans/finished.md#games-sign-in-to-their-store),
step 1. **Decisions:** [0059](../decisions/0059-epic-exchange-code.md) (accepted),
[0004](../decisions/0004-steam-session-boundary.md), [0058](../decisions/0058-store-sessions.md).
**Phone:** iPhone18,4, iOS 27.0, dev build, Epic and Steam signed in. Driven with `pp ui`,
each sequence in one `pp phone lock` session.

**IPA:** `Playport-26.5-86208e93.ipa`, sha256
`86208e931554de7757dbdab2a0b8750874fe87ae336822765fa7b7f02546b0b2`, built from `c970646`
(clean). An earlier build, `e5e51be7…` from `5d559c3`, is the first Snakebird play below;
it found the two faults `c970646` fixes.

## The workstation check (before the phone)

With the workstation's Epic session (the launcher identity, read-only; nothing printed or
kept):

- `GET /account/api/oauth/exchange`: HTTP 200, `{"expiresInSeconds": 299, "code": <32 hex
  digits>, "creatingClientId": <the launcher's client ID>}`. The code was not redeemed.
- `POST …/ownershipToken` for Football Manager 2022 Resource Archiver and Jurassic World
  Evolution: HTTP 200, `{"token": …}`, 840 characters, `egoc1~` and an RS512 JWT whose
  claims are `clid`, `ent`, `exp`, `iat`, `ip`, `jti`, `sub`, with `exp − iat` = 300 s.
- `GET /account/api/oauth/verify` names the account `account_id` and `display_name`; the
  token reply names it `displayName`.

## What was run

| Run (`.work/ui-runs/`) | IPA | What | Result |
| --- | --- | --- | --- |
| `20261007T115736` | e5e51be7 | install Snakebird Complete (319 MB) | installed |
| `20261007T115807` | e5e51be7 | Snakebird Complete, `--until first-frame+10 --shot` | code fetched in 0.55 s, first frame +5.78 s; but `-epicusername=` empty, and the runtime's `NtCreateUserProcess` line printed the code into the log (both fixed in `c970646`) |
| `20261007T120656` | 86208e93 | Snakebird Complete again | code fetched in 0.55 s, first frame +5.86 s, the game's title screen |
| `20261007T120900` | 86208e93 | install Football Manager 2022 Resource Archiver (Epic's JSON manifest), verify | 11 files, 37 542 307 bytes (16 030 123 downloaded) in 3 s; verify 11/11 OK against Epic's manifest |
| `20261007T120953` | 86208e93 | install Jurassic World Evolution | 2983 files, 8 040 963 792 bytes (7 733 184 058 downloaded) in 134 s |
| `20261007T121242` | 86208e93 | Jurassic World Evolution, `--until first-frame+90 --shot` | code and ownership token fetched in 0.88 s, the token file written and removed at exit; the game did not start (`0xc0000018`, below) |
| `20261007T121935` | 86208e93 | Death's Door, `--until first-frame+10 --shot` | code fetched in 0.41 s, first frame +4.30 s, title menu on screen |
| `20261007T122211` | 86208e93 | Hollow Knight, `--until first-frame+10 --shot` | first frame +9.78 s, title menu on screen; no Epic or Steam ticket, as before |

## The launch

The app log (`s1-host.log`) for Jurassic World Evolution, the arguments redacted by the app:

    library: epic: Jurassic World Evolution signed in for the launch: exchange code fetched, with an ownership token in 0.88 s
    title: in-app start Games\JurassicWorldEvolution\JWE.exe -epicapp=373a4372c20540aca7fdd880d27fa49a -epicenv=Prod -EpicPortal -epiclocale=en -AUTH_LOGIN=unused -AUTH_PASSWORD=<redacted> -AUTH_TYPE=exchangecode -epicusername=<redacted> -epicuserid=<redacted> -epicsandboxid=047392e91d5e4cfdb19e2767440ab206 -epicovt=C:\Games\JurassicWorldEvolution\playport-epic.ovt
    title: epic: the ownership token (840 bytes) written to playport-epic.ovt
    title: epic: ownership token file removed (1) at exit

The runtime's own lines, after madeira-unix 0086, mask the same values:

    err:process:NtCreateUserProcess … \"-AUTH_PASSWORD=********************************\" \"-AUTH_TYPE=exchangecode\" \"-epicusername=*********…

At each app start: `library: epic: 0 ownership token file(s) removed at app start (4 Epic
game(s) checked)`.

## Where the secrets went (0059's measurement)

A scratch script, run beside each play in the same session (house arrest over AFC, as for
0017), read the ownership token from `playport-epic.ovt` while the game ran (memory only),
checked its `sub` claim is the signed-in account, and after the play walked the whole
container and read every file modified since the play began. It searched each for the
account ID (ASCII and UTF-16LE), the ownership token (whole, and its JWT's first 40
characters), and by pattern for an exchange-code argument (`AUTH_PASSWORD=` and 32 hex
digits, ASCII and UTF-16LE) or any `egoc1~` token. It printed paths and needle names only.

| After | Files walked | Bytes walked | Files read | Hits |
| --- | --- | --- | --- | --- |
| Snakebird, IPA e5e51be7 | 12 576 | 73.1 GB | 444 (347 MB, the fresh install with it) | 2: `Documents/s1-host.log` (the code argument, from the runtime's `NtCreateUserProcess` line), and `EOSSDK-Win64-Shipping.dll` (the SDK's own `egoc1~` string, not a token) |
| Snakebird, IPA 86208e93 | 12 581 | 73.1 GB | 27 (22 MB) | 0 |
| Jurassic World Evolution | 15 581 | 81.1 GB | 2 583 (6.2 GB, the fresh install with it) | 0 |
| Death's Door | 15 590 | 81.1 GB | 26 (5.3 MB) | 0 |

- The ownership token file was seen 840 characters long, `egoc1~`, `sub` the signed-in
  account, and gone 5.1 s later, when the game ended.
- The files read include the registry, the games' logs (Snakebird's `Player.log`), the app
  and Steam logs, the catalogue and the session files.
- Not reachable over AFC: `SystemData` and the container's metadata plist. Not measured:
  process memory, and files written and deleted during a play.
- The log copy from the first Snakebird play was rotated off the phone by the next runs;
  the workstation's pulled copy had the spent code scrubbed.

Result: with `c970646`, no copy of the code, the account ID or the ownership token outside
the command line and the token file, and the file only while the game runs.

## What the games made of it

None of them shows an Epic sign-in yet, for reasons outside this step:

- **Snakebird Complete** signs in to EOS through Unity's web stack, which refuses Epic's
  certificate: its `Player.log` says `Curl error 60: Cert verify failed. Certificate is not
  correctly signed by a trusted CA. UnityTls error code: 7`, then `Tried to login auth:
  NoConnection`. The game plays signed out. The guest's trusted roots are the runtime's
  matter (Among Us's EOS client failed the same way, PLA-39).
- **Jurassic World Evolution** ends at once with `0xc0000018`: its 442 MB executable has no
  relocations and its preferred base `0x140000000` is refused (`ml985: preferred base
  0x140000000+0x1a5c5000 REFUSED status=0xc0000018`), so `wine: failed to create main module`.
  Its sign-in had been fetched and the token file written; the failure is the runtime's
  image placement.
- **Death's Door** has no EOS SDK: it starts with the code and plays as before.

So whether Epic accepts a code fetched by the launcher identity for a game's own EOS client
is not yet shown on the phone. The workstation shows the code's shape and that it is the
launcher's; the EOS sign-in waits for the guest's TLS roots.

## Not checked on the phone

- **The sign-in failure page** (Try again, Play offline, Cancel): it needs Epic signed out or
  the phone offline, which only the owner can arrange; the choice between the rows is host
  tested (`testRefusalsFromTheCatalogue`: `mayPlayOffline`).
- **Sign-out removal**: host tests only, as for 0017 (signing out of Epic ends the session).
- The refusals' messages (anti-cheat, Ubisoft Connect, Frontier, Cryptic): host tests.
