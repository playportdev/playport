# Portal 2: native FEX allocator/link prerequisite

## Verdict

The disabled-allocator **JemallocDummy target now builds**, and a host test
links real FEXCore, FEXCore_Base and JemallocDummy libraries and runs native
allocator hooks and ResetCallRetStack. This resolves the remaining allocator
build prerequisite recorded in [native portability](2026-10-01-fex-native-portability.md).

**Portal 2 remains unplayable.** No full instruction decoding, IR, JIT or guest
execution occurs. No IPA was built or installed; **not checked on the phone**,
with no device-run IPA SHA256. The link test uses section garbage collection:
it validates its reachable native code, not every symbol in the archives.

## Repair

`patches/fex/0013` removes one IOS_RPM_GUARD invocation from the libc-backed
malloc_usable_size implementation. That macro exists only inside the enabled
rpmalloc branch; libc size queries neither need nor should acquire its lock.
Every enabled-allocator guard stays intact, including rpmalloc_usable_size.
No pin, upstream source in place, runtime behavior or app build record changes.
The patch was added to the series and applied through the build pipeline.

## Reproduction

```sh
./pp build --to fex
cmake -S .work/run/fex -B .work/guest32/decode-audit/native -G Ninja \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_BUILD_TYPE=Release -DENABLE_X86_HOST_DEBUG=ON \
  -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF -DENABLE_LTO=OFF \
  -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
  -DENABLE_CCACHE=OFF -DENABLE_OFFLINE_TELEMETRY=OFF \
  -DENABLE_ASSERTIONS=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
python3 build/guest32/native_link_audit.py .work/guest32/decode-audit/native
./pp test --quick
```

The runner builds all three libraries, uses the real Core.cpp compilation
flags from the compilation database, re-enables test assertions and links
against the actual native libraries and fmt. It refuses an enabled allocator,
an iOS Core build or a build directory outside the repository's `.work`.
It prints source/archive hashes and keeps the executable in
`.work/guest32/native-link-audit/`. This optional host audit requires a
configured FEX build and is not part of the ordinary quick suite.

## Results

- Native allocator calls malloc, malloc_usable_size, free and calloc succeed;
  calloc bytes are zero. No replacement allocator implementation is supplied.
- Linked ResetCallRetStack accepts null thread/base without logging, then clears
  a fully dirtied 16 MiB reservation. Each of 1024 resets clears both newly
  dirtied end bytes; a full scan after the first and final resets is all zero.
- Real logging reports `resets=1024 bytes=16384MB per_reset=16384KB` and
  `by_site core=512 cpubackend=512 jit-rollover=0`, without ARM timing fields.
- Enabled-allocator preprocessed token streams before/after the patch are
  identical using the real ARM64EC compilation flags, both with and without
  FEX_IOS_HOST. This is static preservation, not an ARM runtime test.
- The disabled-allocator source also compiles with FEX_IOS_HOST defined on the
  native host, with no undefined fex_ios_rpm_lock/unlock references.
- ARM64EC DLL rebuild and pipeline machine-type check pass; DLL SHA256:
  `d2efdb4bb82133e9bf30cc4bce3d56d29dd153191f6569059cb02a62bfd6083f`.
- Quick host tests pass name/secret/pin/patch gates, all 480 tooling tests and
  host C suites. Swift tests were not requested. `git diff --check` passes.

Logs: `.work/guest32/native-allocator/{arm64ec-build,native-build,link-audit,preservation,quick-test}.log`.
All commands ran in the foreground and exited; no background processes started.

## Next gate

The native allocator and selected native-library link are no longer blockers.
Resume the [isolated full-decoder gate](2026-10-01-guest32-fetch-boundary.md#next-smallest-execution-gate):
use the real series-applied frontend in 32-bit CS mode, separated guest/native
byte sources, immediate and boundary reads, NOEXEC rejection and executable
range-cache invalidation. This test does not establish that the full decoder
links, nor that separated-memory instruction decoding or execution works.
