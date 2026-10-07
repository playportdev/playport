# A game's web page in Playport's panel: Snakebird's EOS signs in (decision 0064)

**Date:** 2026-10-07. **IPA:** dev `6eb4929ea7ed88eb92b205b936abb7c163afd159dedfdab005cfaff8da962b22`
(the committed tree; release `19e8091427facdaa2589a21fb8f367e2faa1a510a57dc32de5ad94c8e7633fc2`,
`pp verify --variant release`: 0 failures). The session was unattended (`pp phone unattended on`).
Code: madeira-unix 0092 and 0093, WineHost ABI 5, `app/UrlOpener`, `UrlOpenerHost`,
`UI/GameWebSheet.swift`, `Dev/WebSheetDriver.swift`; the arm64ec `cryptsp.dll` staged; the
`-epicovt` file holds Epic's JSON reply.

## The guest-to-host path (IPA 27f6158d, chunks 1–5, no panel yet)

A Snakebird Complete play logged, from the game's EOS sign-in:

    NtCreateUserProcess: image=L"C:\\windows\\system32\\playport-url-opener.exe" cmdline=L"... \"https://www.epicgames.com/activate?*****************\""
    [jit-pool] x64 image ... playport-url-opener.exe: no pool copy
    [unixlib] module ... (playport-url-opener.exe) -> playport_url_unix_call_funcs
    url: ... INFO [open] open www.epicgames.com/activate (epic-activation) for Snakebird Complete

So the prefix's seeded `https` handler runs the opener, the runtime gives it the table by its
export name, the query is masked in the process lines, and the host logs host and path only.
Hollow Knight on the same IPA: first frame at 9.40 s, no `url:` line.

## The panel and the consent

First tries (IPAs ff59b754, 9288d51d, d39e1bed): the panel came up over the running game
("Signed in to Epic" in its bar, host `www.epicgames.com`), `/id/exchange` signed it in
(Epic's `/id/api/account` answered 200), the device page went on to `/id/authorize`, and then
to `/id/login` with the session gone (401, "Sign in to Epic Games"). Loading the device page
first and signing in only once it asked made no difference.

**Cause, measured with WebKit on the workstation** (WebKit2GTK, an ephemeral store, the
workstation's Epic session, a real device flow started with Snakebird's EOS client:
`deviceAuthorization` answers `prompt: login`, `verification_uri_complete`
`www.epicgames.com/activate?userCode=…`, 600 s): with a desktop user agent the flow reaches
`/id/authorize` with an Allow button and stays signed in; with an iPhone's (with or without
`Safari/`) it goes authorize → `/id/login` → `/id/login/switch-account` → `/id/login`, account
401. The panel now gives Epic's sign-in pages desktop Safari's user agent.

IPA fd6fcb22, then 6eb4929e:

    url: ... [open] open www.epicgames.com/activate (epic-activation) for Snakebird Complete
    url: ... [sheet] up over Snakebird Complete: www.epicgames.com (epic-activation, Epic sign-in)
    url: ... [sheet] signed in to Epic for the page (exchange code fetched)
    url: ... [sheet] page www.epicgames.com/id/exchange
    url: ... [sheet] page www.epicgames.com/id/activate
    ui: web: www.epicgames.com/id/authorize (Signed in to Epic; account 200, ...)
    ui: web: clicked "Allow" on www.epicgames.com/id/authorize
    ui: web: now www.epicgames.com/id/activate/complete

The exchange code took 0.15 s. The screenshots (in the run directory, not committed): the
panel over the game, its bar with the back arrow, a lock, `www.epicgames.com`, "Signed in to
Epic", Close and Ⓑ; under it Epic's page "Snakebird Complete wants access to your Epic Games
account" with the game's and Epic's logos, "With your permission, Epic Games will allow
Snakebird Complete to:"; after Allow, Epic's page loading over the game's level (the game
drawing behind the dimmed edge). So the consent the workstation gave earlier was asked again
for this device flow.

On fd6fcb22 the game then ended `0x80000100` 23 s in: `wine: Call from ... to unimplemented
function cryptsp.dll.SystemFunction032` from advapi32: EOS storing its refresh token in the
Credential Manager, whose encryption delay-loads `cryptsp.dll`, which the app did not stage.
6eb4929e stages the arm64ec `cryptsp.dll` (`EXTRA_PE`), and the same play then ran to the end
of the driver's actions (`ui: done ... ok actions=6`). Snakebird's `Player.log`:

    Tried to login auth: Success
    Logged in to connect

**Second play** (no web actions, `--until first-frame+30`, first frame 4.53 s): no `url:` line,
and `Player.log` again `Tried to login auth: Success` and `Logged in to connect`: the silent
sign-in from the refresh token in the prefix.

## The secrets

- The pulled `s1-host.log` of every run of the day, and the three `Player.log` copies: no
  `userCode=` followed by a value, no `exchangeCode=` or `AUTH_PASSWORD=` with 32 hex digits.
- The container over AFC after the plays (a scratch script, house arrest): 15 445 files
  (81.2 GB) walked, the 42 modified since the first panel play read whole, searched for an
  unmasked `userCode=` value, an exchange code in a URL or argument (ASCII and UTF-16LE) and
  an `egoc1~` token: **0 hits**. EOS's own refresh token is in the prefix's registry, as 0064
  records; it was not searched for (its value is the game's).

## Regressions

| Title | Run | Result |
| --- | --- | --- |
| Hollow Knight | `--until first-frame+10 --shot` | first frame 9.39 s; the title menu (Start Game, Options, Achievements, Extras, Quit Game) |
| Death's Door | `--until first-frame+10 --shot` | exchange code in 0.39 s; first frame 4.21 s; its title menu (Start, Options, Exit) |
| Snakebird Complete | the two plays above | first frame 4.5 s each; signs in to EOS |

## Jurassic World Evolution and the ownership token file

The workstation found (`.work/agent-notes/store-auth/jwe-launcher/report.md`) that JWE's
hidden window is its DRM's error 88500000: the DRM wants Epic's whole reply in the `-epicovt`
file, `{"token":"…"}`, not the bare token. The file now holds the reply: `title: epic: the
ownership token (852 bytes) written to playport-epic.ovt` (was 840). After the plays the
prefix has `AppData\Local\EpicGamesLauncher\3954555031` (5572 bytes), the licence cache the
DRM writes only after a good check, as on the workstation. The game still shows **no frame**
in 600 s (`--until first-frame+90`, no stop condition): after the check its log shows
`\pipe\lrpc\lsasspirpc` and `\pipe\svcctl` not found and a TLS connection on 443 abandoned
after 48 ms, then the launcher-folder probe again; it idles at about 12 % CPU. An earlier run
of the same IPA was disturbed by the owner's use of the phone and is not counted. Open.

## Not measured

- A release build's play (a person taps Allow): the release IPA was verified only.
- An i386 game's page (the opener is not in `syswow64`).
- The confirm card for a non-Epic page, and B on a controller: host tests and code only.
