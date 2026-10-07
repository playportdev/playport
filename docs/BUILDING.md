# Build reference

Playport builds on one x86-64 Linux workstation with no Mac and no Apple
tools, from `pins.lock`, `patches/` and a few cached inputs, into one signed
IPA. Running it is in [AGENTS.md](../AGENTS.md#build). This page is what the
build needs and what is not obvious about it; each stage script's header
says what the stage does, and `pp verify --help` lists the IPA checks.

## Prerequisites

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
| `XTOOL` | xtool 1.20.1 with the increased-memory-limit patch | `build/toolchain/xtool.sh` ("Signing") |
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
build needs tens of GB; an IPA is about 650 MB.

| Path | Contents |
| --- | --- |
| `run/` | the trees, `run/logs/`, `run/stamps/` (each tree stage's input digest: pins, series, scripts, `build/lib.sh`, the toolchains) |
| `cache/` | toolchain caches keyed by version, and mirrors of Wine, FEX, DXMT, rpmalloc, StikJIT; they survive `--clean` |
| `out/` | verified outputs, one directory per build (the newest 3) |
| `inputs/`, `inputs.local` | ld64 and the patched xtool; this machine's tool paths (`pp setup`) |
| `ui-runs/`, `perf-runs/`, `install-runs/`, `sync/` | the device and sync runs |
| `device.lock`, `device.holder.json`, `device-state.json` | the phone's lock, its holder, what the last `pp install` put on the phone and from which checkout; every job on the machine uses these (`$PLAYPORT_DEVICE_DIR` moves them) |

`PLAYPORT_RUN` and `PLAYPORT_OUT` move `run/` and `out/` (`pp sync` gives each
candidate its own, and builds the candidate, a `git clone --shared` of this
repository, with this build area: its inputs, caches and the phone's lock);
`JOBS` sets the parallelism.

## The pipeline

| Stage | Script | Output |
| --- | --- | --- |
| `inputs` | | tools and inputs checked, their versions in `run/logs/inputs.txt` |
| `sources` | | `pins.lock` checked against the Madeira gitlinks; Madeira's wine, FEX and dxmt (`research/dxmt` before its 79e28f0) submodules initialised, not its others |
| `unix` | `stages/unix.sh`, `stages/unix-gaps.sh`, `stages/gstreamer.sh` | `libntdll_unix.a`, `libwin32u_unix.a`, `libwineserver.a`, the crypto statics, `libwinegstreamer_unix.a` (winegstreamer's unix side prelinked with GStreamer's iOS release, cached under `cache/gstreamer-<version>/`) |
| `pe` | `stages/wine-pe.sh`, `stages/wine-pe-strip.py` | the Wine PE DLL sets, `i386-windows`, `aarch64-windows` and `arm64ec-windows` (the first two share the new-WoW64 `build-macos` tree; configure sees GStreamer's headers, so `winegstreamer.dll` is built). The app stages them from `pe/staged`, each image without its `.debug_*` sections: every image the runtime maps is copied whole into the JIT pool. The COFF symbol table stays (`pp perf --profile` symbolises from it); the full images stay in `pe/wine` |
| `fex` | `stages/fex.sh` | `libarm64ecfex.dll`, shipped as `xtajit64.dll`, and aarch64 `libwow64fex.dll`, shipped as `xtajit.dll` (FEX's WoW64 CPU, [Portal 2 step 3](plans/finished.md#portal-2)) |
| `dxmt` | `stages/dxmt-*.sh`, `air-helpers/` | DXMT's unix slice (`libdxmt_combined.a`) and PE DLLs, from one patched tree |
| `vulkan` | `stages/mesa.sh`, `stages/vulkan-pe.sh` | the Vulkan backend (decision 0014): KosmicKrisp as `app/Staged/KosmicKrisp.xcframework`, DXVK and vkd3d-proton (with `patches/vkd3d-proton`) for `arm64ec-windows` |
| `steamapi` | `stages/steamapi.sh` | the Steam API emulator: gbe_fork's `steam_api64.dll` and `steam_api.dll` with their static dependencies, a host `protoc` of the same protobuf release, and Abseil at its pin; native DLLs the app copies into a game's folder at launch (`Runtime/steamapi/`); first `steamapi-vtables.py` checks that every interface's MinGW vtable matches MSVC's, which games use |
| `idevice` | `stages/idevice.sh` | idevice's C FFI at its pin plus `patches/idevice`, built for iOS with `RUST_ROOT` (`ring` for TLS; paths remapped), prelinked into one object exporting the restart and Bonjour pairing interfaces (`libidevice_ffi.a`); `crates.tsv` lists resolved normal target dependencies for `pp notices`, not actual linked members or the build/proc-macro/native graph ([decision 0029](decisions/0029-restart-after-each-game.md), [pairing experiment](plans/finished.md#self-contained-jit-setup-for-a-tester)) |
| `stage` | `stages/session-root.sh`, `stages/ca-bundle.sh`, `stages/stage-artifacts.py`, `stages/stikjit.sh` | the trusted roots (`Runtime/certs/cacert.pem`, cached under `cache/ca-bundle-<date>/`; "The trusted roots" below), the session root `playport-session.exe` (`app/SessionRoot`, staged in `Runtime/arm64ec-windows`, decisions [0027](decisions/0027-titles-as-children-of-a-session-root.md), [0030](decisions/0030-one-title-per-process.md)), `app/artifacts.tsv` recorded, everything staged into `app/`, StikJIT's framework (outside the main checkout's `.work/run`, every run ends by putting the records back and keeping its own in `out/…/records/`, or `run/records/` when it stops before `verify`) |
| `notices` | `notices-inputs.py`, `notices-assemble.sh`, `notices-app.py`, `notices-bundle.py` | the app's `Licenses/` for both variants: the collection inputs prepared in `cache/` from their committed locks, every notice of this run's trees collected into `run/notices` (`pp notices`), the reviewed selection (`build/app-notices.json`) in `run/licenses`, then staged as `app/Staged/Licenses` ([NOTICES.md](NOTICES.md#the-apps-selection)) |
| `app` | xtool | the signed IPA, linked with ld64 |
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
  pin's commit time. Both define `FEX_IOS_HOST`; WoW64 links FEX's own CRT
  (`-nostdlib`, as upstream), so `xtajit.dll` imports only `ntdll.dll` and
  `wow64.dll` (`pp verify` checks it: a CRT import loads `kernelbase.dll` into
  a WoW64 process before its NLS tables exist). The complete built i386
  DLL/driver set, excluding tests and programs, is staged alongside aarch64
  `wow64.dll` and `wow64win.dll`.
- **dxmt.** The unix slice and the PE DLLs must come from the same patched
  tree: the winemetal unix-call table has 150 slots (upstream's, then the
  port's 146-149), and a DLL next to another tree's table calls the wrong
  functions. `pp verify` checks the table.
- **stage.** After a staged `arm64ec-windows` DLL changes, the registry seed
  check fails until `pp registry` (`app/tools/prefix-registry.py`) regenerates it and
  it is committed.
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

The `hosttest` stage, `build/mesa-host-test/run.sh`, tests the driver's CPU
side without a GPU. It builds the same tree for Linux, with KosmicKrisp's
Metal stubs replaced by a mock (`make-mock-bridge.py`). The mock provides a
device, host-memory heaps and dummy handles, and completes commits at once.
`kk-host-test.c` then drives the driver through Vulkan: it creates a device
and builds and records draws with the pipelines it lists (geometry,
tessellation into geometry, line and point fill, transform feedback with its
counters and queries). The stage fails on a
crash, a NIR validation error (debug build), or an MSL library that has an
untranslated intrinsic. It also fails if a pipeline that captures transform
feedback has no vertex function that writes it.

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
