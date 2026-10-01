# Software-separated Win32 memory experiment

This is a **host-tested memory prototype**, not a shipped runtime, PE loader,
WoW64 bridge or emulator. Nothing in the app calls it. It cannot run Portal 2.
It establishes the first memory contract from
[the Portal 2 investigation](../../docs/evidence/2026-10-01-portal2-32-bit.md).
The app remains x86-64-only; no runtime decision or pin is changed.

## Contract

Each `g32_space` reserves a separate, non-executable 4 GiB backing window above
4 GiB. Guest addresses remain `uint32_t`; host addresses are `uintptr_t` or
pointers. Translation adds the backing base **after** checking the complete
access and every page's permissions. Reverse translation checks ownership and
permissions before producing a guest pointer. Guest arithmetic wraps to 32 bits
before translation, but an access straddling the end of the window faults.

Reservations begin at 64 KiB boundaries; guest pages are 4 KiB. The low 64 KiB
is inaccessible. Commit zeroes only new pages; recommit preserves data. Decommit
and release zero discarded guest pages and leave committed neighbors intact.
An unused whole host page becomes `PROT_NONE` and is advised for reclamation.
Release accepts only an allocation's original base. A VM operation cannot span
two reservations; an ordinary memory access can when both permit it.

A 16 KiB host page can contain four guest pages with different permissions.
**Native `mprotect` cannot enforce their permissions independently.** Committed
backing is RW, never executable; `G32_EXEC` permits instruction-byte fetch only.
Every fetch, load, store, string operation and atomic must use equivalent
software checks, including full access width. A raw unchecked `base + address`
in a JIT or syscall bridge is wrong, even if another guest page makes that host
page readable. Pointer loans require external serialization and expire at a VM
change. This prototype has no concurrent-access/lifetime protocol. Failed native
protection operations poison the space; only destruction is safe afterward.

## Checks

`./pp test --quick` includes `guest32_test.c`. The same cases run with actual host
pages and simulated 16 KiB and 64 KiB host granules. They cover the installed
launcher's preferred address (`0x400000`) and image extent (`0x5c000`), **not its
PE contents or execution**; ownership, native/guest pointer conversion,
null/uncommitted/protected pages, access across pages and reservations, upper
address overflow, all-or-nothing permission validation, recommit and zeroing.

For sanitizers:

```sh
mkdir -p .work/guest32
clang -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined \
  build/guest32/guest32.c build/guest32/guest32_test.c \
  -o .work/guest32/test-sanitized
.work/guest32/test-sanitized
```

## Still needed before a title launch

- Automatic allocation/address queries, Windows guard/write-copy semantics,
  concurrent VM changes and safe translated-code invalidation.
- FEX instruction decode/fetch, every memory emitter and atomic/string path
  translated and checked; exceptions reported with guest addresses; tests of
  real x86 instructions, not just this C API.
- Wine i386 images and a WoW64 CPU bridge with explicit nested-pointer and
  callback marshalling, guest PEB/TEB/stack and syscall arguments. High-address
  native Wine objects cannot simply be truncated into 32-bit fields.
- An i386 D3D9/Vulkan bridge into the native graphics stack, plus audio/input.
- Integration only via patch series and the product UI. First a Portal 2 menu,
  then gameplay, save/reload and Hollow Knight regression plays on the phone.

This window proves software backing is possible on the Linux host. It does not
prove the 4 GiB reservation works in the iOS process or that a checked FEX/Wine
bridge is complete or fast enough for gameplay.
