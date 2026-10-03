# Portal 2: plan to the first milestone

**Status:** proposed, 2026-10-03. Nothing here is decided until a decision record
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

**Next, still step 2:** implement window suballocation and owner-local paired
TEB32/PEB32 allocation, then image/VM mapping and guest-relative metadata.
The legacy `wow_peb`, TEB free lists and WoW64 limits are still global; other
startup globals (`peb`, argv, startup info) still rely on serialization.
Route pointer conversions, expose the base to PE code and integrate
whole-window faults for the Mach handler's target process. The current
holdback view is not yet a suballocator; the locked native base queries must
not be called from a signal handler. Do not advance to step 3 yet.

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

## After milestone 1 (outline only)

- **Milestone 2, Portal 2's menu:**
  - an i386 D3D9 path (DXVK i686 from the `dxvk` pin) through `winevulkan`'s
    WoW64 thunks (regenerated with the conversion helpers), then KosmicKrisp;
  - i386 `steam_api.dll`, which `steamapi.sh` already builds;
  - audio and input through `wow64win`.

  Measure frame time and the fault count. **Go/no-go:** if the menu is far from
  interactive speed, the next step is a native aarch64 D3D9 reached by a thunk,
  not more emulation work.
- **Milestone 3:** gameplay, save and reload, and the player's settings on the
  game's page.

## Rules that still apply

Upstream changes are patch files only, with trailers. Wine and FEX series move
only with a Hollow Knight play. The UI is the only entry point, so no test
`.exe` or launch mode is added and Portal 2 itself is the test. Use one evidence
record per milestone step that others rely on, not one per iteration.
