# Native macOS host and on-screen gamepad

This is a work-in-progress record. Both native IPAs passed verification and
the dev app is installed. Gamepad interaction and phone gameplay remain pending.

## Host checks

- Apple Silicon, Xcode's iPhoneOS 27.1/macOS 27.0 SDKs, native LLVM 23.1.4,
  llvm-mingw 20260922 macOS universal with the documented arm64ec CRT rebuild,
  and pinned Rust 1.99.0.
- xtool 1.23.0 builds with the existing increased-memory-limit patch unchanged.
  Apple ID login succeeded after the upstream fixes for `-80045`/`-80046`.
- HostIOKit: 49 tests passed, including finger ownership, cancellation/reset,
  slot-one merging, physical stick preservation and the existing menu gate.
- The UI runner's 30 tests passed, including bounded `touch:` actions routed
  during gameplay; these exercise command routing, not phone input delivery.
- The new overlay and dev touch driver passed iPhoneOS SDK type checking with
  API stubs for the rest of the app. This is not a full app compile.
- A minimal UIKit Swift package built through the app's native wrapper;
  its linked dylib reports platform iOS and minimum iOS 26.0. The wrappers
  use Xcode's real Swift executable so the system trampoline cannot inject
  macOS SDKROOT, and keep temporary files and compiler/SPM caches in the
  build area. Package planning through the companion wrapper also passed.
  A fresh SwiftBuild probe also passed the private-path byte scan: native
  partial links now receive the same debug-map cleanup as the final link.
- The fast host run passed all 591 Python tests. The remaining C portability
  changes were then checked with the complete WoW64 runner and the registry
  test. All passed. The full `pp test` run also passed, including C, TSAN and
  all Swift packages (239 PlayportKit tests).
- The 13 import tests pass with explicit copy-path testing on APFS and a ZIP
  fixture for names that a case-insensitive host filesystem cannot represent.
- The five native-host/CLI compatibility tests and all 30 source-bundle tests
  pass. Linux source-only CI (`pp test --quick` and licence check) passed at
  `98ff4fd`: https://github.com/CircuitSerein/playport/actions/runs/39967816054.
  This CI does not build an IPA on Linux.
- Wine's native host tools and the iOS ntdll/win32u archives built; win32u
  reported 46 compiled units and no failures. The ws4 link check passed.
  GStreamer built with the pinned classic ld64 for archive prelinking and
  passed the strict two-symbol export check. Its archive sha256 is
  `ef403f2337e07d89d4202facf6fe6e8c6bfe20d4b66f34af35836ee4933e0f9f`.
  Current Xcode ld lacks `-d`; the classic linker needs a libc++ iterator
  portability patch and explicit standard headers on this host. Final app
  linking still uses Xcode.
- The full Wine PE stage passed: both make trees exited zero, and i386,
  aarch64 and arm64ec machine checks passed. The stage stripped debug data
  from 4,066 outputs and rewrote the three committed PE manifests.
  Native Wine's macOS driver also needs Xcode's linker: current clang emits
  Objective-C class stubs that lld cannot resolve. Relinking the failed
  object set with Xcode succeeded, followed by the full successful PE stage.
- Both FEX DLLs built and passed their machine checks on the native host.
  macOS passes `TUNE_CPU=none` to FEX's existing CMake interface because its
  native-CPU probe reads `/proc/cpuinfo`; the target keeps the baseline ARM64
  architecture flags. Linux retains its original configuration.
- DXMT's native generators, Unix archive and all eight PE DLLs built. The
  slot check passed (150 slots, 149 calls). The host and iOS LLVM 15 builds
  need explicit standard-header includes with current libc++; the PE-only
  Meson build skips native Metal tools and uses the saved host compiler for
  its generators. Linux retains its original compiler defaults.
  The combined iOS archive built successfully, sha256
  `17f701f39e776455bc45adaeee51ecdcba2056a6d1080ad43b02326de8236583`.
- Mesa's native shader tools and all three iOS libraries built. Their
  architecture and import checks passed; KosmicKrisp, MesaGallium and MesaEGL
  were staged as iOS frameworks. DXVK (arm64ec and i386) and vkd3d-proton
  also built successfully on the native host.
- Both Steam API DLLs built, as did the iOS device/JIT library. Its strict
  symbol checks passed (110 imports), and the offline Cargo inventory
  resolved 149 target packages. Inventory selects the pinned native Rust
  release, matching setup, instead of forcing a Linux host compiler.
  The library sha256 is
  `db617222fee518918b4d2721549166fe3135b4c5013ed079ad77328c6be0e6e0`.
- Rust standard-library provenance passed against the real native installation:
  its notice files and iOS libraries match the unchanged locked archives
  byte for byte. All 39 checker tests passed, including native Apple Silicon,
  Intel Mac and Linux path selection. The archive identity stays unchanged;
  only the installed toolchain path follows the host.
- The full native unsigned release IPA passed all 84 checks, zero failures.
  Its sha256 is
  `55b01c608e59dcb48623434168a59b4407ae28a12ddc45693cf2493894f4e4db`;
  output: `.work/out/20261023-215734-release-unsigned-55b01c60/`.
  Explicit umbrella module maps preserve both C targets' existing public
  headers on case-insensitive APFS. The touch view's observer cleanup is
  MainActor-isolated. Native Xcode linking uses DWARF unwind information
  because compact unwind cannot encode both Rust personalities plus ObjC
  and C++; the nonempty `__eh_frame` parsed without diagnostics. Linux keeps
  its original linker flags. The staged runtime's 5,353 files all matched
  their recorded sizes and sha256 values.
- The dev app compiled, including the touch driver, and its signed IPA passed
  all 85 checks with zero failures. Its sha256 is
  `6544360b203324e4a2b59c4867e0539ead2d69a2d762f90fcb142d16772eb2a2`;
  output: `.work/out/20261023-221758-6544360b/`.

Logs are under `.work/`: `touch-tests-final.log`, `game-import-tests.log`,
`quick-tests-macos.log`, `wow64-macos-tests.log`, `full-host-tests.log`,
`native-unix-headers.log`, `native-unix-gaps.log` and `native-gstreamer.log`.

## Device gates

USB discovery sees one iPhone on iOS 27.0.1; Developer Mode is enabled.
The initial preflight stopped at missing team registration. The bootstrap
registered the phone, and signing succeeded after an owner-authorized
certificate refresh. iOS then refused installation because its three
free-provisioned app slots were occupied by apps from other installers.
The workstation guard counts only XTL-prefixed apps, so its earlier zero
did not represent the phone's global slot usage. The owner removed an
unrelated app; the agent did not uninstall anything. The verified dev IPA
then installed successfully in 24 seconds, recorded under
`.work/install-runs/20261023-221948/`. The app's first-run log showed the
setup checklist, the increased-memory entitlement enabled (6,144 MB limit),
and LocalDevVPN connected. The UI driver's first launch attempt failed;
the app was subsequently opened manually. The game ZIP is in Documents for
UI import. No game was played and no compatibility claim is made.

Tracked in the fork's draft PR: https://github.com/CircuitSerein/playport/pull/1.

Pending: the Controllers settings page and a Hollow Knight run
through first frame + 10 seconds with the on-screen controls.


## Follow-up device verification (2026-10-24)

The earlier pending gates above describe the original IPA. Subsequent tests
used the combined macOS/gamepad and pairing-hardening source tree. The final
verified dev IPA SHA256 is
`8946a191d2d84e6541189566e57bafb86d8f1e1e2db75a98d1cc8c90ca518691`.
It passed 89 IPA checks and was upgraded in place, preserving the container.

The first game launch exposed a native FEX backpatch-lock exclusive store
that the Mach store path cannot emulate. The macOS build now selects
`TUNE_ARCH=armv8-a+lse` alongside `TUNE_CPU=none`. The rebuilt DLL uses CASAL
in that exact function; Linux flags and the FEX pin are unchanged.

After one debugger connection failed with `Socket(Kind(AddrNotAvailable))`,
the owner launched Hollow Knight's Windows GOG version successfully. Logs in
`.work/macos-fex-lse-manual/` and `.work/macos-fex-lse-manual-later/` show JIT
activation in 2.75 s, a first frame at +11.52 s, and runtime liveness at +60 s.
The private screenshot shows rendered game content and the on-screen controls.
Actual touch logs include buttons, stick axes, simultaneous A and left-stick
input and release to neutral. The owner confirmed simultaneous movement,
jumping and attacking, and then verified a wired Xbox controller over USB-C.

The final full host run passed 597 Python tests, C/ThreadSanitizer gates and
all seven Swift packages. These results apply to the combined build. The
extracted feature-only PR branch has not been separately built or installed.
The intermittent debugger connection failure is unexplained; longer gameplay
and performance were not measured. Screenshots and raw logs remain in `.work`.
