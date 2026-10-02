# Portal 2: allocated scalar-memory and native-provenance gate

## Verdict

The real default FEX optimizer/register-allocation pipeline preserves the
independently checked scalar-address contract for all 153 graphs / 19584 input
states from the [pre-optimization gate](2026-10-02-fex-scalar-memory-ir.md).
A further nine real FXCH ST(1) graphs verify native-context pointer provenance
through lowering and physical-register reuse for 18432 TOP/tag combinations.
585 private IR corruption controls fail for their intended reasons.

**Portal 2 remains unplayable.** This is bounded offline IR analysis, not a
memory emitter, interpreter backend or guest execution. No new upstream patch,
pin, runtime/app source, IPA or build record changes. **Not checked on the
phone**; there is no device-run IPA SHA256. This optional host audit introduces
no app entry point.

## Scalar contract after RA

`native_decode_audit.py --memory-allocate` implies `--memory-ir` and remains
separate from the register-only modes. It reuses the same series-applied native
archives, ABI-neutral frontend byte-source seam and real opcode dispatch. The
native ARM backend supplies register budgets without creating or emitting a JIT.
The real default PassManager runs x87 lowering, dead-flag elimination, RA and
IRValidation, with optimization explicitly enabled. No FEX method is replaced.

The 17 existing byte/word/dword MOV and FNSTCW forms still cover base,
displacement, SIB, address-size-16, absolute and wrapping FS addresses at three
guest PCs and native / 16 KiB / 64 KiB host granules. The inspector handles SSA
before RA and initialized physical-register values after RA; inline constants
and guest exit metadata remain IR references. Fixed-register coalescing is
checked by comparing the complete architectural result, not by requiring every
original StoreRegister to survive. Unexpected operations and uninitialized
operands still fail.

Every pre/post-RA guest address, width, direction and store value matches the
independent x86 formula. Loads supply the same sentinel as the earlier gate:
this does **not** execute a FEX load. Only independently verified guest effective
addresses reach `g32_read`/`g32_write`, outside FEX. Checked permissions, full
width/boundary checks, failure preservation and unchanged neighboring bytes
remain covered. Native LoadContext offsets are validated independently and
never translated; their contained segment/control values are guest data.
The redundant FS-cache load in the pre-RA store disappears during optimization:
there is exactly one after RA, not the original two.

## Real native-memory counterexample

The actual decoded instruction is `d9 c9` (FXCH ST(1)), using the same guest-PC,
execute-only byte-source and dispatch lifecycle. Before optimization its IR
contains one F80StackXchange and **no** FormContextAddress/LoadMem/StoreMem.
After the real pipeline it contains two i64 FormContextAddress constructors,
two i128 FPR LoadMem operations and two i128 FPR StoreMem operations.
These are ordinary generic-memory IR, but their addresses are native CPU state,
not guest memory.

`native_context_ir_oracle.h` uses a strict operation whitelist and distinct data,
native-pointer and vector-identity tags. A FormContextAddress creates a native
pointer by adding `index * 16` to a synthetic high CPUState address. Loaded TOP
and FTW are plain data, not pointers. Tags follow each physical-register write:
a register that held a native pointer can subsequently hold scalar context
data, so classification cannot permanently attach to a physical register name.

For all eight TOP values and all 256 input abridged tags, the inspector checks:

- Both complete effective addresses are the independently expected native
  `CPUState.mm[TOP]` and `CPUState.mm[(TOP+1)&7]`, with 16-byte accesses.
- Only properly constructed native-pointer values reach these generic accesses;
  a low guest-valued fixed register cannot substitute for a native address.
- Distinct 128-bit slot **identity tokens**, not floating-point computations,
  swap correctly and preserve the other six slots.
- The lowered path clears C1, sets its two validity bits, leaves TOP unchanged
  and exits at the original guest PC plus two.

No IR-supplied native address is dereferenced. Tokens model only slot identity;
the test is **not x87 floating-point or empty-stack/exception correctness**.
Enumerating all tag patterns exercises the lowered tag arithmetic, not stack
fault delivery. No native address is passed to g32, and no vector guest-memory
support is inferred from this native FPR counterexample.

This verifies a bounded provenance analysis in the **test**, not new provenance
metadata in FEX. Other generic guest memory operations can use the same IR
families: neither opcode name, FPR class nor i64 width alone determines ownership.

## Corruption controls and validation

All controls mutate private real generated graphs and restore their fields.
The existing 225 pre-RA controls remain. An additional 198 allocated scalar
controls change width, native-context offsets or physical address operands;
162 allocated native controls change pointer stride/provenance, memory width,
MM displacement or context offsets. Each fails with the exact expected message,
and each post-RA graph is rechecked after restoring the field.

UBSan exposed a test-only issue with binding packed post-RA Offset fields to
`uint32_t&`. The new mutation helper copies packed fields with `memcpy` and uses
byte offsets for packed Stride/Constant members; no alignment check is disabled.
FEX sources are unchanged.

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-allocate
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-allocate --sanitize
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-ir
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-ir --sanitize
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --simulate
./pp test --quick
```

Optimized and ASan/UBSan audits pass, along with both pre-RA regressions and the
144-block / 18432-input ARM simulator regression. Sanitizers cover the audit,
frontend and g32; other FEX archives remain uninstrumented. Exceptions are
confined to test negative controls and never unwind through FEX. FEX-style
clang-format, Python syntax, mutually exclusive CLI-mode checks and git whitespace
checks pass. Quick host tests, including names/secrets/pins/series gates, pass.
No background process was started and no commit was made in this iteration.

The runner prints source/archive hashes. Frontend SHA256 remains
`714aee4d5ffc2c35fbfdc5f881bf18f34ce4249b296d1a54511e6ca383213ec1`.
Generated artifacts stay in `.work/guest32/separated-memory-ra/{optimized,sanitized}/`;
logs are `.work/guest32/memory-ra-{optimized,sanitized}.log`. Regression logs
are `.work/guest32/iteration25-{memory-ir,memory-ir-sanitized,simulate,quick}.log`.

## Next boundary

A bounded checked scalar ARM-emission gate can now build on verified allocated
guest addresses and this real native-memory counterexample. It must explicitly
preserve guest/native ownership when introducing checks, validate complete
access width before a load/store, keep native CPU-state accesses unmodified and
prove rejection paths preserve bytes/registers. This audit does not implement
that emitter or helper ABI.

Stack/vector/string/atomic guest paths, auxiliary code readers, concurrent VM
changes/code invalidation, faults, Wine i386/WoW64 nested-pointer marshalling,
graphics/audio/input and Portal 2 menu/play/save/reload remain unresolved.
ARM64EC/iOS execution and a Hollow Knight phone regression also remain required.
Any eventual phone experiment must enter through the developer UI.
