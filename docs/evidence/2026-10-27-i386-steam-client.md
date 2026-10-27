# i386 titles on Playport's Steam client (PLA-442)

**Result:** with defaults (Steam API mode `client`, decision 0153), three i386 Steam titles load
Playport's new i386 `steamclient.dll`. Their genuine `steam_api.dll` reaches `SteamAPI_Init()`,
and each game reaches its menu or title screen. Portal 2, which stopped at "Steam is not running"
in PLA-432, shows its main menu. Hollow Knight (x86-64) passes the smoke gate on the same IPA
through the regenerated `steamclient64.dll`.

IPA: `.work/out/20261027-075850-52a9945d/Playport-26.5-52a9945d.ipa` (dev), sha256
`52a9945d05cbad33d616016d47810ad244c429d1b90f939db47a8e18dbdba025`, commit `5c2347b` (branch
`dev/pla-442-i386-steam-client`). Decision [0161](../decisions/0161-steam-client-for-i386-and-every-interface.md).

## Phone runs (iPhone18,4, iOS 27.0.1)

| Title | Run | Result |
| --- | --- | --- |
| Hollow Knight (367520), x86-64 | `.work/ui-runs/20261027T075952` | first frame +12.58 s; `steamclient64.dll` (640,000 bytes) loaded by its steam_api64; SteamClient017/021 served; logged on, tickets armed |
| Half-Life (70), i386, `-gl` | `.work/ui-runs/20261027T080141` | first frame +9.57 s; at first-frame+20 the main menu (New game … Quit). `steamclient.dll` mapped at guest `0x78ca0000`, its unix table through WoW64 (`[unixlib] … steamclient.dll WoW64`); `SteamAPI_Init(): Loaded '…\steamclient.dll' OK`; SteamClient017/020, SteamUser021/023, SteamApps008, SteamFriends017, SteamInput006 served |
| Castle Crashers Demo (207100), i386 | `.work/ui-runs/20261027T080342` | first frame +7.97 s; "Press Start" title screen at first-frame+20; logged on, tickets armed |
| Portal 2 (620), i386 | `.work/ui-runs/20261027T080734` | first frame +8.93 s; main menu (Play single player … Quit) at first-frame+30; no "Steam is not running"; SteamUserStats012, SteamRemoteStorage016, SteamNetworking006 and the rest served; logged on, tickets armed |

Half-Life's client said `not logged on`: the app armed no ticket session for app 70. That is the
title's own ownership-ticket problem (PLA-25: `AccessDenied`), not the i386 client; the two other
i386 titles were logged on. The game still started.

Each run logs about 100–180 `not served, answers 0` lines (ISteamInput, rich presence, launch
command line …): the allow-list of decision 0115, now with method names for every interface.

## Host checks

- `tools/tests/test_steamclient_abi.py` (desktop Wine): every slot of all 248 versions called as
  MSVC code calls it, with `this` in ECX/RCX and its stack arguments. 7,414 calls on i386 pop exactly
  their arguments, return classes through the hidden pointer, and leave the x87 stack balanced. A
  table with one wrong word count fails it.
- Genuine i386 `steam_api.dll` files under desktop Wine with `steamclient.dll` in
  `ActiveProcess\SteamClientDll`: Half-Life's (SDK 1.5x, SteamClient020) and two older SDKs'
  (SteamClient017, SteamUser018) return `SteamAPI_Init` = 1. Before the deprecated getters were
  served, the older ones returned 0: `DEPRECATED_GetISteamUnifiedMessages` answered NULL. An older
  x86-64 steam_api64.dll (SteamClient017) also returns 1.
- `pp test --quick` passed; `pp build` verify: 90 checks.

## Not checked

Gameplay past the menus; cloud saves through the client for these titles; the RDR2 launcher on
this IPA (RDR2 was uninstalled to make room for Portal 2).
