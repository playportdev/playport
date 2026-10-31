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

## Where it stands

Run 20261031T225422 (IPA ad5948b6…): the UDF is handled and single steps run (d6cc, d6d0, …). Each out-of-line
step's BRK also reaches the Mach exception thread, whose `[fault-stuck]` breaker counts the same pc 50 times
and aborts the thread. WoW exits with code 0 before its log or window exists. **Not working yet**. The next
fix is to exempt `PPSS_BRK` from that breaker (signal_arm64_ios.c, `[fault-stuck]`). No login screen, no gx.log,
and no Hollow Knight gate on these IPAs.
