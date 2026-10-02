# Portal 2: native FEXCore build prerequisite

## Verdict

The series-applied **native FEXCore static library now builds**, including the
full frontend and all ten opcode-table sources, without enabling FEX_IOS_HOST.
The ARM64EC DLL also builds and passes the pipeline's machine-type check.
This repairs the two Core.cpp portability failures from the preceding attempts.

**Portal 2 remains unplayable.** No full instruction decode, IR, JIT or guest
execution was performed. No IPA was built or installed; **not checked on the
phone**, with no device-run IPA SHA256. Native library linking is not yet
validated: an additional allocator build blocker was found, described below.

## Patch contract

`patches/fex/0012`:

- Guards callback-entry and FFS reporting with FEX_IOS_HOST, matching the
  capture buffers' declarations and definitions.
- Guards call-return reset timing and timed reporting with
  ARCHITECTURE_arm64 or ARCHITECTURE_arm64ec. ARM hosts retain their existing
  counter-register measurements and reports; non-ARM hosts use the original
  untimed reset report, not fabricated zero timings.
- Leaves the full-size VirtualDontNeed call, early null/base checks and
  reset/site census unconditional. No predictor clearing is removed.

The candidate was made from scratch copies, added to the patch series, and
applied through the build pipeline. No upstream source was edited in place,
no pins moved and no repository commits were made in this iteration.

## Reproduction and validation

```sh
./pp build --to fex
cmake -S .work/run/fex -B .work/guest32/decode-audit/native -G Ninja \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_BUILD_TYPE=Release -DENABLE_X86_HOST_DEBUG=ON \
  -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF -DENABLE_LTO=OFF \
  -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
  -DENABLE_CCACHE=OFF -DENABLE_OFFLINE_TELEMETRY=OFF \
  -DENABLE_ASSERTIONS=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
cmake --build .work/guest32/decode-audit/native --target FEXCore FEXCore_Base -j 6
./pp test --quick
```

The iteration reused the native configuration established in the preceding
attempts. Both FEXCore and FEXCore_Base build successfully. The native archive
build does not check unresolved references at executable link time.

A preprocessor check of the complete ResetCallRetStack function before/after
0012 finds identical whitespace-normalized token streams for both ARM macros,
with and without FEX_IOS_HOST. On the native x86 macro, the function contains
exactly one full-size VirtualDontNeed call and retains census updates, but has
no ARM counter instructions or timing fields. This is a static preservation
check, **not** a run of predictor reset on either platform.

ARM64EC DLL SHA256:
`07e0a9a17a1b7d98b6ef9516987d6c3a8fc802296ef428a598c226ffa34756d7`.

Quick host tests pass the name/secret/pin/patch gates, all 480 tooling tests
and host C suites; Swift tests were not requested. `git diff --check` passes.
The build stopped before staging, so committed app/Wine build records did not
change. The pre-existing FEX External/rpmalloc submodule modification remains
untouched.

Logs and scratch source copies are in `.work/guest32/native-portability/`:
`arm64ec-build.log`, `native-build.log`, `native-base-build.log`,
`preprocessor-check.log`, `quick-test.log`. All commands were foreground calls
and have exited.

## Additional linking prerequisite (not repaired here)

A smoke program was prepared to call the real linked native ResetCallRetStack
and check clearing and census. Its link needs FEX's allocator hooks in addition
to FEXCore and FEXCore_Base. The upstream-supported JemallocDummy target fails
before linking:

```sh
cmake --build .work/guest32/decode-audit/native --target JemallocDummy -j 6
```

`FEXCore/Source/Utils/AllocatorHooks.cpp`, in the libc-backed
`malloc_usable_size`, unconditionally calls IOS_RPM_GUARD, but both the real
guard macro and its non-iOS no-op are defined inside ENABLE_FEX_ALLOCATOR.
The disabled-allocator build therefore reports an undeclared identifier
(around line 293). This is a separate allocator-configuration defect, not a
failure of the now-built Core.cpp.
`native-allocator-build.log` records it; `reset-smoke-build.log` records the
unfinished smoke-program link. **The smoke program never ran.** Do not claim
that native FEXCore is fully linkable or that a decoder has run from these
static-library builds. No synthetic replacement allocator was substituted.

Next smallest prerequisite: repair the guard's disabled-allocator scope and
build JemallocDummy, then resume linking against the real native libraries. After
that, the [full-decoder gate](2026-10-01-guest32-fetch-boundary.md#next-smallest-execution-gate)
still requires separate guest/native byte sources, a real 32-bit CS setup,
immediate/boundary/NOEXEC tests and range-cache invalidation. Other linking and
runtime blockers remain unknown.
