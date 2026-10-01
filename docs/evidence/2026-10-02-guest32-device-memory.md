# Software-backed Win32 memory: phone-side gate passed

## Verdict

The software guest memory contract passes **36/36 checks, twice in one iOS
process**, through dev Settings › Developer › Probes › **Win32 memory
experiment**. The phone has real 16 KiB host pages. Two separate 4 GiB guest
backing windows were reserved above the iOS low-address floor and released
before each run returned.

**This is not Portal 2 execution or working WoW64. No guest instructions ran.**
No Wine session was started and the probe requested no JIT pool. The app's
normal startup helper-readiness check still ran independently. No game files,
saves or Steam session were modified by the probe. The development app was
upgraded in place; no app was uninstalled or container deleted.

## Device run

- IPA: `.work/out/20261002-010654-8c1af7fa/Playport-26.5-8c1af7fa.ipa`.
- SHA256: `8c1af7fa7106c451e9ca6b11ca4d69fb3a18f3c997b596c9e2d91558866c3b30`.
- Dev IPA verification: 71 checks passed, 0 failed.
- Run: `.work/ui-runs/20261002T010714/`.
- Command: `pp ui --action probe:guest32-memory --action probe:guest32-memory --shot-each-action --wait 60`.
- Result: `ok=true`, `exit=0`, `done="ok actions=2"`.

Both runs log:

```text
guest32: memory-probe ok checks=36 failures=0 host_page=16384 backing_a=0x7000004000 backing_b=0x7100010000 guest_execution=none
```

The screenshots remain in that private run directory. They show the Developer
section and the focused Win32 memory experiment row, reporting
**36/36 checks; 16 KiB host pages; no guest code**. These are probe results,
not a compatibility label or a game frame.

The checks exercise ownership and forward/reverse pointer conversion, low-null
rejection, commit/read/write/fetch, a protected 4 KiB guest page sharing native
backing with writable neighbors, whole-access validation without partial writes,
decommit zeroing without damaging a neighbor, the 32-bit upper edge, release
and zeroed reallocation. Native window addresses being reused on the second
run is consistent with the windows being released, not retained for the game.

## Implementation and isolation

`app/Sources/Guest32Experiment/` exposes the shared experiment sources through
repo-relative symlinks, plus `probe.c`. `Guest32Probe.swift` lives in `Dev/` and
calls it off the main thread. The Settings button and UI driver invoke the same
method. The probe rejects a running/spent Wine session, and a dev title launch
rejects a busy probe: these temporary windows can occupy Wine's future fixed
bands, so they must be gone before runtime initialization.

The guest32 target is omitted from the release package's target/dependency list.
An unsigned release build passed 69 verification checks; inspecting its extracted
executable with `llvm-nm` found no `_g32_`, `Guest32Probe` or
`Guest32Experiment` symbols. The release IPA was not installed.

## Host checks

- Full `pp test`: passed, including all Swift packages, 480 tooling tests and
  the new native-probe C test.
- Native probe C test: 36 checks passed, three repeated runs.
- Native probe AddressSanitizer + UndefinedBehaviorSanitizer run: passed.
- `pp check`: dev app compiles.
- Dev signed and release unsigned builds verified; no runtime artifact records,
  pins or upstream patch series changed in this step.

Private host/release logs are `.work/tmp/portal2-device-probe-checks.log` and
`.work/tmp/portal2-probe-release.log`. The source was tested as local changes on
`371e4a9`; this record is committed with those changes.

## Remaining execution gate

[Host-side PE32 materialization](2026-10-02-guest32-pe32.md) and this native
reservation test establish memory feasibility, not a complete loader/CPU path.
FEX still needs checked 32-bit instruction fetch and all memory/atomic/string
paths; Wine still needs guest-pointer syscall/callback marshalling and process
state, followed by the 32-bit graphics/audio/input bridges. Portal 2 remains
unplayable until those gates and actual phone gameplay pass.
