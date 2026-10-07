# 0017: An encrypted app ticket enters the guest, for every Steam game

**Status:** accepted, 2026-10-06, by the owner ("a game gets from its store what
the store's launcher would give it, by default", in the
[store game sign-in plan](../plans/2026-10-06-store-game-auth.md)), step 2. Proposed
2026-09-28 as a per-game switch, off by default; the owner's direction replaces
the switch. One exception to [0004](0004-steam-session-boundary.md). The phone
measurement is in the [evidence](../evidence/2026-10-07-steam-encrypted-app-ticket.md).

## Decision

One exception to 0004, for one secret: Steam's **encrypted app ticket** for
the game being launched. It is **on by default for every Steam game** that runs
with the Steam API emulator (gbe_fork), as Steam's own client gives it to every
game that asks. There is no per-game switch: the review keeps one only if the
phone measurement finds a copy outside the ini line. The launch fetches a fresh
ticket on the host and gives it to the emulator through one file line, which is
removed when the game exits. Nothing else from the host session crosses: not
the refresh or access token, not the account name, not a CDN or depot key.

0004 asks five things of a record like this one. This one meets four and
narrows the fifth.

## The secret

- **What it is.** Steam issues the ticket on `ClientRequestEncryptedAppTicket`
  (EMsg 5526; the reply, 5527, carries an `EncryptedAppTicket` message). It
  is encrypted with the game publisher's key, so Playport cannot read it.
  Inside are:
  - the app ID and the account's SteamID64;
  - the issue time;
  - the account's ownership of the app and its DLC;
  - any data the game asked to include.
- **Who uses it.** A game sends it to its publisher's servers, which decrypt it
  to confirm who is playing and that they own the game. Examples are online
  accounts, cross-play logins, and anti-piracy checks.
- **What a thief could do.** Present it to that one game's servers, as this
  player, until those servers stop accepting it. That could mean signing into
  the game's online account and its progress, purchases or friends there.
- **What a thief could not do.** Sign into Steam or act on the Steam
  account. The ticket cannot be turned into a session or another app's ticket.
- **How long it lasts.** Steam sets the issue time; each publisher's servers
  decide how old a ticket they accept. Playport cannot read either, so the
  lifetime is unknown and assumed to be hours to days.

## Threat model

Everything runs in one process (0004). So anything in the guest can read the
ticket while the game runs: the game itself (which is meant to), any mod or
other DLL it loads, and anything that reads the prefix while the line exists.
The residual risk is 0004's, narrowed to one game's servers and one
ticket's lifetime. With the ticket on for every game, the exposure is every
Steam game the player runs, each to its own servers only.

## The one channel

- **Where.** The line `ticket=<base64>` in `[user::general]` of the game's
  `steam_settings/configs.user.ini`, beside the emulator's DLL. That folder is
  Playport's own (SteamAPISwap marks it). The base64 is of the bytes Steam
  returns as the reply's `encrypted_app_ticket` (the serialised
  `EncryptedAppTicket` message), which is what a game's `GetEncryptedAppTicket`
  gets from Steam's own client.
- **Fetched** right after Play (`LibraryModel.play`, `SteamService.encryptedAppTicket`),
  before the session closes for the launch (0004's suspension), on a session
  already logged on, with a 5 s limit. Steam answers `Fail` unless the session
  is in the game (`ClientGamesPlayed`), as Steam's client is when a running game
  asks, so the session is in it for the call and then in none. No restore is started for it: one could
  outlive the limit and race the suspension. If there is no such session, or
  the fetch fails or times out, the game starts without a ticket and the
  emulator makes up its own, as before. It is never kept on the host: not in the
  Keychain, and not in the service's files.
- **Written** by the launch (`LaunchCoordinator`, `SteamAPISwap.writeTicket`)
  after the emulator's settings, and before the runtime starts.
- **Removed** (`SteamAPISwap.removeTickets`):
  - when the launch ends (the same thread, no network needed);
  - at the next launch and at the next app start, when a crash, a kill or the
    restart after a game left it behind (a Play waits for the start's sweep);
  - at sign-out, from every installed Steam game.
- **Logs** never print it: the launch logs its size and where it went, and
  `Redactor` scrubs a `ticket=` value from any line that reaches a log. `pp secrets`
  fails a committed line that looks like a real one.

## Where it is in the guest (from gbe_fork's source at the gbe pin)

- `settings_parser.cpp` `parse_encrypted_app_ticket` reads the line once at
  startup, into the client and server settings: two copies in process memory.
- `steam_user.cpp` `GetEncryptedAppTicket` copies it into the game's buffer.
  From there it is the game's, which sends it to its servers.
- gbe_fork writes it nowhere: the parser only reads it, `save_global_ini_value`
  writes only the global settings folder's files (never the ticket key), and its
  debug prints are not in the release build.
- **Measured on the phone** ([evidence](../evidence/2026-10-07-steam-encrypted-app-ticket.md)):
  after two plays of Among Us with a ticket, every file in the app's container
  (prefix included) modified since the ticket was written was searched for the
  base64 and the raw bytes: none held them. Only the ini line held the ticket,
  and only while the game ran. Steam gives Hollow Knight no ticket (`Fail`): an
  app has one only when its publisher set it up.

## What 0004 asks, and what this does

| 0004 asks | Here |
| --- | --- |
| a threat model for the secret | above |
| a single channel | the ini line, written at launch, removed at exit |
| measured guest-side storage | from the source, and on the phone: only the ini line, only while the game runs |
| logout removes every copy | sign-out removes every ini line; the host keeps none |
| revocation also invalidates what the guest received | **not possible.** Playport cannot revoke a Steam ticket, and revoking the refresh token does not invalidate one already issued. This is accepted for this secret alone, because the ticket gives no Steam account access and lasts a bounded time. |

## Also

- **What games are affected.** A game that asks Steam to include data in the
  ticket (a server nonce) gets a ticket without it, because it was fetched
  before the game ran. Its servers will refuse it. The emulator already
  ignores that data.
- **The game's own steam_api** (the dev build's per-game choice) gets no ticket:
  it needs a running Steam client, which Playport does not have.
- **No test title yet** checks the ticket online; the plan's step 5 needs one,
  from its survey (step 0). Hollow Knight shows the channel and that it costs
  the launch nothing.
