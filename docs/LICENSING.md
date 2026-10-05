# Licensing

This page records what licences apply to Playport and to what it builds, and
what has to happen before an IPA is given to anyone. It is a working record
by the copyright holder, not legal advice; the assembled application must be
reviewed before any public release.

## Paid distribution and closed source

The reviewed open-source licences permit charging for IPAs, support and early
access, and accepting donations. Payment does not waive source, notice or
relinking duties, and Apple/channel terms need separate review. Recipients of
a GPL build retain the right to modify and redistribute it; a private source
repository is possible, but withholding required source from recipients is not.

**The current combination cannot be distributed as a closed-source application
merely by changing Playport's own licence.** Madeira's GPL host and port code
is a separate blocker. Keeping Playport-authored source proprietary might be
possible after securing alternative rights or replacing/separating the GPL
parts, while still supplying LGPL/MPL source and usable relinking materials.
Nothing here grants such permissions.

The current preparation target is **open-source publication, then a free IPA
with optional support**, not proprietary relicensing. The two publication gates
are tracked in [plans/open-source-release.md](plans/open-source-release.md);
[RELEASE-HOSTING.md](RELEASE-HOSTING.md) describes the chosen flow: free IPAs
on GitHub Releases and donations on Ko-fi or Patreon (decision 0037).
Recipients may mirror their GPL copies anywhere.

## Playport's own licence

Playport is licensed under the **GNU General Public License, version 3 or (at
your option) any later version** (`LICENSE`). Its copyright holders are
the Playport authors.

### The converter exception

On 2026-09-24 the copyright holder adopted the text of the Madeira Converter
Exception, version 1, for Playport's own code (`LICENSE-EXCEPTION.md`; the
reasoning is in [decision 0006](decisions/0006-licence.md)). In summary:

- it is an additional permission under GPL-3.0 section 7: a work that links
  or combines Playport with Apple's Metal Shader Converter library
  (`libmetalirconverter.dylib`) or with Apple's system frameworks (Metal,
  Foundation, CoreGraphics, QuartzCore, UIKit, AppKit and related) may be
  conveyed, and its Corresponding Source need not include the source of those
  Apple libraries;
- it does not extend to the Apple libraries, which stay under Apple's terms,
  and anyone conveying Playport may remove it from their copies;
- it covers only code whose copyright Playport's holder owns: `app/`,
  `build/`, `tools/` and `pp` (except third-party material in them) and
  Playport's own lines in `patches/madeira-unix`, `patches/madeira-winios`,
  `patches/fex`, `patches/rpmalloc` and `patches/dxmt`;
- it does not cover or change Madeira or its forks (Madeira adopted the same
  text for its own code), Wine, third-party material Playport uses, or the
  Apple libraries.

Playport does not build or ship the converter today. The permission keeps
that option open without needing every later contributor's consent, which
adding it later would require. Contributions to Playport are accepted under
GPL-3.0-or-later with this permission.

### Marking

Playport's own source files carry `SPDX-License-Identifier:
GPL-3.0-or-later` in their first lines. A file without that header is
upstream or third-party material and keeps its own licence, or is data
(fixtures, generated manifests, checksum lists). The Markdown documents need
no header.

### Pushing

Distribution begins with the first push to a public remote, not with a
release. Before any public push, `LICENSE-EXCEPTION.md` must be adopted (its
`Adopted on:` line carries a date) and every pushed commit must pass the name
gate (`pp names`, part of `pp test`). CI checks both
(`.github/workflows/checks.yml`); nothing refuses the push itself
([decision 0025](decisions/0025-no-git-hooks.md)).

### Other projects

Taking inspiration from other projects' user interfaces is fine. Porting
their code, or copying their strings, icons or other assets, is not: it
brings their licence terms and attribution duties into Playport. Design;
do not port.

Before offering a patch upstream, read that upstream's contribution policy
(FEX-Emu does not accept AI-generated contributions). Such policies govern
contributions, not the right to use or distribute the code under its licence.

## Components

| Component | Where it ends up | Licence |
| --- | --- | --- |
| Playport (app, HostIOKit, SteamClientKit, build and tooling code) | executable | GPL-3.0-or-later with the converter exception |
| Madeira host layer: `build/ntdll-unix`, `build/wineserver`, `build/win32u-unix`, `madeira_cfg.h`, Winios, `IOSDisplayShim` | executable | GPL-3.0-or-later with Madeira's own converter exception; many `build/*-unix` files carry Wine's LGPL header, and some carry none (see "Open items") |
| Wine: WineHQ plus Madeira's fork (`patches/wine-port`, decision 0013) | executable (unix side), both PE DLL sets, `nls/` | LGPL-2.1-or-later (`COPYING.LIB`, `LICENSE`, `LICENSE-MADEIRA.md`; `NOTICES.md` records current third-party notices) |
| Valve's Wine: the commits of ValveSoftware/wine `proton_11.0` (the Wine Proton ships) that Playport carries as `patches/wine-valve` (decision 0018) | both PE DLL sets, and the Wine headers the unix side compiles against | LGPL-2.1-or-later, as upstream Wine; each commit keeps its author, and notices are collected from the actual patched Wine tree |
| Libraries bundled into the Wine PE DLLs: compiler-rt, musl, tomcrypt, zlib, libpng, libjpeg, libtiff, vkd3d, FAudio, OpenLDAP, Mozilla-derived `regexp.c` | Wine PE DLLs | NCSA or MIT, MIT, public domain/WTFPL, zlib, PNG v2, IJG, libtiff, LGPL-2.1-or-later, zlib, OpenLDAP 2.8, LGPL-2.1-or-later |
| FEX: FEX-Emu/FEX plus Madeira's port (`patches/fex-port`, decision 0008) | `xtajit64.dll` | MIT upstream; Madeira's changes GPL-3.0-or-later with its exception |
| Inside `xtajit64.dll`: rpmalloc (FEX-Emu/rpmalloc plus Madeira's changes, `patches/rpmalloc-port`), fmt, xxHash, Cephes, SoftFloat 3e, tiny-json, cpp-optparse, unordered_dense | `xtajit64.dll` | rpmalloc 0BSD upstream plus Madeira's GPL changes; MIT, BSD-2-Clause, BSD, BSD-3-Clause, MIT, MIT, MIT |
| DXMT: 3Shain/dxmt plus Madeira's port (`patches/dxmt-port`) | executable (unix slice), DXMT PE DLLs | LGPL-2.1-or-later upstream (`LICENSE`, `COPYING.LIB`; upstream relicensed from MIT, kept as `LICENSE.OLD`, after v0.80); Madeira's changes GPL-3.0-or-later with its exception |
| DXBCParser (in DXMT) | executable, DXMT PE DLLs | MIT, per its file headers |
| mingw-directx-headers (compiled into the DXMT slice) | executable | LGPL-2.1-or-later headers |
| GnuTLS 3.8.9 | executable, statically | LGPL-2.1-or-later |
| Nettle/Hogweed 3.10.1, GMP 6.3.0 | executable, statically | LGPL-3.0-or-later or GPL-2.0-or-later |
| FreeType 2.14.3 | executable (in `libwin32u_unix.a`) | FreeType License (FTL) or GPL-2.0-or-later |
| mingw-w64 `57b595039040eaa15bece85b7cc71d952281b269` (llvm-mingw 20260922's CRT/headers; aarch64 CRT rebuilt with arm64ec support) | compiled into PE binaries where runtime code/header definitions are used | ZPL-2.1 baseline with file-specific permissive/LGPL and other terms; runtime/source notice superset collected, not a linked-code audit ([NOTICES.md](NOTICES.md#mingw-w64-source-and-installed-notices)) |
| LLVM 15.0.7 libraries (for airconv) | executable (in `libdxmt_combined.a`) | Apache-2.0 WITH LLVM-exception, plus the legacy LLVM licence; the link keeps Henry Spencer's regex and Unicode's `ConvertUTF`, which carry their own notices |
| KosmicKrisp: Mesa plus `patches/mesa` (decisions 0014, 0015) | `KosmicKrisp.framework` | MIT for most files, each file per its SPDX header (Mesa `docs/license.rst`); Playport's patches keep that licence |
| DXVK `52fe923` (with libdisplay-info and dxbc-spirv), unmodified | `Runtime/vulkan/` DLLs (d3d8, d3d9, d3d10core, d3d11, dxgi) | zlib/libpng; MIT, MIT |
| Khronos Vulkan/SPIR-V headers in DXVK/vkd3d-proton and their shader converters (seven separately pinned gitlinks) | compiled header definitions in the Vulkan PE backend | Vulkan headers: Apache-2.0 OR MIT per file; SPIR-V headers: MIT-style terms with normative-header warning; documentation/tool texts in the collected superset have separate terms; per-file applicability review remains open ([NOTICES.md](NOTICES.md#khronos-header-notices-in-the-pe-backend)) |
| vkd3d-proton `472989a` (with dxil-spirv), with `patches/vkd3d-proton` | `Runtime/vulkan/` DLLs (d3d12, d3d12core) | LGPL-2.1-or-later; dxil-spirv MIT, with MIT and BSD-3-Clause third-party files |
| gbe_fork (Detanup01/gbe_fork) `7103add` (tag `release-2026_09_27`) plus `patches/gbe` (two build fixes and the MSVC way of returning interface structs), its regular `steam_api` build | `Runtime/steamapi/` DLLs (`steam_api64.dll`, `steam_api.dll`), copied into a game's folder at launch in place of the game's own | LGPL-3.0; see "Steam API emulator" below |
| Linked statically into those DLLs: curl, libssq, Mbed TLS, Opus, PortAudio, Protocol Buffers with utf8_range and Abseil (the pins.lock `abseil-cpp` tag), SDL 3, zlib, and the header libraries in gbe_fork's `libs/` (nlohmann json and fifo_map, SimpleIni, stb, utfcpp, libgamepad, sha1) | `Runtime/steamapi/` DLLs | curl's MIT-style licence, MIT, Apache-2.0 (Mbed TLS's other option is GPL-2.0-or-later), BSD-3-Clause, MIT, BSD-3-Clause and MIT, Apache-2.0, zlib, zlib; MIT, MIT, MIT, MIT or public domain, BSL-1.0, MIT, public domain |
| GStreamer 1.28.7, GStreamer's own iOS binary release (the pins.lock `gstreamer` version, sha256 in `build/stages/gstreamer.sh`; built by GStreamer's Cerbero from the `1.28.7` tag of <https://gitlab.freedesktop.org/gstreamer/gstreamer>): core, base, good and bad plugin libraries and the plugins `build/stages/gstreamer.sh` registers | executable (in `libwinegstreamer_unix.a`, statically), with Wine's winegstreamer unix side | LGPL-2.1-or-later; see "GStreamer" below for the libraries it carries |
| JavaSteam protocol schemas (field tables in `app/SteamClient`) | executable | MIT; pinned by commit `433f2ad15c36d5e690a4fe77401ec3f6b960641e` in the [joshuatam/JavaSteam](https://github.com/joshuatam/JavaSteam) fork of [Longi94/JavaSteam](https://github.com/Longi94/JavaSteam) |
| StikJIT 1.9.0 framework (the prebuilt `StikJIT.xcframework` release asset; tag `1.9.0`, commit `32287268fa5824f9edce4cb359f5833ce0cf7b00`, source at <https://github.com/StikDebug/StikJIT>) | the JIT helper extension (`PlugIns/PlayportJIT.appex/Frameworks/StikJIT.framework`), unmodified | MPL-2.0; see "StikJIT" below for what it carries inside |
| idevice (jkcoxson/idevice) at the `pins.lock` `idevice` commit plus `patches/idevice` (Bonjour advertising for on-device pairing), its C FFI with the features the restart after a game and pairing use (decisions 0029, 0033), built by `build/stages/idevice.sh` with the `pins.lock` Rust | executable (in `libidevice_ffi.a`, one prelinked object) | MIT; see "idevice in the executable" below for the crates it carries |
| Playport's patches to Wine (`patches/wine-pe`, `patches/wine-unix`) | Wine trees | offered under LGPL-2.1-or-later, so the Wine tree stays LGPL |
| Playport's patches to vkd3d-proton, gbe_fork and idevice (`patches/vkd3d-proton`, `patches/gbe`, `patches/idevice`) | those trees | offered under each upstream's licence: LGPL-2.1-or-later, LGPL-3.0, MIT ([decision 0040](decisions/0040-patch-series-under-upstream-licences.md)) |
| Playport's patches to Madeira, FEX and DXMT | those trees | the patched code keeps its licence; Playport's lines are GPL-3.0-or-later with the exception |

Apple's frameworks and the Swift runtime are system libraries on the device,
not bundle contents. The build tools (llvm-mingw, xtool, Apple ld64, the
Apple SDK) are not redistributed, but llvm-mingw's mingw-w64 CRT and headers
are compiled into the PE files Playport builds (see "Open items").

The combination is conveyed under GPL-3.0-or-later as a whole: every
component licence above is compatible with that, and the LGPL relinking
duties for the statically linked LGPL code still apply.

### StikJIT

The JIT helper extension embeds StikJIT's prebuilt framework
(`build/stages/stikjit.sh`, docs/ARCHITECTURE.md "Built-in JIT").

- **MPL-2.0** is file-level copyleft and names the GPL family as Secondary
  Licenses (MPL-2.0 section 3.3), so shipping the unmodified framework inside
  a GPL-3.0-or-later app is permitted. The duties: ship the MPL text with the
  binary (`StikJIT-LICENSE.txt`, docs/NOTICES.md), say where its source is
  (the row above identifies the reviewed release tag/commit association, not
  independently verified binary build derivation), and
  make the exact MPL-covered source, including changes to covered files,
  available to recipients under MPL. Unmodified binaries also have this duty;
  it does not require a public development repository.
- **No MPL file is changed.** The framework binary is copied byte for byte
  (its sha256 is pinned in `build/stages/stikjit.sh`). The staging adds an
  `Info.plist` the release lacks and rewrites module-qualified names in the
  generated `.swiftinterface` so the Linux Swift compiler can read it; the
  interface is a compiler input that is not shipped as source, and the
  rewrite is the published sed in `build/stages/stikjit.sh`, so it is public in
  any case.
- **What the framework carries that is not MPL.** StikJIT's README says the
  bundled idevice (in the binary) and the `universal.js` and `legacy.js`
  scripts (framework resources) keep their own licences.
  - The scripts are removed from the staged framework (`build/stages/stikjit.sh`
    deletes them; they are resources, not code) and are not shipped. The
    helper runs Playport's own GPL-3.0-or-later script instead,
    `app/PlayportJIT/playport-universal.js`, written from Playport's former
    workstation activation tool (removed by decision 0011; in the git
    history) and StikJIT's documented protocol.
  - The embedded idevice library also carries Rust/native dependencies.
    The committed archive contains AWS-LC, stdlib and other crate candidates;
    archive presence and embedded strings do not establish final linked members
    or exact source versions. The [StikJIT audit](release-audits/stikjit-rust.md)
    found no verified embedded idevice revision, Cargo lock or build derivation.
    `idevice-LICENSE.txt` is copied from Playport's pinned idevice source
    (`d32c8189c51c2789496b0768039419c3705498c3`). Its bytes are verified for
    that donor source only. idevice and its crates are MIT/Apache-2.0: their
    notices are owed, not their source ([decision 0042](decisions/0042-the-source-bundle-is-complete.md)).
- The StikDebug app itself (AGPL-3.0) is not bundled: Built-in JIT does not
  need it. The helper's launcher and XPC code are Playport's own
  (`app/Sources/S1Probe/BuiltInJit.swift`, `app/Sources/PlayportJIT`),
  written from StikJIT's integration guide; no other project's code is copied.

### idevice in the executable

`build/stages/idevice.sh` builds idevice's C FFI from the pinned commit and
prelinks it, with the Rust standard library and every crate it links, into one
object in the executable. The stage writes `crates.tsv` beside the object
(149 entries at the pin: the normal dependencies resolved for iOS with the
stage's features). This is not a complete build/proc-macro/native dependency
or linked-member inventory. Package metadata declares these licence options;
it does not establish all copied-file terms or complete attribution:

- MIT, Apache-2.0, or a choice between them, for most crates.
- BSD-3-Clause for the dalek curve crates (`curve25519-dalek`,
  `ed25519-dalek`, `x25519-dalek`) and `subtle`; ISC for `rustls-webpki` and
  `untrusted`.
- `ring` (TLS): Apache-2.0 and ISC.
- `unicode-ident`: Unicode-3.0 in addition to MIT or Apache-2.0.
- A few crates offer MIT among other options (Unlicense, BSD-2-Clause,
  BSD-3-Clause or ISC).
- The Rust standard library (`core`, `alloc`, `std` and their dependencies):
  MIT or Apache-2.0.

`build/notices-assemble.sh` collects recursive notice candidates and direct
`license-file` payloads from checksum-locked archives, as an incomplete superset
(docs/NOTICES.md). Generic licence texts do not replace missing copyright and
permission notices. `ns-keyed-archive`, `plist-macro` and `plist_ffi` carry
notices Playport writes from their Cargo metadata ([decision 0039](decisions/0039-owners-licensing-review.md));
that does not settle the rest: `plist-macro` credits a serde JSON macro port without an
exact source revision, and `plist_ffi` contains original LGPL-2.1-or-later
libplist headers/C++ material despite its package-level MIT declaration.
Those originals and the LGPL block in StikJIT's generated header retain their
terms. The focused attribution catalog now collects 103 whole locked-source
files, preserving the original author/port credits, README licence distinctions
and libplist headers as an evidence superset. It does not invent missing grants,
resolve serde's original revision or cover StikJIT's unverified embedded build;
actual compiled/linked applicability, complete notices and adequate rights remain
unresolved ([audit](release-audits/stikjit-rust.md)). No crate is patched, but
unmodified use does not waive these duties.


### GStreamer

`build/stages/gstreamer.sh` prelinks winegstreamer with the members reached
from `libGStreamer.a` and 20 registered plugins. The
[GStreamer/Cerbero audit](release-audits/gstreamer.md) distinguishes an existing
**trial** prelink map and shared-run observations from exact-IPA linkage.
Registrations can reach encoders, sources/sinks and GL/Vulkan helpers too;
observed game playback does not constrain all shipped capabilities.

- LGPL-family sources include GStreamer, GLib/GObject/GIO/GModule,
  proxy-libintl and FFmpeg. The observed FFmpeg string says LGPL 2.1-or-later;
  its build uses Meson, so absence of `--enable-gpl` is not a licence test.
  Recipe defaults disable GPL/nonfree/version3 options, and the trial map has
  no x264/x265 member families. Exact producer options/patches and final linked
  members remain unverified; the FFmpeg version marker also needs explanation.
- Permissive source notices include libvpx, Opus, libvorbis/libogg, PCRE2,
  libffi, zlib and bzip2. ORC's whole notice contains both BSD-2-Clause and
  BSD-3-Clause attribution. FFmpeg's mapped IJG-derived files independently
  require the Independent JPEG Group credit listed in [NOTICES.md](NOTICES.md).
- Rust/stdlib/demangler and MoltenVK member candidates also appear. Cerbero's
  Rust 1.96.0 bootstrap and Vulkan SDK version are not verified embedded source
  identities; Playport's separate Rust 1.98.1 inventory does not cover them.

`build/notices-gstreamer.py` preserves a checksum-verified notice superset for
17 recipe-associated source archives, included in `pp notices`, and `pp source`
packs those archives with Cerbero 1.28.7. MoltenVK's Apache-2.0 licence (v1.2.9)
is carried; the Rust parts are MIT/Apache-2.0. Their notices are owed, not their
source, and no proof of binary derivation is required
([decision 0042](decisions/0042-the-source-bundle-is-complete.md)). Copyright
licence compliance, enabled-codec patents and channel/territory review are
separate; no patent or public-distribution clearance is asserted. The owner
accepts the codec patent risk of FFmpeg's H.264, AAC and MPEG decoders ([decision 0041](decisions/0041-codecs-supersets-and-relinking.md)).

### Steam API emulator

`build/stages/steamapi.sh` builds gbe_fork's regular `steam_api` for x86-64
and i386 from its pin with `patches/gbe`. The app copies it into a game's
folder at launch in place of the game's own `steam_api(64).dll`, which it keeps
beside it (docs/plans/2026-09-27-steam-for-games.md).

- **LGPL-3.0** (gbe_fork's `LICENSE`; the repository names no "or later").
  Conveying it inside a GPL-3.0-or-later app is permitted: LGPL-3.0 is GPL-3.0
  with extra permissions. It is a separate DLL, so the Corresponding Source
  of gbe_fork and its dependency archives goes with every IPA
  ([DISTRIBUTION.md](DISTRIBUTION.md)), and a recipient replaces it by
  rebuilding the stage.
- **The dependencies** it links statically are all permissive, and Apache-2.0
  (Mbed TLS, Abseil) is compatible with (L)GPL-3.0. Their sources are the
  archives on gbe_fork's `third-party/deps/common` branch at the gitlink the
  pin records, and Abseil at its pins.lock tag.
- **Not built:** gbe_fork's overlay (`ingame_overlay`, GPL-3.0; the
  `api_experimental` and `steamclient` builds) and Microsoft Detours.
- **Build tools from gbe_fork's tree:** premake5 (its `third-party/common/linux`
  branch) runs at build time and is not shipped.
- **No Steam code or Steam SDK binary** is shipped. gbe_fork's `sdk/` headers
  are compiled in; their provenance is gbe_fork's.

### Not built and not shipped

- Apple's `libmetalirconverter.dylib`, which Madeira's tree carries: never
  copied, built against or shipped.
- Madeira's native D3D12 runtime (`madeira_d3d12.dll`) and its test programs:
  `build/stages/stage-artifacts.py` takes only names from the Wine PE manifests. The
  one winemetal unix slot that would reach the converter
  (`madeira_ir_convert`) is a Playport stub that refuses
  (`app/Sources/WineHost/d3d12_converter_absent.c`). Adopting that path would
  first need Apple's converter agreement read.
- DXMT's `nvapi` (built with `enable_nvapi=false`), Wine bundles that no
  shipped DLL links (fluidsynth, mpg123, lcms2, xml2/xslt, jxr, gsm,
  capstone), and Madeira's title scaffolding and deploy scripts.

## Obligations when an IPA is given to anyone

They apply from the first copy that leaves the workstation, even to one
tester. The procedure is [DISTRIBUTION.md](DISTRIBUTION.md).

1. **Corresponding Source** for that exact build (GPL-3.0 sections 1 and 6),
   provided as an exact source bundle next to the IPA under this project's
   distribution procedure, not merely a generic upstream link: this repository
   at the build's commit
   (patches, build scripts, the AIR helper port), source archives of the
   Madeira, wine, FEX (with rpmalloc and its other submodules) and DXMT
   commits, the Mesa, DXVK and vkd3d-proton commits (with their submodules),
   the gbe_fork commit with its `third-party/deps/common` archives and the
   Abseil tag,
   FreeType `VER-2-14-3`, LLVM 15.0.7, the crypto tarballs with their
   checksums, and GStreamer 1.28.7 with the Cerbero recipes and library
   sources its iOS release was built from, and the idevice source with its
   linked Rust dependencies. For online downloads, GPL-3.0 section 6(d) requires
   equivalent source access at no further charge, with clear directions beside
   the IPA. It permits a different server (including a third party's), but we
   remain responsible for exactness, completeness and availability. The
   written-offer route in section 6(b) concerns physical-product distribution
   and is not a general substitute for section 6(d).
2. **LGPL relinking.** GnuTLS, Nettle/Hogweed, GMP, Wine's unix side,
   DXMT's unix slice and GStreamer with the LGPL libraries it carries
   (GLib, FFmpeg) are linked statically. Because the whole app's source is provided, a recipient
   can rebuild and relink with a modified library. The chosen route is a rebuild
   from Corresponding Source, not mandatory per-component relink trials
   (decision 0041) from the public repository at the release's tag, whose sources
   the bundle also holds ([DISTRIBUTION.md](DISTRIBUTION.md), decision 0042).
3. **Installation Information** (GPL-3.0 section 6, LGPL-3.0 section 4(e)).
   An iPhone is a User Product, but applicability also depends on section 6's
   transaction conditions; that fact alone does not settle the duty for a
   software-only sale. Our procedure supplies instructions to build, sign
   with the recipient's own Apple ID, install and activate JIT in any case.
   Review both applicability and sufficiency for the actual delivery method.
   Apple-controlled signing is neither an automatic waiver nor proof that
   instructions alone suffice.
4. **Complete notices**, in the app and next to the source
   ([NOTICES.md](NOTICES.md)). Madeira's own third-party notices are a
   starting point but not complete for this build. Settings › About › Licences
   displays the selected, owner-reviewed notice bundle; collection limitations
   and separate release gates remain.
5. **No further restrictions** on the recipient. Whether a given delivery
   channel's terms add restrictions is part of choosing the channel.

## Open items

- Wine's bundled-library row predates the current pin's complete library set
  (including its replacement of `tomcrypt`). Review actual linked members and
  compiled headers against the recursively collected notice inventory; that
  row is not a completed release audit.
- mingw-w64's exact source revision and release-script association are recorded
  in `build/mingw-notices.lock.json`; runtime/source notice collection and installed
  notice-byte comparisons are implemented. Audit actual CRT/compiled header/linked
  members across the PE binaries and the local arm64ec CRT rebuild. The
  [LLVM runtime collector](release-audits/llvm-runtime-collection.md)
  preserves exact-source libc++/libc++abi/libunwind/compiler-rt and resource-header
  credit supersets, now included in a separately verified `pp notices` directory.
  Complete applicability/attribution and binary derivation remain open. `COPYING.MinGW-w64-runtime.txt`'s upstream
  Cephes FIXME: only libmingwex's `lgamma`, `lgammaf`, `lgammal`, `coshl`, `sinhl`,
  `tanhl` and `hypotl` can reach a UCRT link, and Moshier's grants ("may be used
  freely"; "BSD license is fine, modification is OK") are carried in FEX's
  `cephes-LICENSE.txt`, which the app now lists for mingw-w64 too; the owner
  accepted that reading ([audit](release-audits/mingw-cephes.md), [decision 0039](decisions/0039-owners-licensing-review.md)). Tool/profile licence texts in the
  collected superset do not establish that those tools/profile objects are shipped.
- Khronos header root notices and `LICENSES/` texts from DXVK/vkd3d-proton's
  seven header checkouts (including nested converter copies) are collected with
  committed-byte origins. Mesa's scoped Vulkan/video and top-level SPIR-V headers
  are also collected whole with file/blob/range origins, preserving their credits
  as a superset. Review per-file/compiled-header applicability, Mesa's generated
  registry/grammar and other source credits, and additional shader-converter
  notices; neither superset is a claim of executable linkage.
- FreeType: taken under FTL, with its credit line ([decision 0039](decisions/0039-owners-licensing-review.md)).
- OpenLDAP 2.8: taken as GPL-compatible, as the FSF lists the OpenLDAP licence ([decision 0041](decisions/0041-codecs-supersets-and-relinking.md)).
- DXBCParser: its files say "Copyright (c) Microsoft Corporation. Licensed under the MIT
  License" with no year, and no licence text is in DXMT's tree. They come from
  microsoft/D3D12TranslationLayer (BlobContainer and DXBCUtils almost unchanged,
  ShaderBinary modified) and microsoft/DirectX-Headers (the tokenized-format header),
  whose LICENSE texts are identical. That text is committed byte for byte in
  `build/notices-extra/` with its commit and sha256, and collected as
  `DXBCParser-LICENSE-Microsoft.txt`. Resolved as a notice; no year exists upstream.
- DXMT's upstream is LGPL-2.1-or-later since the move to upstream DXMT
  ([decision 0007](decisions/0007-dxmt-on-upstream.md)). Madeira's
  `LICENSE-MADEIRA.md` in the DXMT tree still calls the upstream licence MIT;
  it is Madeira's file and is left as it is. Whether the LGPL DXMT code
  changes anything for a future converter combination is open (LGPL code
  does not carry Playport's or Madeira's converter exception).
- Madeira's `build/*-unix` files without a licence header: Madeira's
  documents disagree on whether they are LGPL or GPL-3.0; either reading
  allows Playport to convey the app under GPL-3.0-or-later. Playport takes the
  stricter reading, GPL-3.0-or-later, and sends no request ([decision 0039](decisions/0039-owners-licensing-review.md)).
- Ownership confirmation of the downstream wine commits is recorded as
  pending in Madeira's provenance document. Both Madeira questions, with the
  36 headerless files and a request text for its author, are in the
  [ownership audit](release-audits/ownership.md#madeiras-two-questions-host-only-2026-09-30).
- Apple's terms: the Xcode and SDK agreement for the SDK used on Linux, the
  Apple ID and developer terms of whatever channel delivers IPAs to testers.
  The owner accepts this risk ([decision 0039](decisions/0039-owners-licensing-review.md)).
- Only the header lines of each Wine bundled library's licence were read; the
  notice files are copied whole.
