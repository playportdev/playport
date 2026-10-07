# 0063: A GOG game's Galaxy sign-in

**Status:** accepted, 2026-10-07, by the owner in the
[store game sign-in plan](../plans/2026-10-06-store-game-auth.md) (step 5): on by default for
every GOG game whose build carries a Galaxy client ID, and the residual below accepted
before the phone measurement, whatever it showed. One exception to
[0004](0004-steam-session-boundary.md); amends [0058](0058-store-sessions.md)'s "nothing
crosses into the guest". The workstation measurement (B0) is summarised under "What GOG
does"; the phone measurement is in the evidence the plan's gate writes.

## Decision

While a GOG game that ships GOG's Galaxy SDK (`Galaxy64.dll`) runs, the host is its local
Galaxy service, as GOG's own Galaxy client is. The game's SDK connects to `127.0.0.1:9977`
and asks for auth info with its own Galaxy client ID and secret; the host answers with a
**refresh token scoped to that game's client ID**, minted from the host's GOG session.
Achievements, stats, leaderboards and play time are served by the host. This is on by
default for every GOG game whose build manifest carries a Galaxy `clientId`, as GOG's
client gives it to every such game, with no per-game switch.

One secret crosses: the game-scoped refresh token. Nothing else from the host session does.

## How

- **The client.** The build manifest's `clientId` and `clientSecret` go into the game's
  install record (`manifests/gog-<id>.json` in the host's container) at install and
  update; a record written before reads them from its build at the next launch.
- **The listener.** At Play (`LibraryModel.play`), for a GOG game with a client while GOG
  is signed in, `GalaxyListener` (GOGClientKit) binds `127.0.0.1:9977`; the launch stops it
  however it ends. Signed out, no client, or the port taken: the game runs without it, as
  before, and a `galaxy:` line says why. Each connection is read on its own thread; a
  malformed or oversized frame (over 1 MiB) closes it.
- **The service.** `GalaxyService` answers the SDK's communication-service messages:
  `AUTH_INFO` (the binding check, then the mint at the play's first request, the overlay
  state "not supported", and the reply with the refresh token, the user ID and the public
  user name), `GET_USER_STATS`, `UPDATE_USER_STAT`, `DELETE_USER_STATS`,
  `GET_USER_ACHIEVEMENTS`, `UNLOCK_USER_ACHIEVEMENT`, `CLEAR_USER_ACHIEVEMENT`,
  `DELETE_USER_ACHIEVEMENTS`, the leaderboard requests, `GET_USER_TIME_PLAYED` and
  `START_GAME_SESSION`. Anything before the sign-in is refused (401); a message it does not
  serve gets 501. `LIBRARY_INFO` (GOG's separate peer library, which split SDKs load) is
  answered "not available": that library is not provided. The game's access token is
  refreshed at the game's client when it has under five minutes left. Unlocks and stat
  updates made with no network are not kept for later.

## The secret

- **What it is.** The host trades its GOG session's refresh token (GOG's desktop-client
  identity, 0058) at `auth.gog.com/token` with `grant_type=refresh_token`, the game's
  `client_id` and `client_secret`, and `without_new_session=1`. GOG answers with an access
  token and a refresh token for that client ID, the same user, and its own session ID.
- **Who uses it.** The SDK in the game signs in to GOG itself with it, over TLS, and then
  talks to GOG's back ends directly (multiplayer lobbies, chat, cloud storage). A game's own
  servers may also accept the sign-in. Without it the SDK stays signed out and these features
  are silent, which is the behaviour before this record.
- **What a thief could do.** Act as the player toward that game's GOG features until the
  token lapses. **Assumed worst case** (not measured, by the owner's choice): the token is
  usable beyond the game, up to acting on the GOG account as the player.
- **How long it lasts.** The access token GOG returns lasts 3600 s. Refreshing the
  game-scoped refresh token at the game's client gave a new access token and the same
  refresh token; GOG states no lifetime for refresh tokens, and the host session's refresh
  token was still accepted after about 22 hours. The crossing token is therefore assumed to
  last as long as the session it came from, or longer.

## What GOG does (workstation, 2026-10-07, one account)

Moonscars (GOG 2106173825, build 1.6.009), its client ID and secret from its public build
manifest:

- The game-scoped token: HTTP 200, fields `access_token`, `refresh_token`, `expires_in`
  (3600), `token_type` (`bearer`), `scope` (null), `session_id`, `user_id`. Its tokens and
  session ID differ from the host session's; the user ID is the same.
- Afterwards the host session went on working: its access token read the library (200),
  and its refresh token refreshed (200, the same session ID). Minting does not end or
  replace the host session.
- `GET gameplay.gog.com/clients/{client}/users/{user}/achievements` with the game-scoped
  access token: 200, `items` (34), `total_count`, `limit`, `page_token`,
  `achievements_mode`; each item `achievement_id`, `achievement_key`, `name`,
  `description`, `visible`, `date_unlocked`, image URLs, rarity fields.

## Threat model

Everything runs in one process (0004), so guest code can read the token while it is in
memory or on the socket: the game itself (which is meant to), any mod or DLL it loads.

- **Binding.** The host answers only when the request's `client_id` and `client_secret`
  equal the installed build's `clientId` and `clientSecret` from its build manifest (kept
  in the host's install record, not the prefix). Galaxy's own client ID is always refused.
  A guest gets at most the token GOG's client would give that game.
- **Listener only during a GOG play.** The service listens on loopback only from the
  launch of a GOG game with a client ID to its exit, while GOG is signed in. Another app on
  the phone could connect in that window; the game's client ID and secret are public (its
  build manifest), so the binding does not stop it, and it would get that game's token.
  The window is the bound. Every connection is logged (without payload).
- **Per play.** The token is minted at the first auth request of each play and kept in
  memory for that play only.

## The one channel

The local Galaxy service's `AUTH_INFO` reply on the loopback socket, and only that. Not the
command line, the environment, the registry, prefix files, or the `wine_host` ABI. The host
does not write it anywhere.

## What never crosses

The host session's refresh and access tokens, and the game-scoped **access** token the host
uses for `gameplay.gog.com`. The game's client secret comes from the game and the public
manifest; it is a game identity, not a user secret, but is still kept out of logs.

## Guest-side storage

Whatever the SDK writes (logs, caches) is measured after the phone play by searching the
prefix and the container for the minted token, and listed in the evidence.

## Logs

The service never logs payloads: a connection, each request's message name and size, and
each reply's status. `Redactor` scrubs `refresh_token`/`access_token` and `client_secret`
values in the forms it already covers; host tests show it.

## Sign-out and revocation (the residual)

GOG offers no revocation (0058). Sign-out deletes the host session, and a play that starts
signed out runs without the service; it ends **only the host's copy**. A token that already
crossed into a game goes on working until GOG lets it lapse, and is assumed usable beyond
that game. 0004's fifth condition (revocation that also invalidates what the guest got)
cannot be met. The sign-out says so.

The owner accepted this residual on 2026-10-07, whatever the measurement showed.

## Costs and risks

- GOG may change or close the cross-client refresh grant; that ends the features, not play.
- Some SDK builds may expect a registered Windows service or more of the local protocol
  before they proceed; the phone shows which.
- An achievement the game unlocks is sent to GOG at once and is permanent on the account,
  as with GOG's client.
