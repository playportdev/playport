# Plan: games sign in to their store (Epic exchange code, Steam tickets)

**Date:** 2026-10-06. **Kind:** plan, not started. **Blocks:** the 0.4.0 release (owner,
2026-10-06: "the stores update can't ship without these"). `main` carries the 0.4.0
version and `docs/releases/0.4.0.md` (`b21f63d`); nothing is built or drafted. **Decisions:**
0059 (Epic exchange code) is written here; [0017](../decisions/0017-encrypted-app-ticket.md)
(Steam encrypted app ticket, proposed) is accepted or amended here; 0062 (a live Steam
session during play) is written only if step 0 calls for it. 0060 and 0061 are taken on
`vulkan-performance`.

## Goal and the owner's direction

Playport aims to run every game Proton runs. Only kernel anti-cheat (EasyAntiCheat,
BattlEye) and games that need another company's launcher stay out. Today two kinds of
game are lost to the session boundary
([0004](../decisions/0004-steam-session-boundary.md),
[0058](../decisions/0058-store-sessions.md)), not to the runtime:

- **Epic.** A game whose catalogue sets `OwnershipToken=true` or `CanRunOffline=false` is
  refused on its page ("This game needs Epic online sign-in…",
  `EpicLibrary.swift`). In the owner's library: Borderlands 3, Guardians of the Galaxy,
  Football Manager 2022 and its tools, Jurassic World Evolution, Star Trek Online
  ([evidence](../evidence/2026-10-06-epic-games.md)). Every other Epic game launches with
  no exchange code, so one that uses Epic Online Services (achievements, friends, online
  play) runs signed out of them.
- **Steam.** gbe_fork answers `GetEncryptedAppTicket` and `GetAuthSessionTicket` with
  made-up tickets. A game whose servers check either one refuses its online part: an
  online account, cross-play, matchmaking. The offline game runs.

Done means: a game gets from its store what the store's own launcher would give it at
launch, by default, and the refusal above is left only for anti-cheat and third-party
launchers. Decision 0004's rule (no host session secret in the guest) keeps holding for
the session itself: the refresh and access tokens never cross. What crosses is a
game-scoped, short-lived credential, by one channel each.

## What the store launchers pass (to confirm in step 1)

**Epic**, from the launcher's command line and open-source Epic launchers:

- `-AUTH_LOGIN=unused -AUTH_PASSWORD=<exchange code> -AUTH_TYPE=exchangecode`. The code
  comes from `GET /account/api/oauth/exchange` on Epic's account service with the host's
  access token. It is one-time and lasts about 5 minutes. The game trades it, with its
  own EOS client identity, for its own session.
- `-epicapp`, `-epicenv=Prod`, `-EpicPortal`, `-epicusername=<display name>`,
  `-epicuserid=<account ID>`, `-epiclocale`, `-epicsandboxid=<namespace>`. Today
  Playport passes the first three and the locale.
- For `OwnershipToken=true`: `-epicovt=<path>` to a file holding the ownership token,
  fetched with `POST …/ecommerceintegration/api/public/platforms/EPIC/identities/<account
  ID>/ownershipToken` (form `nsCatalogItemId=<namespace>:<catalog item ID>`) and written
  before launch.

**Steam**:

- The **encrypted app ticket**: 0017 describes it (one file line, written at launch,
  removed at exit).
- The **auth session ticket** (`GetAuthSessionTicket`): what most online games send to
  their servers, which ask Steam (`AuthenticateUserTicket`) whether it is valid. Steam
  says yes only while the issuing client is logged on and has reported the ticket
  (`ClientAuthList`). Playport closes the Steam session before the runtime starts
  (`suspendForLaunch`), so a ticket made on the host before launch is likely dead by the
  time the server checks it. Step 0 measures this.

**GOG** games are DRM-free and start with no credential. Galaxy SDK features (achievements,
GOG multiplayer) need the GOG Galaxy client. Step 0 counts the games in the owner's library
that need them; they are out of this plan unless the owner adds them.

## Steps

**0. Survey (workstation, no phone).** For each store, list the owner's games and what
each needs at launch:
- Epic: the catalogue attributes already read (`OwnershipToken`, `CanRunOffline`), plus
  which games carry the EOS SDK (`EOSSDK-Win64-Shipping.dll`) in their manifest.
- Steam: which owned games import `GetEncryptedAppTicket`, `GetAuthSessionTicket` or
  `BeginAuthSession` from `steam_api64.dll` (their import tables, from the depot files
  already on the phone or fetched from the manifests), and which of them are online-only.
- GOG: which games ship `Galaxy64.dll`.

Write `docs/evidence/<date>-store-game-auth-survey.md`. The owner then picks the test
titles (below) and says whether a live Steam session during play (step 4) is in the 0.4.0
gate.

**1. Epic exchange code: decision 0059 and the launch (host only).**
- Write 0059 as 0017 is written: the secrets (exchange code; ownership token), the threat
  model, the one channel, guest-side storage, sign-out, revocation. The threat to state:
  everything runs in one process (0004), so guest code can read the code from the command
  line (the `PEB`, Wine's process list) before the game redeems it. Any Epic client can
  redeem it, which would give a session on the account, so the code's 5 minutes, its
  single use and the game redeeming it at once are the bound. The ownership token proves
  ownership of one item only.
- On by default for every Epic game, as Epic's launcher does. No per-game switch unless
  0059's review asks for one.
- `EpicSession.exchangeCode()` and `EpicSession.ownershipToken(namespace:catalogItem:)`;
  `EpicInstaller.arguments` gains the auth arguments, `-epicusername`, `-epicuserid` and
  `-epicsandboxid`. The ovt file goes in the game's own folder under the prefix, is
  written after Play and removed at exit, at the next launch and app start, and at
  sign-out (0017's pattern).
- `Redactor` already scrubs `exchangeCode`; add the `-AUTH_PASSWORD=` argument, the ovt
  path's contents and the ownership token to it and its tests. The launch log prints the
  arguments with the code redacted.
- Remove the refusal for `OwnershipToken`/`CanRunOffline`. Keep the refusals for
  anti-cheat and for third-party launchers (Roller Champions, Trackmania), and give
  those their own messages.
- If the exchange-code fetch fails, the game does not start: the page says Epic could not
  sign the game in, with Try again. It does not start the game signed out.

**2. Steam encrypted app ticket: 0017 accepted (host only).** Amend 0017 so the ticket is
on by default, not per game. The owner's direction outranks the record's switch; the
review keeps a per-game off switch only if the measurement in step 5 finds a copy outside
the ini line. Implement 0017's phase 5 as written (`LaunchCoordinator` writes the line;
removal at exit, next launch, app start and sign-out). Amend 0004 to point at 0017 and
0059.

**3. Steam auth session tickets, the short form (host only).** If step 0 shows a ticket
made before launch is still accepted while Steam's session is closed (try it from the
workstation: make one with the host client, close the session, call
`AuthenticateUserTicket` with a public test app), hand a small batch to gbe_fork through
the same ini file as 0017 and let `GetAuthSessionTicket` give them out in order. A gbe
patch (`patches/gbe`) may be needed for this; 0017's record covers the channel. If such
tickets are not accepted, go to step 4.

**4. A live Steam session during play (decision 0062, only if steps 0 and 3 call for
it).** The host keeps the CM connection up during a play, on its own thread. A new
`wine_host` entry lets gbe_fork ask the host for an auth session ticket, which the host
makes and reports (`ClientAuthList`), and cancel it. No token crosses; the ABI carries
only the ticket bytes. 0062 changes 0004's suspension rule and needs its own threat
model: guest code can now ask the host for tickets for the running app. This step is
large (the host network thread during play, JIT and thermals with it on). The owner
decides after step 0 whether it gates 0.4.0 or follows.

**5. On the phone (one session per gate, `pp phone lock`).**
- Epic: the test title signs in and plays to `first-frame+10` and on into its menu,
  where its online part shows the account (Jurassic World Evolution or Football Manager
  2022, the lighter of those that fit `MemoryNeed`; Borderlands 3 if it fits). Death's
  Door again, now with a code. After each play: search the prefix and the container for
  the exchange code, the ownership token and the ovt file (0017's measurement).
- Steam: the test title from step 0 reaches its online menu with the account signed in.
  Hollow Knight to `first-frame+10` (no regression). The same search for the ticket.
- Sign-out from each store removes every leftover file.
- Write `docs/evidence/<date>-store-game-auth.md` with the IPA's sha256.

**6. Release.** Update `docs/releases/0.4.0.md` (the Epic refusal paragraph becomes what
now works; the Steam online part), then `pp release 0.4.0` from a clean, pushed `main`
in its own build area (`PLAYPORT_BUILD`, a fresh `run/`: the live `run/`'s CMake caches
hold absolute paths).

## Order and size

| Step | Needs | Size |
| --- | --- | --- |
| 0 Survey | workstation, store sessions | small |
| 1 Epic 0059 + launch | 0 (test title) | medium |
| 2 Steam 0017 | none | small (designed) |
| 3 Auth tickets, short form | 0 | small if tickets survive the session, else 4 |
| 4 Live Steam session (0062) | 3 fails, owner | large |
| 5 Phone gates | 1, 2 (3 or 4) | one session each |
| 6 Release | 5 | about 15 min build |

Steps 1 and 2 are independent and can run in parallel.

## Risks

- Epic may tie an exchange code to the device or reject one fetched with the
  desktop-client identity for a game's EOS client. Step 1's first workstation call shows
  it.
- A game may launch fine with the code and still fail in EOS on Wine/iOS for other
  reasons (EOS overlay, its web views). That is a runtime issue for its own plan, not a
  refusal.
- Heavy Epic titles in the owner's library (Borderlands 3, Guardians of the Galaxy) may
  not fit `MemoryNeed`. The gate needs one title that fits.
- Step 4 keeps a network thread busy during play, with costs for power and heat.

## Not in this plan

Kernel anti-cheat; games that install another company's launcher; GOG Galaxy online
features (unless the owner adds them after step 0); Epic and GOG cloud saves (the PC
import plan's 2.4 and 3.7).

## Open (owner)

- After step 0: is step 4 (a live Steam session during play) in the 0.4.0 gate?
- After step 0: are GOG Galaxy features in scope?
