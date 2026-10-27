# 0161: Playport's Steam client for i386 titles, and for every interface version

**Status:** accepted, 2026-10-27, by the owner's request that 32-bit titles get the same Steam
client as 64-bit ones, with no workaround
([PLA-442](https://linear.app/playportdev/issue/PLA-442), after
[PLA-432](https://linear.app/playportdev/issue/PLA-432)). Amends
[0115](0115-a-steam-client-for-the-launched-app.md) (its "x86-64 only" consequence and its
interface list) and [0153](0153-rdr2s-settings-are-every-games-defaults.md) (`client` holds for an
i386 title too).

## Context

0153 made Playport's Steam client every game's default, but 0115's client was a
`steamclient64.dll` only. An i386 game's `steam_api.dll` loads `steamclient.dll` from
`ActiveProcess\SteamClientDll`, found none (`c0000135`), and the game said "Steam is not
running" (Portal 2, PLA-432). PLA-432's fix sent every i386 executable to the emulator instead
(`SteamAPISwap.launchMode`): no client for 32-bit titles at all.

Two more gaps showed when genuine i386 steam_api DLLs were run against the client under desktop
Wine, and they hit x86-64 games too:

- The slot table had ISteamClient 017–023, ISteamUser 017–023, ISteamUtils 007–011, ISteamApps
  007–009 and ISteamFriends 015–017. Every other interface (UserStats, RemoteStorage,
  Matchmaking, Networking, UGC, …) and every older version was a nameless stub.
- An older SDK's steam_api (SteamClient017 with SteamUser018) failed `SteamAPI_Init`: its context
  asks every getter, and `DEPRECATED_GetISteamUnifiedMessages` answered NULL.

## Decision

- **An i386 `steamclient.dll`** from the same source (`app/SteamClientShim/steamclient.c`, built
  by `steamclient.sh` with compiler-rt's builtins for 64-bit division), staged as
  `Runtime/steamclient/i386-windows/steamclient.dll` (P9-steamclient). A client-mode play gets both
  DLLs in `C:\Program Files (x86)\Steam\`, as Steam installs them, whatever the title's executable:
  a 32-bit game can start 64-bit helpers and the reverse. The keys already name both
  (`SteamClientDll`, `SteamClientDll64`), and the unix call table already takes a WoW64 caller.
- **No emulator fallback.** `SteamAPISwap.launchMode` is gone: an i386 title gets the mode its
  settings give, `client` by default.
- **i386 ABI.** MSVC calls an interface method with `this` in ECX and the callee pops its stack
  arguments. Every vtable slot is an assembler thunk that copies the caller's arguments, calls
  the served C method (cdecl, `this` first, as on x86-64) or the unserved answer, and pops what the
  table says that slot takes. An unserved slot that returns a float leaves 0.0 in st0; one that
  returns a class writes 8 zero bytes through the hidden pointer and returns it, as on x86-64.
- **Every version.** `build/steamclient-vtables.py` takes every version string gbe's getters name
  (`dll/steam_client_interface_getter.cpp`, `dll/dll.cpp`, in the pinned tree) and its class:
  248 versions of 244 classes. Per slot it records the name, the hidden-pointer return, the i386
  stack words (clang's own `__stdcall` decoration of the SDK signature; a virtual destructor's
  slot takes MSVC's flags word) and a float return; it checks that the i386 slot order is the
  x86-64 one. Served methods match a family exactly (`ISteamUser` is not `ISteamUserStats`).
- **Unknown versions.** x86-64 still answers a Steam-named version the table lacks with a stub of
  trampolines that answer 0. i386 answers NULL and logs it: a callee-pop slot cannot be answered
  without its argument size.
- **More of what an old steam_api asks.** The deprecated ISteamClient getters are served like the
  others (by argument count: `(pipe, version)` or `(user, pipe, version)`), SteamClient006's
  `CreateGlobalUser` is served, and the pre-1.2x exports `Steam_BLoggedOn`, `Steam_BConnected`,
  `Steam_CreateLocalUser`, `Steam_LogOn`, `Steam_LogOff`, `Steam_GetGSHandle`,
  `Steam_GSBLoggedOn`, `Steam_GSBSecure` and `Steam_GSGetSteamID` answer as the interfaces do.

## Consequences

- What crosses and what never crosses is 0115's, for i386 as for x86-64.
- `tools/tests/test_steamclient_abi.py` builds both DLLs and calls every slot of every version
  under desktop Wine as MSVC code would; it is skipped without llvm-mingw or wine.
- The DLLs are bigger (about 640 KB and 400 KB against 140 KB): the names of every slot of every
  version, for the log lines and the trace.
