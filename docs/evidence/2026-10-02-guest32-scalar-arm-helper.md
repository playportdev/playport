# Portal 2: compiled checked scalar ARM64 helper

## Verdict

The candidate scalar helper and real g32 read/write checks now **execute as
compiled ARM64 instructions** in the optional host simulator, rather than
being called from the native host inspector. All 6327 calls and seven compiled
corruption controls pass. This closes the helper-machine-code prerequisite;
it does **not** implement a checked FEX call site.

**Portal 2 remains unplayable. Not checked on the phone.** No patch/pin, app,
IPA, build record, runtime switch or product entry point changes. There is no
device-run IPA SHA256. The shipped ARM64EC convention remains untested.

## Experiment boundary

`build/guest32/scalar_arm_audit.py` compiles the unchanged `scalar_access.c`
and `guest32.c` at `-O2` for freestanding non-EC AArch64 ELF. The C fixture
includes g32's implementation to initialize its private layout without a
Python layout replica. It sets metadata for two low and two top-of-space guest
pages. A noinline freestanding memmove supplies ordinary native byte copying;
**all validation remains in the unmodified g32 code before copying**.

Clang's freestanding integer/pointer types are real ARM64 types. Declaration-only
OS headers are generated inside `.work`; section garbage collection and a
no-undefined link remove OS allocation/protection functions. Symbol checks
require the helper/copy/fixture and reject retained VM-setup functions. Neither
g32_create nor native mmap/mprotect is exercised. The three host-granule values
are fixture metadata here, not three real ARM host-page configurations.

The ELF loader maps native code/metadata above 4 GiB, plus a native stack and
return capture. Sparse data backing is above 4 GiB with both neighboring pages
always RW, including those denied by guest metadata. There are **no mappings
at numeric guest addresses**. Simulator hooks observe instructions/accesses
and stop at return or error; none fabricate return values, translate an address,
implement a memory operation, or map a faulting access. Actual helper, checked
access and memmove machine instructions execute. No emitted FEX block calls it.

## Checks

Across granule metadata 4096/16384/65536, 6327 calls cover:

- all 64 committed permission pairs and decommitted neighboring pages;
- byte/word/dword loads/stores at aligned, unaligned and cross-page addresses;
- exact end-of-space fits, multi-byte overflow, blocked low addresses;
- dirty upper bits and actual native backing, metadata, code, stack and
  return-capture addresses (rejected, never silently truncated);
- invalid operation encodings, null spaces and poisoned spaces.

An independent Python oracle checks explicit little-endian bytes, partial
register results and the packed status/value. Every allowed backing byte is
observed exactly once in the proper direction; rejection must touch **no**
backing byte, even when only the second guest page denies permission. Complete
16 KiB backing snapshots include neighboring byte canaries. During helper
execution only backing and stack writes are allowed, so native metadata/code
writes fail. No pointer loan or OS operation occurs.

AAPCS64 checks require unchanged x19–x29, low 64 bits of v8–v15, and restored
SP. This deliberately does **not** assert caller-clobbered registers/flags are
preserved. In this Clang build, both successful and rejected calls alter
x8–x12 and NZCV. A future FEX caller must save all live volatile state before
calling, not just retain the destination on failure; callee-saved checks alone
are insufficient for FEX live-state preservation.

Seven separately compiled mutations fail for their intended oracle/access
reason, not a build error or arbitrary simulator crash: native truncation,
store-width truncation, partial-register clobber, status packing, first-page-only
validation, permission bypass, and writing a prefix after rejected validation.
The last control returns the correct rejection result but is still rejected
because it touches backing.

## Validation

```sh
PYTHONPATH="$PWD/.work/guest32/arm-simulator/deps" python3 \
  build/guest32/scalar_arm_audit.py
python3 build/guest32/scalar_access_audit.py
./pp test --quick
python3 -m py_compile build/guest32/scalar_arm_audit.py
clang -std=c11 -Wall -Wextra -Werror -c build/guest32/scalar_arm_fixture.c \
  -o .work/guest32/scalar-arm/fixture-host.o
clang --analyze -std=c11 -Wall -Wextra -Werror \
  build/guest32/scalar_arm_fixture.c -o .work/guest32/scalar-arm/fixture.plist
git diff --check
```

All pass. The existing standalone helper audit retains 7203 host cases,
ASan/UBSan and its six corruption controls. The quick suite retains tooling,
name/secret/pin/series and host C checks. Simulator version is hash-locked
Unicorn 2.1.4, native library SHA256
`ddb196ec82b52e502c18e4a34478bf7b9f61c83c2ebaa95c74d8ded45a95da9c`.
The runner prints unchanged helper/g32 and fixture source hashes. Logs are
`.work/guest32/scalar-arm-audit.log`, `scalar-arm-host.log` and
`scalar-arm-quick.log`; ELF/object/header artifacts stay in
`.work/guest32/scalar-arm/`. No background process was started.

## Next boundary

Emit a bounded checked call from real FEX lowering and execute it against this
compiled helper, preserving live caller-clobbered GPR/FPR/flags, rejecting
before architectural publication/continuation, and retaining the faulting
guest PC. Native CPU-state pointers must bypass the guest helper. No current
test establishes that lowering, fault delivery, concurrent VM lifetime,
ARM64EC/iOS execution, other memory families, Wine i386 marshalling,
graphics/audio/input or Portal 2 menu/play/save/reload.
