# SteamClient: native Steam protocol client

This package is the smallest separable native Steam client the app needs.
It is host-side Swift: it talks to Steam's CM servers over a WebSocket and to the content CDN over HTTPS.
It does not involve the guest, Wine or JavaSteam.
The pinned JavaSteam fork was used only as a behavioural reference.
No JVM object or port is part of the design.

`SteamClientKit` is the library: the session actor, PICS, the depot and CDN code, the whole-title install engine (`Sources/SteamClientKit/Install`), and the service layer the app's UI calls (`Service/`: `SteamService`, the Pair-screen model, title metadata and the art cache).
The app's Steam screens (`app/Sources/S1Probe/UI/`) are its only user; on the phone they are driven like any other screen (`pp ui`, docs/DEVICE.md).

## Test (Linux host)

```sh
cd app/SteamClient
swift test --build-system native     # offline tests, including a fake session for every pairing state; fixtures from tools/make-fixtures.py
```

`pp test` runs them too. The CM transport and the Keychain store exist only on Apple platforms, so nothing here talks to Steam from the workstation.

`SteamClientKit` is compiled with `-O` in every configuration (`Package.swift`), because xtool builds the app in its debug configuration and at `-Onone` the chunk pipeline is CPU-bound on the phone at about 0.2 MB/s.

## Design points

- **Pinned schemas.** `Wire/Schemas.swift` hand-pins every message field by its proto field number, from JavaSteam commit `433f2ad15c36d5e690a4fe77401ec3f6b960641e` in the [joshuatam/JavaSteam](https://github.com/joshuatam/JavaSteam) fork (MIT licence). The pin is by SHA in that fork: the commit is not on upstream Longi94/JavaSteam master. There is no protobuf code generation and no runtime reflection. `ProtoFields` type-checks every access. A field that changes wire type, a missing required field, an unknown section magic or an unknown chunk container becomes `SteamError.protocolChanged`, never a crash. The `PinnedSchema` enum in that file is the pin list.
- **Secrets.** Tokens, the QR URL, the request id, depot keys, the manifest request code and the machine id travel as `Secret<T>`, whose descriptions print `<redacted>`. Every log line also passes through `Redactor.scrub`, which removes JWTs, `s.team/q` URLs, query strings, bearer values and home paths. CDN logs name the host only. Account names and SteamIDs appear only as non-reversible tags (`acct#xxxx`).
- **Credential login.** `loginWithCredentials` sends the account name and the password, encrypted with the RSA key `GetPasswordRSAPublicKey` returns (PKCS#1 v1.5, `Crypto/RSA.swift`, checked against OpenSSL in `RSATests`), to `BeginAuthSessionViaCredentials`, then polls as the QR login does; a Steam Guard code typed meanwhile goes in through a `GuardCodeInbox` (`UpdateAuthSessionWithSteamGuardCode`). The password is a `Secret` used for that one call and never stored or logged. The approved refresh token is stored exactly as the QR login stores it.
- **Serialised auth.** The `SteamSession` actor runs QR and credential login, restore, renew and logout through `transition`, which admits one at a time. A concurrent second attempt fails with `invalidState` instead of interleaving credential-store writes.
- **Bounds.** HTTP and CM waits have deadlines. Retries are counted: 3 per request, then the next of at most 3 servers. QR polling tolerates 3 consecutive transport failures and reconnects when the CM drops the socket. Every await is cancellable, and SIGINT cancels cooperatively.
- **Content safety.** Before any file is chosen, the whole manifest is validated. Absolute paths, drive letters, `..` and `.`, control characters, stream separators, case-insensitive duplicates, symlink targets outside the root, chunks past a file's end and oversized chunks or sections each reject it. Every decompressor (inflate, gzip, zip, LZMA/VZip, zstd/VZstd) stops at the declared size, and the declared size must equal the manifest's. Staged files are opened with `O_NOFOLLOW`, and every existing path component is `lstat`-checked for planted symlinks.
- **Relaunch recovery.** The stage journals each chunk only after it is verified and `fsync`ed. A relaunch re-hashes journalled bytes on disk before trusting them.
- **Whole-title install** (`Install/`).
  - *Depot selection* (`DepotSelection`) keeps depots that are Windows or have no OS restriction, and that are 64-bit or arch-neutral. It keeps the default language plus the chosen one, and DLC depots only for owned DLC. It skips low-violence variants, and it skips `depotfromapp` redistributables, which it reports as not installed.
  - *The plan* (`InstallPlan`) is the union of the manifests. A later depot overrides an earlier one by path, compared without case. A path that is a file in one depot and a directory in another is refused. Symlink entries are counted and not installed.
  - *The engine* (`InstallEngine`) fetches each unique chunk once through a bounded task group. It writes each chunk by `pwrite` to every place it occurs. It `fsync`s data in batches, and only then appends to the journal: a fixed 32-byte record per verified chunk or file, with a CRC-checked tail. It hashes finished files by streaming `pread`.
  - *Free space* is checked before the first chunk and every 128 chunks: `volumeAvailableCapacityForImportantUsage` on Apple platforms, `statvfs` on Linux. The engine needs the bytes still to be written, plus 5% of the plan, plus the caller's reserve. A shortfall stops the job with `insufficientSpace` and keeps the stage. Each pre-flight logs the available and needed bytes. On the phone the Apple figure counts purgeable space, so it can be far above lockdown's `AmountDataAvailable`; a reserve meant to trip the pause has to be sized against the logged figure.
  - *CDN failures.* A server that fails 4 times in a row is dropped. A depot that every server refuses with HTTP 401, 403 or 404 fails as `unsupported`, because CDN auth tokens are not implemented.
  - *Commit.* The whole tree moves into place with one `rename`. Reinstalling the same app moves the old tree aside first; the install record is written before that old tree is deleted, and the next install sweeps any old tree a kill left behind, plus stages of other builds of the app.

## Platform seams

The code is platform-neutral Swift apart from two seams, both Apple-only.

1. **Credential store** (`Auth/SecretStore.swift`): `KeychainSecretStore`, Security.framework generic-password items, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronisable, service `dev.playport.app.steamclient`, in the app's own default access group unless `accessGroup` names one. `protection(_:)` reads back an item's group, accessibility and sync flag, never its data. It holds the paired session on the phone ([evidence](../../docs/evidence/2026-09-24-steam-pairing.md)). The Linux tests use `MemorySecretStore` or `FileSecretStore`.
2. **CM WebSocket transport** (`Net/WebSocketTransport.swift`): `URLSessionWebSocketTask`, whose `receive` delivers one whole message ("once all the frames of the message are available"). One CM packet is therefore one message by construction, and a message over `maximumMessageSize` fails instead of splitting. On Linux, swift-corelibs-foundation's `URLSessionWebSocketTask` splits messages, so the Linux host has no transport.

## Known limits

- The credential login has not run against Steam yet: its messages, the RSA step and every screen state are tested offline, and the screens were seen on the phone as a preview only.
- A real account has been verified live on the phone: QR pairing approved from a second device, restore, the license list, the owned library and a licensed depot key ([`docs/evidence/2026-09-24-steam-pairing.md`](../../docs/evidence/2026-09-24-steam-pairing.md)). `RevokeToken` against a real session and a refresh token Steam actually renews have not run yet.
- The `renew` single-write replacement is unit-tested only: Steam has not yet renewed a refresh token live.
- Updates (a manifest diff against the retained copy), delta patching, zstd dictionaries and CDN auth tokens (`GetCDNAuthToken`) are out of scope. A depot the CDN refuses is a typed `unsupported` failure.
- Staged files are sparse until written. The free-space check counts the bytes still to be written, not the bytes already allocated.
- HTTP bodies are size-checked after download, not streamed. The caps are 64 MiB for manifests and 16 MiB for chunks.
