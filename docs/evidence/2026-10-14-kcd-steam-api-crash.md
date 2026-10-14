# Evidence: Kingdom Come's crash in the Steam API emulator, and steam_interfaces.txt

**Date:** 2026-10-14. **Kind:** a static analysis of the crash logs and the emulator
DLL, host unit tests, and phone runs (dev app).
**Linear:** [PLA-350](https://linear.app/playportdev/issue/PLA-350) (blocks step 4 of
[PLA-216](https://linear.app/playportdev/issue/PLA-216)).
**Branch:** `dev/pla-350-kcd-steam-api` (from `main` `5f9339b`).
**IPA (dev):** `7c4436fd685a080a4a6fb374cd8c832b227b7f1db756bbed64e34d29ac2c2202`.
iPhone18,4, iOS 27.0.1. Run directories are under `$PLAYPORT_BUILD/agent-notes/`.

## The crash

Kingdom Come: Deliverance (379430) exited `0xc0000005` about 11–12 s after the game
started, with no first frame, in both step-4 runs of the donor-memory plan (IPA
`195d5698…`, branch `research/extended-memory`; run directories
`donor-memory/runs/old-step4/kcd-pool-off` and `kcd-pool-6144`,
[2026-10-14-donor-pool-kcd.md](2026-10-14-donor-pool-kcd.md)):

```
[exc-disp] raise tid=0100 code=c0000005 … p0=0 p1=1f4
[guest-exact] … rip=0x73f9214760 x86=41 83 3f 00 …     cmp dword [r15],0
[unixlib] module 0x73f9060000 (steam_api64.dll) -> playport_steam_unix_call_funcs
NtTerminateProcess(handle=0xffffffffffffffff, exit_code=0xc0000005)
```

The last good launch was 2026-10-04 (IPA `9057b91f`).

## Cause

PLA-350 was reasoned out statically from the emulator code, which `main` and
`research/extended-memory` share byte for byte (no difference in `patches/gbe`,
`build/stages`, `app/SteamClient` or `SteamAPISwap`). It was not reproduced on an IPA
built from `main`.

- `rip − base = 0x1b4760` in the staged `steam_api64.dll` (the same file the build
  stages, sections ending at `0x80b000` as the phone's image). It is in gbe_fork's
  `Steam_User::GetAuthSessionTicket(void *pTicket, int cbMaxTicket, uint32 *pcbTicket,
  const SteamNetworkingIdentity *)`, the four-argument form of SteamUser022 and later.
  `r15` is the identity, loaded from the fifth argument slot. The call after it is
  `steam_networking_utils->SteamNetworkingIdentity_ToString(…, 0x80)`.
- gbe patch 0006 (`624cc35`, on 2026-10-07, after the last good launch) added that
  read: `if (pSteamNetworkingIdentity && !pSteamNetworkingIdentity->IsInvalid())`.
  Before it, the identity was never read.
- On the guest stack (SRA `rsp` `0x710486fcc0`), the return address is
  `0x73f58ed921` in `WHGame.dll`. The arguments are `cbMaxTicket = 0x400` and
  `pcbTicket` on the stack, and the fifth slot holds `0x1f4`. The game passed three
  arguments; `0x1f4` is a stale stack value.
- The game reaches the four-argument slot through the older SDK's exported accessor
  `SteamUser()`. gbe answers it with `old_user`, which is its newest version
  (`SteamUser023`) unless a `steam_interfaces.txt` names the game's own version.
  Playport's `SteamAPISwap` never wrote one. So every emulated game that calls the
  old accessors got gbe's newest interfaces. This did no harm until 0006 began
  reading the new fourth argument.

## Change

`SteamAPISwap.apply` now writes `steam_settings/steam_interfaces.txt` beside each
swapped DLL. The file is made from the kept `.orig` DLL the way gbe_fork's
`tools/generate_interfaces` does it at the gbe pin:

- the same name list in the same order (each name followed by digits, except
  `STEAMCONTROLLER_INTERFACE_VERSION`);
- every match in file order;
- the SteamClient017 rule.

When a DLL names no interface, no file is written. A `steam_interfaces.txt` that the
settings supply (`Settings.files`) is written as given. One that is already in the
folder is left alone. gbe patch 0006 is unchanged.

**This changes the interface versions of every emulated title:** a game that calls
the exported accessors (`SteamUser()`, `SteamFriends()`, `SteamClient()` and the rest)
now gets the versions its own `steam_api` names, not gbe's newest. Games that ask for
their interfaces by version string are not affected.

Tests (`SteamAPISwapTests`):

- `testAnOlderSDKsInterfaceVersionsAreWrittenFromTheKeptOriginal`: a
  SteamUser019-era DLL gets its versions in generate_interfaces order, and a DLL that
  names no interface gets no file.
- `testANewerSDKsInterfaceVersionsKeepOnlySteamClient017`: the SteamClient017 rule,
  and longer names are not taken for shorter ones.
- `testAGivenOrExistingInterfacesFileIsLeftAlone`.

`./pp test` passed.

## Phone (IPA `7c4436fd…`, one locked session)

| Run | Directory | Result |
| --- | --- | --- |
| Kingdom Come, `--until first-frame+10 --wait 300 --shot` | `pla350/runs/kcd-fix` | game started +5.61 s, **first frame +28.22 s**, until reached, exit 0. No `c0000005` in the log. Steam acked the game's auth session ticket (`ticket 1347420161: auth session for app 379430, 240 bytes`), so GetAuthSessionTicket now returns. The screenshot shows the Warhorse Studios intro logo. Peak `[xp] fpMB` 3639. |
| Hollow Knight, `--until first-frame+10 --shot` | `pla350/runs/hk-fix` | game started +4.01 s, first frame +10.81 s, until reached, exit 0. The screenshot shows the title menu (Start Game, Options, Achievements, Extras, Quit Game). Peak `[xp] fpMB` 2800. |

Both runs used the VC++ 2015 prerequisites as before (`exit code 666`, already
installed). The phone was at 80 % on power, with 3.3 GB free.

This proves that Kingdom Come starts on the fixed IPA. It does not show what the
game's `steam_interfaces.txt` holds: the file is only on the phone.

## Afterwards: Plaion's EULA (on `research/extended-memory`)

The first launches after this change, on IPA `f1f024ae…` (this fix merged
into `research/extended-memory`), showed a page Kingdom Come had not shown
before: Plaion's EULA, with a QR code and "Accept (A)". With the owner's
approval, it was accepted by script: one A after `pp pad wait-text` had read
"EULA" and "Accept". The main menu then had Continue, the save loaded
Rattay, and the EULA did not come back in the next two launches
([2026-10-14-donor-pool-kcd.md](2026-10-14-donor-pool-kcd.md)).

**Open question:** did the interfaces file make the game show it? With
its own SDK's versions, the game may no longer have seen a stored
acceptance. This was not checked. The save was still seen.
