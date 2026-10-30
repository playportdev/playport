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
   is installed, else the first `.msixvc2` (below), from the `xboxlive.com` CDN
   roots only. No package for the account (`PackageFound: false`, 403, 404) is
   `XboxInstallRefusal.notEntitled`.
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

## MSIXVC2 (PLA-503)

MSIXVC2 is the PC package format Microsoft made generally available with the
October 2026 GDK (default from April 2027). A `.msixvc2` is a ZIP:

- `XboxPackage.cbor` (CBOR, self-described tag `XVCP`): content ID, fulfilment
  content ID, version, the package's keys, its boxes and its chunks. Each chunk
  names its content key and a *secret*: a segment holding its files' names.
- `Chunks/<id>.cbor` (`XVCC`): the chunk's files in order, each a length, a
  hash (SHA-256/384/512, by CBOR tag) and its *segments*.
- `Boxes/<name>`, stored: `XBOXBOX\0`, segment bytes, a manifest (`XVCB`: the
  box's segments), its seal (`XVCZ`: the manifest's hash), then the manifest's
  offset (LE64) and length (LE32).

A segment is variable-size (content-defined), may be Deflate-compressed, then is
AES-256-CBC encrypted with the first 16 bytes of its plaintext hash as IV, under
its own key wrapped by the package key. The package key is the key source's
wrapped key unwrapped by SP800-108 HMAC-SHA256 (`MSIXVC2:PackageData:AES_256_CBC`,
the source's KDF context) of the licence's content key (`XboxMSIXVC2Keys`).
A wrapped key with an IV is AES-256-CBC (the source's IV; for a segment, the
chunk's rolling IV: one step per wrapped key, file by file); without one, AES
key wrap (RFC 3394, then RFC 5649), as Xodus's pull request unwraps every key.
The licence key is the one whose ID is the content source's; a licence with one
key whose ID differs uses it (Xodus's choice; a wrong key fails every hash).

`XboxMSIXVC2Package.fetch` reads the metadata with HTTP ranges, never the whole
ZIP: the end record (ZIP64 too), the directory, `XboxPackage.cbor` and every
`Chunks/<id>.cbor` (CRC-checked), each box's header, trailer and sealed manifest,
and each chunk's secret. Every read is kept in `<stage>.package` (records of
offset, length, bytes), so a resumed install fetches none again. Each file's
segments must lie in their box's segment area and be listed (hash, length) by
the box's manifest; their lengths must make the file's.

The install goes through the same engine: one ContentKit chunk per distinct
segment (shared segments are fetched once), read by range straight into the
stage. A segment's box bytes are checked against its box hash before they are
decrypted (fetched once more if they fail), its plaintext against its hash; a
good box hash with a bad plaintext is the licence's key ("Xbox licence key
doesn't decrypt this package"). Before the commit every file is hashed whole
against the package's hash for it. MSIXVC2 installs every file decrypted
(Microsoft: "installed files are stored unencrypted"), so the record's
`encrypted` is empty and MicrosoftGame.config is read from the staged file.
`packageName` is the `.msixvc2` file name without its extension.

Not supported, refused by name: Brotli-compressed segments (no decoder here
yet), compressed boxes in the ZIP, ZIP encryption, MSIXVC2 file format other
than 1, and key derivations or algorithms other than SP800-108 and AES-256-CBC.
No retail MSIXVC2 title was in the PC Game Pass or console catalogues on
2026-10-30, so the format is checked against the two references and a synthetic
package only (below).

## Updates (PLA-501)

`XboxUpdates.swift`, after Xodus Nexus's `xodus-store-updates` patch.

- **Detection.** `XboxInstaller.updateCheck(_:)` asks GetBasePackage (the
  install's call) for the record's content ID and compares its `VersionId`'s
  first four parts with the record's version as four 16-bit numbers
  (`XboxPackageVersion`). It answers `.available` or `.current`, or throws
  (no record, Microsoft unreachable, no version). The content ID is the
  record's (the package's VDUID), not displaycatalog's as in Nexus.
- **The bridge's checker.** `XboxUpdateChecker(installer:)` is the
  `XboxPackageUpdates` for a play. It answers for the version the runtime
  sends, against GetBasePackage for the running copy's record. No record, a
  malformed version, an error or 60 s without an answer (Nexus's limit) is
  `.unknown`, so the reply is `E_FAIL`.
- **Install.** `XboxInstaller.update(product:title:)` fetches the new
  package's metadata (MSIXVC: the prefix with its hash tree; MSIXVC2: the
  ZIP's metadata by range), then compares each of its files with the
  installed file at the same path (any case), stored the same way:
  - MSIXVC: every installed page against the new hash tree's level-0 entry.
    A plain or kept-encrypted page is hashed as it is. A decrypted page is
    encrypted again with its entry's data unit and the region's key first, so
    it still matches when its file moved in the package. A kept-encrypted page
    that moved has new data units and ciphertext, so it is fetched.
  - MSIXVC2: every segment against the installed bytes at the same offset in
    the file, by the segment's own hash.
  - A file that matches whole stays in place (its SHA-1 is taken on the way).
    Any other file is staged whole through ContentKit's resumable engine. Its
    matching pages or segments are read from the installed file and checked
    again as they are copied (one that no longer matches is fetched instead).
    The rest come from the CDN. So only changed pages or segments are fetched.
  - Staged files are renamed over the installed ones, files the package no
    longer has are removed, and the record is rewritten last. A stop before
    then leaves the copy and its record as they were; the next update resumes
    from the journal (stage `xbox-<ID>_<version>-update`).
  - With the copy's folder gone there is nothing to compare: it is installed
    again whole (`reinstalled`). A copy already at the latest version fetches
    nothing.
- GetBasePackage also lists `update-<from version>-….xsp` files beside the
  package (Microsoft's per-version patches). Their format is not known here and
  they are not used: the comparison above needs only the new package.
- Cost on the device: the update reads the whole installed copy once to compare
  it, and encrypts each decrypted page again (software AES-XTS). A changed file
  needs room for its staged copy until it is renamed in.

## The bridge

During one Xbox play the host answers the guest's `xgameruntime` over Xodus's
keyed loopback bridge (decision
[0167](../../docs/decisions/0167-xbox-guest-tickets.md)).

- `XboxBridgeListener` (`XboxBridgeListener.swift`) binds 127.0.0.1 on a free
  port at `start()`. `guestEnvironment` gives `XODUS_BRIDGE_PORT` and
  `XODUS_BRIDGE_KEY`, the names the runtime reads. They go into the title's
  environment only, never `setenv` in the app; the key is never logged.
  Each connection must send the play's 64-hex-character key (32 random bytes)
  within 10 s, before anything else. A missing or wrong key, another magic or a
  frame over 64 KiB (header included) ends the connection. At most 8
  connections are open at once.
- Wire (`XboxBridgeWire.swift`): magic `0x58445358`, a u16 type and a u16
  length, all little-endian, then an XML body. A reply's type is the request's
  plus one.
- `XboxBridgeService` binds every request to `XboxBridgeCopy`: the copy's
  Product ID, its declared related products and the `MSAAppId` (with its
  `MSAFullTrust`) from its MicrosoftGame.config.
  - `MSA_TOKEN_REQUEST` (3 → 4) returns Xodus's `MSATokenResponse`: `Token`
    and `Expiry` (the title's TokenBroker user ticket, `xboxlive.signin`, or
    `MBI_SSL` for a full-trust copy) and `DeviceRps` and `DeviceExpiry` (the
    device's user.auth ticket). It is served only for the copy's client ID, or
    for Xbox's platform ID `0000000040159362` when the copy declares none. A
    refusal is an empty body, as in Xodus.
  - `STORE_LICENSE_TOKEN_REQUEST` (5 → 6) uses
    `XboxSession.licenceToken(parentProductID:productIDs:nonce:)` (Nexus's
    `v8.0/licenseToken` request) and answers `Hresult` and `Token`. The parent
    must be the copy, and every product (or `PRODUCT/SKU`) the copy or one of
    its related products.
  - `STORE_PACKAGE_UPDATES_REQUEST` (9 → 10) passes the copy's version to the
    injected `XboxPackageUpdates`; the dev app's is `XboxUpdateChecker`
    (below). `Checked` true with `Count` 0 is sent only for a verified current
    package. With no checker, or an unknown answer, the reply is `E_FAIL`,
    never an empty success.
  - Everything is refused before sign-in, for another client or product, and for
    any other type (an empty reply of type + 1).
- Sign-out (and device reset) runs `XboxSession.onSignOut` handlers before the
  session's tickets are deleted. The listener's handler revokes the service, so a
  ticket minted in flight is never sent, and it closes every connection and the
  port. The host then holds no ticket it issued. A ticket the game already
  received lasts until Microsoft lets it lapse; that is 0167's residual.
- Logs name each request and reply type with sizes and a status (`served`,
  `refused: another product`, …). They never contain a payload, ticket, licence
  token, nonce or key.

## Playing a copy (PLA-499)

A Play of an installed copy (the dev app's `Dev/XboxPlay.swift`) goes through, in order:

- `XboxSession.licence` on every Play. `XboxPlayRefusal.check` turns a refusal into
  the launch's message: `kind` is `.signIn` (signed out, `signInRequired`,
  `deviceRejected`) or `.licence` (Microsoft's refusal, the device limit, licensing
  unreachable with no stored licence, or a licence with no key for the copy). The
  title and text say which.
- `XboxPlayFiles(installed:keys:)`: the record's kept-encrypted files and their
  ciphers. `plaintext(_:original:out:)` decrypts a file's whole pages from its
  original by their data units and cuts it to the file's size. PlayportKit's
  `InPlaceSwap` puts that plaintext under the original's name in the copy's own
  folder and sets the original aside beside it. A game that relaunches itself or
  looks beside its executable finds what it expects; Wine's loader needs no
  change (unlike Xodus's memfd launch view). At the launch's end the originals
  go back over the plaintext. A per-play marker in the state root lets the next
  app start finish that after a crash.
- `XboxGameManifest.load(folder:)` reads the copy's MicrosoftGame.config:
  `MSAAppId`, `MSAFullTrust`, `RelatedProducts` (for `XboxBridgeCopy`) and the
  `KnownDependency` names. `prerequisites(files:)` gives `VC14`'s installer when
  the package carries one at `Engine/Extras/Redist/en-us/vc_redist.x64.exe`
  (Nexus's one case). Otherwise Wine's own VC++ runtime stands in, as for the
  pilot. It runs through the app's prerequisites mechanism (decision 0079).
- The bridge's listener for the play. Its `guestEnvironment`, plus
  `WINE_WINHTTP_HTTP2=1` (patches/wine-gdk offers HTTP/2 only when asked), goes into
  `LaunchCoordinator.Request.guestEnvironment`: the game's environment only.
- PlayportKit's `GamingRuntimeKeys` (Gaming Services' version and the Store's
  WinRT class served by `xgameruntime.dll`) are topped up in the prefix.

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
`xodus-content-device-limit` and `xodus-offline-license` patches. The bridge
follows the same Xodus's `xodus-service/src/connection/{mod,xml}.rs`,
`licensing/content.rs` (`get_license_token`) and `proto/xodus/common.proto`, and
the same Nexus's `src/main/xodus-service.ts` and its `xodus-store-license`,
`xodus-license-sku`, `xodus-store-updates`, `xgameruntime-tcp-bridge` and
`xgameruntime-store-updates` patches. Derived files carry GPL-3.0-only provenance
headers; `LICENSE-Xodus.txt`, `LICENSE-XodusNexus.txt` and
`LICENSE-CikExtractor.txt` preserve the applicable notices. See
[LICENSING.md](../../docs/LICENSING.md#xbox-planned). The library follows Xodus
Nexus `e0668a12f1da931aed13537ef04295599011317b` (`src/main/catalog.ts`,
`src/main/account-library.ts`, `assets/xodus-subscription-login.patch`). The
install follows Xodus `53ea781dcd073e31d7ea68e894134e9c959bff04`
(`crates/msixvc/src/{xvd.rs,crypt.rs,hash_tree.rs,layout.rs,math.rs,streaming.rs,
streaming_ntfs.rs,models/xvd/}`, `crates/xodus/src/api/xbox/`,
`crates/xodus-cli/src/{package.rs,commands/streaming.rs}`). MSIXVC2 follows
Xodus pull request #219 (open; cyberps96/xodus `feat/msixvc2-support`) at
`e8194a89ea372c809015952bcab255e65b2b3089` (`crates/msixvc2/src/{cbor,crypto,
package}.rs`, `crates/xodus-cli/src/commands/extract.rs`); where it is silent or
inconsistent (CBC key wrapping and the rolling IV, GUIDs as text, box manifests
and seals, `Boxes/` names) the facts follow LukeFZ/XvdTool.Streaming pull request
#3 at `99db4dd3285b80cadcd60f21a311d909121a8944` (GPL-2.0; read for the format,
no code taken). Re-check both when #219 merges.

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
test key) served by a 127.0.0.1 range server. `msixvc2-synthetic.msixvc2` is a
synthetic MSIXVC2 (31 KiB: two chunks, two boxes, six files, compressed,
encrypted, shared and plain segments, a ZIP64 entry) written by
`Tests/msixvc2-fixture.py` with Python's zipfile, zlib and `cryptography`,
independently of the reader, under a test licence key (bytes 0x40…0x5f);
running the script again gives the same bytes. `msixvc2-synthetic-v2.msixvc2`
(`--v2`) is the same package as version 1.2.4.0 with two segments and the
config changed, a file removed and one added: the update tests' v2. The MSIXVC
update tests build their v2 with `XboxTestPackage.build(…, version:)`.

`PLAYPORT_BUILD=$PWD/.work ./pp test --swift XboxClientKit` runs public session
flows (exchange, relaunch, expiry/renewal/refusal, device reuse/replacement/reset,
sign-out during renewal, device limit, tampered response and logs), licensing
(content key, cache and expiry, offline lease, refusal versus network/service
error, logs), the bridge (framing, the cap, key, tickets per request, refusals,
logs, a real socket with a split and an oversized frame, sign-out closing it),
plus the independent FIPS-197/RFC-4231/RFC-3394/RSA vectors, and the install: the
pilot's real header, layout, regions, segment metadata and hash tree (a flipped
byte at each level found), IEEE 1619 and OpenSSL XTS vectors, cut and damaged
metadata (throw, never trap), stream-extract over HTTP ranges, resume after a
stop and a dropped connection, a byte flipped on the wire and on disk, the NTFS
fallback without SegmentMetadata.bin, licence and entitlement refusals, and
remove with and without saves.

The phone is a deferred gate: Microsoft sign-in/2FA, relaunch, sign-out/reuse,
and the passkey finding. The sheet assumes passkeys are unavailable in a
sideloaded web view and steers to Authenticator, code or password; no phone
finding is claimed. `pp ui` paths: `xbox:signin`, `xbox:wait`, `xbox:status`,
`xbox:signout`, `xbox:reset-device` (help in `tools/ui.py`).

The library's phone gate is deferred too: `./pp ui --action xbox:library --shot`
(signed in) shows the Xbox chip's copies with Microsoft's art and logs counts only.

The install's phone gate is deferred as well (signed in, the pilot in the library):
`./pp ui --action install:xbox-9MW9469V91LM --action xbox:installed:9MW9469V91LM --shot`
installs the copy from its page and checks it is adopted and every file verifies;
`uninstall:xbox-9MW9469V91LM` removes it keeping its saves (the page's Remove also
offers deleting them).

The play's phone gate (signed in, installed):
`./pp ui --play xbox-9MW9469V91LM --until first-frame+10 --shot`. A refusal ends the
run with `refused: <title>: <text>` (sign-in or licence).
