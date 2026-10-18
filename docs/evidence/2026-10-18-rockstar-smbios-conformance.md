# The RSMB table Rockstar's launcher reads before its fault (PLA-401)

**Linear:** https://linear.app/playportdev/issue/PLA-401

Follows [the generated-fault record](2026-10-18-rockstar-generated-fault.md).
In RDR2 run `.work/ui-runs/20261018T120626` (IPA `32b91220…`), the launcher's
thread `0054` logs six `get_core_id_regs_arm64 stub` lines. A few hundred
milliseconds later the same thread reports `producer=INTOp` and ends on
`0xc0000096`. Wine builds the SMBIOS table once per process, on the first RSMB
`SystemFirmwareTableInformation` Get (`dlls/ntdll/unix/system.c`
`get_firmware_info`), and builds it on that thread. The six lines are one per
logical processor (one package of six cores). Nothing in that run showed what
the call asked for, what it returned, or whether the table was well formed.

## What the iOS build runs

The iOS `ntdll` unix object is built from the `wine` tree with `wine-port`,
`wine-valve` and `wine-unix` applied. It compiles the `__APPLE__` branch: its
strings include `AppleSMBIOS`, `IOPlatformExpertDevice` and `Socket #%u`. The stub
lines can only come from `create_smbios_processors`. That function is reached only
when no usable `AppleSMBIOS` table exists and the platform expert is found, so the
phone runs the generated table: BIOS, system, chassis and board from the platform
expert's manufacturer, model, serial and UUID (each may be absent), one type 4 per
package, one type 44 per logical processor, a type 32 and an end marker. No
Playport or Madeira patch touched this code before this record.

## Host check of the real code

A host probe compiled the real functions from the run tree under ASan and UBSan:
`append_smbios*`, the non-Linux register stub, `create_smbios_processors`, the
`__APPLE__` `create_smbios_data` and `cf_to_string`, `enum_firmware_info`,
`get_firmware_info`, the `NtQuerySystemInformation` case, and kernelbase's
`get_firmware_table`. Mocked IOKit and CoreFoundation supplied placeholder strings
and mocked topologies supplied the cores. It covered every input class:
- platform-expert properties absent, vendor and model only, or all four;
- a 127-byte and a 128-byte model;
- topologies of one package of 6 cores, two packages of 4, and 4 cores with SMT.

The probe was a scratch tool under `.work`. Checked against DSP0134 3.6.0:

- **Conforming in every class:**
  - the prologue's length and version;
  - every structure in bounds, at least its 3.0 minimum length (types 0, 1, 2, 3, 4, 32), with string indexes within its string-set and the string-set ended by a double NUL;
  - unique handles; the board's chassis and each type 44's processor reference resolve;
  - type 4 thread counts match the type 44 structures;
  - one end marker, last;
  - `STATUS_INFO_LENGTH_MISMATCH` below the header, and `STATUS_BUFFER_TOO_SMALL` with the required size and no payload written for a short buffer;
  - success with the tail untouched for an exact or oversized buffer, and the same bytes on every call;
  - `GetSystemFirmwareTable`/`EnumSystemFirmwareTables` return the required size for a short or empty buffer.
- **Type 44 Block Length (spec violation).** Tables 129 and 130 make a type 44 structure
  `6 + Y` bytes, its block `Y = 2 + Block Length`. Wine set Block Length to
  `Length - 6`: each of the phone's type 44 structures (Length 10) said 4 where
  the data is 2 bytes. A reader that trusts it reads 2 bytes past the formatted
  area, into the string-set terminator, still inside the table. It is in upstream
  Wine since `4571d0e869f` and only on aarch64 (an x86-64 build has no type 44).
  Wine's own reader, wineboot, counts registers and ignores it.
- **`cf_to_string` overflow (not shown to matter here).** A CFData property of 128 bytes
  or more made it write the terminator one byte past the caller's array (ASan:
  stack-buffer-overflow). Nothing shows the phone's properties are that long.

## Changes

- `patches/wine-unix/0040`: Block Length = Length − 8 (`upstream-bug`). It is a
  conformance fix whether or not it touches the launcher, and changes no value
  that identifies the device or the processor.
- `patches/wine-unix/0041`: `cf_to_string` copies at most `buffer_size - 1` bytes
  (`upstream-bug`).
- `patches/wine-unix/0042`: logs a process's first 16 firmware table queries
  (`diagnostics`) as `err:ntdll` lines with the thread id. Each line gives
  provider, action, table id, buffer size, required size, table length and
  status. For an RSMB table returned whole, it also gives the structure count,
  the type 44 count, how many of those have Block Length = Length − 8, and
  whether the table walks validly to its end marker. It never logs bytes,
  strings, serials or UUIDs.
- `tools/tests/test_smbios_ios.py` compiles each patch's added lines inside
  their Wine function:
  - the Block Length check uses 0, 1 and 3 registers;
  - the `cf_to_string` check uses exact, longer and shorter data with a guard byte;
  - the shape check covers a valid table, Wine's old Block Length, a missing end marker, a short prologue length and an oversized structure.

  Against the unpatched lines, the first two checks fail.

Checks: `pp test --quick` (655 Python tests, host C suites), `pp names`,
`pp secrets` clean. `pp build`: 89/89 IPA checks, IPA
`c0ff4235d29369408b18ae269b0b32e28c762f2cc82804a75b6807bc547fdf5b`. The record is
`app/artifacts.tsv` (`libntdll_unix.a`). The phone result follows once the single
diagnostic round has run.
