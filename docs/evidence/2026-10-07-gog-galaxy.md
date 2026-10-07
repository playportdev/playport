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

**Update, PLA-55 (IPA `5eaca1e8`, below):** the SDK's silence was a system APC that never ran;
with wine-unix 0018 Moonscars and Monster Train send `AUTH_INFO` and get the token within half a
second. Their sign-in at GOG then fails on the next gap, Schannel without security packages
(PLA-50), so the gate still does not pass. The rest of this section is the first state.

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

## PLA-55: the SDK's connect completes through a system APC (wine-unix 0018)

**IPA** `Playport-26.5-5eaca1e8.ipa` (dev), sha256
`5eaca1e843e91318f4c760034794e5be542816f9eaec760f2e543987d7f3e1ae`: `d9f7723` with
`patches/wine-unix/0018-ntdll-iOS-run-pending-system-APCs-when-a-thread-poll.patch`. Phone
as above, unattended. Run directories: `$PLAYPORT_BUILD/ui-runs/20261007T192320` (Moonscars),
`…T192653` (Monster Train), `$PLAYPORT_BUILD/perf-runs/20261007T193124`, and the regressions
below.

**Cause** (measured on the workstation, `$PLAYPORT_BUILD/agent-notes/store-auth/pla55/`). The
SDK's network thread issues `ConnectEx` to `127.0.0.1:9977`, then polls its I/O completion port
with a zero timeout (`GetQueuedCompletionStatus(…, 0)`) and never enters a server wait. In Wine
the connect completes through a system APC (`APC_ASYNC_IO`) on the issuing thread, and only that
APC posts the completion packet. On iOS the server cannot signal a thread (wine-unix 0002 queues
the APC "without a signal": the `[apc-nosignal] #1 tid=<SDK thread> type=2` line in every
failing play), and a zero-timeout `NtRemoveIoCompletion` returns without a server call, so the
APC never ran. After 15 s the SDK tried to start the `GalaxyCommunication` service (the late
`\pipe\svcctl` open) and gave up. Withholding SIGUSR1 from that one thread in a desktop
wineserver (an `LD_PRELOAD` shim) reproduced the phone's host log line for line; delivering it
3 s late made the SDK send `AUTH_INFO` 3 s late. The SCM is consulted only after the failure.

**Fix.** wine-unix 0018: on iOS a zero-timeout `NtRemoveIoCompletion(Ex)` that finds the port
empty does a zero-timeout, non-alertable select on the port's wait object, which runs the
thread's pending system APCs and then takes a packet one of them posted.

**Moonscars** (`--until first-frame+60 --shot`): JIT 2.19 s, first frame +5.25 s, the title
screen at +60 s.

    [srv-conn] … dport=9977 …
    [apc-nosignal] #1 tid=0104 type=2 queued without a signal
    galaxy: 17:23:35.737Z [galaxy] a connection from the game
    galaxy: 17:23:35.975Z [galaxy] AUTH_INFO: a game token minted for the build's client in 0.24 s
    galaxy: 17:23:36.149Z [galaxy] AUTH_INFO (87 bytes) -> 200 (91 bytes)
    galaxy: 17:23:36.447Z [galaxy] the game closed a connection after 97 bytes in 1 frame(s)

The reply comes 0.41 s after the connection, and no late `\pipe\svcctl` open follows. The SDK
then connects to GOG on port 443 and loads `schannel.dll`, and `Player.log` ends
`AuthenticationListener::OnAuthFailure(): FAILURE_REASON_CONNECTION_FAILURE` (was
`GALAXY_SERVICE_NOT_AVAILABLE`). No `GET_USER_ACHIEVEMENTS` or other frame came: the SDK asks for
those only once signed in. The likely cause, inferred from the same thread's earlier lines and
not measured: `secur32:start_samss Failed to open service manager` and `load_auth_packages Failed
to get security packages list: 80090304`. The pinned Wine's secur32 gets its packages from an
lsass service that the phone does not run, so Schannel has no TLS package (PLA-50). Proton 10's
secur32, on the workstation, does not ask that service. No achievement was unlocked.

**Monster Train** (`gog-1304291300`, `--until first-frame+60 --shot`): first frame +4.25 s,
the black screen at +60 s as before. `AUTH_INFO (87 bytes) -> 200 (91 bytes)` 0.57 s after the
connection, the token minted in 0.41 s; its `logfile.log`: `[Network] Unable to authenticate
with GOG. Giving up. State: Failed` in the same second, with the same `secur32` lines.

**0063's measurement: the minted token in the container.** A scratch script (under `.work`, not
committed) walked the app's container over AFC after the Moonscars and Monster Train plays and
read every file modified since just before the first of them. The host keeps the minted tokens
in memory only, so the script searched for their shapes: GOG's 64-character mixed-case
alphanumeric refresh token and its 150 to 400-character access token, in ASCII and UTF-16LE,
and the names `refresh_token` and `access_token`. It printed counts and paths, never a value.

| Files walked | Bytes walked | Files read (modified since) | Hits |
| --- | --- | --- | --- |
| 17,762 | 89.0 GB | 37 (21.5 MB) | **0** (two access-token-shape matches, in `s1-host.log` and `s1-host.prev.log`, are Swift symbol names in a thread backtrace) |

The SDK failed its GOG sign-in before using the token, so this shows only that neither the
host nor the service nor the SDK wrote it to a file before that point. Whether the SDK stores a
token after a successful sign-in is not measured; process memory is not searched.

**The poll's cost** (Moonscars, `pp perf --secs 120`, the title screen). The frame rate was
mean 59.5, median 60, p10 59.9 fps, frame time 16.81 ms, GPU 0.66 ms, CPU 72–84 %. Between 20
and 55 s after the first present, the patched plays and three unpatched plays (`baf1dfa1` and
earlier, `gog-b9/moonscars1`, `moonscars2`, `final/moonscars`) all ran 59.9 fps. The SDK thread
keeps polling after its sign-in fails. From the `[xp-t]` and `[srv-t]` lines, 20 s after its
connection to the end:

| Build | SDK thread CPU | Server requests/s on that thread | Its server time |
| --- | --- | --- | --- |
| unpatched (3 plays) | 4.2–4.3 % of a core | 793–810, none a select | 77–78 ms/s |
| wine-unix 0018 (`pp perf`, and the ui play) | 5.1–5.2 % | 734–743 polls, each with a select | 138–140 ms/s |

The poll costs that thread about one percentage point of a core, with no frame cost on this
title. Other titles that poll a completion port with a zero timeout pay the same.

**Regressions on `5eaca1e8`** (one `pp phone lock` session):

- Hollow Knight (`app-367520`, `first-frame+10 --shot`): JIT 2.62 s, first frame +9.77 s, the
  title menu; `emulator connected (protocol 1, tickets armed)`.
- Shogun Showdown (`gog-1104084973`, `first-frame+20 --shot`): first frame +19.02 s, "Press any
  button".
- Valheim (`app-892970`, on its page's DXMT, `first-frame+60 --shot`): first frame +7.24 s, the
  intro cinematic at +60 s. `[ticket] ticket 1347420161: auth session for app 892970, 240 bytes`,
  `auth list acked by Steam`, `checked by a server: EAuthSessionResponse 0 (OK), state 2`, then
  `cancelled by the game`. `Player.log`: `Logged in PlayFab user via Steam auth session ticket`
  at the first attempt.
- Snakebird Complete (`epic-8337d1f975514d35ad0c1176e8a29f26`, `first-frame+30 --shot`): first
  frame +4.95 s, the main menu; `Player.log`: `Tried to login auth: Success`, `Logged in to
  connect` (the silent EOS sign-in).

## Not checked on the phone

The GOG sign-in itself (blocked by PLA-50, above), a gameplay request, the token refresh,
sign-out during a play; they are host-tested only (`GalaxyTests`).
