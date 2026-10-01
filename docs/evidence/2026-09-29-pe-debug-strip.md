# The Wine PE set without its DWARF

**Status:** built, checked on the host, and one Hollow Knight play on the phone;
The Witcher 3 and a symbolised profile not yet run.
**Date:** 2026-09-29. Plan: [performance follow-up](../plans/2026-09-28-performance-follow-up.md),
step 5. [Decision 0019](../decisions/0019-jit-pool-sized-from-the-limit.md)
named this follow-up.

## Why it costs memory

`stages/wine-pe.sh` builds with `-g`. The `.debug_*` sections are allocated
sections of each image, after all the others, and they count in its
`SizeOfImage`. The runtime copies every image it maps whole into the JIT pool
(`[jit-pool] image BASE+SIZE (name)`), and the pool is resident. So the DWARF
of every DLL a title loads is resident memory that nothing on the phone reads.

## Measured (host)

Taken from the images Hollow Knight's 720-row run loaded (its `[jit-pool] image`
lines, `$PLAYPORT_BUILD/perf-baseline/r720-1`) against the staged runtime of
`a6018dac`:

| | |
|---|---|
| image copies in the run | 62, 181.4 MiB (74 `images` in the pool figure counts repeats) |
| of which the Wine PE set | 56 images, 125.3 MiB of `SizeOfImage` |
| their `.debug_*` sections | 50.8 MiB |
| `SizeOfImage` after `llvm-strip --strip-debug` | 60.8 MiB: **64.5 MiB less** (the 64 KiB section alignment rounds the saving up) |
| arm64ec `ntdll.dll`, which each child copies | 4.0 → 1.25 MiB |
| the whole staged PE set, both architectures (apparent file size) | 565 → 265 MiB |
| the dev IPA | 753 → 437 MB (`a6018dac` → `4c73e9c7`) |

The strip leaves every other section at the same RVA and size (checked across
the 56 images). It also keeps the DOS stub with Wine's `Wine builtin DLL`
stamp, the exports, the load config (the ARM64EC CHPE metadata) and the COFF
symbol table: `llvm-nm` lists the same 6,550 symbols in ntdll before and after.
`tools/sampleprof.py` symbolises `pp perf --profile` from that table, not from
DWARF. No tool in the repository reads the DWARF. The output is deterministic:
two strips of the same input are byte-identical.

## The change

`build/stages/wine-pe-strip.py` mirrors the two build trees' PE sets into
`$PLAYPORT_RUN/pe/staged`, each PE image through `llvm-strip --strip-debug`.
The `pe` stage runs it after `wine-pe.sh` and regenerates the manifests from the
mirror. `stage-artifacts.py` stages from there. The full images stay in
`pe/wine` for a debugger. `wine-pe.sh` is unchanged, so its configure key is
too, and the next build did not reconfigure Wine: its `pe` stage took 15 s,
10 s of that the strip of 2,425 files.

What it loses: Wine's dbghelp on the phone no longer finds DWARF in the
runtime's DLLs (DXMT's DLLs were already stripped because theirs crashed it in
The Witcher 3, [record](2026-09-25-witcher3-setup.md)).

## On the phone

`pp ui --play app-367520 --until first-frame+10` against the same play on the
build before (both dev, the `pool` figure of the `result` event):

| IPA | first frame | pool head | images | children |
|---|---|---|---|---|
| `2e4167a9…` (2026-09-29 15:26, with DWARF) | – | 203 MiB | 64 | 5 MiB |
| `4c73e9c7b894f4f7ed5bd9221ee863a1165122feaaf502fa7c3f64bf3235566d` | 11.29 s | **132 MiB** | 65 | 2 MiB |

The head is 71 MiB smaller with one image more. The play reached its first
frame and ran on. So did a second play with Runtime counters off, first frame
at 10.05 s ([counters record](2026-09-29-release-counters.md)).

Not yet run:

- The Witcher 3's start, which loads module symbols through dbghelp.
- `pp perf --profile` of a `--cpu-prof` run, to check it still names functions.
