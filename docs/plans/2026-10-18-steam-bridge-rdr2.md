# Steam client bridge for Red Dead Redemption 2's Steam copy

**Linear:** https://linear.app/playportdev/issue/PLA-398 (sub-issue of
[PLA-253](https://linear.app/playportdev/issue/PLA-253))

## Goal

Red Dead Redemption 2 bought on Steam (app 1174180), played from the Steam library on the phone,
reaches the Rockstar Games Launcher's Social Club Sign In page. Today the launcher's own
`steam_api64.dll` finds no Steam client (`SteamAPI_IsSteamRunning() did not locate a running
instance of Steam`) and the launcher says "Steam failed to initialize". This is the smallest slice
of the [Steam client bridge](2026-10-12-steamclient-bridge.md) (option B) that answers it: a
Playport `steamclient64.dll` in the prefix that serves the game's and the launcher's genuine
`steam_api64.dll` for the launched app only. Owner approved every decision on this path on
2026-10-18 ([decision 0115](../decisions/0115-a-steam-client-for-the-launched-app.md)).

## Chunks

| Chunk | What | Gate |
| --- | --- | --- |
| C0 | Decision 0115; `SteamAPISwap.Mode.client`; compat default `steamAPI: client` for app 1174180 (also in release); the game page's Steam API row; the ticket session for `client`; a game started through a publisher launcher inherits its Open's grace, graphics environment and runtime keys (`PublisherLauncher.games`) | host tests |
| C1 | x86-64 `steamclient64.dll` shim in C (`app/SteamClientShim`, build stage `steamclient.sh`, `Runtime/steamclient/`, IPA check); vtable slots generated from gbe's pinned SDK headers (`build/steamclient-vtables.py`, only the generated slot table is committed); madeira-unix patch giving a `steamclient` module its unix table; WineHost `steam_client.c` with `steam_client_protocol.h`; Swift `SteamClientHost` (snapshot plus the play's `SteamTicketBroker`) | host C tests for the blocks and the slot table; `./pp build` |
| C2 | Prefix: `Valve\Steam` keys topped up (`SteamPath`, `SteamExe`, `ActiveProcess` `SteamClientDll`/`SteamClientDll64`, `ActiveUser`); `ActiveProcess\pid` set by the session root (`PP_REQUEST_STEAM_CLIENT`) to its own id, cleared at the title's end and at session start; the shim copied to `C:\Program Files (x86)\Steam\` (client mode only) | session protocol and registry tests |
| C3 | `pp test --quick`, names, secrets, `./pp build`; one phone session: Hollow Knight first-frame+10 (emulated, unchanged), RDR2 from the Steam library to the Sign In page; up to 3 log-driven rounds | the log shows the steamclient unix table bound, HELLO, no `did not locate`, no "Steam failed to initialize"; screenshots |
| C4 | Tickets (auth/web API through the broker, the encrypted app ticket) only where C3's log asks | the same phone gate |

## Rules

Never sign in or type the Rockstar password; Story mode only; stop at the Sign In page. Public
SDK headers and logs only, no analysis of closed binaries. Nothing crosses beyond 0115's list.
No pool size or rpmalloc change.

## Progress

- 2026-10-18: plan written. C0–C2 done (`e97073c`, `05a9d97`, `7345956`, `60763bf`); C3 three phone
  rounds ([evidence](../evidence/2026-10-18-steam-bridge-rdr2.md)): the launcher's steam_api now loads
  Playport's client, `SteamAPI_Init` succeeds and a live auth ticket is acked; no Sign In yet: the
  runs were on DXMT, where the launcher exits with code 3. Fixes found by the runs: the
  `Valve\Steam` keys in both views of `HKCU\Software` (this runtime redirects `KEY_WOW64_64KEY`
  into `Wow6432Node`), and Vulkan as the game's compatibility default.
- **Handoff:** build, install, and play RDR2 from the library (Vulkan, client) through
  `mark:first window+240` with screenshots; stop at the Sign In page. C4 (tickets) only if that run
  asks. The Wow6432Node redirection needs its own runtime issue.
