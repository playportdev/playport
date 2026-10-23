# DXVK descriptor diagnostics host fixture

PLA-431; [host evidence](../../docs/evidence/2026-10-23-dxvk-descriptor-cost-probe-host.md).
After reconstructing DXVK with patch 0006:

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
