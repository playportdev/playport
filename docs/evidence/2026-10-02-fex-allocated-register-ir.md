# Portal 2: optimized and allocated register-only IR gate

## Verdict

The real series-applied FEX default optimizer/register-allocation pipeline now
passes an independent 32-bit register oracle for all prefixes of the two
[register-only sequences](2026-10-02-fex-register-ir.md). This advances that
host-audit gate from pre-optimization SSA to verified physical-register IR.

**Portal 2 remains unplayable.** No ARM instruction is emitted or executed, no
Windows API bridge exists here, and this is not full ContextImpl::GenerateIR or
game loading. No app/runtime code, upstream patch, pin or build record changed.
No IPA was built or installed; **not checked on the phone**, with no device-run
IPA SHA256. This optional host audit is not another entry point into the app.

## Real pipeline and bounded checker

`native_decode_audit.py --allocate` implies `--ir`, retaining the real decoder,
opcode dispatchers, separated-memory byte-source adapter and pre-optimization
checks. After Finalize it constructs the real PassManager, configures its RA
pass, and runs the default pipeline: x87 stack optimization, dead-flag
elimination, constrained register allocation and assertion-enabled IRValidation.
O0 is explicitly off and `MADEIRA_NO_DFE` must be unset. No FEX method or pass
is replaced.

A non-emitting subclass of the real Arm64Emitter supplies the same register
budgets used by the native ARM backend's 32-bit mode. Its constructor has no
code buffer and emits nothing. This avoids hardcoding counts or accidentally
using an unconfigured RA pass. It does **not** establish correctness of the
shipped ARM64EC register budget or its calling convention.

The offline checker has separate SSA and physical-register storage. After RA,
operands are read from bounded GPR/GPRFixed indices; temporary registers begin
invalid and only the eight architectural GPRs are initialized. i32 writes
zero-extend and i64 bit inserts retain bits. Coalesced writes to fixed registers
update architectural state even when StoreRegister has disappeared. Inline
entrypoint offsets remain checked guest-PC IR references, not physical register
operands. Copy is the only newly accepted operation. Unexpected memory, flags,
spill/fill, vector, helper or other operations abort rather than being ignored.
The model establishes low-32-bit register behavior only, not native CPU-state
storage or upper-64-bit runtime semantics.

RA can coalesce stores and merge operations across GuestOpcode debug markers.
Those markers are therefore not assumed to be architectural-state barriers
after allocation. Each nonempty sequence prefix is separately decoded, emitted,
optimized, allocated and checked at its ExitFunction. The original per-instruction
oracle still checks every pre-RA boundary. Every prefix must reduce its number
of explicit LoadRegister/StoreRegister operations, proving the audit actually
exercises static-register coalescing rather than rechecking an unchanged graph.

## Coverage and results

At native, simulated 16 KiB and simulated 64 KiB host granules, all 16 prefixes
(nine all-GPR MOV instructions and seven partial-register MOV/MOVZX instructions)
run at each of `0x400ffe`, `0x900ffe` and `0xffff0ffe`. This yields:

- 144 prefix pipelines, with the first instruction crossing a guest-page boundary;
- 128 initial register states per pipeline (zero, all-one, deterministic random);
- 18432 complete register-state comparisons on **each** side of RA, plus
  84096 pre-RA instruction-boundary comparisons;
- checked guest-valued metadata and exit PCs, unchanged execute-only backing
  bytes, denied ordinary data reads and released decoder/emitter/guest ownership.

Optimized and ASan/UBSan runs pass all three granules. Sanitizers cover the
frontend, adapter, checker and g32, **not** the FEX archives containing opcode
handlers, optimization, RA, validation and the non-emitting emitter constructor.
Both earlier decoder and pre-optimization IR audits still pass in both modes.

Three private negative controls corrupt the generated graph **after RA**, after
all pre-RA checks have passed: a constant's literal, its assigned fixed-register
destination, or the inline exit offset. All three are rejected by checker
assertions (SIGABRT). Copies, scripts, binaries and assertion logs remain in
`.work/guest32/separated-ra/`; tracked or upstream sources were not corrupted.

## Reproduction and validation

Use the existing assertion-enabled native build from
[the allocator evidence](2026-10-01-fex-native-allocator.md#reproduction):

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --allocate
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --allocate --sanitize
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --ir
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --ir --sanitize
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --sanitize
./pp test --quick
```

Audit/source/archive hashes and output are recorded in
`.work/guest32/separated-ra/{optimized,sanitized}.log`; regression, negative-control
and quick-test logs are alongside them. The series-applied Frontend.cpp SHA256
remains `714aee4d5ffc2c35fbfdc5f881bf18f34ce4249b296d1a54511e6ca383213ec1`.

`pp test --quick` passes all gates, 480 tooling tests and the host C suites.
Python syntax compilation, FEX-style clang-format and git whitespace checks
pass. Swift tests and an ARM64EC rebuild were not requested: only optional
host-audit sources changed. All commands ran in the foreground and exited;
no background process was started.

## Integration findings and next gate

A future offline backend audit must distinguish physical-register operands from
inline IR references even after PostRA is true. It must also model implicit
architectural writes from coalesced operations; counting StoreRegister nodes
would miss most of this pipeline's register effects.

The next bounded gate is real ARM machine-code emission for these register-only
cases, with structural guest-PC/exit and register checks before execution on an
ARM target. Any eventual phone experiment must enter through the developer UI.
Scalar/stack/vector/string/atomic guest-memory access, CPU-state pointer
provenance, concurrent invalidation, SMC/cache/diagnostic readers, Win32 nested
pointers and i386 graphics/audio/input still need separate integration. No
result here supports a Portal 2 menu or gameplay claim.
