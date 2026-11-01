# World of Warcraft Classic Era (ARM64 client) start-up on the phone, 2026-10-31

**Linear:** PLA-514. Branch `dev/pla-516-battlenet`, madeira-unix 0252–0270, decision 0176 and its amendment; runs 2026-10-31 to 2026-11-01. The game was started from the Library
(`./pp ui --play bnet-wow_classic_era --until first-frame+60 --shot --wait 300`) as a native ARM64 child.
Run directories are under `.work/ui-runs/`.

## What blocked it, in order

1. **x18 compares not patched** (run 20261031T215841, IPA `9ee9987479c1eedfce817665aaf62f87335ee045b04afcb348e3b75991a1e32e`). The main thread spun in
   `WowClassic-arm64.exe`+0x2bb38, a loop inside the vectored handler (+0x2b870) that WoW calls for the
   `udf #0x9720` it raises at +0xd6c8 in a TLS callback. The handler does `cmp x18, #0x38; b.lo <loop>`; iOS
   zeroes x18 and the x18 patcher matched ADD/ADDS only, not SUB/SUBS (CMP). Reproduced off the phone by
   emulating the handler (Unicorn) on the run's JIT-pool dump: x18 = 0 reaches the loop, x18 = TEB returns
   `EXCEPTION_CONTINUE_EXECUTION` with Pc + 4. Fix: 0252. 239 `cmp x18` words exist in the exe (4x the rate of
   other registers); 16 of them sit on words a junk literal load targets, so the literal guard still leaves them.
2. **Single step** (run 20261031T222147, IPA `1d723cd19a4f5be8c03c7df25a18c3873f377bb66b27081983615b810604db8b`). The handler sets Cpsr.SS (bit 21) and steps the
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
   step, and a step that is dropped anyway is logged. Run 20261031T234647 (IPA `70718df4f0c43165766bc4814e27beee447e7a3ad8f12c5a828590203f6d360e`): no step was dropped,
   and the same store fault happened. Across runs the bad pointer moves by exactly as much as WoW's pool copy
   moves (0xc8000). So `w10` is consistent with a 32-bit RVA computed as *pool address* (from ADRP) minus
   *PE ImageBase* (from the loader): about 0x2e24ed8 into .rdata, offset by pool − PE. The native child runs the
   image from its JIT-pool copy, but PEB/LDR report the PE view's base, so any RVA WoW computes from its own
   code addresses against its module base is wrong. Making the pool copy the module's reported base for a
   native ARM64 child (PEB ImageBaseAddress, the LDR entry, VirtualQuery of it) is a design change in the
   loader and the virtual-memory views, and is not done here.

Hollow Knight on IPA `70718df4…` (the same): first-frame+10 passes (run 20261031T234751).

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

## Hash hypothesis, full x18 patching (madeira-unix 0263), and the jump target

- **WoW does hash its own .text.** In the emulator, the first TLS callback reads .text byte by byte
  in three loops over +0x2998–+0xb3760, about 181,000 bytes each (+0x22b9c, +0x2702c, +0x29134), plus
  two shorter ones at +0x284e0 and +0x28618. The x18 patches put 1,038 changed words in that
  range.
- **But serving the original bytes made WoW fail earlier.** A validation build sent those 14 loads
  to the PE view, which holds the original bytes, with a flag-free range check (runs 20261101T004745
  and 20261101T005322). WoW then took the decoy path at +0x53e8 after 8 UDFs; without the redirect it
  gets 13. So the jump into +0xb3790 does not come from a hash poisoned by patches; more likely,
  every hash WoW compares reads the same patched bytes. The validation code was dropped.
- **0263: the patcher now covers every instruction that reads x18.** That is, every logical,
  ADD/SUB, ADC/SBC, CCMP, CSEL, 1-, 2- and 3-source, bitfield and EXTR form, stores of x18, and
  CBZ/TBZ on x18 through a branch trampoline. The literal guard now leaves any x18 reader with Rd = 31
  as code. WoW's text: 196,547 sites patched, 694 left to fault. Run 20261101T010131: no change,
  13 UDFs, then the same jump.
- **Registers at the bad jump** (run 20261101T010647): `blr x26` at +0x26670 with
  x26 = pool + 0xb3790 (`add w7, w6, w17`, then the illegal word at +0xb3794). x20 and x21 point
  into WoW's `.data` (+0x3520000, +0x3880000). The stack above sp+0x170 holds instruction words: a
  code buffer WoW assembles. Where x26 is computed was not found statically (the function is
  obfuscated junk around it), and the emulator does not yet run past the first TLS callback.
  This is the open blocker.

Final IPA `5b14b446dc0c571f7a08c11c6ced7b4402b947a414c81ea862a9fe15f63266c4`:

| Check | Result | Run |
|---|---|---|
| Hollow Knight first-frame+10 | passes | 20261101T011141 |
| `d3d12` probe on Vulkan | exit 0 | 20261101T011230 |
| `arm64` probe | exit 42 (all checks pass) | 20261101T011306 |
| `pp test --quick` | passes | |

## The client remaps its own image (madeira-unix 0264, decision 0176 amended)

- **What it does** (diagnostic build logging a native child's memory calls, run 20261101T012702):
  `NtCreateSection(SEC_COMMIT | SEC_NO_CHANGE, 0x5dc7000)`, a read-write view of it, an RWX
  protect of the image, `NtUnmapViewOfSection` of the image, then three `NtMapViewOfSection` at
  the image's base (offset 0 RX 0x34d0000, `.data` RW, the rest RO). All three failed the 64 KB
  alignment check on the 16 KB-aligned pool copy, and the client jumped into encrypted bytes at
  +0xb3790. It then decrypts a function at a time in the read-write view and calls
  `FlushInstructionCache` on it (first: view+0xb3790, 0x400 bytes).
- **Encrypted .text.** 46 MB of the client's 48 MB .text is encrypted (a 1 KB window is either free
  of the unallocated encoding groups or about one word in eight in them; 142 windows are code). The
  x18 patcher had changed 196,547 encrypted words; it now leaves those windows alone (512 sites
  patched at load). 95 relocations on encrypted .text words were skipped by the copy; a native
  child's copy now gets them all.
- **The decrypted function at +0xb3790** checks that its return address lies between two
  literals and that its caller is a BL/BLR; on failure it overwrites the PEB forever. Copying the
  flushed bytes into the copy was not enough (run 20261101T020945: it spun in that loop); the
  read-write view is now remapped onto the copy's RW alias, so writes WoW makes without a flush
  reach the copy too.
- **Run 20261101T021958:** the three views map at the copy, the other views are one with it, the
  function at +0xb3790 is patched and passes its check, and WoW handles further UDFs and allocates
  another RWX buffer. It then spins at +0x33a44c (called from +0x336694). No login screen yet.

Gates on IPA `ff0cd315c663a22fd3591de6a1b852bacea65ac4782d01ac1be6fbaaf4a3ea26` (the 0264 build, the one run 20261101T021958 used):

| Check | Result | Run |
|---|---|---|
| Hollow Knight first-frame+10 | passes | 20261101T022522 |
| `arm64` probe | exit 42 (all checks pass) | 20261101T022617 |
| `d3d12` probe on Vulkan | exit 0 | 20261101T022648 |

## The client decrypts all of its .text at once (madeira-unix 0265)

- **The spin** (diagnostic build dumping the stuck thread's registers and code, run 20261101T023507):
  the main thread is in the third TLS callback (+0x3365f0, called with the image base and
  `DLL_PROCESS_ATTACH`; WoW put it and +0x3366f0 into its TLS callback list, which the file has as
  +0x43e8, +0x2f73a8, +0x2f7458). It calls +0x33a370, whose loop at +0x33a438 is
  `ldr x8, [sp, #0x10]; cmp w1, w8; b.ne …; …; cmp x18, #0xa7e; …; b.lo +0x33a46c; b +0x33a438`. With
  x18 = TEB, `b.lo` is never taken; iOS zeroes x18, so it loops forever. The decrypted code around
  it was not x18-patched: +0x33a06c (`cmp x18, #0x605`) was left too.
- **How it decrypts** (runs 20261101T024405 and 20261101T025321: every `NtFlushInstructionCache`
  logged, and a thread watching eight words of the copy's .text): after the remap and the flush of
  the function at +0xb3790, the only flushes are of 76 one-page RWX buffers, and then all eight
  watched words (+0x200000 to +0x2df0000) change within one sample, written by code at +0xb8544 (lr
  +0xb7a20). There is no flush on the way. Then WoW calls `FlushInstructionCache` on each of the
  copy's three views (0x34d0000, 0x2740000 and 0x1b7000 bytes). 0264 took as code only what the first
  word of a flushed range reaches, which for the whole image patched nothing.
- **The decrypted image** (run 20261101T030044, the copy's first view written out at that flush and
  compared with the file): 46,360 of the 47,103 1 KB windows of .text changed. 600 windows did not,
  most of them 0x2d000–0xb1000 and a few near +0xb3790, which still read as encrypted (10 to 40
  unallocated words in 256). A window threshold cannot tell the two apart: 63 decrypted windows hold
  more than 8 unallocated words (data in .text), and two unchanged ones only 10 and 11. `.pdata`
  lists the functions involved (+0x3365f0, +0x3366f0, +0x33a370 are in it; the protector's +0xb3790
  is not); 24 of its 160,236 entries sit in windows that are still encrypted.
- **Fix (0265):** a flush's patch run also gets a code hint: the image's `.pdata` function starts,
  and the windows in which a quarter of the words differ from the backing store of the remap. What
  those starts reach, following BL calls as well, is code, without leaving those windows. Run over
  the dump on the workstation with the series' patcher, it patched 40,590 sites with 0x115c40 bytes
  of trampolines, including +0x33a450 and +0x33a06c. Test: `tools/tests/test_x18_encrypted.py`.
- **Run 20261101T031619** (IPA `6cc28905b97f5c815402d61b25ff527cc5ea13842679610f7ec58003a4d77d79`):
  `[remap] … 46360 KB of .text … rewritten since the remap; the functions its .pdata lists there
  x18-patched (x18 trampolines 0x1194d8 of 0x618000 used)`. There is no spin. WoW passes its TLS
  callbacks, writes `Logs/cpu.log`, registers `Logs/gx.log` with WER (not written yet) and starts
  threads: 28 raise the planned UDF at +0x3367a4 in its thread-attach callback; two ntdll
  thread-pool workers exit. For the
  rest of the 240 s the main thread waits at 0% CPU in `NtWaitForAlertByThreadId`, from a loop
  at +0x293b618 that waits (through +0x2e5428) on each of a list of 0x40-byte entries; the worker
  threads (started at +0x309138 and +0x2404e48) wait too. No window, no login screen.
- **What 0265 does not reach** (same run): six `[x18-emul3]` faults at WoW +0xfc80, +0x12d490,
  +0x133c58, +0x133c88, +0x1c5b60 and +0x1d4dc0, all `ldr x8, [x18, #0x58]` (the TLS array), which the
  fault path emulates correctly. +0x12d488, for one, is a leaf function after `udf #0` padding that
  `.pdata` does not list and no BL the walk followed calls. A CMP or MOV of x18 in such a function
  would read 0.

Gates on IPA `6cc28905b97f5c815402d61b25ff527cc5ea13842679610f7ec58003a4d77d79` (the 0265 build):

| Check | Result | Run |
|---|---|---|
| Hollow Knight first-frame+10 | passes | 20261101T032159 |
| `arm64` probe | exit 42 (all checks pass) | 20261101T032252 |
| `d3d12` probe on Vulkan | exit 0 | 20261101T032323 |

## The idle was a thread the livelock breaker ended; then display_lock (madeira-unix 0266, 0267)

- **What the main thread waited for** (run 20261101T031619, read off the decrypted image): the loop at
  +0x293b618 creates WoW's worker threads one at a time (+0x2e5538: `_beginthreadex` suspended, store the
  start routine and argument in a slot, `ResumeThread`) and, after each, waits (+0x2e5428, a parking lot
  on `NtWaitForAlertByThreadId`) until the new thread's thunk (+0x2e5500) has taken them and cleared the
  slot. Every thread first raises the planned UDF at +0x3367a4 in WoW's `DLL_THREAD_ATTACH` callback.
  The Mach handler's livelock breaker (ml385/ml876) kept one count for the whole process; 28 threads at
  the same pc brought it to 50, and it logged `[fault-stuck] BREAKING LOOP: page 0x4000 pc 0x10c64e7a4
  repeated 50 times -> diverting thread to abort_thread` on the 29th, tid `00dc`, inside the callback:
  that thread never reached the thunk and the main thread waited for it for the rest of the run.
- **Fix (0266):** the breaker's rule moves to `pp_fault_loop.h`, keyed on the faulting Mach thread too: a
  fault on another thread starts a new run. Alignment faults stay uncounted (0132), a new address is
  still progress up to the storm ceiling. Test: `tools/tests/test_fault_loop.py`.
- **Run 20261101T033858** (IPA `62ef5567cd955ff8288c777fd79b61c4dd20693480ebb8c42136c493e24c130a`): no
  thread is ended; 57 threads start (named ones include `WowConnMain`, `bs Network`, `TACT Task Thread`,
  `WatchdogThread`), WoW loads dxgi.dll and DXVK's DXGI creates a Vulkan instance and finds the A19 Pro
  GPU. At +17 s the main thread faults in host code, `NtUserDisplayConfigGetDeviceInfo` (+0x170 into it)
  for `DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO`: a monitor whose output id matches has no
  source, and `monitor->source->gpu` reads address 0x120. The access violation goes to WoW's handler,
  which carries on, with `display_lock` still held; its next `vkGetPhysicalDeviceProperties`
  (`get_gpu_info_from_uuid` → `lock_display_devices`) waits on that lock, held by the same thread, for
  the rest of the run (`[thread-sample] … mutex=S1Probe\`display_lock owner_tid64=` itself).
- **Fix (0267):** the target-name, preferred-mode and advanced-color lookups in `sysparams_ios.c` pass
  over a monitor without a source, as `NtUserQueryDisplayConfig` does. WineHQ 11.20's `sysparams.c` has
  the same lookups. (`sysparams_ios.c` is what the iOS build compiles, not Wine's `sysparams.c`.)
- **Run 20261101T040227** (IPA `7b46d47396345036a31435624933277f00259dfb65b99a85ebac6063415035e9`, the 0267 build): no fault in the display code. vkd3d-proton
  creates the D3D12 device; WoW writes `Logs/gx.log` (pulled): `Force API D3D12`, adapter
  `"Apple A19 Pro GPU" 3GB … dx12:true`, monitor 1564x720 at 120 Hz, `D3d12 Device Create Successful
  (794.5 ms)`, `Using shader family dx_5_0`. Then the main thread repeats, 525 times in about 30 s:
  open a file, `NtAllocateVirtualMemory` 0x148000 bytes `PAGE_EXECUTE_READWRITE`, read 1,343,488 bytes
  into it, run code in it (an ILL at +0x8e520 of each copy). None is freed; each becomes a 1.3 MB JIT
  pool alias (aliases 103 → 621), the 896 MB pool is exhausted at about +35 s and the launch ends
  (`pool=exhausted:head`, the app's "ran out of JIT memory" alert). No window, no login screen yet.
  Which file this is, and whether WoW reloads it because a step in the loaded code fails, is open.
- Also: the 55 MB `wow-dec.bin` and a 940 MB `fex-jit-dump.bin` (diagnostic dumps in the title's config
  folder) were removed with `pp phone rm`, which now deletes a `title-cfg/TITLE/NAME.bin` and nothing
  else there. The unix stage's `LINK FAIL … libwineserver.a: duplicate symbol` line predates this work
  (release 0.3.0's log has it): `stage_linktest` links the archive without the `ws_` renames on purpose,
  beside the renamed one, which links (`LINK OK … libwineserver-ws4.a`).

Gates on IPA `7b46d47396345036a31435624933277f00259dfb65b99a85ebac6063415035e9` (the 0267 build):

| Check | Result | Run |
|---|---|---|
| Hollow Knight first-frame+10 | passes | 20261101T040449 |
| `arm64` probe | exit 42 (all checks pass) | 20261101T040540 |
| `d3d12` probe on Vulkan | exit 0 | 20261101T040611 |

## The 1.3 MB blobs were system32's ntdll; freed RWX memory gives its pool range back (madeira-unix 0268, 0269)

- **Which file, and the fault at +0x8e520** (run 20261101T040227, read off the run log and the decrypted
  image): the reads are 1,343,488 bytes, the size of the ARM64EC `ntdll.dll` the prefix's `system32`
  holds (`build-arm64ec/dlls/ntdll/arm64ec-windows/ntdll.dll`), and +0x8e520 is that file's export RVA of
  `NtProtectVirtualMemory` (its file offsets equal its RVAs in `.text`). The caller, WoW+0x10aa5c, sets
  `x0 = -1, x1 = &base, x2 = &size, w3 = 0x40, x4 = &old` and `blr`s into the copy: a hook-proof
  `NtProtectVirtualMemory(PAGE_EXECUTE_READWRITE)`. On Windows the file is ARM64X and the export is the
  native `svc #0x50; ret`; the ARM64EC file's export is the x86-64 stub (`4c 8b d1 b8 50 00 00 00 …
  0f 05 c3`), whose first word, 0xb8d18b4c, is unallocated in ARM64. Each ILL went to WoW's handler,
  which loaded the file again and called it again from inside the dispatch: the frame pointer at the ILL
  drops by 0x2380 a copy, 525 nested loads, none freed. Not an x18, relocation or flush problem.
- **Fix (0268):** both places such an ILL reaches, the Mach handler (which delivers it to the guest
  itself) and `ill_handler`, recognize Wine's x86-64 stub at the pc in a native ARM64 child
  (`pp_x64_syscall_stub.h`) and enter `__wine_syscall_dispatcher` as the child's aarch64 stub does (x8
  the number, x9 the return address). The numbers agree: all 265 `Nt*` x86-64 stubs of the ARM64EC
  ntdll carry the number of the same function's `mov x8, #id` stub in the aarch64 ntdll. A first build
  with the `ill_handler` path only (IPA `6f4eaa673dff731a4cb463c6af4a86e90d3d21b278fb18e39d1a6c4c97ff85e6`, run 20261101T042609)
  ran the first call of each iteration as a system call, but the second (restoring the protection)
  reached the Mach handler and the guest, and the loop went on.
- **Fix (0269):** a MEM_RELEASE of a native child's RWX memory now puts the alias's pool range on the
  free list (after the 3 s reuse grace) when the ledger records it whole for that process; before, the
  range stayed with the process until it exited. A native child's live RWX aliases are also held to a
  quarter of the pool: past it the child's own allocation fails, rather than a leaking guest exhausting
  the pool, which ends the launch for everyone. In run 20261101T042609 that budget refused 512 of WoW's
  further blobs (`[jit-pool] anon RWX … REFUSED`) and the launch was not ended (`head_exhausted=0`).
- **Run 20261101T043750** (IPA `bfbf4f78124c40361cdb9dfee954b9aea650d3f9927f1b886c207b2f8809e941`): two
  blobs, not 525. Through the stubs WoW calls `NtProtectVirtualMemory` twice on the child's ntdll page
  0x73fc0fc000 (and back), `NtCreateThreadEx` twice and `NtSuspendThread` on the new thread (all
  `[x64-stub] … (Mach)`). It goes on: vkd3d-proton creates the swap chain
  (`dxgi_vk_swap_chain_init_sync_objects`), mmdevapi and the audio stream start, `Logs` is written, 66
  threads. No frame is presented by +250 s (`kk-gpu frames=0`), no window or login screen.
- **The next blocker** (not fixed): the main thread runs at 98 % in WoW+0x2cb1b90 (`[thread-sample]`,
  lr +0x2cacdf0): `cmp x18, #8` at +0x2cb1b8c, then `b.lo` back into the same block, with x18 = 0. It is
  in `.pdata` function +0x2cb1018, in a case of the jump table at +0x2cb1af0 (`adr; ldrsw [x9, w0, uxtw
  #2]; adr; add; br x8`, table at +0x2cb3f34). The flush's code walk (0265) stops at a `br`, so no case of
  a switch is reached and their x18 reads stay unpatched: the gap the 0265 amendment names.
- **Probe:** `arm64.c` now also allocates, runs and frees 800 RWX blocks of 0x148000 bytes (about 1 GB,
  more than the pool's room), and reads `system32\ntdll.dll` into RWX memory and calls its
  `NtProtectVirtualMemory` export there. Run 20261101T045041: `rwx churn: 800 of 800`, the pool head at
  185 MB with 143 MB free (`anon RWX freed: #512 … back on the freelist`), `NtProtectVirtualMemory
  returned 0x0, old 0x4, now 0x2`, `done ok`. The x86-64 build passes under desktop Wine. Host test:
  `tools/tests/test_x64_syscall_stub.py`.

Gates on IPA `bfbf4f78124c40361cdb9dfee954b9aea650d3f9927f1b886c207b2f8809e941` (the 0269 build):

| Check | Result | Run |
|---|---|---|
| `arm64` probe (re-imported with the new checks) | exit 42 (all checks pass) | 20261101T045041 |
| Hollow Knight first-frame+10 | passes | 20261101T045202 |
| `d3d12` probe on Vulkan | exit 0 | 20261101T045256 |

## Every word of a `.pdata` function is code but its tables and literals (madeira-unix 0270)

- **The gap:** 0265's flush walk follows direct branches and BL calls from the `.pdata` function
  starts; a block entered only through a jump table and a `br` is never reached. The `cmp x18, #8`
  at +0x2cb1b8c (run 20261101T043750) is such a block.
- **Fix (0270):** a flush with a code hint also takes as code every word of each `.pdata` function,
  its length from the packed unwind data or its `.xdata` header, except the data kept among them:
  what an ADR, ADRP+ADD or ADRP+load offset addresses for a load in the next 8 words (a jump table,
  bounded by the compare or mask on its index, else to the function's end), and what an LDR
  (literal) loads. A data run must start where no code falls through to it: after a B, RET, BR
  (and their authenticated forms), a UDF, an unallocated word, up to 3 alignment NOPs, or data,
  and never at a function start. The literal rule needs that: in the Classic Era client 132,499 of
  the 170,883 literal loads in reachable code load a word of reachable code. A function with an
  unallocated word outside its data (still encrypted) is left to its start, as before.
- **Offline, over the decrypted image of run 20261101T043750** (`.work/agent-notes/wowrt/spin/`,
  the patcher as the series leaves `virtual_ios.c`): 40,590 sites before, 55,679 after (+15,089,
  none lost); +0x2cb1b8c is patched. None of the added sites is in the 31,678 words of the bounded
  jump tables an independent script (`spin/jt4.py`) finds; 891 are words an LDR (literal) loads
  that code falls through to. The run takes 0.26 s of host CPU for the 46 MB `.text`. Host test:
  `tools/tests/test_x18_encrypted.py` (a case reached only through a table, the table's
  x18-looking words and a literal after it unchanged, a function past an unallocated word left).

Gates on IPA `9447607cde41bc0f6a3c83a201d6a74e19f5fb54183ccec0b39bb6b1bde7ab7b` (the 0270 build):

| Check | Result | Run |
|---|---|---|
| Hollow Knight first-frame+10 | first frame at +9.09 s, passes | 20261101T100723 |
| `arm64` probe | exit 0x2a (all checks pass) | 20261101T100811 |
| `d3d12` probe on Vulkan | exit 0 | 20261101T100905 |

**World of Warcraft (retail) on the 0270 build.** Classic Era was uninstalled from the phone to free
space, so the retail client (`Wow-arm64.exe`) ran instead: `./pp ui --play bnet-wow --until
first-frame+90 --shot --wait 300`.

- **Run 20261101T101129:** no frame by +312 s (exit 2). The load's patcher patched 547 sites in the
  copy's `.text` (the rest was still encrypted). Unlike Classic Era, the client flushed one 1 KB window
  only (`[remap] … flushed 0x7043d15000+0x400, its copy at 0x108690000`, RVA 0xb5000), and the image's
  re-patch found no x18 site in it. The main thread then ran at 98 % CPU, every sample at
  `Wow-arm64.exe`+0xb5204.
- **Diagnostic run 20261101T102407** (IPA with the parked `spin/0265-DIAG-spin-dump.patch`, not
  committed; the clean IPA `9447607c…` was reinstalled after it): +0xb51e0..+0xb5214 is a byte-copy
  loop that copies 0x1000 bytes from the stack (`ldrsb w8, [x8]; … strb w8, [x12]; cbnz x10`). It reads
  no x18. Its destination x12 = 0x141a1c94c is in the client's own PEB page (`child_peb=0x141a1c000`).
  Between the 2 s and 10 s watchdog dumps the destination moved from 0x141a1c1d3 to 0x141a1c94d
  (1,914 bytes in 8 s, x10 0xe2d → 0x6b3) while the process handled about 600 Mach exception
  messages. The PEB page now starts with the page's own address and a return address
  (`0x10a5dab10`, +0x27b10). All of the 28,672+ `x18-redir2` dispatches to `KiUserExceptionDispatcher`
  happened before the flush. Still open: where the destination comes from, why each store costs
  about 4 ms, and what the same loop writes on Linux. This is the next blocker. It is not an x18
  rewrite gap.

## The read-write view was never one with the copy; retail reaches its login screen (madeira-unix 0271)

- **Correction to the last part.** The loop at +0xb51e0..+0xb5214 does not run slowly. Its last
  instruction (`b +0xb51e4`) starts the 0x1000-byte copy again, without end. The 2 s dump caught it
  0x94d bytes in and the 10 s dump 0x1d3 bytes in. The process ran at IPC 7.7 with 296 of 303 ms in
  user time per sample, so no store traps. The about 75 Mach messages/s came from other threads.
  The destination is the caller's x9, which held the PEB.
- **Runtime cause.** Run 20261101T102407's remap lines read `0 bytes of other views made one with
  it` for all three views. The copy started at 0x10a5b3000: the pool shift (ml141) had moved the
  copy 0x3000 past a 16 KB page so that `.data` would start on one (`[data-align] Wow-arm64.exe
  shifted +0x3000`). The client's read-write view of its section (0x7043c60000) is page aligned, so
  no page of it could be `vm_remap`ped onto the copy (0264), and the two stayed separate memory.
  A write through the view reached the copy only on a flush, and a write at the base never reached
  the view. On Windows they are one memory, and the client wrote the 1 KB window at RVA 0xb5000
  through that view.
- **Fix (0271, `pp_copy_align.h`).** In a native ARM64 child, whose copy is the image, the copy is
  shifted only when an executable section reaches into the page its first writable section starts
  in. Otherwise it starts on a page, as Windows starts an image on 64 KB. x86-64 and ARM64EC
  processes keep the shift. Host test: `tools/tests/test_copy_align.py` (retail's layout, `.text`
  ending in `.data`'s page, code later in that page, aligned and read-only layouts).
- **Run 20261101T104647** (fix plus the spin-dump diagnostic, IPA
  `6bf94f3b5e991516d76d07f0c1132a17789f448824601f40e51eb04d2a70e595`, not kept): the copy is at
  0x10a378000, and the remap lines read 0x4320000, 0x28a0000 and 0x208000 bytes made one (all but
  the last 0x3000). The client flushes the window and then its 59,820 KB of rewritten .text, which is
  x18-patched (trampolines 0x27765c of 0x7c8000). First window at +31.5 s and first frame at +32.1 s.
  The stop screenshot shows the login screen: Email or Phone, Password, Remember Account, Log In,
  Create Account, Menu, Quit, "Version 12.1.5 (70688) (Release arm64)", with the Screen Narrator
  prompt over it. The background is black, with no login scene. `Logs/gx.log` (pulled into the
  run's `wow/`): `World of Warcraft Retail ARM64 12.1.5.70688`, `Force API D3D12`, `"Apple A19 Pro
  GPU" 3GB … dx12:true`, `D3d12 Device Create Successful (782.3 ms)`, `Using shader family dx_5_0`.

Gates on IPA `fce8b0f432902b8567cd35e29205605ecd13a82eae5d9c3d811a12739c82ff06` (the 0271 build):

| Check | Result | Run |
|---|---|---|
| Hollow Knight first-frame+10 | first frame at +9.84 s, passes | 20261101T110018 |
| `arm64` probe | exit 0x2a (all checks pass) | 20261101T110124 |
| `d3d12` probe on Vulkan | exit 0 | 20261101T110227 |
| `./pp test --quick` | all passed | host |

**World of Warcraft (retail) on the 0271 build** (`./pp ui --play bnet-wow --until first-frame+90 --shot
--wait 300`, run 20261101T110435, exit 0): first window +23.6 s, first frame +24.0 s. The remap lines
are the same as in the diagnostic run (all but the last 0x3000 bytes made one). The screenshot shows the
same login screen, and the owner sees only text on black: the fonts are drawn, but not the background,
frames, buttons or logo. The Screen Narrator prompt overlaps the login fields because its box is not
drawn. `Logs/gx.log` has 25 lines, the same as above, ending `UAV format support BGRA8:true RG16F:true
RGBA16F:true` and `<IsGPUDriverOutOfDate> No`. It has no texture-format, compressed-format or error line.
The host log has no vkd3d-proton format warning. vkd3d-proton logged two `fixme`s (`Wide lines not
supported` and `Narrow quad lines not supported`, from `rs_line_info_from_d3d12`) and DXVK's DXGI some
`warn`s (`Found monitors not associated with any adapter, using fallback` and stubs). The swapchain is
`[kk-wsi] create chain format=44 … 1564x720 images=3`. Two SEGVs (reads at the base of the read-write
view, 0x7043c60000, from RVA +0x346e8c, after the client had unmapped it: `NO wine view`) went to the
client's handler and it carried on. Runs before 0271 never got this far. The missing textures are the next blocker.

## x18 coverage against the Linux reference; SIMD pairs and a third scratch register (madeira-unix 0263 amended)

PLA-516. The reference (PLA-608, `$PLAYPORT_BUILD/ref-arm64/REFERENCE.md`) ran the Classic client's ARM64 image
under Wine for aarch64 Linux in qemu TCG to its login screen and recorded every executed word with a
register field of 18: 1,471 executed x18 readers (`x18-executed-classic.txt`), and in run c11-cnt how
often each ran (`x18-counts-classic.txt`, plugin `x18cnt`). The patcher, as the series leaves
`virtual_ios.c`, ran offline over the phone's dump of the decrypted Classic image (run 20261101T030044) as the
phone runs it: the load pass (cipher 1) over the file's `.text`, then the flush pass (cipher 2, `.pdata`
hint) over the 46,360 windows rewritten since the remap. Every rewritten word was checked with
`ios_x18_patched_site` against its original.

| The 1,471 executed x18 readers | Before | After |
|---|---|---|
| Rewritten by the flush pass | 1,347 | 1,347 |
| Rewritten by the load pass (a B in the dump too: all 512 load-pass sites are) | 89 | 89 |
| Left, completed by the `[x18-emul3]` fault path (`ldr x8, [x18, #0x58]`, the TLS array; one `ldr x8, [x18, x8]`): leaf functions `.pdata` does not list | 31 | 31 |
| Left, harmless: Rd = xzr without flags (`sub wzr, w18, w16, lsr #1`) | 3 | 3 |
| Left, reading 0 | 0 | 0 |
| Not in the dump as executed: +0xb3824 `ldr x8, [x18, #0x60]` in the protector's self-rewritten function at +0xb3790 (the dump has other code there, with B words of an earlier flush pass) | 1 | 1 |

The 31 emulated sites ran 2 to 179 times each in c11-cnt (179: +0x12d490, +0x133c58, +0x133c88, +0x1c5b60,
+0x1d4dc0; 68: +0x2d9bea0, +0x2df56d0, +0x2dfd438; 0: +0x28b5fd8; the rest 2): no hot path runs
through the exception handler. The hottest readers are TLS-array loads the flush pass rewrites
(+0x23d6e8 3,810,775 times, +0x24f330 and +0x24f2a0 2,040,065, +0x246cb8 1,912,184, +0x168128c 1,909,524,
+0x1681f1c 1,876,137). +0xb3824 ran 668,189 times, about 26 per raise of the UDF at +0x1297c that Linux
re-raises some 26,000 times without a single step; the phone takes the other path there (0253).

What the patcher did beyond the readers was wrong in one class: ios_insn_x18_role took Rt2 = 18 of
every LDP/STP as x18, also in an LDP/STP of SIMD and FP registers (V = 1, `ldp q19, q18, [x8], #0x20`,
`stp s19, s18, [x10, #0x50]`) and in a load into x18. Such a pair was rewritten to q17/s17 (s16 when
it named x17): 2,003 words in the Classic client's code (14 in the load pass, a copy loop at
+0x22904…+0x2ccc8; 1,989 in the flush pass). 220 of them ran 132,000,579 times in c11-cnt, each
loading or storing the wrong register (+0x1991db0…+0x1991ee8, 3,101,760 times each). WowTextures' d3d12
probe (`stp s16, s18, [x13]` in its quad loop) draws its quads wrong on the phone the same way. An
instruction naming both x16 and x17 (`subs x17, x18, x16, lsr #28`, `madd x16, x29, x17, x18`) was
left to read 0: 48 code words. 0263 now gives Rt2 the x18 role only in an STP of X or W registers, and
takes the first of x17, x16, x15 … the instruction does not name as its scratch register; the single
step (0259's `ppss_x18_tramp`) and a re-flush (0264's `ios_x18_patched_site`) read it from the
trampoline's first word. Over the dump: load pass 512 → 499 sites, flush pass 55,679 → 53,737
(trampolines 0x17da5c → 0x1705f4 bytes), none skipped, no word rewritten that does not read x18, and the
1,471 readers as in the table. Tests: `tools/tests/test_x18_compare.py`, `test_single_step.py`,
`test_x18_x64_code.py` (ntdll's x64 word 0xec834817 is such an STP of d18 and no longer an x18 site).

Left as they are: 1,198 code words that move x18 into SP (`sub sp, x18, #0x1a0`, `mov sp, x18`), none
executed in the reference (the trampoline moves SP). Three data words the flush pass rewrites as code
are loaded by code that ran in the reference: +0x322808 (the 8-byte constant 1,000,000,000 that
`ldr x14, #0x322808; … mul x8, x8, x14` at +0x3226bc multiplies by, right after a `bl` to a function
that does not return), +0x11593c (loaded by `ldr x26, #0x115938` at +0x111f18) and +0x10ce0c (by `ldr x8,
#0x10ce08` at +0x10bdc0). Each sits in its function's constant data after a word that reads as an
instruction falling through, which 0270 takes as code; the client loads its own code as literals
2,897 times among the rewritten words, so the literal alone does not tell them apart (PLA-609).

## The login screen draws: the textures were never a format problem (0263 amended, IPA e460d772)

On IPA fce8b0f4 (run `20261101T110435`) retail drew only text on black. The leads were the GPU side;
none held:

- **BC formats work.** KosmicKrisp reports `textureCompressionBC` and maps BC1–BC7 to Metal's BC
  formats; the A19 Pro is Apple9-or-later, where Metal samples BC natively. vkd3d-proton answers
  `D3D12_FEATURE_FORMAT_SUPPORT` for BC1/2/3/4/5/7 with support1 `0x9013e0` (TEXTURE2D,
  SHADER_SAMPLE, MIP; RADV `0xd013f0` adds TEXTURE1D and gather) and reports UMA, cache-coherent UMA.
- **Nothing in the driver logs.** With `VKD3D_DEBUG=warn` (run `20261101T112608`) vkd3d-proton warned
  only at device creation (no `VK_EXT_dynamic_rendering_unused_attachments`, A8 as R8, D24S8 as
  D32S8, SM 6.6 caveats); no resource, heap or format warning. Metal API validation (`pp gpu
  validate`, `.work/gpu-runs/20261101T112919`) found 134,267 messages, all redundant state or
  render-target residency notices, no error, no command buffer error. A frame capture
  (`.work/gpu-runs/20261101T113228`, frame 900) has the whole frame: an 80-draw depth pass of
  13,533 elements (the login scene), bloom downsamples and a 22-draw UI pass, so the GPU was drawing
  everything the client asked.
- **The d3d12 probe now samples textures.** `tools/compat/probes/d3d12.c` draws 24 textured quads
  beside its triangle and checks each quad's colour in the read-back frame: R8G8B8A8, B8G8R8A8,
  BC1/2/3/7, A8 and R8 with swizzles, B5G6R5, B5G5R5A1, B4G4R4A4, sRGB views of TYPELESS textures,
  7 mip levels (each level its own colour), placed in a default heap, copied from a buffer placed in
  an upload heap, written by WriteToSubresource into a custom L0 write-back heap, copied on a copy
  queue, and point/anisotropic heap samplers. Desktop Wine with vkd3d-proton 3.0 on RADV: all 24 ok.
  The first phone version (8 quads, one row) passed on fce8b0f4 (run `20261101T112316`); the
  24-quad version failed there (`20261101T114345`, exit 8) with the top row's colours wrong and, on
  screen (`20261101T120323`), every quad stretched into a strip down the window: its vertices were
  wrong. Leaving out the custom-heap and copy-queue checks, the A8 check, the heap samplers, or
  vkd3d-proton's allocation clears (`VKD3D_CONFIG=memory_allocator_skip_clear`) changed nothing.
- **The quads' vertices are written by `stp s16, s18, [x13]`** (and `stp s17, s18`, the y value in
  s18) in the probe's own loop, the instruction class 0263 rewrote to s17 (section above). With
  0263 amended (commit `64d7a8d2`) on IPA e460d772cd52c919a0575766959a88764c489908fce1db0c20944d21cfc23dbb
  the probe passes all 24 checks (`20261101T121847`, exit 0, `--settings
  'dir-d3d12:{"graphics":"vulkan"}' --play dir-d3d12 --wait 180`).

The same IPA, run `20261101T121944` (`--play bnet-wow --until first-frame+90 --shot`): the login
screen draws in full. The Midnight logo top left, the animated login scene through a ringed portal
with crystal wings either side, the Blizzard logo, the version and copyright lines, red Log In,
Menu, Create Account and Quit buttons, and the Screen Narrator dialog in its framed box with Enable
and Disable buttons over the login fields (it hides them until answered). So the text-only screen
came from the client's own code, not the driver: the only change between the two IPAs is the x18
patcher's (0263/0264: SIMD pairs keep s18/q18, a third scratch register). Which of the client's copy
loops and float stores fed the missing draws is not traced; that the
text survived because other code builds it is an inference. The same IPA:
Hollow Knight (Vulkan backend) first frame +9.81 s (`20261101T122231`), the arm64 probe exit 0x2a
(`20261101T122330`).

The d3d12 probe must be imported again after it is rebuilt (`pp phone put …
Documents/Import/d3d12/d3d12.exe`, then `uninstall:dir-d3d12` and `import:Import/d3d12`, or the
import lands as `dir-d3d12 2`); `skip I,J` on its command line leaves checks out.
