# Portal 2: decoder fetch boundary and execution-port audit

## Verdict

The host experiment now exercises **two unmodified FEX decoder methods** with
an experimental `g32_query` executable-range adapter and separated backing.
They correctly gate byte peeks and range checks at guest page boundaries, even
when execute-only and non-executable pages share accessible native backing.
It also reproduces the stale executable-range cache after a VM permission change
and verifies that resetting the cache restores rejection.

**Portal 2 remains unplayable.** This is not a FEX port or even a full instruction
decode: no opcode dispatcher, IR, JIT, Wine bridge or game instruction runs.
No upstream sources, pins, patches or shipped app changed. No IPA was built or
installed; **not checked on the phone**, with no device-run IPA SHA256.

The scope shifts from more loader helpers to identifying the concrete first
execution integration boundary. The existing host loader is not the current
execution bottleneck. The installed launcher and engine both have empty TLS
directories (directory 9 RVA and size are zero); another TLS helper would not
by itself advance these two images.

## Reproducible experiment

```sh
python3 build/guest32/fetch_audit.py .work/run/fex
python3 build/guest32/fetch_audit.py .work/run/fex --sanitize
```

The runner reads `FEXCore/Source/Interface/Core/Frontend.cpp`, extracts exactly
`Decoder::CheckRangeExecutable` and `Decoder::PeekByte` without modifying them,
and compiles them with minimal synthetic context/decoder declarations. Its
query adapter returns executable committed guest regions, zero length for
non-executable or out-of-32-bit-range addresses. The test supplies a contiguous
adjusted backing pointer; this setup is **not** a production lifetime/fetch API.
It intentionally performs one raw native read of a non-executable marker to
prove native accessibility cannot enforce the guest execute permission.

Checks run at actual host pages and simulated 16 KiB and 64 KiB granules:

- Execute-only byte peeks work; cached successive peeks avoid another query.
- A later non-executable page denies a peek and a crossing-width range check.
  `g32_fetch` agrees and preserves its destination on failed full-width access.
- Enabling execute permission on the neighbor permits both methods and fetch.
- Revoking execute permission leaves a cached peek stale until reset; the fresh
  `g32_fetch` already rejects. This is an expected reproduction, **not** an
  unfixed test failure or a claim of an upstream defect under its existing VM
  protocol.
- Resetting the cache rejects revoked, decommitted and null guest addresses.
- The last guest byte is fetchable when executable, but a second byte/range
  crossing 2^32 is rejected rather than wrapping or reading the native guard.

The same extracted methods pass against both the pinned source in
`.work/fex-feasibility` (HEAD `9fbdc00bd6401aff3b32d79e78ff98b8a13e4dcf`)
and the current series-applied `.work/run/fex` (HEAD
`f9b5fd2525956374066aa12396934846e9cbe45c`). Their combined extracted-method
SHA256 is `d781f0d735bf894f937beac6a6e4584bfc7e16a220d4bc9877b1488592f47a57`.
The runner prints whole-source SHA256 as well. It is optional host evidence,
not part of CI: CI does not require a prepared FEX tree. Generated C++, objects,
binary and private logs stay in `.work/guest32/`.

## Concrete integration surfaces

The following source anchors refer to `.work/run/fex` relative to its root;
line numbers are deliberately omitted because patch series move them.

| Surface | Source anchor | Required contract / why a single bias is insufficient |
| --- | --- | --- |
| Decoder bytes and immediates | `Frontend.cpp`: `PeekByte`, `ReadData`, `AdjustAddrForSpecialRegion` | Retain guest PCs and check the complete width before reading separated backing. The experiment covers only peeks/range checks, not `ReadData` or full decoding. Current sub-floor adjustment chooses an image window, not a process space. |
| Executable range cache | `Frontend.h`: `ResetExecutableRangeCache`; `Core.cpp`: `InvalidateThreadCachedCodeRange` | The existing invalidation path resets the decoder under the unique code-invalidation lock. A separated VM must participate in this protocol on permission/commit/release changes; `g32_query` alone cannot invalidate it. |
| Additional code-byte readers | `Core.cpp`: `GenerateIR` SMC CRC and optional Zydis input; `CompileBlock` disk-cache store; `IosMonoTryActivate` | These read guest addresses as native pointers outside decoder peeks. Audit/translate them too, or explicitly keep those paths out of the first isolated decode gate; do not claim a global fix from `AdjustedInstStream`. |
| Effective-address computation | `Addressing.cpp`: `LoadEffectiveAddress`; `OpcodeDispatcher.cpp`: `DecodeAddress`, `GetSegment` | Preserve address-size narrowing, segment bases and 32-bit arithmetic before widening to the host pointer. LEA must still produce a guest value. |
| Existing sub-floor translation | `OpcodeDispatcher.h`: `IosXlate`, `_LoadMemAutoTSO`, `_StoreMemAutoTSO` | Enabled by the code's image window; not per-process or width/permission-aware. Pair fast paths use different helpers, and cannot be assumed covered. |
| Ordinary data and vectors | `JIT/MemoryOps.cpp`: `LoadMem`, `StoreMem`, TSO/pair/masked/gather/non-temporal/element/broadcast variants | `GenerateMemOperand` covers only some forms. Check actual selected lanes/widths, preserving fault behavior; masked lanes must not become unconditional native accesses. |
| Guest stack | `JIT/MemoryOps.cpp`: `Push`, `Pop`, `PushTwo`, `PopTwo`; `IR/Passes/RegisterAllocationPass.cpp` pair folding | Native pre/post-index writeback couples address and guest SP. Keep SP guest-valued; checking ordinary load/store helpers alone misses these. Re-audit after optimization. |
| Strings | `JIT/MemoryOps.cpp`: `MemCpy`, `MemSet`; dispatcher `MOVSOp`, `STOSOp` | Preserve direction, per-element faults and guest progress; whole-range memcpy is not equivalent when a later element faults. |
| Atomic RMW | `JIT/AtomicOps.cpp`: `CAS`, `CASPair`, `Atomic*` | Separate emitters consume raw addresses. Require read **and** write access, correct width/alignment, atomicity and fault semantics; copying via ordinary read/write helpers is not an atomic bridge. |
| Native internal memory | `IR/Passes/x87StackOptimizationPass.cpp`: `LoadStackValueAtOffset_Slow`, `GetOffsetTopAddressWithCache_Slow`; context/spill ops in `MemoryOps.cpp` | Generic `LoadMem` also serves native CPU-state storage after x87 lowering. Unconditionally interpreting every IR memory address as a guest pointer is wrong. A port needs explicit guest/native provenance or distinct operations. |
| WoW64 boundary | `Source/Windows/WOW64/Module.cpp`: `HandleSyscallImpl`, `BTCpuProcessInit`, `Context::LoadStateFromWowContext` | Stack return address, syscall arguments, Unix-call nested pointers and FS/TEB values assume shared addresses. Merely translating the argument array leaves its nested guest pointers wrong. Bridge code allocation below 2 GiB also remains blocked. |

This is a starting inventory, not an exhaustive security or correctness proof.
It does not demonstrate performance or concurrent VM safety.

## Next smallest execution gate

Build a **series-applied, host-isolated full decoder test**, using 32-bit CS/mode
and synthetic execute-only code in separated memory. Verify a register-only
instruction (for example `B8 imm32`) produces the expected decoded operands at
a page edge, and a truncated/cross-no-execute instruction yields a guest-address
no-execute result. Exercise immediate reads, multiple blocks and range-cache
invalidation. Keep native address loans serialized and unrelated code-reader
features explicitly outside this gate. This advances the real frontend without
pretending that a partial data-access port can safely launch the game.

After that: distinct checked guest-memory IR, register-only execution, then
scalar/stack accesses with explicit faults; vectors/strings/atomics and Wine
marshalling remain mandatory before any Portal 2 menu attempt. Upstream changes
must be patches with required trailers; eventual app entry remains dev Settings
and the product Play UI, never a new launch switch or file-push path.

## Validation

- Optimized and ASan+UBSan extracted-method experiments: pass all three granules.
- Pinned-source ASan+UBSan experiment: same result and same method hash.
- `pp test --quick`: passed name/secret gates, pin/patch checks, 480 tooling tests
  and host C suites; Swift tests not requested.
- Python syntax compilation and `git diff --check`: pass.

Logs: `.work/guest32/fetch-audit-optimized.log`, `fetch-audit-sanitized.log`,
`fetch-audit-pinned.log`, `iteration8-quick.log`. Remaining title blockers and
private file hashes: [Portal 2 investigation](2026-10-01-portal2-32-bit.md).
