# 0062: A live Steam session during play: the game's auth session and web API tickets

**Status:** accepted, 2026-10-07, by the owner's answers to step 4 of the
[store game sign-in plan](../plans/finished.md#games-sign-in-to-their-store) (reconnect on demand,
`ClientGamesPlayed` for the play, the WoW64 branch where cheap, on by default with no
switch; an encrypted ticket with the game's data out of scope). One exception to
[0004](0004-steam-session-boundary.md), and a change to its suspension rule. The phone
measurement is in the [evidence](../evidence/2026-10-07-steam-live-session.md).

## Decision

During a Steam game's play the host keeps its logged-on CM connection up, for one use:
making the game's **auth session tickets** (`GetAuthSessionTicket`) and **web API
tickets** (`GetAuthTicketForWebApi`) as Steam's own client does. It is **on by default
for every Steam game** that runs with the Steam API emulator, with no per-game switch.
Every other Steam call stays refused while the game runs (0004's suspension): no
installs, PICS, profiles, stats, Cloud or sign-in.

What crosses into the guest is a ticket's bytes, a handle and a state. Not the refresh or
access token, not a game connect token by itself, not the SteamID, not another app's
ticket.

## How

- **At Play** (`LibraryModel.play`, after the encrypted app ticket of
  [0017](0017-encrypted-app-ticket.md)), on a session already logged on and within 5 s:
  `SteamService.prepareTicketSession` fetches the app's **ownership ticket**
  (`ClientGetAppOwnershipTicket`), checks Steam has pushed **game connect tokens**
  (`ClientGameConnectTokens`, kept in memory, at most Steam's `max_tokens_to_keep`,
  cleared at disconnect), sends `ClientGamesPlayed` with the app (the session is in the
  game for the play), and arms a `SteamTicketBroker`. Failing any of that, the game runs
  with the emulator's made-up tickets, as before.
- **Suspension** (`suspendForLaunch`) then leaves the CM connection logged on, with its
  heartbeat and receive tasks at utility priority, and refuses everything else.
- **The channel** is one Wine unix call table, `playport_steam_unix_call_funcs`
  (`app/Sources/WineHost/steam_ticket.c`, `steam_ticket_protocol.h`), which the runtime
  gives a module whose export name is a `steam_api`'s (madeira-unix 0087), for x86-64
  and, through WoW64, i386. The emulator (gbe 0006) calls it: HELLO on every start,
  CREATE (a type and an identity; no app ID), STATUS and CANCEL by handle. The blocks are
  fixed-size with no pointers, each checked by magic and size.
- **A ticket** is built as Steam's client builds it: the token with its length, a
  24-byte session header (its size, 1, the type, 8 random bytes, a timestamp, a
  sequence), then the ownership ticket with its length; a web API ticket is padded with
  random bytes to 2560. The host sends `ClientAuthList` with every live ticket by the
  CRC32 of its auth part; Steam's `ClientAuthListAck` makes it acked (after 10 s without
  one it is given anyway, as Steam's client does); `ClientTicketAuthComplete` says which
  server checked it and with what `EAuthSessionResponse`. A web API ticket's identity is
  bound as `str:<identity>`, a session ticket's `SteamNetworkingIdentity` in its string
  form when the game passes a valid one.
- **Limits, set by the host:** the launched app only; at most 8 live tickets; one each
  2 s, four at once. Steam's token supply (10) bounds it too.
- **The end.** `CancelAuthTicket` takes a ticket out of the list. Before the restart
  after the game (`TitleLaunch.end`), `endPlay` sends an empty list and an empty
  `ClientGamesPlayed` within 1 s. A crash or a kill ends the socket with the process.
- **Reconnect on demand** (owner): a CREATE on a closed connection logs on again with
  the stored session, at most once a minute, reading the refresh token from the Keychain
  while the guest runs; it waits up to 5 s for it, else the game gets the emulator's own
  ticket. Tickets of the old connection are ended.
- **Logs** carry a ticket's handle, type and size, and whether it is bound to an
  identity; never its bytes, a token, the identity or the SteamID. The play's end logs
  the CM's messages in and out during it.

## Threat model

Everything runs in one process (0004).

- **What a thief in the guest gets** (the game, a mod or DLL it loads, anything reading
  its memory): tickets for this app, as this player, valid at this game's servers (or
  the one identity a web API ticket names), and only while the phone's session is up and
  the ticket is live. The ownership ticket inside one is a Steam-signed proof that this
  account owns this app until it expires; it gives no session.
- **What it does not get:** Steam account access, a token usable outside this session,
  another app's ticket, the SteamID through the channel (the ticket carries it, as
  Steam's own tickets do).
- **The live socket** is the new residual: native code that escapes the guest could
  drive the logged-on CM connection and act as the account over CM (chat, persona,
  trading calls). This is inside 0004's residual ("a hostile guest binary can read
  anything the process can"): the same code could read the Keychain item through the
  app's own entitlements. The mitigation is 0004's: only owned titles and genuine
  clients run. The connection does nothing for the guest but tickets.
- **Locking.** The broker is a lock, not an actor; nothing waits on the network under
  it, and the ack handler never blocks on it beyond a few copies, so a game thread
  suspended inside a call (the in-game menu's pause) cannot stall Steam's pushes.

## What 0004 asks, and what this does

| 0004 asks | Here |
| --- | --- |
| a threat model for the secret | above |
| a single channel | the emulator's unix call table, during the play only |
| measured guest-side storage | the game's memory; the container search after the plays found no ticket header in any file the plays wrote but the emulator's own DLL (evidence) |
| logout removes every copy | the host keeps tickets in memory only; sign-out cannot happen during a play, and the process restarts after it |
| revocation also invalidates what the guest received | **yes**: a cancel, the play's end (an empty list) and the session's end (the process restart; Steam's `AuthTicketInvalid` for a client no longer connected) all end it |

## Also

- **Steam's matchmaking, lobbies and P2P stay out:** the emulator's networking is off
  (`disable_networking=1`). This serves games that sign in to their publisher's servers.
- **i386 games** get the same table through WoW64 and the emulator's i386 build: one line
  in the runtime, no other cost (owner: add it if cheap).
- **Battery.** Steam sets the heartbeat (9 s): about one message out each 9 s. On
  cellular that keeps the modem out of idle; measured only on Wi-Fi.
- **Not in scope:** an encrypted app ticket with the game's own data (0017 stays as it is).
