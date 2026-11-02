# Licensing

This page records what licences apply to Playport and to what it builds, and
what has to happen before an IPA is given to anyone. It is a working record
by the copyright holder, not legal advice. Each release passes the checks in
[DISTRIBUTION.md](DISTRIBUTION.md) and the owner's sign-off
([decision 0068](decisions/0068-release-owner-signoff.md)) before it is published.

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

Playport is **open source, with free IPAs and optional support**, not
proprietary relicensing. Both publication gates are passed
([finished plans](https://linear.app/playportdev/issue/PLA-695)).
[RELEASE-HOSTING.md](RELEASE-HOSTING.md) describes the flow: free IPAs on GitHub
Releases and donations on Ko-fi or Patreon (decision 0037).
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

Distribution began with the first push to a public remote, not with a
release. Every public push needs `LICENSE-EXCEPTION.md` adopted (its
`Adopted on:` line carries a date) and every pushed commit to pass the name
gate (`pp names`, part of `pp test`). CI checks both
(`.github/workflows/checks.yml`); nothing refuses the push itself
([decision 0025](decisions/0025-no-git-hooks.md)).

### Other projects

Taking inspiration from other projects' user interfaces is fine. Porting
their code, or copying their strings, icons or other assets, is not: it
brings their licence terms and attribution duties into Playport. Design;
do not port. The Xbox client is the one recorded exception: it is written
from Xodus's code and takes Xodus's terms ("Xbox (planned)" below).

Before offering a patch upstream, read that upstream's contribution policy
(FEX-Emu does not accept AI-generated contributions). Such policies govern
contributions, not the right to use or distribute the code under its licence.

## Components

| Component | Where it ends up | Licence |
| --- | --- | --- |
| Playport (app, HostIOKit, SteamClientKit, build and tooling code) | executable | GPL-3.0-or-later with the converter exception |
| XboxClientKit and the Xbox sign-in sheet | dev executable only (0179); absent from release | Xodus-derived files GPL-3.0-only, without the converter exception; Nexus's Xodus patches also retain their MIT notice, CLEP decoding retains CikExtractor's MIT notice (below) |
| Madeira host layer: `build/ntdll-unix`, `build/wineserver`, `build/win32u-unix`, `madeira_cfg.h`, Winios, `IOSDisplayShim` | executable | GPL-3.0-or-later with Madeira's own converter exception; many `build/*-unix` files carry Wine's LGPL header, and some carry none (see "Licence readings") |
| Wine: WineHQ plus Madeira's fork (`patches/wine-port`, decision 0013) | executable (unix side), both PE DLL sets, `nls/` | LGPL-2.1-or-later (`COPYING.LIB`, `LICENSE`, `LICENSE-MADEIRA.md`; `NOTICES.md` records current third-party notices) |
| Valve's Wine: the commits of ValveSoftware/wine's `bleeding-edge` branch (the Wine Proton bleeding-edge ships) that Playport carries as `patches/wine-valve` (decisions 0018, 0049) | both PE DLL sets, and the Wine headers the unix side compiles against | LGPL-2.1-or-later, as upstream Wine; each commit keeps its author, and notices are collected from the actual patched Wine tree |
| Libraries bundled into the Wine PE DLLs: compiler-rt, musl, tomcrypt, zlib, libpng, libjpeg, libtiff, vkd3d, FAudio, OpenLDAP, Mozilla-derived `regexp.c` | Wine PE DLLs | NCSA or MIT, MIT, public domain/WTFPL, zlib, PNG v2, IJG, libtiff, LGPL-2.1-or-later, zlib, OpenLDAP 2.8, LGPL-2.1-or-later |
| FEX: FEX-Emu/FEX plus Madeira's port (`patches/fex-port`, decision 0008) | `xtajit64.dll` (arm64ec) and `xtajit.dll` (FEX's WoW64 CPU for 32-bit games) | MIT upstream; Madeira's changes GPL-3.0-or-later with its exception |
| Inside `xtajit64.dll`: rpmalloc (FEX-Emu/rpmalloc plus Madeira's changes, `patches/rpmalloc-port`), fmt, xxHash, Cephes, SoftFloat 3e, tiny-json, cpp-optparse, unordered_dense | `xtajit64.dll` | rpmalloc 0BSD upstream plus Madeira's GPL changes; MIT, BSD-2-Clause, BSD, BSD-3-Clause, MIT, MIT, MIT |
| DXMT: 3Shain/dxmt plus Madeira's port (`patches/dxmt-port`) | executable (unix slice), DXMT PE DLLs | LGPL-2.1-or-later upstream (`LICENSE`, `COPYING.LIB`; upstream relicensed from MIT, kept as `LICENSE.OLD`, after v0.80); Madeira's changes GPL-3.0-or-later with its exception |
| DXBCParser (in DXMT) | executable, DXMT PE DLLs | MIT, per its file headers |
| mingw-directx-headers (compiled into the DXMT slice) | executable | LGPL-2.1-or-later headers |
| GnuTLS 3.8.9 | executable, statically | LGPL-2.1-or-later |
| Nettle/Hogweed 3.10.1, GMP 6.3.0 | executable, statically | LGPL-3.0-or-later or GPL-2.0-or-later |
| FreeType 2.14.3 | executable (in `libwin32u_unix.a`) | FreeType License (FTL) or GPL-2.0-or-later |
| mingw-w64 `57b595039040eaa15bece85b7cc71d952281b269` (llvm-mingw 20260922's CRT/headers; aarch64 CRT rebuilt with arm64ec support) | compiled into PE binaries where runtime code/header definitions are used | ZPL-2.1 baseline with file-specific permissive/LGPL and other terms; runtime/source notice superset collected, not a linked-code audit ([NOTICES.md](NOTICES.md#mingw-w64-source-and-installed-notices)) |
| LLVM 15.0.7 libraries (for airconv) | executable (in `libdxmt_combined.a`) | Apache-2.0 WITH LLVM-exception, plus the legacy LLVM licence; the link keeps Henry Spencer's regex and Unicode's `ConvertUTF`, which carry their own notices |
| Mesa (KosmicKrisp, Zink, EGL): Mesa plus `patches/mesa` (decisions 0014, 0015; Zink PLA-162) | `KosmicKrisp.framework`, `MesaEGL.framework`, `MesaGallium.framework` | MIT for most files, each file per its SPDX header (Mesa `docs/license.rst`; the OpenGL frontend also SGI-B-2.0 and Khronos notices, in Mesa's `licenses/` and the header superset); Playport's patches keep that licence; no MoltenVK code or header is built in |
| DXVK `52fe923` (with libdisplay-info and dxbc-spirv), with `patches/dxvk` | `Runtime/vulkan/` DLLs (d3d8, d3d9, d3d10core, d3d11, dxgi) | zlib/libpng; MIT, MIT |
| Khronos Vulkan/SPIR-V headers in DXVK/vkd3d-proton and their shader converters (seven separately pinned gitlinks) | compiled header definitions in the Vulkan PE backend | Vulkan headers: Apache-2.0 OR MIT per file; SPIR-V headers: MIT-style terms with normative-header warning; documentation/tool texts in the collected superset have separate terms; per-file applicability review remains open ([NOTICES.md](NOTICES.md#khronos-header-notices-in-the-pe-backend)) |
| Khronos Vulkan-Loader `9e9518d` (tag `v1.4.363`), unmodified, built against Vulkan-Headers `6802bb4` (tag `v1.4.363`) | `Runtime/vulkan-loader/arm64ec-windows/vulkan-1.dll` (decision [0131](decisions/0131-the-khronos-vulkan-loader-for-a-game-whose-layer-must-load.md)) | Apache-2.0; its bundled cJSON MIT; Vulkan-Headers Apache-2.0 OR MIT |
| vkd3d-proton `472989a` (with dxil-spirv), with `patches/vkd3d-proton` | `Runtime/vulkan/` DLLs (d3d12, d3d12core) | LGPL-2.1-or-later; dxil-spirv MIT, with MIT and BSD-3-Clause third-party files |
| gbe_fork (Detanup01/gbe_fork) `7103add` (tag `release-2026_09_27`) plus `patches/gbe` (two build fixes and the MSVC way of returning interface structs), its regular `steam_api` build | `Runtime/steamapi/` DLLs (`steam_api64.dll`, `steam_api.dll`), copied into a game's folder at launch in place of the game's own | LGPL-3.0; see "Steam API emulator" below |
| Linked statically into those DLLs: curl, libssq, Mbed TLS, Opus, PortAudio, Protocol Buffers with utf8_range and Abseil (the pins.lock `abseil-cpp` tag), SDL 3, zlib, and the header libraries in gbe_fork's `libs/` (nlohmann json and fifo_map, SimpleIni, stb, utfcpp, libgamepad, sha1) | `Runtime/steamapi/` DLLs | curl's MIT-style licence, MIT, Apache-2.0 (Mbed TLS's other option is GPL-2.0-or-later), BSD-3-Clause, MIT, BSD-3-Clause and MIT, Apache-2.0, zlib, zlib; MIT, MIT, MIT, MIT or public domain, BSL-1.0, MIT, public domain |
| nexus-xgameruntime (domsvoboda/nexus-xgameruntime) `ab2fac3` plus `patches/xgameruntime` (a build fix: libxml2 and the WinRT JSON header from Playport's Wine tree; then Playport's runtime features, such as the save-conflict question and add-on mounts and catalog queries), built by `build/stages/xbox-pe.sh` | `Runtime/arm64ec-windows/xgameruntime.dll`, an arm64ec Wine builtin | LGPL-2.1-or-later; see "Xbox (planned)" below for the MIT material in it |
| Compiled into `xgameruntime.dll`: libxml2 from the Wine pin's `libs/xml2` with Playport's Wine series, and llvm-mingw's C++ runtime linked statically | `Runtime/arm64ec-windows/xgameruntime.dll` | libxml2 MIT, with `list.c` and `dict.c` under their own ISC-style notices and `timsort.h` MIT; the C++ runtime as the llvm-mingw rows say |
| nghttp2 (nghttp2/nghttp2) `85e300c` (tag `v1.70.0`), unmodified, library only (`build/stages/xbox-pe.sh`) | `Runtime/arm64ec-windows/libnghttp2.dll`, an arm64ec Wine builtin that Wine's winhttp loads | MIT; its `lib/sfparse.c` MIT under the sfparse, nghttp3 and nghttp2 contributors |
| GStreamer 1.28.7, GStreamer's own iOS binary release (the pins.lock `gstreamer` version, sha256 in `build/stages/gstreamer.sh`; built by GStreamer's Cerbero from the `1.28.7` tag of <https://gitlab.freedesktop.org/gstreamer/gstreamer>): core, base, good and bad plugin libraries and the plugins `build/stages/gstreamer.sh` registers | executable (in `libwinegstreamer_unix.a`, statically), with Wine's winegstreamer unix side | LGPL-2.1-or-later; see "GStreamer" below for the libraries it carries |
| JavaSteam protocol schemas (field tables in `app/SteamClient`) | executable | MIT; pinned by commit `433f2ad15c36d5e690a4fe77401ec3f6b960641e` in the [joshuatam/JavaSteam](https://github.com/joshuatam/JavaSteam) fork of [Longi94/JavaSteam](https://github.com/Longi94/JavaSteam) |
| StikJIT 1.9.0 framework (the prebuilt `StikJIT.xcframework` release asset; tag `1.9.0`, commit `32287268fa5824f9edce4cb359f5833ce0cf7b00`, source at <https://github.com/StikDebug/StikJIT>) | the JIT helper extension (`PlugIns/PlayportJIT.appex/Frameworks/StikJIT.framework`), unmodified | MPL-2.0; see "StikJIT" below for what it carries inside |
| Mozilla's trusted root certificates, as published in curl's CA extract (the dated file the pins.lock `ca-bundle` row names, sha256 in `build/stages/ca-bundle.sh`) | `Runtime/certs/cacert.pem`, unmodified: the roots crypt32 imports into the prefix's ROOT store | MPL-2.0 (the PEM file is its own source form; the app carries the MPL-2.0 text as `StikJIT-LICENSE.txt`) |
| Wine Mono 11.3.0, WineHQ's binary release (the pins.lock `wine-mono` version, `wine-mono-11.3.0-x86.tar.xz`, sha256 in `build/stages/wine-mono.sh`; decision [0077](decisions/0077-ship-wine-mono.md)): Mono's runtime (`libmono-2.0-x86_64.dll`, `libmono-2.0-x86.dll`) and class libraries, FNA with FAudio, FNA3D and SDL, winforms, wpf, monoDX, System.Speech and Wine Mono's support files | `Runtime/mono/wine-mono-11.3.0/`, unmodified (a link staged as a copy of its target) | the licences its `COPYING` lists: Mono's parts MIT X11 or LGPL (SharpZipLib GPL with an exception), FNA MS-PL and MIT, its libraries zlib, winforms, wpf, monoDX and System.Speech MIT, Wine Mono's own code MIT. Source: the release's `wine-mono-11.3.0-src.tar.xz` (sha256 `SRC_SHA256` in the same script), which the source bundle carries and the notices come from |
| idevice (jkcoxson/idevice) at the `pins.lock` `idevice` commit plus `patches/idevice` (Bonjour advertising for on-device pairing), its C FFI with the features the restart after a game and pairing use (decisions 0029, 0033), built by `build/stages/idevice.sh` with the `pins.lock` Rust | executable (in `libidevice_ffi.a`, one prelinked object) | MIT; see "idevice in the executable" below for the crates it carries |
| Playport's patches to Wine (`patches/wine-pe`, `patches/wine-unix`) | Wine trees | offered under LGPL-2.1-or-later, so the Wine tree stays LGPL |
| Playport's patches to vkd3d-proton, gbe_fork, idevice and nexus-xgameruntime (`patches/vkd3d-proton`, `patches/gbe`, `patches/idevice`, `patches/xgameruntime`) | those trees | offered under each upstream's licence: LGPL-2.1-or-later, LGPL-3.0, MIT, LGPL-2.1-or-later ([decision 0040](decisions/0040-patch-series-under-upstream-licences.md)) |
| Playport's patches to DXVK (`patches/dxvk`) | the DXVK tree | offered under DXVK's zlib/libpng licence ([decision 0061](decisions/0061-dxvk-as-a-series.md)) |
| Playport's patches to Madeira, FEX and DXMT | those trees | the patched code keeps its licence; Playport's lines are GPL-3.0-or-later with the exception |

Apple's frameworks and the Swift runtime are system libraries on the device,
not bundle contents. The build tools (llvm-mingw, xtool, Apple ld64, the
Apple SDK) are not redistributed, but llvm-mingw's mingw-w64 CRT and headers
are compiled into the PE files Playport builds (see "Licence readings").

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
  identities; Playport's separate Rust 1.99.0 inventory does not cover them.

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
beside it (PLA-650).

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

### Xbox (planned)

The Xbox store ([spec PLA-485](https://linear.app/playportdev/issue/PLA-485), [decision 0179](decisions/0179-the-xbox-store.md))
adds a Swift client, `XboxClientKit`, written from Xodus's and Xodus Nexus's
code and docs (its session and synthetic device land in PLA-491); `xgameruntime`
as an ARM64EC Wine builtin; and `nghttp2`. This section answers the plan's
licensing question; the Components table gains each component when it lands.
The upstreams were read on 2026-10-30:

| Upstream | Read at | Licence as published |
| --- | --- | --- |
| Xodus ([xodus-gaming/xodus](https://github.com/xodus-gaming/xodus)) | `514dd56f360a4bdf12f4acde5148bac5ce5f957f`; MSIXVC2 is its open PR #219 from cyberps96/xodus, `e8194a89ea372c809015952bcab255e65b2b3089`, a fork carrying the same `LICENSE` | GPL-3.0. `LICENSE` is the version 3 text (sha256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`; it differs from Playport's `LICENSE` only in two FSF URLs). No file header, Cargo `license` field or README line says "only" or "or later" |
| Xodus Nexus ([domsvoboda/xodus-nexus](https://github.com/domsvoboda/xodus-nexus)) | `v0.4.1` (`e0668a12f1da931aed13537ef04295599011317b`) and main `96c652343d30ae16fe476818288edbed5dfac673`, the same `LICENSE` | MIT, "Copyright (c) 2026 Xodus Nexus contributors". Its `assets/` patches modify Xodus (GPL-3.0), Wine and xgameruntime (both LGPL-2.1-or-later) |
| nexus-xgameruntime ([domsvoboda/nexus-xgameruntime](https://github.com/domsvoboda/nexus-xgameruntime)), a fork of [xodus-gaming/xgameruntime](https://github.com/xodus-gaming/xgameruntime) | main `5539e7d23d2d2c49f8547c9b9721fb7bc59139c1`, 74 commits ahead of upstream `f03484d64867c1e65d421c1aba2f290c20bd7b4d` | `LICENSE` is the LGPL-2.1 text (sha256 `108e904a8b3df6012207649af241d5261a9c000f75d025034618f53ff9485c75`); every source file is LGPL-2.1-or-later by its header or SPDX line, except the MIT material listed below |
| nghttp2 ([nghttp2/nghttp2](https://github.com/nghttp2/nghttp2)) | tag `v1.70.0`, commit `85e300c79fb6dbcfa9c1013215c8710c1c2cd3d2` (the commit Nexus pins) | MIT (`COPYING`, sha256 `6b94f3abc1aabd0c72a7c7d92a77f79dda7c8a0cb3df839a97890b4116a2de2a`) |

MSIXVC2 (PLA-503) is translated from Xodus PR #219 at the commit above. Where that PR is silent or
inconsistent, the format's facts (CBOR labels, key wrapping with CBC and the rolling IV, box
manifests and seals) were read from LukeFZ/XvdTool.Streaming PR #3 at
`99db4dd3285b80cadcd60f21a311d909121a8944`, which is GPL-2.0 (`LICENSE` is the version 2 text):
no code was taken from it, so it adds no licence to `XboxClientKit`.

Rechecked at the pins (PLA-493, 2026-10-30): `xgameruntime` is `ab2fac35b500b87fefe51add26a0672a71d11576`,
the commit the ground truth's runtime carried, three commits before the main read above. Its
`LICENSE` and `tests/Nexus/LICENSE` have the same bytes, the same 12 `src/System/Threading`
files name libHttpClient, and the MIT files are the same six; every other C, C++, IDL and
header file in `src/`, `include/` and `libs/` has an LGPL-2.1-or-later header, and the two
export `.def` files and `include/version.h.in` carry no notice. `nghttp2`'s `COPYING` has the bytes above.
libxml2 comes from Playport's Wine tree, not Valve's `7fc704ef` (`patches/xgameruntime` 0001);
its `COPYING` has the same bytes as Valve's.

#### The Swift client

- **It is a work based on Xodus.** GPL-3.0 section 0 counts copying from or
  adapting "all or part of the work" as modifying it; the result is "based
  on" the earlier work. Translating Xodus's Rust into Swift is adapting it, so
  the fact that no Xodus code is linked does not make the client independent.
  The facts of Microsoft's protocol (hosts, field names, the bridge's wire
  format) are not Xodus's expression, but a file is not split along that line:
  the method decides. Every XboxClientKit file written while reading Xodus's
  code, or Nexus's Xodus patches, is treated as a work based on Xodus.
- **It may be combined.** Xodus's GPL-3.0 and Playport's GPL-3.0-or-later
  meet at version 3, and an app that carries the client is conveyed under
  GPL-3.0.
- **Version 3 only, until the owner decides** (Licence readings). Xodus ships the
  version 3 text and says nothing else. GPL-3.0 section 14 reads "If the
  Program does not specify a version number … you may choose any version
  ever published"; whether shipping the version 3 text specifies one is a
  reading. Playport takes the stricter reading, as it did for Madeira's
  headerless files. Under it:
  - Xodus-derived code goes in files of its own, headed
    `SPDX-License-Identifier: GPL-3.0-only`, never mixed into a
    GPL-3.0-or-later file. XboxClientKit's other files keep the usual header.
  - A build that carries those files is GPL-3.0 as a whole, not "or later".
    Decision 0006's "the whole combination stays or later" holds only for builds
    without them. Today that means the dev app only: decision 0179 keeps every
    Xbox surface in the dev app, with `pp verify --variant release` refusing
    a release executable that carries one.
- **What it owes** (GPL-3.0 sections 4 and 5), from the first public push of
  such a file, not only from the first IPA:
  - each derived file states that it was modified, with a date (section
    5(a)). Its header names Xodus, the Xodus commit it was written from, and
    "translated to Swift by the Playport authors" with the date;
  - the package carries Xodus's `LICENSE` beside the code as
    `LICENSE-Xodus.txt`, as `app/SteamClient` carries JavaSteam's, and the
    app's notices gain an Xodus component for it;
  - code written from Nexus's own code (its launcher, MIT) keeps Nexus's
    notice too (`LICENSE-XodusNexus.txt`). Code written from Nexus's Xodus
    patches owes both;
  - Xodus's `licensing/splicense.rs` retains LukeFZ's 2022 CikExtractor MIT
    notice. The translated CLEP state decoding in `XboxCrypto.swift` and the
    SPLicense, device-key and content-key code in `XboxLicensing.swift` keep it
    as `LICENSE-CikExtractor.txt`; the app's Xodus component carries it too;
  - Xodus's other files carry no copyright notice to keep; the derived files
    are in Playport's own source.
- **The converter exception does not cover it.** The exception covers only
  code whose copyright Playport's holder owns. The Xodus-derived files are
  third-party material in `app/`, which `LICENSE-EXCEPTION.md` already leaves
  out ("material Playport takes from others"). GPL-3.0 section 7 adds: "If
  additional permissions apply only to part of the Program, … the entire
  Program remains governed by this License without regard to the additional
  permissions." So a converter build that included this code could not rely
  on the exception for it. Unlike DXMT's LGPL code, GPL-3.0 code has no
  linking permission of its own to fall back on. Nothing changes today: the
  converter is not built, and release builds carry no Xbox code. Whether this
  blocks a future converter build is open (Licence readings).
- **Apple's frameworks.** The client uses Foundation, Security and related
  frameworks. For them it relies on the reading this page already takes:
  they are System Libraries on the device (GPL-3.0 section 1), so it does not
  depend on the exception.
- **The bridge.** XboxClientKit and `xgameruntime` talk over a loopback TCP
  socket (decision 0180). They are separate programs, so the bridge does not
  join their licences, and both are GPL-3.0-compatible in any case.

#### `xgameruntime`

- **LGPL-2.1-or-later.** LGPL-2.1 section 3 lets it be conveyed under the
  GPL, so it sits in the GPL-3.0 app as Wine's PE DLLs do. It is a PE DLL of its
  own in the runtime, an ARM64EC Wine builtin that a game's process loads. It
  is not linked into the executable, so a recipient replaces it by rebuilding
  its stage, as with gbe_fork.
- **Playport's lines in `patches/xgameruntime`** are offered under
  LGPL-2.1-or-later, the licence of the tree they patch (decision 0040's rule),
  so the tree stays under one licence and needs no exception.
- **The converter.** It is a guest PE DLL that never links the converter or
  an Apple framework, in the same position as Wine's PE DLLs. Playport's reading
  is that it adds nothing to the open DXMT question. The owner confirms that
  reading with the converter decision.
- **What it carries that is not LGPL.** This list was read at the commit
  above; recheck it at the pin.
  - The 12 files in `src/System/Threading/` that say "From
    https://github.com/microsoft/libHttpClient" under an LGPL header.
    libHttpClient is MIT, "Copyright (c) 2017 Microsoft Corporation". MIT
    permits the relicensing but requires its notice, which those files
    dropped. Which libHttpClient revision they came from is not recorded.
    Its `LICENSE.md` has not changed since the first commit,
    `256d1cc9b3ed9310b41a3da9a2d2de354efe22da` (sha256
    `d889d2995fd80a7eddc656e5e782d4755c4344cd2f80a6c7cc4529177829bc5f`).
  - `include/private/env.h`, `logging.h`, `statics.h` and
    `libs/xgameruntime-common/env.c`, `logging.c`: MIT, "Copyright (c) 2025
    Weather". All but `statics.h` read "Permission is hereby granted,
    CoTaskMemFree of charge", a search-and-replace slip in the grant; their
    headers are carried as they are, with `statics.h`'s intact wording.
  - `src/System/Threading/AsyncIdentity.h`, `SPDX-License-Identifier: MIT`
    with no copyright line. Nexus's MIT text is in the tree as
    `tests/Nexus/LICENSE` (the same bytes as Xodus Nexus's `LICENSE`).
  - libxml2, compiled statically from a Wine tree's `libs/xml2`
    (`cmake/Xml2.cmake`, checked against `cmake/xml2.lock.json`, which names
    ValveSoftware/wine `7fc704ef49c50e9702c9983a5250d5738697bb04`). It is MIT
    (`COPYING`, the same bytes as the fork's `licenses/Wine-libxml2.txt`),
    with `list.c` and `dict.c` under their own ISC-style notices ("this
    permission notice appear in all copies") and `timsort.h` under MIT
    (Christopher Swenson, Vojtech Fried, Google). Once this ships, libxml2 is
    no longer a Wine bundle that no shipped DLL links ("Not built and not
    shipped").
  - WinRT declarations generated from Wine's `include/` IDL
    (LGPL-2.1-or-later).
  - The C++ runtime it links statically (`-static -static-libstdc++`):
    llvm-mingw's libc++, libc++abi, libunwind and the mingw-w64 CRT, as in
    Playport's other PE files (Licence readings).
  - The GDK API headers in its `include/` are headed as Wine-project files,
    LGPL-2.1-or-later. Their provenance is the upstream's.
- **Not built:** `external/googletest`, `tests/` and `scripts/`.

#### nghttp2

- **MIT.** It is built library-only as `libnghttp2.dll`, a separate ARM64EC
  PE DLL. Wine's winhttp loads it at run time for HTTP/2 (Nexus's
  `wine-winhttp-http2.patch`, which `patches/wine-gdk` ports), and winhttp
  compiles against its header `nghttp2/nghttp2.h`. MIT is compatible with
  Wine's LGPL and the app's GPL. MIT also permits combining it with anything,
  the converter included, so it raises no exception question.
- **Owed: its notice.** `COPYING` (Tatsuhiro Tsujikawa and nghttp2
  contributors) covers the library. `lib/sfparse.c` and `sfparse.h` name
  their own holders (sfparse, nghttp3 and nghttp2 contributors). Its source
  goes in the bundle like every pin Playport builds, for the recipient's
  rebuild; MIT itself asks only for the notice (decision 0042).

#### For the runtime pins (PLA-493)

No IPA that carries either DLL leaves the workstation without these:

1. **Pins.** `xgameruntime` at a commit of domsvoboda/nexus-xgameruntime;
   `nghttp2` at tag `v1.70.0`, commit `85e300c79fb6dbcfa9c1013215c8710c1c2cd3d2`.
   Recheck the licence facts above at the pinned commit.
2. **Source** (`build/source-bundle.json` and DISTRIBUTION.md's list of
   git trees):
   - both trees by commit, with `patches/xgameruntime` in Playport's archive;
   - submodules a library-only or runtime build does not use, left out with
     their reason: `external/googletest`, and nghttp2's `third-party/mruby`,
     `third-party/neverbleed`, `third-party/urlparse` and `tests/munit`;
   - libxml2 and the WinRT IDL compiled from a Wine tree the bundle packs:
     Playport's Wine pin with its series. If the stage takes them from
     another Wine commit (the fork's lock names Valve's `7fc704ef`), that
     tree needs its own entry.
3. **Notices** (`build/notices-assemble.sh`, NOTICES.md's table, one
   `build/app-notices.json` component for each DLL):
   - xgameruntime:
     - its `LICENSE` (LGPL-2.1) and `tests/Nexus/LICENSE` (Nexus's MIT);
     - the whole MIT headers of `libs/xgameruntime-common/env.c` and
       `include/private/statics.h`;
     - libHttpClient's `LICENSE.md`, committed in `build/notices-extra/` with
       its commit and sha256, as DXBCParser's Microsoft text is;
     - libxml2's `COPYING`, already collected as `wine-libs-xml2-COPYING`
       and now to be selected for the app, plus the headers of `list.c`,
       `dict.c` and `timsort.h`.
   - nghttp2: `COPYING` and the header of `lib/sfparse.c`.
   - Both DLLs come into the scope of the llvm-mingw runtime and mingw-w64
     notice collection.
4. **This page:** Components rows for both DLLs, libxml2 out of "Not built
   and not shipped", and both trees in the Corresponding Source list under
   "Obligations".

#### For the other Xbox tickets

- **The first that lands Xodus- or Nexus-derived Swift** (sign-in, PLA-491,
  at the latest) must do the following: add the file headers and
  `LICENSE-Xodus.txt` (and `LICENSE-XodusNexus.txt` if Nexus code is used),
  add the notices component and NOTICES.md row, and add a Components row.
- **`patches/wine-gdk`** (PLA-494): each commit keeps its author, and
  Nexus's and Xodus's Wine patches become part of the LGPL-2.1-or-later Wine
  tree; the MIT that Nexus's repository names is compatible with that for
  its authors' lines. Playport's lines are offered under LGPL-2.1-or-later,
  as in `patches/wine-pe`. A patch that copies code from elsewhere keeps
  that code's terms.
- **Outside this page:** Microsoft's terms, the synthetic device and
  decrypting store DRM are not copyright-licence questions. They stay with
  the release record decision 0179 requires.

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
  shipped DLL links (fluidsynth, mpg123, lcms2, xslt, jxr, gsm, capstone;
  Wine's libxml2 is compiled into `xgameruntime.dll`), and Madeira's title
  scaffolding and deploy scripts.

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
   Abseil tag, the nexus-xgameruntime and nghttp2 commits,
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

## Licence readings

- **mingw-w64.** Its exact source revision and release-script association are recorded
  in `build/mingw-notices.lock.json`; runtime/source notices are collected and installed
  notice bytes compared. The [LLVM runtime collector](release-audits/llvm-runtime-collection.md)
  preserves exact-source libc++/libc++abi/libunwind/compiler-rt and resource-header
  credit supersets in a separately verified `pp notices` directory.
  `COPYING.MinGW-w64-runtime.txt`'s upstream
  Cephes FIXME: only libmingwex's `lgamma`, `lgammaf`, `lgammal`, `coshl`, `sinhl`,
  `tanhl` and `hypotl` can reach a UCRT link, and Moshier's grants ("may be used
  freely"; "BSD license is fine, modification is OK") are carried in FEX's
  `cephes-LICENSE.txt`, which the app lists for mingw-w64 too; the owner
  accepted that reading ([audit](release-audits/mingw-cephes.md), [decision 0039](decisions/0039-owners-licensing-review.md)). Tool/profile licence texts in the
  collected superset do not establish that those tools/profile objects are shipped.
- **Khronos and Mesa headers.** Root notices and `LICENSES/` texts from DXVK/vkd3d-proton's
  seven header checkouts (including nested converter copies) are collected with
  committed-byte origins. Mesa's scoped Vulkan/video and top-level SPIR-V headers
  are also collected whole with file/blob/range origins, preserving their credits
  as a superset. Neither superset is a claim of executable linkage.
- FreeType: taken under FTL, with its credit line ([decision 0039](decisions/0039-owners-licensing-review.md)).
- OpenLDAP 2.8: taken as GPL-compatible, as the FSF lists the OpenLDAP licence ([decision 0041](decisions/0041-codecs-supersets-and-relinking.md)).
- DXBCParser: its files say "Copyright (c) Microsoft Corporation. Licensed under the MIT
  License" with no year, and no licence text is in DXMT's tree. They come from
  microsoft/D3D12TranslationLayer (BlobContainer and DXBCUtils almost unchanged,
  ShaderBinary modified) and microsoft/DirectX-Headers (the tokenized-format header),
  whose LICENSE texts are identical. That text is committed byte for byte in
  `build/notices-extra/` with its commit and sha256, and collected as
  `DXBCParser-LICENSE-Microsoft.txt`, the notice; no year exists upstream.
- DXMT's upstream is LGPL-2.1-or-later since the move to upstream DXMT
  ([decision 0007](decisions/0007-dxmt-on-upstream.md)). Madeira's
  `LICENSE-MADEIRA.md` in the DXMT tree still calls the upstream licence MIT;
  it is Madeira's file and is left as it is. LGPL code does not carry Playport's
  or Madeira's converter exception, and the converter is not built.
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
- Xodus's version: GPL-3.0 only, or any version under section 14 because it
  names none? Playport takes version 3 only until the owner decides
  ("Xbox (planned)"). Under the other reading, the derived files could carry
  `GPL-3.0-or-later`, and the whole combination would stay "or later".
- The Xodus-derived Swift and a future converter build: the exception does
  not reach that code, and GPL-3.0 has no linking permission to fall back
  on. This is open for the converter decision, as DXMT's question is. The
  routes: the Xodus contributors grant the same permission; the converter
  build leaves XboxClientKit out; or the derived code is replaced by code
  written without reading Xodus. Playport's reading that `xgameruntime` (a
  separate guest PE DLL) adds nothing to that question is confirmed at the
  same time.
- `xgameruntime`'s libHttpClient-derived threading files: the notice is
  settled, because libHttpClient's `LICENSE.md` has been unchanged since 2017.
  Which libHttpClient revision they were taken from is not recorded upstream.
- The app's notice selection (`build/app-notices.json`) was release-reviewed on
  2026-10-05; its `xgameruntime` and `nghttp2` components (PLA-493), like the
  Xodus one, came later and wait for the owner's review before an IPA that
  carries them leaves the workstation.

The collected notices' known coverage limits are in [NOTICES.md](NOTICES.md#gaps). The
linked-member and applicability audits not yet done (Wine's bundled libraries against the
current pin, mingw-w64 and the LLVM runtime, Khronos and Mesa headers, LGPL DXMT with a
converter) are [PLA-725](https://linear.app/playportdev/issue/PLA-725).
