# 0059: An Epic game starts signed in: an exchange code and an ownership token enter the guest

**Status:** accepted, 2026-10-07, by the owner's direction ("a game gets from its store
what the store's launcher would give it, by default", in the
[store game sign-in plan](../plans/finished.md#games-sign-in-to-their-store)), step 1. One exception
to [0004](0004-steam-session-boundary.md); replaces [0058](0058-store-sessions.md)'s
refusal of a game that needs Epic's sign-in. The phone measurement is in the
[evidence](../evidence/2026-10-07-epic-game-auth.md).

## Decision

Every Epic game starts as Epic's launcher starts it, signed in: **on by default**, with no
per-game switch. Right after Play the host fetches a fresh **exchange code** and, for a game
whose catalogue sets `OwnershipToken=true`, an **ownership token**, and puts them where the
launcher does:

    -AUTH_LOGIN=unused -AUTH_PASSWORD=<exchange code> -AUTH_TYPE=exchangecode
    -epicusername=<display name> -epicuserid=<account ID> -epicsandboxid=<namespace>
    -epicovt=C:\Games\<folder>\playport-epic.ovt

beside the arguments the game always had (`-epicapp`, `-epicenv=Prod`, `-EpicPortal`,
`-epiclocale`). A build whose Live asset sidecar names an EOS deployment also gets
`-epicdeploymentid=<32 hex>` (PLA-61): a public build identity, not a player identity or
credential. It is kept at install and refreshed by the page's existing asset/update check,
including sidecar-only changes and removal; it passes online and offline, without a new
Play-time request. Nothing else from the host session crosses: not the `eg1` refresh or
access token, not a CDN token.

A game whose catalogue sets `OwnershipToken` or `CanRunOffline=false` is no longer refused.
Refusals stay for anti-cheat (EasyAntiCheat or BattlEye files; Epic's access control;
Marvel Rivals) and for another company's launcher (Ubisoft Connect by the catalogue;
Elite Dangerous, Frontier's; Star Trek Online, Cryptic's), each with its own message.

**When the sign-in cannot be had** (offline, Epic signed out, Epic refusing), the game does
not start signed out by itself. The page says Epic could not sign the game in, with Try
again and Cancel. A game whose catalogue allows offline play and asks for no ownership
token also gets **Play offline**: it starts with the arguments it had before this record,
and the log says it plays offline by the player's choice (owner, 2026-10-07).

0004 asks five things of a record like this one. This one meets four and narrows the fifth.

## The secrets

- **The exchange code.** `GET /account/api/oauth/exchange` on Epic's account service with
  the host's access token answers `{"expiresInSeconds": 299, "code": <32 hex digits>,
  "creatingClientId": <the launcher's client>}` (measured from the workstation,
  2026-10-07). It is one-time and lasts five minutes.
  - **Who uses it.** The game's EOS SDK trades it, with the game's own EOS client identity,
    for the game's own session: achievements, friends, online play, the publisher's account.
  - **What a thief could do.** Any Epic client can redeem it, once, within five minutes.
    Redeemed by a thief first, it gives a session on the account as that client (and the
    game then fails its sign-in).
  - **What bounds it.** Its five minutes, its single use, and the game redeeming it as it
    starts, seconds after Play.
- **The ownership token.** `POST …/ecommerceintegration/api/public/platforms/EPIC/identities/<account
  ID>/ownershipToken` with `nsCatalogItemId=<namespace>:<catalog item ID>` answers
  `{"token": "egoc1~<JWT>"}`: an RS512-signed token naming the account, the client, the
  entitlements of that item and the caller's IP, with `exp − iat` = 300 s (measured).
  - **Who uses it.** The game checks with Epic that the account owns it.
  - **What a thief could do.** Show, for five minutes, that this account owns this item.
    It gives no session.
- **The account ID and display name.** Not credentials, but they identify the player, so
  they are kept out of logs like the rest.

## Threat model

Everything runs in one process (0004). Guest code can read the code from the command line
before the game redeems it: the process's `PEB`, Wine's process list, and the session's
request file (below) while it exists. So can any mod or DLL the game loads. The ownership
token can be read from its file or the game's memory. The residual is 0004's, narrowed to a
five-minute single-use code and a five-minute proof of ownership for each play.

## The one channel

- **The command line** the session root gives the game. On its way there it passes once
  through the session's request file (`AppData\Local\Playport\session\request` in the
  prefix, mode 0600), which the session root reads and deletes before it starts the game.
- **The ownership token's file**, `playport-epic.ovt` in the game's own folder under
  `C:\Games`, named by `-epicovt`, mode 0600. It holds Epic's reply as it came,
  `{"token":"egoc1~…"}`, as Epic's launcher writes it, not the bare token: a game's DRM
  reads the JSON (Jurassic World Evolution's refused the bare token with its error
  88500000; corrected 2026-10-07, [evidence](../evidence/2026-10-07-url-opener.md)).
- **Fetched** right after Play (`LibraryModel.play`, `EpicAccount.launchSignIn`): the account,
  the ownership token if the catalogue asks for it, then the code last, each call with a
  10 s limit and one retry. Never kept on the host: not in the Keychain, not in a file.
- **Written** by the launch (`LaunchCoordinator`, `EpicOwnershipFile.write`) before the
  runtime starts, after removing one a crash left.
- **Removed** (`EpicOwnershipFile.remove`): when the launch ends; at the next launch; at the
  next app start, from every installed Epic game (a crash, a kill or the restart after a
  game can leave it); at sign-out. A code is never on disk after the session root starts
  the game.
- **Logs** never print them: the launch logs the arguments with `-AUTH_PASSWORD=`,
  `-epicuserid=` and `-epicusername=` redacted (Swift, and the C side's `argv` lines), the
  token's size and where it went. `Redactor` scrubs those arguments and any `egoc1~` token
  from every line; `pp secrets` fails a committed code argument or ownership token.

## Where it is in the guest

- The game's process: its command line (the `PEB`), and whatever the game does with it.
  An EOS game hands the code to `EOS_Auth_Login` with the exchange-code credential type.
- The `.ovt` file while the game runs.
- **Measured on the phone** ([evidence](../evidence/2026-10-07-epic-game-auth.md)): after
  Snakebird Complete, Jurassic World Evolution and Death's Door, every file in the app's
  container modified since the play began was searched for the code (by pattern), the
  account ID and the ownership token: none held them. The first build found the code in the
  app log, printed by the runtime's process-creation line; madeira-unix 0086 masks it there.

## What 0004 asks, and what this does

| 0004 asks | Here |
| --- | --- |
| a threat model for the secret | above |
| a single channel | the command line (through the request file the session root deletes), and the `.ovt` file while the game runs |
| measured guest-side storage | on the phone, after each Epic play (the evidence) |
| logout removes every copy | sign-out removes every `.ovt` file; the code is spent or expired within five minutes; the host keeps neither |
| revocation also invalidates what the guest received | **narrowed.** Sign-out ends the host's session at Epic (0058); the game's own session, made from the code, is Epic's to end, not Playport's. Accepted: the code and the ownership token last five minutes, and what the game makes of them is what Epic's launcher would have let it make. |

## Also

- **Offline play** is the player's choice, per launch, for a game that allows it; the
  Play offline row is not shown for a game with an ownership token or `CanRunOffline=false`.
- **Fortnite-style access control** stays refused with the anti-cheat message.
- An exchange code is fetched with the launcher's identity and redeemed by the game's own
  EOS client, as with Epic's launcher. The phone has not shown Epic accepting one yet: the
  EOS games tried could not reach Epic (the guest's TLS roots) or did not start (the
  evidence). If Epic ever ties codes to a client, the sign-in fails, not the play offline.
