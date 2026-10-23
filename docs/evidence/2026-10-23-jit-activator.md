# Standalone Jit activator, 2026-10-23

A standalone app now contains its own local packet tunnel, pairing importer and
developer-app picker. Its display name is **Jit activator** and its app icon is a
white lightning bolt on blue. It upgrades the existing activator installation;
the bundle identifier is retained so pairing and configuration survive updates.

## Observed delivery

- The official Playport 0.4.0 IPA was verified before local development signing:
  `dbeed0312025637a52c4c9493d6ec5d37008016cc5c9edeba5165ca8883df9c3`.
  Playport was installed in place with its JIT extension and Increased Memory
  Limit entitlement retained. Its real first-run UI opened on an iPhone 16
  running iOS 26.6.1.
- Pairing import, the activator's embedded VPN and developer-app discovery worked
  on that phone. No separate VPN application was required for that path.
- Real device attempts exposed two helper-startup omissions: the canonical
  `PlayportJITEntry/entry.c` decoder bootstrap and the first XPC message needed
  to establish the anonymous connection. Both are included in the candidate.
  Subsequent attempts reached target launch, but JIT completion was not observed
  before the activation deadline.
- Playport's JIT method was changed through its UI to **Another app**, and its
  first-run setup was completed without signing into a store. Opening Home alone
  does not request Playport's JIT memory; its game-launch path does.

The scope then moved to the requested name and icon. End-to-end JIT activation,
a Windows game first frame, timeout recovery, Cancel and retry remain unverified.
This record does not claim that the activator is functionally complete.

## Validation and review

The standalone app builds with native Xcode tooling. Strict deep signature
verification passed for the candidate installed during device diagnosis. The
worker executable defines `_NSExtensionMain`. Independent source review returned
NON-BLOCKING after the helper lifecycle, launch deadline, cancellation and
startup fixes, and again for the icon/name packaging. The opaque 1024 px icon
was inspected at full size and at 60 px.

The name and secret gates passed. The broader host quick suite was stopped after
its existing read-memory ASan fixture stalled; it is not reported as passing.
The existing Playport built-in JIT caller was not migrated to the new lifecycle.

Screenshots, device logs, pairing and signing material remain local under
`.work`; they are not included with this record. Temporary Mac developer-tool
permissions used during diagnosis were restored to their original disabled
state. Linear tracking was unavailable in this environment.
