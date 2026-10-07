# Evidence: a GOG game's Galaxy service (decision 0063, plan step 5)

**Date:** 2026-10-07. **IPA:** `Playport-26.5-baf1dfa1.ipa` (dev), sha256
`baf1dfa16c6a2dff04f5a1226544c3f7847560a6690762382ca1426e868a6d22`, built from `8afe7ee`
(B1 to B5: `9ec1ee7`, `830f638`, `3292142`, `141abea`, `8afe7ee`). Earlier plays on
`77ba6ce0…` (`77ba6ce03e9e53b8bcb661857c02211a84ee8ba260fbbaf58b63108b2dec4d20`, before the
byte counts were logged) and `77df004e…` (`77df004ec11c91f31b0e8e78501861fb2bda2ebe9ccf7a89fbcc2b661214c18d`) and a scratch
IPA (`3603b4da`, below: the same code and a listener for the probe; not committed). Phone: iPhone18,4, iOS 27.0, Wi-Fi, on charge, unattended; GOG signed in with the
owner's account. Run directories are under `$PLAYPORT_BUILD/agent-notes/store-auth/`
(`gog-b9/`, `final/`, `sockprobe/`, `gog-desktop/`); screenshots stay there.

## Result

The host side works; the gate does not pass. On the phone the Galaxy SDK of Moonscars and
Monster Train connects to the service and sends nothing, then signs out with
`FAILURE_REASON_GALAXY_SERVICE_NOT_AVAILABLE`. On the workstation the same Moonscars files,
under Proton, send `AUTH_INFO` at once and get the service's reply. No game token was minted
in any play, so no token crossed and none could be left in the container. No achievement was
unlocked.

## Install (B2)

`pp ui --action install:gog-2106173825`: Moonscars 0.70 GB, 335 files, in about 40 s. Its
install record (`Library/Application Support/Playport/manifests/gog-2106173825.json`, pulled)
holds `galaxy` (the build's client ID and secret) and `galaxyRead: true`. Shogun Showdown's
older record took its client from its build at its first launch:

    [gog] 1104084973: Galaxy client read from build 59059134842096269 into its record

The driver reported each GOG install (Moonscars, Duck Paradox, Monster Train) as `done, but
not in the library` although the store log says `done` and the game then played: a driver
check, not the install (not looked into).

## Moonscars (GOG 2106173825), `--until first-frame+60 --shot`

Four plays, one on each IPA named above; on `baf1dfa1`: JIT 2.43 s, first frame +5.44 s, the title screen
("Press Space to Start") at +60 s. The host's lines:

    galaxy: … [galaxy] the Galaxy service listens on 127.0.0.1:9977 for this play
    galaxy: … [galaxy] a connection from the game
    galaxy: … [galaxy] the game closed a connection after 0 bytes in 0 frame(s)

The connection comes 5 s after Play and closes 15 s later. `Player.log`: `Galaxy SDK was
initialized`, then `AuthenticationListener::OnAuthFailure():
FAILURE_REASON_GALAXY_SERVICE_NOT_AVAILABLE`. A tenth of a second before the close the guest
opens `\pipe\svcctl` (`RPC_S_SERVER_UNAVAILABLE`): most likely the SDK trying to start the
`GalaxyCommunication` service after its wait. With fastsync off (`set:dev.fastsyncOff=true`)
the same.

## Back-ups (on the scratch IPA `3603b4da`, the same GOG code)

- **Duck Paradox** (GOG 1816031813, another SDK build): installed (1.0 GB, 9 s); the game ends
  `0xf8f88f70` 1 s after start, before any connection.
- **Monster Train** (GOG 1304291300, another SDK build, 15.3 MB): installed; first frame
  +4.46 s, a black screen at +60 s; the Galaxy SDK connects 8 s after Play and closes 15 s
  later after 0 bytes, as Moonscars'.

## What the workstation shows (HOST-DEBUGGING)

Moonscars' files pulled from the phone, Proton 10, a scratch prefix, the sway display:

- With a logging stand-in on `:9977` that answers nothing: the SDK connects and sends
  `AUTH_INFO` (sort 1, type 3, 88 bytes: client ID, secret, PID) at once, again at 3, 3 and 6 s,
  and closes at 15 s. No `GalaxyCommunication` service is registered in that prefix: the SDK
  does not need one there.
- With Playport's own `GalaxyListener` and `GalaxyService` (a Linux build, a fake token source,
  no GOG session used): `AUTH_INFO (88 bytes) -> 200 (33 bytes)`, the SDK closes the
  connection and then fails at GOG with `FAILURE_REASON_INVALID_CREDENTIALS` (the fake token).
  So the frames and the reply are what the SDK reads.
- `WINEDEBUG=+winsock`: the SDK's thread binds, calls `ConnectEx`, then
  `SO_UPDATE_CONNECT_CONTEXT`, `FIONBIO`, a non-blocking `recv` (would block), and `send`.

On the phone, a scratch probe (an imported executable, removed afterwards) ran that sequence and
the others Boost.Asio uses (blocking; `ConnectEx` with a completion port, with and without
skip-on-success; overlapped `WSASend`/`WSARecv`), against a server in the guest and, on a
scratch IPA that started the listener for the probe, against the host's listener: every one
connected, sent, and got its reply (`AUTH_INFO refused: the client is not this build's`,
403, for its made-up client). So the guest's sockets and the host's listener work; what keeps
the SDK from sending on the phone is not found (its threads, a wait that does not return, or
another check before the send). Not a service registration (B8): the SDK does not need one
under Proton.

## Regressions on `baf1dfa1`

- Hollow Knight (`app-367520`) to `first-frame+10 --shot`: JIT 2.35 s, first frame +9.38 s, the
  title menu; the Steam emulator connected with tickets armed.
- Shogun Showdown (`gog-1104084973`, GOG, no Galaxy DLL) to `first-frame+20 --shot`: first frame
  +18.71 s (+19.17 s on 2026-10-06), "Press any button"; the service listened (its build names a
  client) and nothing connected.

## Not checked on the phone

The sign-in itself, the mint, a gameplay request, the token refresh, the container search for
a minted token, sign-out during a play; they are host-tested only (`GalaxyTests`).
