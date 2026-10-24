# vkd3d descriptor elapsed diagnostics (PLA-431)

Run `build/vkd3d-descriptor-test/run.sh` after reconstructing the vkd3d tree with
`pp build`. Optional arguments select the source tree and repository-local output
directory. `CC=clang` tests the same production helper with clang. The runner
links `libs/vkd3d/vkd3d_descriptor_stats.c`, not duplicated accounting formulas;
it uses deterministic clock injection only in the test executable, and bounds
execution with `timeout`. It also saves optimized disabled-guard assembly.

Fixtures cover inclusive/immediate-child/exclusive/outermost thread sums,
standalone copies, repeated same-operation nesting, exclusion inheritance,
work/failure counts, explicit early-return/end-once behavior, two threads,
devices/mixed-device rejection, depth overflow, saturation, invalid frequency,
failed/backwards/noncontained clocks, equal timestamps, capture boundaries,
calibration isolation, report throttling/final reporting and callback failure.
The reviewer regressions `10;150..200;30..40;100` and overlapping siblings
`10;20..50;40..60;100` reject timing and propagate errors through deeper ancestors.
A valid capture clock/quiescent boundary does not override operation errors.

For ASan/UBSan, compile the same fixture/helper with `-fsanitize=address,undefined
-fno-omit-frame-pointer -O1`, then run under a bounded timeout. No Vulkan, Wine,
phone, CPU-clock bridge or runtime activation interface is required by this suite.
Real descriptor-copy semantics, Windows QPC failure behavior in Wine/iOS, effective
phone precision, logging I/O failure and rendering remain integration/device gates.

The optimized fixture's distro GCC **and clang** introduce ordinary stack-canary
TLS access before the guard because the scope is an address-taken local. This is
instrumentation-induced compiler/security/prologue overhead, not diagnostic TLS
or original descriptor work. Do not disable stack protection to hide it. Production
ARM64EC/i386 objects must also be inspected with their actual build flags: no
**diagnostic** TLS/clock/counter operation may execute on the disabled branch.
Stack setup/zeroing, branches and code/layout effects are not zero overhead.

See `docs/evidence/2026-10-23-vkd3d-descriptor-cost-probe-host.md` for exact build,
assembly, schema and coverage limits. Independent review precedes parser/integration;
owner save/scene/window coordination, calibration/controls and human gameplay follow
separately. A2 remains gated.
