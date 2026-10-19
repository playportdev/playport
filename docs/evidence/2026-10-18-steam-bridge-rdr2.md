# Playport's Steam client answers Red Dead Redemption 2's launcher (PLA-398)

**Linear:** [PLA-398](https://linear.app/playportdev/issue/PLA-398) (under
[PLA-253](https://linear.app/playportdev/issue/PLA-253)).
**Plan:** [Steam bridge for RDR2](../plans/finished.md#steam-bridge-for-rdr2).
**Change:** decision [0115](../decisions/0115-a-steam-client-for-the-launched-app.md),
`app/SteamClientShim`, `patches/madeira-unix` 0158, WineHost `steam_client.c`, the session root's
`PP_REQUEST_STEAM_CLIENT`. Branch `dev/pla-291-rockstar-launcher`.

**Question:** With a Playport `steamclient64.dll` in the prefix, does the Rockstar Games Launcher
that Red Dead Redemption 2's Steam copy (app 1174180) starts get past `SteamAPI_Init` and reach
Social Club's Sign In page?

**Answer so far:** it gets past Steam. The launcher's own `steam_api64.dll` finds the client,
loads it, binds its unix table, and `SteamAPI_Init` succeeds with a live, Steam-acked auth session
ticket. The Sign In page was not reached: in these runs the launcher ran on DXMT (the session
cleared the dev build's saved RDR2 settings, which had held Vulkan) and ended itself with exit
code 3 seven seconds in. The game's compatibility default is now Vulkan, as the launcher's Open;
that is not yet run on the phone.

## Desktop check first (desktop Wine 11.19, scratch prefix, no display, no Steam sign-in)

A probe exe called `SteamAPI_Init` through a genuine `steam_api64.dll` (SDK 1.57 from a game the
workstation already held, then the launcher's own copy) with the `Valve\Steam` keys and the shim
in `C:\Program Files (x86)\Steam`:

- `IsSteamRunning` 1, `SteamAPI_Init` 1; steam_api asked for `SteamClient017` and `SteamClient020`,
  `SteamUtils010`, `SteamUser021`/`022`, `STEAMAPPS_INTERFACE_VERSION008`, then `SteamController008`
  and `SteamInput006` (stubs) from `RunCallbacks`.
- With a dead `pid`: "did not locate a running instance of Steam", but the client still loads.
  With no `SteamClientDll64`: "Could not determine Steam client install directory".

## Phone runs (dev IPAs, `pp phone lock` sessions)

| Run | IPA sha256 | What |
| --- | --- | --- |
| `20261018T111300` | `d45589b20f4d41b134f44215f5df3c2adc4301415ec54b02f21d586c9cb34f10` | Hollow Knight, emulated: first frame at +10.37 s, `steamapi: emulated: emulated` |
| `20261018T111413` | same | RDR2, client: the root wrote `ActiveProcess` pid 32; the launcher's steam_api still "did not locate…" and "Could not determine Steam client install directory"; the hive held every value |
| `20261018T112347` | same | RDR2 with `env.WINEDEBUG=+reg` (diagnosis): the launcher opens `HKCU\Software` with access `0x20119` (`KEY_WOW64_64KEY`) and the runtime walks it into `Software\Wow6432Node`, where `Valve` is absent |
| `20261018T113016` | `de687aed609879479b5ca269a284b631eea93b5a9114b94f790cf97db7db9e2c` | Hollow Knight, emulated: reached first frame+10 (unchanged) |
| `20261018T113131` | same | RDR2, client, keys in both views: see below |

Run `20261018T113131` (keys in both views, commit `60763bf`):

- `[S_API] SteamAPI_Init(): Loaded 'C:\Program Files (x86)\Steam\steamclient64.dll' OK`, then
  `[unixlib] module … (steamclient64.dll) -> playport_steamclient_unix_call_funcs`.
- `steamclient: client connected (protocol 1) for app 1174180: steamid set, persona set, logged on,
  tickets armed, language english, encrypted app ticket none`.
- What the launcher asked: `SteamClient017`, `SteamClient020`, `SteamUtils010`, `SteamUser022`,
  `SteamFriends017`, `STEAMAPPS_INTERFACE_VERSION008` (served); `STEAMUSERSTATS_INTERFACE_VERSION012`
  and `SteamController008` (stubs, no method called); one auth session ticket (234 bytes), acked by
  Steam 0.3 s later. No `not served` slot line: every method it called is implemented.
- No "did not locate" or "Steam failed to initialize" line.
- Then `Launcher.exe` called `ExitProcess(3)` about 7 s after start, while Rockstar Service was
  starting, and `PlayRDR2.exe` showed "Unable to launch game, please try reinstalling the game."
  The launcher had loaded `d3d11`/`dxgi` with `winemetal` (DXMT), `wined3d` and `opengl32`: the run
  was on DXMT (`title: graphics: dxmt`). The PLA-364 run that reached "Steam failed to initialize"
  was on Vulkan, and the launcher's Open is Vulkan; round 1 (Steam not found) ended the same way
  on DXMT, so the exit follows the backend, not the client.

Screenshots (in the run directories, not committed): every RDR2 shot from 45 s to 240 s in
`111413` and `113131` shows only the Windows "Error" box with that text, OK and Help, on black.
No sign-in was attempted; no password was typed.

## Next

- RDR2 from the library on Vulkan (now its compatibility default) to the Sign In page.
- The runtime's `KEY_WOW64_64KEY` redirection into `Wow6432Node` for an x64 process is a runtime
  bug beyond Steam (any x64 program reading `HKCU\Software` that way): its own issue.

## Round 4: Vulkan by default (IPA `7f0caa62f5825054dd1f6549109e4e975e01dbf4eefe7ed58b4286c9a74ae06f`, HEAD `3ed58eb`)

One lock session (`phone-session-4.sh`). RDR2's saved settings were cleared for the session, so the
compatibility defaults chose Vulkan and `client`.

- Hollow Knight (`20261018T114431`): first frame +9.97 s.
- RDR2 from the Steam library (`20261018T114545`):
  - `graphics: vulkan` and `steamapi: client: original`. The session root is the prefix's Steam client.
  - The launcher's steam_api connected: logged on, tickets armed. It was served SteamClient017/020,
    Utils010, User022, Friends017 and Apps008, and got a 234-byte auth session ticket. UserStats012,
    Controller008 and Input006 got stubs, and two of their slots were called and answered 0.
  - First window at +7.60 s.
  - 60 s: Social Club's "Verify your email" page with its text, under the cookie notice. Rockstar
    recognised the Steam-linked account and sent a code to its address. No agent typed anything.
  - 90 s: the same page with the code field.
  - Rockstar's `launcher.log`: the account signed in at 09:48:15, the front end was told "external
    launch post-sign in", and the context went from Auth to MainWindow. 0.2 s later Launcher.exe ended on
    `Exception: 0xc0000096` (privileged instruction) in its main thread.
  - Host log: the main thread hit an AV read of 0 in FEX's fault sequence, and FEX turned it into
    `c0000096` at a guest address in Launcher.exe, which was unhandled. `NtTerminateProcess` was
    `0xc0000096`.
  - 150 s and 240 s: PlayRDR2.exe's "Unable to launch game, please try reinstalling the game."
  - Pool: head 504 MiB, tail 353 MiB, room 40 MiB; no exhaustion or refusals. Band peak 14,971 MB,
    0 refused.

The Steam bridge got the Steam copy past "Steam failed to initialize", through Social Club's account
check, to a signed-in launcher. The next blocker is the privileged-instruction exception right after
the main window opens.
