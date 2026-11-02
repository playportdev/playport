# Xbox ground truth: Xodus Nexus plays Hollow Knight: Voidheart Edition on the workstation (PLA-487)

**Linear:** [PLA-487](https://linear.app/playportdev/issue/PLA-487), under the spec
[PLA-485](https://linear.app/playportdev/issue/PLA-485); plan
[PLA-485](https://linear.app/playportdev/issue/PLA-485), phase 0. Words as in
[GLOSSARY.md](../../GLOSSARY.md) and decisions [0179](../decisions/0179-the-xbox-store.md),
[0180](../decisions/0180-xbox-guest-tickets.md).

**Result.** On 2026-10-30, unmodified Xodus Nexus v0.4.1 installed the pilot (Product ID
`9MW9469V91LM`) from the test account's PC Game Pass access. Its runtime signed in to Xbox Live
by itself. The owner played into King's Pass and quit from the game's menu, and the runtime
uploaded the cloud save at exit. The gate is met with the pilot. The workstation now holds one
of the account's Microsoft Store devices (a synthetic one). It was **not** made the offline
device: the offline-PC setting was only ever read (`GET`), never set.

| Question | Answer |
|---|---|
| Package format | **MSIXVC**: an XVD (`msft-xvd` at 0x200), format version 3, Fixed, content type Title, flags `READ_ONLY \| REGION_ID_IN_XTS`, package 1.5.12620.0, drive 5,250,465,792 B. Catalogue: `Windows.Desktop`, x64, PFN `TeamCherry.15373CD61C66B_y4jvztpgccj42`, content `31f3afa5-02a7-4cd9-ac6e-4f4be4604ab8`, 5,281,849,344 B. The other two packages are `XVC` for `Windows.Xbox`. No MSIXVC2 |
| Kept encrypted | Two files only: `Hollow Knight.exe` (675,840 B on disk) and `UnityCrashHandler64.exe` (1,531,904 B). The package's `SegmentMetadata.bin` (173,210 B in its user data; corrected by PLA-497, which parsed the kept 44 MB prefix: this row first said the package had none) flags exactly these two `KEEP_ENCRYPTED_ON_DISK` among its 1,795 segments, the same set Xodus's NTFS-metadata fallback (every `*.exe`) gives. All 143 DLLs (`UnityPlayer.dll`, the GDK thunks, Mono) and the data are plaintext (`MZ`) |
| Bridge requests | One per launch: `MSA_TOKEN_REQUEST` (type 3), `ClientId` = the title's `MSAAppId` `000000004823914A`, `AllowUi` true, `MSAFullTrust` false. Reply (type 4, 4,475 B) carries `Token`, `Expiry`, `DeviceRps`, `DeviceExpiry`, `XboxMsaAccountId`, `StoreMsaAccountId`. No `STORE_LICENSE_TOKEN_REQUEST` (5) or `STORE_PACKAGE_UPDATES_REQUEST` (9) from this title |
| Xbox Live hosts (runtime) | `title.mgt.xboxlive.com` (`/titles/default/endpoints`, `/titles/current/endpoints`), `device.auth.xboxlive.com`, `sisu.xboxlive.com`, `xsts.auth.xboxlive.com` (one per relying party, then about once a minute), `profile.xboxlive.com`, `images-eds-ssl.xboxlive.com`, `titlestorage.xboxlive.com` |

## Versions

- Launcher: `Xodus-Nexus-0.4.1-x86_64.AppImage`, sha256
  `3ba5cce6a3d84bec3d7b2286cf878886f0b8dd3a6aea7635abe376a0237dbd4d` (release `candidate.json`,
  commit e0668a12; sha512 file verified). Run extracted, not changed.
- Backend: release `backend-v0.2.13` (upstream xodus `53ea781d`, patch recipe `linux-run-v72`,
  launch contract `linux-run-v25`, recipe sha256 `1e43af07…b6f5`). The launcher installs the
  newest backend release at or above its lock, so a later run may differ.
- Runtime: `runtime-11.0-20261028-ge5afe21e` (`nexus-runtime-11.0-experimental-ge5afe21e`,
  about 1.5 GB extracted). Its `XODUS_NEXUS_PATCH.json`: base Proton `7a94df49`, patch state
  `e5afe21e`, `xgameruntime.dll` sha256 `c3672c32…a6`. Features include
  `xodus-tcp-bridge-v1`, `cloud-saves-pr28`, `wine-winhttp-http2-v1`, `nghttp2-v1`,
  `xuser-offline-identity-v2` and `appmodel-package-identity-v1`. This is also the newest
  release at install time, not a pin.

## Setup

- Everything under a side worktree's `$PLAYPORT_BUILD/agent-notes/xbox-gt/`
  ([0117](../decisions/0117-side-copies-that-build.md)):
  - a scratch `HOME`/`XDG_*`;
  - the Electron profile (`--nexus-profile`);
  - the install root, the runtime and the Wine prefix.
- Account storage: a private D-Bus session bus without service activation, running a scratch
  `gnome-keyring-daemon` (secrets only). Nexus stores the account only in a Secret Service:
  four items under service "Xodus Service" (`dev_license`, `device-tokens`, `user-session`,
  `nexus-subscription-v2`). They were in the scratch keyring, never the owner's.
- Proxy: mitmproxy 12.3.1 on loopback, one listener per client:
  - the sign-in window (`--proxy-server`);
  - the launcher's Node and the Rust backend (`HTTPS_PROXY`, `NODE_USE_ENV_PROXY`);
  - Wine (`http_proxy`).
  Its CA was trusted only through the scratch NSS db, `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS` and
  `WINE_ADDITIONAL_CERTS_DIR` for the scratch prefix. It kept scrubbed summaries plus raw
  exchanges in a 0600 directory under `.work`. Those raw files are secret-bearing and
  uncommitted; credentials typed into the sign-in window were replaced by their lengths before
  writing.
- Bridge tap: a relay swapped in at `xodus-service`'s socket (`renameat2` exchange). It logged
  frame types and the non-secret request fields only.
- Shims: `pkexec` was refused, so the backend's SMBIOS read raised no polkit prompt. URL openers
  were refused too.
- Displays: the launcher and unattended runs used the headless sway session
  ([HOST-DEBUGGING.md](../HOST-DEBUGGING.md)). The owner cannot view it, so by the owner's
  instruction for this case the sign-in window was shown on the owner's niri session. For play,
  only the game was shown there: the launcher stayed on sway's Wayland socket with `DISPLAY` set
  to niri's X server, which the Proton game inherits.

## Sign-in, device and library (launcher and backend)

- **Sign-in window.** It loaded `login.live.com/ppsecure/InlineLogin.srf` twice, then made these
  calls:
  - `GetCredentialType.srf`;
  - `login.microsoft.com/consumers/fido/get` (the page offers passkeys; the password path was
    used);
  - `ppsecure/post.srf` three times;
  - `InlineClientAuth.srf`.
  - Page assets came from `logincdn.msftauth.net`, `aadcdn.msauth.net` and
    `lgincdnmsftuswe2.azureedge.net`, and telemetry went to `*.events.data.microsoft.com`.
- **Backend.**
  - `login.live.com/RST2.srf`, the token exchange; it repeats for every relying party and
    refresh.
  - `ppsecure/deviceaddcredential.srf`, the synthetic device. Its SMBIOS components were sent as
    errors `0x80070002` because `pkexec` was refused, and Microsoft accepted the device anyway.
  - `device.auth.xboxlive.com/device/authenticate`, `sisu.xboxlive.com/authorize`,
    `user.auth.xboxlive.com/user/authenticate`, `xsts.auth.xboxlive.com/xsts/authorize` and
    `title.mgt.xboxlive.com/titles/default/endpoints`.
- **Library.**
  - `POST beige.xboxservices.com/PCGAFD/entitlements/subscriptions`, then
    `GET /PCGAFD/entitlements`.
  - The first library page classified 798 entitlements: 771 Game Pass, 26 owned and 1 other.
    The pilot is Game Pass.
  - The catalogue came from `displaycatalog.mp.microsoft.com/v7.0/products` and the Store page
    from `apps.microsoft.com/api/Reco/GetComputedProductsList`.
- **Offline device.**
  - `GET beige.xboxservices.com/pcgafd/config/offlinepc` twice. Nothing else touched it; there
    was no `POST …/offlinepc/true`.
  - Nexus did write a device-bound lease for the pilot into its `license-cache` from a `run`.
    `run --license-cache` stores whatever lease Microsoft issues (binding `Machine`,
    `leaseRequired`). That is the normal content-licence lease, not a designation.

## Install

- The plan offered the `Windows.Desktop` MSIXVC as the only supported choice.
- `packagespc.xboxlive.com/GetBasePackage/31f3afa5-…` returned the file list and CDN roots.
- The download was **plain HTTP** from `assets1.xboxlive.com` (user agent `xodus-cli/0.1.0`):
  about 1,570 `Range` requests of 20 KiB to MiB pieces. Nexus fetched the XVD header and
  metadata into `.xodus-streaming.msixvc` (44 MB) and decrypted file by file into the install
  directory. The 5.0 GB install took about two minutes.
  - Because the URLs are `http://`, the backend's `reqwest` used `http_proxy` for them, the
    listener meant for Wine; the client label in the raw summary is therefore Wine's.
- `POST licensing.mp.microsoft.com/v7.0/licenses/content` came once at install and once at each
  launch:
  - request fields: `concurrencyMode` "Rude", `licenseVersion` 4, `keyOnly` true, a client
    challenge, and the user as an MSA RPS ticket keyed by a Windows SID string;
  - reply: `license.keys[]` (`drmType` "Mkms", a key id, the wrapped key) and `license.leases[]`.

## Launch

- **Decrypted copies.** `xodus-cli run … --materialize-chain` made
  `<installRoot>/.xodus-chain-*` (0700), removed at exit. Inside: the two decrypted executables
  (`Hollow Knight.exe` 672,256 B, `UnityCrashHandler64.exe` 1,531,824 B, i.e. the ciphertext
  without its page padding) and 16 symlinks to the install.
- **Memory mapping.** The game process also got both executables as memfds:
  `WINE_DLL_FILE_MAP` (NT paths) and `WINE_EXE_FILE_MAP` (Unix paths), fds 29 and 31.
- **Environment.**
  - `XODUS_BRIDGE_PORT`/`XODUS_BRIDGE_KEY`, `XODUS_SOCKET`, `XODUS_SAVE_SYNC=auto`,
    `XODUS_XSTS_PLAYFAB` (set), `XODUS_ACCOUNT_HASH` and `XODUS_OFFLINE_IDENTITY`;
  - `WINEDLLOVERRIDES=…;winhttp=b;libnghttp2=n` (the runtime's WinHTTP with HTTP/2).
- **Runtime sign-in** (auth metadata log):
  1. `init-default` (title.mgt);
  2. `init-tickets`, the bridge's MSA token;
  3. `init-device` (device.auth);
  4. `init-sisu` (sisu with device, user and title tokens);
  5. `init-current`, then `init-complete`;
  6. XSTS per relying party and a refresh about every 60 s.

  All HTTP 200, HTTP/2 through the CONNECT proxy, with the CA from `WINE_ADDITIONAL_CERTS_DIR`.
- **Cloud saves.**
  - The first `GET titlestorage…/connectedstorage/users/xuid(…)/scids/<scid>` gave 404: no
    container yet.
  - One `PUT …/lock` 15 s after start went out as HTTP/1.0 and got 400 `text/html`. Not
    diagnosed: possibly a proxy artefact.
  - At exit, two rounds of `PUT …/lock` → `PUT <blob guid>,binary` → `PUT save1,savedgame` /
    `sharedData,savedgame` (201) → `DELETE …/lock`. The `save1` blob was 64,454 B.
  - The game exited with code 0.
- **Launcher during play.** `userpresence.xboxlive.com` presence `POST` every minute and `DELETE`
  at exit, plus social polls (`peoplehub`, `xblmessaging`, `notificationinbox`).
- **First unattended run (sway).** The game reached its first-start language list at 1920x1080
  on DXVK. The screenshot stays in the run directory.
- **Second run (game on niri).** The owner picked the language, started a new game, played in
  King's Pass and quit from the in-game menu. No screenshot was taken of the owner's session;
  the uploaded `save1` is the record.

## Limits and leftovers

- Raw exchanges and the redacted fixtures cut from them stay in `.work`, outside the
  repository. That is 40 fixtures: one per client, method, host and path shape, with tokens,
  ids, gamertag and email removed. The redactor and its leak check live in the scratch
  directory.
- An `ss` check at one moment of the play showed no direct, unproxied connection from the game;
  that is a snapshot, not a full accounting. One `GnuTLS error: A TLS fatal alert has been
  received` in the game log is not attributed to a host.
- The workstation's synthetic device and its lease remain in the scratch keyring and
  `license-cache` until that directory is deleted. Removing the device from the account's
  Store device list is the owner's choice (account.microsoft.com/devices/content).
