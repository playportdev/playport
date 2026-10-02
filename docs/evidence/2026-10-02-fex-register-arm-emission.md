# Portal 2: register-only ARM machine-code emission gate

## Verdict

The real series-applied native FEX ARM backend emits all 144 prefixes from the
[allocated register-only IR audit](2026-10-02-fex-allocated-register-ir.md).
Independent machine-word analysis matches the x86 register oracle for all
18432 input/block combinations. Entry, unlinked exit and guest-PC metadata
checks pass. This advances the bounded host gate from allocated IR to checked
ARM machine code, **not execution**.

**Portal 2 remains unplayable.** No emitted ARM instruction, dispatcher or exit
linker executes. This does not validate the shipped ARM64EC ABI, guest-memory
translation, a Wine bridge, game loading or playability. No upstream patch,
pin, app/runtime source or build record changed. No IPA was built or installed;
**not checked on the phone**, with no device-run IPA SHA256. This optional host
experiment is not another entry point into the app.

## Real emission and independent checker

`native_decode_audit.py --emit` implies `--allocate`, retaining real decoder,
opcode dispatch, default optimization/RA and both existing IR oracles. A real
native Arm64JITCore configures the allocation pass itself, emits each block
with CompileCode and copies it from temporary storage into the real shared
code buffer. The context owns a real Dispatcher and the thread owns real
LookupCache and PassManager objects. No FEX method, allocator or named-symbol
resolver is replaced. Native layout flags remain uniform; the existing
ABI-neutral byte-source seam is enabled only for Frontend.cpp.

`native_code_oracle.h` is separate from the IR evaluator and uses no FEX
encoding helpers. It analyzes only MOVN/MOVZ/MOVK, unshifted register-MOV and
bitmask-immediate MOV aliases, BFI and UBFX machine words. W writes zero-extend;
bitmask immediates are decoded by element width, rotation and replication.
Only the eight architectural static GPRs begin initialized. Temporaries must
be written before use and register numbers must belong to the native backend
budget (or its explicit scratch register). STATE/SP, memory, flags, helper,
vector, atomic and unexpected branch instructions are not silently ignored.
The comparison establishes low-32-bit guest register behavior only, not
upper-64-bit CPU-state semantics or correctness of dispatcher fill/spill.

The rest of the generated block is structurally checked, rather than omitted
from the audit:

- One guest-valued entry and the ADR/header-store prologue; no TF, interrupt or
  spill code is accepted in this native configuration.
- Monotonic guest/debug markers, with no assumption that they are architectural
  state barriers after RA; complete sequence prefixes remain the oracle unit.
- One final branch into an aligned unlinked thunk, its instruction/literal
  layout, zero HostCode, exact exit guest RIP and caller-relative offset.
- The linker literal equals the real Dispatcher's nonzero linker address.
- Bounded tail fields, SingleInst/guest size and independently decoded small
  packed host-PC/guest-RIP deltas agree with every debug marker. Unexpected
  metadata formats fail rather than being skipped.

Execute-only separated guest instructions cross a page at each of three PCs
(`0x400ffe`, `0x900ffe`, `0xffff0ffe`) and three host granules (native, simulated
16 KiB, simulated 64 KiB). All 16 prefixes retain unchanged guest bytes, deny
ordinary data reads and release their ownership. The same 128 zero/all-one/
deterministic-random input states used by the IR oracle also check the emitted
machine words. ESP and EBP are treated only as register values, with no stack
or guest data-memory accesses.

## Validation

Using the assertion-enabled native build from the
[allocator evidence](2026-10-01-fex-native-allocator.md#reproduction):

```sh
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --emit
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --emit --sanitize
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --allocate
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --allocate --sanitize
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --ir
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --ir --sanitize
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --sanitize
./pp test --quick
```

All modes pass. ASan/UBSan and leak detection cover the test, machine checker,
frontend, adapter and g32; FEX archives containing the backend, passes,
dispatcher and opcode handlers are **uninstrumented**. Source/archive hashes
and output are in `.work/guest32/separated-emission/{optimized,sanitized}.log`;
regression and quick-test logs are alongside them. Series-applied Frontend.cpp
SHA256 remains
`714aee4d5ffc2c35fbfdc5f881bf18f34ce4249b296d1a54511e6ca383213ec1`.

Six private negative controls corrupt emitted code **after both IR checks**:
a MOV literal, a fixed-register destination, a replacement memory instruction,
the exit branch target, the exit guest-RIP literal or packed RIP metadata.
All abort in the independent machine/structure checker (SIGABRT). The script,
copies and logs stay in `.work/guest32/separated-emission/negative-controls*`;
tracked/upstream sources are not corrupted.

`pp test --quick` passes all gates, 480 tooling tests and the host C suites.
Python syntax compilation, FEX-style clang-format and git whitespace checks
pass. Swift tests and an ARM64EC rebuild were not requested: only optional
host-audit sources changed. All processes ran in the foreground and exited;
no background process was started.

## Integration findings and next gate

Even offline CompileCode needs a real Dispatcher: InsertNamedSymbolLiteral
resolves the exit-linker address during emission, before any block executes.
The initial scratch harness omitted it and faulted at that named-symbol
resolution; constructing the real dispatcher fixes the missing setup without
inventing a placeholder address.

InternalThreadState uses NonMovableUniquePtr, whose assignment releases the
incoming pointer but does **not** destroy a previously owned object. An initial
per-prefix PassManager assignment leaked 141 managers; sanitizer validation
caught it. Owning one manager per thread, as the runtime does, eliminates the
leaks and passes all 144 prefix pipelines. This is a harness ownership repair,
not an upstream pointer-container change.

The next bounded gate is actual register-only block execution on an ARM target
or simulator with explicit static-register inputs and a checked exit capture.
The current code only validates initial unlinked exit structure: native helper
calling, linker backpatching, dispatcher filling/spilling, exceptions, code
publication/cache coherency and concurrent invalidation remain untested. Any
eventual phone experiment must be exposed through the developer UI. Scalar/
stack/vector/string/atomic guest memory, native CPU-state pointer provenance,
auxiliary code readers and i386 Wine/graphics/audio/input integration remain
separate blockers. Nothing here supports a Portal 2 menu or gameplay claim.
