# Portal 2: separated-memory full decoder gate

## Verdict

The **real series-applied FEX frontend now decodes synthetic 32-bit instructions
from separated guest memory** with a real ContextImpl and opcode tables.
Guest PCs stay below 4 GiB, while instruction bytes come from high backing.
Immediate operands, multi-block control flow and full-width executable checks
pass at native, simulated 16 KiB and simulated 64 KiB host granules.

**Portal 2 remains unplayable.** This is full instruction decoding, not IR
execution, a JIT port, Wine marshalling or a Windows runtime. No game image
is decoded or executed. No IPA was built or installed; **not checked on the
phone**, with no device-run IPA SHA256.

## ABI-neutral test seam

The previous attempt enabled FEX_IOS_HOST only for Frontend.cpp, changing the
ContextImpl layout relative to native libraries. That abort happened before
any decoding. The new `patches/fex/0015` instead provides the opt-in compiler
macro `FEX_TEST_DECODER_BYTE_SOURCE` solely in the byte-source method. It adds
no fields, platform macro, CMake option, app entry point or runtime switch.
No shipped target enables it. The ordinary iOS byte-source path is retained.

The audit recompiles the complete frontend with this test macro and links its
object before the ordinary FEX archives. All layout/configuration flags remain
native and identical to the context and test. Only the test's external byte-source
callback is supplied; no context, decoder, table, allocator or instruction
implementation is replaced. The seam returns a guest InstStream and a separate
AdjustedInstStream. Real PeekByte and ReadData still call CheckRangeExecutable
with the complete guest access width before reading backing.

The callback loans the first executable byte using `g32_translate`; contiguous
4 GiB backing supplies subsequent bytes **only after the real decoder's width
checks**. A failed loan returns the unmapped guest pointer, which must never be
dereferenced. VM changes and decoding are serialized in this single-threaded
test, and range caches are explicitly reset after VM changes. This is not a
concurrent lifetime API or a production memory adapter. It does not integrate
`InvalidateThreadCachedCodeRange` with a live guest VM.

## Reproduction

Use the native CMake configuration from the
[allocator evidence](2026-10-01-fex-native-allocator.md#reproduction), then:

```sh
./pp build --to fex
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --sanitize
./pp test --quick
```

The runner requires a repository-local native build, disabled allocator,
x86 host debug and FEX assertions. It refuses FEX_IOS_HOST and a source lacking
the test seam. It builds/links real FEXCore, FEXCore_Base, JemallocDummy, cephes,
softfloat, fmt and xxhash using the real compilation database. Test assertions
are enabled even for release compilation. Sources/archives are hashed in logs.
Generated files stay in `.work/guest32/separated-decoder/`.

`--sanitize` instruments the complete frontend, test adapter and g32 with
ASan/UBSan (fatal on errors); **other FEX archives remain uninstrumented**.
The audit is optional, not part of CI: it requires a prepared native FEX tree.

## Validated cases

Each of the three host granules passes:

- `B8 78 56 34 12` starts two bytes before a guest page edge. A native-readable
  but non-executable neighboring page yields `PARTIAL_DECODE_INST`, zero block
  size and the original guest fault PC. Starting on that neighbor instead yields
  `NOEXEC_INST`. Neither failure has a valid instruction table entry.
- Making the neighboring page execute-only and resetting the cache yields a
  five-byte MOV with literal `0x12345678` and destination EAX. `g32_fetch` agrees;
  ordinary `g32_read` remains denied.
- All eight 32-bit GPR destinations and 32-bit immediates match independently
  specified encoding values. Operand-size prefix plus imm16 and imm8 cases
  exercise ReadData widths 2 and 1 as well as prefix/opcode peeks.
- A conditional branch explores both successors: three successful blocks,
  five instructions, expected block entries/sizes and immediate literals.
  Every reported block/instruction PC remains guest-valued.
- Revocation of EXEC followed by cache reset rejects a formerly decoded MOV;
  restoring EXEC allows it again. Decommit rejects the cross-page immediate
  and the neighbor; release and guest null produce NOEXEC.
- A MOV opcode at `UINT32_MAX` yields PARTIAL_DECODE rather than wrapping its
  immediate to guest zero or reading beyond backing.

Disk cache, SMC, relocation-section lookups, auxiliary code readers and JIT are
outside this gate. The syscall handler aborts on syscall/section lookup rather
than fabricating support. CS is explicitly 32-bit and config Is64BitMode is
false. No Wine process state or syscall implementation is present.

## Compatibility and checks

- Optimized and ASan/UBSan decoder audits: pass all three granules.
- `pp test --quick`: passes name/secret/pin/patch gates, all 480 tooling tests
  and host C suites; Swift tests were not requested. Python syntax compilation,
  C++ formatting with FEX's clang-format style and `git diff --check` pass.
- ARM64EC DLL rebuild and pipeline machine-type check: pass. SHA256:
  `9454e98fdb20f272779eabc89ffecac0937bc211aab1c75c1ad501e58bc8dd9f`.
- Native and actual ARM64EC frontend preprocessed tokens before/after the patch
  are identical after normalizing assertion source-line numbers (and
  line-derived ScopedAccumulation names). No test macro is in ordinary flags.
- Native/test-seam layouts match: SharedCodeBufferManager 24 bytes,
  ContextImpl 1488 bytes, FrontendAllocator offset 968. No iOS layout is mixed
  into the native context.
- Series-applied Frontend.cpp SHA256:
  `714aee4d5ffc2c35fbfdc5f881bf18f34ce4249b296d1a54511e6ca383213ec1`.

Logs and static preservation script are under
`.work/guest32/separated-decoder/`: `arm64ec-build.log`, `optimized.log`,
`sanitized.log`, `preservation.log`, `preservation.py`, `quick-test.log`.
The patch is stored in format-patch form and applied through the pipeline;
upstream sources were not edited in place and no pins or app/Wine build records
changed. All commands ran in the foreground and exited; no background process
was started.

## Next smallest execution gate

Decoding is no longer the first execution blocker. Validate real decode-to-IR
for a bounded register-only 32-bit sequence, keeping guest PCs and reporting
exact register/immediate semantics. Do not jump from this synthetic frontend
gate to a game launch. Distinct guest/native memory provenance, ARM execution,
checked scalar/stack operations, vector/string/atomic coverage and Wine pointer
marshalling remain mandatory. The existing
[integration inventory](2026-10-01-guest32-fetch-boundary.md#concrete-integration-surfaces)
still applies; the test seam is not a global fix for other code-byte readers.
