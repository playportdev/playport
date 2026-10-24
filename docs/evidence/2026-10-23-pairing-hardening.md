# Pairing hardening on the native macOS build

Work started 2026-10-23 and continued 2026-10-24. This records local checks;
it is not a claim that gameplay or every dependency has been audited.
This evidence was recorded before pushing the security changes for owner
review in the fork. No upstream pull request has been submitted.

## Confirmed signer and storage boundary

The first signed build gave the main executable and helper the same
application identifier/default Keychain group. xtool discarded extension
entitlements, and its signer used the first array entry for every bundle.
Provisioning had already produced distinct profiles.

`patches/xtool` and `patches/zsign` preserve an exact canonical bundle-path
mapping, select the root independently of mapping order, and reject a missing
app/extension mapping for real signing. Frameworks receive no application
entitlements. Unsigned builds may omit nested mappings, with empty rights.
The signer integration test uses synthetic bundles and no account credentials.
It passed forward/reverse mapping, missing-root/missing-helper refusal and
framework-rights checks.

Dev IPA:

- `.work/out/20261024-001007-ae4b5b1a/Playport-26.5-ae4b5b1a.ipa`
- SHA256 `ae4b5b1ac5f1435dda8ae27add194a3f5152405ce414388d681df96db05d4e56`
- 89 IPA checks passed, including separate groups, the extension's code/profile
  identity match, and no application rights in the framework.
- Upgraded the phone in place; the container was retained.
- `.work/ui-runs/20261024T001404`: `probe:pairing-isolation` completed with
  `ok actions=1`, result `ok: true`. The helper created and read a synthetic
  item; main was denied access to that same live item; helper removed it.
  No actual pairing credential was read by the test. Screenshot stays in the run.

## Credential flow

On-device generation and current/pending records now stay in the helper.
XPC returns candidate tokens and revisions, never stored pairing bytes. JIT,
preparation and CoreDevice relaunch read credentials inside the helper.
The vault uses one WhenUnlockedThisDeviceOnly, non-syncing item and a bounded
cross-process file lock around read/compare/write. A runtime guard checks the
actual default group using a nonsecret marker, then uses that explicit group
for credential queries. This guard was added after the first phone run above; the later final dev
run below exercises it.

Legacy import is idempotent when helper already holds the same record. An
existing different record is preserved until an explicit repair. Reading an
imported key permanently disqualifies that process from initializing Wine;
a clean restart is required. Wine independently refuses any remaining legacy
Keychain item or dropped pairing file, including with an external JIT provider.

StikJIT is built from its pinned sources with a Data API and the same patched
idevice source as the C wrapper. No new plaintext pairing file is created.
Matching files left by the previous API are removed at helper startup. Secret
and raw pairing-payload debug dumps are removed. TLS Finished, framing and
padding checks fail closed. The listener has bounded handshake attempts.

## Peer authentication and checks

`0003-authenticate-pairing-peer.patch` pins the raw identifier and long-term
public key after verifying the SRP-bound setup signature. Pair Verify decrypts
and verifies M2 against that pin before signing M3. Non-contributory X25519
and wrong states fail; authentication failure cannot trigger enrollment or a
tunnel request. Old records without the peer pin require explicit re-pairing.

- 26 selected Rust library tests passed, including a real TLS duplex handshake
  with authenticated but invalid Finished, malformed padding/framing, setup
  signature/round-trip tests, and mock connect failures proving no M3,
  implicit enrollment or listener request for an unauthenticated peer.
- The host `idevice-tools` CLI check passed with the explicit USB enrollment
  command updated for the new connect policy.
- Seven JITKit host tests passed: pending/current separation across helper
  restart, stale-token/revision refusal, failed-write preservation, corrupt
  storage, idempotent migration, competing writers, and non-helper rejection.
- `pp test --quick` passed: 596 Python tests and host C gates. Three stale
  fixtures were corrected for inherited Xcode environment, native Rust
  selection and the additional JITKit host package. Targeted identity tests
  also cover wildcard/shared groups and a wrong default group.
- Final `pp test` passed: 597 Python tests, host C gates (including pad
  ThreadSanitizer), and all seven Swift packages. Log stays in
  `.work/security-final-host-tests.log`.
- Linux source-build configuration was checked against xtool's SwiftSDK:
  it explicitly selects the Darwin iPhoneOS Swift resource directory and
  cctools linker. A Linux IPA build has not been run here.

Strict peer-auth dev IPA:

- `.work/out/20261024-003130-3bf3e3d5/Playport-26.5-3bf3e3d5.ipa`
- SHA256 `3bf3e3d50c50cb911fc717e78e72da243ae54177e0fc8d41af876bedfa23b1c3`
- 89 IPA checks passed; upgraded the phone in place.
- Automated launch for pairing did not complete in 20 seconds. No pairing
  code was shown by that run; manual opening of the app was requested.
- After the owner opened Playport and completed pairing, the log pulled to
  `.work/security-manual-pair-log` shows a helper candidate without exported
  credentials, successful DDI download/mount, `device ready`, `ready, TXM present`,
  and `verified pairing committed to Keychain`. The checklist then reports
  on-phone pairing and the VPN up. This exercises the strict setup and subsequent
  authenticated connection on this iOS version; it is not a gameplay test.

Unsigned release IPA (including the runtime default-group guard):

- `.work/out/20261024-005611-release-unsigned-3a7eb1d7/Playport-26.5-release-unsigned-3a7eb1d7.ipa`
- SHA256 `3a7eb1d7103e48c1de9ab32adb5dc8b3c50a8696e794d933d11bd5ea41d5cf75`
- 84 IPA checks passed. The first attempt exposed a missing JITKit link in
  release staging; adding it fixes local dependency resolution. A regression
  checks every local Swift package is linked (15 notice-input tests passed).

Final dev IPA (runtime default-group guard included):

- `.work/out/20261024-011155-4ed1b9cb/Playport-26.5-4ed1b9cb.ipa`
- SHA256 `4ed1b9cb405d7523d28c793e48a68927bccc86b80222b334c8d7f38c1ec752dd`
- 89 IPA checks passed; upgraded in place with the container retained.
- `.work/ui-runs/20261024T011243`: isolation probe, setup, readiness wait and
  import all completed (`ok actions=4`, result `ok: true`). Existing pairing
  survived the upgrade. Helper preparation reported `device ready` and
  `ready, TXM present`; vault reads exercise the runtime default-group guard.
- The owner's Windows GOG folder, staged as a ZIP, imported through the UI as
  `dir-hollow knight gog 89718`, status Ready, executable `Hollow Knight.exe`.
  This is a local import, not a Steam install or an ownership verification.

First game smoke: `.work/ui-runs/20261024T011405`, same final dev IPA.
JIT acquisition succeeded (`acquire(512 MiB) -> 0`), the runtime started and the
title started, but exited `0xc0000005` before the first frame. Playport relaunched
and helper readiness succeeded again. No touch action ran. The failure log
identifies `libarm64ecfex.dll+0x1192c8`, instruction `0x880afea9`
(`stlxr w10, w9, [x21]`), writing its native backpatch lock in the RX pool.
The Mach store path found a valid writable alias but did not decode STLXR.
The macOS FEX build used generic ARMv8 without LSE after disabling Linux CPU
probing. A compiler probe with the same ARM64EC compiler confirms that adding
LSE changes this compare-exchange from LDAXR/STLXR to CASAL, already supported
by the Mach path. The Darwin-only `TUNE_ARCH=armv8-a+lse` fix leaves the Linux
options and component pins unchanged. The app requires iOS 26, whose supported
device baseline has LSE. The rebuilt DLL's exact HandleUnalignedAccess function
uses CASAL (`.work/fex-lse-unaligned-disassembly.txt`).

Corrected dev IPA:

- `.work/out/20261024-012353-8946a191/Playport-26.5-8946a191.ipa`
- SHA256 `8946a191d2d84e6541189566e57bafb86d8f1e1e2db75a98d1cc8c90ca518691`
- 89 IPA checks passed; installed in place, game and pairing retained.
- `.work/ui-runs/20261024T012525`: automatic launch attached the debugger, then
  failed with `Socket(Kind(AddrNotAvailable))` while preparing the JIT pool.
  It did not reach the game. The cause of this intermittent connection failure
  is not established. No automatic retry was issued.
- The owner then launched successfully. `.work/macos-fex-lse-manual/s1-host.log`
  records successful JIT prepare/blessing/detach (2.75 s), runtime initialization,
  `[mach-cas]` handling the formerly failing native lock, and first frame at
  +11.52 s. The screenshot in that directory shows the rendered game background
  and on-screen controls. It stays private under `.work`.
- `.work/macos-fex-lse-manual-later/s1-host.log` shows the runtime still alive
  at +60 s (over 10 s after first frame), finger input, nonzero stick axes,
  virtual-pad button presses, and simultaneous A (`0x1000`) with left-stick
  input followed by a neutral state. These are actual touchscreen inputs,
  not the scripted touch driver. The owner confirmed simultaneous movement,
  jumping and attacking, resolving an initial suspicion of a two-touch limit.
- The owner also confirmed a wired Xbox controller works on the iPhone via
  a USB-C adapter, on the same installed build. This is an owner-reported
  manual check; no automated controller run or model-specific trace was captured.

The local smoke and physical multitouch checks passed. Longer gameplay and
performance have not been measured. The intermittent debugger connection
failure above remains unexplained.
The anonymous XPC endpoint and PID restriction are not a signing-identity
authentication claim. Other store credentials in the main process and a full
Wine/FEX sandbox are outside this pairing-store change.
