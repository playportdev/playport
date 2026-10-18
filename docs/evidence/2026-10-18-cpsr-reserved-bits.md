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
