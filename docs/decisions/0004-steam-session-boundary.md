# 0004: Steam session boundary

**Status:** accepted, 2026-09-24

## Decision

The app's native Steam client (`app/SteamClient`) and any Steam client
running inside the guest are separate sessions. **No host Steam secret is
ever transferred into the guest**: not the refresh token, the access token,
QR material, machine or session bindings, CDN tokens or depot keys, by any
route (files in the prefix, the environment, the registry, command-line
arguments, IPC, shared memory, or the `wine_host` C ABI). A guest client
performs its own login.

This rule can change only by a new decision record that shows a threat model
for the specific secret, a single channel for it, measured guest-side storage,
logout that removes every copy, and revocation that also invalidates what the
guest received.

## Why

Everything runs in one process: the host app, the runtime and every guest
binary share one address space, one container, one Keychain entitlement set
and one environment (Wine imports the Windows environment from the unix one,
and Wine's `\??\unix\` namespace reaches the whole sandbox). There is no
in-process boundary between host and guest code. Handing a host secret to the
guest would turn every guest-side leak surface (the guest client's logs and
dumps, its stored session under Wine's ineffective DPAPI, the prefix in a
container copy) into a host-session leak surface.

## How the host side is kept

- Host secrets live in the Keychain only: a generic-password item,
  `ThisDeviceOnly`, not synchronisable, in the app's access group. The
  container holds none.
- In memory, secrets are `Secret<T>` values that print as `<redacted>`, and
  every log line passes a scrubber for JWTs, QR URLs, query strings, bearer
  values and home paths.
- The `wine_host` ABI has no parameter that carries a credential.
- Launch modes that pass Steam commands put no secret in the launch
  environment, and the device driver checks every transcript for leaks
  (`harness/device/steam-device-run.py`).
- Logout revokes the token with Steam, deletes the Keychain item and cached
  account data, and leaves games and saves in place.
- Exceptions, each with its own record meeting the five things above: a game's
  encrypted app ticket, one ini line while the game runs
  ([0017](0017-encrypted-app-ticket.md)); and an Epic game's exchange code on its
  command line and ownership token in one file while it runs
  ([0059](0059-epic-exchange-code.md)); and a Steam game's auth session and web
  API tickets, made by the host during the play through one unix call table
  ([0062](0062-steam-live-session.md)); and a GOG game's refresh token for its own Galaxy
  client, in the local Galaxy service's auth reply while the game runs
  ([0063](0063-gog-galaxy-sign-in.md)). A game's web page opened in Playport's panel
  ([0064](0064-game-web-sheet.md)) is not a transfer: an Epic game's Epic sign-in page is
  signed in with a fresh exchange code inside the panel's own non-persistent web session,
  and nothing of it reaches the guest.
- During a play the host's Steam session does no Steam work: the CM session
  closes before the runtime starts, except that it stays logged on for the
  game's tickets alone while they are armed ([0062](0062-steam-live-session.md)).

## Residual risk

A hostile guest binary can read anything the process can, including a host
token while it is in memory. The mitigation is scope: only owned titles and
genuine clients run, and host tokens are held in memory only while in use.
