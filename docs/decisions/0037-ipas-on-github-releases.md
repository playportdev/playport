# 0037: Free IPAs on GitHub Releases, donations on Ko-fi or Patreon

**Status:** accepted, 2026-09-30, by the copyright holder. This decision picks
where releases go. It does not approve publishing: the gates in
[the open-source release plan](../plans/finished.md#open-source-publication-and-the-first-ipa) still apply.

## Decision

- Official IPAs are published as assets on this repository's **GitHub
  Releases**. Each release has the IPA, its exact matching source, the
  notices, the checksums and the install instructions.
- Every IPA is **free to download**. There is no paid tier, minimum price,
  licence key or supporter-only build.
- Donations go through a **Ko-fi or Patreon** page, linked from the README
  and the release notes. A donation buys no software, no rights and no
  earlier or different build.
- This replaces the earlier plan in [RELEASE-HOSTING.md](../RELEASE-HOSTING.md),
  which kept IPAs off GitHub and proposed itch.io's $0-or-Donate flow.

## Why

- **One place.** The source, the patch series, the issues and the releases are
  all on GitHub. A release can hold the IPA beside the exact source it was
  built from, so recipients get the source at no extra charge.
- **Size fits.** A release asset can be up to 2 GiB, and GitHub sets no limit
  on the total size of a release or on download bandwidth. The release IPA is
  about 435 MB. Gumroad's free-product cap (250 MB in total) does not fit.
- **No store terms in between.** A download platform's publisher licence
  (itch.io section 4, Gumroad sections 6.5 to 6.7) had to be checked against
  the GPL. With a GitHub release, only GitHub's terms apply, and a donation
  page sells nothing, so it is kept apart from the software.

## Consequences

- `README.md`, [LICENSING.md](../LICENSING.md), [DISTRIBUTION.md](../DISTRIBUTION.md)
  and the release plan no longer say "keep official IPAs off GitHub".
- CI still builds and uploads nothing (decision 0002: the workstation builds
  and signs). A person uploads each release by hand from a verified
  `pp build --variant release` output, after `pp secrets` and `pp verify`.
- GitHub's automatic "Source code" archives hold only this repository, with no
  submodule and no pinned upstream tree. They are not the Corresponding
  Source. Each release attaches its own source archives, and they stay attached
  for as long as that release's IPA is available.
- The Apple SDK, signing, JIT and channel questions stay open. Hosting the IPA
  on GitHub does not answer them.
