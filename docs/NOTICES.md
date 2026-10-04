# Notices

The component licences in [LICENSING.md](LICENSING.md) have differing notice
and attribution duties. This page inventories the collected files, where they
come from, and the known gaps. It is not a complete linked-code audit or legal
approval. [plans/open-source-release.md](plans/open-source-release.md) tracks
completion before an IPA is distributed.

## Wine fallback fonts

`Runtime/fonts/{tahoma,tahomabd}.ttf` are unchanged, tracked Wine-pin prebuilts
from `fonts/` (artifact provenance `fonts`), not host FontForge outputs.
`wine-NOTICES.md` includes the Bitstream Vera font licence; the notices stage
also preserves SFD header lines 1–6 for each face as
`wine-fonts-*-attribution.txt`, with committed-source derived origins.
The Wine component's `wine-*` app selection includes these attributions.
The faces came after the owner's 2026-09-30 review, so `build/app-notices.json`
is `unreviewed` with them as its open question: no IPA with them goes to anyone
until they are reviewed ([DISTRIBUTION.md](DISTRIBUTION.md)).

## Collecting the files

```sh
# A pp build does all of this in its notices stage (BUILDING.md), into run/notices.
# By hand: first the collection inputs, from their committed locks, into the cache
# (build/mingw-notices.lock.json's two checkouts, build/llvm-runtime-notices.lock.json's
# sparse LLVM checkout, build/rust-dist.lock.json's three archives and
# build/gstreamer-notices.sources.json's Cerbero and 17 recipe archives):
python3 build/notices-inputs.py .work/cache           # --plan: what is missing; fetches nothing
# Collection never clones or fetches. MINGW_SOURCE, LLVM_MINGW_SOURCE, LLVM_RUNTIME_SOURCE,
# RUST_NOTICE_DIST, GST_NOTICE_CERBERO and GST_NOTICE_SOURCES name other prepared inputs
# (notices-inputs.py then leaves them alone); this LLVM is NOT LLVM 15 airconv.
pp notices --prepare-rust-cache .work/rust-notice-cargo   # destination must not exist
RUST_NOTICE_CARGO_HOME=$PWD/.work/rust-notice-cargo pp notices OUT
# OUT must not exist yet (build/notices-assemble.sh)
```

The script copies each licence and notice file byte for byte from the pinned
trees of a finished `pp build` run into `OUT`, and writes
`SHA256SUMS`. The tree roots default to that run's layout under
`$PLAYPORT_BUILD/run` and can be overridden with `WINE`, `FEX`, `MYTHIC`
(the Madeira checkout), `DXMT`, `LLVM`, `FREETYPE`, `MESA`, `DXVK`, `VKD3D`, `GBE` and `ABSL`; `STIKJIT` and
`IDEVICE` default to the checkouts `build/stages/stikjit.sh` keeps in
`$PLAYPORT_BUILD/cache`, and `IDEVICE_RUN` to the run's `idevice` stage output.
`build/notices-provenance.py` reconstructs each expected Git tree from its pin
and ordered series in disposable scratch storage, compares its tree ID with
HEAD, and rejects tracked local changes. Populated submodules are checked
recursively; rpmalloc has its own declared series. Required notice submodules
must exist. Deliberately absent submodules are recorded as **not verified**;
Madeira's Wine gitlink is not collected (the build replaces it with a symlink
to the separate Wine tree). This is not a complete source-bundle check.
Crypto tarballs must pass Madeira's `SHA256SUMS`. Rust verification exports
committed idevice source and copies the Cargo registry into disposable scratch
under `.work` before running Cargo: even offline metadata/tree commands maintain
cache locks/bookkeeping. It requires the pinned Rust toolchain, cached archives
and index; it neither fetches nor compiles. `RUST_NOTICE_CARGO_HOME` selects a
separate registry for verification and notice copies (default `$RUST_ROOT/cargo`).
The compiler and standard-library documentation still come from `RUST_ROOT`.
`RUST_NOTICE_DIST` (default `$PLAYPORT_BUILD/cache/rust-dist`) must contain the
locked `rustc` host, `rust-std` iOS and target-independent `rust-src` `.tar.xz`
archives. Collection verifies notice bytes and the entire installed iOS
standard-library payload, inventories the matching published source archive, and
copies its recursive notice-file candidates and library packages' direct
`license-file` payloads as a labelled superset. It never
installs, unpacks source-tree paths or downloads components. MinGW collection also
requires `LLVM_MINGW` (from `pp setup`) and clean `MINGW_SOURCE`/`LLVM_MINGW_SOURCE`
checkouts; see [below](#mingw-w64-source-and-installed-notices). No app resources, source repositories,
shared registry inputs or tracked files are updated.

Collection uses a temporary directory beside `OUT`. It publishes `OUT` only
when all collection steps and checksum verification succeed; failure removes
the temporary output and never replaces an existing destination. A successful
collection is still an incomplete inventory while the gaps below remain.

Git-sourced direct copies and recursively discovered Wine notices must be
regular tracked files with their committed bytes; untracked additions and
symlinks are rejected. The following path-independent manifests accompany
`SHA256SUMS`:

- `tree-provenance.json`: pins, actual/expected tree IDs, ordered patch hashes
  and populated/absent submodule status;
- `notice-origins.json`: component-relative origins of direct copies (including
  recursive Wine and Khronos header notices), checking that copied bytes equal their sources;
  Rust release notices require locked-archive verification and are rehashed at
  copy verification; registry notices have their own archive-member origins in
  `rust-provenance.json`. No unverified Rust cache copies are accepted;
- `derived-origins.json`: committed archive/source hashes, exact archive member
  names or inclusive line ranges, and extracted-payload hashes and sizes. Each
  extract is recomputed and compared byte for byte. Missing, duplicate or
  non-regular archive members, invalid/short line ranges, untracked/changed
  sources and changed extracts fail collection. No archive paths are unpacked
  to the filesystem by this verification. Correct line ranges do not establish
  that an excerpt includes every required notice;
- `rust-provenance.json` (schema 3): idevice tree and committed `Cargo.lock` hash, pinned
  Rust version, shared build target/features, regenerated path-independent normal
  dependency inventory/hash, registry archive hashes and per-file source hashes.
  Generated `crates.tsv` must match offline Cargo resolution. Every registry
  package reported by metadata is checked against its committed lock checksum;
  selected crates are recorded. Missing/mutated archives, changed source files,
  injected files, duplicate/unsafe/link archive members, source symlinks and
  unsupported Git/alternative-registry sources fail collection. Cargo's own
  `.cargo-ok` and `.cargo-checksum.json` markers are not trusted as source.
  Each selected registry crate records its direct `license-file` declaration,
  resolved archive path and recursive `notice_candidates`. Collection reopens
  locked archives and copies that notice superset, including non-candidate declared
  filenames, not shared extracted sources. `collected_notices` records exact
  archive members/checksums, payload hashes/sizes and declaring manifests.
  The reviewed `build/rust-attribution.lock.json` catalog additionally pins focused
  whole-file attribution evidence; its hash and `attribution_superset` markers
  stay in the record. Publication rechecks the complete pinned evidence set,
  hashes/sizes and incomplete scope, even if source/candidate/origin entries are
  jointly removed. Evidence copies do not remove notice-less crates from the summary.
  Missing/unsafe/inherited declarations and flattened-name collisions fail closed.
  Inventory publication rechecks candidate/declaration coverage, the selected crate
  set, all copied bytes/origins and both crate summaries. Crates with no native
  notice files remain explicitly listed; licence expressions alone do not satisfy
  attribution. This is not a header-credit or linked-member audit;
- `rust-stdlib-provenance.json` (schema 4): committed Rust distribution lock hash,
  release manifest identity/hash, three release archive hashes, installed
  standard-library file hashes and notice member/source hashes. Every archive's
  `version` and `git-commit-hash` must match the locked release identity. The
  `source` record hashes every regular file in `rust-src`, lists library package
  declarations and recursively identifies notice-file candidates (including
  vendored sources, compiler-builtins and libunwind). Library packages' direct
  `license-file` declarations add candidates regardless of basename, with resolved
  `license_file_source` paths and `declared_by` manifest lists. Collection copies
  every candidate byte for byte, with `collected_notices` mapping flat output names
  to source paths, archive members/checksums, payload hashes and sizes. These
  are a **notice superset, not an applicability audit or resolved/linked
  dependency graph**. Unsafe, duplicate, link,
  wrong-root or colliding archive members, missing required source/licence files,
  missing/changed notices, dirty/untracked locks, pin/identity mismatches and
  changed/extra/symlinked installed library files fail collection. Copying
  rechecks the source archive and candidate bytes; flattened-name collisions,
  existing/symlinked destinations and failed writes are refused. Before inventory
  publication, missing/extra/changed/symlinked source-notice outputs and incomplete
  or mismatched origin maps, omitted declared candidates and inconsistent declaration/
  source-file hashes are rejected. This checks
  published source/archive bytes, **not binary build derivation, actual linked
  members, the compiler executable, complete Corresponding Source or an IPA**;
- `mingw-provenance.json` (schema 1): committed notice-lock hash, exact reconstructed
  mingw-w64/llvm-mingw source trees, release-script checksum/revision declaration,
  recursive tracked source notice candidates (plus root `AUTHORS`), copy hashes/sizes
  and installed notice-byte comparisons for the three PE target CRT directories.
  Inventory publication rechecks complete payload/origin and installed-notice coverage.
  This is a source notice superset, **not library/header build derivation or IPA provenance**;
- `mesa-provenance.json` (schema 1): exact Mesa source tree, mandatory and selected
  vendored/local header paths, committed Git blob IDs, full-file LF line ranges,
  source/payload hashes and sizes. Collection preserves full header bytes as an
  explicitly labelled notice superset; inventory publication recomputes the
  selected set, source bytes, origins and exact-tree association. Missing/extra/
  changed/symlinked payloads or omitted origins fail. This is not compiled-header
  applicability, generated-input attribution or binary/IPA derivation;
- `gstreamer-provenance.json` (schema 1): the complete preparatory Cerbero/source
  manifest, retaining recipe/archive hashes, per-source file hashes, mandatory/
  recursive candidates and internal alias origins. All 17 reviewed component
  archives are required; assembly disallows partial subsets. Flat
  `gstreamer-source-<component>-<source-path>` payloads preserve every collected
  byte; flattened collisions fail. Before inventory publication the collector
  recomputes the full manifest from the committed review lock and reverified
  archives, checking complete payload coverage and bytes. The tree gate requires
  this collection even if all GStreamer outputs are deleted. Inputs default to
  `$PLAYPORT_BUILD/cache/gstreamer-notices/cerbero.tar.gz` and `sources/`, overridden
  by `GST_NOTICE_CERBERO`/`GST_NOTICE_SOURCES`. No download occurs. This is
  **recipe-associated source evidence, not verified binary/IPA derivation**;
- `llvm-runtime/`: the separate, large runtime/header superset from
  `build/notices-llvm-runtime.py`, with its own `llvm-runtime-provenance.json`,
  `SCOPE.txt` and `SHA256SUMS`. The original verifier regenerates all source/lock/
  candidate/origin bytes and checks the **entire directory** before final inventory
  publication. Its tree-gate requirement prevents omitting the directory; root
  flattening, extra directories and missing/changed/symlinked files fail. Source
  inputs are `LLVM_RUNTIME_SOURCE` (default `$PLAYPORT_BUILD/cache/llvm-runtime-notices`)
  and `LLVM_MINGW_SOURCE`. Preserve the whole collection contract; do not silently
  trim its roughly 82 MB of source/test/tool text for an app resource. Applicability
  and the eventual app notice selection still require review;
- `inventory.json`: names, sizes and SHA-256 hashes of all payloads, including
  the other manifests and verified `llvm-runtime/` files, labelled
  **incomplete-inventory**. The outer `SHA256SUMS` covers nested files and the
  inner checksum list; only the outer checksum list excludes itself.

These records contain no workstation paths. They establish the scope of the
collection, not that the selected inputs produced any particular IPA. The
Rust binary-to-source build derivation and prebuilt embedded-library provenance
still require separate verification. A normal-dependency graph is not a link-member
or build-dependency audit and does not prove which crates survived prelinking.

Registry sources must be pristine archive bytes. Builds can leave generated
files in the cache (the existing cache has `plist_ffi/plist.h`); collection
refuses those extras. `pp notices --prepare-rust-cache OUT` creates separate
notice inputs using `build/notices-rust-cache.py`, without reading or resetting
the build cache's extracted sources. It checks the exact idevice pin and clean
committed lock, requires a unique cached archive for **every registry package
in that lock** (including inactive packages), verifies each archive checksum,
and materializes only validated regular members. Unsafe paths, duplicate members,
file/directory collisions, links, unsupported sources and missing inputs fail
without publishing output. It copies the offline index, not credentials,
configuration, binaries or toolchain state. No fetch or compilation occurs.

The path-independent `notice-cache.json` records archive and source hashes;
Cargo bookkeeping markers are generated, not trusted as provenance. Publication
is same-filesystem and refuses existing/racing destinations. Preparation alone
does not resolve dependencies: collection still independently regenerates the
inventory and rechecks every metadata crate against committed lock/archive bytes.
Keep this cache private under `.work`; it is not a completed source package or
verified standard-library source package.

### Rust release archive lock

`build/rust-dist.lock.json` records the release-specific HTTPS manifest and
its checksum, and the three component URLs/checksums selected from it. For Rust
1.98.1, the published manifest was fetched locally and checked against its
published `.sha256` file. This is a reviewed checksum pin, not a verified
publisher signature. Updating the Rust pin requires reviewing and committing
this lock too; collection does not trust an installed rustup manifest as its
checksum authority. The full source commit is read from the checksum-verified
archives; all three must declare the same commit and release string. This is an
upstream release association, not proof that rebuilding those sources reproduces
the installed libraries. Keep the release archives private in `.work`, not in Git.

The `rust-src` inventory includes archive-root licences/copyright, library sources,
vendored crates and libunwind. Notice candidates are regular files whose basenames
start with licence/license/copying/copyright/notice/unlicense. Library package
`license-file` declarations also select regular archive payloads, independently
of basename. Paths are resolved relative to the declaring manifest, including
parent-relative references within the archive; shared/discovered files are copied
only once, retaining every declaring manifest. Missing files, directory references,
archive escapes, absolute/Windows/control-character paths and non-string declarations
(including workspace inheritance) fail closed. Workspace resolution is not yet
implemented; collection never guesses an inherited notice. Package licence
expressions remain inventory data, not licence selections. Neither discovery rule
finds every source-header attribution or establishes applicability. Required root licences,
workspace lock/manifest, core/alloc/std sources, compiler-builtins and libunwind
licences must exist. All recursive notice-file candidates are now copied as
`rust-source-<source-path-with-slashes-replaced-by-hyphens>`; ambiguous flattened
names fail rather than overwrite. The manifest retains exact original paths.
The source archive is rehashed/reopened before copying; no source-tree paths
are unpacked. Standalone verification without `--collect-source-notices OUT`
remains read-only and does not declare a `collected_notices` map.

This superset includes test/other-platform/tool material. It does not determine
which texts apply to iOS, collect every source-header credit or resolve inherited
workspace declarations. Registry crates' direct declared notices are collected
separately from their locked archives (below). This does not prove
binary derivation or supply a recipient-side rebuild package. Header/declaration
and linked-member review remain open.

`COPYRIGHT-library.html` and `licenses/` are supplied by the **rustc component**,
not `rust-docs`. Every supplied licence text is collected as a clearly labelled
release superset (including compiler/documentation licences and exceptions), not
as a claim that each applies to linked stdlib code. The old optional five-text
list omitted Unicode and other supplied texts; the 1.98.1 archive has no separate
BSD-3-Clause text. Missing required MIT/Apache-2.0/BSD-2-Clause/ISC texts or the
library copyright file now fail rather than silently omitting them.

### Rust registry notice selection

The collector reads the normalized crate-root `Cargo.toml` from each locked
archive, not `Cargo.toml.orig` or guessed workspace defaults. Recursive regular
files with licence/license/copying/copyright/notice/unlicense basenames form a
superset; direct `package.license-file` payloads are added regardless of basename.
Internal `.`/parent path components are normalized within that crate only.
Archive escapes, missing/directory payloads, absolute/Windows/control-character
paths and non-string/inherited declarations are refused. Declaration/discovery
matches are copied once. Root notice output names stay unchanged; nested paths
have slashes replaced with hyphens, with collisions refused before any copy.
Standalone verification remains read-only unless `--collect-notices OUT` is used.

The local locked idevice inventory selects 147 registry crates. Collection now
preserves 277 native notice files, including five nested files previously missed:
regex-syntax's Unicode table licence; ring's once_cell MIT/Apache notices and
fiat notice; tracing-core's spin notice. Three crates still supply no notice file:
`ns-keyed-archive`, `plist-macro` and `plist_ffi`. Their licence expressions remain
inventory data, not substitute attributions or verified StikJIT provenance.
The [locked-source audit](release-audits/stikjit-rust.md) found author/README
credits, a serde macro-port origin gap in `plist-macro`, and original LGPL
libplist headers/C++ material in `plist_ffi` despite package-level MIT metadata.
The filename-based selector alone misses those source/header credits. The focused
`build/rust-attribution.lock.json` catalog now preserves **103 additional full
files, 299,542 bytes** (9 ns-keyed-archive, 11 plist-macro, 83 plist_ffi), bringing
registry collection to **380 notice/evidence files**. Exact archive checksums and
per-member hashes/sizes are pinned separately from generated provenance. All
regular files outside `plist_ffi`'s `test/data/` fixture subtree are retained:
README/licence distinctions, original/normalized manifests, publisher VCS clues,
Rust sources, libplist C/C++ headers/sources, tests/scripts, tools and example
credits. Source/test/tool bytes are an explicit attribution **evidence superset**,
not app-ready licence texts or proof that those files are compiled/shipped.

Inventory publication rechecks the catalog identity, complete selected set and
payload hashes/sizes; missing members, modified bytes, removed superset markers,
changed scope or old schema records fail. The native selector remains available
for the observations-only audit. The notice-less summary still lists all three
crates: preservation does not create absent MIT copyright/permission grants,
identify serde's original revision or establish adequate original notices. No
copyright year, licence substitution or copied-code provenance is guessed.
Complete attribution/rights and compiled/linked applicability remain open; this
catalog covers Playport's locked executable dependencies, **not StikJIT**.

### mingw-w64 source and installed notices

`build/mingw-notices.lock.json` records llvm-mingw release `20260922`'s source
commit `0eca5ac93da14a74bc81c249e841356ececc5d95`, its `build-mingw-w64.sh`
checksum and the script's `MINGW_W64_VERSION` revision
`57b595039040eaa15bece85b7cc71d952281b269`. These were reviewed against the
published tag and committed script; the release tag is unsigned. Neither a tag
name nor identical notice bytes proves installed binary derivation. Updating the
toolchain requires reviewing this lock and the local arm64ec CRT rebuild too.

Prepare separate, clean Git checkouts at those commits under `.work`; defaults
are `$PLAYPORT_BUILD/cache/mingw-w64-notices` and
`$PLAYPORT_BUILD/cache/llvm-mingw-notices`. `MINGW_SOURCE` and `LLVM_MINGW_SOURCE`
can instead name existing clean inputs. `build/notices-mingw.py` uses disposable
Git reconstruction with no patches, requires a committed regular lock and exact
script bytes, and refuses dirty/wrong trees, symlinked inputs, missing required
notices and flattened-name collisions. It never fetches, builds or modifies
source/toolchain inputs. Output and scratch cannot be inside either input tree.

The current source supplies **12 texts**, including root `AUTHORS`, the ZPL
summary, `COPYING.MinGW-w64-runtime.txt`, the tool/header summary, profile GPLv2,
winpthreads/winstorecompat notices and other library/tool texts. All are copied
byte for byte as `mingw-source-<flattened-source-path>`, including unlinked/tool
material as an explicit superset. The runtime notice includes project, getopt,
gdtoa, Sun math, musl-derived functions and Wine header/IDL attributions; the
DirectX header summary alone never replaced it.

Five installed notice files in each of `aarch64-w64-mingw32`, `i686-w64-mingw32`
and `x86_64-w64-mingw32` (the CRT directories our PE builds use, including
arm64ec's aarch64 CRT) must equal their locked source bytes: `COPYING`,
`COPYING.MinGW-w64.txt`, `COPYING.MinGW-w64-runtime.txt`, `COPYING.winpthreads.txt`
and `COPYING.winstorecompat.txt`. Missing/changed/symlinked files fail before any
copy. Write failures roll back created payloads; inventory publication refuses
missing/extra/changed/symlinked copies and incomplete origin maps.

This does **not** audit individual compiled headers, actual linked members,
libc++/compiler-rt notices or CRT rebuild provenance. The runtime text's upstream
**Cephes FIXME** is answered by Moshier's own grants, which FEX's
`cephes-LICENSE.txt` quotes; the app carries that file for mingw-w64 as well, and
the reading awaits review ([audit](release-audits/mingw-cephes.md)). The separate
DirectX copies remain tied to their DXMT/DXVK submodule versions.

### Separate LLVM runtime preparation

`build/notices-llvm-runtime.py` now supplies standalone offline `inspect`,
`collect` and `verify` actions using `build/llvm-runtime-notices.lock.json`.
The exact LLVM 23.1.2/llvm-mingw script association and source bytes are verified;
this is separate from LLVM 15.0.7's airconv notices. The actual-source smoke
scanned **17,768 files** and preserved **14,321 whole-file texts, 81,916,394 bytes**.
Recursive notice/credit and marker-selected files include code, tests, tools,
documentation and other platforms as an explicitly incomplete superset.

This output is **not part of `pp notices`**. Do not merge its flat files blindly:
its complete-set `verify` contract, scope text and checksum list must survive
an explicit future assembly integration. Exhaustive attribution, installed
headers/generated inputs, actual applicability, libunwind's missing legacy
contributor reference and binary/IPA derivation remain open. See
[the collection audit](release-audits/llvm-runtime-collection.md).

### Khronos header notices in the PE backend

`build/notices-khronos.py` collects the root notice summaries and recursive
notice candidates, including **every regular file under `LICENSES/`**. Generic
text basenames such as `MIT.txt` and `Apache-2.0.txt` must not be missed. The
current seven checkouts supply **21 texts**, each kept separately:

- DXVK's `include/vulkan`, `include/spirv` and
  `subprojects/dxbc-spirv/submodules/spirv_headers`;
- vkd3d-proton's `khronos/Vulkan-Headers`, `khronos/SPIRV-Headers`,
  `subprojects/dxil-spirv/third_party/spirv-headers` and
  `subprojects/dxil-spirv/subprojects/dxbc-spirv/submodules/spirv_headers`.

The tree gate now requires those gitlinks recursively, including converter
parents. Missing/undeclared nested submodules fail instead of being accepted as
optional absent inputs. Collection requires declared Git roots and committed
regular source bytes; missing required summaries/texts, untracked/changed notices,
symlinked sources/parents, control-character paths, flattened-name collisions and
existing outputs fail before copying. Failed payload writes remove only created
payloads. The enclosing assembly removes its entire temporary output on failure.
Direct-copy origin verification rechecks the copied bytes before publication.
Standalone collection does not replace the assembly's exact pin/series tree gate.

Names are `khronos-<dxvk|vkd3d>-<component-relative-path-with-slashes-replaced-by-hyphens>`.
Do not deduplicate attribution across checkouts with different gitlinks. Root
copyright summaries accompany the generic licence texts; the SPIR-V normative
header warning is retained. This is a source notice **superset**, including
CC-BY-4.0 documentation/tool material, not a claim that it is executable code.
Per-file credits, actual header/code applicability and other shader-converter
libraries still need review. These separate checkouts do not cover Mesa's
vendored headers; the scoped Mesa collection below preserves those separately.

### Mesa vendored Vulkan/SPIR-V header notices

`build/notices-mesa.py` preserves full committed headers under `include/vulkan/`
and `include/vk_video/`, plus top-level headers under `src/compiler/spirv/`.
The exact reconstructed source supplied **43 headers, 1,968,209 bytes** in the
local smoke. Outputs are `mesa-header-superset-<flattened-source-path>.txt`, with
`mesa-provenance.json` retaining original paths, blobs, full-file line ranges
and hashes. Full headers include code and other-platform/Mesa-local material:
this is a notice superset, not a licence-text-only directory or a linkage claim.

This avoids guessing a prefix that might omit copyright/permission blocks,
Android notices after code, or SPIR-V normative warnings. Assembly retains its
exact pin/series gate; collection and inventory revalidation reject dirty,
untracked, missing, symlinked and colliding scoped inputs and altered copies.
Revalidation requires the same `MESA` source input. Generic Mesa licence texts
remain separate. Generated registry/grammar input credits, other source/header
attribution and actual compiled-header/linked-member applicability remain open.
See [the Mesa audit](release-audits/mesa.md) for scope and source-level evidence.

## What is collected, and why

| Files in `OUT` | Source tree | Needed for |
| --- | --- | --- |
| `Playport-LICENSE.txt`, `Playport-LICENSE-EXCEPTION.md` | this repository | the app's own code |
| `JavaSteam-LICENSE.txt` | `app/SteamClient/LICENSE-JavaSteam.txt` (JavaSteam's MIT licence) | the Steam protocol schema tables in `app/SteamClient` |
| `GPL-2.0.txt`, `LGPL-3.0.txt` | the GMP tarball | the GPL-2.0-or-later and LGPL-3.0-or-later options of GMP, Nettle and FreeType |
| `LGPL-2.1.txt` | wine `COPYING.LIB` | Wine, DXMT, the directx headers, `regexp.c` |
| `wine-LICENSE.txt`, `wine-COPYING.LIB.txt`, `wine-LICENSE-MADEIRA.md`, `wine-NOTICES.md` (plus `wine-LICENSE.OLD.txt` only if present) | wine | both PE DLL sets, `nls/`, the unix side; Wine's current root notices and any historical licence actually present |
| `wine-libs-<relative-path>` (slashes become hyphens) for licence, copying, copyright and notice files recursively found under `libs/` | wine `libs/`, collected by `build/notices-wine.py` | a superset including unlinked libraries, not a claim of linked-code coverage; includes new library notices without relying on the removed `tomcrypt` directory |
| `FEX-LICENSE.txt`, `FEX-LICENSE-MADEIRA.md` | FEX | `xtajit64.dll` |
| `rpmalloc-LICENSE.txt`, `rpmalloc-LICENSE-MADEIRA.md`, `fmt-`, `xxHash-`, `cephes-`, `SoftFloat-3e-`, `tiny-json-`, `cpp-optparse-`, `unordered_dense-LICENSE.txt` | FEX `External/`, Madeira `LICENSES/` (SoftFloat) | the code statically inside `xtajit64.dll` |
| `Madeira-LICENSE.txt`, `Madeira-LICENSE-EXCEPTION.md`, `Madeira-THIRD-PARTY-NOTICES.md` | Madeira | the host layer in the executable, Winios |
| `DXMT-LICENSE.txt`, `DXMT-COPYING.LIB.txt`, `DXMT-LICENSE.OLD.txt`, `DXMT-LICENSE-MADEIRA.md`, `DXMT-COPYING.GPL-3.0.txt` | DXMT (upstream's LGPL-2.1-or-later licence and its former MIT one, then Madeira's port) | the unix slice and the DXMT PE DLLs |
| `DXBCParser-header.txt` | DXMT `libs/DXBCParser` (first lines of a source file; the directory has no licence file) | DXBCParser, in the slice and the PE DLLs |
| `DXBCParser-LICENSE-Microsoft.txt` | `build/notices-extra/D3D12TranslationLayer-LICENSE`: microsoft/D3D12TranslationLayer's MIT `LICENSE` at a recorded commit, where DXBCParser's files come from (DirectX-Headers' is the same text) | the MIT text DXBCParser's headers name |
| `crate-notice-from-metadata-{ns-keyed-archive,plist-macro,plist_ffi}.txt` | `build/notices-extra/*-NOTICE-from-metadata`, written by Playport from each crate's Cargo.toml (`license`, `authors`), since none has a licence file upstream ([decision 0039](decisions/0039-owners-licensing-review.md)) | the three locked crates' MIT notices, labelled as written from metadata |
| `mingw-source-<flattened-source-path>` (12 texts at the current lock) | exact mingw-w64 source revision declared by locked llvm-mingw release script; 15 installed notice copies compared against source | PE runtime/header and library/tool notice superset, not linked-member or binary-build proof |
| `mingw-directx-headers-COPYING.MinGW-w64.txt` | DXMT `include/native/directx` | the headers compiled into the slice |
| `LLVM-LICENSE.TXT`, `LLVM-Support-COPYRIGHT.regex.txt`, `LLVM-Support-ConvertUTF-Unicode-notice.txt` | LLVM 15.0.7 | the LLVM libraries in the executable, and the regex and Unicode code the link keeps |
| `FreeType-LICENSE.TXT`, `FreeType-FTL.TXT`, `FreeType-GPLv2.TXT` | FreeType | FreeType in `libwin32u_unix.a`; both options, since the choice is open |
| `Mesa-license.rst`, `Mesa-licenses-<name>.txt` for every file in Mesa's `licenses/` | Mesa (`docs/license.rst`, `licenses/`) | KosmicKrisp in `KosmicKrisp.framework`; most of it is MIT, and each file names its licence in an SPDX header |
| `mesa-header-superset-<flattened-source-path>.txt` (43 at the current pin/series) | full committed Vulkan/video headers and top-level SPIR-V headers in Mesa | scoped copyright/permission/normative-warning superset, including code and other platforms; not compiled-header applicability |
| `DXVK-LICENSE.txt`, `DXVK-libdisplay-info-LICENSE.txt`, `DXVK-dxbc-spirv-LICENSE.txt`, `DXVK-mingw-directx-headers-COPYING.MinGW-w64.txt` | DXVK and its `subprojects/`, `include/native/directx` | the DXVK DLLs in `Runtime/vulkan/` (zlib/libpng; libdisplay-info and dxbc-spirv MIT) |
| `khronos-<dxvk\|vkd3d>-<flattened-source-path>` (21 texts at the current pins) | seven Vulkan/SPIR-V header checkouts, including nested dxbc-spirv/dxil-spirv copies | root attributions and recursive notice/`LICENSES/` superset for the PE backend; not Mesa's vendored headers or an applicability audit |
| `vkd3d-proton-COPYING.txt`, `vkd3d-proton-LICENSE.txt`, `vkd3d-proton-AUTHORS.txt` | vkd3d-proton (LGPL-2.1-or-later) | `d3d12.dll`, `d3d12core.dll` in `Runtime/vulkan/` |
| `dxil-spirv-LICENSE.MIT.txt`, `dxil-spirv-dxbc-spirv-LICENSE.txt`, `dxil-spirv-bc-decoder-header.txt`, `dxil-spirv-glslang-spirv-header.txt` | vkd3d-proton `subprojects/dxil-spirv` (the two headers are the first lines of a source file; those directories have no licence file) | the shader converter inside `d3d12core.dll` |
| `gbe_fork-LICENSE.txt` | gbe_fork (LGPL-3.0) | `steam_api64.dll`, `steam_api.dll` in `Runtime/steamapi/` |
| `gbe_fork-libs-<lib>-SOURCE.txt` for fifo_map, gamepad, json, sha, simpleini, stb, utfcpp | gbe_fork `libs/` (each `SOURCE.txt` holds the library's origin and licence text) | the header libraries compiled into the steam_api DLLs (MIT; sha1 public domain; stb MIT or public domain) |
| `gbe_fork-deps-<dep>-<file>.txt` for curl, libssq, mbedtls, opus, portaudio, protobuf (and its `utf8_range`), sdl, zlib; `abseil-cpp-LICENSE.txt` | the archives on gbe_fork's `third-party/deps/common` branch at the pinned gitlink, and Abseil at the pins.lock `abseil-cpp` tag | the libraries linked statically into the steam_api DLLs (curl's licence, MIT, Apache-2.0 (mbedtls, chosen over its GPL-2.0-or-later option; Abseil), BSD-3-Clause (opus, protobuf), MIT (portaudio, utf8_range), zlib (SDL, zlib)) |
| `StikJIT-LICENSE.txt` | StikJIT at tag `1.6.0` (`LICENSE`, MPL-2.0) | the StikJIT framework in the JIT helper extension; its source location is in [LICENSING.md](LICENSING.md#stikjit) |
| `idevice-LICENSE.txt` | jkcoxson/idevice at commit `d32c8189c51c2789496b0768039419c3705498c3` (`LICENSE.txt`, MIT) | verified notice bytes for Playport's pinned executable input; donor bytes only for StikJIT, whose embedded revision/dependencies remain unverified |
| `rust-crates.tsv`, `rust-<crate>-<version>-<flattened-path>` for recursive notice candidates, direct declared `license-file` payloads and the focused attribution evidence catalog, `rust-crates-without-licence-files.txt` | `build/stages/idevice.sh`'s normal-dependency inventory, regenerated offline from pinned source; registry bytes verified against committed `Cargo.lock` archive hashes | idevice's normal target dependencies; not an exact linked-member inventory ([LICENSING.md, "idevice in the executable"](LICENSING.md#idevice-in-the-executable)) |
| `rust-source-<flattened-source-path>` for every recursive notice-file candidate | locked published `rust-src` archive, rechecked before copying | source notice superset (including root copyright, compiler-builtins, libunwind and vendored crates); applicability/header coverage still needs review |
| `rust-COPYRIGHT-library.html`, `rust-licenses-<licence>.txt` for every supplied text | installed `share/doc/rust`, verified against locked `rustc` release archive; installed iOS stdlib verified against locked `rust-std` archive | standard-library copyright inventory plus a release licence-text superset (including unlinked compiler/docs material); generic texts alone do not replace crate attribution |
| `GnuTLS-COPYING.LESSERv2.txt`, `Nettle-COPYING.LESSERv3.txt`, `Nettle-COPYINGv2.txt` | the crypto tarballs | the statically linked crypto libraries |

Each fork's `LICENSE-MADEIRA.md` is kept whole, including Madeira's converter
exception text, because it is part of that fork's licence notice.

## Credit lines

A licences screen must also show:

- "This software is based in part on the work of the Independent JPEG Group."
  (libjpeg in `windowscodecs.dll`, and IJG-derived FFmpeg files observed in the
  GStreamer trial prelink; exact release applicability still requires review);
- the Henry Spencer regex credit (`LLVM-Support-COPYRIGHT.regex.txt`, items 2
  and 3);
- FreeType's FTL credit, if FTL is chosen over GPL-2.0-or-later.

## The app's selection

The app does not carry the whole collection: much of it is audit superset
(the LLVM runtime source alone is about 82 MB of code, tests and tools).
[`build/app-notices.json`](../build/app-notices.json) is the reviewed list of
what it carries:

- one component per part of the IPA, with its licence and the collected files
  that are its notices. `pp test` fails when a provenance key in
  `app/artifacts.tsv`, or a part outside it (the Swift app, KosmicKrisp,
  StikJIT, the Rust standard library, llvm-mingw's runtime, the mingw-w64
  CRT), has no component;
- exclude groups, each with its reason: the collection records, the LLVM
  runtime superset beyond its root licence and credit files (the LLVM
  exception waives attribution for runtime code embedded by compiling), and
  the attribution evidence of the three Rust crates without licence files;
- the credit lines the licences require verbatim (IJG, Henry Spencer's regex,
  FreeType's FTL credit: FTL is chosen over GPL-2.0-or-later);
- the review status and the open questions a reviewer must settle.

```sh
pp notices --app $SRC/notices $SRC/Licenses   # build/notices-app.py select
```

`build/notices-app.py select` checks the collection is whole
(`build/notices-bundle.py`), then fails on any collected file that no component
includes and no group excludes, and on any include pattern that names no
collected file: a new or renamed notice needs a decision here. It copies the
selected files byte for byte and adds `components.json` (each component's
licence, parts and files, the credit lines and the open questions: the data
for the app's licences page) and `CREDITS.txt`, then `inventory.json` and
`SHA256SUMS`. Its status is `unreviewed-app-selection` until the selection's
review status is set to `release-reviewed` by the person who settles the open
questions; only then does `pp verify --distribution` accept it. The owner did so
on 2026-09-30 ([decision 0039](decisions/0039-owners-licensing-review.md)).

`build/notices-bundle.py check DIR` accepts only a whole bundle: every file in
`SHA256SUMS` and `inventory.json`, none missing, changed, unlisted, a symlink or
a special file. `stage SRC DEST` copies one only after that check and leaves
`DEST` unchanged on failure. `pp verify` checks an app's `Licenses/` the same
way, that its `components.json` covers every provenance key in the bundled
`artifacts.tsv`, and with `--notices DIR` that it equals that bundle. An app
without a reviewed selection is reported as not distributable;
`--distribution` fails it. The pipeline's `notices` stage makes the
selection from each build's collection and stages it as `app/Staged/Licenses`,
which both variants ship at the app root, and its `verify` compares the IPA's
`Licenses/` with it.

Settings › About › Licences (`app/Sources/S1Probe/UI/LicencesView.swift`, both
variants; pages in place of the About section, every row and paragraph on the
controller's ring, B back a page) shows Playport's copyright, licence and warranty notice and where its
source is, then reads `Licenses/components.json` through PlayportKit's
`Licences`: each component with its licence and files, each file's text, the
credit lines, and while the selection is unreviewed its status and open
questions. A missing or inconsistent `components.json` (a listed file absent, an
unsafe name, another schema) shows as missing notices, never a placeholder list.
A dev build's driver opens it with `open:licences` (`open:licences#wine` for a
component). No build has run the stage or compiled the page yet.

## Gaps

- **No IPA carries notices yet.** The `notices` stage and the licences page
  exist ([The app's selection](#the-apps-selection)), but no build has run them.
  The selection is `release-reviewed` ([decision 0039](decisions/0039-owners-licensing-review.md)). The first build changes the IPA and its checksum.
- mingw-w64's runtime and recursive source notices are now collected and
  installed notice bytes checked (the Cephes reading is accepted:
  [audit](release-audits/mingw-cephes.md), decision 0039), but actual
  CRT/header/linked-member coverage and local CRT build derivation still need review.
  The exact-source LLVM runtime/header-credit superset is now collected in a
  separately verified `llvm-runtime/` directory, but exhaustive attribution,
  applicability and binary derivation remain open
  ([LICENSING.md, "Open items"](LICENSING.md#open-items)).
- Mesa's licence texts are collected whole; which of them the files compiled
  into KosmicKrisp carry has not been read file by file. DXVK/vkd3d-proton's
  seven Khronos header checkouts now supply root notices and licence-text
  supersets, including nested converter copies. Their per-file/header applicability
  audit remains open. Mesa's scoped vendored Vulkan/video/SPIR-V full headers now
  preserve their credits, but compiled-header applicability, generated-input and
  other source/header credits and additional shader-converter notices remain open.
- Madeira's `THIRD-PARTY-NOTICES.md` is copied as Madeira ships it; on its
  own it does not cover everything in this build.
- Wine's recursive notice inventory fixes stale filenames but does not prove
  coverage of every compiled file/header, generated data or required credit.
  Its component/linked-member inventory needs review against the current pin.
- Exact tree/series checks and origin maps cover notice inputs, extracts and
  populated submodules, not a complete source bundle or their connection to an
  IPA. Absent submodules, Rust standard-library build derivation/linked-member
  provenance and StikJIT's embedded dependencies remain incomplete. Rust
  registry/archive and regenerated inventory checks do not cover build dependencies
  or a link-member audit; use the separate pristine notice inputs when the shared
  cache has generated extras. Published `rust-src` bytes and package declarations
  are inventoried and notice-file candidates are collected as a superset, but
  direct library `license-file` declarations are collected regardless of basename.
  Registry notices now include recursive candidates and direct `license-file`
  payloads from locked archives, with complete copy/summary coverage checks.
  The focused three-crate catalog additionally preserves full original attribution
  evidence, including libplist headers and serde-port credits; it does not repair
  missing permission notices or establish copied-code origins. Additional header
  credits, inherited workspace declarations and notice-less crates still need
  review/collection, and supplied texts need applicability review.
  The StikJIT/Rust audit additionally identified mixed LGPL libplist source/header
  terms and a serde macro-port attribution gap. StikJIT archive/metadata clues
  do not recover its exact dependency set; the copied idevice donor notice is
  not verified embedded-framework coverage.
  The collector is not proof of release-source provenance.
- **GStreamer's complete release notice coverage remains unresolved.**
  `pp notices` now includes `build/notices-gstreamer.py`'s preparatory superset:
  17 Cerbero-recipe-associated archives and 66 notice/attribution candidates,
  including GLib's internal COPYING aliases, zlib's non-candidate README,
  patent texts and FFmpeg IJG source credits. Its committed review lock is
  **not a binary-build lock**. Assembly verifies the entire preparatory set;
  it does not establish that these archives produced `libwinegstreamer_unix.a`.
  Producer Cerbero configuration/patched-source association,
  Rust 1.96.0/embedded-crate and MoltenVK source/notices, additional header credits,
  codec/linked-member applicability and exact-IPA provenance remain unresolved.
  See [the GStreamer audit](release-audits/gstreamer.md) for versions, origins,
  trial-map limitations and independent patent questions.
