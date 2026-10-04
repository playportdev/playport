# Portal 2: plan to the first milestone

**Status:** proposed, 2026-10-03; milestones 1 and 2 reached (2026-10-04). Nothing here is decided until a decision record
accepts it. It would extend [0005](decisions/0005-title-cohort.md), which limits the
cohort to x86-64 Direct3D 11 titles. This plan replaces the direction of the
`portal2-runtime` branch before milestone 0; the review below says why.

## The problem in one paragraph

Portal 2 (Steam app 620) is i386 PE32 only. A 32-bit Windows process needs its
whole address space below 4 GiB, but every iOS ARM64 task has a hard 4 GiB
`__PAGEZERO`. That is why the launch fails in `virtual_map_main_module`
([evidence](evidence/2026-10-01-portal2-32-bit.md)). The 32-bit address space
must therefore live in a **window** at some host base `B` above 4 GiB. A guest
address `g` is host address `B + g`. Everything else (Wine's WoW64 layer, FEX's
i386 frontend, i386 DLLs) already exists upstream. The work is to make them use
`B + g` instead of assuming that `g` is the host address.

## Review of the branch so far

The branch has 30 iterations, about 11k lines and 25 evidence records, and has
not moved Portal 2 any closer to running:

- **The hot path is too slow.** It checks permissions in software for each 4 KiB
  page, through a helper call that saves all registers on every load. Portal 2
  cannot reach a playable frame rate that way. ARM64 offers
  `ldr w0, [xB, wAddr, uxtw]`, which adds a base to a zero-extended 32-bit
  address at no cost. Native protection at the host's 16 KiB granularity is
  enough, as it already is for x86-64 titles on the same phone.
- **It reimplements what Wine already does.** `pe32.c` (mapping, relocations,
  imports, exports and forwarders) is Wine's i386 loader. The planned
  "WoW64 bridge with nested-pointer marshalling" is Wine's `wow64.dll` and
  `wow64win.dll`, which already build for `aarch64-windows`
  (`build/generated/wine-pe-aarch64-windows.tsv`). FEX already has
  `Source/Windows/WOW64` (`libwow64fex.dll`).
- **It starts from the wrong end.** It checks FEX's JIT one instruction form at a
  time in a simulator, while the open questions that decide whether this can work
  at all (below) have not been tried.
- **The paperwork outweighs the progress.** There is an evidence record and a
  README section for every iteration.

Madeira already contains the right mechanism in a narrower form. fex-port 0060
(`ml951`, `ml954`, `ml1057`) handles x86-64 images whose base is below 4 GiB:

- the image runs from a high mapping;
- `OpDispatchBuilder::IosXlate` adds the window offset at FEX's four memory choke
  points (`_LoadMemAutoTSO` and `_StoreMemAutoTSO`, address and `AddressMode`
  forms);
- the decoder reads code from the high mapping (`AdjustAddrForSpecialRegion`);
- Wine's Mach fault handler services the accesses that are not translated, which
  is slower but still correct.

For a 32-bit process the same idea becomes simpler. Every guest address is below
4 GiB, so the translation is an unconditional `B + zext32(EA)`, with no window
test.

## Questions that decide whether this can work

Each milestone step is ordered to answer one of these as early as possible.

1. **WoW64 beside ARM64EC in one Mach process.** Madeira has only run ARM64EC
   pseudo-processes. A WoW64 title would be a child of the x86-64 session root
   ([0027](decisions/0027-titles-as-children-of-a-session-root.md)), with an
   aarch64 ntdll, `wow64.dll` and an i386 guest. At the Wine pin, unix-side
   `is_wow64()` reads **global `main_image_info.Machine`**, not the TEB;
   `get_wow_teb()` reads `WowTebOffset`. Both identity and the iOS patches'
   global WoW64 allocation state must become owner-aware. The child already
   has an ARM64EC-session TEB, so the normal first-TEB setup cannot suffice.
2. **FEX's WOW64 module on iOS.** Madeira's iOS JIT plumbing (the JIT pool,
   W^X aliases, call-return stacks, the mono bridge) is mostly in
   `Source/Windows/ARM64EC/Module.cpp`, which 30 fex-port patches touch. The
   1,058-line `WOW64/Module.cpp` needs the same pieces. This is probably the
   largest single task.
3. **How much pointer conversion there is.** At the Wine pin:
   - `wow64` and `wow64win` have about 2,500 `get_ptr`/`get_ulong`/`get_handle`
     helper uses and about 230 direct conversions;
   - `ntdll/unix` has about 50;
   - the generated `winevulkan` and `opengl32` thunks have about 5,400.

   Guest-to-host conversions that are missed only fault into the slow path.
   Host-to-guest conversions (`PtrToUlong` of a host pointer) that are missed are
   silently wrong, so those must be audited.
4. **Speed.** An i386 DLL has no ARM64EC-style hybrid code, so DXVK's D3D9 (or
   wined3d) runs as emulated x86 code, unlike the native ARM64EC DXVK that
   x86-64 titles use. That cost is measured at milestone 2 and is the go/no-go
   point.

## Milestone 0: reset the branch (done 2026-10-03)

The branch was rebuilt from Release 0.2.0 with only:

- the [launch-blocker record](evidence/2026-10-01-portal2-32-bit.md);
- the restored build inputs and the verified baseline IPA;
- fex 0012–0014 and the native FEX link audit (`build/guest32/`), the base for
  step 4's coverage test.

The decode/IR harness was not kept because it needed seam 0015 and the
software-checked memory code; step 4 writes its coverage test fresh. Everything
else (`guest32.c`, `pe32.c`, the checked scalar helper, the simulator and
lowering audits, fex seams 0015 and 0016, the dev Settings probe and its
`TitleMode` guard, `probe:guest32-memory`, their `pp` C tests and their evidence
records) is on the `portal2-guest32-experiment` branch. Only a few earlier
evidence records that kept records link to are kept, as written. Any automated
loop should take milestone 1's steps as its instructions.

## Milestone 1: Portal 2's launcher runs its own code

**Done, 2026-10-04.** Every marker below shows on the phone with 3 serviced low
faults, and Hollow Knight passes on the same IPA
([step 4 evidence](evidence/2026-10-04-portal2-inline-translation.md)). The
items still open in step 2 carry over to milestone 2. **Next:**
[milestone 2](#milestone-2-portal-2s-menu).

**Done when** a Portal 2 Play through the UI (`pp ui --play app-620 --until
mark:…+5`) shows in `s1-host.log`:

- `portal2.exe` mapped at guest `0x400000`;
- the i386 `kernel32` and `ntdll` loaded;
- the entry point executed;
- `bin/engine.dll` loaded;
- a count of serviced low-address faults.

A Hollow Knight play to `first-frame+10` must still pass. No graphics and no
menu are required yet.

### Step 1: build the pieces (done 2026-10-03)

[Build and regression evidence](evidence/2026-10-03-portal2-runtime-build.md):
625 i386 Wine DLLs/drivers, aarch64 `wow64.dll`, `wow64win.dll` and FEX's
`xtajit.dll` are staged and verified. The dev IPA is 657,326,047 bytes;
new runtime resources add 196,526,080 bytes (187.4 MiB). Hollow Knight reaches
its first frame at 9.63 s and passes `first-frame+10`.

**Build scaffolding, not working WoW64.** FEX's aarch64 configuration uses the
mingw CRT link recipe but leaves `FEX_IOS_HOST` off: turning it on needs the
module's missing JIT/alias/arena bindings from step 3, not dummy symbols.
No Portal 2 play or i386 execution is claimed. **Next: step 2**, the per-process
Wine window and conversion audit.

- `build/stages/wine-pe.sh`: add `i386` to the aarch64 tree
  (`--enable-archs=i386,aarch64`). This adds a manifest
  (`wine-pe-i386-windows.tsv`), a machine check and stripping. `wow64*.dll`
  already builds.
- `build/stages/fex.sh`: a second configuration for `libwow64fex.dll`
  (aarch64-windows, `Source/Windows/WOW64`), staged as Wine expects for the x86
  WoW64 CPU (`xtajit.dll`).
- Stage `Runtime/i386-windows`. Add `pp verify` checks for the new machine
  types, and record the IPA size increase.
- **Check:** `pp build` and `pp verify` pass, and a Hollow Knight play is
  unchanged. Commit, including the new build records.

### Step 2: the window in Wine (patches/madeira-unix or wine-port)

**In progress, 2026-10-03:** madeira-unix 0049 reserves an uncommitted,
PEB-owned 4 GiB Wine view before the i386 image load, exports native base
queries, and releases it at child exit. The checked arithmetic header is
host-tested directly from the patch, including inverse rejection, NULL,
window edges and disjoint bases. [Evidence and conversion inventory](evidence/2026-10-03-portal2-wine-window.md).
Portal 2's phone play proves reservation and release at `B=0x7038010000`,
but still fails the unchanged low image mapping (`c0000017`); **no image
has been mapped in the window and no i386 code executes**. Hollow Knight
passes `first-frame+10` (9.40 s first frame, menu visible). Phone tests ran
despite the 18% battery warning.

**Owner identity follow-up, 2026-10-03:** madeira-unix 0050 and wine-unix
0008 isolate unpublished child image/module state in its `thread_data` and
make `is_wow64()` owner-aware, even before a failed main-image map. Native
TEBs inherit the creator's PEB; CPU-area queries use the target TEB's owner.
Portal 2's phone log shows child `Machine=0x14c`, `is_wow64=1`, alongside
session `Machine=0x8664`, `session_is_wow64=0`. Its `wow_teb` is still NULL
and the map still fails `c0000017`: **no paired TEB/PEB or i386 execution**.
Concurrent-startup host tests pass; Hollow Knight passes `first-frame+10`
(9.69 s first frame, menu visible). The same step-2 evidence record holds
the latest IPA and runs.

**Suballocation follow-up, 2026-10-03:** madeira-unix 0051 splits the reserved
window into fixed-address allocation views and protected gaps without
unmapping it. It allocates owner-local PEB32 **storage only**, at guest
`0x7ff00000` (16 KiB); it is not populated or linked to a TEB. Host tests use
the production splitter/owner wrapper with real mappings and a mocked Wine
view tree, including failure rollback and concurrent disjoint owners. The
phone confirms the bootstrap view and teardown; Portal 2 still fails
`c0000017`, `wow_teb=NULL`, with no i386 execution. Hollow Knight passes
`first-frame+10` (8.29 s first frame, menu visible). The same step-2 evidence
record holds the IPA and runs.

**Initial TEB-pair follow-up, 2026-10-03:** madeira-unix 0052 moves the
pristine initial native TEB beside TEB32 in the owner's window: guest
`0x7fe00000` / `0x7fe02000`, paired offsets ±`0x2000`. Native pointers stay
host-relative; TEB32 self, PEB and native backlink are guest-relative. PEB32
gets bootstrap scalars only, not native loader/heap/parameter pointers. The
phone confirms pairing, TLS publication and restoration of the original TEB
before window release. Portal 2 still fails `c0000017`, with no mapped image
or i386 execution. Hollow Knight passes `first-frame+10` (8.13 s first frame,
menu visible). Production-helper host tests cover state preservation, failures,
restoration and concurrent disjoint owners with mock Wine layouts/views and
real mappings/TLS; the same step-2 evidence record holds the IPA and runs.

**Fixed-image follow-up, 2026-10-03:** madeira-unix 0053 maps Portal 2's
main image at host `B+0x400000`, with guest ImageBase/PEB32 image `0x400000`,
entry `0x4017d1` and relocation delta 0. Wine's existing PE mapper loads the
sections; i386 bytes keep logical EXEC but are native-NX and get no pool copy
or global sub-floor registration. Failed maps roll back to protected gaps.
Host tests cover placement, bounds, NX/protection and rollback/retry with
real mappings and mock Wine views/page metadata. The phone now passes the
image map, then explicitly stops at the unwired process-parameter/native
WoW64-loader boundary (`c00000bb`), restoring the TEB and releasing the window.
**No i386 code executes.** Hollow Knight passes `first-frame+10` (8.24 s first
frame, menu visible); details remain in the same step-2 evidence record.

**Process-parameter follow-up, 2026-10-03:** madeira-unix 0054 packs normalized
PE32 parameters, all eight startup strings (including opaque RuntimeInfo) and
the environment into one owned view at guest `0x7e000000`. PEB32 publishes
that guest pointer and the owner's heap-option scalars, without borrowing
native heap/loader pointers. Global-option writes now target the current PEB.
Host tests cover validation, failure-before-publication, handles, empty/binary
fields, size/window edges and disjoint storage. The phone confirms the
parameters and environment; startup still deliberately stops before the native
WoW64 loader (`c00000bb`), with **no i386 execution**. Hollow Knight passes
`first-frame+10` (9.25 s first frame, menu visible). The same step-2 evidence
record holds the IPA and runs.

**Guest-placement follow-up, 2026-10-03:** madeira-unix 0055 accepts in-range
server ASLR hints and searches owner-local gaps on collision, respecting guest
limits and fixed stripped/flat images. Window PE32 relocations use Wine's existing
kernel with guest-only deltas and full-directory validation before mutation.
Completed maps suppress the server's host-versus-guest `STATUS_IMAGE_NOT_AT_BASE`
warning so the native loader cannot add B a second time. Host tests cover gap
selection, failures, bounds and nonzero/negative/wrapping relocations. Portal 2
still selects preferred guest `0x400000`, now returns map success, and stops at
the retained native-loader boundary (`c00000bb`): **no i386 execution and no
phone check of nonzero relocations**. Hollow Knight passes `first-frame+10`
(9.26 s first frame, menu visible). Details remain in the step-2 evidence record.

**Native VM follow-up, 2026-10-03:** madeira-unix 0056 routes explicit
host-window pointers through owner-checked anonymous reserve/commit/protect/
decommit/full-release operations. Release retains and coalesces protected
holdbacks; decommit guarantees zero on recommit. Logical EXEC stays native-NX.
Portal 2's phone play confirms parameter allocation through this path, but still
stops before the native loader (`c00000bb`), with **no i386 execution**.
Protection/decommit/release/reuse are host-tested, not phone-validated. Hollow
Knight passes `first-frame+10` (8.20 s first frame, menu visible); details remain
in the step-2 evidence record.

**Guest-constrained NULL allocation follow-up, 2026-10-03:** madeira-unix
0057 shares owner-local gap search between images and anonymous VM. NULL
requests with a <=32-bit zero-bits constraint reserve/commit in the owner's
window; counts/masks, large-address-aware limits, rounding and top-down
selection use guest offsets. Unconstrained native NULL requests remain native.
The phone confirms parameters at guest `0x10000`, `null=1`,
`zero_bits=0xffffffff`; startup still stops before the loader (`c00000bb`),
with **no i386 execution**. Top-down/collision selection and other limits are
host-tested, not phone-validated. Hollow Knight passes `first-frame+10`
(9.26 s first frame, menu visible); details remain in the step-2 evidence record.

**Native basic-query follow-up, 2026-10-03:** madeira-unix 0058 routes native
host-window `MemoryBasicInformation` through owner checks under registry then
virtual locking. Logical state/protection/type, allocation identity, forward
regions, free holdbacks and the reserved low guard stay window-bounded; results
remain **host pointers**. Unsupported window query classes fail closed, including
local WorkingSetEx arrays containing window addresses. Normal parameter bootstrap
validates its allocation through `NtQueryVirtualMemory` before publication, and
Portal 2's phone log confirms a private/RW/committed 16 KiB region and 48-byte
return. Startup still stops before the loader (`c00000bb`), with **no i386
execution**. Other query cases are host-tested with mock Wine metadata. Hollow
Knight passes `first-frame+10` (10.01 s first frame); its captured screenshot is
black, not visual evidence of a menu. Details and the latest IPA remain in the
same step-2 evidence record.

**Native image-section follow-up, 2026-10-03:** madeira-unix 0059 routes
owner-local native `NtMapViewOfSection` for complete, ordinary i386 `SEC_IMAGE`
views, with host returns and guest placement/relocations. Explicit host addresses
and guest-constrained NULLs use the existing Wine mapper, gap search and
wineserver registration; unmap retains/coalesces holdbacks and never deletes
bootstrap views. Native image queries report host base and exact image extent,
not host-page padding. Other section forms/attributes and Ex/remote operations
fail closed. Portal 2's normal main-image bootstrap now uses this native section
entry, confirming guest `0x400000` and map success on the phone; startup still
stops at the retained loader boundary (`c00000bb`), with **no i386 execution**.
Unmap/failure rollback, collision/nonzero relocation, top-down and image queries
are host-tested only. Hollow Knight passes through `first-frame+30` (9.41 s
first frame), with a reviewed main-menu screenshot. Details and exact unsupported
cases remain in the same step-2 evidence record.

**Native protection follow-up, 2026-10-03:** madeira-unix 0060 routes owner-local
native `NtProtectVirtualMemory` for window image and anonymous VM pages through one
transaction that Wine's image setup and anonymous commit also use. Each 4 KiB Wine
page keeps its logical protection (EXEC, WRITECOPY, GUARD) and query result; a 16 KiB
host page gets the union of native permissions, never EXEC, so a stricter page beside
a permissive one is enforced only logically. Guard pages are enforced or refused.
Image READWRITE is WRITECOPY on private backing; images with shared writable sections
are now refused. Failure changes no page, byte or output. Bootstrap views,
quarantined images, image padding and cache/CFG modifiers fail closed. Host tests
cover transitions, old values, partial pages, writecopy with the file unchanged, NX,
rollback and owners.

On the phone, Wine's image setup for Portal 2's main image applies six section
protections through the transaction, all with status 0 and native EXEC off. The
map then succeeds, and startup stops at `c00000bb`. No normal bootstrap step reaches
the native `NtProtectVirtualMemory` route before that stop, so that route itself is
host-tested only. There is no i386 execution. Hollow Knight passes
`first-frame+30` (9.71 s first frame, menu visible). Details are in the same
step-2 evidence record.

**Native-loader follow-up, 2026-10-03:** madeira-unix 0061 removes the startup
stop. The i386 child loads its own aarch64 ntdll (the session's ARM64EC one is no
WoW64 host), maps the i386 ntdll in its window, gets a window 32-bit stack and its
own guest init block, PEB32 and i386 context. wine-pe 0015 takes the native DLLs
of a WoW64 process from `C:\windows\sysarm64` (an aarch64 farm the app links),
since system32 is the ARM64EC set. On the phone the child runs native aarch64
PE code through `loader_init` into wow64.dll's `process_init`, with the i386
ntdll **relocated** to guest `0x7bf40000` (first phone check of a nonzero
relocation); wine-pe 0014 stops there (`c00000bb`) before loading the CPU module.
Loading FEX's `xtajit.dll` without that stop pulled the native kernelbase in
through its CRT imports and faulted the app. **No i386 instruction runs yet.**
Hollow Knight passes `first-frame+10` (9.06 s first frame, menu visible).
Details are in the same step-2 evidence record.

**wow64 conversion follow-up, 2026-10-03** ([evidence](evidence/2026-10-03-portal2-wow64-pointers.md)):

- wine-pe 0016 converts wow64.dll's pointers through the window. A
  `wow64_window.h` holds `wow64_to_host` and `wow64_to_guest` (rejection,
  never truncation; host-tested), and the base comes from the TEB32/PEB32
  pair. Every thunk file is audited, and so are the exception, APC and
  callback frames and the initial context.
- wine-pe 0018 converts wow64win.dll's audited thunks (398 win32u calls,
  and all callbacks). Any other win32u call stops the process and names
  the call.
- madeira-unix 0063 gives the child its 32-bit limits and NLS views in the
  window. 0064 aliases GDI's shared handle table there. `wine_host.c` links
  `syswow64`.
- On the phone, the i386 loader and user32 initialize, and `portal2.exe`'s
  entry point runs. It loads `bin\launcher.dll`, which loads `steam_api`,
  `tier0` and `vstdlib`.
- Follow-up: one DC_ATTR arena that every window aliases (win32u's DC cache
  moves DCs between processes, so per-child buckets cannot work); the
  apiset map and KUSER_SHARED_DATA aliased into the window; FEX translating
  the whole window inline (fex 0017); i386 unix libraries with their WoW64
  tables; the guest's own debug output.
- Second follow-up: secondary threads' TEB pairs in the window,
  `NtUserMessageCall` and the message loop audited, and LD1/ST1 lanes in
  the low-fault emulator.
- On the phone the launcher loads `bin\engine.dll`, which loads its own
  modules up to `shaderapidx9`, Wine's i386 `d3d9`/`wined3d` and
  `localize` (64 i386 images). FEX's generated code then calls a null
  helper and the child hangs (18.8 million serviced low faults by then).
- Hollow Knight passes `first-frame+10` (8.76 s, menu visible).

Still open in step 2 (carried to milestone 2):

- wow64win's remaining unaudited thunks (D3DKMT, raw input, hooks);
- freeing a secondary thread's pair and 32-bit stack before process exit
  (done after milestone 2: madeira-unix 0073);
- pointers inside the unix libraries' WoW64 parameter blocks;
- fonts for i386 GDI;
- other query classes;
- writable and anonymous section views, and unmap of file views;
- the global `wow_peb`, TEB free lists and limits (unused by this path);
- startup globals that rely on serialization.

- In `ntdll/unix/virtual.c`, for a WoW64 pseudo-process, reserve a 4 GiB window
  at `B` at process start. Every limit that means "the 32-bit address space"
  (`limit_2g`, `limit_4g`, `user_space_wow_limit`, `zero_bits` for 32-bit
  callers, the 32-bit image limit at line 3852) then refers to `[B, B+4G)`.
  The low 64 KiB stays unmapped.
- One header with `wow64_to_host(ULONG)` and `wow64_to_guest(void *)`. The
  latter rejects pointers outside the window rather than truncating them. `B`
  is a per-process value that the unix side exports.
- Route the WoW64 pointer conversions through it:
  - `wow64/wow64_private.h` `get_ptr` and the `PtrToUlong` stores of host
    pointers in `wow64`;
  - `env.c`'s `wow_peb` and `wow64_params` setup;
  - the 32-bit TEB, stack and context setup;
  - callback, APC and exception frames.

  Handles and integers keep their plain macros. Do this file by file, with a
  grep list in the patch's evidence.
- Host C test (a `pp` C test entry): conversion round trips, rejection of
  out-of-window values, and the window edges.
- Confirm or extend Madeira's low-address fault servicing (the `ml938` handler
  that fex-port 0060 refers to) so that it treats the whole window as one
  sub-floor range for a WoW64 pseudo-process. This is the correctness backstop
  for everything not yet translated.

### Step 3: FEX's WOW64 module on iOS (patches/fex)

**Check passed, 2026-10-03** ([evidence](evidence/2026-10-03-portal2-fex-wow64.md)):
fex 0015/0016, rpmalloc 0003 and madeira-unix 0062 load `xtajit.dll` (FEX's own
CRT, imports only ntdll and wow64) with the JIT pool, the host band and the
guest window (base from the paired TEB32; code decoded from the window, memory
operands translated inline, the rest serviced by the Mach handler in the window:
1,072 low faults). On the phone FEX runs i386 code from `LdrInitializeThunk` to
the guest's first system call, `NtAllocateVirtualMemory`, where wine-pe 0014 now
stops (`c00000bb`). Questions 1 and 2 are answered: WoW64 runs beside the ARM64EC
session, and FEX's WoW64 module runs on iOS. Hollow Knight passes
`first-frame+10` (9.61 s, menu visible).

**Milestone 1 reached, 2026-10-03:** a Portal 2 play shows every marker
(`portal2.exe` at `0x400000`, i386 `kernel32` and `ntdll`, the entry point,
`bin/engine.dll` at `0x79640000`, the serviced-fault count); Hollow Knight
passes `first-frame+10` on the same IPA
([evidence](evidence/2026-10-03-portal2-wow64-pointers.md)).

- Port the iOS JIT plumbing from `ARM64EC/Module.cpp` into `WOW64/Module.cpp`:
  pool allocation, aliases, call-return stacks and the transition hooks. Share
  code through `Source/Windows/Common` where the ARM64EC patches allow it.
- Translate the module's own guest pointers: `Context->Esp` argument blocks,
  `StackArgs->Args` in the unix-call path (line 469 at the pin), and exception
  and callback frames.
- **Check:** the phone run reaches the first i386 instruction in `ntdll`
  (`LdrInitializeThunk`), even if every access faults into the slow path.
  This answers questions 1 and 2. If it fails structurally, stop and write it
  up before going further.

### Step 4: inline translation in FEX (patches/fex)

**Check passed, 2026-10-04** ([evidence](evidence/2026-10-04-portal2-inline-translation.md)):

- fex 0018 emits every guest load and store as `[B, wEA, uxtw]`, the TSO
  forms included. Push and pop become such an access plus an ESP update.
  Atomics, pairs, vector-element, x87, state-save and string ops use
  `B + zext32(EA)`.
- Sampling showed that push, pop, call and return caused 97.8% of the
  18.8 million faults.
- The coverage test (`build/guest32/window_coverage_audit.py`) passes on 174
  i386 instructions in four configurations. A control without a window is
  rejected.
- The milestone run has 3 serviced low faults. They are native ntdll reads of
  the i386 ntdll image, not FEX code.
- fex 0019 turns the "null helper call" (the dispatcher branching to
  `CompileBlock`'s refusal of EIP 0) into the guest's access violation. The
  child now exits with `c0000005` instead of hanging.
- Hollow Knight passes `first-frame+10` (9.59 s, menu visible).

- In 32-bit mode, apply `B + zext32(EA)` at the `IosXlate` sites. Emit it as the
  `MemOffsetType::UXTW` register-offset form so that the backend produces
  `[xB, wEA, uxtw]`. Then cover the remaining direct memory sites in
  `OpcodeDispatcher` (string ops, atomics, x87, vector loads and stores).
- Have the decoder fetch from `B + RIP`, and translate `QueryGuestExecutableRange`
  and InvalidationTracker queries.
- **Coverage test** (the kept native host build): decode a corpus of i386
  instructions in 32-bit mode and assert that every `LoadMem`/`StoreMem`/atomic
  address in the IR comes from the base add. This replaces the per-instruction
  simulator audits.
- **Check:** the milestone run above, with the serviced-fault count falling to
  near zero. Then a Hollow Knight regression play, as AGENTS.md requires when the
  FEX series moves. Write one evidence record with the IPA's sha256.

## Milestone 2: Portal 2's menu

**Reached, 2026-10-04** ([evidence](evidence/2026-10-04-portal2-d3d9-vulkan.md)).
Portal 2 plays its intro videos and reaches its main menu about 30 s after Play.
The menu runs at 60.0 FPS when capped at 60 (16.68 ms per frame, 3.55 ms of GPU
time) and at 119.3 FPS with no limit (the 120 Hz panel, 8.39 ms per frame), with
8 serviced low faults. **Go/no-go: go.** The menu is at interactive speed on
emulated i386 code, so there is no case yet for a native aarch64 D3D9. Gameplay
has not been measured. Hollow Knight passes `first-frame+10` on the same IPA.

1. The null shader-API factory: i386 `opengl32` had no unix table, so its `DllMain`
   failed. That failure took `wined3d`, `d3d9` and `shaderapidx9.dll` down with it.
2. The i386 Direct3D 9 path:
   - DXVK's i686 `d3d9.dll`, in the Vulkan overlay over `syswow64`;
   - winevulkan and win32u's Vulkan through the window, with placed memory maps
     (wine-unix 0011);
   - the next wow64win audits (wine-pe 0022);
   - data section views in the window (madeira-unix 0071).
3. Blockers on the way:
   - no WoW64 audio driver (0072);
   - fex 0020: read faults in an RWX interval go to the guest;
   - the emulated Steam API's MSVC vtable order for callbacks (gbe 0004);
   - socket buffers through the window (wine-unix 0012).
4. **Next:**
   - choose Portal 2's default backend (DXMT cannot run i386 Direct3D 9; the runs
     set Vulkan per game);
   - then milestone 3.

5. Hardening after the milestone-1 review: the window outlives its threads and
   the Mach handler's lookups, an exited thread's pair and stack are reclaimed
   (madeira-unix 0073), pointer messages and class menu names keep their guest
   form (wine-pe 0024, 0025), diagnostics read no unchecked guest stack, and every
   Steam interface has MSVC's vtable layout (gbe 0005, checked at build).

Still open from milestone 1 step 2: pointers inside other unix libraries' WoW64
parameter blocks (audio now has none), i386 GDI fonts, other query classes, and the
global WoW64 state.

## After milestone 2 (outline only)

- **Milestone 3:** gameplay (a chamber played with a controller, measured with
  `pp perf --pad`), input and audio (a WoW64 table for the null driver) through
  `wow64win`, save and reload, and the player's settings on the game's page.

## Rules that still apply

Upstream changes are patch files only, with trailers. Wine and FEX series move
only with a Hollow Knight play. The UI is the only entry point, so no test
`.exe` or launch mode is added and Portal 2 itself is the test. Use one evidence
record per milestone step that others rely on, not one per iteration.
