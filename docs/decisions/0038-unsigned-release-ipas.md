# 0038: Release IPAs are signed ad hoc, for the recipient to re-sign

**Status:** accepted, 2026-09-30, by the copyright holder; its always-`--clean`
build is changed by [0050](0050-release-reuses-the-build.md). It picks what a
published IPA is and how it is made. It does not approve publishing: the gates
in [the open-source release plan](../plans/finished.md#open-source-publication-and-the-first-ipa) still apply.

## Decision

- A release's IPA is the `release` variant built with `pp build --unsigned`:
  `xtool dev build --ipa` without `--sign`. xtool then signs the bundle **ad hoc**
  with the app's entitlements (`increased-memory-limit`) and no certificate,
  profile, team or device. The recipient signs it again with their own Apple ID
  (a re-signing tool, or their own developer account), which carries the
  entitlement over.
- `pp release VERSION` makes a release on this workstation: a `--clean`
  unsigned release build of a clean, pushed HEAD, then `pp names`, `pp secrets`
  and `pp verify --variant release --unsigned`, then a **draft pre-release** on
  GitHub with the IPA, `provenance.txt`, `artifacts.tsv`, `SHA256SUMS` and draft
  notes. It never publishes; a person publishes the draft once the gates pass.
- The version is `CFBundleShortVersionString` in `app/Info.plist` and
  `app/PlayportJIT-Info.plist`; `pp release` refuses a version they do not name.
  The first is 0.1.0.

## Why

- **A Personal Team IPA is one phone's.** Its profile lists the maintainer's
  device and carries the team ID and device list, which the repository's rules
  keep private. It installs on no one else's phone.
- **Ad hoc keeps the entitlement.** A bundle with no signature at all would lose
  `increased-memory-limit`, which FEX's arena needs; re-signing tools take the
  entitlements from the existing signature.
- **The workstation builds** (decision 0002): no Apple SDK or credentials go to
  GitHub's runners, and CI still builds and uploads nothing (decision 0037).

## Consequences

- `pp verify --unsigned` replaces the signature and profile checks for such an
  IPA: every code directory matches (ad hoc), the entitlements are exactly
  `increased-memory-limit`, there is no CMS signer, no `embedded.mobileprovision`
  and no team prefix in the bundle ID, and CodeResources seals every file.
- Unsigned outputs are named `Playport-<sdk>-release-unsigned-<sha8>.ipa`;
  `pp install` never picks one, and the next signed build does not compare its
  profile with one.
- Installing through a re-signing tool, including the JIT helper extension's
  own App ID and JIT, is untested until a release is installed that way.
