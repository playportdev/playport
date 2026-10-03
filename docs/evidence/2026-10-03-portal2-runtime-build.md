# Portal 2 milestone 1, step 1: runtime build scaffolding

## Result

The [plan's step 1](../PORTAL2-PLAN.md#step-1-build-the-pieces-done-2026-10-03)
builds, stages and verifies the new runtime pieces. **It does not run i386
code or remove Portal 2's low-address launch blocker.** No cohort decision,
new launcher or test executable was added. Next is step 2's per-process Wine
window and pointer-conversion audit.

- Source at build: `59302e8` with this step's local changes.
- IPA: `.work/out/20261003-113340-6d18cac5/Playport-26.5-6d18cac5.ipa` (dev).
- SHA256: `6d18cac5600db962b551f64fce2775640166a4b08222ee0b724c3fb76187a433`.
- Size: **657,326,047 bytes**. Against the preceding committed artifact record,
  628 new resources add **196,526,080 bytes (187.4 MiB)**: 625 i386 DLLs/drivers
  (190,595,072 bytes), aarch64 `wow64.dll`, `wow64win.dll` and `xtajit.dll`.
  This is the measured runtime-payload increase, not an exact before/after IPA
  delta; the stored ZIP also grows its manifest, signature seals and metadata.
- `pp build`: passed; `pp verify`: **77 checks passed, 0 failed**. All new
  guest images are PE32 I386 Wine builtins; the three host DLLs are PE32+ ARM64
  builtins; FEX exports `BTCpuProcessInit`, `BTCpuThreadInit`, `BTCpuSimulate`.
- Host tests cover strip discovery, both variants' resource lists, PE header
  parsing and rejection of wrong machine/magic or missing core DLLs.

## Build changes and failures resolved

Wine's `build-macos` configures with `--enable-archs=i386,aarch64`;
`build-arm64ec` stays separate. The i386 manifest is generated from stripped
outputs as the other two are. Staging takes the complete built i386 DLL/driver
set, excluding tests, programs and `.sys` drivers, rather than inventing a PE32
loader or predicting the game's transitive imports. Both package variants name
this resource directory. `pp verify` checks its contents and machine types.

The first Wine build failed to compile i386 ntdll: the native CHPE detach probe
read a TEB member absent in PE32, and the lock census emitted ARM `mrs`
instructions. **wine-pe 0013** guards the native detach probe and uses
`NtQueryPerformanceCounter` plus its frequency for non-ARM lock timing. The
ARM paths are unchanged in logic; their ntdll hashes changed on rebuilding
modified sources (the PE keeps the COFF symbol table). The aarch64 `winetest`
record also changes; it is not shipped. The stage now stops on any unexpected
`make` failure rather than recording an incomplete set.

FEX gets a second aarch64 configuration and uses the architecture-specific
`dlltool` driver; plain `llvm-dlltool` had produced x64 import libraries.
**fex 0015** applies the existing mingw CRT link rules to the WoW64 module and
guards a shared reserve-failure diagnostic's iOS band references. Without these,
WoW64 lacked its startup/C runtime and referenced undefined band globals.

This configuration deliberately leaves **`FEX_IOS_HOST` undefined for WoW64**.
Enabling it exposed unresolved mono/alias/arena helpers implemented by the
ARM64EC frontend, not WoW64. No no-op helpers were added to force a link; step 3
must port the real JIT and transition plumbing before enabling it. The
`FEX_IOS_HOST_BUILD` CMake option selects the mingw CRT build configuration;
it does not enable the `FEX_IOS_HOST` preprocessor paths. This DLL is build
scaffolding and must not be mistaken for a functioning iOS frontend.

FEX ARM64EC and the dependent DXMT/Vulkan PE outputs were rebuilt and their
records updated in the default `.work/run`; pins are unchanged. Registry
seeding and notice selection checks passed without changes to their inputs.

## Phone regression

One device-lock session upgraded in place, keeping the container, then ran:

```sh
./pp phone lock -- sh -c './pp install --no-build && ./pp ui --play app-367520 --until first-frame+10 --shot'
```

Run: `.work/ui-runs/20261003T113426`. The installed event and result both name
the IPA SHA256 above. The result is **ok**, exit 0, `until first-frame+10`.

- JIT acquired in 2.54 s; runtime started at 3.32 s; game started at 3.39 s.
- Hollow Knight's first frame at **9.63 s**, followed by ten seconds running.
- No JIT pool exhaustion, no refused FEX-band allocation; all reported runtime
  limit counters were zero.
- The stop screenshot is black (no menu/gameplay image is claimed). The launch
  verdict is the logged first-frame and continued run, not a screenshot verdict.
  Screenshots and logs remain in the private run directory.

The full host suite initially found a pre-existing release-test assertion for
`0.1.0` despite the Release 0.2.0 baseline. Commit `a4fbc3c` fixes that test to
check the actual app version and its helper's agreement, without changing either
plist. The rerun of **`pp test` passed**, including 483 Python tests, the host C
tests and all three Swift packages. `pp slots` passed (150 slots, 149 calls),
`git diff --check` passed, and `pp build --plan` reports no trees or staging to
rebuild. Host-test output stays in `.work/tmp/portal2-runtime-host-tests.log`.
