# Free IPAs on GitHub Releases, donations on Ko-fi or Patreon

**Status: chosen hosting and workflow ([decision 0037](decisions/0037-ipas-on-github-releases.md)),
not permission to publish.** Playport is open source. Its IPAs are free to
download from this repository's GitHub Releases, and support is voluntary,
through Ko-fi or Patreon. `LICENSE` stays GPL-3.0-or-later with the existing
exception. The source and the IPA are published through separate gates;
[plans/open-source-release.md](plans/open-source-release.md) tracks the work
still open.

## What a release holds

Each GitHub Release is tagged at the commit its IPA was built from. It has
these assets:

| Asset | From |
| --- | --- |
| `Playport-<version>.ipa` | a verified `pp build --variant release --unsigned` output: signed ad hoc, no profile, for the recipient to re-sign ([decision 0038](decisions/0038-unsigned-release-ipas.md)) |
| `SHA256SUMS` | every attached asset, including notes and the release manifest |
| `provenance.txt`, `artifacts.tsv` | the build output |
| `Playport-<version>-source.tar` | `pp source --build` on the same output: Playport at the tag, every pinned upstream tree with its submodules and patch series, the dependency tarballs and crates, with its own manifest and `SHA256SUMS` ([DISTRIBUTION.md](DISTRIBUTION.md), section 2) |
| `NOTICES.tar` | the IPA's exact `Licenses/` files, checked with `pp verify --distribution` before any draft upload ([NOTICES.md](NOTICES.md)) |
| `INSTALL-REBUILD.tar` | the build commit's distribution, build, device, licensing and notice instructions |
| `RELEASE-MANIFEST.json`, `RELEASE-NOTES.md` | exact asset/source identities, visible source gaps and unapproved draft status |

- **Size limits.** GitHub's documented limits are 2 GiB per asset and 1000
  assets per release, with no cap on a release's total size or on download
  bandwidth. The recent release IPA is about 435 MB. A source tar without Wine
  and Mesa came to 370 MB (2026-09-30); the later exact inventory pack is
  about 619 MiB. Split one larger than 2 GiB,
  and list every part in `SHA256SUMS`.
- **GitHub's own "Source code" archives are not enough.** They hold only this
  repository: not `upstream/madeira`, the pinned Wine, FEX, DXMT and other
  trees, or the dependency sources. Attach the complete source yourself.
- **Keep old releases.** Leave the source of every published IPA attached for
  as long as the IPA is. If a release has to be withdrawn, keep its source
  available and say where it is.
- **Build and draft on the workstation.** CI builds, signs and uploads nothing,
  and no workflow may attach an IPA. `pp release VERSION` builds the unsigned
  release IPA `--clean` from a clean, pushed HEAD, runs `pp names`, `pp secrets`
  and `pp verify --variant release --unsigned` (which fails an IPA holding a
  profile, a team prefix or a signer), assembles the assets in
  `$PLAYPORT_BUILD/releases/vVERSION/`. Before uploading a **draft pre-release**,
  it additionally checks the IPA with `--distribution` against its own extracted
  notices and attaches those notices and committed instructions. The repository
  and target commit are explicit. `--no-github` permits private incomplete local
  preparation, without an upload command; neither mode grants publication
  approval. Source gaps stay in the notes/manifest. A person completes the gates
  and approves publication; the tool never publishes.
- Mark early builds as **pre-releases**. They are still free.

## Donations: Ko-fi or Patreon

- The IPA is free for everyone. Put no download behind a Ko-fi purchase, a
  Patreon tier, a paywalled post or a licence key.
- A donation buys no software licence, no exclusive right and no different
  build. If patrons ever get a build earlier, they get it under the GPL, with
  its source, and may share it. Do not attach an NDA or a no-sharing rule.
- Stopping a Patreon membership does not take away the right to run, change or
  share a copy already received.
- Link the page from `README.md` and from each release's notes. GitHub shows a
  **Sponsor** button when `.github/FUNDING.yml` names the account
  (`ko_fi: NAME`, `patreon: NAME`). Add that file only once the page exists.
- Before starting, review Ko-fi's or Patreon's terms, fees, taxes and
  consumer duties. Describe the support as a donation only when it is one.

## GitHub's role and redistribution

GitHub hosts the source, the patch series, the issues and the official releases.
That is **where we publish**, not a restriction on recipients. Anyone who gets
the IPA may mirror it or its source elsewhere under its licences. We cannot
require them to donate, to download only from GitHub, or to keep a copy private.

Check GitHub's [Terms of Service](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service)
and [Acceptable Use Policies](https://docs.github.com/en/site-policy/acceptable-use-policies/github-acceptable-use-policies)
for this package before the first release. Hosting on GitHub does not settle
Apple's terms; the owner accepts that risk
([decision 0039](decisions/0039-owners-licensing-review.md)).

## Draft release notes

Use only once the release gates pass and the real links and checksums are in
place:

> Playport is free and open-source software under GPL-3.0-or-later, with the
> additional permission in `LICENSE-EXCEPTION.md`. Bundled components keep
> their own licences. The IPA is free.
>
> This release includes the IPA, its exact matching source, the third-party
> notices, the checksums and the install instructions. You may change and
> redistribute the software under its licences. There is no warranty, except
> where the law requires one. Bring your own games: Playport grants no right to
> redistribute any game. Read the device and signing requirements before you
> install.

Once a Ko-fi or Patreon page exists, add after "The IPA is free.": "If you want
to support development, you can donate on Ko-fi or Patreon. A donation buys no
extra licence and does not restrict anyone's right to share the software."
0.1.0 names no donation link (decision 0039).

Do not promise App Store approval, permanent signing, support for every game, or
an Apple-approved JIT or distribution route.

## Before the first release

- [x] Resolve the Apple SDK, signing and channel questions: the owner accepts the
  risk, and nothing Apple owns is attached (decision 0039).
- [ ] Complete and test the release package in [DISTRIBUTION.md](DISTRIBUTION.md):
  the exact source, complete notices, and usable install and relinking
  instructions (relinking by rebuilding from the source, decision 0041).
- [ ] Check that every asset fits GitHub's limits and that the source archives
  rebuild the tagged IPA.
- [ ] Later, not for 0.1.0 (decision 0039): set up the Ko-fi or Patreon page,
  review its terms, then add `.github/FUNDING.yml` and the README link.
- [ ] Get the owner's explicit approval before creating the tag, the release or
  any upload. Record the released checksum and the matching source manifest.

## Primary sources to re-check at publication

- GitHub [About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
  (asset size and count limits) and
  [Displaying a sponsor button](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/displaying-a-sponsor-button-in-your-repository)
  (`FUNDING.yml`).
- The [Ko-fi](https://ko-fi.com/terms) or [Patreon](https://www.patreon.com/policy/legal)
  terms for the chosen page.
- [GPLv3](https://www.gnu.org/licenses/gpl-3.0.html), sections 6(d), 10 and 12:
  access to the source, direct licences to recipients, and conditions we may
  not add.
