# Plan: self-contained JIT setup for a tester

**Date:** 2026-09-30. **Status:** same-phone pairing experiment passed on iOS
27.0 (24A437), including readiness and Hollow Knight first-frame+10; automatic
product setup (Pair again, then Play) also passed on the phone; a first run
with no pairing and the release variant are not yet checked on the phone. Phone results belong in
[the evidence record](../evidence/2026-09-30-on-device-pairing.md).

## Goal and acceptance boundary

The tester installs the IPA and completes any unavoidable setup **on that same
phone**. No tester guide, terminal, computer-generated pairing file, exported
file, second pairing app or file fetched from us. The app explains the next
necessary system action in context and resumes setup when the person returns.

Sideloading/signing the IPA is the starting boundary. iOS requires a person to
approve Developer Mode and permissions; Playport must not claim to do those
silently. LocalDevVPN installation and its first VPN approval are on-device
steps today. The IPA already includes the JIT helper and protocol script;
StikJIT downloads and mounts the Developer Disk Image automatically.

Success means a release install without Playport pairing credentials reaches
Hollow Knight's first frame after on-device setup only. Existing Keychain
credentials must not be destroyed to simulate this: use a separate test identity
or a consenting fresh tester, never uninstall the current app.

## Feasible pairing path

- On **iOS 27**, a host advertises
  `_remotepairing-pairable-host._tcp`. The phone selects it in Settings,
  Privacy & Security, Developer Mode, and enters the host's six-digit code.
- [StikPair documents same-device pairing](https://github.com/StikDebug/StikPair#use)
  on iOS 27. That removes the old assumption that self-discovery is wholly
  unknown, but Playport still needs its own phone evidence. Its implementation
  is not used here.
- The pinned idevice `d32c8189` implements the host protocol. Its
  `remote_pairing` feature is already enabled transitively by `tunnel_tcp_stack`;
  the build currently exports only the restart interface.
- The existing host FFI uses raw mDNS sockets and generates its PIN after
  connection. An iOS host should publish via Apple's Bonjour, without the
  restricted multicast entitlement, and know the PIN before leaving the app.
- An RP pairing record contains per-phone trust credentials and long-term host
  keys. It cannot be bundled as a generic secret in the IPA. Generate it locally
  and store it directly in the existing this-device-only Keychain item.
- On **iOS 26**, no equivalent on-device provisioning path has been established.
  File import stays for existing users, but is **not** acceptance of this goal.
  If no such path is found, self-contained first-time setup requires iOS 27;
  do not quietly replace the goal with a computer recipe.

## 1. Same-phone experiment, before product setup

A dev-only Settings UI and corresponding `pp ui` actions:

1. `patches/idevice` adds platform-advertising callbacks and a caller-provided
   PIN, with cancellation and borrowed credential bytes. Keep the upstream pin
   and existing APIs unchanged; include the series in the build digest and apply
   it to a build copy, never to the cached upstream checkout.
2. Publish the generated service identity, TXT records and listener port with
   `NetService`; declare the Bonjour service and Local Network purpose.
3. Show the PIN before switching apps. Begin bounded background execution;
   Cancel, timeout, advertising failure and iOS expiration stop advertising and
   abort the listener. Do not expose pinless trust on the local network.
4. A person approves Local Network access, opens Developer Mode in iOS Settings,
   selects Playport and enters the code. The workstation cannot drive that UI.
5. Keep returned credentials in memory, with no file export or secret logging.
   The experiment's **Use new pairing** explicitly replaces the Keychain record;
   starting or cancelling an experiment leaves existing credentials alone.
6. Check readiness and play Hollow Knight through the existing UI, to
   `first-frame+10`, using the newly generated credentials over LocalDevVPN.

**Done when** the evidence record includes the IPA sha256 and exact iOS build,
Bonjour discovery, Settings pairing, background lifetime, readiness and play
results. A published service alone is not success.

## 2. Automatic first-run / Play setup, only after the experiment works

- On a fresh install or a Play without credentials, start one resumable setup
  flow; no hunt through Settings and no import/export step.
- Detect what can be detected (signature, stored pairing, reachable VPN and
  readiness). Show only the next missing requirement, never a static checklist.
- Route to LocalDevVPN's App Store page if absent, activate it once approved,
  and resume when Playport returns. Developer Mode and system permissions stay
  explicitly user-approved.
- For pairing, generate a one-time PIN and advertise only during the explicit
  setup attempt. Explain the exact Settings destination in-app. A Live Activity
  can keep the PIN visible while in Settings; do not require notification
  permission just to finish setup. Verify that background time covers the flow;
  handle suspension/expiration with a clean retry, not a stuck spinner.
- On completion, stop advertising, validate the generated record and use it for
  readiness. Store valid credentials in the Keychain automatically; retain any
  existing working record until replacement is proven. Continue the original
  Play request after preparation rather than asking the player to start over.
- Gate first-time self-pairing on iOS 27. Keep import only as an advanced recovery
  path, not the recommended tester experience.
- Add a decision record for locally generated pairing credentials and bounded
  Bonjour advertising. Offer the idevice interface upstream after validation.
- The dev UI driver drives the same flow (decision 0012); system approval still
  needs a person once. Release carries no probe/driver controls (decision 0009).

**Done when** a freshly signed release IPA on an iOS 27 phone with no Playport
pairing record reaches a first frame with only same-phone interaction. Repeat
launch, reboot, denied permission, cancellation and expired background time must
also leave recoverable state. The tester needs no external instructions.

## Risks / remaining questions

- The actual phone must show and connect to Playport's Bonjour registration.
- The resulting credentials must work over LocalDevVPN, not only Wi-Fi onboarding.
- `beginBackgroundTask` grants finite, system-controlled time; it is not a
  guarantee of 30 seconds or enough time for every person.
- The Settings destination / pairing protocol can change in an iOS point release.
- iOS 27 JIT itself is not settled on every chip ([runtime risks](2026-09-27-runtime-risks.md#1-whether-jit-keeps-working-after-the-next-ios-update)).
- Re-signing changes Keychain access groups; the same-phone flow must be able to
  create new credentials, rather than assuming an earlier install's record.
