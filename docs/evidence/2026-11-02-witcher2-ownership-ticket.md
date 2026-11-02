# The Witcher 2: Steam's app ownership ticket gets its SteamStub payload past the Steam check

**Linear:** [PLA-798](https://linear.app/playportdev/issue/PLA-798),
[PLA-478](https://linear.app/playportdev/issue/PLA-478) (The Witcher 2, 20920).

## Before

With madeira-unix 0287 (the WoW64 commit fix,
[2026-11-02-wow64-commit-pages.md](2026-11-02-wow64-commit-pages.md)), `witcher2.exe`'s unpacker
stub runs its payload. The payload asks Playport's Steam client for
`ISteamAppTicket::GetAppOwnershipTicketData`, gets 0, shows "Steam Error: Application load error
6:0000065432" and exits (run `$PLAYPORT_BUILD/ui-runs/20261102T1345-w2-commitfix`).

## Change

`steamclient.c` serves `GetAppOwnershipTicketData` for the launched app. It returns the ownership
ticket Steam gave the play (EMsg 857/858, already fetched by `prepareTicketSession` for the auth
tickets and held by `SteamTicketBroker`). The new CALL method `PP_SC_OWNERSHIP_TICKET` carries it.
The answer gives the offsets of the ticket's fields: the SteamID at 8, the app ID at 16, and the
signature at the ticket's leading length (the signed part, which counts the length field itself);
the rest is the signature. The game already receives the same bytes inside every auth session
ticket.

## On the phone

Dev IPA `4d2a7a13d62dbdf4fe631002df38848808e05a5caa406fceca6ae0c0fa044d4b` (branch
`dev/pla-798-w2-phone`: main `a8500239` + madeira-unix 0287 + this change), iPhone18,4, iOS 27.2,
The Witcher 2 (20920) from Steam. Run `$PLAYPORT_BUILD/ui-runs/20261102T1359-w2-ownership`
(`pp ui --pad --play app-20920 --until 'mark:first window+20' --leave-running`, then
`pp pad send '600 A'` on the launcher; log in `pull2/`):

```
steamclient: STEAMAPPTICKET_INTERFACE_VERSION001: served (through ISteamClient)
steamclient: ownership ticket: 178 bytes
steamclient: app ownership ticket: 178 bytes, signed part 50
```

The ticket's signed part is 50 bytes and its signature 128 bytes. No "Steam Error" box appears.
The payload goes on to the game, which connects to the Steam client a second time (SteamUser014,
SteamFriends008, SteamUserStats009, SteamApps004, SteamRemoteStorage004) and reaches
`title: +61.21 s first frame`. The screenshot 60 s after A (`after-a-60.png`) shows the opening
cinematic at 60 FPS / 16.7 ms on the overlay.

Unserved calls logged after the check (none of them stopped the run): `ISteamUserStats009`
`FindOrCreateLeaderboard` and `RequestCurrentStats`, `ISteamRemoteStorage004` `GetFileCount`.
Gameplay, the menus and saves were not checked.

Hollow Knight passed the smoke check on the same IPA: first frame at +9.63 s
(`$PLAYPORT_BUILD/ui-runs/20261102T140146`).
