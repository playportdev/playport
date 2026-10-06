# Portal 2 milestone 1, step 4: inline translation in FEX

## Result

[Step 4](../plans/finished.md#portal-2)'s check
passes. FEX now addresses every i386 guest memory access through the guest
window inline. In Portal 2's milestone run the serviced low faults fall from
18,780,160 to 3. The run reaches the same point as before: `bin\engine.dll` at
`0x79640000`, 64 i386 images, the last one `localize.dll`. The null call after
`localize.dll` is now explained. `materialsystem.dll` calls the shader API's
factory, which is null. The guest now gets its access violation at EIP 0 and
the child exits with `c0000005` about 23 s after launch, where before it hung
until the UI run's 300 s limit. Hollow Knight passes `first-frame+10`.

IPA: `.work/out/20261004-004052-a1e5be71/Playport-26.5-a1e5be71.ipa` (dev).
SHA256: `a1e5be716ee68fb6f2b873d91fadecf8697a52024d82d9509fb5494401f9ca68`.
It is built from this commit's series. `pp build` (78 IPA checks) and
`pp test` passed.

## Where the faults came from

The Mach handler logs one serviced window access in 4,096 (`[wow64-fault]`:
instruction word and host pc). The step 3 run
(`.work/ui-runs/p2th-5`, 18,780,160 faults) left 4,593 samples, all from
FEX-generated code:

| Instruction form | Samples | Share | IR op |
| --- | ---: | ---: | --- |
| `str w, [x8, #-4]!` / `ldr w, [x8], #4` | 2,336 | 50.9% | `Push` / `Pop` |
| `stp w, w, [x8, #-8]!` / `ldp w, w, [x8], #8` | 2,152 | 46.9% | `PushTwo` / `PopTwo` (RA-merged) |
| LSE atomics, `casal` | 44 | 1.0% | `AtomicFetch*`, `CAS` |
| `ldr`/`str` unsigned offset, other `ldp`/`stp` | 40 | 0.9% | `LoadMem` (string ops), pairs |
| `ld1 {v.b}[n]`, `stur s`, `str w, [x], #4` | 21 | 0.5% | `VLoadVectorElement`, x87/SSE stores, `MemSet` |

`x8` is ESP: push, pop, call, return and enter/leave were 97.8% of all
faults. fex-port 0060's choke points (`_LoadMemAutoTSO`/`_StoreMemAutoTSO`)
translated only the loads and stores that pass through them.

## Changes

- **fex 0018** (feature): with a window base set, the dispatcher emits:
  - every guest load and store as `[B, wEA, uxtw]`. `LoadMem` and `StoreMem`
    take B as a pooled constant register and the guest address as a UXTW
    register offset. `LoadMemTSO` and `StoreMemTSO` take the same form; the
    backend forms the address in a temporary, because `ldapr`/`stlr` have no
    register offset.
  - push and pop as that store or load plus an explicit ESP update. `Pop`
    takes the stack pointer by reference.
  - atomics, CAS pairs, load/store pairs, vector element, broadcast,
    non-temporal, masked, x87 80-bit, FXSAVE/XSAVE/FNSAVE/FLDENV, cache-line
    and prefetch forms through `B + zext32(EA)`.
  - `REP STOS` with B in its segment prefix. `REP MOVS` adds B to both
    pointers and takes it off the returned ones, so ESI and EDI stay guest
    values.
  - the full SMC check's CRC, read through the window.

  The base is set in `BeginFunction` for a 32-bit block whose window is the
  whole 4 GiB, which is what the WoW64 module's `IosSubfloorWindowForCode`
  reports. ARM64EC blocks are 64-bit and get no base, so x86-64 codegen is
  unchanged. The coverage test also found a real bug: the x87 pass formed the
  split 80-bit store's `+8` address in 32 bits, which truncated `B + EA + 8`.
  It now forms it in 64 bits.
- **fex 0019** (feature): Madeira's `CompileBlock` refuses guest RIPs below
  `0x10000` and returns 0. The ARM64EC module turns that 0 into the guest's
  fault, but the WoW64 dispatcher branched to it. That is the step 3 "null
  helper call": `lr - 4` was the dispatcher's `blr x4` to `CompileBlock`,
  `x0 = 0`, and guest EIP was 0. In the WoW64 module the block now compiles,
  the decoder finds no executable range, and the guest gets
  `EXCEPTION_ACCESS_VIOLATION` at EIP 0. The first eight such jumps log
  `[wow64-low-jump]` with the guest registers and `[ESP]`.
- Already in place from step 3 (fex 0016 and 0017), with no change needed:
  - the decoder fetches from `B + EIP`;
  - `QueryGuestExecutableRange`, `LookupExecutableFileSection`, tracker
    notifications and `InvalidateGuestCodeRange` convert at the module edge;
  - the InvalidationTracker invalidates by guest address.

## Coverage test

`build/guest32/window_coverage_audit.py` uses the kept native host build
(`.work/guest32/decode-audit/native`, the series-applied tree). It assembles
`build/guest32/window_corpus.s` with `llvm-mc`: 174 i386 instructions covering
every address form, the stack, string, locked, x87, MMX/SSE, state-save,
prefetch and descriptor-table instructions. Each instruction goes through
`ContextImpl::GenerateIR` with FEX's default passes, including RA. The test
then requires every guest memory op's address to be `[B, wEA, uxtw]` or
`B + zext32(EA)` (plus a small constant for split accesses). It resolves
post-RA register arguments to their defining nodes. `Push`, `Pop` and gathers
fail the test outright. FEX context and GDT accesses are allowed.

```text
PASS: 174 i386 instructions x 4 configurations, every guest memory access addresses the window at 0x7038010000
  LoadMem 376, StoreMem 396, LoadMemTSO 104, StoreMemTSO 56, LoadMemPair 32, StoreMemPair 20,
  AtomicFetch* 64, AtomicSwap 4, CAS 4, CASPair 4, MemCpy 8, MemSet 4, VLoadVectorElement 36,
  VStoreVectorElement 16, VLoadNonTemporal 4, VStoreNonTemporal 8, Prefetch 8, CacheLineClear 4,
  ValidateCode 174
PASS: control without a window rejected: FAIL [tso] mov eax, dword ptr [ebx]: LoadMemTSO address is not in the window
```

The four configurations are: TSO on, TSO off, TSO with full SMC checks, and
TSO off with reduced-precision x87. `native_link_audit.py` still passes, and
its link step is now shared with this test.

## Phone runs

Battery 75%, charging. Each run was `pp install --no-build`, then
`pp ui --play app-620 --until done --wait 150 --shot`.

- `p2s4-1` (fex 0018 and 0019 without the jump log; IPA `2246b10a…`): 54
  serviced low faults. The guest gets
  `Unhandled page fault on execute access to 00000000`, tries to start
  `winedbg`, and ends with `NtTerminateProcess(c0000005)`. The window is
  released.
- `p2s4-2` (the IPA above, `.work/ui-runs/p2s4-2`):

```text
[wow64-fault] serviced 1 window access(es); latest guest 0x7bf94000 -> host 0x70b3fa4000 read 1 byte(s) insn=0x38686809 pc=0x1059bb0dc
002c:err:wow:wow64_NtMapViewOfSection Playport: i386 image c:\games\portal 2\bin\engine.dll at 79640000
002c:err:wow:wow64_NtMapViewOfSection Playport: i386 image c:\games\portal 2\bin\localize.dll at 787b0000
E 2C [wow64-low-jump] guest RIP=0x0 [esp]=0x792cfb6c [esp+4]=0x7935b2dc eax=0x0 ecx=0x0 edx=0x0 ebx=0x0 esp=0xc5e718 ebp=0xc5e738 esi=0x793cb9d8 edi=0x7b6e8690
wine: Unhandled page fault on execute access to 00000000 at address 00000000 (thread 002c), starting debugger...
002c:err:wow:Wow64SystemServiceEx Playport: i386 NtTerminateProcess( ffffffff, c0000005 )
[wow64-window] release peb=0x124cac000 base=0x7038010000 serviced_low_faults=3
```

  - Every milestone 1 marker is in the log: `portal2.exe` at `0x400000`, the
    i386 `kernel32` and `ntdll`, the entry point (`launcher.dll` is loaded by
    the executable's own code), `bin\engine.dll` at `0x79640000`, and the
    serviced-fault count.
  - The 3 remaining faults are byte reads (`ldrb w9, [x0, x8]`) of the i386
    ntdll image at guest `0x7bf94000`, from native ntdll code (host pc at
    `ntdll.dll+0x6b0dc` in `p2s4-1`). This is a Wine-side unconverted pointer,
    not FEX code.
  - The null call: `[ESP]` is `materialsystem.dll+0xfb6c`, the return from
    `call [esi+0x2abc]` with `"ShaderDeviceMgr001"`. That is the shader API
    module's factory. `shaderapidx9.dll` maps twice and its dependencies
    `d3d9`, `wined3d` and `opengl32` load. i386 `opengl32` gets the stub table
    (no GL), so the factory stays null. This is milestone 2's i386 D3D9 path,
    not an emulation fault.

**Hollow Knight** (`.work/ui-runs/p2s4-2-hk`, same IPA, after Portal 2):
exit 0 at `first-frame+10`. The first frame came at 9.59 s (step 3 runs:
8.26–10.11 s), and the screenshot shows the main menu.

## Open

- **Gathers** (`VLoadVectorGatherMasked*`, AVX2) form addresses from vector
  lanes and are not translated. The coverage test rejects them, and the corpus
  has none.
- **Wrap at 4 GiB**: a `B + zext32(EA)` pair or split access adds its small
  offset after the zero-extension, so an access that straddles guest
  `0xffffffff` does not wrap. The single loads and stores wrap exactly.
- **TSO cost**: an acquire/release access is now `add` + `ldapr`/`stlr`, and
  the atomics add a `mov w, w` and an `add` in front of the address. No frame
  time has been measured (milestone 2).
- The 3 remaining faults come from native ntdll reading the i386 ntdll image
  through a guest address.
- FEX's disk-cache hashing (`DiskCache.cpp`) still reads guest code by guest
  address. It did not appear among the sampled faults.
