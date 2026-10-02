# Portal 2: candidate checked scalar helper ABI

## Verdict

A host-only candidate native C helper now implements checked byte/word/dword
scalar accesses with an explicit value/status return contract. All 7203
standalone cases, six helper corruption controls, real FEX scalar pre/post-RA
checks and simulator regressions pass.

**Portal 2 remains unplayable.** The helper is not installed in FEX or linked
into the app; no emitted block calls it. This adds no runtime/app switch,
upstream patch, pin, IPA or changed build record. **Not checked on the phone**;
there is no device-run IPA SHA256.

## Scope and contract

The [raw-emission baseline](2026-10-02-fex-scalar-arm-emission.md) still accesses
numeric guest addresses directly. This chunk implements only the next gate's
C helper side, not call lowering or exception delivery.

`build/guest32/scalar_access.{h,c}` defines `g32_scalar_access(space, address,
operation, value)`:

- `space` is the only native pointer; a **64-bit** operand address rejects
  high/native addresses and dirty upper bits before narrowing. Guest address
  arithmetic must already have wrapped to 32 bits. A lowering must not conceal
  bad native provenance with an unconditional truncation at helper entry.
- The operation is width 1, 2 or 4, optionally ORed with a store bit. Other
  encodings reject without access. No CPU-state pointer, source/destination
  buffer pointer or borrowed backing pointer crosses this interface.
- The packed 64-bit result contains `g32_result` in bits 63:32 and the value in
  bits 31:0. Successful loads merge only their low byte/word/dword into the old
  destination. Successful stores and all failures return the input unchanged.
- Little-endian bytes are explicitly assembled/disassembled, independent of
  native integer byte layout. This replaces the scalar inspector's previous
  host-endian `uint32_t` buffer copies, without claiming a big-endian test run.
- The existing serialized g32 read/write API checks the **complete** width and
  every page's permissions before copying. Rejected operations change neither
  guest bytes nor VM metadata, including denied cross-page stores. No pointer
  loan survives the call.

This is an **ordinary native C ABI**, not a FEX preserve-all helper convention.
The helper does not touch architectural state or flags directly. Future emitted
call sites must preserve live caller-clobbered GPR/FPR/flags, inspect status
before publishing a load result or continuing, and deliver a fault at the guest
PC. Return-value preservation alone cannot prove emitted-call preservation.
The header documents those obligations explicitly. Only low-register scalar
MOV/FNSTCW-style stores are in scope; atomics, other memory families,
concurrency and ARM64EC interop remain absent.

## Integration and tests

`pp test --quick` now includes `scalar_access_test.c`, without requiring FEX or
the optional simulator. Across native, 16 KiB and 64 KiB host granules, 7203
calls cover:

- all 64 read/write/execute permission pairs on neighboring guest pages;
- widths 1/2/4, loads/stores, aligned/unaligned and page-crossing accesses;
- concrete little-endian and partial-register results, complete byte canaries
  and unchanged query state/ownership/permissions;
- decommitted, execute-only, unreserved and low-address rejection;
- exact top-of-space fits and multi-byte overflow rejection;
- malformed widths/bits, null spaces, wide/native backing addresses and dirty
  upper bits, native CPU-state-like canaries, and separate-space isolation.

`scalar_access_audit.py` repeats the standalone optimized and ASan/UBSan builds
and requires assertion rejection of six private mutations: native-address
truncation, store-width truncation, failure-value clobber, partial-register
clobber, big-endian stores and incorrect status packing. Compile errors or
unrelated segmentation faults do not count as passing controls. Core dumps
are disabled and all outputs stay in `.work/guest32/scalar-helper/`.

The real FEX scalar inspector now calls this helper outside FEX for the 19584
input states both before and after optimization/RA. Independent fixture
permission, byte and result checks remain. All 585 IR controls pass; native
FXCH context pointers still bypass g32/the helper. **This does not establish an
emitted helper-call ABI.** Raw scalar simulator accesses remain identity mapped
and unchecked, precisely as in the previous baseline.

## Validation

```sh
python3 build/guest32/scalar_access_audit.py
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-allocate
python3 build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-allocate --sanitize
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --memory-simulate
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/native_decode_audit.py .work/guest32/decode-audit/native --simulate
./pp test --quick
. build/env.sh
clang -target arm64-apple-ios26.5 -isysroot "$IOSSDK" -std=c11 -O2 \
  -Wall -Wextra -Werror -c build/guest32/scalar_access.c \
  -o .work/guest32/scalar-helper/scalar-ios.o
```

All pass, including 480 tooling tests, name/secret/pin/series checks and existing
host C tests. The 153-block/19584-input raw scalar simulator and
144-block/18432-input register simulator regressions retain all corruption
controls. Clang static analysis, Python syntax, FEX-style formatting of the
modified C++ audit and git whitespace checks pass. ASan/UBSan cover the helper,
frontend, audit and g32, not FEX archives or the simulator. The iOS object is
compile-only, not hardware/ABI validation. No background process was started.

Helper source SHA256:
`cae1ca634a4c93222d5e7e31bd7ef6a4ea00d58a99c60ffae5f7a0f654cd7fb1`.
Helper header SHA256:
`8fcf469f271678a2355ab08d38526151d717be196be830db4cf3939795614dd8`.
Source/archive hashes are also printed by the audit runners. Validation logs
are `audit.log`, `fex-allocated{,-sanitized}.log`, `raw-emission-regression.log`,
`register-regression.log` and `quick.log` under
`.work/guest32/scalar-helper/`.

## Next boundary

Emit and execute a bounded scalar helper call with the real checked C helper,
not a simulator hook that merely fabricates success. Prove native CPU-state
pointers bypass translation, live-state preservation, zero-extended guest
register publication, status-based rejection before continuation and unchanged
bytes/registers on the rejection path. The shipped ARM64EC bridge and actual
iOS execution remain separate gates. Other guest-memory families, Wine
WoW64/i386 marshalling, graphics/audio/input and Portal 2 menu/play/save/reload
remain unresolved. Device experiments must enter through the product UI.
