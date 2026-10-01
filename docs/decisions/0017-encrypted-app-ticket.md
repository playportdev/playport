# 0017: An encrypted app ticket may enter the guest, per game

**Status:** proposed, 2026-09-28. Not accepted. Until it is, no ticket
enters the guest and [0004](0004-steam-session-boundary.md) holds unchanged.

## Decision (proposed)

One exception to 0004, for one secret: Steam's **encrypted app ticket** for
the game being launched. The player turns it on for one game on that game's
page ("Prove ownership to the game's servers"); it is off by default.
When it is on, the launch fetches a fresh ticket on the host and gives it to
the Steam API emulator through one file, which is deleted when the game
exits. Nothing else from the host session crosses: not the refresh or access
token, not the account name, not a CDN or depot key.

0004 asks five things of a record like this one. This one meets four and
asks to narrow the fifth.

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
other DLL it loads, and anything that reads the prefix while the file exists.
The residual risk is 0004's, narrowed to one game's servers and one
ticket's lifetime.

## The one channel

- **Where.** The line `ticket=<base64>` in the game's
  `steam_settings/configs.user.ini`, beside the emulator's DLL. That folder is
  Playport's own (SteamAPISwap marks it).
- **Written** by the launch (`LaunchCoordinator`) after the ticket is
  fetched, and before the runtime starts.
- **Removed:**
  - when the game exits (the same thread, no network needed);
  - at the next launch and at the next app start, when a crash or a kill left
    it behind;
  - at sign-out, from every installed game.
- **Fetched** right after Play, before the session closes for the launch
  (0004's suspension), with a 5 s limit. If the fetch fails, the game starts
  without a ticket. It is never kept on the host: not in the Keychain, and not
  in the service's files.

## Where it is in the guest (from gbe_fork's source at the gbe pin)

- `settings_parser.cpp` `parse_encrypted_app_ticket` reads the line once at
  startup, into the client and server settings: two copies in process memory.
- `steam_user.cpp` `GetEncryptedAppTicket` copies it into the game's buffer.
  From there it is the game's, which sends it to its servers.
- gbe_fork writes it nowhere: the parser only reads it, and its debug prints
  are not in the release build.
- **To measure on the phone before this record is accepted:** after a play
  with a ticket, search the whole prefix and the app container for the base64
  and for the raw bytes. Only the ini line may hold them, and only while the
  game runs.

## What 0004 asks, and what this does

| 0004 asks | Here |
| --- | --- |
| a threat model for the secret | above |
| a single channel | the ini line, written at launch, removed at exit |
| measured guest-side storage | from the source; the phone measurement is still to do |
| logout removes every copy | sign-out removes every ini line; the host keeps none |
| revocation also invalidates what the guest received | **not possible.** Playport cannot revoke a Steam ticket, and revoking the refresh token does not invalidate one already issued. The proposal is to accept this for this secret alone, because the ticket gives no Steam account access and lasts a bounded time. |

## Also

- **What games are affected.** A game that asks Steam to include data in the
  ticket (a server nonce) gets a ticket without it, because it was fetched
  before the game ran. Its servers will refuse it. The emulator already
  ignores that data.
- **Scope.** A game with the switch off gets gbe_fork's own made-up ticket,
  as it does today. No cohort title needs a real one, so there is no test
  title yet: the plan's "done when" needs a game whose online login checks
  the ticket.

## If accepted

- Implement phase 5 as above (docs/plans/2026-09-27-steam-for-games.md).
- Measure the guest-side storage on the phone, and record it in
  `docs/evidence/` before the switch ships in a release build.
- Amend 0004's "How the host side is kept" to point here.
