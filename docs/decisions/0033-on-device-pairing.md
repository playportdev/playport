# 0033: Generate JIT pairing credentials on this iPhone

**Status:** accepted, 2026-09-30. The [phone experiment](../evidence/2026-09-30-on-device-pairing.md)
proved same-phone Bonjour discovery, pairing, readiness and Hollow Knight
first-frame+10 on iOS 27.0 (24A437). Automatic product setup remains to be
implemented and verified ([plan](../plans/finished.md#self-contained-jit-setup-for-a-tester)).

## Decision

- First-time JIT setup on iOS 27 generates its RP pairing credentials inside
  Playport. A tester does not generate, transfer, export or import a file on a
  computer. Signing/sideloading the IPA remains outside this setup boundary.
- An explicit setup attempt advertises a host through Apple's Bonjour
  (`_remotepairing-pairable-host._tcp`), with a Local Network purpose string.
  idevice handles the TCP/SRP protocol; `patches/idevice` separates platform
  advertising and allows a random six-digit PIN to be known before leaving
  the foreground. No restricted multicast entitlement or raw mDNS daemon is
  needed by the app.
- The person approves iOS permissions and pairs in Settings, Privacy & Security,
  Developer Mode. System trust is not bypassed: no silent/pinless host is
  advertised. Advertising exists only for the bounded attempt and stops on
  completion, cancellation, failure or background expiration.
- Generated credentials go straight from memory to the existing unsynchronised,
  this-device-only Keychain item, never into Documents, logs or evidence. Product
  replacement must preserve an existing record until the new one is proven.
- The product setup flow handles the next missing requirement and resumes a
  pending Play; it does not send the tester to a guide. LocalDevVPN installation
  and its initial VPN approval remain same-phone steps. The app cannot include
  its own packet tunnel under a free team's entitlements.
- iOS 26 import remains an advanced compatibility/recovery path, not fulfilment
  of computer-free first-time setup. No on-device pairing path is established
  there. Dev probes stay out of release (0009); the driver calls the same UI
  model as the person (0012).

## Why

Pairing credentials represent one phone's trust in one host identity. A generic
file in the IPA would not pair another phone and distributing our record would
expose our debug access. Acting as the host on the phone itself removes the
external-file requirement without changing JIT's trust protocol.

## Limits

Background execution is finite and controlled by iOS. The setup UI must make
expiration recoverable, not promise an indefinite listener. A reboot,
permission denial, signing-team change and a truly fresh release install still
need product validation. Changes to iOS discovery or pairing may require a
protocol update; the existing import path remains available for recovery.
