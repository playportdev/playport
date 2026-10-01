# GStreamer/Cerbero static-prelink notice provenance

## Result and scope

**Preparatory source inventory completed; the release notice gate is still open.**
This audit selects checksum-verified source archives associated with Cerbero's
`1.28.7` recipes, not a verified binary-build dependency lock. It supplies a
standalone offline collector and preserves notice/source-attribution bytes.
The host-only continuation below integrates this preparatory superset into the
notice assembler; app staging, runtime pipeline, pins and licences are unchanged.
No app/runtime build, installation, device command, upload or legal clearance.

There are three different evidence levels:

1. The committed `build/stages/gstreamer.sh` pins the iOS archive checksum and
   registers 20 plugins. The cached archive matches that checksum.
2. An existing **trial**, not release, prelink map identifies archive members.
   Current shared-run symbols corroborate the 20 plugin descriptors, but neither
   tree is a release from this branch. The committed stage produces no link map.
3. Public Cerbero `1.28.7` recipe bytes and the 17 selected source archives are
   independently checksum-verified. A matching release number and plausible
   embedded version strings do **not** establish binary derivation from them.

## Reproducible references and integrity

Full source URLs, SHA-256 values, archive roots, recipe hashes and mandatory
notice paths are in [`build/gstreamer-notices.sources.json`](../../build/gstreamer-notices.sources.json).
Its status is deliberately `preparatory-source-review-not-binary-build-lock`.
Checksums are reviewed HTTPS evidence, **not locally verified publisher signatures**.
GitLab exposes signed tag material, but this audit did not verify its trust chain.

| Input | Exact identity / SHA-256 |
| --- | --- |
| Stage bytes | `be9b77fd24c0f7948d85c64a864fca9a95eda9590bfedf71bfb4b87fedbc12ef` |
| iOS release archive (`gstreamer-1.28.7-xcframework.tar.xz`) | `2b1233ba3d1f8166bfa85f664709ee5ff36b81e82b9652a1d3e79c1783da9584` |
| Its unique regular `GStreamer.xcframework/ios-arm64/libGStreamer.a` member; matches extracted cache bytes | `ecf080ef5498547660e8d02d9986958d65f010d7089ecdf0d51f7f9d1a6b0b60` (1,346,491,424 bytes) |
| GStreamer `1.28.7` tag commit | `070125524a8422e29d3b69a372ed4f62fd343ffa` (tag object `ce166e12155ed01fa521e29698c9904ea5608056`) |
| Cerbero `1.28.7` tag commit | `e0e7007e210dab3e2f3e898939e2cfe1fd02f123` (tag object `264e80df17fb52de1a9750764334b246aeae586a`) |
| Cerbero commit-addressed source archive | `f55907635c6edcd1448bad0e3bda1f346ae707a61ec66ad2d1dd854f7e0df16e` |
| Existing trial `hk-video/prelink.map` | `dde420fce93eca375b77e3800b536cdce7edc74123bb737520dbaac5f48f3ea5` |
| Current shared-run `unix/gstreamer/obj/symbols.txt` | `eed89d16c0e6e6278c92b68e02d02a0a9bbfe91bb0f4e52700b03a386c068367` |
| Current shared-run `unix/gstreamer/obj/winegstreamer_unix.o` | `fd46e0301bcba9f0b33f5e573527fe582bca6693551ee6725dee39543fcc4762` |
| Current shared-run `unix/gstreamer/libwinegstreamer_unix.a` | `01ac411c12fb9c3cb02e7d605cf8a720fe24f31347973fd4b7f54f770479954a` |

Tag review endpoints:

- <https://gitlab.freedesktop.org/api/v4/projects/gstreamer%2Fcerbero/repository/tags/1.28.7>
- <https://gitlab.freedesktop.org/api/v4/projects/gstreamer%2Fgstreamer/repository/tags/1.28.7>

The release archive was streamed read-only; no binary/toolchain was downloaded
or copied. No licence/copying/notice payloads were found in its member list
(the substring scan also matched unrelated header names). Six selected iOS
members were hashed separately, including version headers; their hashes and
sizes are local in `.work/gstreamer-review/cached-release-verification.json`.
Source downloads and public API responses are private under
`.work/gstreamer-review`; nothing from the cache is published here.

## Selected plugins and linkage observations

The committed static registrations, grouped by source release archive:

| Source 1.28.7 archive | Registered plugins |
| --- | --- |
| `gstreamer` | `coreelements` |
| `gst-plugins-base` | `typefindfunctions app playback videoconvertscale audioconvert audioresample vorbis opus ogg` |
| `gst-plugins-good` | `deinterlace videofilter autodetect isomp4 matroska audioparsers vpx` |
| `gst-plugins-bad` | `videoparsersbad applemedia` |
| `gst-libav` | `libav` |

The trial map's object-file section has **2,867 libGStreamer.a member entries**.
Do not infer inclusion from the entire 1.35 GB archive, headers or recipe `deps`.
Conversely, registering a plugin can reach encoders, sources, sinks and support
libraries, not just the decoder used in a tested game. `applemedia` pulls
VideoToolbox encoder and source/sink objects as well as decoder objects;
`vorbisenc` also appears. Ranking `vtdec`/`vtdec_hw` marginal does not unlink them.
GStreamer GL/Vulkan helpers appear even though no Vulkan plugin is registered.

The map has no archive-member families for x264, x265, GnuTLS, Nettle or GMP.
Those may exist in the full binary archive or elsewhere in the app; this is
only a negative observation about this trial map. The 20 descriptors in the
current shared-run symbol list match the registrations. A production prelink
and final executable map, tied to clean input records and an IPA hash, are
still required; hidden symbols and member names alone are insufficient.

## Component/notice table

Versions below are **exact recipe/source versions**, not an assertion that
these archives produced the binary. Every archive-backed row was downloaded
and checked against the recipe's full `tarball_checksum`; the JSON holds all
17 full checksums and exact member roots. Notice paths are relative to those
roots. Recursive candidates and all regular `LICENSES/` payloads are retained
as an unapplied superset, including test/tool/unlinked material.

| Component | Recipe version; trial-map evidence | Mandatory paths / attribution observations |
| --- | --- | --- |
| GStreamer core and support | `1.28.7`; 78 core members plus base/audio/video/app/pbutils/tag/riff/rtp/GL/Vulkan/codecparser libraries | Five separate `COPYING` files (core/base/good/bad/libav). Source headers retain author copyrights and often Library GPL 2-or-later declarations; supplied generic text is LGPL 2.1. Root texts alone are not an author/header audit. |
| GLib/GObject/GIO/GModule | `2.82.4`; 79/17/206/2 members | `COPYING` is a symlink to `LICENSES/LGPL-2.1-or-later.txt`; preserve verified target bytes and alias origin. All `LICENSES/` texts, `subprojects/gvdb/COPYING`, `docs/reference/AUTHORS`, `docs/reference/COPYING`, `gmodule/AUTHORS`. Includes LGPL and permissive/documentation/test alternatives; per-file applicability remains open. |
| FFmpeg | `7.1`; avcodec 1009, avformat 459, avutil 77, avfilter 25, swscale 24, swresample 11 members | `LICENSE.md`, `COPYING.LGPLv2.1`, `doc/authors.texi`; retain all four supplied GPL/LGPL texts as a **superset**, not a claim GPL code is linked. Whole `libavcodec/jfdctfst.c`, `jfdctint.c`, `jfdctint_template.c`, `jrevdct.c` preserve IJG attribution (below). |
| libvpx | `v1.14.1`; 250 members | `LICENSE`, **`PATENTS`**, `AUTHORS`; also third-party libyuv/libwebm/x86inc/gtest candidates. BSD-3-Clause baseline; patent grant retained, not general patent clearance. |
| Opus | `1.5.2`; 135 members | Whole `COPYING` (multiple copyright holders and patent/licensing discussion), `AUTHORS`; BSD-style terms. |
| libvorbis / libvorbisenc | `1.3.7`; 19/1 members | `COPYING`, `AUTHORS`; BSD-3-Clause. Encoder presence is not excluded by decoder-only usage. |
| libogg | `1.3.5`; 2 members | `COPYING`, `AUTHORS`; BSD-3-Clause. |
| PCRE2 | `10.42`; 23 pcre2-8 members | `LICENCE`, `COPYING`, `AUTHORS`; preserve subsidiary notices, including JIT-related attribution if applicable. `cmake/COPYING-CMAKE-SCRIPTS` is unlinked tool material in the superset. |
| ORC | `0.4.42`; 63 members | Whole `COPYING`: David A. Schleef's BSD-2-Clause baseline **and** Matsumoto/Nishimura's BSD-3-Clause Mersenne Twister notice. Recipe says BSD-3-Clause; calling everything only BSD-2-Clause loses a notice. Applicability of the latter still requires member review. |
| libffi | Meson port **`3.2.9999.5`**, not guessed system libffi; 4 members | `LICENSE`; MIT attribution. Exact Meson-port archive/checksum, not a substitute modern libffi release. |
| zlib | `1.3.1`; 10 members | **`README`** (recipe-declared notice, non-candidate basename) and `LICENSE`; retain both. Recursive contrib notice is a superset. |
| bzip2 | `1.0.8`; 7 members | Whole `LICENSE`: Julian Seward's copyright, conditions, disclaimer, altered-version marking requirement and separate historical libbzip2 naming condition. |
| proxy-libintl | **`0.5`**; one `libintl.c` member | `COPYING`; LGPL-family source notice. Mirror member filename is `0.5.tar.gz`; recipe also defines a local `proxy-libintl-0.5.tar.gz` filename. Neither is GNU gettext's source/version. |
| Rust support reached through `libgstaws` | Recipe bootstrap candidate **Rust `1.96.0`**; 11 members named object/compiler_builtins/gimli/std/panic_unwind/rustc_demangle/alloc/core/gstaws/addr2line | Not collected or binary-locked by this tool. Need exact standard-library release notices/source and crate notices, not the app's separately built Rust `1.98.1` inventory. Identify whether gstaws's glue contains attributable non-stdlib code. No aws descriptor is registered. |
| MoltenVK | Recipe **`1.3.283.0` is Vulkan SDK version**, not established MoltenVK source version; one `libMoltenVK.a-arm64-master.o` | Not collected or binary-locked. A single relocatable master object can encapsulate many sources/dependencies. Require SDK payload/source association, actual MoltenVK commit, `LICENSE`, any `NOTICE`, per-file credits and nested-library/header notices. Do not replace them with a current generic Apache text. |

The collector records hashes of **all Cerbero regular source files**, so recipe
patches, helper code and configuration have exact archive-member origins too.
FFmpeg's source association includes Cerbero's `recipes/ffmpeg/0001-Add-Meson-build.patch`
and `fix-textrels.patch`; recipes may select conditional patches/options.
The collector does not apply those patches or execute recipes, and a pristine
source notice superset is not the final patched-source attribution audit.

## FFmpeg options, codec claims and patents

The current prelinked object contains the string
`libavcodec license: LGPL version 2.1 or later`. Its embedded configuration
uses **Meson**, not FFmpeg's configure script: `nonfree=disabled`,
`version3=disabled`, selected filters only, hardware acceleration/network/
protocols disabled. The recipe and Meson-port patch default `gpl=disabled`;
there is no embedded explicit `gpl` override. Therefore absence of the text
`--enable-gpl` is not by itself a meaningful Meson-build licence test.
The embedded iOS header says `FFMPEG_VERSION "03d8bbd"`, not literally `7.1`;
the build's FFmpeg directory name and library versions are compatible with
7.1, but the short version marker needs producer-side explanation.

H.264/AAC, VP8/VP9, MPEG and other FFmpeg decoder objects are present in the
trial map; this is not a runtime enumeration of enabled codecs or their ranks.
The libav plugin and registration of native codecs do not restrict the binary
to the formats that Hollow Knight was seen to use. A final audit needs generated
FFmpeg `config.h`/Meson options, codec/parser/demuxer/filter lists, patch set,
linked-member attribution and their source-to-binary association.

**Additional confirmed notice need:** the trial map contains `jfdctfst.c.o`,
`jfdctint.c.o` and `jrevdct.c.o`. FFmpeg `LICENSE.md` calls out IJG requirements,
and the whole source files preserve those bytes. The binary-accompanying
credit must state **“This software is based in part on the work of the
Independent JPEG Group.”** Review and document changes/additions/deletions
relative to the IJG originals as required; copying the LGPL text is not enough.
This is independently relevant to GStreamer, even if another Wine component
already needs the same credit. Full copied source files are selected attribution
inputs, not proof all FFmpeg headers/embedded third-party notices are covered.

Copyright licence selection and patent questions are distinct. LGPL FFmpeg
and lack of x264/x265 do not waive patents on H.264/AAC/MPEG or other enabled
formats, nor does using system VideoToolbox automatically clear software,
channel, territory or business-model obligations. libvpx `PATENTS` and Opus's
licensing statements must be retained and reviewed for their actual scope;
they are not a general no-patents guarantee. Exact enabled capabilities,
territories/channel and relevant grants/claims need qualified review. This
worker makes no patent, licence-compatibility or distribution-clearance assertion.

## Rust and MoltenVK: exact missing inputs

Public `gst-plugins-rs` tag `gstreamer-1.28.7` resolves to
`e9229628528b19e9b42e52620be4e79a2e054363`
(tag object `9405ecb8468c3cb703589931fe7e06414939815c`). Its public Cargo.lock
hash is `4a29a7b318658cd42c4847dc7c91c4f01159e3afdcdb56132ef0c58df61832ce`.
It declares candidate gst-plugin-aws `0.15.3`, object `0.37.3`, gimli `0.32.3`,
addr2line `0.25.1`, rustc-demangle `0.1.28`. These declarations **must not**
be substituted for proof of which versions are inside the binary; some mapped
members may instead be the compiler's stdlib dependencies.

The prelinked object's Rust source-path strings contain commit
`ac68faa20c58cbccd01ee7208bf3b6e93a7d7f96`; the public Rust `1.96.0` channel
manifest associates that commit with 1.96.0, matching Cerbero's bootstrap.
This is useful corroboration, not verified embedded library derivation. No Rust
binary archive/toolchain was downloaded. Still missing: exact producer compiler/
stdlib archive checksums, source association, Cargo graph and archive checksums
for the Rust members that survived prelinking, and their complete notices.

MoltenVK's custom recipe copies from `config.moltenvk_prefix`, rather than
naming a source tarball/checksum. Recipe version `1.3.283.0` alone cannot supply
an exact MoltenVK commit or embedded dependencies. Obtain the producer's SDK
manifest, payload checksum and source/notice mapping. No SDK download was made.

## Standalone preparation and fail-closed behaviour

[`build/notices-gstreamer.py`](../../build/notices-gstreamer.py) is intentionally
usable standalone and **now connected to `pp notices` as a preparatory superset**.
It performs no fetch, compilation, extraction
to source paths, recipe execution or shared-input write. Prepare privately:

```sh
python3 build/notices-gstreamer.py \
  .work/gstreamer-review/cerbero.tar.gz \
  .work/gstreamer-review/sources \
  .work/gstreamer-review/notices
# Explicit partial selection is possible, never labelled complete:
# append --component ffmpeg (output must be a new directory).
```

The lock must equal committed bytes; stage digest/release pin/checksum must
match the review. Cerbero archive/checksums, reviewed recipe/config hashes,
literal tarball checksums and non-inherited versions are verified without
executing code. Default requires every one of the 17 locked source archives;
explicit subsets list omitted components. Rust/MoltenVK/build-derivation gaps
remain explicit even when all 17 succeed.

Output stays under this worktree's `.work`, away from input trees. Filesystem
symlinks, corrupt/missing archives, unsafe/control-character/wrong-root/duplicate
members, file-directory collisions, hardlinks and special files fail. Archive
symlinks may resolve only internally, in one hop, to an exact regular member;
GLib's two COPYING aliases are recorded with the target member/hash. No filesystem
link is followed. Required notices and recursive notice/authors/patents candidates
plus every `LICENSES/` file are copied byte for byte into component-separated
paths. Candidates include some source/data/test/tool files; this is not a
claim every payload is a licence or applies to the executable.

`gstreamer-source-inventory.json` records source file hashes/sizes, alias
origins, notice payloads and exact resolved archive members. Before same-filesystem
no-clobber publication, all payload bytes and coverage are rechecked. Failure
removes temporary output and preserves pre-existing/racing destinations.
This is not Corresponding Source packaging or a complete legal-notice inventory.

## Checks and integration

- 15 targeted fixture tests: byte preservation/path-independent origins,
  missing/corrupt inputs, committed-lock/stage/pin/recipe/config refusals,
  mandatory/non-candidate/`LICENSES` coverage, unsafe/duplicate/wrong-root/
  special/colliding members, GLib-style aliases, external/dangling/chained/
  hardlink rejection, filesystem links, partial subsets, output boundaries,
  write/manifest failure rollback, racing/existing destinations and CLI cleanup.
- Full source smoke: **17 components, 22,415 regular source files, 66 copied
  notice/attribution-candidate payloads**; inputs unchanged. The initial Xiph
  downloads returned non-archive responses despite successful HTTP status;
  their recipe checksum mismatch was detected, and verified public mirror
  archives were used instead. No unchecked response was admitted to collection.
- Before the task commit, the pending lock was committed only in the isolated
  `.work/gstreamer-review/smoke-repo` fixture for the committed-byte check;
  the smoke is source preparation, never a release build. Repeat with the task
  commit's real lock for integration. Logs/output remain private in `.work`.
- Python syntax, shell syntax of the unchanged stage and `git diff --check`
  passed. Plain `./pp test --quick` passed name/secret/patch and available C
  gates, but four existing NetmuxdRestartTest socket fixtures failed because
  this deeply nested worktree exceeds AF_UNIX's pathname limit. A global short
  scratch alias fixed those four but exposed an unrelated BuildAreaTest
  realpath-versus-alias assertion; it was not used as a successful check.
- `./pp test --quick` then passed **256 Python tests**, name/secret/patch gates
  and available host C tests with an uncommitted scratch-only `sitecustomize`
  adapter shortening **only NetmuxdRestartTest temporary directory strings**
  through a live directory-descriptor alias to this worktree's `.work`.
  Fixture contents, tests/assertions and production files were not modified;
  all physical scratch writes remained in this worktree. Adapter and logs are
  private in `.work/gstreamer-review/test-adapter` and
  `.work/gstreamer-review/quick-tests-adapted.log`. Plain deep-path invocation
  remains an infrastructure limitation, not an unexplained passing suite.
  Swift was omitted; gamepad C/ThreadSanitizer tests were skipped for the
  unpopulated Madeira submodule. No checkout was performed solely for them.

### Host-only assembly integration

`pp notices` now requires the complete 17-component preparatory set. Supply
`GST_NOTICE_CERBERO` and `GST_NOTICE_SOURCES`, or populate the documented
`$PLAYPORT_BUILD/cache/gstreamer-notices/` defaults. `--assemble` copies into an
existing assembly directory; `--verify-assembly` regenerates the exact manifest
and candidate bytes from the committed lock and reverified archives. Partial
`--component` selections remain standalone-only. Inputs are read only; disposable
preparation stays under this worktree's `.work/tmp`.

The assembler copies flat `gstreamer-source-*` payloads and preserves the full
standalone manifest as `gstreamer-provenance.json`, including GLib alias origins.
Flattened collisions and pre-existing/racing payloads fail without overwriting;
write failures remove only files created by the collector. Final inventory
publication calls complete source/manifest/payload revalidation. A required
collection entry in the tree gate prevents silently omitting the whole set.

Added 14 regressions; full unmodified host tests passed (352 Python tests plus
available C and Swift suites). Cached-source assembly smoke preserved all 66
payloads across 17 components and passed the actual inventory hook and checksums.
Private output/logs are `.work/gstreamer-assembly-smoke`,
`.work/gstreamer-assembly-smoke.log` and `.work/gstreamer-assembly-full-tests.log`.
No full branch notice collection, app build, device run or publication occurred.

Do not tick the broad GStreamer notice gate: obtain producer-side Cerbero
commit/configuration/CI manifest and patched-source association for the exact
binary; resolve Rust/MoltenVK sources and notices; finish file/header/credit
applicability; associate clean prelink/final-link evidence with an exact IPA;
then finish complete validated release notice inputs and app staging, and test
source/relinking separately. None of those blockers is cleared by this smoke.
