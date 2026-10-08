# 0068: The owner signs off the release app, without automated tests

**Status:** accepted, 2026-10-08, by the owner ("owner signs off without automated
tests"). Changes [0038](0038-unsigned-release-ipas.md) where a person publishes "once
the gates pass": for the release app on the phone, the gate is the owner's sign-off.
Replaces the replay of a plan's phone gates on the release IPA (for 0.4.0, the
store-sign-in gates that PLA-74 listed). Keeps [0009](0009-dev-and-release-builds.md),
[0012](0012-the-ui-is-the-only-entry-point.md) and [0050](0050-release-reuses-the-build.md).

## Decision

- **The release app's check on the phone is the owner's.** The owner installs the
  release IPA as a player does (re-signed with a sideloader, or over the dev app's
  container), plays what they choose, and signs off. No `pp ui`, `pp perf` or
  scripted gate list runs against the release app, and none is required before a
  draft is published.
- **The sign-off is a comment on the release's Linear issue** with the date, the
  IPA's sha256 and, in a line, what the owner tried. No evidence record is needed.
- **The machine checks of what is shipped stay.** `pp release` still requires a
  clean, pushed HEAD with its exact build provenance, `pp names`, `pp secrets`,
  `pp verify --variant release --unsigned` (and `--distribution` for a GitHub
  draft), the source bundle and the checksums. They check the IPA and the source,
  not the app on a phone.
- **A change is still proved on the dev app.** The rules in `AGENTS.md` for a
  change (a `pp ui` play, a run that shows a page) are unchanged: the runtime and
  the UI are the same code in both variants, and the dev app is what the driver
  can drive.

## Why

- **The release app cannot be driven** (0009): it has no driver, so an automated
  gate on it means rebuilding the gate on the dev app of the same commit, which the
  change's own checks already did.
- **What differs in a release needs a person anyway**: the re-signing sideloader,
  the quiet runtime and its `playport.log`, and the consent cards a person taps
  (Allow on a game's web panel, decision 0064).
- **The replayed gates held a release back.** 0.4.0's notes and build were ready
  while a five-title phone replay, with the owner at the phone for parts of it,
  was still to come.

## What it costs

- A regression only the release variant has (code under `#if PLAYPORT_RELEASE`, the
  quiet runtime) ships unless the owner meets it while signing off.
- A store or title the owner does not try in the release app is checked only by
  the dev app's runs.
- The owner can still ask for any dev-app gate before signing off; it is then
  part of that release's issue, not a standing requirement.
