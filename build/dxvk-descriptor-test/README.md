# DXVK descriptor diagnostics host fixture

PLA-431; [host evidence](../../docs/evidence/2026-10-23-dxvk-descriptor-cost-probe-host.md).
After reconstructing DXVK with patches 0006–0007:

```sh
export PLAYPORT_BUILD=$PWD/.work
export TMPDIR=$PLAYPORT_BUILD/agent-notes/kk-parity/tmp
build/dxvk-descriptor-test/run.sh
```

Optional arguments: patched DXVK tree, output directory. The runner compiles and
executes the **real** `src/dxvk/dxvk_descriptor_stats.cpp`/header at `-O2`, with a
30-second producer bound. Fake clocks are injected only by this C++ fixture, not
by any production environment switch. Assertions exercise timing, work, nesting,
exclusions, failure/unwind, concurrency, saturation, reporting and raw calibration.
Sibling-clock regressions include the reviewer's 150..200 then 30..40 trace,
overlapping siblings, deeper ancestor invalidation, failed/backwards child reads,
recovery, and valid equal/nonoverlapping timestamps. Rejection is asserted through
operation `clock_errors`/`nest_errors` and absent valid parent timing, not capture
`clock_ok=0`. Both bad traces print their actual fields before assertions so the
fixture against 0006 shows both failures. See the
[clock-fix evidence](../../docs/evidence/2026-10-23-dxvk-descriptor-clock-fix-host.md)
for before/after results and sanitizer flags.
It also writes `disabled-path.asm` for optimized host guard inspection.

`cmdlist-disabled-path.cpp` is a compile-only ARM64EC inspection seam for the real
inline Vulkan wrappers. Compile with the production DXVK include directories and
flags from `build-dxvk/compile_commands.json`; replace the source/output/dependency
arguments rather than overwriting production objects. Inspect it together with the
actual context and descriptor-pool objects using `llvm-objdump -dr --demangle`.
The null-pointer branch must bypass diagnostic TLS, clocks, counters and work loops.

No Vulkan calls or GPU work execute here. Host `CLOCK_MONOTONIC` tests do not prove
Windows QPC/iOS clock resolution or diagnostic overhead. There is no phone driver,
gameplay harness or parser in this directory. The diagnostic remains default off;
future activation uses existing Graphics options, `PLAYPORT_DESCRIPTOR_STATS=1`.
