# XboxClient: Microsoft sign-in and the synthetic device

`XboxClientKit` is the host-side Xbox client on ContentKit (PLA-491, decisions
[0058](../../docs/decisions/0058-store-sessions.md) and
[0166](../../docs/decisions/0166-the-xbox-store.md)). The app links it **only in dev**;
its account, sign-in sheet and device-reset action are in `Sources/S1Probe/Dev/`.
The release package has no XboxClientKit dependency. Every Xbox Swift type starts
`Xbox`, so release verification catches a surface that reaches the executable.

## Session boundary

- `XboxHTTP` is the injected transport: `XboxHTTPRequest` in, status and a
  secret-wrapped body out. `XboxURLSessionHTTP` uses an ephemeral URLSession,
  without cookies, cache or redirects. No body, URL, header or provider error text
  is logged. Tests use a fixture transport and `MemorySecretStore`; no network.
- `XboxSession.prepareSignIn()` registers/authenticates the synthetic device and
  returns Microsoft's inline page with CloudExperienceHost's headers.
  `XboxSignIn` supplies the web view's user agent and script bridge, validates
  the page's origin and decodes its `DAProperty`. `signIn(_:)` exchanges that
  result for Microsoft device/user tickets. An inline-approval fault returns
  `.continueAt`: the same non-persistent web view loads the second hosted leg,
  keeping that sheet's cookies but giving it fresh broker headers.
- `userTicket` silently renews a ticket near expiry; `renew()` forces a silent
  exchange. A definitive authentication fault deletes the issued credentials
  and asks for sign-in again. A connection, service or malformed-response error
  does not replace the device or throw away the account session.
- `deviceTicket` exchanges the device's STS ticket for a service ticket. Ticket
  values are `Secret<String>`; each carries its expiry. The synthetic device's
  private key and proof secret never cross this boundary to a game.
- Keychain service `dev.playport.app.xbox` uses ContentKit's
  `AfterFirstUnlockThisDeviceOnly`, non-synchronisable store. Item `device`
  holds random hardware, the registration and its encrypted private-key state;
  it survives sign-out. Items `session` and `device-token` hold **all issued
  account/device tickets, proof secrets and account information**. Sign-out
  deletes both, fences in-flight exchanges, and keeps `device`. Future Xbox
  key/lease storage must participate in this deletion boundary.
- The device contains no phone identifiers and never probes hardware. Reset
  signs out and generates a different device; the next sign-in registers it.
  A definitive device-authentication refusal replaces it once, not in a retry
  loop. HTTP/service errors do not spend a new device slot.
- The Microsoft Store's ten-device limit is **licensing reason 501, not HTTP
  501**. `XboxLicenseFailure.check` recognises it and points to
  `account.microsoft.com/devices/content`; it never echoes provider guidance.
  Device registration is anonymous. Association with the account and that
  limit occur at licensing (PLA-496), not while displaying the sign-in page.

## Provenance and offline checks

Written from Xodus `514dd56f360a4bdf12f4acde5148bac5ce5f957f`:
`xodus-cli/src/{webview.rs,commands/login.rs}`, `xodus/src/{tokens/,api/live/,
models/,clep/challenge.rs,licensing/{splicense,utils}.rs}`. The two hosted legs'
headers and licensing reason 501 also follow Xodus Nexus
`96c652343d30ae16fe476818288edbed5dfac673` (`xodus-hosted-signin.patch`,
`xodus-content-device-limit.patch`). Derived files carry GPL-3.0-only provenance
headers; `LICENSE-Xodus.txt`, `LICENSE-XodusNexus.txt` and
`LICENSE-CikExtractor.txt` preserve the applicable notices. See
[LICENSING.md](../../docs/LICENSING.md#xbox-planned).

`Tests/XboxClientKitTests/Fixtures/` contains **synthetic, redacted responses**, not
account captures. No PLA-487 captures were present when this ticket began.
The XML/JSON shapes are those Xodus parses. The device licence wraps a freshly
generated test-only RSA2 key in a version-4 CLEP state. The device proof wraps
bytes 0…31; user responses are AES-256-CBC encrypted and HMAC-signed with the
same SP800-108 derivation as the broker. Fixtures were independently sealed
with Python `cryptography` and exclusive-canonicalised with `lxml`; the binary
RSA/DER/signature fixtures are known-answer vectors from that synthetic key,
not usable credentials. Base64 text starts on its own line so the secret scan
still catches a real inline ticket rather than exempting the whole directory.

`PLAYPORT_BUILD=$PWD/.work ./pp test --swift XboxClientKit` runs public session
flows (exchange, relaunch, expiry/renewal/refusal, device reuse/replacement/reset,
sign-out during renewal, device limit, tampered response and logs), plus the
independent FIPS-197/RFC-4231/RSA vectors.

The phone is a deferred gate: Microsoft sign-in/2FA, relaunch, sign-out/reuse,
and the passkey finding. The sheet assumes passkeys are unavailable in a
sideloaded web view and steers to Authenticator, code or password; no phone
finding is claimed. `pp ui` paths: `xbox:signin`, `xbox:wait`, `xbox:status`,
`xbox:signout`, `xbox:reset-device` (help in `tools/ui.py`).
