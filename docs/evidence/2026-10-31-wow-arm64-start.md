# World of Warcraft Classic Era (ARM64 client) start-up on the phone, 2026-10-31

**Linear:** PLA-514. Branch `dev/pla-516-battlenet`, madeira-unix 0252–0255. The game was started from the Library
(`./pp ui --play bnet-wow_classic_era --until first-frame+60 --shot --wait 300`) as a native ARM64 child.
Run directories are under `.work/ui-runs/`.

## What blocked it, in order

1. **x18 compares not patched** (run 20261031T215841, IPA 9ee99874). The main thread spun in
   `WowClassic-arm64.exe`+0x2bb38, a loop inside the vectored handler (+0x2b870) that WoW calls for the
   `udf #0x9720` it raises at +0xd6c8 in a TLS callback. The handler does `cmp x18, #0x38; b.lo <loop>`; iOS
   zeroes x18 and the x18 patcher matched ADD/ADDS only, not SUB/SUBS (CMP). Reproduced off the phone by
   emulating the handler (Unicorn) on the run's JIT-pool dump: x18 = 0 reaches the loop, x18 = TEB returns
   `EXCEPTION_CONTINUE_EXECUTION` with Pc + 4. Fix: 0252. 239 `cmp x18` words exist in the exe (4x the rate of
   other registers); 16 of them sit on words a junk literal load targets, so the literal guard still leaves them.
2. **Single step** (run 20261031T222147, IPA 1d723cd1). The handler sets Cpsr.SS (bit 21) and steps the
   import resolver (emulated: about 4,000 steps across three UDFs). Wine on iOS dropped the bit. Fix: 0253
   steps such a context in software: branches/ADR/ADRP/literal loads are done on the context, other
   instructions run out of line before a `brk #0xf0f5`.
3. **Debug registers** (runs 20261031T223920, 20261031T224829). The handler reads Bcr/Bvr/Wcr in the
   context. `save_context` left the stack's leftover values in them, and the handler then went to a decoy
   (Pc = +0x53e8, x1 = 0), which faulted, and the game showed "Game Initialization Failed". Emulating the
   handler with nonzero debug registers gives the same +0x53e8. Fix: 0255 zeroes them.
4. 0254: the ILL handler no longer writes the 896 MB JIT pool dump for a UDF in a guest image.

5. **The step's BRK hit the livelock breaker** (run 20261031T225422). The Mach exception thread's `[fault-stuck]`
   breaker counted each out-of-line step's BRK at the same slot pc and ended the thread at 50. 0256 declines that
   BRK first, so it goes to trap_handler.
6. **Trampolines were stepped instruction by instruction** (run 20261031T231240; logged step trace: about 20 µs
   a step). A patched instruction showed up as up to seven steps outside the image. 0259 steps it as one
   instruction: out of line with the TEB in its scratch register, or on the context for `mov xN, x18`.
7. **CMP x18 words that a junk literal load points at stayed unpatched** (runs 20261031T231240,
   20261031T232640). The literal guard treated 38 of WoW's `cmp x18, #imm` words as data. With x18 = 0, the
   handler's single-step path ran `ldr x28, <literal>` and returned with x28 = 0xf1030e5f1800009f (two code
   words); ntdll's `call_vectored_handlers` then faulted on it. Reproduced in the emulator with the phone's x18
   model, and gone once these words are patched. 0260 never treats a CMP/CMN of x18 as data: its low five bits
   are 0b11111, which no aligned pointer has.
8. 0257: the Mach thread's 896 MB pool dump at the first unhandled exception now runs only with the
   diagnostics on (it ran in 69 of 93 runs on 2026-10-30/31). 0258: `NtGetContextThread` returns zeroed debug
   registers.

## Where it stands

Run 20261031T233815 (IPA 6e598040043f6dcbc1d552558d498d6234686b2c77e463b5e0a9564ac032c03e): the first TLS
callback completes, and WoW handles 11 planned UDFs with their single steps (the emulator saw 7 in that
callback). Then a stepped `str x9, [x8]` at +0x118d4 writes the image's PE .text address (0x141461000) through
x8 = 0x710e184ed8, which nothing maps. x8 is `(ret ^ K) + w10`, where `ret` is the return value of a call at
+0x11064 that WoW resolved itself, and K = 0xb96cc89bbdc29933. Just before it, WoW had VirtualAlloc'd 0x2000
bytes RWX (0x7043c50000). The game then shows "Game Initialization Failed: M…" and exits with code 1.
Still open: which call at +0x11064 this is, what it returns under Wine on iOS compared with Windows, and how
WoW's RWX code buffer is handled on iOS. No login screen yet.

Hollow Knight on IPA 6e598040: first-frame+10 passes (run 20261031T234011).

9. 0261: a stepped BLR into host code (the syscall dispatcher, from ntdll's stubs) now runs out of line as one
   step, and a step that is dropped anyway is logged. Run 20261031T234647 (IPA 70718df4…): no step was dropped,
   and the same store fault happened. Across runs the bad pointer moves by exactly as much as WoW's pool copy
   moves (0xc8000). So `w10` is consistent with a 32-bit RVA computed as *pool address* (from ADRP) minus
   *PE ImageBase* (from the loader): about 0x2e24ed8 into .rdata, offset by pool − PE. The native child runs the
   image from its JIT-pool copy, but PEB/LDR report the PE view's base, so any RVA WoW computes from its own
   code addresses against its module base is wrong. Making the pool copy the module's reported base for a
   native ARM64 child (PEB ImageBaseAddress, the LDR entry, VirtualQuery of it) is a design change in the
   loader and the virtual-memory views, and is not done here.

Hollow Knight on IPA 70718df4…: first-frame+10 passes (run 20261031T234751).

## The pool copy as the image (decision 0176, madeira-unix 0262)

IPA `d4c7ef73326c14a27fe7f8c66c5532616d33c398235d3d972c560bd41ed220ca`. A native ARM64 child is now given
each image's pool copy as the module (`[native-image] … the image is its pool copy` for the exe and every
DLL but its ntdll). The PE-side unwinder translated pool pcs to the view and looped in `virtual_unwind`
(the `arm64` probe hung, run 20261031T235908) until its reverse translation left presented copies alone.

- **The probes and Hollow Knight on this IPA:** `arm64` probe exit 42, which is all checks passing
  (run 20261101T002236); `d3d12` probe on Vulkan exit 0 (run 20261101T002202); Hollow Knight
  first-frame+10 passes (run 20261101T002112). `pp test --quick` passes.
- **WoW (run 20261101T001536, the same runtime):** the store fault is gone, and exceptions carry pool
  addresses. WoW handles 13 planned UDFs, then `blr x26` at +0x26670 jumps to +0xb3794. In the file
  and the copy, those bytes are not code (0xc272545e): an illegal instruction, which WoW's handler
  turns into "Game Initialization Failed: M". Still open is whether x26 is a pointer computed from a
  wrong value or a region WoW expects to have decrypted, or to fault on, first: protecting a
  presented copy changes Wine's view and leaves the pool page RX, so a region WoW makes no-access
  or non-executable would not fault.
