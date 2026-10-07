# Evidence: a game's Steam auth session ticket made by the host (Valheim, decision 0062)

**Date:** 2026-10-07. **IPAs:** `Playport-26.5-6eb4929e.ipa` (dev), sha256
`6eb4929ea7ed88eb92b205b936abb7c163afd159dedfdab005cfaff8da962b22` (plays 1 and 2, Soccer
Online: Ball 3D); `77ba6ce0…` (`77ba6ce03e9e53b8bcb661857c02211a84ee8ba260fbbaf58b63108b2dec4d20`,
play 3, with `sspicli.dll` staged); `Playport-26.5-baf1dfa1.ipa`, sha256
`baf1dfa16c6a2dff04f5a1226544c3f7847560a6690762382ca1426e868a6d22` (play 4, HEAD of the GOG
step). Phone: iPhone18,4, iOS 27.0, Wi-Fi, on charge, unattended. Steam signed in with the
owner's account. Run directories are under `$PLAYPORT_BUILD/agent-notes/store-auth/`
(`valheim/`, `ball3d/`, `final/valheim`); screenshots stay there.

Step 4 of the [store game sign-in plan](../plans/2026-10-06-store-game-auth.md) left S1 open:
no game had asked the host for a ticket. This record is the first that did.

## Valheim (Steam 892970, Unity x86-64)

Installed through the UI (`pp ui --action install:892970`): 4.54 GB in 161 s, `app-892970`,
`valheim.exe`. Four plays to `--until first-frame+60 --shot`: first frame at +6.8 to +6.9 s
(the intro cinematic), then the game ends `0xc0000005` 15 to 16 s after Play, each time.

The host's lines, of the same form in all four plays (play 4, IPA `baf1dfa1`, shown):

    steam: … [emulator] emulator connected (protocol 1, tickets armed)
    steam: … [ticket] ticket 1347420161: auth session for app 892970, 240 bytes; 9 token(s) left
    steam: … [ticket] auth list acked by Steam: 1 ticket(s), handle(s) 1347420161
    steam: … [ticket] play ended: 1 ticket(s) made, 1 live at the end, 1 ack(s), 0 server check(s)
    steam: … [ticket] cm: 17 in / 12 out during the play

So a game's `GetAuthSessionTicket` reached the host through gbe's unix call (0062), the host
built a 240-byte ticket from a game connect token and the app's ownership ticket, reported it
in `ClientAuthList`, and Steam acknowledged it 0.3 s later. No server checked it
(`ClientTicketAuthComplete` never came): the game died about a second later. The ticket's
handle is the same in every play (the emulator's numbering starts again each play).

The game's `Player.log` (`users/playport/AppData/LocalLow/IronGate/Valheim`): `Steam
initialized`, `Sending PlayFab login request (attempt 1)` (its crossplay sign-in, which uses
the ticket), then its crash handler (`Crash!!!`, a jump to address 1, no stack:
`RtlLookupFunctionEntry returned NULL`), then `Session auth respons callback` from the main
thread. So the PlayFab login's result was never logged.

- On IPA `6eb4929e` the log also showed `DllNotFoundException: PartyWin32` (PlayFab Party):
  `import_dll Library SspiCli.dll (which is needed by …PartyWin32.dll) not found`. The arm64ec
  `sspicli.dll` is now staged (`EXTRA_PE`, commit `fc465fb`); on IPA `77ba6ce0` and later
  SspiCli.dll and PartyWin32.dll load and the exception is gone, but the crash is unchanged.
  Its cause is not known; it is runtime work, not the ticket's (Linear).

## Back-ups

- **Soccer Online: Ball 3D** (Steam 485610): installed through the UI (439 MB, 14 s); its play
  stayed alive with no first frame for 600 s (a 320×240 window, `[win-pos]`), the emulator
  connected and no ticket was asked for.
- **Battlerite** (504370): not tried; the chunk's 30-minute box was spent.

## What is left of S1

A server checking one of the host's tickets (`server check(s)` above 0) is still unseen: the
title that made one dies before using it. The ticket's layout was not compared with a real
client's: nothing refused it.

## Play 5: on DXMT a server checks the ticket (S1 seen)

The crash above is on Vulkan, which Valheim gets by default here: DXVK calls a NULL
`vkGetMemoryWin32HandleKHR` for the intro video's shared texture (fixed on the unmerged
vulkan-performance branch, not on this one). Play 5 (IPA `baf1dfa1`, the same build as play 4)
set the game page's Direct3D to DXMT through the UI (`pp ui --settings
'app-892970:{"graphics":"dxmt"}' --play app-892970 --until first-frame+120 --shot`; the host
logs `library: play Valheim (app-892970) on dxmt`). First frame at +6.7 s; the game ran the
full 138 s until the driver ended it, with no fault. The stop screenshot shows the intro
cinematic still playing (subtitles), so the main menu was not reached in 120 s; the run
directory is `$PLAYPORT_BUILD/agent-notes/store-auth/valheim-dxmt/play1`.

The host's lines (`s1-host.log`):

    steam: 17:01:44.938Z [emulator] emulator connected (protocol 1, tickets armed)
    steam: 17:01:56.083Z [ticket] ticket 1347420161: auth session for app 892970, 240 bytes; 9 token(s) left
    steam: 17:01:56.443Z [ticket] auth list acked by Steam: 1 ticket(s), handle(s) 1347420161
    steam: 17:02:02.318Z [ticket] ticket 1347420161 checked by a server: EAuthSessionResponse 0 (OK), state 2
    steam: 17:02:02.454Z [ticket] ticket 1347420161: cancelled by the game; 0 live
    steam: 17:02:03.235Z [ticket] auth list acked by Steam: 0 ticket(s)
    steam: 17:02:03.419Z [ticket] ticket 1347420162: auth session for app 892970, 240 bytes; 9 token(s) left
    steam: 17:02:03.814Z [ticket] auth list acked by Steam: 1 ticket(s), handle(s) 1347420162
    steam: 17:02:04.229Z [ticket] ticket 1347420162 checked by a server: EAuthSessionResponse 0 (OK), state 2
    steam: 17:02:09.491Z [ticket] ticket 1347420162: cancelled by the game; 0 live
    steam: 17:02:09.803Z [ticket] auth list acked by Steam: 0 ticket(s)

The game's `Player.log` (pulled with `pp phone pull` after the run; local time, UTC+2):

    19:01:54: Steam initialized, persona:…
    19:01:56: Sending PlayFab login request (attempt 1)
    19:02:01: Session auth respons callback
    19:02:02: Failed to logged in PlayFab user via Steam auth session ticket: /Client/LoginWithSteam: HTTP/1.1 409 Conflict
    19:02:02: PlayFab login failed! Retrying in 0.9594418s, total attempts: 1
    19:02:02: Released session ticket
    19:02:03: Sending PlayFab login request (attempt 2)
    19:02:03: Session auth respons callback
    19:02:09: Logged in PlayFab user via Steam auth session ticket
    19:02:09: PlayFab local entity ID is …
    19:02:09: Released session ticket

So S1 is seen: PlayFab's `LoginWithSteam` sent each of the host's tickets to Steam's web API,
Steam told the host each was checked (`ClientTicketAuthComplete`, `EAuthSessionResponse` OK),
and the game's crossplay sign-in succeeded on its second attempt with the second ticket. The
first attempt's `409 Conflict` came from PlayFab after Steam had passed the ticket (the host's
`OK` at 17:02:02.318 precedes it), so it is PlayFab's answer to the request, not a refused
ticket; the logs do not say more. No `play ended: …` line: the driver ended the app, and the
host writes that line when the game exits. This replaces "What is left of S1" above.

Direct3D stays DXMT on Valheim's page (saved with `--keep-settings`; its page shows `DXMT`,
"Changed for this game"): on this branch Vulkan fails every play at the intro, so DXMT is
the only way it plays here.
