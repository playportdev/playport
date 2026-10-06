# StikJIT 1.6.0 and notice-less Rust crates: provenance audit

## Result and limits

**Audit observations completed; embedded idevice provenance and notice coverage
remain unresolved.** Neither publication gate in
[the release plan](../plans/finished.md#open-source-publication-and-the-first-ipa) is satisfied by this audit.
No binary revision has been inferred from a current upstream branch, matching
crate versions, timestamps, generated headers or a Rust compiler string.

Read-only inputs were the clean cached StikJIT 1.6.0 source/ZIP, the clean pinned
idevice notice-donor source, and the coordinator's pristine locked registry
archives. Inspection used committed stages, Git tree/byte validation, ZIP/Mach-O
metadata, archive member names, LLVM symbol/header inspection and focused archive
source review. Only this worker's `.work/stikjit-audit` contains outputs. No
network, Cargo resolution, compilation, app/runtime build, install, device call,
account/secret inspection, upstream edit, pin change or binary replacement occurred.
Existing caches/run inputs are **not** a release of this branch.

## Exact byte evidence

The stage is [build/stages/stikjit.sh](../../build/stages/stikjit.sh), SHA-256
`44d471bd3487e8dc70b71a9e0fa3dc20dd7f856ff50279455fbf7b5132bbf4d8`.
Its separately checked ZIP and source commit associate a release asset with a
source tag; they do not prove build derivation.

| Input | Observed identity |
| --- | --- |
| StikJIT source commit | `e6bbfe0399de0b839869356dc02b2ad8214ac5bd` |
| StikJIT committed tree | `26faf6b5eac0d863bd788b76b0045fdce5eae19e` |
| `StikJIT.xcframework.zip` SHA-256 | `14990ce6a2cd6c54176ef5b76f664731d08a7e43e959a5176a3e65c9b716f215` |
| ZIP member `StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT` | 3,077,912 bytes; SHA-256 `d2416958d7c38b6587ecd754c25df50f15dbfe109ffce028d9a8c6b2ea73cbd3` |
| Committed `idevice/libidevice_ffi.a` | 57,017,464 bytes; SHA-256 `4db23fe1d342927b9480bb9a8577f219994365621dc28aa0018e23ea1990ecc8` |
| Committed `idevice/idevice.h` SHA-256 | `696286794e8cf1c18a91d4dab5046cef4d9bae352f5e7a1ad33fbc0ba30d7ab4` |
| Notice-donor idevice commit | `d32c8189c51c2789496b0768039419c3705498c3` |
| Notice-donor committed tree | `9f6aeb1fffe6dd5236067f3d6e349de9eb1b327a` |
| Donor `LICENSE.txt` SHA-256 | `131488ce7e302b9f62e3236793e57c86a208d3dfaf03e6d7d03ddc0fc82392ed` |
| Donor `Cargo.lock` SHA-256 | `3c1a7710f0cd02f9100e91b97c9f8abc6546f115f7f3255551c990628aea0e16` |

Both cached Git inputs passed exact-tree/clean tracked-byte validation. Their
tracked status remained clean after inspection. The audit does not establish
clean build trees for other components, a staged framework or an exact IPA.

### What the tag actually supplies

At the StikJIT commit, `idevice/` contains a binary static archive, generated
header and module map, **not idevice source, its Cargo.lock or a Rust build
recipe**. `.github/workflows/build.yml` builds Swift with XcodeGen/xcodebuild on
`macos-15`; it does not rebuild that archive or record how it was produced.
`project.yml` requests hidden linking of `idevice_ffi`, dead stripping and private
symbol stripping. The README credits bundled idevice but supplies no revision.
These committed files were checked byte for byte; their hashes are in the local
observation JSON. No dSYM, link map, Rust lock or dependency manifest is supplied
in the checked ZIP.

The framework is a thin arm64 Mach-O dylib with UUID
`73a7c215-9242-3644-8048-a6a662395e59`. `LC_BUILD_VERSION` records iOS platform 2,
minimum 17.4.0, SDK 18.5.0 and linker tool version 1167.5.0. These describe binary
metadata, not idevice revision or a verified compiler/SDK installation.

The committed archive has **900 members**. The audit's BSD/SysV archive parser
agrees exactly with `llvm-ar t`. Candidates include `idevice`, `idevice_ffi`,
`idevice_srp`, `ns_keyed_archive`, `nskeyedarchiver_converter`, `plist_macro`,
`plist_ffi`, `aws_lc_rs`, `aws_lc_sys`, C/assembly crypto objects, and Rust
standard-library/compiler-builtins objects. Archive presence is not evidence
that a member survives final framework linking/dead stripping.

Embedded path-string search found **117 crate-version clues in the archive and
63 in the final framework**, including `aws-lc-rs-1.16.2`, `plist-macro-0.1.6`,
`rustls-0.23.37` and `tokio-1.50.0`. Archive symbols include the
`aws_lc_0_39_0_` prefix. `ns-keyed-archive-0.1.5` and `plist_ffi-0.1.6` are archive
path clues, not final-framework path clues. Absence of a string/symbol in the
stripped framework proves no absence of compiled code. None of these observations
is a resolved dependency set, a source checksum or exact linked-member proof.

Both binary inputs contain the Rust path-commit clue
`48a229ceaefd4985c50990b14116b6d856af0985`. It matches the source commit declared
in this branch's `build/rust-dist.lock.json`, but does **not** prove which host
compiler, target stdlib archive, flags or patched sources built StikJIT's archive.
No idevice revision was found in the inspected metadata/strings. This is a
bounded inspection result, not a proof that no encoded revision could exist.

### Why the notice donor is not the embedded source pin

Playport builds a **separate executable relaunch library** from the idevice pin
using `build/stages/idevice.sh`. Its shared helper selects `aarch64-apple-ios`
and `ring,tcp,core_device,core_device_proxy,tunnel_tcp_stack,rsd` without default
features. `crates.tsv` is a normal dependency graph, not build/link evidence.
The stage's introductory description of it as every linked crate is too strong.

The StikJIT static archive instead contains AWS-LC candidates. The donor lock
also contains AWS-LC 1.16.2/0.39.0 and matching versions for many string clues:
matching versions are compatible with multiple revisions/builds, not identity.
A freshly regenerated Playport ring-feature inventory cannot serve as StikJIT's
dependency inventory. The final framework's hidden/stripped private symbols also
prevent treating exported-symbol output as a complete Rust component list.

The donor notice is verified **only as bytes of its own pinned source**. Missing
proof includes the embedded idevice commit/changes, original Cargo lock and
vendor/archive checksums, active normal/build/proc-macro features and target,
Rust host compiler and stdlib derivation, generated header/build-script inputs,
native crypto build inputs, static-member-to-source mapping, and the final
framework's link map or equivalent reproducible-build evidence.

## Three locked crates: real attribution, not generic MIT substitution

The following **crates.io archive checksums come from the committed donor lock**.
Each local `.crate` was rehashed and every member validated in memory; shared
extracted build-cache sources were not used. Each has no recursive notice-file
candidate and no direct `package.license-file` declaration under the current
collector's rule. That does **not** mean it has no attributions or mixed terms.

| Archive | SHA-256 | Declared package licence; archive file count |
| --- | --- | --- |
| `ns-keyed-archive-0.1.5.crate` | `815e8c8171d033165fdda6d95630d6f447592ad5e6fbade9db26663970c6fae6` | `MIT OR Apache-2.0`; 9 |
| `plist-macro-0.1.6.crate` | `82c39e020f2d8d361e91a434cfe26bc7c3e21ae54414379816d0110f3f7ca121` | `MIT`; 11 |
| `plist_ffi-0.1.6.crate` | `35ed070b06d9f2fdd7e816ef784fb07b09672f2acf37527f810dbedf450b7769` | `MIT`; 148 |

Their normalized and original manifests name **Jackson Coxson**. Their
`.cargo_vcs_info.json` declarations respectively name
`f8cec65e865cb48301d33b2244bec45a2f3d2bc2`,
`d1d48559ddc8e9bd263f36180bbe1d4f2a3d55e5`, and
`265379167ab3f9a5664621a7f1c0f494b2ac7c96`, with empty `path_in_vcs`.
These are publisher-declared VCS clues inside checksum-verified archives, **not
independently verified Git-source origins**. No Git checkout at those revisions
was obtained. No copyright year or complete grant has been invented.

### ns-keyed-archive

`src/lib.rs:1` and `src/encode.rs:1` credit Jackson Coxson. `README.md:4` credits
NSKeyedArchiver Converter (michaelwright235/nskeyedarchiver_converter), also a
locked dependency at 0.1.3. Preserve that credit and review copied-code scope
against exact source; the dependency's own collected notices do not automatically
establish attribution for derivative code in this crate.

Exact archive-relative evidence: `ns-keyed-archive-0.1.5/README.md`, SHA-256
`04f31d158655160ca201652d683df4abdfbbdc54263e6ea02aafb5574fef7b63`;
`ns-keyed-archive-0.1.5/src/lib.rs`, SHA-256
`2c9f273371bd50b313d0c18ff41942eb7f7aff53f42be57dc6163f5f665b06ce`.
Author/README evidence and the licence expression do not supply a complete MIT
copyright/permission notice. Obtain exact-source/holder notice clarification.

### plist-macro

`src/index.rs:1` and `src/m.rs:1` credit Jackson Coxson. **`src/m.rs:2` explicitly
says it is ported from serde's json macro.** The manifest has only `plist` as a
direct dependency and does not identify the version/revision of copied macro
code. Do not attribute the port automatically to whichever serde_json version
happens to be in idevice's dependency graph. Compare exact-source history and
retain the applicable original notices/credits as well as the port author's.

Exact member `plist-macro-0.1.6/src/m.rs`, SHA-256
`5bf38859260263462d884435bf80514be97234947db148d9544a978d8722bfc1`.
The README's MIT label is not a missing copyright/permission notice replacement.

### plist_ffi: mixed licence files hidden by package metadata

**This is not an all-MIT source archive.** `README.md:8,14,19` identifies copied
libplist headers, tests and C++ code. Its licence section (lines 36–40) retains
those originals' licences and offers the author's Rust files under MIT or
libplist's licence. That distinction contradicts flattening all contents to the
normalized package-level MIT expression.

Examples with exact locked-source attribution:

- `plist_ffi-0.1.6/cpp/include/plist/plist.h:1–22`, SHA-256
  `118a5ef7f331b2af5bc0d44032c1c761acc1c84fbc0fa5d7965e52b6169e69b1`:
  Nikias Bassen (2012–2023), Jonathan Beck (2008–2009), LGPL-2.1-or-later
  permission/warranty header.
- `plist_ffi-0.1.6/cpp/src/Array.cpp:1–19`, SHA-256
  `8de87e18a8b4a5edd44a7b7a9072b825e8b06030ce8a43311c763212c23d3e48`:
  Jonathan Beck (2009), LGPL-2.1-or-later header.
- `plist_ffi-0.1.6/README.md`, SHA-256
  `1b60445e401df6b5eba42cf43e39c8105b05d98f2c6bff5a1984a6da57d0a1af`.
- `plist_ffi-0.1.6/build.rs`, SHA-256
  `3f113baab2c64102e29141a0e66743151aeaaee6404d64971bb5f664853b0819`:
  generates root `plist.h` via cbindgen and compiles `src/shims.c` when
  `danger` is enabled. It does **not** request compilation of `cpp/src/`.
- `plist_ffi-0.1.6/src/shims.c`, SHA-256
  `0de927e4cf676b7f2129e0139a8d20f5a40d6a4496c22b2995cf2a4130eb4766`:
  credits Jackson Coxson and includes the generated root header.

Other copied C++/test/tool headers carry additional original credits. Examples
include Nikias Bassen, Sebastien Gonzalve, Martin Szulecki and Zach C.; an example
Info.plist has an Apple copyright value. These are source-superset observations,
not assertions that examples/tools or C++ code are shipped in the executable.
The tool records exact per-file hashes and matching line observations, not a
complete notice-selection policy or applicability audit.

Additionally, **StikJIT's committed generated `idevice/idevice.h:9792–9813`
already contains libplist's LGPL header and the Bassen/Beck copyright lines**
(the full header hash is above). Lines 9788–9790 explicitly state that the
appended file retains its original licence and is not under idevice's licence.
This is exact StikJIT-tag source evidence,
independent of the donor archive. Preserve those bytes if distributing that
header; neither this inclusion nor the archive clues establish which LGPL
code/header definitions reach the final binary. Source publication must retain
original mixed-licence material even if a particular binary does not compile it.

## Corrections for coordinator-owned files

No shared collector/docs were edited. Required reconciliations:

1. `build/notices-assemble.sh:181–183` and `docs/NOTICES.md`'s
   `idevice-LICENSE.txt` row must label the copy as **verified donor/pinned
   Playport idevice notice bytes only; embedded StikJIT revision unverified**.
   Do not mark that committed-byte origin as verified StikJIT coverage. Retain an
   explicit separate unresolved StikJIT embedded-dependency gap.
2. `docs/LICENSING.md`, StikJIT subsection: remove the statement that idevice
   is the *only* remaining third-party code; the archive contains Rust stdlib,
   crypto and dependency candidates, with an incomplete final-link inventory.
   Qualify the claimed tag-to-binary source derivation separately from ZIP
   integrity. Keep the borrowed-revision explanation, but make it an unresolved
   provenance limitation, not fulfilment of the embedded library's notice duty.
3. `docs/LICENSING.md`, executable idevice subsection: replace “all permissive”,
   “Every notice is collected” and generic texts “stand for” notice-less crates.
   Record the mixed libplist source terms, serde macro-port origin gap and
   missing complete attribution notices. Likewise qualify linked-crate claims
   in `docs/BUILDING.md` and `build/stages/idevice.sh` as normal graph evidence.
4. Keep the existing notice-less summary; author/manifest observations do not
   close it. A future collector should preserve exact locked README/header
   bytes or audited inclusive header excerpts with source/member/checksum
   origins, explicitly labelled as a superset where appropriate. Generic MIT
   text plus a guessed year is not a safe repair. No such payload collection
   or assembler change was included in the original audit; the host-only
   continuation below subsequently adds focused evidence preservation.

## Safe next actions

- Obtain the **original embedded archive build record** from its producer:
  exact idevice commit/patches, Cargo.lock/vendor bytes, features/target,
  compiler/stdlib/native-tool identities, generated inputs, and static and
  final-framework link maps. Verify against the existing ZIP/archive hashes.
- If that record is unavailable, prepare a reviewed **verified rebuild** of
  the required StikJIT revision with an explicitly pinned idevice source and
  dependency set. Record source-to-object/member and member-to-framework
  linkage, input checksums, toolchain evidence and output hashes. Do not label
  rebuilding the donor pin as recovering the old binary's revision. A replacement
  needs separate pin/pipeline review and later runtime/device checks; none ran here.
- For the three crates, use their locked archive bytes and declared VCS clues
  to obtain exact-source/holder clarification and missing notice texts; verify
  any source/notice relationship before collection. Resolve the serde macro
  origin and original libplist notices. Preserve mixed headers verbatim and
  assess actual compiled/linked applicability separately from source publication.
- Regenerate appropriate normal **and build/proc-macro** graphs from the
  selected exact source; independently audit native/code-generation inputs and
  stdlib binary derivation. A normal graph is not final link-member evidence.
- Keep Section 2's StikJIT/notice-less-crate item and broader release gates open.

## Reproduction

The one-off inspection script used here was removed once its observations were
recorded above.

## Host-only continuation: preserve locked attribution evidence

`build/rust-attribution.lock.json` now catalogs full-file evidence from the
three exact crates.io archives listed above. Selection is deliberately inclusive:
all regular files in ns-keyed-archive/plist-macro, and all regular plist_ffi files
outside `test/data/` (65 fixture data files excluded, including binary plists).
The catalog pins archive checksums and every selected member's SHA-256/size:
**9 + 11 + 83 = 103 files, 299,542 bytes**. No source or licence bytes are edited.

This preserves author/README credits, the whole serde-port macro, original and
normalized manifests, publisher VCS clues, libplist's original C/C++ header
permission/warranty blocks, source, test/script/tool and example credits. It is
an **attribution evidence superset**, not a completed copyright audit or app
licence selection. Publisher VCS declarations remain unverified source clues.
The excluded fixture subtree is not covered by this notice catalog; exact-source
packaging and publication review still need the complete archives.

`build/notices-rust.py` incorporates these bytes into ordinary registry collection
and emits schema 3 with the catalog hash, incomplete scope and per-candidate/
origin `attribution_superset` markers. Collection reopens checksum-locked archives
and compares catalog hashes/sizes before copying. The native filename/declaration
selector remains separate, so the original observations-only audit retains its
meaning. Inventory publication independently enforces the catalog's complete
selected set and bytes even if source/candidate/origin entries are jointly removed;
old schema, changed scope, catalog identity or superset markers fail closed.

The **notice-less summary still lists all three crates**. Whole-source copies do
not invent absent MIT grants/years, resolve serde's original revision or prove
complete original attribution/adequate rights. No added collection covers the
unverified StikJIT embedded build. Review the catalog on any dependency update;
matching names or another crate version cannot substitute for its exact checksums.

Checks in this coordinator worktree:

- Eight new regressions cover full-byte/origin preservation, explicit missing
  notices, changed archive/source/size or missing members, discovery/declaration
  deduplication, joint-manifest omissions, schema/scope/marker/catalog tampering,
  missing/extra/changed/symlinked outputs, write rollback and CLI failure cleanup.
  Targeted registry tests passed: **42 tests**.
- Unmodified full `./pp test` passed: **369 Python tests**, four available host C
  tests and all Swift suites (27, 136 and 49; one SteamStub sample skipped).
  The two gamepad C/ThreadSanitizer tests still skip the unpopulated Madeira
  submodule. Private log: `.work/rust-attribution-review/full-tests.log`.
- Real offline smoke regenerated the same **147 registry crates / 149 inventory
  entries**, collected **380 notice/evidence files** (277 native notices + 103
  catalog files), passed the actual inventory hook and all output checksums.
  Collected payload/manifest secret/home-path pattern scan found no hits.
  Private inputs/output/logs remain under `.work/rust-attribution-review`;
  shared source/toolchain/cache inputs were read only, not rebuilt/reset/changed.
- No app/runtime build, phone use, source publication, account creation or upload.
  This tests the registry collection slice, not a complete branch `pp notices`
  run, an exact IPA or a source/relinking package. Complete attribution, producer
  provenance, applicability/rights and all publication/distribution gates stay open.

## StikJIT's source commits its idevice library prebuilt

StikJIT's tag `1.6.0` (commit `e6bbfe0399de0b839869356dc02b2ad8214ac5bd`, the pinned
release) tracks `idevice/libidevice_ffi.a` (57,017,464 bytes, blob
`3fb7e2dbfdb9db3d47bd6364a435bbc10d5581f9`) with `idevice/idevice.h` and a module map,
and records no idevice revision beside them. Its source therefore does not build its
idevice copy either: the embedded revision stays unknown, and the release's source
cannot show it. `pp source` drops that library from the StikJIT archive with this
reason (`build/source-bundle.json`) and keeps the gap in the catalog's `missing` list.
A verified rebuild of StikJIT from a pinned idevice remains the way to close it.

## Host-only continuation: upstream repositories of the three crates (2026-09-30)

The crates.io records name `jkcoxson/ns_keyed_archive`, `jkcoxson/plist_macro` and
`jkcoxson/plist_ffi`. Cloned read-only under `.work/licence-research`:

- **Same bytes.** Every file of the three locked archives that the repositories
  hold (all but Cargo's generated `Cargo.toml` and `.cargo_vcs_info.json`) equals
  the repository's current file byte for byte (6, 8 and 80 files).
- **No licence file, ever.** No commit in any of the three repositories has held a
  `LICENSE*` or `COPYING*` file. The only terms are the manifests' `license`
  (`MIT OR Apache-2.0` for ns-keyed-archive, `MIT` for the other two), the
  `authors` field (Jackson Coxson), per-file `// Jackson Coxson` lines and the
  READMEs. So there is no upstream copyright-and-permission notice to collect;
  only the holder can supply one.
- **plist_ffi links no libplist code.** Its `build.rs` runs cbindgen to generate
  `plist.h` from the Rust sources and, with the default `danger` feature, compiles
  only `src/shims.c` (`// Jackson Coxson`). The LGPL-2.1-or-later libplist C++
  sources, headers and tests under `cpp/` and `test/` are in the archive but
  are never compiled. What reaches the executable from this crate is the author's
  Rust code and shim, which the README offers under MIT or libplist's licence.
  This narrows the earlier "mixed LGPL" concern to the source package, where the
  LGPL files keep their headers.
- **plist-macro's port.** `src/m.rs:2` says it is ported from serde's `json!`
  macro (serde_json, MIT OR Apache-2.0). serde_json's `LICENSE-MIT` names no
  copyright holder, so carrying serde_json's licence texts with a credit line is
  the whole attribution it asks for; the exact serde_json revision stays unknown.

**What would close it:** a licence file from the holder in each repository (and a
release of the crates with it). A request the owner can post as an issue in each
repository:

> The crate declares `license = "MIT"` (ns_keyed_archive: `MIT OR Apache-2.0`) but the
> repository and the published crate have no licence file. MIT asks that its
> copyright and permission notice go with every copy, so a project that ships your
> crate in a binary has no notice text to include. Could you add a `LICENSE` (for
> ns_keyed_archive, `LICENSE-MIT` and `LICENSE-APACHE`) with the copyright line you
> want, and publish a release with it? plist_macro: could the notice also credit
> serde_json's `json!` macro, which `src/m.rs` says it is ported from?

Until then the app's selection carries none of their files, and the review
question in `build/app-notices.json` stays open.
