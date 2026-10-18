# 0115: A Steam client in the prefix for the launched app (Red Dead Redemption 2 first)

**Status:** accepted, 2026-10-18, by the owner's approval of every decision on the path for Red
Dead Redemption 2's Steam copy to reach Social Club's sign-in (PLA-398, under
[PLA-253](https://linear.app/playportdev/issue/PLA-253)). Amends [0004](0004-steam-session-boundary.md)
and [0062](0062-steam-live-session.md) (the Steam bridge plan's D1), and
[0112](0112-a-launchers-open-outlasts-a-pool-exhaustion.md),
[0114](0114-trim-social-clubs-chromium-and-the-launchers-threads.md) and
[0116](0116-tail-room-for-every-process-and-the-launchers-smc-checks.md) (Open only → also a game
the launcher starts). [Plan](../plans/2026-10-18-steam-bridge-rdr2.md),
[bridge plan](../plans/2026-10-12-steamclient-bridge.md).

## Context

Red Dead Redemption 2 bought on Steam (app 1174180) starts `PlayRDR2.exe`, which starts the
Rockstar Games Launcher with `-steamAppId=1174180`. The launcher loads its own genuine
`Launcher\ThirdParty\Steam\steam_api64.dll`, outside the game's folder, which `SteamAPISwap` never
touches. That steam_api looks for a running Steam client through `HKCU\Software\Valve\Steam`
(`ActiveProcess\pid`, `SteamClientDll64`, `SteamPath`), finds none, and the launcher stops with
"Steam failed to initialize" before its sign-in page. The emulator cannot answer it: the
launcher is not the game's folder, and the emulator is a steam_api, not a client. The standalone
launcher Open reaches the sign-in page (decisions 0112, 0114, 0116).

## Decision

- **A Playport `steamclient64.dll`** (x86-64, plain C, llvm-mingw; `app/SteamClientShim`, the build
  stage `steamclient.sh`, `Runtime/steamclient/x86_64-windows/`) is placed at
  `C:\Program Files (x86)\Steam\` and serves any genuine steam_api in the session, for the
  launched app ID only. The launched app's genuine chain (`PlayRDR2.exe` → `Launcher.exe` →
  the game) counts as that app.
- **Mode.** `SteamAPISwap.Mode.client` ("Playport's Steam client"): the game's own steam_api
  DLLs (the same swap state as `original`), SteamStub still removed (as `emulated`), the prefix's
  Steam folder and keys written. App 1174180's compatibility default is `client`, and the release
  app takes a compatibility default of `client` (it still forces `emulated` otherwise).
- **What crosses**, as Steam's own client gives it to a game: the SteamID, the persona name, the
  logged-on state, ownership of the launched app (and its DLC list), the language, auth session and
  web API tickets through the play's `SteamTicketBroker` (0062's rules and limits), and the
  encrypted app ticket fetched at Play as 0017 fetches it (without the game's `userdata`, served
  as an at-once call result).
- **Never crosses:** the refresh or access token, the CM session key or connection, machine or
  session bindings, CDN or depot keys, another app's tickets.
- **Allow-list.** Only the methods the shim implements answer from the host; every other method
  slot of a known interface answers 0 (false, none, not logged on) and logs its interface, version
  and slot; an unknown interface version gets NULL and a log line. Threat model as 0004: the guest
  is the game the player started, scoped to its app ID.
- **`SteamAPI_IsSteamRunning` (D6).** `ActiveProcess\pid` is the session root's process id
  (`playport-session.exe` lives through the whole play, no extra process or pool). The root writes
  it, with `ActiveUser` (the account ID), on `PP_REQUEST_STEAM_CLIENT`, and sets both to 0 at the
  title's end and at its own start, so a later `original`-mode game never meets a stale id. The
  static keys (`SteamPath`, `SteamExe`, `ActiveProcess\SteamClientDll`, `SteamClientDll64`) are
  `PrefixRegistryFile` top-ups. All of it only when the mode is `client`. Every key is written in
  both views of `HKCU\Software` (also under `Software\Wow6432Node\Valve\Steam`): on this runtime
  an x64 process's 64-bit-view read (`KEY_WOW64_64KEY`, as the Rockstar launcher's steam_api asks)
  is sent into `Wow6432Node` (run `20261018T112347`, Wine's `reg` channel), where Windows would not
  look; the runtime's redirection is its own issue.
- **Unix calls.** A new madeira-unix patch gives a module whose export name contains
  `steamclient` the table `playport_steamclient_unix_call_funcs` (WineHost `steam_client.c`,
  `steam_client_protocol.h`), as 0087 does for `steam_api`; the launcher's genuine steam_api also
  matches 0087 but never asks for a unix library. Blocks keep 0087's rules (magic, size, version,
  fixed fields, no pointers): HELLO (the snapshot), CALL (tickets, the encrypted app ticket), POLL
  (a ticket's state for its callback). Callbacks and call results are made by the shim, guest side:
  nothing on the host answers later yet. The host provider (`SteamClientHost`) answers from a lock,
  never waiting on the network.
- **Interface layout (D3).** Slots are generated from the public Steamworks SDK headers already
  pinned as gbe's `sdk/` (MSVC x64 ABI, by `build/steamclient-vtables.py`); only the generated
  slot table is committed, not Valve's headers.
- **A game started through a publisher launcher** inherits that launcher's Open settings: the
  exhaustion grace (0112), the graphics environment (0114) and the runtime keys (0116), under the
  game's own. The link is data (`PublisherLauncher.games`), not an app ID check in the launch.
- **D10 is met for Rockstar**: with a working Rockstar launcher (PLA-394), its Steam titles run
  through it rather than being refused.

## Consequences

- Titles in `emulated` mode are unchanged; the emulator ignores the `Valve\Steam` keys, and the
  root writes `pid` only for a `client` play.
- The shim is x86-64 only; an i386 client is the bridge plan's phase 1b.
- The slot table covers `ISteamClient` 017–023, `ISteamUser` 017–023, `ISteamUtils` 007–011 and
  `ISteamApps` 007–009; anything else a run asks for is logged and found from the logs.
- The encrypted app ticket carries no `userdata` until the bridge's phase 2.
