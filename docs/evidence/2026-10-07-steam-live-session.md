# Evidence: a live Steam session during play (decision 0062)

**Date:** 2026-10-07. **IPA:** `Playport-26.5-74c28bf7.ipa` (dev), sha256
`74c28bf7da22866df2436f85c0acdd0178e606fd27b3e1a1e9305551adebdea0`, built from the step 4
code committed in `086c59c` and `624cc35` (madeira-unix 0087, gbe 0006, WineHost ABI 4).
Phone: iPhone18,4, iOS 27.0, Wi-Fi, on charge. Steam signed in with the owner's account.
Run directories are under `$PLAYPORT_BUILD/ui-runs/` and `$PLAYPORT_BUILD/perf-runs/`;
screenshots stay there.

## P1: Hollow Knight (`app-367520`)

`pp ui --play app-367520 --until first-frame+10 --shot` (`20261007T125857`): JIT 2.53 s,
runtime +3.53 s, first frame +8.69 s, the title menu as before. The logs show, in order:

    [ticket] app 367520: no encrypted app ticket: ClientRequestEncryptedAppTicket 367520: EResult Fail
    [ticket] app 367520: tickets armed: ownership ticket 178 bytes, 10 game connect token(s), in 0.30 s
    [service] suspended for a title launch; CM kept for the game's tickets
    title: ticket: auth session and web API tickets armed; the CM session stays logged on for them
    [unixlib] module 0x73f62a0000 (steam_api64.dll) -> playport_steam_unix_call_funcs (0x1093c9b70)
    steam: ... INFO [emulator] emulator connected (protocol 1, tickets armed)

So the x86-64 emulator's `__wine_unix_call` reaches the host's table through ARM64EC
ntdll on the first play. Arming costs 0.29–0.41 s after Play (five plays).

The CM's traffic, logged at the play's end (`endPlay`, reached through the in-game menu's
Quit game):

| Run | Play | CM in / out | Tickets |
| --- | --- | --- | --- |
| `20261007T125950` (Hollow Knight, wait 15 s, Quit) | 49 s | 7 / 6 | 0 |
| `20261007T131552` (Hollow Knight, wait 120 s, Quit) | 119 s | 8 / 17 | 0 |
| `20261007T131411` (Among Us, to its crash) | 17 s | 20 / 14 | 0 |

Out is mostly the 9 s heartbeat (Steam set 9 s at every logon) plus `ClientGamesPlayed`;
in is Steam's pushes. Hollow Knight asks for no ticket, so none was made.

In `20261007T125950` the CM socket closed 16 s into the play (`websocket receive: 53`,
ECONNABORTED on the phone's side), before the menu was opened; the play's end then could
not reach Steam (`the play's end not sent to Steam`), and the next start logged on
normally. In the perf run (138 s) and the 119 s play it stayed up. Its cause is not known;
a game that asks for a ticket after such a drop gets the reconnect (0062), which no run
exercised (S3 below).

## `pp perf --title app-367520 --secs 120` (`perf-runs/steam-live-1`)

With the live session: 59.3 fps mean, 60.0 median and p10 (one 43.6 fps bucket at
t = 10 s, the load), frame time 16.69 ms, GPU 8.64 ms, CPU about 110 % (mostly E cores),
about 185 mW CPU in the play, thermal nominal throughout, hitches ≥ 25/50/100 ms
66/3/1, battery 100 % on charge. The CM stayed connected the whole run.

No run with the session closed was made: there is no switch for it (0062, on for every
game), and making one for a measurement would be a launch mode. `docs/evidence` has no
Hollow Knight perf run on this build line to compare with (the 2026-10-06 fastsync record
measured Portal 2). By the play's timings (first frame +8.69 to +9.71 s in four plays,
against about 10 s in AGENTS.md) and a 60 fps median, the session costs the play nothing
visible; a few messages each 9 s is all it adds.

## Among Us (`app-945360`)

- **Binaries** (pulled from the phone; not kept in the repository): `GameAssembly.dll` is
  PE32+ x86-64 and the game's `steam_api64.dll.orig` is 64-bit, so the WoW64 branch is not
  needed for it (it is in place for i386 games anyway). IL2CPP's `global-metadata.dat`
  names `OnSteamEncryptedAppTicketLoginCallback`, `OnSteamEncryptedAppTicketLoginCallbackRetry`
  and `SteamworksAppTicketFail`; its Steamworks.NET has no `GetAuthTicketForWebApi` at all
  (an SDK before 1.57). `GetAuthSessionTicket` appears only as the wrapper's own names.
  Among Us signs in to its servers with the **encrypted app ticket** (0017), not with a
  session or web API ticket.
- **Play** (`20261007T131411`): the encrypted app ticket (142 bytes) written, tickets
  armed, `emulator connected (protocol 1, tickets armed)`, first frame +14.98 s, then the
  PLA-39 fault at 17 s (`exit=0xc000001d`). No CREATE, no ack, no `ClientTicketAuthComplete`
  (`play ended: 0 ticket(s) made`), as the static strings predict. Its online menu is not
  reached (PLA-39, PLA-40).
- An earlier play (`20261007T130811`) drew no frame in 300 s and never loaded
  `steam_api64.dll` (threads spinning in `UnityPlayer.dll` and `sentry.dll`); the driver
  ended it. Not this work: the emulator was never loaded. The ticket line it left was
  removed at the next app start (`ticket: 1 removed at app start`).

So no title on the phone has exercised a ticket yet: S1 needs a game that calls
`GetAuthSessionTicket` or `GetAuthTicketForWebApi` for its own servers.

## S2: the container search

After the plays, every file in the app's container modified since the session began
(43 of 15,590, 39 MB) was searched for the ticket's fixed session header as the host builds
it (`u32 24, u32 1, u32 2` and the type-5 form): the host's tickets live in memory only,
so there are no bytes of one to search for. The only hits are the two copies of the
emulator's own `steam_api64.dll` (the same 27 occurrences in each, in its code), copied
into the games' folders at each launch. No log, save, registry hive or app file holds one.

## S3 and S4

- **S3** (the Home Screen for 60 s mid-play, then a ticket): not run. `pp ui` has no way to
  put the app in the background, and adding one would be a launch path outside the UI
  (decision 0012). The reconnect is covered by the host tests only.
- **S4** (a kill mid-play): every `--until` run ends the app by killing it mid-play. After
  each, the next start logged on normally (`logged on as acct#… heartbeat 9s`), and the
  encrypted app ticket a kill left was removed at that start.

## Not checked

A ticket made and acked by Steam, a server's check (5429), the reconnect, cellular power.
