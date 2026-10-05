# Portal 2: real native FEX context link prerequisite

## Verdict

The real disabled-allocator **ContextImpl now links, constructs and destroys**
with the native FEX libraries, without replacement context or allocator
implementations. This resolves the `rpm_cas_snapshot_take` link blocker found
when moving beyond the [reset-only audit](2026-10-01-fex-native-allocator.md).
The ARM64EC DLL also builds and passes the pipeline's machine-type check.

**Portal 2 remains unplayable.** No instruction decoding, separated-memory
adapter, IR, JIT or guest execution was performed. No IPA was built or installed;
**not checked on the phone**, with no device-run IPA SHA256.

## Repair and regression contract

`patches/fex/0014` guards both the rpmalloc snapshot POD declaration and its
CompileBlock diagnostic consumer with ENABLE_FEX_ALLOCATOR. The existing
CB_SUMMARY report remains unconditional. Enabled-allocator builds retain the
snapshot and its reporting unchanged; disabled builds no longer reference an
absent provider. No fabricated snapshot stub is supplied.

Crucially, the allocator option previously defined this macro **only for
JemallocLibs**, not Core.cpp. The patch therefore also sets a source-local
Core.cpp compile definition when the CMake allocator option is enabled.
Guarding Core.cpp alone would silently remove the shipped diagnostic. A
source-local definition avoids altering unrelated FEX sources' macro branches.

The optional native_link_audit test now constructs and destroys a real context
configured for 32-bit mode. Its vtable retains CompileBlock at link time, making
the original undefined symbol reachable even with section garbage collection.
It builds and links the ordinary cephes and softfloat archives, plus fmt and
xxhash, alongside the original three FEX libraries. Allocator and full predictor
reset/census tests remain intact. This is a link prerequisite, not a decoder
or emulation gate; it does not invoke CompileBlock.

No pins or upstream sources were edited in place. The candidate was prepared
in a scratch git tree, emitted with git format-patch, added to the series and
applied by the build pipeline. The build stopped before staging, leaving app
and Wine build records unchanged. The pre-existing rpmalloc submodule build
modification remains untouched.

## Reproduction and results

Use the native configuration in the
[allocator evidence](2026-10-01-fex-native-allocator.md#reproduction), then:

```sh
./pp build --to fex
python3 build/guest32/native_link_audit.py .work/guest32/decode-audit/native
./pp test --quick
```

- The native test passes real ContextImpl construction/destruction, allocator
  hooks, 1024 full predictor resets and reset/site census checks. No substitute
  FEX implementations are linked.
- The identical test linked with pre-patch Core.cpp fails **solely** on
  rpm_cas_snapshot_take. This verifies the repair against the actual failing
  configuration, rather than just checking archive creation.
- Complete enabled-allocator Core.cpp preprocessed token streams before/after
  are identical under the real ARM64EC flags, with and without FEX_IOS_HOST,
  after normalizing whitespace and line-derived ScopedAccumulation variable
  names. The only unnormalized differences are those local variable names
  shifted by the new directives. This is static preservation, not an ARM
  runtime test.
- Object symbol checks confirm that ARM64EC Core.cpp retains the rpmalloc
  snapshot reference, while the disabled-allocator native object has none.
- Quick host tests pass name/secret/pin/patch gates, all 480 tooling tests and
  host C suites. Swift tests were not requested. `git diff --check` passes.
- ARM64EC DLL SHA256:
  `65573d98530b4cffc0acc28d64657dd7f5619e161807ccaccf80cfc03cbdb6ca`.
- Series-applied Core.cpp SHA256:
  `bfa154323a726c5c9f2d52c26038ee5bf66e418fb7d9c7d4cc47f978608fb5b6`.

Logs and the before/after validation script are under
`.work/guest32/native-context/`: `arm64ec-build.log`, `link-audit.log`,
`preservation.log`, `before-link.log`, `provider-symbols.log`, `validate.py`,
`quick-test.log`.
All commands ran in the foreground and exited; no background processes were
started.

## Next gate

Resume the [full-decoder gate](2026-10-01-guest32-fetch-boundary.md#next-smallest-execution-gate)
with the real series-applied context and decoder: 32-bit CS mode, separated
native/guest byte sources, immediate and boundary reads, NOEXEC rejection and
executable range-cache invalidation. Native-context linking no longer blocks
that experiment, but other decoder or runtime blockers remain unknown. This
work adds no shipped Win32 game capability.
