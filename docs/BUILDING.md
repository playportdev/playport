# Build reference

Playport builds from `pins.lock`, `patches/` and a few cached inputs into a
signed IPA. The Linux path needs no Mac or Apple tools; this fork also builds
natively on macOS using Xcode's SDKs. Running it is in [AGENTS.md](../AGENTS.md#build). This page is what the
build needs and what is not obvious about it; each stage script's header
says what the stage does, and `pp verify --help` lists the IPA checks.

## Prerequisites

### Native macOS host

The same `pp setup`, `pp check`, `pp build` and `pp install` commands are used
on macOS. Xcode supplies the iPhoneOS/macOS SDKs and Apple linker; the SDK
version is discovered with `xcrun`, rather than requiring the Linux SDK bundle's
26.5 directory names. The inputs stage also builds the pinned classic ld64 for
GStreamer archive prelinking: current Xcode ld removed the required `-d` flag.
The final app link uses Xcode. This extends upstream's analysis-only Mac workflow
([0031](decisions/0031-a-mac-for-analysis-only.md)). Linux keeps its existing
cross-toolchain, slim SDK and netmuxd setup.

Install the native host tools with Homebrew (no shell profile changes needed):

```sh
brew install bash coreutils llvm lld gnu-sed gnu-tar findutils make gawk \
  bison flex gettext cmake ninja p7zip flock jq pkgconf premake \
  libclc spirv-llvm-translator glslang spirv-tools
```

Use a Python environment with `pefile`, `meson`, `mako`, `pyyaml`, `packaging`,
`jinja2`, `ply` and `pymobiledevice3` on PATH, and install native `rustup`.
The build installs the pinned Rust and iOS std into its own build area.
Keep this environment and scratch under `.work/` when preparing it locally.

Use `llvm-mingw-20260922-ucrt-macos-universal.tar.xz` (sha256
`52e5f5a7b131021d0c39a37a38fa380a1da7885cd04bd61afd0cd4ecfb8bc1f3`),
and apply the **same arm64ec CRT preparation below**. Record its location with
`pp setup --llvm-mingw DIR`. The native premake is used for Steam API DLLs;
the upstream bundled premake executable is Linux-only.

The build compiles xtool 1.23.0 with the existing increased-memory-limit patch
for signing. This pin includes the upstream Apple login fixes (#337/#380);
Apple ID users must log in again after upgrading. Sign in with
`$PLAYPORT_BUILD/inputs/xtool-src/.build/release/xtool auth login` before installing.
On Mac the phone uses Apple's system usbmuxd and USB; no netmuxd/systemd service
is needed. USB selection prevents a cabled phone's Wi-Fi record from being
counted as a second phone. The app is upgraded in place, as on Linux.

### Linux host

**Host tools.** The `inputs` stage checks for `clang`, `clang++`, `ld64.lld`,
`llvm-ar`, `llvm-nm`, `llvm-objdump`, `llvm-objcopy`, `llvm-lipo` (host LLVM
22.x), `gcc`, `make`, `bison`, `flex`, `msgfmt`, `cmake`, `ninja`, `meson`,
`python3`, `swift`, `xxd`, `openssl`, `patch`, `git`, `rsync` and `7za` (the
Steam API emulator's dependency archives), and the Python
module `pefile` (`app/tools/prefix-registry.py`). For the phone, `pp install`
checks for `pymobiledevice3`, `netmuxd` and `jq`; the pairing file also needs
`socat` ([DEVICE.md](DEVICE.md#setup-once)).

**Cached inputs** are not committed. System toolchains (`LLVM_MINGW`,
`DARWIN_SDK`) stay where they are installed, and the repository names no path
outside itself: `./pp setup` finds them once (llvm-mingw's clang on `PATH` or
`--llvm-mingw DIR`; the SDK from `swift sdk`) and records them, with netmuxd's
socket, in `$PLAYPORT_BUILD/inputs.local` (gitignored; `build/env.sh` and
`build/inputs.py` read it, and an environment variable wins). `LD64` and
`XTOOL` are built on demand into `$PLAYPORT_BUILD/inputs/`, and so is `RUST_ROOT`.

| Variable | What | How to produce it |
| --- | --- | --- |
| `LLVM_MINGW` | llvm-mingw 20260922 UCRT, with its aarch64 CRT rebuilt for arm64ec | below |
| `DARWIN_SDK` | xtool's SDK bundle (`iPhoneOS26.5.sdk`, `MacOSX26.5.sdk`) | `xtool sdk install <Xcode 26.6 .xip> --slim` |
| `LD64` | Apple ld64-956.6 for Linux | `build/toolchain/ld64.sh` ("Linking") |
| `XTOOL` | xtool 1.23.0 with the increased-memory-limit patch | `build/toolchain/xtool.sh` ("Signing") |
| `RUST_ROOT` | the `pins.lock` `rust` release with the `aarch64-apple-ios` standard library, through rustup (`rustup-init` checked by sha256), with its crate cache | `build/toolchain/rust.sh` (the `idevice` stage) |

Apple's Metal developer tools are not an input: the AIR helpers are
hand-ported LLVM IR (`build/air-helpers/README.md`) and `dxmt_command.metal`
is compiled on the device.

**llvm-mingw.** The release `llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64.tar.xz`
(sha256 `bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21`) has
EC-capable libc++ and builtins, but its aarch64 CRT import libraries lack the
arm64ec pieces FEX needs. Once, in place:

1. Rebuild mingw-w64-crt for aarch64 with EC support from the commit
   llvm-mingw names as `MINGW_W64_VERSION` (`57b595039040eaa15bece85b7cc71d952281b269`):

       ../configure --prefix=$LLVM_MINGW --host=aarch64-w64-mingw32 \
           --disable-lib32 --disable-lib64 --enable-libarm64 --enable-arm64x \
           --with-default-msvcrt=ucrt --enable-cfguard --enable-silent-rules
       make -j"$(nproc)" && make install

2. Copy `libclang_rt.builtins-aarch64.a` to `$LLVM_MINGW/aarch64-w64-mingw32/lib/`
   as `libgcc.a`, `libgcc_eh.a` and `libgcc_s.a` (the mingw driver requires
   `-lgcc` by name; the builtins resolve `#__chkstk_arm64ec`).

## The build area

`$PLAYPORT_BUILD` (default `.work/` in the repository, gitignored). Nothing
the project makes lives outside the repository. One
build needs tens of GB; an IPA is about 300 MB, deflated (1.5 GB unpacked).

| Path | Contents |
| --- | --- |
| `run/` | the trees, `run/logs/`, `run/stamps/` (each tree stage's input digest: pins, series, scripts, `build/lib.sh`, the toolchains) |
| `cache/` | toolchain caches keyed by version, and mirrors of Wine, FEX, DXMT, rpmalloc, StikJIT; they survive `--clean` |
| `out/` | verified outputs, one directory per build (the newest 3) |
| `inputs/`, `inputs.local` | ld64 and the patched xtool; this machine's tool paths (`pp setup`) |
| `ui-runs/`, `perf-runs/`, `install-runs/`, `sync/` | the device and sync runs |
| `device.lock`, `device.holder.json`, `device-state.json` | the phone's lock, its holder, what the last `pp install` put on the phone and from which checkout; every job on the machine uses these (`$PLAYPORT_DEVICE_DIR` moves them) |

`PLAYPORT_RUN` and `PLAYPORT_OUT` move `run/` and `out/`; `JOBS` sets the
parallelism. `pp sync` is watch-only by default (decision
[0054](decisions/0054-madeira-frozen.md)). Its exceptional `--move-pin-0054`
mode needs a new decision first: a candidate has its own run and out directories
but uses this build area's inputs, caches and phone lock
([UPSTREAM-SYNC.md](UPSTREAM-SYNC.md#moving-the-madeira-pin)).

## The pipeline

In the main checkout, use focused host checks first when they can answer the
question, then `pp build --plan` to see what would run and why. `pp check` is
an unsigned app compile, not a cheap host-only check: it first builds changed
dependencies and notices. Incremental builds reuse input stamps, but `app` and
`verify` still run, and a tree or staged-set change also reruns `notices`.
Use the stage logs to judge cost, not a fixed warm-loop time; reserve `--clean`
for a required full rebuild. Run checks directly, or enable shell `pipefail`
when piping output: `pp test | tail` alone can hide a failing test exit status.

| Stage | Script | Output |
| --- | --- | --- |
| `inputs` | | tools and inputs checked, their versions in `run/logs/inputs.txt` |
| `sources` | | `pins.lock` checked against the Madeira gitlinks; Madeira's wine, FEX and dxmt (`research/dxmt` before its 79e28f0) submodules initialised, not its others |
| `unix` | `stages/unix.sh`, `stages/unix-gaps.sh`, `stages/gstreamer.sh` | `libntdll_unix.a`, `libwin32u_unix.a`, `libwineserver.a`, the crypto statics, `libwinegstreamer_unix.a` (winegstreamer's unix side prelinked with GStreamer's iOS release, cached under `cache/gstreamer-<version>/`) |
| `pe` | `stages/wine-pe.sh`, `stages/wine-pe-strip.py` | the Wine PE DLL sets, `i386-windows`, `aarch64-windows` and `arm64ec-windows` (the first two share the new-WoW64 `build-macos` tree; configure sees GStreamer's headers, so `winegstreamer.dll` is built). The app stages them from `pe/staged`, each image without its `.debug_*` sections: every image with native code the runtime maps is copied whole into the JIT pool. The COFF symbol table stays (`pp perf --profile` symbolises from it); the full images stay in `pe/wine` |
| `fex` | `stages/fex.sh` | `libarm64ecfex.dll`, shipped as `xtajit64.dll`, and aarch64 `libwow64fex.dll`, shipped as `xtajit.dll` (FEX's WoW64 CPU, [Portal 2 step 3](plans/finished.md#portal-2)) |
| `dxmt` | `stages/dxmt-*.sh`, `air-helpers/` | DXMT's unix slice (`libdxmt_combined.a`) and PE DLLs, from one patched tree |
| `vulkan` | `stages/mesa.sh`, `stages/vulkan-pe.sh` | the Vulkan backend (decision 0014): KosmicKrisp as `app/Staged/KosmicKrisp.xcframework` (with Mesa's EGL and Zink as `MesaEGL`/`MesaGallium.xcframework`), DXVK (with `patches/dxvk`) and vkd3d-proton (with `patches/vkd3d-proton`) for `arm64ec-windows`, plus DXVK's `i386-windows` `d3d9`, `d3d10core`, `d3d11` and `dxgi` for WoW64 Direct3D 9 to 11 |
| `steamapi` | `stages/steamapi.sh` | the Steam API emulator: gbe_fork's `steam_api64.dll` and `steam_api.dll` with their static dependencies, a host `protoc` of the same protobuf release, and Abseil at its pin; native DLLs the app copies into a game's folder at launch (`Runtime/steamapi/`); first `steamapi-vtables.py` checks that every interface's MinGW vtable matches MSVC's, which games use |
| `idevice` | `stages/idevice.sh` | idevice's C FFI at its pin plus `patches/idevice`, built for iOS with `RUST_ROOT` (`ring` for TLS; paths remapped), prelinked into one object exporting the restart and Bonjour pairing interfaces (`libidevice_ffi.a`); `crates.tsv` lists resolved normal target dependencies for `pp notices`, not actual linked members or the build/proc-macro/native graph ([decision 0029](decisions/0029-restart-after-each-game.md), [pairing experiment](plans/finished.md#self-contained-jit-setup-for-a-tester)) |
| `stage` | `stages/session-root.sh`, `stages/ca-bundle.sh`, `stages/wine-mono.sh`, `stages/stage-artifacts.py`, `stages/stikjit.sh` | the trusted roots (`Runtime/certs/cacert.pem`, cached under `cache/ca-bundle-<date>/`; "The trusted roots" below), Wine Mono (`Runtime/mono/wine-mono-<version>/`, the release and its source release cached under `cache/wine-mono-<version>/`; "Wine Mono" below), the session root `playport-session.exe` (`app/SessionRoot`, staged in `Runtime/arm64ec-windows`, decisions [0027](decisions/0027-titles-as-children-of-a-session-root.md), [0030](decisions/0030-one-title-per-process.md)), the URL opener `playport-url-opener.exe` beside it (`app/UrlOpener`, the prefix's http and https handler, decision [0064](decisions/0064-game-web-sheet.md)), `app/artifacts.tsv` recorded, everything staged into `app/`, StikJIT's framework (outside the main checkout's `.work/run`, every run ends by putting the records back and keeping its own in `out/…/records/`, or `run/records/` when it stops before `verify`) |
| `notices` | `notices-inputs.py`, `notices-assemble.sh`, `notices-app.py`, `notices-bundle.py` | the app's `Licenses/` for both variants: the collection inputs prepared in `cache/` from their committed locks, every notice of this run's trees collected into `run/notices` (`pp notices`), the reviewed selection (`build/app-notices.json`) in `run/licenses`, then staged as `app/Staged/Licenses` ([NOTICES.md](NOTICES.md#the-apps-selection)) |
| `app` | xtool, `deflate-ipa.py` | the signed IPA, linked with ld64, rewritten deflated |
| `verify` | `verify-ipa.py` | the IPA checks; the IPA, `artifacts.tsv`, `SHA256SUMS`, `provenance.txt` and the logs to `out/` |

Every tree is its pin with its series applied by `apply_series`
(`build/lib.sh`: `git am -3` with a fixed committer and date, so the commits
do not depend on who builds); `ensure_series` re-applies a series whose
patch-ids differ from the tree's commits. What the stage logs show that is
not a failure, and what must hold:

- **unix.** The as-built `libwineserver.a` reports `LINK FAIL` under lld with
  four symbols it shares with `libntdll_unix.a`: expected, ld64 resolves them
  as Xcode does ("Linking").
- **pe.** Four `make -k` failures are expected, the ntoskrnl test drivers
  `dlls/ntoskrnl.exe/tests/arm64ec-windows/driver{,2,3,_netio}.dll`
  (`undefined symbol: #__chkstk_arm64ec`), which are not shipped. Any other
  `***` line is a real failure.
- **fex.** `-stdlib=libc++` is mandatory (the `-gnu` default `-lstdc++` does
  not exist in llvm-mingw); the DLLs must read back as ARM64EC (`xtajit64`)
  and ARM64 (`xtajit`). Debug info is stripped. ARM64EC's build date is its
  pin's commit time. On macOS, CPU probing is disabled and the target is
  ARMv8 with LSE (supported by the app's iOS 26 device baseline), so native
  backpatch locks use CASAL instead of exclusive stores into the RX pool.
  Both define `FEX_IOS_HOST`; WoW64 links FEX's own CRT
  (`-nostdlib`, as upstream), so `xtajit.dll` imports only `ntdll.dll` and
  `wow64.dll` (`pp verify` checks it: a CRT import loads `kernelbase.dll` into
  a WoW64 process before its NLS tables exist). The stage takes each
  architecture's Wine modules from its `build/generated` manifest (decisions
  [0070](decisions/0070-wine-modules-proton-parity.md) and
  [0071](decisions/0071-wine-modules-full-proton-set.md)): the whole production
  arm64ec, aarch64 and i386 sets, programs and i386's 16-bit modules included,
  without tests and `winetest.exe`. The arm64ec tree is configured with every
  program configure lists (`--enable-<program>`, `stages/wine-pe.sh`), since Wine
  leaves programs out of an arm64ec build by default; `winedbg`, `wineboot` and
  `explorer` stay out of it ([decision 0082](decisions/0082-system32-programs.md)).
- **dxmt.** The unix slice and the PE DLLs must come from the same patched
  tree: the winemetal unix-call table has 150 slots (upstream's, then the
  port's 146-149), and a DLL next to another tree's table calls the wrong
  functions. `pp verify` checks the table.
- **stage.** The registry seed check compares `app/registry` with the staged
  `arm64ec-windows` DLLs' `WINE_REGISTRY` resources and the generator's fixed
  keys, not arbitrary DLL bytes. If it reports a stale seed, run `pp registry`
  (`app/tools/prefix-registry.py`) against that staged set, review the diff and
  commit it. A digest error from it (wine.inf's `do_reg_operation`, a media DLL's
  `DllRegisterServer`, WIC, wintrust, msisip) means a Wine move changed code the seed
  ports: check the port; for a media DLL, refresh `app/tools/wineboot-media.reg` from a
  `wineboot --init` desktop prefix of the new Wine (decision 0080) and update the digest.
- **notices.** Runs after any tree or the staged set changes, and on its own
  scripts, locks and selection. The first run puts roughly 0.5 GB of
  locked inputs (three source checkouts, the Rust release archives, Cerbero and
  the GStreamer recipe archives) in `cache/`, each checked against its lock;
  one already there that differs is reported, never replaced. A collected file
  the selection does not classify, or a pattern that names nothing, stops the
  build: classify it by a reviewed edit to `build/app-notices.json`. The staged
  bundle keeps its status (`release-reviewed` from the reviewed selection, decision 0039;
  `unreviewed-app-selection` whenever the selection is not):
  `pp verify` reports it, and only `--distribution` fails it.

**The trusted roots.** `Runtime/certs/cacert.pem` is Mozilla's root store as
published in curl's CA extract (<https://curl.se/docs/caextract.html>), the dated
file `cacert-<date>.pem` the pins.lock `ca-bundle` row names, checked against the
sha256 in `build/stages/ca-bundle.sh` (ARCHITECTURE.md, "Trusted roots"). Move it
by hand before each release: take the newest date from that page, download
`https://curl.se/ca/cacert-<date>.pem`, check it against the published
`cacert.pem.sha256` when the dated file is the newest, then put the date in
`pins.lock`, the sha256 in `ca-bundle.sh`, and both in `build/source-bundle.json`'s
`ca-bundle` entry, and commit them with the rebuilt `app/artifacts.tsv`.

**Wine Mono.** `Runtime/mono/wine-mono-<version>/` is WineHQ's Wine Mono release in its
shared-directory form, unmodified (decision [0077](decisions/0077-ship-wine-mono.md)):
`build/stages/wine-mono.sh` fetches `wine-mono-<version>-x86.tar.xz` and
`wine-mono-<version>-src.tar.xz` from `https://dl.winehq.org/wine/wine-mono/<version>/`,
checks each against its sha256 in the script and unpacks the first. It moves with the
wine pin: the version is the wine pin's `WINE_MONO_VERSION`
(`dlls/mscoree/mscoree_private.h`; `tools/tests/test_wine_mono.py` compares them when the
run's Wine tree is there). To move it, put the version in `pins.lock`, both sha256s in
`wine-mono.sh` and the source release's in `build/source-bundle.json`'s `wine-mono` entry,
check the support package's registry against `app/tools/prefix-registry.py` `WINE_MONO`,
and commit them with the rebuilt `app/artifacts.tsv` and `app/registry`.

**The SDK's libc++ headers for iOS C++.** The host clang searches its own
`../include/c++/v1` before the sysroot's, so on a Linux host with libc++
installed an iOS compile would take Linux's libc++ headers. Their
`__config_site` has no Apple availability markup, so code below the app's
deployment target calls exports that only a newer iOS's libc++ has. libc++ 21's
`std::__hash_memory` killed the app at launch on iOS 26.0 (PLA-5). Every iOS C++
compile (DXMT's unix slice and its LLVM, `mesa.sh`) passes
`-stdlib++-isystem $IOSSDK/usr/include/c++/v1`, and `pp verify` fails a Mach-O
that imports a libc++ symbol iOS 26.0 lacks (`LIBCXX_NEWER_THAN_MINOS`).

**No workstation path in the IPA.** Every tree is compiled with
`-ffile-prefix-map` for its own root and the toolchains (the unix stage's
clang shim, Wine's `CROSSCFLAGS`, FEX's and DXMT's flags, and
`build/ld64/swift-build` for the app), and ld64 writes its debug map
repo-relative. `pp verify` fails an IPA naming this machine's `$HOME` or the
repository. A tree Madeira's scripts built before a flag change keeps the old
paths: rebuild it with `--clean`. Prebuilt parts keep their own CI's paths
(StikJIT, llvm-mingw's libc++abi).

### KosmicKrisp

`build/stages/mesa.sh [ROOT]` builds Mesa's Vulkan driver for iOS from the
`mesa` pin plus `patches/mesa` ([decision 0014](decisions/0014-vulkan-through-kosmickrisp.md)).
The `vulkan` stage runs it without `hosttest` and stages the driver as
`app/Staged/KosmicKrisp.xcframework`, which the app embeds. Beyond the usual
host tools it needs LLVM with clang, libclc and SPIRV-LLVM-Translator, for the
Linux-side shader tools (`mesa_clc`, `vtn_bindgen2`, `kk_clc`). Its `check`
stage runs `build/check-macho-imports.py`, which resolves every import of
`libvulkan_kosmickrisp.dylib` against the iPhoneOS SDK. The driver links with
`-undefined dynamic_lookup`, so without this check a missing symbol would
show up only when dyld loads it on the phone.

The same tree also gives OpenGL (PLA-162; [ARCHITECTURE.md](ARCHITECTURE.md#opengl)):
a second iOS build directory, `run/mesa/ios-gl`, builds Mesa's EGL and its
OpenGL frontend with Zink as the one Gallium driver (`-Dgallium-drivers=zink
-Dvulkan-drivers= -Dopengl=true -Degl=enabled -Dplatforms=macos`, no GLES, GLX,
GBM, glvnd, LLVM or video codecs). `libEGL` and `libgallium_dri` are staged as
`app/Staged/MesaEGL.xcframework` and `MesaGallium.xcframework`; MesaEGL links
MesaGallium, Zink loads KosmicKrisp by its framework install name, and
`patches/mesa` 0022–0028 make Zink build without MoltenVK, present to Metal
surfaces, give the surfaceless EGL platform window surfaces on a `CAMetalLayer`
(sRGB ones for sRGB pixel formats), reach Zink without DRM devices, keep no Zink
disk cache on iOS, and let Zink create its instance on KosmicKrisp with no Vulkan
loader ([decision 0087](decisions/0087-opengl-through-zink-on-the-host.md)). The `check`
stage checks both libraries too, MesaEGL's imports against MesaGallium's exports
(`check-macho-imports.py --with`). The app links and embeds all three
frameworks; win32u dlopens MesaEGL as its EGL.

The `hosttest` stage, `build/mesa-host-test/run.sh`, tests the driver's CPU
side, and Zink's over it, without a GPU. It builds the same tree for Linux, with KosmicKrisp's
Metal stubs replaced by a mock (`make-mock-bridge.py`). The mock provides a
device, host-memory heaps and dummy handles, and completes commits at once.
`kk-host-test.c` then drives the driver through Vulkan: it creates a device
and builds and records draws with the pipelines it lists (geometry,
tessellation into geometry, line and point fill, transform feedback with its
counters and queries). The stage fails on a
crash, a NIR validation error (debug build), or an MSL library that has an
untranslated intrinsic. It also fails if a pipeline that captures transform
feedback has no vertex function that writes it. Then it builds Zink and EGL for
Linux on the same mock (`run/mesa/hosttest/build-gl`) and runs
`zink-host-test.c`: a surfaceless EGL display reaches Zink the way the phone
does (no DRM device has a driver in that build), and a compatibility context
clears, draws a fixed-function and a GLSL 1.20 triangle, blits and reads back.
Zink loads the workstation's Vulkan loader (`libvulkan.so.1`), limited to the
mock by `VK_DRIVER_FILES`; the stage fails on a GL error, a renderer that is
not Zink, or an untranslated MSL library (`run/mesa/hosttest/msl-zink/`).

The pipeline's `vulkan` stage leaves the host test out. Run it on the build's
tree, edits included, with `build/stages/mesa.sh .work/run/mesa hosttest`
(after a `pp build` has made `run/mesa/mesa` and `run/mesa/host`); the MSL
libraries it translated land in `.work/run/mesa/hosttest/msl/`. A new case is
a shader in `build/mesa-host-test/shaders/` and a pipeline in `kk-host-test.c`.

## Variants

Only `app` and `verify` differ between `dev` and `release`
([decision 0009](decisions/0009-dev-and-release-builds.md)), so a release
build after a dev one reuses every tree. xtool takes the product name from
`./xtool.yml`, so the release app builds from a second package,
`app/.release/` (gitignored), that `stage-artifacts.py release` makes. Its
`xtool.yml` names
`Icon/AppIcon.png` for the icon, where the dev app's `Icon/AppIcon-dev.png` carries a
DEV tab. Both are rendered from `app/Icon/AppIcon.svg` by `app/Icon/render.sh` and
committed; the build does not render them.

`pp build --variant release --unsigned` builds the IPA a release publishes
([decision 0038](decisions/0038-unsigned-release-ipas.md)): xtool signs it ad hoc
with its entitlements and no certificate, profile, team or device, and `verify`
runs `pp verify --unsigned` in place of the signature and profile checks. It is
named `Playport-26.5-release-unsigned-<sha8>.ipa`; `pp install` never picks it.
`pp release VERSION` reuses the newest such build of HEAD, or runs it
(incrementally; `--clean` builds every tree afresh, [decision 0050](decisions/0050-release-reuses-the-build.md)), binds source/notices/instructions
to its exact commit and requires distribution notice verification before a draft
upload. `--no-github` assembles privately without an upload command; source gaps
remain visible and neither mode approves publication
([RELEASE-HOSTING.md](RELEASE-HOSTING.md)).

## Linking

The app links with Apple's ld64, not the SDK's `ld64.lld`: `libwineserver.a`
and `libntdll_unix.a` both define four symbols, which ld64 resolves as
Madeira's Xcode link does and lld refuses. `build/toolchain/ld64.sh` builds
ld64 from cctools-port, apple-libtapi (the slow part) and apple-libdispatch
at pinned commits, with `-D_GLIBCXX_NO_ASSERTIONS` (GCC 15's assertions abort
in ld64's Objective-C pass). `build/ld64/swift-build` is the SwiftPM toolset
xtool runs: the per-target `-r` steps go to `ld64.lld`, every final link to ld64.

## Signing

- **Patched xtool.** Stock xtool 1.20.1 silently drops the
  `com.apple.developer.kernel.increased-memory-limit` entitlement for a free
  team, and FEX then gets no JIT arena. `build/toolchain/xtool.sh` builds it
  with `build/toolchain/xtool-1.20.1-increased-memory-limit.diff`; the
  pipeline refuses an `XTOOL` without it.
- **Account.** `xtool auth login` once, from a terminal; bare `xtool auth` is
  the login and fails without one.
- **Identity.** One bundle ID for both variants, signed as
  `XTL-<team>.dev.playport.app`; display name Playport; the
  executable is `S1Probe` (dev) or `Playport` (release). The JIT helper
  extension has its own bundle ID and profile
  ([ARCHITECTURE.md](ARCHITECTURE.md#built-in-jit)).
- **Entitlements.** xtool's free-team set plus `increased-memory-limit`
  (`app/S1Probe.entitlements`); `get-task-allow` lets debugserver attach for JIT.
- **Deployment target.** iOS 26.0, so a phone on any iOS 26 installs it; only iOS 27.0
  is tested ([DEVICE.md](DEVICE.md#known-good-ios-versions)). The pinned SDK accepts up to 26.5.

## Public CI and publication preparation

[`.github/workflows/checks.yml`](../.github/workflows/checks.yml) is
**source/testing-only**. It runs `pp test --quick` (name/secret/pin/patch gates,
Python tests and available host C tests) and checks the exception's adoption
marker. A host compiler is needed, but no iOS SDK, signing account or phone is
used. Swift tests are omitted. Host C tests that require an unpopulated Madeira
submodule are explicitly skipped; the default CI checkout does not populate it.
An adoption marker is a source check, not a legal-clearance decision.

The workflow uses hosted Linux runners, a commit-pinned checkout with persisted
credentials disabled, and read-only repository permissions. It has no signing
secrets, app/runtime build, install/device steps, cache or artifact uploads,
release steps or reusable workflows. Official signed IPAs must not be published
through GitHub, including public Actions artifacts. For simplicity, this CI
uploads **no artifacts at all**, even renamed archives or build directories.
Recipients' licence rights to redistribute their copies are unaffected.

`tools/tests/test_release_ci.py` runs before the remaining test-job commands
and in `pp test --quick`. It fails closed on any additional workflow file or
change to the approved executable workflow text. Changes to runners, actions,
permissions, triggers or commands require explicit policy/test review; full-line
comment and blank-line edits alone do not. This deliberately narrow allowlist avoids
trying to recognise all possible upload commands or artifact suffixes. It is a
regression gate, not protection against an editor who also changes the gate,
repository settings, compromised actions or upload code added to tested scripts.

Build and device gates remain local workstation checks; green public CI does
not prove that this commit builds/runs on iOS, that collected notices are
complete, or that a recipient can rebuild/relink the delivered app. Source
publication needs approved history, provenance and remote review; an IPA needs
separate exact-source, notice, relinking, Apple/signing and channel review
([open-source release plan](plans/finished.md#open-source-publication-and-the-first-ipa),
[distribution procedure](DISTRIBUTION.md)). Technical Linux/free-team signing
success is not legal distribution approval. Do not upload local `.work`, caches,
SDKs, provisioning material or whole run outputs as public build artifacts.

This policy covers the checked-in workflow only. Historical hosted release
attachments and CI artifacts have **not** been inspected in this preparation
pass: no selected, approved publication remote/history was supplied. Inspect
those separately before any public push; the broader publication gate remains
open.
