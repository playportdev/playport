# Portal 2: checked scalar call-preservation prerequisite

## Verdict

A manually constructed real FEX ARM caller now invokes the compiled checked
helper against separated backing and preserves all live native-32-bit FEX
registers/flags. Both the ordinary helper and a deliberately destructive
AAPCS64 wrapper pass 6381 calls, with seven caller corruption controls rejected.
This closes the bounded spill/call/restore prerequisite, **not memory IR
lowering or guest fault delivery**.

**Portal 2 remains unplayable. Not checked on the phone.** No upstream patch,
pin, app, IPA, build record, runtime switch or product entry point changes.
There is no device-run IPA SHA256. No background process was started.

## Boundary and method

`build/guest32/scalar_call_audit.py` links `scalar_call_emit.cpp` against the
same real native FEX archives and compilation database as the prior emission
audits. Context layout stays non-iOS/non-EC throughout; no FEX method is
replaced and no upstream source is edited. The fixture uses Arm64Emitter's
actual `SpillStaticRegs`, `PushDynamicRegs`, `PopDynamicRegs` and
`FillStaticRegs` implementations with ordinary, **not preserve-all**, ABI.
SVE, AVX and AFP are disabled in this bounded native context.

The emitted caller executes from high RX memory in the hash-locked ARM
simulator. Its helper is the unchanged checked C implementation compiled as
freestanding ARM64, with the same sparse high backing and private C metadata
fixture as the [helper gate](2026-10-02-guest32-scalar-arm-helper.md). There are
no numeric guest-address mappings. Hooks only observe instructions/accesses
and stop at capture/error: no helper return, translation, backing operation,
register restoration or fault rescue is fabricated by a hook.

A high native descriptor supplies space, already computed 64-bit address,
operation and value. This deliberately does **not** test x86 effective-address
formation, RA integration, operand provenance selection, instruction decode
or memory-handler replacement. Native CPU-state pointers are used only by
FEX's real spill/fill code, never sent through the guest helper as operands.

The packed result is retained in x3 (TMP4), the temporary documented by FEX to
survive spill boundaries. After all live state is restored, a non-flag-setting
status extraction/CBNZ selects destination publication plus a native success
marker, or a native fault-PC record and stop. A store's unchanged returned
value keeps EAX unchanged. The fault PC is a fixed fixture value `0x401234`,
**not a dispatcher exception or a recovered decoded instruction PC**. Capture
is a BR through a temporary, so the live dynamic x30 must survive the helper's
BLR/return rather than being used as a fixture return address.

## Coverage and corruption controls

6381 cases per caller retain all 6327 compiled-helper scenarios plus 54
rejections of the new native caller-code/state/descriptor addresses. They
cover all committed guest permission pairs, decommitted neighbors, unaligned
byte/word/dword loads/stores, cross-page checks, low and top-of-space rejection,
exact final-byte fits, wide/native addresses, malformed operations and
poisoned/null spaces across three granule metadata values. Granules are fixture
metadata, not three actual ARM VM configurations.

Each call must enter the actual helper exactly once with the expected arguments
and 16-byte-aligned SP. Independent byte/status checks require complete-width
backing census on success and no backing access on failure. Full backing
snapshots, native argument/code canaries and untouched CPU-state bytes outside
the real static spill slots are checked. Stack accesses are bounded to the
4 KiB below entry SP, with surrounding byte canaries and exact restored SP.
CPU-state spill slots intentionally change even on rejection: this is normal
FEX native state publication, not a claim that all native bytes stay unchanged.

All 24 static/dynamic allocated GPRs, full 128 bits of all 30 allocated SIMD
registers, x25 (call-return stack), x28 (STATE) and NZCV survive, except successful
EAX loads. Guest GPR and PF/AF inputs are zero-extended; dynamic registers and
full SIMD values are poisoned. x0-x3 and v0-v1 are emitter temporaries, not
live guest allocations. x18 is not part of this native 32-bit register budget.

`scalar_call_clobber.S` executes the actual helper first, then overwrites all
AAPCS64-volatile GPRs other than the returned x0, all volatile SIMD registers,
the high 64 bits of v8-v15, and NZCV. It respects callee-saved GPRs and low
v8-v15 halves. This ensures success cannot depend on this Clang build happening
to avoid vector registers or preserving particular volatile GPRs.

Seven separately emitted broken callers fail for their intended observable
reason (not a compile error or arbitrary simulator fault):

1. Omit static spilling: live GPR mismatch.
2. Omit dynamic save/restore: live GPR mismatch.
3. Omit static SIMD preservation: full-vector mismatch.
4. Publish the destination before restoration: successful load is lost.
5. Omit NZCV restoration: flag mismatch.
6. Continue without checking status: rejected call takes success marker.
7. Record the wrong guest PC: fault-record mismatch.

## Validation

```sh
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/scalar_call_audit.py .work/guest32/decode-audit/native
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/scalar_call_audit.py .work/guest32/decode-audit/native --sanitize
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/scalar_arm_audit.py
python3 build/guest32/scalar_access_audit.py
./pp test --quick
python3 -m py_compile build/guest32/scalar_call_audit.py build/guest32/scalar_arm_audit.py
clang-format --style=file:.work/run/fex/.clang-format --dry-run --Werror \
  build/guest32/scalar_call_emit.cpp
git diff --check
```

All pass. ASan/UBSan instruments the C++ fixture, not the existing FEX archives,
compiled ARM helper or simulator. The helper regression retains 6327 cases and
seven corruption controls; host helper regression retains 7203 cases,
sanitisers and six controls. Quick name/secret/pin/series, tooling and host C
checks pass. Optional native/simulator dependencies remain outside CI.

Simulator version is Unicorn 2.1.4; native library SHA256 remains
`ddb196ec82b52e502c18e4a34478bf7b9f61c83c2ebaa95c74d8ded45a95da9c`.
The runner prints fixture/helper/g32/archive and ELF hashes. Logs are
`.work/guest32/scalar-call-{optimized,sanitized,helper-regression,host-regression,quick}.log`.
Caller exports and native binaries stay in `.work/guest32/scalar-call/`, and
ARM ELF/object/header artifacts in `.work/guest32/scalar-arm/`.

## Next boundary

Wire a bounded guest scalar memory IR operation into real FEX lowering using
this checked call sequence, with explicit native-pointer bypass, allocated
operand/destination liveness, guest effective-address arithmetic and decoded
faulting PC retention. Test the decoded block, including successful continuation
and rejected non-continuation, against separated backing. The fixture's native
fault record is not adequate product fault delivery.

Other memory families, concurrent VM changes, ARM64EC/iOS interop, Wine i386
marshalling, graphics/audio/input and Portal 2 menu/play/save/reload remain
unresolved. Phone integration must use the UI and include a Hollow Knight
regression play.
