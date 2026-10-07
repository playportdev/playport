# Evidence: games sign in to their store, the phone gates (plan step 6)

**Date:** 2026-10-07. **Final IPA:** `Playport-26.5-5eaca1e8.ipa` (dev), sha256
`5eaca1e843e91318f4c760034794e5be542816f9eaec760f2e543987d7f3e1ae`, built from `b75dd27`
(the [store game sign-in plan](../plans/2026-10-06-store-game-auth.md)'s last runtime change,
wine-unix 0018). Phone: iPhone18,4, iOS 27.0, on charge, unattended. Run directories are under
`$PLAYPORT_BUILD/ui-runs/` and `$PLAYPORT_BUILD/perf-runs/` (named below); screenshots stay
there. The release (plan step 7) is handed off to the owner: no release build, draft or push
was made. The release variant of this IPA was not built or checked.

## Per store

| Store | Proven | On which IPA | Record |
| --- | --- | --- | --- |
| Epic | The launch passes an exchange code (fetched in 0.4 to 0.6 s) and Epic's launcher arguments, and an `-epicovt` file with Epic's JSON ownership-token reply for an `OwnershipToken` game. Death's Door starts with a code: `exchange code fetched in 0.41 s`, the title menu (`5eaca1e8`). | `86208e93` (step 1), `6eb4929e` (the ovt as JSON), `5eaca1e8` | [epic-game-auth](2026-10-07-epic-game-auth.md), [url-opener](2026-10-07-url-opener.md) |
| Epic | **An EOS game signs in.** Snakebird Complete's first sign-in goes through Playport's web panel (AccountPortal device code, Epic's consent page, Allow). Each later play signs in silently: `Tried to login auth: Success`, `Logged in to connect`, the main menu at first frame +30 s (`5eaca1e8`). | `6eb4929e`, `5eaca1e8` | [url-opener](2026-10-07-url-opener.md) |
| Steam | **Encrypted app ticket.** Among Us gets a 143-byte ticket (0.22 s on `6b253ef0`). On `5eaca1e8` it was written again (`the encrypted app ticket (143 bytes) written to 1 configs.user.ini`); first frame +15.07 s, the play ran to its stop at first frame +10 s. Its online menu still waits on PLA-39. | `6b253ef0`, `5eaca1e8` | [steam-encrypted-app-ticket](2026-10-07-steam-encrypted-app-ticket.md) |
| Steam | **Auth session tickets checked by a server.** On DXMT (its page's Direct3D) Valheim's PlayFab login asks for a ticket. The host makes it (240 bytes) and Steam acks it, then `checked by a server: EAuthSessionResponse 0 (OK), state 2`. `Player.log`: `Logged in PlayFab user via Steam auth session ticket` (on `5eaca1e8` at the first attempt). | `baf1dfa1`, `5eaca1e8` | [steam-live-session](2026-10-07-steam-live-session.md), [steam-ticket-valheim](2026-10-07-steam-ticket-valheim.md) |
| GOG | **A Galaxy game signs in.** Moonscars and Monster Train connect to the host's service, send `AUTH_INFO` and get `200` with a freshly minted game token within 0.6 s (PLA-55, wine-unix 0018, on `5eaca1e8`). On `31eda60f` (PLA-58, wine-pe 0029: `InternetGetConnectedState` no longer answers "offline" without `\\.\Nsi`) the SDK then signs in at GOG: Moonscars' `Player.log` has `OnAuthSuccess()` and `GOG_SERVICES_CONNECTION_STATE_CONNECTED`, the service connection stays open with three web-broker subscriptions, and Monster Train reads `GET_USER_ACHIEVEMENTS -> 200 (16450 bytes)`. No achievement or stat was written. | `5eaca1e8`, `31eda60f` | [gog-galaxy](2026-10-07-gog-galaxy.md) |

The plan's gate, per title, on `5eaca1e8`:

| Gate | Title | Result |
| --- | --- | --- |
| Epic signs in and reaches its menu | Snakebird Complete | **passes**: first frame +4.95 s, silent EOS sign-in, main menu |
| Steam's title reaches its online menu signed in | Valheim (DXMT) | **passes the sign-in**: PlayFab logged in with the host's ticket. The main menu was not reached within first frame +60 s; the intro cinematic was still playing |
| GOG shows its Galaxy sign-in | Moonscars | **does not pass** on `5eaca1e8`: `AUTH_INFO -> 200`, then `OnAuthFailure(): FAILURE_REASON_CONNECTION_FAILURE`. **Passes on `31eda60f`** (PLA-58, wine-pe 0029): `OnAuthSuccess()`, `GOG_SERVICES_CONNECTION_STATE_CONNECTED`; Hollow Knight, Shogun Showdown, Valheim (DXMT, ticket checked, PlayFab) and Snakebird (EOS) replayed on it with the same results ([gog-galaxy](2026-10-07-gog-galaxy.md#pla-58-the-sdk-asks-whether-the-machine-is-online-wine-pe-0029)) |
| Hollow Knight to `first-frame+10` | Hollow Knight | **passes**: first frame +9.77 s, the title menu, `emulator connected (protocol 1, tickets armed)` |
| Death's Door to `first-frame+10` | Death's Door | **passes**: first frame +4.39 s, the title menu |
| Sign-out removes every leftover file | all three | **not run on the phone**: signing out would end sessions the owner pairs again. Host tests only |

The other plays on `5eaca1e8`:

- Shogun Showdown (GOG, no Galaxy DLL): first frame +19.02 s, "Press any button".
- Monster Train: first frame +4.25 s, a black screen at +60 s, as on earlier IPAs.
- Moonscars under `pp perf --secs 120`: median 60 fps. The poll costs the SDK thread about
  one percentage point of a core ([gog-galaxy](2026-10-07-gog-galaxy.md)).

## Secret searches (`5eaca1e8`, `31eda60f`)

Scratch scripts under `.work` (not committed) walked the app's container over AFC (house
arrest) after the plays. Each read every file modified since just before the session's first
play, and printed counts and paths only.

| Search | For | Files walked | Read | Hits |
| --- | --- | --- | --- | --- |
| after Moonscars and Monster Train | GOG token shapes (a 64-character mixed-case refresh token, a 150 to 400-character access token), `refresh_token`/`access_token`, in ASCII and UTF-16LE | 17,762 (89.0 GB) | 37 (21.5 MB) | **0** (two access-token-shape matches in the host log are Swift symbol names in a backtrace) |
| after Moonscars and Monster Train signed in (`31eda60f`) | the same | 17,785 (89.0 GB) | 44 (51.5 MB) | **0** (the shape matches are Swift symbol names in the host logs and C++ mangled names in Metal's shader cache) |
| after every play of the session, Snakebird, Death's Door and Among Us included | an unmasked `userCode=` value, an exchange code in a URL or argument (32 hex, ASCII and UTF-16LE), an `egoc1~` ownership token | 17,780 (89.0 GB) | 81 | **0** |

A second GOG search, after the last plays, was stopped part way: the owner needed the phone. It
counts as not run. The earlier records searched for Steam tickets and found none outside the
emulator's ini line (the encrypted app ticket, while the game runs) and its own DLL
([steam-encrypted-app-ticket](2026-10-07-steam-encrypted-app-ticket.md),
[steam-live-session](2026-10-07-steam-live-session.md)). That search was not repeated on
`5eaca1e8`. No search covers process memory.

## Still open

Each item names its Linear issue (team PLA).

- **PLA-50**: secur32 gets its security packages from an lsass service that the phone does not
  run (`start_samss Failed to open service manager`, `80090304`). It did not block the GOG
  sign-in (that was PLA-58, fixed by wine-pe 0029 on `31eda60f`) and does not affect TLS; it
  leaves no NTLM, Negotiate or Kerberos for a game that uses them.
- **PLA-58**: the NSI adapter table (`\\.\Nsi`) the phone lacks; wine-pe 0029 only answers
  `InternetGetConnectedState` without it.
- **PLA-41**: Jurassic World Evolution passes its DRM check but shows no frame in 600 s.
- **PLA-39**: Among Us's EOS client and its fault; its online menu has not been reached.
- **PLA-54**: Monster Train.
- **PLA-61**: Epic's `deploymentid`.
- **PLA-62**: the Steam live session's gaps (the reconnect after the background, S3, is
  host-tested only) and sign-out on the phone (host tests only).
- **PLA-60**: GOG B6 (an offline queue for unlocks and stats), B7 (the split SDK, Quake II) and
  writes (no achievement or stat has been written).
- **PLA-64**: the URL opener for i386 games (it is not in `syswow64`), and the UI no person has
  checked (a release play approved by a person).
- **PLA-57**: `pp ui --action install:gog-<id>` reports "done, but not in the library" for a
  GOG install that worked (a driver check).
- **PLA-59**: a log line for a guest's hidden top-level window text (JWE's dialog).
- **PLA-63**: the JIT pool unmap.
- **Valheim on Vulkan** no longer dies at the intro since `patches/dxvk` 0001 (decision 0061,
  IPA `beefb876`): DXVK refuses the shared texture and the game lives, its ticket is checked
  by a server and PlayFab signs in. Its picture stays black (Unity's video player gets a null
  `GetSharedHandle` and the intro never shows), so its page stays on DXMT
  ([steam-ticket-valheim](2026-10-07-steam-ticket-valheim.md#play-6-on-vulkan-with-patchesdxvk-0001-decision-0061)).
  Its Linear issue is still to be filed.
- The release (step 7): the owner's later session.
