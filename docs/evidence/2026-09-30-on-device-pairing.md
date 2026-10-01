# On-device RP pairing experiment

**Status:** same-phone pairing proven, and the product flow (pair, verify,
save, Play) passed on the phone in one run. First-run-with-no-pairing and
release are not yet checked on the phone.

## Inputs and source findings

- Tested phone: iOS **27.0 (24A437)**, queried through lockdown without
  persisting device identifiers.
- `pins.lock` idevice `d32c8189c51c2789496b0768039419c3705498c3`
  implements `PairableHost`, SRP and RP pairing-file serialization.
- `remote_pairing` is already enabled transitively by `tunnel_tcp_stack` in the
  idevice build. Only its four restart calls were exported to the app.
- The pinned FFI owns raw mDNS advertising and generates its PIN after a peer
  connects. Neither is suitable for an app that must send the person to Settings.
- [StikPair's README](https://github.com/StikDebug/StikPair#use), checked during
  this work, describes same-device pairing on iOS 27: Settings, Privacy &
  Security, Developer Mode, **Pair with StikPair**, then a PIN in a Live Activity.
  This is external documentation, not a successful Playport experiment. Its
  implementation is not used here.

## Implementation under test

`patches/idevice` adds caller-provided Bonjour advertising and a caller-provided
six-digit PIN, preserving upstream's existing entry points. The callback hands
XML credentials to the app in memory; nothing writes them to Documents or logs.
The pin is unchanged. The patch has not been offered upstream yet.

The dev-only Settings probe publishes the generated identity/TXT/port with
`NetService`, shows the code before leaving Playport, and holds an iOS background
task. Timeout, Cancel, publication failure and background expiration cancel the
Rust accept and stop advertising. Existing Keychain credentials remain unchanged
until the person explicitly chooses **Use new pairing**.

## Host checks

- `pp test --quick`: passed; names and secrets clean, patch-series checks,
  109 tooling tests, and all host C tests (including pad ThreadSanitizer).
- The patched idevice FFI compiled for `aarch64-apple-ios` and staged its archive.
- Initial Swift compilation caught the Bonjour delegate's isolation and a
  dynamic `Self` capture in a C callback. Fixed by main-run-loop publication
  with a checked `@preconcurrency` delegate conformance and a concrete singleton
  reference in the callback. The signed dev build passed all 70 IPA checks and
  installed as an in-place upgrade (container kept).
- Read-only lifecycle review found no blocking callback/token lifetime,
  cancellation, ABI, TXT/identity or series/digest issue. This is static review,
  not a phone result.

- `pp check --variant release`: unsigned release app compiles. The verifier's
  four release-isolation checks passed on that executable, including absence
  of the pairing probe's Swift types and driver strings. This is not a signed
  release IPA or a release phone test.

## Product implementation after the experiment

Not yet checked on the phone.

- `OnDevicePairing.swift` is now product code. The dev section and actions are
  thin controls over the same model.
- Setup is root-owned and appears only when iOS 27 has no pairing. It stages the
  new record in memory, connects LocalDevVPN, and runs readiness on those exact
  bytes. It saves to the Keychain only after readiness: an insert-only add for
  first setup, a compare-and-replace for Pair again, so a failure or an
  intervening import is not overwritten.
- Game Play and the UI driver both await the same setup before `TitleLaunch`;
  the pending Play continues only after the sheet has dismissed. Nothing
  pending persists across a cold launch.
- Cancellation, an iOS background expiry, publication failure and a timeout stop
  Bonjour, cancel the Rust accept and discard the in-memory record.

## Product flow on the phone

IPA `.work/out/20260930-154144-7dfcc8ab/Playport-26.5-7dfcc8ab.ipa`, SHA256
`7dfcc8ab3c0afb495e2966f60483af2cdce5ca7b6333acdfec83b3635d4018eb`, installed in
place (dev). Host: `pp test --quick` passed; dev and release `pp check` passed;
release-isolation checks passed on the unsigned release executable.

1. **Existing pairing, no sheet.** `pp ui --play app-367520 --until
   first-frame+10` passed (`.work/ui-runs/20260930T154216`): JIT 3.10 s, first
   frame +8.87 s. Play went straight through `JitSetup.ensureReady`.
2. **Pair again, then Play, one run.** `pp ui --action jit:pair --action
   jit:wait --play app-367520 --until first-frame+10` passed
   (`.work/ui-runs/20260930T154315`). The person paired in iOS Settings and
   returned without touching Playport. The log shows Bonjour published,
   credentials received, readiness `ready, TXM present` on the in-memory record,
   then `verified pairing committed to Keychain`. The sheet dismissed itself
   about 32 s after it opened; Play followed: JIT 3.13 s, first frame +8.86 s,
   ran to first-frame+10. There was no Use step, no file and no computer.

Not yet checked on the phone: the automatic sheet on a install that has no
pairing at all (it needs a new signing identity or a consenting fresh tester;
the current record is not deleted to fake it), the release variant, Cancel,
background expiry, Local Network denial and LocalDevVPN not installed.

## Reaching Settings and keeping the code in view

**Settings links** (`probe:settings-url-N`, Settings closed before each so it
could not resume its last page; screenshots in `.work/pairing/links/`). iOS
27.0 (24A437), IPA `4d5605360fc5…`:

| Link | Opens | Lands on |
| --- | --- | --- |
| `App-prefs:Privacy&path=DEVELOPER_MODE` | yes | Settings' Apps list |
| `App-prefs:root=Privacy&path=DEVELOPER_MODE` | yes | Settings' Apps list |
| `prefs:root=Privacy&path=DEVELOPER_MODE` | no | — |
| `App-prefs:DEVELOPER_SETTINGS` | yes | Settings' Apps list |
| `App-prefs:Privacy` | yes | Settings' Apps list |
| `App-prefs:` | yes | Settings' top level |

No link reaches Privacy & Security or Developer Mode from a third-party app.
The bare `App-prefs:` is the best available: Privacy & Security is one tap
from there. Open Settings uses it, with Playport's public Settings page as the
fallback.

**Pasting the code:** the person reported the pairing field did not accept
paste. Copying the code was removed.

**Floating code window.** A picture-in-picture window showing the code (a
sample-buffer layer, `UIBackgroundModes` audio) floated over Settings; see
`.work/pairing/links/pip-settings.png`. Then
`pp ui --action jit:pair --action jit:open-settings --action jit:wait --play
app-367520 --until first-frame+10` passed (`.work/ui-runs/20260930T155707`, IPA
`4d5605360fc5…`). The person paired from the floating code and went back with
◀ Playport. Log: Bonjour published, credentials received, `ready, TXM
present`, verified pairing committed. Setup to dismissal took 34 s; then JIT
3.09 s and first frame +9.72 s, running to first-frame+10.

The build without the copy step (`9d934ae2ab4b…`) passed an ordinary
`--play app-367520 --until first-frame+10` (`.work/ui-runs/20260930T155943`,
JIT 3.09 s). Its pairing path differs from `4d5605360fc5…` only by the removed
copy.

Whether the floating window keeps Playport running past iOS's background time
limit, as it should with active picture in picture, has not been measured. Each
pairing so far finished within about 35 s.

## Phone results

Installed initial probe IPA:
`.work/out/20260930-145721-eaadf7e6/Playport-26.5-eaadf7e6.ipa`, SHA256
`eaadf7e6930a4e390dc33b08ef556f58b0a6c23dc90cec5a7c4563f8d31466ad`.

`pp ui --action open:settings#pairing --shot-each-action --leave-running`
passed on this IPA. The screenshot shows the experiment button and **Not started**.
Run: `.work/ui-runs/20260930T145843`. Automatic readiness with the pre-existing
credentials reported the LocalDevVPN endpoint unreachable; the person was asked
to connect it, with no automatic retry.

The initial `probe:pairing` driver run
(`.work/ui-runs/20260930T150027`) did **not** start the listener: launch-time
readiness was still busy. Its action completion was not pairing success. The
person was asked to start with the in-app button after readiness finished.
The driver now waits for readiness and rejects a refused start; it also waits
for pairing before `probe:pairing-use` in the same run, because a later `pp ui`
relaunch would discard the deliberately in-memory credentials. These driver
corrections passed `pp check` (unsigned dev compilation), but are not yet in
the installed initial probe IPA. A later probe-panel fix also passed `pp check`:
after Use, it now shows the live readiness value and offers Connect LocalDevVPN
instead of leaving a stale **Checking readiness…** message. This UI correction
is not in the initial tested IPA either.

## Same-phone pairing result

The person at the phone confirmed **Pair with Playport** appeared in iOS
Settings, pairing completed, and they tapped **Use new pairing**. The existing
process log shows Bonjour publication followed by credentials received, twice
(the person repeated the experiment); neither attempt logged credential bytes.
The screenshot after the last attempt shows **New pairing stored in the
Keychain** and no remaining Use button. No exported or computer-generated file
was involved in these attempts.

Evidence retained only under `.work/pairing/after-pairing/`: `s1-host.log` and
`status.png`. Same initial probe IPA/hash as above. This proves the same phone
can discover and pair with Playport while the app is backgrounded for Settings.

Readiness after each Use timed out at the LocalDevVPN endpoint. The person was
asked to connect LocalDevVPN and check readiness; no automatic retry or game
launch followed that timeout.

After the person connected LocalDevVPN, they reported **Ready**. A fresh driven
launch corroborated **prepare: device ready** and **ready, TXM present**, proving
the generated Keychain credentials survived relaunch and opened the tunnel/DDI
path. Run: `.work/ui-runs/20260930T150739` (same IPA/hash). That play itself was
refused because Hollow Knight was not catalogued yet. The person explained they
had removed Playport earlier, which deleted its game container, and then
reinstalled Hollow Knight through the UI. No deletion/uninstall was requested
as part of this experiment.

## Play result

`pp ui --play app-367520 --until first-frame+10 --shot` **passed** after Hollow
Knight was reinstalled. Run: `.work/ui-runs/20260930T151023`; same initial probe
IPA SHA256 `eaadf7e6930a4e390dc33b08ef556f58b0a6c23dc90cec5a7c4563f8d31466ad`.

- JIT acquire: **3.29 s**, 896 MiB pool.
- Runtime started: **+4.01 s**; game started: **+4.08 s**.
- First frame: **+11.30 s**; run completed at **first-frame+10**.
- Self-check passed; no JIT exhaustion or host mapping refusal reported.

This proves same-phone pairing produces credentials usable for JIT over
LocalDevVPN, across app relaunches. It does not prove automatic release
onboarding yet. Fresh-install acceptance, background expiration and cancellation
remain untested. Never include PINs, device identifiers, identity TXT records,
credentials or raw pairing logs.
