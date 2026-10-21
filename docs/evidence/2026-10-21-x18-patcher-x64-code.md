# The x18 patcher and the x64 code in ARM64EC images (2026-10-21)

**Linear:** PLA-364, PLA-413. Host analysis only; the phone was offline. Dev IPA `56b9fe7f` (madeira-unix
0204) is built and verified but has not been run on the phone. Evidence for the launcher crash:
[2026-10-21-rdr2-cs-fastpath-and-heap.md](2026-10-21-rdr2-cs-fastpath-and-heap.md#the-initonceexecuteonce-stub-broke-the-rockstar-launcher).

## Why the InitOnceExecuteOnce stub crashed the launcher

- **The faulting code.** Run e1's host log puts the first fault at `ntdll.dll+0x628c4`, `ldr x8, [x8, #0x60]`. Two
  words earlier is an **unpatched** `mov x8, x18` (`aa1203e8`): the dump `aa1203e8 2a1f03e1 [f9403108]`. In
  the same dump the sites before and after it are branches to trampolines (`1402614d`, `14026143`).
  - The thread's x18 was 0, so x8 became 0. The fault handler's emulation covers only a base register of
    x18 (`[x18-decline] … rn=8`), so the read of 0x60 went to the guest as an access violation.
  - The function is RtlProcessFlsData: it reads `NtCurrentTeb()->Peb->ProcessHeap` to free the FLS chunks.
- **Why that site was skipped.** Every ntdll copy in e1 logs `[x18-patch] … patched=787 skipped=2` and
  `[x18-lit] 1 literal-pool word(s) matched x18 patterns — skipped`. The good build f01287bb (pG's log)
  logs `patched=788 skipped=2` with no `[x18-lit]` line.
- **Rebuilding the stub's ntdll.** The dropped patch was applied to a copy of `loader.c` in scratch,
  compiled, and linked against the run tree's other ntdll objects, writing nothing in the run tree. The
  patcher's scan, run against that file, gives one literal skip:
  - at RVA `0x628bc`, the crash site;
  - marked by the word at RVA `0x8670c`, `0x18ee0d8d`;
  - the current ntdll gives none.
- **What that word is.** It lies in ntdll's x64 code, `__wine_spec_relay_entry_point_772`:
  `48 8d 0d ee 18 04 00`, `lea rcx, [rip+0x418ee]`.
  - From its third byte the word reads `0x18ee0d8d`, an `LDR Wt, <literal>` to ARM64. Its target is a
    fixed distance back, in the ARM64EC code.
  - The ARM64EC code is laid out up to 0x7ee50, and the x64 code starts on the next page at 0x7f000. So
    the x64 code does not move, while the stub's 0x370 bytes moved RtlProcessFlsData under that target.
  - Which ntdll change breaks which function was therefore a lottery. The stub's code was never the
    cause, which is why it crashed whether its switch was on or off.

## What else the same misreading did

The patcher walks all of .text as ARM64, and the end of an ARM64EC image's .text is x64 (the CHPE code
map, type AMD64). Over the 592 ARM64EC DLLs staged by the current build:

- **125 x64 words in 49 DLLs decode as x18 instructions, and the patcher overwrote each with a branch.**
  - ntdll has two: one in a relay entry point and one at RVA `0x8ed4c`, inside the x64
    `KiUserExceptionDispatcher` (`74 17 48 83 ec 28`, the `je` displacement and the following `sub rsp`).
  - kernelbase has 9, msvcr120 15.
- **opengl32 has one x18 instruction left unpatched by an x64 "literal"**: `mov x10, x18` at RVA `0x2274c`.

## The fix (madeira-unix 0204)

- **The scan skips x64 code.** The scan shared by the trampoline budget and the patcher now reads the
  image's code map through the header in the view it has.
  - Words in AMD64 ranges are never an LDR (literal) source and never a patch site.
  - The metadata pointer is resolved against the header's ImageBase, or for a child copy, whose pointer is
    rebased, against the copy's RX base. The source pre-scan, the parent copy's budget and the patcher
    therefore agree.
  - An image with no code map is scanned as before.
- **The log line.** `[x18-patch]` now ends in `x64_skipped=N`, where -1 means no code map.
- **Host results, from the same functions compiled against the PE files:**
  - The stub's ntdll patches RtlProcessFlsData's site and leaves only its two x64 words.
  - opengl32's site is patched.
  - No x18 instruction outside x64 code is left unpatched in any of the 592 DLLs.
- **Host test.** `tools/tests/test_x18_x64_code.py` builds an image with that ntdll's words at their
  offsets and runs the scan functions as the series leaves them:
  - with a code map, both for a source mapping and for a rebased child copy;
  - without a code map, where the old failure is kept.

## Not checked

- **On the phone:** nothing yet.
  - It needs the Hollow Knight first-frame+10 gate.
  - It needs an RDR2 launcher run. 0204 changes the bytes of every ARM64EC DLL's x64 code back to what
    the linker wrote.
  - With 0204 the InitOnceExecuteOnce stub can be retried. Only the launcher run decides it.
