# Plan: games sign in to their store (Epic, Steam, GOG)

**Date:** 2026-10-06, rewritten 2026-10-07. **Kind:** plan, in progress: steps 0, 1, 2 and
4 done (4's S1 waits for a title that asks for a ticket); GOG (step 5) next. **Blocks:** the 0.4.0 release (owner, 2026-10-06: "the stores update
can't ship without these"). `main` carries the 0.4.0 version and `docs/releases/0.4.0.md`
(`b21f63d`); nothing is built or drafted.

**Decisions:** [0059](../decisions/0059-epic-exchange-code.md) (Epic exchange code and
ownership token) was accepted in step 1;
[0017](../decisions/0017-encrypted-app-ticket.md) (Steam encrypted app ticket) was accepted
in step 2; [0062](../decisions/0062-steam-live-session.md) (a live Steam session during
play) was accepted in step 4; 0063 (a GOG game's
Galaxy sign-in) in the GOG step. 0060 and 0061 are taken on `vulkan-performance`.

## Goal and the owner's direction

Playport aims to run every game Proton runs. Only kernel anti-cheat (EasyAntiCheat,
BattlEye) and games that need another company's launcher stay out. Today some games lose
their online part to the session boundary
([0004](../decisions/0004-steam-session-boundary.md),
[0058](../decisions/0058-store-sessions.md)), not to the runtime:

- **Epic.** A game whose catalogue sets `OwnershipToken=true` or `CanRunOffline=false` is
  refused on its page ("This game needs Epic online sign-in…", `EpicLibrary.swift`):
  Borderlands 3, Guardians of the Galaxy, Football Manager 2022 and its two tools, Jurassic
  World Evolution, Star Trek Online. Every other Epic game launches with no exchange code,
  so the 23 of 34 that carry the EOS SDK run signed out of it.
- **Steam.** gbe_fork answers `GetAuthSessionTicket` and `GetAuthTicketForWebApi` with
  made-up tickets. A game whose servers check one refuses its online part. (The encrypted
  app ticket is real since step 2.)
- **GOG.** 31 of the owner's 46 GOG games ship the Galaxy SDK. With no Galaxy service its
  features (achievements, stats, leaderboards, GOG multiplayer) are silent.

Done means: a game gets from its store what the store's own launcher would give it at
launch, by default, and a refusal is left only for anti-cheat and third-party launchers.
0004's rule keeps holding for the host session itself: its refresh and access tokens never
cross. What crosses is a game-scoped credential, by one channel each, under its own record.

## Settled (owner, 2026-10-07)

- **Step 4 is in the 0.4.0 gate.** Step 3 (tickets made before launch) is dropped: Valve's
  documentation for `EAuthSessionResponse` says `OK` means Steam has verified the user is
  online, and `AuthTicketInvalid` means "not from a user instance currently connected to
  steam", so a ticket made before `suspendForLaunch` closes the session dies with it.
- **Step 4's choices.** D1: reconnect on demand during play (at most once a minute, reading
  the Keychain while the guest runs), recorded in 0062. D2: send `ClientGamesPlayed` for the
  play. D3: i386 games as the Among Us pull calls for (a WoW64 table and gbe's i386 build if
  it is i386). D4 (an encrypted ticket with the game's data) is out of scope. D5: on by
  default for every Steam game, no switch.
- **In scope before 0.4.0:** Epic's older JSON manifest form (Football Manager 2022, its
  Editor and Resource Archiver, Scarf; `EpicManifest` refuses it today) and GOG Galaxy
  features.
- **GOG residual.** The owner accepts that the game-scoped GOG refresh token crosses into
  the game even if it is account-equivalent and cannot be revoked; 0063 states it plainly.
- **Epic offline.** When the exchange code cannot be fetched (offline, Epic signed out), a
  game that may run offline (`CanRunOffline` not `false`, no `OwnershipToken`) offers
  **Play offline** beside Try again and Cancel; it then starts with the arguments it had
  before step 1, logged as offline. Any other game offers Try again and Cancel only.
- **Test titles.**
  - Epic: Jurassic World Evolution (8.0 GB; ownership token, no offline play, EOS) if it fits
    `MemoryNeed`; Snakebird Complete (319 MB, EOS) as the light first check; Death's Door as
    the regression play; the Football Manager 2022 Editor or Resource Archiver for the JSON
    manifest (install and verify).
  - Steam: Among Us (945360, installed, 1.15 GB): pull its binaries and look at which ticket
    it uses. Its first play on the phone ended at 17 s in a runtime fault, and its EOS
    client failed TLS before any sign-in (Linear PLA-39), so its online menu needs that
    runtime work first; otherwise another Steam title with a publisher login.
  - GOG: Moonscars (0.70 GB, Unity x86-64, `Galaxy64.dll`, achievements); back-ups Duck
    Paradox and Monster Train; Quake II for the split SDK.

## What each store's launcher passes

**Epic** (confirmed from the workstation, 2026-10-07):

- `-AUTH_LOGIN=unused -AUTH_PASSWORD=<exchange code> -AUTH_TYPE=exchangecode`. The code comes
  from `GET /account/api/oauth/exchange` with the host's access token: 32 hex digits,
  `expiresInSeconds` 299, `creatingClientId` the launcher's client. It is one-time. The game
  trades it, with its own EOS client identity, for its own session.
- `-epicapp`, `-epicenv=Prod`, `-EpicPortal`, `-epicusername=<display name>`,
  `-epicuserid=<account ID>`, `-epiclocale`, `-epicsandboxid=<namespace>`.
- For `OwnershipToken=true`: `-epicovt=<path>` to a file holding the ownership token from
  `POST …/ecommerceintegration/api/public/platforms/EPIC/identities/<account ID>/ownershipToken`
  (form `nsCatalogItemId=<namespace>:<catalog item ID>`); the reply is `{"token": …}`, an
  840-character `egoc1~` token.

**Steam:** the encrypted app ticket (0017, step 2), and the auth session and web API tickets,
which Steam accepts only while the issuing client is logged on and has reported them
(`ClientAuthList`): step 4.

**GOG:** games are DRM-free and start with no credential. The Galaxy SDK in a game connects
to the local Galaxy service on `127.0.0.1:9977` (a header and protobuf over TCP), asks for
auth info with the game's own client ID and secret, and gets a refresh token scoped to that
game's client; stats, achievements and leaderboards go through the service.

## Steps

**0. Survey. Done 2026-10-07** ([evidence](../evidence/2026-10-07-store-game-auth-survey.md)).
Epic: 23 of 34 games carry the EOS SDK, 6 set `OwnershipToken`, 2 `CanRunOffline=false`, 3
ship EasyAntiCheat, 4 use the JSON manifest form. Steam: the owned list cannot be read from
the workstation; static scans cannot show ticket use for Unity or interface-based games.
GOG: 31 of 46 ship the Galaxy SDK.

**1. Epic: decision 0059, the launch, and JSON manifests. Done 2026-10-07** (`5d559c3`,
`c970646`; [evidence](../evidence/2026-10-07-epic-game-auth.md)). 0059 accepted, on by
default with no per-game switch; 0004 and 0058 point at it. Right after Play the host
fetches a fresh exchange code (and, when the catalogue sets `OwnershipToken`, a five-minute
ownership token); the launch passes Epic's launcher's arguments and writes
`playport-epic.ovt` in the game's folder, removed at exit, next launch, app start and
sign-out. Without the sign-in the page offers Try again and Cancel, and Play offline for a
game that allows it. The OwnershipToken/CanRunOffline refusal is gone; anti-cheat and other
companies' launchers keep theirs, each with its own message. `EpicManifest` reads Epic's
JSON form. The app, `Redactor` and the runtime's process lines (madeira-unix 0086) keep the
code, account ID and display name out of logs. On the phone: Snakebird Complete and Death's
Door start with a code (fetched in 0.4–0.6 s) and reach their menus; Jurassic World
Evolution gets a code and an ownership token, its file written and removed at exit; the
FM2022 Resource Archiver installs from its JSON manifest and verifies 11/11; Hollow Knight
plays as before. The container search after the plays found no copy of the code, the
account ID or the token. Open:
- No game has shown an EOS sign-in yet: Snakebird's EOS refuses Epic's certificate
  (`Curl error 60`, the guest's TLS roots, as Among Us's PLA-39), and Jurassic World
  Evolution does not start (`0xc0000018`, its fixed-base executable placed by the
  runtime). Both are runtime work, filed separately; step 6 needs one of them fixed or
  another EOS title.
- The sign-in failure page and sign-out removal are checked by host tests only.

**2. Steam encrypted app ticket: 0017 accepted. Done 2026-10-07** (`e65f3f0`, `bd490ac`,
`0b4cc93`; [evidence](../evidence/2026-10-07-steam-encrypted-app-ticket.md)). On by default
for every Steam game with no per-game switch; 0004 points at 0017 and 0059. After Play the
host asks Steam for the ticket (the session in the game for the call, 5 s limit); the launch
writes `ticket=<base64>` in the emulator's `configs.user.ini` and removes it at exit, next
launch, app start and sign-out. On the phone: Among Us gets a 143-byte ticket in 0.22 s;
Hollow Knight gets none (`Fail`: not set up for tickets) and plays as before. The container
search found no copy outside the ini line. Open: sign-out removal is tested on the host only.

**3. Steam tickets made before launch: dropped** (Settled, above).

**4. A live Steam session during play (decision 0062). Done 2026-10-07** (`086c59c`,
`624cc35`; [evidence](../evidence/2026-10-07-steam-live-session.md)). 0062 accepted with the
owner's D1, D2, D5; D3: the WoW64 branch was one line and gbe's i386 build already existed,
so it is in; Among Us is x86-64 anyway. On the phone (IPA `74c28bf7`): Hollow Knight logs
`emulator connected (protocol 1, tickets armed)` and `CM kept for the game's tickets`,
plays as before (60 fps median in a 120 s `pp perf`; arming takes 0.3–0.4 s), and its play
costs the CM 6–17 messages out and 7–8 in. Among Us uses the encrypted app ticket (its
IL2CPP strings; no web API ticket in its Steamworks.NET) and made no ticket before its
PLA-39 fault. The container search found no ticket header outside the emulator's DLL.
Open: no title has made a ticket yet (S1 needs one that calls `GetAuthSessionTicket` or
`GetAuthTicketForWebApi` for its own servers); S3 (the background) cannot be driven
through `pp ui` and the reconnect is host-tested only; one play's CM socket dropped
16 s in (ECONNABORTED, cause unknown). Design as built: the host keeps the logged-on CM
connection during a play (heartbeat and receive tasks at `.utility`); every other Steam call
stays refused while suspended. gbe_fork asks the host for auth session and web API tickets
through a Wine unix call table; the host builds each ticket from a game connect token and
the app's ownership ticket, reports it with `ClientAuthList`, and cancels it. No token
crosses: only ticket bytes, a handle and a state. The app ID is pinned to the launched
title; at most 8 live tickets, one every 2 s. Chunks, in order:

| # | Chunk | Size |
| --- | --- | --- |
| 4.1 | Wire: EMsgs 779, 857/858, 5432 (with `CMsgAuthTicket`), 5575, 5429, with tests | S |
| 4.2 | `CMConnection` push handler; `SteamSession` token queue (≤ `max_tokens_to_keep`, cleared at disconnect); `appOwnershipTicket(appID:)` | S–M |
| 4.3 | `SteamTicketBroker`: build (24-byte header, CRC32 of the auth part, web API padding to 2560), auth list, ack, cancel by the auth part's CRC, `endPlay`, limits; tests | M |
| 4.4 | Service and launch: `prepareTicketSession` at Play, `suspendForLaunch` keeping the CM while a broker is armed, `endPlay` before the restart, `cm: N in / M out` counters, reconnect on demand (D1), `ClientGamesPlayed` (D2) | M |
| 4.5 | WineHost: `steam_ticket_protocol.h`, `steam_ticket.c`, provider registration (ABI 4), C tests | S–M |
| 4.6 | `patches/madeira-unix`: the `steam_api` name match to the table; the WoW64 branch if D3 calls for it | S |
| 4.7 | `patches/gbe`: the host client, `auth.cpp`/`steam_user.cpp`/`steam_client.cpp` hooks; HELLO on every play | M |
| 4.8 | Docs: 0062 (threat model: tickets for this app only, revocable by cancel and end of play; the live socket inside 0004's residual); amend 0004's suspension rule; ARCHITECTURE | S |
| 4.9 | Phone: P1 (Hollow Knight, HELLO, "CM kept", `pp perf --secs 180` against the broker off), the Among Us pull, S1–S4 (online menu, container search, Home Screen for 60 s, kill mid-play); evidence | 2–3 sessions |

Steam lobbies, matchmaking and P2P stay out (Playport sets gbe's `disable_networking=1`):
step 4 serves games that sign in to their publisher's servers.

**5. GOG Galaxy (decision 0063).** The host is the game's local Galaxy service while a GOG
game with a Galaxy client ID runs. Measured first on the workstation (B0, 2026-10-07, with
the owner's GOG session, results only): a refresh token minted at Moonscars' client with
`without_new_session=1` answered 200 with the same user ID and its own session ID; the host
session went on working (library read, refresh with the same session ID); the game token
refreshed at the game's client without rotating; access tokens last 3600 s; the game's
achievements list (34 items) read with the game-scoped access token. Not measured, by the
owner's choice: whether the game token works at another client (0063 assumes the worst case).

| # | Chunk | Size |
| --- | --- | --- |
| B1 | Write 0063 with B0's numbers and the accepted residual; amend 0004's exceptions and 0058's "nothing crosses" | S |
| B2 | `GOGContent`/`GOGInstaller`: the build manifest's `clientId`/`clientSecret` into the install record (host container, not the prefix); older records fetch it at the next launch | S |
| B3 | `GalaxyWire` in GOGClientKit: the frame (u16 big-endian header length, header, payload) and the messages' fields, with host tests | S–M |
| B4 | `GalaxyService` actor: `AUTH_INFO` (binding to the build's client ID and secret, Galaxy's own ID refused), `LIBRARY_INFO`, `START_GAME_SESSION`, stats, achievements, leaderboards, time played, against `gameplay.gog.com` with the host-held game access token; host tests | M |
| B5 | The listener and the launch: up only from a GOG launch with a client ID to its exit, while GOG is signed in; port taken or signed out → run without; `Redactor` and tests | M |
| B6 | Offline queue for unlocks and stats, sent at the next play; deleted at sign-out | S–M |
| B7 | Split SDK (Quake II's `GalaxyPeer.json`): GOG's peer library fetched on the device into the prefix's official layout; a LICENSING/DISTRIBUTION note | S–M |
| B8 | Only if the phone shows it: an SDK that will not connect without a registered `GalaxyCommunication` service (a Wine patch) | unknown |
| B9 | Phone gate: Moonscars to `first-frame+10` and into the game; the log shows `AUTH_INFO` and the achievements request; container search for the minted token; Shogun Showdown and Hollow Knight as regressions; evidence. An achievement unlock is permanent on the owner's account: ask first | one session |

**6. Phone gates (one `pp phone lock` session each).** Each store's test title on the IPA
that will ship: Epic signs in and reaches its menu; Steam's title reaches its online menu
signed in; GOG's shows its Galaxy sign-in; Hollow Knight and Death's Door to
`first-frame+10`. Sign-out from each store removes every leftover file (where it can be done
without the owner re-pairing). `docs/evidence/<date>-store-game-auth.md` with the IPA's sha256.

**7. Release.** Update `docs/releases/0.4.0.md` (the Epic refusal paragraph becomes what now
works; Steam's online part; GOG's Galaxy features), then `pp release 0.4.0` from a clean,
pushed `main` in its own build area (`PLAYPORT_BUILD`, a fresh `run/`: the live `run/`'s
CMake caches hold absolute paths).

## Order

Step 1 → step 4 → GOG (step 5) → phone gates (6) → release (7). Next: GOG, from B1. Each step commits with its
own evidence; the scratch measurements behind the designs are left in the build area.

## Risks

- A game may launch fine with the code and still fail in EOS on Wine/iOS for other reasons
  (TLS, the overlay, web views): runtime work filed on its own, not a refusal.
- Jurassic World Evolution may not fit `MemoryNeed`; Borderlands 3 and Guardians of the
  Galaxy (over 80 GB) are out of reach for a gate.
- Step 4 keeps a network socket up during play: a 9 s heartbeat (power on cellular), a new
  x64→ARM64EC unix call, and a socket a thread suspended under the broker's lock could stall.
  The CM may not top up connect tokens in a long play.
- GOG may change its cross-client refresh grant; some SDK builds may want a registered
  service or more of the local protocol (B8). About a ninth of the 31 Galaxy games are 32-bit
  and cannot run anyway.

## Not in this plan

Kernel anti-cheat; games that install another company's launcher; Steam lobbies and P2P;
Epic and GOG cloud saves (the PC import plan's 2.4 and 3.7).
