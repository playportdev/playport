# Plan: a Steam client bridge for games (the game's own steam_api, Playport's steamclient)

**Date:** 2026-10-12. **Kind:** design and execution plan, decided. **Status 2026-10-19:**
no phase has started. One slice of Phase 1 has shipped for one game:
[decision 0115](../decisions/0115-a-steam-client-for-the-launched-app.md) and the
[Steam bridge for RDR2](finished.md#steam-bridge-for-rdr2) (PLA-398, merged in `dfc527f`). It adds
Steam API mode `client`; an x86-64 `steamclient64.dll` (`app/SteamClientShim`) serving
ISteamClient, Utils, User, Friends and Apps for the launched app, with logging stubs for the rest;
madeira-unix 0158's unix table; and the `Valve\Steam` keys in both registry views (PLA-400). It is
the compatibility default of RDR2 (1174180) alone. Every other title still uses the emulator.
Phase 1 (PLA-257) builds on that slice: generated vtables, callbacks and call results, and Hollow
Knight on `client`.
(Review 2026-10-13: the owner took decisions D1–D10 on 2026-10-13, see
[Owner decisions](#owner-decisions-decided-2026-10-13)). **Linear:** [PLA-253](https://linear.app/playportdev/issue/PLA-253)
(umbrella; each phase has its own issue, listed under [Phases](#phases)).

**Repository path:** `docs/plans/2026-10-12-steamclient-bridge.md`.

Working material for this plan is in the build area, not here: the interface scan
(`$PLAYPORT_BUILD/agent-notes/pla253/scan_ifaces.py`, `ifaces.tsv`, `iface-rank.tsv`) and the
parity reference set (`$PLAYPORT_BUILD/agent-notes/pla253/reference-set.md`, which stays
private).

## Goal

**Proton parity, with online games playable** (owner, 2026-10-12). A Steam game on the phone gets
what it gets under Proton on a desktop with Steam running: the same Steam features (sign-in state,
ownership and DLC, persona and friends, stats and achievements, Cloud, tickets) and the same online
reach (lobbies, P2P and Steam Datagram Relay, the server browser, dedicated servers, the game
coordinator), wherever Proton gets them.

Under Proton a game keeps its own `steam_api(64).dll`; Steam's client runs outside Wine, and a
Wine-side `steamclient` forwards the game's interface calls to it. This plan gives Playport the
same shape:

- the game keeps its **own** `steam_api(64).dll` (nothing swapped);
- Playport puts a **guest `steamclient(64).dll` shim** where Steam's registry says the client is;
- the shim forwards each call through **one Wine unix call table**, as the ticket table does today
  (`app/Sources/WineHost/steam_ticket.c`, madeira-unix 0087, decision
  [0062](../decisions/0062-steam-live-session.md));
- the host's native Swift client (`app/SteamClient`) answers, over its CM connection.

This replaces the Steam API emulator (`patches/gbe`, `SteamAPISwap` mode `emulated`) once the
reference set passes; the emulator stays as a per-title fallback during the transition and is
removed right after the bridge is proven to work (owner, D7, 2026-10-13).

### Considered and not chosen: Valve's Windows client in the guest (option A)

Run Valve's Windows `steam.exe`/`steamclient64.dll` headless inside the prefix, as a desktop
Windows does. Not chosen:

- **Security boundary ([0004](../decisions/0004-steam-session-boundary.md)).** A guest
  client does its own login and keeps its own session in the prefix under Wine's DPAPI, readable by
  every guest binary and copied with the container: the leak surface 0004 exists to avoid, now for
  a full account session, not one game's ticket.
- **Memory.** The JIT pool is 512 MiB (0036). Steam's Chromium UI alone reached about 700 MiB of
  pool head in earlier measurements (0019); each extra x86-64 process costs about 20–28 MiB
  (0094/0096). Even headless, `steam.exe`, its service and `steamclient64.dll` (26 MB on disk) run
  under FEX beside the game.
- **Dependency on Valve's Windows client.** Its files are not redistributable, update on Valve's
  schedule, need a second sign-in on the phone, and would make Playport depend on a closed Windows
  binary running under emulation, where the host already speaks the protocol natively.

Option B costs a large ABI surface (every interface version a game may ask for) and a protocol
implementation per feature; the phases below are ordered to buy the most parity per step.

## Done when

The umbrella is done when, for every title in the **parity reference set**
(`$PLAYPORT_BUILD/agent-notes/pla253/reference-set.md`; about 25 titles kept in the build area:
Steam single-player baselines, old-SDK and i386 titles, lobby/P2P/SDR titles, server-browser
titles, game coordinator titles, own-backend titles, and the other stores' online titles below),
measured on the
phone and under desktop Proton with the same game build:

1. **Outcome class matches** per feature row: *starts*, *signed in to Steam*, *ownership/DLC*,
   *persona/friends*, *stats/achievements live*, *Cloud*, *online* (lobby joined / server joined /
   match played for 5 min). Each row is Same, Better, or Worse; **no Worse row** except one with a
   filed Linear issue the owner has accepted as out of scope (anti-cheat, launcher-gated).
2. **Online:** each L/D/G title in the set completes its online row against a desktop peer or a
   public server, phone to desktop and desktop to phone where the game allows it.
3. **No regression:** Hollow Knight (`app-367520`) and Portal 2 (`app-620`) first-frame+10 on the
   new default; JIT pool head at first frame within 10 MiB of the emulator's for the same title.
4. **0004 holds:** a new decision record (proposed in Phase 0) covers everything that crosses, and
   the device driver's leak check and `pp secrets` are clean on every gate run.
5. The emulator is no longer the default for any Steam title; its removal is its own issue (Phase 6),
   done right after the bridge is proven (D7).

Measurement record per title: IPA sha256, run directory, desktop Proton version, the outcome row,
and the game's Linear Compatibility issue updated (AGENTS.md).

## Inventory: which interfaces games use

**Method.** `scan_ifaces.py` reads interface version strings (ASCII and UTF-16LE, so .NET
string literals count) from the binaries in the build area: the phone pulls of the dll survey
(`$PLAYPORT_BUILD/agent-notes/dll-survey/phone-binaries`, `epic-binaries`), the GOG and Epic
desktop copies under `$PLAYPORT_BUILD/agent-notes/store-auth/`, and the Half-Life copy under
`$PLAYPORT_BUILD/agent-notes/speedrun/`. A game's own
binaries name the interfaces it asks for (since the 1.37-era SDK the accessors are inline in the
game, so the strings are in the game, not in steam_api). A real `steam_api(64).dll` names only its
SDK's set and is reported separately; the emulator's builds (several MB) were skipped.

**Coverage is thin:** 10 distinct games had binaries that carry the strings (6 Unity/IL2CPP or Mono
assemblies were not pulled, e.g. Hollow Knight's and Valheim's `Managed/`). Older SDKs
(`CSteamAPIContext::Init`) fetch every interface at start, which inflates their counts. Phase 0
re-runs the scan on the whole reference set (game files pulled under the phone lock, or downloaded
by Playport's installer to the workstation).

**Interfaces named by games (of 10), most first:**

| Interface | Games | Versions seen | Note |
|---|---|---|---|
| ISteamUser | 10 | 018–023 | every game; tickets already live (0062) |
| ISteamUtils | 9 | 007–010 | |
| ISteamFriends | 9 | 015, 017 | persona name everywhere; rich presence, overlay calls |
| ISteamApps | 9 | 007, 008 | ownership, DLC, language, branch |
| ISteamUserStats | 6 | 011, 012 | |
| ISteamRemoteStorage | 6 | 012–014 (016 in steam_api) | Cloud |
| ISteamController / ISteamInput | 6 | Controller 003–007, Input 006 | answer "no controllers": games fall back to XInput |
| ISteamMatchmaking | 4 | 009 | lobbies |
| ISteamMatchmakingServers | 4 | 002 | server browser |
| ISteamHTTP | 4 | 002, 003 | |
| ISteamUGC | 4 | 003–014 | Workshop |
| ISteamNetworking (legacy P2P) | 3 | 005 | |
| ISteamGameServer (+Stats) | 4 | 012, 015 | listen/dedicated servers in-process |
| ISteamInventory | 3 | 001, 002 | |
| ISteamHTMLSurface, Screenshots, Music, Video, AppList, UnifiedMessages | 3–4 | | old-SDK context fetches; answer minimally |
| ISteamGameCoordinator | 2 | 001 | old-SDK fetches here; the real users are Valve's GC titles |
| ISteamNetworkingSockets / NetworkingUtils | 1 | 012 / 004 | Half-Life's 2023 build; Valheim and most new titles (not pulled) |
| ISteamAppTicket, ParentalSettings | 1–2 | | |

**What steam_api asks of steamclient.** A real `steam_api64.dll` (SDK 1.5x) reads
`HKCU\Software\Valve\Steam\ActiveProcess` (`pid`, `SteamClientDll`, `SteamClientDll64`), loads
that DLL and resolves `CreateInterface`, `Steam_BGetCallback`, `Steam_FreeLastCallback`,
`Steam_GetAPICallResult`, `Steam_ReleaseThreadLocalMemory` and the `Breakpad_*` exports; it asks
`CreateInterface` for `SteamClient017`…`SteamClient021`. Every interface version string the game
passes goes through steam_api to the client unchanged, so **the shim must serve every version a
game asks for, not one per SDK**: Half-Life's game binaries ask for `SteamUser023` through a
steam_api whose own set ends at `SteamUser021`.

## Architecture

```
game.exe ─► steam_api64.dll (the game's own) ─► steamclient64.dll (Playport shim, guest PE)
                                                     │ __wine_unix_call (one table, x86-64 and WoW64)
                                                     ▼
                         WineHost steam_client.c (block checks) ─► Swift SteamGameBridge
                                                     │                   │
                                                     │                   ├─ snapshot (lock): ids, ownership, DLC, persona, stats
                                                     │                   ├─ event queue (lock): callbacks, call results
                                                     │                   └─ SteamSession / CMConnection (actor): CM messages
                                                     ▼
                                            native networking (host): SDR, P2P, sockets
```

### The guest shim

- **What it is.** A PE DLL per architecture, `steamclient64.dll` (x86-64) and `steamclient.dll`
  (i386), built with llvm-mingw like the emulator (`build/stages/`), shipped in `Runtime/`, and
  placed at `C:\Program Files (x86)\Steam\` in the prefix with the `ActiveProcess` keys Proton's
  prefix has (`SteamClientDll`, `SteamClientDll64`, `SteamPath`, `pid`) and `Software\Valve\Steam`
  (`SteamExe`, `SteamPath`). It is a native DLL, not a Wine builtin.
- **Exports.** `CreateInterface`, `Steam_BGetCallback`, `Steam_FreeLastCallback`,
  `Steam_GetAPICallResult`, `Steam_ReleaseThreadLocalMemory`, `Steam_IsKnownInterface`,
  `Steam_NotifyMissingInterface`, the `Breakpad_*` no-ops, and the older global entry points
  (`Steam_CreateSteamPipe`, `Steam_ConnectToGlobalUser`, `Steam_ReleaseUser`, `Steam_GSLogOn`…)
  that pre-1.2x steam_api builds call.
- **The vtable ABI.** Interfaces are C structs of function pointers, **generated** per interface
  version from Valve's public Steamworks SDK headers (a generator in `tools/`, its output committed
  or built; headers from the SDK releases, see owner decision D3). No C++ classes in the shim, so
  the MSVC/Itanium differences the emulator patches around (gbe 0003–0005) are explicit:
  - x86-64: Microsoft x64 convention, `this` in RCX; a method returning a class type (`CSteamID`,
    `SteamNetworkingIdentity` by value) takes a hidden return pointer after `this`, as MSVC member
    functions do; overloaded virtuals in MSVC's reversed declaration order; the destructor slots
    where MSVC puts them.
  - i386 (WoW64): `__thiscall` (`this` in ECX, callee pops); the same return and order rules;
    structs at the SDK's Windows packing (`VALVE_CALLBACK_PACK_LARGE`, 8).
  - One method thunk per (interface, version, method): it packs its arguments into a pointer-free
    block and makes one unix call. A version never seen gets `Steam_NotifyMissingInterface` and NULL,
    as Steam's client does, and a log line naming it (so the inventory grows from real runs).
- **Pipes and users.** `HSteamPipe` and `HSteamUser` are small integers the shim hands out
  (`CreateSteamPipe`, `ConnectToGlobalUser`, `CreateLocalUser` for a game server). One global user:
  the host's account. Game-server users are separate host-side game-server logons (Phase 5).
- **Callbacks and call results.** steam_api's `SteamAPI_RunCallbacks` and the manual-dispatch API
  (`SteamAPI_ManualDispatch_*`) both pull through `Steam_BGetCallback(pipe, &CallbackMsg_t)` /
  `Steam_FreeLastCallback`, and call results through `Steam_GetAPICallResult(pipe, call, buf,
  size, expected, &failed)`. The shim polls the host's per-pipe queue with one non-blocking unix
  call and copies each record into a buffer it owns until `FreeLastCallback`. The host emits the
  Windows layout of each callback struct (pointer-free in the SDK; the same bytes for x86-64 and
  i386 at pack 8, checked by a generated size table per callback ID). `SteamAPICall_t` handles are
  the host's.
- **`SteamAPI_IsSteamRunning`.** steam_api checks that `ActiveProcess\pid` names a live process.
  The guest has no `steam.exe`. Phase 0 measures the cheapest true answer on desktop Wine: the pid
  of a process the session already runs (`explorer.exe` or `services.exe`) written at prefix start,
  else a madeira-unix answer; a guest `steam.exe` stub costs a process (20–28 MiB of pool) and is
  the last resort (decision D6).
- **No overlay.** `GameOverlayRenderer64.dll` is not provided; `ISteamUtils::IsOverlayEnabled`
  answers false. `ActivateGameOverlayToWebPage` opens the URL in the game web sheet
  ([0064](../decisions/0064-game-web-sheet.md)), which is what the player would see.

### The unix call channel

- **One table**, `playport_steamclient_unix_call_funcs` (`app/Sources/WineHost/steam_client.c`,
  `include/steam_client_protocol.h`), given by a new madeira-unix patch to a module whose export
  name contains `steamclient` (0087 matches `steam_api`; the game's real steam_api never asks for a
  unix library, so 0087 is harmless while both exist), and the same table as its WoW64 table.
- **Blocks** keep 0087's rules (magic, size, version, a known call, fixed fields), with one
  addition: data larger than a block (a Cloud file, a lobby's data, a packet) is passed as a
  `uint64_t` guest address and a length. The guest and host share one address space (0004), so the
  host copies in or out directly after checking the range is the caller's committed memory; an
  i386 address is zero-extended, so one layout serves both architectures and no WoW64 thunk
  table is needed. Phase 1 verifies that a WoW64 guest address is readable as is from the host.
- **Calls:** HELLO (versions, armed), CALL (interface id, version, method id, argument block,
  out block), POLL (pipe → the next callback, or none), RESULT (call handle → its bytes), FREE,
  RELEASE (pipe/user ends). Method dispatch on the host is by generated id, not by name.
- **Never block the game thread on the network.** As the ticket broker does: a synchronous
  getter reads the snapshot under a lock; a request that needs Steam returns a `SteamAPICall_t` at
  once and its answer arrives later as a call result. A method Steam's own client answers
  synchronously from cache (persona name, friends count, `BIsSubscribedApp`) is answered from the
  snapshot.

### The host side (Swift)

- **`SteamGameBridge`** (SteamClientKit `Service/`), the generalisation of `SteamTicketBroker`: a
  lock-based front for the guest-facing calls (snapshot reads, the event queue, request ids), and
  the `SteamSession`/`CMConnection` actor for CM work, with receive and heartbeat at utility
  priority during a play (0062). The C side sees it through a provider of function pointers set
  with `wine_host_set_steamclient_provider`, as the ticket provider is set today.
- **Per-interface services**, each a small type over CM messages the client already speaks or
  will: User (tickets: the existing broker, moved in), Apps (the PICS data and license list kept
  at Play), Friends (`ClientPersonaState`, `ClientFriendsList`, rich presence), UserStats (the
  existing schema/stats code, now live: `ClientGetUserStats`, `ClientStoreUserStats2`), RemoteStorage
  (files in the prefix's `Steam\userdata\<account>\<app>\remote`, synced by the existing `Cloud`
  code before and after the play), Matchmaking (the matchmaking-service messages), GameServer, the
  GC relay, HTTP (host `URLSession`), UGC and Inventory (Steam's unified service methods).
- **Threading.** The CM receive loop pushes the messages a play needs (`pushedEMsgs`) into the
  bridge; the bridge turns them into callback records under its lock. Nothing waits on the network
  under the lock (0062's rule).
- **Persistence.** None beyond what exists: the snapshot is in memory for the play; Cloud files are
  the game's files.

### What crosses the boundary (0004, 0062)

Crosses, as Steam's own client gives it to a game: the SteamID, persona names (own and friends'),
ownership/DLC/branch, the app's stats and achievements, Cloud file contents, lobby data and member
lists, auth session and web API tickets (0062), the encrypted app ticket **fetched live with the
game's data** (fixes 0017's limitation), packets on Steam's networking sockets, GC messages.

Never crosses: the refresh or access token, the CM session key or connection, machine and
session bindings, CDN and depot keys, any other app's tickets, the networking certificate's
private key (the host terminates SDR; only payloads cross).

This widens 0062's "the connection does nothing for the guest but tickets". It needs **a new
decision record** amending 0004/0062 (decision D1), with the threat model: the guest can now ask
the live session to act for the launched app (join lobbies, store stats, send GC messages), so the
host keeps an allow-list of CM messages per interface, scoped to the launched app ID, with rate
limits, and refuses everything else (no chat to arbitrary users, no trading, no account calls).

### Lifecycle

1. **Play** (`LibraryModel.play`, `LaunchCoordinator`): as today, the session (logged on) fetches
   the ownership ticket, connect tokens, `ClientGamesPlayed`; plus the snapshot (persona, friends,
   DLC, stats), Cloud sync in, and arms the bridge. Offline: the bridge arms in Steam's offline
   mode from cached data (`BLoggedOn` false), as Steam's client does offline.
2. **Launch:** the game's own steam_api stays; SteamStub is still taken off (see DRM); the prefix's
   `Steam\` folder and `ActiveProcess` keys are written; `SteamAppId`/`SteamGameId` as 0020.
3. **Play runs:** HELLO, calls, polls. Reconnect on demand as 0062 (at most once a minute).
4. **End** (`endPlay`, before the restart): leave lobbies, close networking sessions, flush stats,
   empty auth list, empty `ClientGamesPlayed`, Cloud sync out after the restart as today. A crash
   or kill ends the socket with the process.

### Fallback during the transition

`SteamAPISwap.Mode` gains `client` (label "Playport's Steam client"). During Phases 1–5 a title
runs `client` only when `compat-defaults.json` or the player's game page says so; the default stays
`emulated`. The default flips per title class when its reference titles pass (Phase 2 for
single-player, Phase 4 for online). A failed HELLO (no bridge) makes the shim answer as Steam's
client does when not logged on; it never falls back to the emulator inside a run. Removing the
emulator is Phase 6, right after the bridge is proven to work, with no waiting period (Review
2026-10-13: owner decision D7).

## Networking: what is realistic

| Feature | How Steam does it | Plan | Realism |
|---|---|---|---|
| Lobbies (ISteamMatchmaking) | CM matchmaking-service messages (create, join, list, data, chat, leave) | host service, Phase 3 | **high**: CM only |
| Server browser (ISteamMatchmakingServers) | master-server list over CM, then each server's UDP info query from the client | host does both, Phase 3 | **high** |
| Dedicated servers with Steam auth | game connects directly (IP); auth session ticket checked by the server via Steam | works today with 0062 tickets once the client calls are real; Phase 3 | **high** |
| ISteamNetworkingSockets / Messages over **SDR** | relay network config from Steam's public web API; a networking certificate requested over CM; tickets per relay session; UDP to relays with pings to choose a route | host-native implementation (D4), Phase 4 | **medium**: the relay client protocol is the hard part; Valve publishes the sockets protocol as open source but not every relay detail; fall back to direct UDP/ICE where the game allows |
| P2P / ICE (direct) | signalling over Steam, then ICE (STUN/TURN-like) | host-native, Phase 4 | **medium** |
| Legacy ISteamNetworking P2P | Steam's client carries it over the same relays today | mapped onto the sockets layer, Phase 4 | **medium** |
| Game servers in the game (ISteamGameServer) | a separate anonymous or token game-server logon, heartbeats to the master server | host game-server session, Phase 5 | **medium**; listen servers behind the phone's NAT need relays anyway |
| Game coordinator (ISteamGameCoordinator) | protobuf messages wrapped in CM client↔GC messages | relay only (opaque payloads), Phase 5 | **high** for transport; the titles that use it are VAC titles (see below) |

All of it runs on the host (native arm64, iOS sockets), not under FEX: lower CPU, no extra guest
threads, and the certificate key stays on the host.

## DRM

- **SteamStub.** Keep removing it (`SteamStub`, x64 and x86 since PLA-99). With a real client
  behind steam_api the stub's own check would also need to find and query the client; removal is
  the same outcome for the player (0096's rule: outcome, not process), costs nothing at run time,
  and avoids running the stub's decryptor under FEX. Re-measure on desktop Wine in Phase 0 whether
  the stub's check passes against the shim; if it does, removal becomes optional per title.
- **CEG** (Custom Executable Generation). A CEG executable is tied to the account and calls into
  steam_api/steamclient to validate itself; the emulator cannot answer it, a real client
  path can. Unknown here: whether the depot's executable needs a per-account step at install
  (Steam's client does one) and which CM messages it needs. Phase 2 checks one CEG title found by
  the Phase 0 scan; until then CEG titles stay as they are.
- **Becomes unnecessary:** the emulator's `steam_settings/` (persona, DLC, achievements schema
  files), `configs.user.ini` with its `ticket=` line (0017's channel; the ticket comes live),
  `.orig` swaps of steam_api, and the "Steam API: the game's own" warning on the game page.
- **Third-party DRM** (Denuvo, publisher wrappers) is unchanged: those that only need steam_api to
  answer ownership benefit; online activation still needs the network.

## Anti-cheat

- **VAC.** On Windows, Steam's client loads VAC modules into the game; under Proton on Linux,
  VAC titles play on VAC-secured servers. Playport's client loads no VAC module and cannot. What a
  VAC server or the CM does when a client reports no VAC presence is **unknown**; the outcome could
  be a refused connection ("unable to verify game session") or, at worst, an account flag. Risk is
  to the owner's account. **Rule (decision D5):** online VAC titles are tested first on non-secure
  servers (`-insecure` listen servers, community servers with VAC off), then on VAC-secured servers
  only with a dedicated test account the owner provides, never the owner's main account, and never
  in competitive matchmaking.
- **Easy Anti-Cheat and BattlEye.** Their Proton support loads a native Linux runtime into Wine
  and is enabled per game by its developer; neither exists for iOS, and a kernel component is
  impossible. **Not possible.** Keep refusing these titles with a message, as Epic titles are
  refused today (0059).
- **Counter-Strike 2: offline bots are a Phase 5 goal; online is not a target** (Review
  2026-10-13: owner decision D9). Online play is VAC-secured matchmaking through the game
  coordinator with a trust system that a third-party client would be judged by, and the account-ban
  risk falls on the owner's account, so it stays out. The offline-bots goal carries the costs the
  draft named: 76 GB, and Source 2 at a CPU/GPU load that may be beyond the phone's measured
  headroom (a hypothesis until Phase 5 measures it).

## Online play from other stores

Kept proportionate: these games do not use the Steam bridge, so they get one section and their
own issues. Their titles are in the same reference set and measured the same way.

- **Epic (EOS).** The game's EOS SDK talks to Epic's services directly over HTTPS and its own
  sockets; Playport's part is the sign-in it already gives (the exchange code on the command line,
  [0059](../decisions/0059-epic-exchange-code.md)) and a correct network stack. Open:
  nothing from the earlier issues: PLA-40 (guest TLS) closed on 2026-10-13, since EOS signs in
  (Snakebird, Among Us; its `UnexpectedError` was the AccountPortal web page, decision 0064), and
  PLA-69 (a failed sidecar refresh hid Epic's update) was fixed the same day (1f12076). EOS
  sign-in in more titles and P2P are O1's work. EOS P2P and its relays are EOS's own (no Playport
  component), so they need only UDP sockets and the NSI tables (PLA-27 done). **Easy Anti-Cheat
  through EOS:** not possible, as above; keep 0059's refusal.
- **GOG Galaxy.** The Galaxy SDK talks to the local Galaxy service the host serves while the game
  runs ([0063](../decisions/0063-gog-galaxy-sign-in.md)), then to GOG's back ends directly
  for lobbies, chat and multiplayer. PLA-55 (the SDK connects but never sends) closed on
  2026-10-13: wine-unix 0018 fixed it, and Monster Train signs in to Galaxy. Remaining: Galaxy lobbies and P2P are the
  SDK's own traffic to GOG (sockets only), but a split SDK's peer library (`LIBRARY_INFO`) is
  answered "not available" today; a lobby game that needs it fails there. One GOG lobby title
  measures it.
- **Own backends** (PlayFab, Photon, custom servers): no store component; they need correct
  sockets (TCP, UDP, IPv6), TLS (the guest roots, PLA-40's work) and WebSockets through Wine's
  `winhttp`/`websocket`. A sweep of the reference set's own-backend titles finds what is missing.
- **Launcher-gated** (Ubisoft Connect, EA app, Battle.net, Rockstar), including Steam and Epic
  copies that start through them: the launcher is a Chromium app with a resident service; without
  running it, its game will not start (the launcher holds the session and the game asks it for a
  token over local IPC). Running it costs the Chromium memory option A was rejected for, and its
  sign-in stays in the guest (Review 2026-10-13: the launcher plan's D6 keeps it inside 0004, no
  host secret crosses). **Decided (D10, 2026-10-13):** refuse with
  a message naming the launcher, as 0059 does for Epic catalogue entries, and record each such title
  as Broken (launcher) in Compatibility, until [PLA-254](https://linear.app/playportdev/issue/PLA-254)
  has a working launcher for that publisher; its titles then run through it. Titles whose launcher
  can be skipped by starting the game's executable (the 2K launcher) are not launcher-gated: start
  the executable directly, as Proton users do.

## Phases

Each phase is its own Linear issue, a sub-issue of [PLA-253](https://linear.app/playportdev/issue/PLA-253). Effort is in
working days of one agent session plus phone gates, for the shape above; it widens if Phase 0's
answers go the other way.

| Phase | Issue | Acceptance | Phone gate | Effort |
|---|---|---|---|---|
| **0** | [PLA-262](https://linear.app/playportdev/issue/PLA-262) *Steam bridge: decisions, baselines and the full interface scan* | Owner decisions D1–D10 answered (done 2026-10-13); the decision record amending 0004/0062 drafted; scan re-run on every reference title; desktop Proton baselines recorded per title and feature row; `IsSteamRunning` pid approach and the SteamStub-against-shim question answered on desktop Wine | none (host only) | 4–6 d |
| **1** | [PLA-257](https://linear.app/playportdev/issue/PLA-257) *Steam bridge slice: a game's own steam_api through Playport's steamclient (x86-64; User, Apps, Utils, callbacks)* | Shim (x86-64), generator for ISteamClient/User/Apps/Utils at every version the scan found, the unix table (madeira-unix patch + WineHost), `SteamGameBridge` with snapshot, queue and call results; tickets moved from the emulator path; mode `client` on the game page; host tests for every block and the generated vtable layouts | Hollow Knight `client` first-frame+10, log shows `SteamAPI_Init` true, SteamID, ownership, one callback and one call result delivered; an online-ticket title from the set `client` gets a live auth ticket through the real steam_api; Hollow Knight and Portal 2 default (`emulated`) unchanged | 8–12 d |
| **1b** | [PLA-258](https://linear.app/playportdev/issue/PLA-258) *Steam bridge: i386 (WoW64) and SDK breadth* | i386 shim and thunks (`__thiscall`), WoW64 address check, every interface version the scan found generated (missing ones logged, not crashing) | Half-Life and one more i386 title from the set `client` to menu; a newest-SDK x86-64 title from the set to menu | 5–8 d |
| **2** | [PLA-264](https://linear.app/playportdev/issue/PLA-264) *Steam bridge: single-player parity (Friends, UserStats live, RemoteStorage, live encrypted app ticket, CEG check)* | Persona/friends/rich presence, stats and achievements stored live, Cloud files in Steam's layout synced around the play, encrypted ticket with the game's data, overlay URLs to the web sheet; default flips to `client` for single-player titles in the set that pass | Each S title: outcome rows Same as Proton; an achievement unlocked on the phone shows on Steam within the play; a Cloud save round-trips phone→desktop→phone | 8–12 d |
| **3** | [PLA-265](https://linear.app/playportdev/issue/PLA-265) *Steam bridge: lobbies, server browser and Steam-auth servers* | Matchmaking and MatchmakingServers services; master list and server queries on the host; VAC rule in effect | A lobby title: phone creates, desktop joins and the reverse; Half-Life: server browser lists, joins a non-secure server; the online row of a legacy-P2P or lobby title from the set | 8–10 d |
| **4** | [PLA-255](https://linear.app/playportdev/issue/PLA-255) *Steam bridge: networking sockets, SDR relays and P2P* | Host-native sockets layer (D4), networking certificate over CM, relay config and routing, ICE fallback, legacy P2P mapped; default flips for online titles that pass | Valheim joins a desktop-hosted world over Steam networking; Portal 2 co-op phone↔desktop; a legacy-P2P lobby title plays 5 min | 15–25 d |
| **5** | [PLA-263](https://linear.app/playportdev/issue/PLA-263) *Steam bridge: game servers, game coordinator, Workshop and Inventory* | Game-server logon, GC relay, UGC subscribe/download, Inventory read; Counter-Strike 2 against offline bots (D9) | Dota Underlords reaches its online lobby; TF2 per the VAC rule; one Workshop title loads a subscribed item; Counter-Strike 2 plays a match against offline bots | 10–15 d (CS2 not estimated) |
| **6** | [PLA-256](https://linear.app/playportdev/issue/PLA-256) *Retire the Steam API emulator* | Right after the bridge is proven (D7): no title needs `emulated`; `patches/gbe`, `build/stages/steamapi.sh`, `SteamAPISwap`'s swap path and 0017's ini channel removed (records amended) | Reference set re-run on the release candidate | 2–3 d |
| **O1** | [PLA-259](https://linear.app/playportdev/issue/PLA-259) *EOS online: measure EOS sign-in and P2P* | EOS sign-in shown in a game log; an EOS P2P/lobby title plays online or the blocker is filed | an EOS title from the set signs in; one EOS online title | 3–6 d |
| **O2** | [PLA-260](https://linear.app/playportdev/issue/PLA-260) *GOG Galaxy online: lobbies and the peer library* | A Galaxy lobby title measured; `LIBRARY_INFO` answered if a title needs it (own decision if it adds a secret) | One GOG lobby title phone↔desktop | 3–6 d |
| **O3** | [PLA-261](https://linear.app/playportdev/issue/PLA-261) *Own-backend online sweep (sockets, TLS, WebSockets)* | Every B title's online row recorded; each gap filed | B titles in the set | 3–5 d |
| **O4** | [PLA-266](https://linear.app/playportdev/issue/PLA-266) *Launcher-gated titles: refuse with a message* | Detection of Ubisoft Connect/EA app/Battle.net/Rockstar launch chains on Steam and Epic copies; a page message; Compatibility entries | One Steam and one Epic launcher-gated title show the message | 2–3 d |

Phases 3 and 4 can run in either order after 2; O1–O4 are independent of the bridge and can run
any time. Review 2026-10-13: with the decisions taken, Phase 1 can start; Phase 0's remaining host
work (the decision record amending 0004/0062, the full scan, the desktop Wine checks) is not
started. Its desktop Proton baselines need the workstation's Steam sign-in on the second account
(D8), which the owner creates when Phase 3 starts. Every phase that changes the runtime or the
launch path keeps the Hollow Knight and Portal 2 first-frame+10 gate (AGENTS.md).

## Risks

- **ABI surface.** Hundreds of (interface, version, method) thunks; a wrong slot or calling
  convention is a crash far from its cause. Mitigation: generated from Valve's headers, host tests
  that compare generated layouts with an MSVC-ABI reference (vtable offsets, struct sizes), and a
  log of every missing version.
- **Protocol drift.** CM messages and the relay protocol change on Valve's schedule; the pinned
  schema approach (`Wire/Schemas.swift`) turns a change into `protocolChanged`, not a crash.
- **Account risk** from a third-party client acting live for a game (lobbies, stats, GC). Mitigation:
  the per-interface allow-list, rate limits, the VAC rule, a test account for anything VAC.
- **Battery/thermal:** a live CM session plus relays during play; measure on Wi-Fi and cellular.
- **The emulator's features that a real client does differently** (offline saves under
  `GSE Saves`): Phase 2 migrates a title's emulator saves into Steam's layout once, keeping a backup.
- **Size of Phase 4.** SDR is the largest unknown; if it slips, Phases 3 and 5 still deliver
  lobby-plus-dedicated-server and GC titles.

## Owner decisions (decided 2026-10-13)

**Decided by the owner, 2026-10-13:**
- D1–D6, D8 and D10 as recommended below. For D10, launcher-gated titles are refused with a message until [PLA-254](https://linear.app/playportdev/issue/PLA-254) has a working launcher for that publisher; they then run through it.
- Two answers differ from the recommendations:
  - **D7:** remove the emulator right after the bridge is proven to work.
  - **D9:** Counter-Strike 2 with offline bots is a named goal of Phase 5.
- The second account (D5 and D8) is created by the owner when Phase 3 starts.

| # | Decision | Recommended default | Decided 2026-10-13 |
|---|---|---|---|
| D1 | Widen 0062: the live session acts for the launched app beyond tickets (lobbies, stats, friends, GC, networking), with a per-interface allow-list | Yes, by a new decision record in Phase 0, scoped to the launched app | As recommended |
| D2 | Option B over option A | B (this plan) | As recommended |
| D3 | Source of Steamworks SDK headers for the generator (Valve's SDK download needs a Steamworks account; redistribution terms) | Fetch the SDK in the build area as a locked input, commit only generated tables of offsets/ids, not Valve's headers; check LICENSING.md with the owner | As recommended |
| D4 | Networking implementation: Playport's own Swift/C, or Valve's open-source networking-sockets library built for iOS (BSD-3) plus Playport's relay client | Valve's library for the sockets protocol, Playport's code for what it lacks; a licensing note in LICENSING.md | As recommended |
| D5 | Testing VAC titles online | Non-secure servers first; VAC-secured only with a dedicated test account from the owner; never competitive matchmaking | As recommended; the owner creates the test account when Phase 3 starts |
| D6 | `SteamAPI_IsSteamRunning`: pid of an existing guest process, a runtime answer, or a guest `steam.exe` | The cheapest that passes on desktop Wine, in that order | As recommended |
| D7 | When to remove the emulator | After Phase 5 and two weeks with no `emulated` override in use | **Differs:** right after the bridge is proven to work |
| D8 | A second Steam account (and a desktop Steam sign-in on the workstation) for phone↔desktop multiplayer and Proton baselines | Yes: a separate test account owning the online reference titles (free titles first); the workstation's Steam sign-in authorised for that account only (HOST-DEBUGGING.md's rules) | As recommended; the owner creates the account when Phase 3 starts |
| D9 | Counter-Strike 2 | Not a target; an offline-bots stretch check after Phase 5 at most | **Differs:** offline bots are a named goal of Phase 5 (online stays out) |
| D10 | Launcher-gated titles | Refuse with a message; no launcher runs in the guest | As recommended, until [PLA-254](https://linear.app/playportdev/issue/PLA-254) has a working launcher for that publisher; those titles then run through it |

## Open questions (not determinable from the workstation now)

- Which interfaces the unscanned reference titles use (managed assemblies and most Steam titles
  were not pulled): Phase 0.
- Whether SteamStub's check passes against the shim, and what CEG needs at install and at run.
- What VAC servers and the CM do with a client that reports no VAC presence.
- Whether every WoW64 guest address is readable from the host as is under Madeira.
- The SDR relay client's authentication details beyond Valve's public documentation.
- Whether `Steam_BGetCallback`'s polling rate (games call `RunCallbacks` each frame) costs measurable
  CPU through FEX's unix-call transition; the poll is one call per frame per pipe.
