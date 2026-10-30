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
  account/device tickets, proof secrets and account information**; item
  `licences` holds each copy's unwrapped content keys with the licence's expiry
  and offline lease. Sign-out deletes all three, fences in-flight exchanges,
  and keeps `device`.
- The device contains no phone identifiers and never probes hardware. Reset
  signs out and generates a different device; the next sign-in registers it.
  A definitive device-authentication refusal replaces it once, not in a retry
  loop. HTTP/service errors do not spend a new device slot.
- The Microsoft Store's ten-device limit is **licensing reason 501, not HTTP
  501**. `XboxLicenseFailure.check` recognises it and points to
  `account.microsoft.com/devices/content`; it never echoes provider guidance.
  Device registration is anonymous. Association with the account and that
  limit occur at licensing (PLA-496), not while displaying the sign-in page.

## Library (PLA-492)

- `XboxSession.storeTicket()` exchanges the device and user tickets silently for
  the Microsoft Store's own ticket (`www.microsoft.com`, `mbi_ssl`, the Store
  app's client ID), cached with the session and deleted at sign-out. A refusal
  asks for sign-in but keeps the session.
- `XboxStoreLibrary.refresh(_:)` reads the account's PCGAFD entitlements (every
  `x-ms-ct` page) with that ticket, follows each licence's parents to **owned**
  or **PC Game Pass** access (inactive, trial, shared, expired, flagged and
  unresolved licences give none; a bad row takes its children with it), then
  looks the licensed products up in the public display catalogue (20 per page,
  four at a time, bundles' products in later rounds). A copy is listed, keyed
  by Product ID with its title and Microsoft's art, only when it is a game with
  a Windows.Desktop **MSIXVC/MSIXVC2** package, directly or through its bundle.
  Left out: UWP/EAppx and other packages, products with no Store package
  (Microsoft delivers them through Battle.net, the EA app or another launcher),
  add-ons, and an edition whose games are listed as copies of their own.
- Each refresh reads the entitlements again and looks up only products the
  previous snapshot lacks; a product it could not resolve is looked up again.
  The catalogue transport allows 8 MiB a response (a page of 20 runs to ~2 MiB).

## Licences and content keys

`XboxSession.licence(contentID:market:)` (`XboxLicensing.swift`) follows Xodus's
`get_license_content`: a device ticket and the account's Store ticket for
`www.microsoft.com` (`mbi_ssl`, the Store app's client ID) and the PUID go to
`licensing.mp.microsoft.com/v7.0/licenses/content` with Xodus's fixed challenge.
The first key licence's SPLicense block carries the packed content keys (RFC 3394
AES key wrap under the device key) and its expiry; the device key is the
registration licence's EncryptedDeviceKey. Recorded responses (PLA-487) show the
content licence expiring as it is issued, with a lease licence whose policy says
`isOffline`, a 30-day `expiresAt` and a 2-day `pollAt`, although nobody had
changed the account's offline device. As Nexus does, such a lease is taken as
Microsoft's offline grant. The result is typed:

- `.licensed`: fresh keys (`.microsoft`), stored in `licences`; or, only while
  licensing is unreachable (`.network`, or HTTP 408/429/5xx), the stored keys
  until the later of the licence's expiry and its offline lease (`.cache`).
- `.refused(XboxLicenseFailure)` is Microsoft's **definitive** answer, and the
  only one: an HTTP 2xx body holding `satisfactionFailure` with a numeric reason
  and no `license`. Reason 501 is `.deviceLimit` (the device, not the copy; it
  deletes every copy's keys); any other reason is `.refused` (that copy's keys
  deleted). A licence lapse counts `.refused` only.
- `.unavailable(XboxLicenceProblem)` is never a verdict: network, HTTP
  408/429/5xx (`service`), any other HTTP error including 401 and 403
  (`rejected`; Nexus counts 403 as a refusal, but it carries no licensing
  reason), unrecognised or ambiguous bodies and keys that don't unwrap
  (`invalidResponse`), and missing tickets (`session`). Only `network` and
  `service` fall back to stored keys.

Logs say granted/refused/unavailable only: no content ID, licence, key, ticket
or provider text.

## Installing a copy (PLA-497)

The pilot's package format is **MSIXVC**: an XVD (format 3, fixed, integrity
protected) whose drive is NTFS. `XboxInstaller.install(product:contentID:title:)`
follows Xodus's streaming install:

1. **Package and entitlement.** The catalogue names each copy's Windows.Desktop
   GDK package (`XboxProduct.package`: content ID, format, MaxDownloadSize).
   `XboxSession.packageLocation(contentID:)` exchanges the account's RPS ticket
   (`user.auth.xboxlive.com`, `mbi_ssl`, the Store app) at user.auth, gets an XSTS
   token for `http://update.xboxlive.com`, and asks
   `packagespc.xboxlive.com/GetBasePackage/<contentID>`. The first `.msixvc` file
   is installed, from the `xboxlive.com` CDN roots only. No package for the account
   (`PackageFound: false`, 403, 404) is `XboxInstallRefusal.notEntitled`; an
   MSIXVC2 package is `unsupported` (PLA-503).
2. **Licence.** `licence(contentID:)` (the same GUID: the XVD's VDUID). A refusal
   is `XboxInstallRefusal.licence(XboxLicenseFailure)`, before any download; the
   licence must carry every key the package's regions name.
3. **Metadata prefix.** Every byte before the first encrypted region (header, hash
   tree, user data, XVC information, the drive's GPT and NTFS metadata: 44 MB for
   the pilot, as Nexus keeps) is fetched into `<stage>.package` beside the stage,
   resuming a partial one. `XboxPackage.load` checks the hash tree from the
   header's top hash down and every metadata page it reads against it.
4. **Files.** The NTFS drive's `$MFT` (walked linearly, paths from `$FILE_NAME`
   parents) gives every file and its pages; a file Xodus would silently skip
   (resident data, fragments, sparse runs, attribute lists) is refused by name.
   `SegmentMetadata.bin` (the pilot has one: exactly its two `.exe`s are
   `KEEP_ENCRYPTED_ON_DISK`) chooses the kept-encrypted files; without it every
   `.exe` is (Xodus's NTFS fallback).
5. **Stream-extract.** ContentKit's install engine stages the files in 1 MiB
   chunks of one file's pages, read with HTTP ranges straight into the stage: no
   copy of the package is kept, so the install needs about the game's size plus
   the metadata prefix. Each page is checked against its level-0 hash entry
   (SHA-256 of the ciphertext, 20 bytes and the page's XTS data unit in an
   encrypted region) and fetched once more if it fails; then plain files are
   XTS-AES-128 decrypted (`XboxXTS`: tweak key = the content key's first half;
   tweak = data unit, region ID, VDUID) and cut to size, and kept-encrypted files
   written as their whole encrypted pages. A stop resumes from the engine's
   journal; the prefix is not fetched again.
6. **Commit.** Every file's SHA-1 is taken, the stage moves into `C:\Games` with
   one rename, and `manifests/xbox-<ProductId>.json` (`XboxInstalled`) keeps the
   files and hashes, MicrosoftGame.config's executable, Title ID, MSA app ID and
   SCID, and for each kept-encrypted file what a play needs to decrypt it
   (`XboxEncryptedFile`: size, region, key ID, data units; the tweak's VDUID is
   the content ID). No key, ticket or account identifier.

The CDN roots are plain HTTP (`assets1/assets2.xboxlive.com` have no certificate
for their names), which App Transport Security refuses in URLSession: ranges go
over `XboxRangeClient`, an HTTP/1.1 keep-alive client on sockets (no redirects,
compression or chunked bodies; Content-Range must be the range asked). The bytes
are trusted only through the hash tree, which is anchored in the unsigned-here
XVD header: the header's signature is not checked (as in Xodus).

`verify` re-hashes the installed files; `forget(_:keepSaves:localAppData:)` drops
the record and stages and, unless saves are kept, the runtime's local saves for
the copy's SCID (`XboxSaves`: `XodusGameSave`, `XodusGameSaveFiles[Cache]`, every
account).

## Provenance and offline checks

Written from Xodus `514dd56f360a4bdf12f4acde5148bac5ce5f957f`:
`xodus-cli/src/{webview.rs,commands/login.rs}`, `xodus/src/{tokens/,api/live/,
models/,clep/challenge.rs,licensing/{splicense,utils}.rs}`. The two hosted legs'
headers and licensing reason 501 also follow Xodus Nexus
`96c652343d30ae16fe476818288edbed5dfac673` (`xodus-hosted-signin.patch`,
`xodus-content-device-limit.patch`). Licensing follows Xodus
`53ea781dcd073e31d7ea68e894134e9c959bff04` (the backend Nexus v0.4.1 pins:
`licensing/{content,splicense}.rs`, `models/{licensing,devicecredential}.rs`,
`xodus-cli/src/{license.rs,commands/license.rs}`) and Nexus
`e0668a12f1da931aed13537ef04295599011317b`'s `xodus-content-response`,
`xodus-content-device-limit` and `xodus-offline-license` patches. Derived files carry GPL-3.0-only provenance
headers; `LICENSE-Xodus.txt`, `LICENSE-XodusNexus.txt` and
`LICENSE-CikExtractor.txt` preserve the applicable notices. See
[LICENSING.md](../../docs/LICENSING.md#xbox-planned). The library follows Xodus
Nexus `e0668a12f1da931aed13537ef04295599011317b` (`src/main/catalog.ts`,
`src/main/account-library.ts`, `assets/xodus-subscription-login.patch`). The
install follows Xodus `53ea781dcd073e31d7ea68e894134e9c959bff04`
(`crates/msixvc/src/{xvd.rs,crypt.rs,hash_tree.rs,layout.rs,math.rs,streaming.rs,
streaming_ntfs.rs,models/xvd/}`, `crates/xodus/src/api/xbox/`,
`crates/xodus-cli/src/{package.rs,commands/streaming.rs}`).

`Tests/XboxClientKitTests/Fixtures/` contains **synthetic, redacted responses**, not
account captures. No PLA-487 captures were present when PLA-491 began. The
licensing fixtures (`licence-*`, `device-add-licensing.xml`) copy the recorded
responses' shape (elements, attributes, policy fields, SPLicense block order and
sizes, times) with made-up IDs and a generated device key; the wrapped content
key is bytes 0x40…0x5f. The real licences can't be redacted: their keys are
wrapped for a real device.
The XML/JSON shapes are those Xodus parses. The device licence wraps a freshly
generated test-only RSA2 key in a version-4 CLEP state. The device proof wraps
bytes 0…31; user responses are AES-256-CBC encrypted and HMAC-signed with the
same SP800-108 derivation as the broker. Fixtures were independently sealed
with Python `cryptography` and exclusive-canonicalised with `lxml`; the binary
RSA/DER/signature fixtures are known-answer vectors from that synthetic key,
not usable credentials. Base64 text starts on its own line so the secret scan
still catches a real inline ticket rather than exempting the whole directory.
The library's fixtures are recorded, not synthetic: `entitlements.json` is 15
rows of the PLA-487 ground-truth PCGAFD response (renewal IDs redacted; one row
keeps the capture's redacted key, which the parser skips), and
`catalog-products.json` is the display catalogue's records for those products
and their bundles' products (the pilot's from the ground-truth capture, the rest
from the public endpoint, which needs no account), trimmed to the fields read.
`store-ticket.xml` is a synthetic, unsealed broker reply.
`pilot-metadata.cut.zlib` is **real**: pieces of the pilot's package as the CDN
served it (no account data is in a package): its three header pages, the hash
tree's top page, the level-1 and level-0 pages down to MicrosoftGame.Config's
page, that page, and the whole user data and XVC information (`PPCUT1`, then
u32 count and `{u64 offset, u32 length, bytes}`, zlib). Everything else of the
install's tests is a synthesised MSIXVC with the pilot's layout
(`XboxTestPackage`: GPT, NTFS with 4 KiB records, three regions, XTS under a
test key) served by a 127.0.0.1 range server.

`PLAYPORT_BUILD=$PWD/.work ./pp test --swift XboxClientKit` runs public session
flows (exchange, relaunch, expiry/renewal/refusal, device reuse/replacement/reset,
sign-out during renewal, device limit, tampered response and logs), licensing
(content key, cache and expiry, offline lease, refusal versus network/service
error, logs), plus the independent FIPS-197/RFC-4231/RFC-3394/RSA vectors, and the
install: the pilot's real header, layout, regions, segment metadata and hash tree
(a flipped byte at each level found), IEEE 1619 and OpenSSL XTS vectors, cut and
damaged metadata (throw, never trap), stream-extract over HTTP ranges, resume
after a stop and a dropped connection, a byte flipped on the wire and on disk,
the NTFS fallback without SegmentMetadata.bin, licence and entitlement refusals,
and remove with and without saves.

The phone is a deferred gate: Microsoft sign-in/2FA, relaunch, sign-out/reuse,
and the passkey finding. The sheet assumes passkeys are unavailable in a
sideloaded web view and steers to Authenticator, code or password; no phone
finding is claimed. `pp ui` paths: `xbox:signin`, `xbox:wait`, `xbox:status`,
`xbox:signout`, `xbox:reset-device` (help in `tools/ui.py`).

The library's phone gate is deferred too: `./pp ui --action xbox:library --shot`
(signed in) shows the Xbox chip's copies with Microsoft's art and logs counts only.
