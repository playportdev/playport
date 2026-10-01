# Software-separated Win32 memory experiment

This is a **host-tested memory, PE32 mapping and import-binding prototype**, not a shipped
runtime, complete Windows loader, WoW64 bridge or emulator. The dev app can
exercise the memory contract from Settings; no game uses it. It cannot run
Portal 2.
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

## PE32 image materialization

`pe32.{h,c}` maps i386 PE32 file buffers into guest reservations, copies headers
and sections, zeroes BSS, applies HIGHLOW/ABSOLUTE relocations and sets per-guest-
page permissions. All guest addresses, including the returned entry point and
IAT slots, remain 32-bit values. It never executes backing natively. Relocation
records are snapshotted before applying fixups, so a fixup cannot mutate a later
record while it is being parsed. Mapping failures leave output unchanged and
release only the reservation obtained by that call, never a conflicting one.

Import inspection reads bounded descriptors, lookup tables, IAT slots, DLL and
symbol names through checked guest reads, including ordinal imports and the
FirstThunk fallback. `g32_pe_bind_imports` snapshots those names and guest IAT
addresses, then uses a caller-supplied resolver to stage guest target addresses.
It validates every target and writable IAT slot before writing any slot. Targets
may be readable data or fetchable code in the same space; wide resolver output
rejects native pointers rather than truncating them. Duplicate/byte-overlapping
IAT slots are rejected, and binding failures preserve guest bytes/protections.
Resolver-side effects cannot be rolled back: callbacks must not modify guest
memory, change mappings or reenter the API. Only serialized use is supported.

Binding requires already-writable IAT pages and does not broaden permissions.
The installed launcher and engine each have all IAT slots in one **read-only**
guest page, so a future loader must bind before final protections (or explicitly
manage temporary page permissions). This experiment does not do that for games.
The FirstThunk fallback is snapshotted before writes but cannot be rebound after
its lookup data is overwritten. Import inspection/binding does **not** load or
resolve dependencies itself, initialise TLS, construct Windows process state,
call DllMain or execute an entry point. Image metadata is native ownership state,
not a guest ABI structure; it expires when its reservation is released.

The parser deliberately supports page-aligned sections (alignment at least
4 KiB), at most 96 sections, 16 data directories and a 512 MiB image. Import
inspection has a total one-million-thunk budget; binding stages at most 65536
imports. Bound-address/delay imports and automatic export-forwarder resolution
are not supported. These are experimental
resource/format limits, not a statement of full Windows loader compatibility.
Guard pages, shared/write-copy mappings and discardable sections are not yet
implemented. Headers retain the file's original preferred ImageBase; relocated
guest addresses are returned separately in `g32_pe_image`.

`pp test --quick` also runs `pe32_test.c`: synthetic images at native, 16 KiB and
64 KiB host granules, every truncated input length, malformed headers/sections,
relocations, imports, reservation conflicts, rollback and 4096 deterministic
file mutations. Binding checks exercise synthetic function/data imports, ordinal
and FirstThunk lookup, rebind with a separate lookup table, high native-pointer
rejection, wrong-space/unmapped/inaccessible targets, read-only and cross-page
IAT refusal, malformed later imports before resolver callbacks, overlapping
slots, resource limits and no-import images. Real game files are private and
are **not** CI fixtures. Their binding test deliberately rejects an unresolved
import and verifies the entire mapped image is unchanged; no game import is
resolved. [Binding evidence](../../docs/evidence/2026-10-02-guest32-import-binding.md).
Their read-only local inspection can run through the same test executable:

```sh
clang -std=c11 -O2 -Wall -Wextra -Werror \
  build/guest32/guest32.c build/guest32/pe32.c build/guest32/pe32_test.c \
  -o .work/guest32/pe32-test
.work/guest32/pe32-test .work/portal2-files/portal2.exe .work/portal2-files/engine.dll
```

This is a host test, not another entry point into app functionality. The
[real-file evidence](../../docs/evidence/2026-10-02-guest32-pe32.md) includes an
independent full-image comparison at both preferred and relocated addresses.

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

## Phone-side memory gate

Dev Settings › Developer › Probes has **Win32 memory experiment**, also driven
with `pp ui --action probe:guest32-memory --shot-each-action`. The button runs
36 checks on a worker, frees both 4 GiB windows and reports its result in the
row and host log. It uses the very same C sources as the host tests, through
repo-relative source/header symlinks in `app/Sources/Guest32Experiment/`.
No Wine session, JIT acquisition, title/file modification or guest execution
is performed. The probe and a title launch refuse to run concurrently, and a
spent runtime must restart first: these windows can temporarily occupy the
bands Wine will later reserve. The target is not declared or linked in release.

[Device evidence](../../docs/evidence/2026-10-02-guest32-device-memory.md) shows
36/36 checks twice in one iOS process with real 16 KiB host pages. Software
backing is therefore possible in this app on the phone as well as the host.
This does not prove a checked FEX/Wine bridge is complete or fast enough for
gameplay.
