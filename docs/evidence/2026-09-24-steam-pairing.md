# Steam pairing with a second device, on the phone

*The raw logs, tables and screenshots this record names were removed in the 2026-09-25 repository cleanup; they remain in git history.*

**Date:** 2026-09-24, 20:35–20:41Z. **Device:** the reference iPhone (iOS 27.0),
Playport upgraded in place. **Account:** the test account, shown only as
`acct#09a3` / `sid#9a5d` (`Redactor` tags).
**Result:** the first real sign-in on the phone. The captain scanned Playport's
code with the Steam app on a second device and approved it; the refresh token
went to the Keychain. The first logon after approval then timed out (a client
bug, fixed here); after the fix, every later launch logged on from the Keychain
with no approval, the owned library lists Hollow Knight, and the licensed depot
key for 367521, which the anonymous session is refused, is issued.

## 1. Builds

| IPA | sha256 | Tree | Used for |
| --- | --- | --- | --- |
| `Playport-26.5-49ce66ba.ipa` | `49ce66ba0c1055c5a7a7deafa3df66c49542df903317dff40640fe3bc4664a99` | `e8c01f6` | baseline, both pairings (§3) |
| `Playport-26.5-52b188d6.ipa` | `52b188d6d06db8ef6b4f3fac1afe9f840c1a9ab67cba54e71824b2d7a066961d` | `9e47679` (the Multi fix) | every run after §3 |

Both came from `build/build-from-pins --from app` and passed `verify-ipa`. The
second was installed over the first with `pymobiledevice3 apps install`; the
container, and the Keychain, were kept.

## 2. Baseline, before pairing (IPA `49ce66ba`)

- `01-status.txt`: `session: none`;
  only the machine-id Keychain item exists.
- `02-anon-sample.txt`: anonymous
  `sample 367520`: `GetDepotDecryptionKey(367521): EResult AccessDenied`.

## 3. Pairing from the Account screen

The app was opened with no `S1_MODE` (the new Steam games / Account /
Diagnostics tabs). `ui-pairing-log.txt`
is the app's own redacted `[ui]` log.

| Attempt | Code (fingerprint) | Scanned + approved | Outcome |
| --- | --- | --- | --- |
| 1 | `66XW` at 20:36:31Z | 20:36:36Z, first poll | token stored; logon timed out waiting for `ClientLogOnResponse` (751) |
| 2 | `PRAK` at 20:37:20Z | 20:37:25Z, first poll | same |

Both times, right after the approval, the log shows `dropped frame:
non-protobuf CM message 798`. EMsg 798 is `ClientUpdateGuestPassesList`, a
legacy (non-protobuf) message Steam sends after a successful account logon, in
the same `Multi` as the logon response. `CMPacket.expandMulti` threw on it and
the receive loop dropped the whole Multi, logon response included. Anonymous
logons never get that message, which is why no earlier run met it. The fix
(`9e47679`) skips legacy packets inside a Multi. A logon failure after an
approval now also falls back to a restore from the stored token, so the user
is never asked to approve twice. Both are unit-tested.

## 4. After the fix (IPA `52b188d6`, installed in place)

- `03-restore.txt`: `restore` logs on
  as `acct#09a3` from the Keychain with no QR and no approval.
  The token was stored by the *previous* build, so pairing survived an in-place
  upgrade.
- `04-status.txt`: the Keychain
  read-back: `keychain session: … own=true accessible=cku thisDeviceOnly=true synchronizable=false`
  (`cku` is `AfterFirstUnlockThisDeviceOnly`).
- `05-games.txt`: `games --refresh`:
  81 owned games, 78 could run; `app 367520 [Verified] Hollow Knight 5.23 GB`.
  The other lines are the account's purchase list and are not committed.
- `06-depots.txt`: `depots 367520`
  through the account session: 367521@257781644874438846, as pinned.
- `07-sample.txt`: `sample 367520
  --max-bytes 8000000`: `depot key: obtained`, the manifest (1,803 files,
  5,231,995,691 B), and 16 files / 21 chunks committed, SHA-1 verified. The
  anonymous session got `AccessDenied` for the same depot key (§2).
- The app's UI, launched again, restored silently (`[ui] … logged on as
  acct#09a3`, the last lines of the UI log) and showed the Steam games tab from
  the disk cache.

Each driver run is a new process launch, so runs 03–07 are also five
kill-and-relaunch restores, none of which asked for approval.

## 5. Is pairing really one-time? (design report §8.4, measured)

| Claim | Measured |
| --- | --- |
| Later sign-ins need no approval | **Yes.** Six launches after pairing (five driver runs, one UI launch) logged on from the Keychain token alone. |
| Pairing lasts until the token's `exp` | The first real token's `exp` is **2027-04-23T23:31:39Z**, about 211 days after issue. |
| Pairing extends without re-approval | `renewTokens()` ran once automatically after the first restore: Steam issued an access token and **did not** renew the refresh token (`result=not-due`). When Steam renews is still unmeasured; the service retries at most daily and records each result (`status` prints it). |
| Pairing survives an in-place upgrade | **Yes**, once: the token stored by `49ce66ba` restored under `52b188d6`. |
| Keychain item is per-device | `thisDeviceOnly=true synchronizable=false`, in the app's own access group (`own=true`). |
| Survives an uninstall | Not tested (it would wipe the prefix and staged titles). Assume re-pair. |

`logout`/`RevokeToken` was deliberately **not** run: the pairing stays in place
for the licensed install (P4).

## 6. Redaction

Every transcript passed `steam-device-run.py`'s leak check (no JWT, QR URL,
bearer or token value, container or home path, team ID); the UI log excerpt
passed `--scan`. Account and SteamID appear only as tags. No token, QR payload
or refresh secret was logged; the fingerprints are 20 bits of a hash of the
payload.
