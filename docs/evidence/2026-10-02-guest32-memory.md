# Portal 2: first software-address-space experiment

## Scope and verdict

The owner requested local Portal 2 execution on the non-jailbroken phone and
approved restoring the build inputs, including an experimental repo-local
Windows toolchain. **Portal 2 still does not run.** No app was installed,
launched, uninstalled or changed on the phone. There is no tested IPA SHA256.

The previous [inspection](2026-10-01-portal2-32-bit.md) identifies the installed
build as i386 and the low-address image mapping failure. This experiment tests
one prerequisite: preserving 32-bit guest addresses with backing above 4 GiB.
It does not claim a Wine/FEX loader, working WoW64 or graphics support.

## Implementation

`build/guest32/guest32.{h,c}` reserves a separate 4 GiB non-executable host window
for each software address space, with per-4-KiB guest reservation and permission
metadata. Checked forward/reverse translations separate native and guest
pointers, validate the entire access, and reject the low 64 KiB and upper-edge
crossings. Commit/recommit, protect, decommit and whole-reservation release are
implemented for the experiment's documented subset. Discarding a guest page
zeros only its bytes, not a live neighbor sharing the native page.

The important limitation is explicit: backing for a committed native page is
RW. Guest permissions must be checked **on every access**, including fetch,
string and atomic paths in a future emulator. Native page protection cannot
independently represent four guest pages on this phone's 16 KiB pages. Raw
unchecked pointer arithmetic would bypass the contract. VM concurrency and
native syscall/callback pointer marshalling are not implemented.

The test reserves the installed launcher's preferred `0x400000` address and
`0x5c000` image extent. That is only a memory-range test: it neither loads the
actual PE file nor executes its instructions. These tests do not overturn the
app's x86-64-only constraint or prove iOS can reserve this window at runtime.

## Checks

- `pp test --quick`: passed, including the new guest32 C test, the existing host
  C tests and 479 tooling tests. Madeira was populated, so its pad tests ran.
- The guest32 cases pass with native host pages, simulated 16 KiB and simulated
  64 KiB host granules. They cover isolation, permissions, cross-page accesses,
  upper-edge overflow, guest arithmetic wrapping into null, failed validation
  without partial copies, reservation boundaries and decommit/reallocation
  zeroing.
- Both GCC and Clang AddressSanitizer + UndefinedBehaviorSanitizer runs pass.
- Clang cross-compiles `guest32.c` for `arm64-apple-ios26.5` against the recorded
  SDK with `-Wall -Wextra -Werror`. This is compilation, not a device run.
- `git diff --check`: clean.

Private test/build logs and binaries remain under `.work/guest32/` and
`.work/tmp/`. See [the contract and remaining work](../../build/guest32/README.md).

## Build restoration

The recorded llvm-mingw archive was fetched and verified against the committed
SHA256, its ARM64EC CRT rebuilt from the documented commit, and builtins copied
under the GCC library names. The patched xtool, Apple linker and locked Rust
were built/restored; `pp build --to inputs` and `--to sources` pass. No pins were
moved. The owner explicitly approved keeping this experimental toolchain in
`.work/inputs/`, an exception to the usual system-tool location rule.

The baseline unix build compiled ntdll, win32u and wineserver. Its first
GStreamer archive download exceeded the foreground timeout; this is not a
runtime failure or a completed IPA. The phone's existing app has a different
bundle identity, so it was left untouched. Resolving installation and checking
JIT and actual guest execution on the phone remain necessary.
