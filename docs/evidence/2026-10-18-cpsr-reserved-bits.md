# Reserved CPSR bits: WineHQ 7fb24b7 hand-ported into the iOS replacements

**Date:** 2026-10-18. **Linear:** [PLA-390](https://linear.app/playportdev/issue/PLA-390)
(under PLA-76, the [Proton ARM64 alignment plan](../plans/2026-10-05-proton-arm64-alignment.md),
item W8b; related to PLA-302, PLA-303 and PLA-304). **Branch:** `dev/pla-76-proton-alignment-ws`,
built in the owner-authorized side copy (its own build area; no install, no phone). The owner was
away, so the conservative option was taken: the commit as upstream wrote it, at the sites the iOS
files share with upstream, and nothing more. **Status:** built to a verified dev IPA; **not
checked on the phone.**

## What upstream changed

WineHQ `7fb24b7` "ntdll: Ignore attempts to set reserved CPSR bits" (in wine-11.20; Valve's
bleeding-edge has it as `f9a7e33`) adds `cpsr_user_mask` (`0xf620fc30`) to `unix_private.h`
and `cpsr_host_mask` (`~cpsr_user_mask | 0x1000`, the host bits and SSBS) to `signal_arm64.c`.
A context that Windows code sets keeps only the user bits, and a signal handler that returns to a
context keeps the host bits of the interrupted state. wine-11.20's [move](2026-10-18-wine-11.20.md)
brought the `unix_private.h` half, but `build/ntdll-unix/build.sh` builds Madeira's
`signal_arm64_ios.c` and `thread_ios.c` in place of `signal_arm64.c` and `thread.c`.

## The port: madeira-unix 0161 (`madeira-port`)

| Upstream hunk | iOS site | Ported |
|---|---|---|
| `unix_private.h` `cpsr_user_mask` | wine-11.20's own `unix_private.h`, which the replacements include | already there |
| `cpsr_host_mask` | `signal_arm64_ios.c`, after the ESR definitions as upstream | yes |
| `save_context`: Cpsr from the signal state, user bits only | `save_context` | yes |
| `restore_context`: keep the signal state's host bits | `restore_context` | yes |
| `NtSetContextThread`: `frame->cpsr`, user bits only | `NtSetContextThread` | yes |
| `set_thread_wow64_context`: the ARM WoW64 frame's Cpsr, user bits only | `set_thread_wow64_context` | yes |
| `save_syscall_entry_frame` | none: the iOS `usr1_handler` does not build a syscall frame from the signal state (the iOS dispatcher's x18 load) | no |
| `usr2_handler`: keep the signal state's host bits | `usr2_handler` | yes |
| `thread.c` `context_to_server`, ARM and ARM64 | `thread_ios.c` `context_to_server` | yes |
| `tests/exception.c` | a PE test; Wine's tests are not built or run here | no |

The bits FEX's ARM64EC and WoW64 modules read and write in a native context (NZCV, and bit 21 for
the x86 trap flag) are all user bits, so the guest flags pass through unchanged. Playport's own
context patches (madeira-unix 0136, 0137, wine-unix 0036, fex 0037, wine-pe 0042;
[2026-10-13](2026-10-13-wow64-thread-context.md)) do not touch these lines and are unchanged.

Left as before:

- **wineserver's Mach capture.** `mach_ios.c` `ios_fill_thread_context` still reports a suspended
  thread's whole `__cpsr` to `GetThreadContext`. Upstream's equivalent is the suspended thread's
  own `save_context`, which now masks. A reader can therefore still see host bits; a writer
  cannot set them. This was not changed: it is a server-side, iOS-only path outside the commit.
  madeira-unix 0162 changed it later ([below](#the-read-side-madeira-unix-0162-2026-10-19)).
- **The PLA-122 `[ua-ctx]` log.** It prints the raw host CPSR beside the frame's. After this change
  the frame's value holds only the user bits, so the two can differ by host bits.

## Host test

`tools/tests/test_cpsr_reserved_bits.py` (run by `pp test`) takes the masking lines from the patch
file and compiles them against a model ucontext. It checks five things:

- the five user-mask sites and the two host-mask sites are present;
- upstream's `test_thread_context` property holds: setting `~orig` flips exactly `0xf620fc30`;
- the host bits and SSBS survive `restore_context` and `usr2_handler`;
- every NZCV and trap-flag pattern FEX writes reaches the restored state;
- a save after a restore returns the same pattern.

## Build

- **IPA (dev):** `$PLAYPORT_BUILD/out/20261018-084619-399bcfd8/Playport-26.5-399bcfd8.ipa`.
  - sha256 `399bcfd8dd9c014095a40b1292e85011b15eeb5275fe95589bad1c73d492e11e`.
  - 412,508,307 bytes.
- **Checks:**
  - verify-ipa reported 86 passed and 0 failed;
  - `pp verify` reported 0 failures;
  - the unix stage's ntdll build reported 37 files compiled and 0 failed, and its `libwineserver.a`
    link test shows the same four duplicate symbols as before.
- **Disassembly:** in the built `signal_arm64.o` and `thread.o`, the CPSR stores AND with
  `0xf620fc30` and the restores with `0xf620ec30` (`~cpsr_host_mask`).
- **Record:** `lib/libntdll_unix.a` is the one record that changed.

## Owed on the phone (not checked)

On this IPA:

- Hollow Knight (`app-367520`) first frame+10;
- Portal 2 (`app-620`) first frame+10;
- the `threadctx` probe (`dir-threadctx 4` and `dir-threadctx-i386 4`), which exercises
  `SetThreadContext`/`GetThreadContext`; its checks a–e should read as in the 2026-10-13 final
  column.

No title is known to depend on setting reserved CPSR bits.

## The read side: madeira-unix 0162 (2026-10-19)

**Linear:** [PLA-303](https://linear.app/playportdev/issue/PLA-303). **Branch:**
`dev/pla-303-cpsr-read-side`, off `main` `9d0f44c`, built and tested in the main checkout. The
owner was away, so the conservative option was taken: mask the two reads, nothing more.

The M2b runs ([proton-alignment-phone](2026-10-18-proton-alignment-phone.md)) checked 0161 on the
phone, with the threadctx probe unchanged. This closes the gap left above: wineserver's Mach
capture now reports only the user bits, as the thread's own `save_context` does.

### The patch

`patches/madeira-unix/0162-wineserver-report-only-the-user-CPSR-bits-from-the-M.patch`
(`Class: madeira-port`, the follow-up of 0161; `Offered-upstream: no`). In
`wineserver/mach_ios.c` `ios_fill_thread_context`:

- the Mach state's `__cpsr` is masked with `IOS_CPSR_USER_MASK` (`0xf620fc30`);
- for a thread in a syscall, the syscall frame's `cpsr` is masked the same way. A frame ntdll
  wrote already holds only user bits (0161's `NtSetContextThread`), so this changes nothing there.

`IOS_CPSR_USER_MASK` is a copy of `cpsr_user_mask`, not a shared definition: it is in ntdll's
`unix_private.h`, which the server cannot include, and Wine has no header both share. The host
test checks that the two values are the same.

### Places checked

| Place | What it reads | Result |
| --- | --- | --- |
| `mach_ios.c` `ios_fill_thread_context`, the Mach state | `arm.__cpsr` into `arm64_regs.pstate` | masked (0162) |
| `mach_ios.c` `ios_fill_thread_context`, the syscall frame | the frame's `cpsr` at `0x108` | masked (0162) |
| `mach_ios.c`, the x86-64 and i386 guest views | `ContextAmd64.EFlags` and the WoW64 context's `EFlags`, both from FEX, not the CPSR | no CPSR read |
| `thread_ios.c` `context_from_server`, ARM and ARM64 | the server's `pstate`/`cpsr` into `Cpsr` | unchanged; upstream does not mask here either, the producer does |
| `signal_arm64_ios.c` `NtGetContextThread` (current thread) and `get_thread_wow64_context` | the syscall frame's and the ARM WoW64 frame's `Cpsr` | unchanged, as upstream; both are written masked |
| `signal_arm64_ios.c` Mach exception handler and the other `thread_get_state` users (hang watchdogs, stack samplers, `ios_abort_thread_in_guest_code`, sub-floor and unaligned-atomic emulation) | `pc`, `sp`, `fp`, `lr` and `x` registers | none reads `__cpsr` into a CONTEXT |
| PLA-122 `[ua-ctx]` | the signal state's raw CPSR | log only |
| `app/Sources/WineHost/wine_host.c` sampler | `pc` and `x18` | no CPSR |
| ARM64EC `cpsr_to_eflags` (`dlls/ntdll/unwind.h`) | bit 21 and NZCV only | all user bits: the masks cannot change a guest EFlags |

### Host test

`tools/tests/test_cpsr_reserved_bits.py` has a second test, `test_read_side`. It takes the two
masking lines and the mask from 0162 and compiles them, with 0161's `save_context` and
`NtSetContextThread` lines, against a model of the Mach state, the frame and the server's context:

- the mask equals `cpsr_user_mask`, and the patch has two masking sites;
- a capture of a host state with reserved bits set returns what `save_context` would;
- all 32 NZCV/trap-flag patterns pass through;
- a frame ntdll wrote reads back unchanged.

Removing either mask fails it.

### Build and phone

- **Build:** `./pp build` (dev), unix stage only, then stage, notices, app and verify. The
  `libwineserver.a` link test shows the four known duplicate symbols. The built
  `wineserver/obj/mach_ios.o` has two `mov #0xfc30; movk #0xf620` pairs.
- **IPA (dev):** `$PLAYPORT_BUILD/out/20261019-092035-0bd623f2/Playport-26.5-0bd623f2.ipa`.
  - sha256 `0bd623f2bddee654792ff6535dd45f15231cd01d2a3b68d161dbd66efab7f06a`.
  - verify-ipa: 89 checks passed, 0 failed.
  - `provenance.txt` says `9d0f44c` "with local changes", because the build ran before the
    commit (`115ecf1`, the `installed` event's head).
- **Record:** `lib/libwineserver.a` is the one row that changed.
- **Checks:** `./pp test` (full) passed: `tools/tests` 662, the C tests and every Swift package.
- **Phone:** iPhone18,4, iOS 27.0.1, battery 57–60 % and charging. One `pp phone lock` session ran
  the install (`pp install --no-build`, in place), Hollow Knight, then the threadctx probes. The
  probes were put, imported through the UI, played, and uninstalled through the UI. Both
  uninstalls report the folder, record and stage gone and not catalogued. The run directories are
  under `$PLAYPORT_BUILD/ui-runs/`.

| Run | What | JIT | Result |
| --- | --- | --- | --- |
| `f5-hk` | Hollow Knight (`app-367520`), `--until first-frame+10 --shot` | 2.42 s | first frame **+8.78 s**, FEX disk cache warm (hits 106,494, misses 1). The screenshot shows the main menu with Start Game highlighted and the touch controls drawn |
| `f5-probe64` | `threadctx`, x86-64 | 2.38 s | ends after 4 s, `done FAIL` (check d-set-spin only), no crash report |
| `f5-probe32` | `threadctx-i386`, WoW64 | 2.32 s | ends after 4 s, `done FAIL` (check d-set-spin only), no crash report |

The probe executables are the ones M2b and M3 ran (`threadctx.exe` sha256 `ab7fd947…`,
`threadctx-i386.exe` `d7e72b54…`).

| Check | M2b, 64 / i386 (`6e68a205`) | this IPA, 64 / i386 |
| --- | --- | --- |
| a: never-run thread | ok / ok | ok / ok |
| d: `SetThreadContext` on a never-run thread | ok / ok | ok / ok |
| b: spinning thread, 16 of 16 | ok / ok | ok / ok |
| c: thread in `WaitForSingleObject` or `Sleep`, 4 of 4 | ok / ok | ok / ok |
| e: a second suspension sees the counter move on, 3 of 3 | ok / ok | ok / ok |
| d: `rax`/`eax` set on the spinning thread reaches it | BAD / BAD | BAD / BAD (unchanged, PLA-303) |

- With addresses masked, every `CHECK` and `a-unstarted` line matches M2b text for text.
- The never-run thread's flags read `0010000b` and `00010007`, as before.
- The server substituted the syscall frame (`[ctx-frame] ml716`) 8 times in each probe, as in
  M2b, so both masked reads ran.

No title is known to depend on reading reserved CPSR bits. The x86 guest's EFlags come from FEX,
not from the CPSR, so no x86 title can see the change.
