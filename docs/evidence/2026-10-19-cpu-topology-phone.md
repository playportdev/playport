# CPU topology on the phone: CPUID's core count and Apple's unequal clusters (PLA-392)

**Linear:** [PLA-392](https://linear.app/playportdev/issue/PLA-392), which came from the source reading
in [2026-10-17-cpu-topology.md](2026-10-17-cpu-topology.md) (PLA-76, W5). Branch
`dev/pla-392-cpu-topology`. **Phone:** iPhone18,4 (2 P + 4 E cores), iOS 27.0.1.

**Questions:**
- What do CPUID and `GetLogicalProcessorInformationEx` tell a guest on the phone?
- Do the two bugs that W5 read in the source show up there?
  1. FEX's CPUID says one core while `GetSystemInfo` says six.
  2. Wine's Apple topology assumes equal clusters.

## The probe

`tools/compat/probes/cputopo.c` is built by `tools/compat/probes/build.sh` as `cputopo.exe`
(x86-64, ARM64EC FEX) and `cputopo-i386.exe` (WoW64 FEX).

**What it logs:**
- `GetSystemInfo` and `GetActiveProcessorCount`.
- CPUID:
  - leaf 1 `EBX[23:16]` and the HTT bit;
  - every leaf 4 subleaf;
  - leaves 0xB and 0x1F, when the maximum leaf reaches them;
  - leaf 0x80000008 `ECX`.
- Every `GetLogicalProcessorInformationEx(RelationAll)` entry.
- A timed spin. There is one thread per processor, all running at once, and each times a fixed
  spin 3,000 times. Each spin reads the processor number before and after and is kept only if the
  two match. The probe logs the fastest spin for each processor number.

**What it checks:**
- CPUID's counts cover the processor count.
- The cores are disjoint and together make up the active mask.
- Every cache mask lies inside the active mask.
- Each processor is in exactly one cache of each level and type.

On desktop Wine 11.19, on this workstation's 8-core, 16-thread CPU, both builds end `done ok`.

## Before: IPA `a4e14664…`, main's current build

The IPA is `a4e14664753c7b390cdff3b2ad9086a7e69db6182416b0ec1426d95c80231a4e`, which was
installed already. The runs are `$PLAYPORT_BUILD/ui-runs/f3-before-cputopo` and
`f3-before-cputopo-i386`. Both ended `done FAIL` with the same values:

| Source | What the guest read |
| --- | --- |
| `GetSystemInfo` | 6 processors, mask `0x3f`; `GetActiveProcessorCount` 6 |
| CPUID leaf 1 | `EBX` `04010800`: 1 logical processor, HTT 0 |
| CPUID leaf 4 | 4 subleaves, every one says 1 core |
| CPUID 0x80000008 | `ECX` `00001000`: 1 core |
| CPUID 0xB / 0x1F | 0xB all zero (FEX does not implement it); 0x1F beyond the maximum leaf, 0x16 |
| Cores | 6, one bit each, `EfficiencyClass` 0 |
| L1 | every core: L1I 131072, L1D 65536, 8-way, 128-byte lines |
| L2 | two entries, 6291456 bytes each: mask `0x0f` and mask **`0xf0`** |

**The L2 masks.** The second mask names processors 6 and 7, which do not exist. Processors 4 and 5
get the 6 MiB L2 and the L1 sizes of the other cluster.

**The timed spin, i386 run.** Processors 0–3 ran their fastest spin in 308.9 µs, and processors 4
and 5 in 188.0 µs, 1.64 times faster.

**The timed spin, x86-64 run.** All six processors were within 1.14 times of the fastest. But 11,573
of the 18,000 spins changed processor number between the two reads, against 1,056 in the i386 run.
The fastest time on a processor number therefore does not show that the spin ran there, so this run
does not separate the clusters.

## Root causes, confirmed

1. **CPUID's core count is the number of MIDR entries.** On iOS, FEX's
   `CPUFeatures::FetchHostFeatures` added one entry:
   - the line is `Source/Windows/Common/CPUFeatures.cpp:135-137` in the patched tree;
   - `CPUIDEmu` sets `Cores = CPUMIDRs.size()`;
   - leaves 1, 4 and 0x80000008 read `Cores`.
2. **Wine's Apple `create_logical_proc_info` assumes equal clusters** (`dlls/ntdll/unix/system.c`,
   compiled from the unix tree for iOS):
   - It takes one set of sizes from the top-level `hw.l1icachesize`, `hw.l1dcachesize` and
     `hw.l2cachesize`. On this phone those are the E cluster's.
   - It takes the L2 sharing from `hw.cacheconfig`, here 4.
   - It adds an L2 for every 4 cores, so the second L2 starts at processor 4 and runs past
     processor 5.

## The fix

**`patches/fex/0053`.** The iOS branch now adds one MIDR entry for each processor `GetSystemInfo`
reports.
- The value is the same Apple MIDR as before, so the hybrid flag stays off and the brand string is
  unchanged.
- The count follows madeira.cfg's `cpu-count`.

**`patches/wine-unix/0043`.** It reads the perf levels:
- `hw.nperflevels`;
- for each level, `hw.perflevelN.logicalcpu`, `physicalcpu`, `cpusperl2`, `l1icachesize`,
  `l1dcachesize` and `l2cachesize`.

If they add up to `cpu_count` with one thread per core, it builds the table from them:
- one package;
- one core per processor;
- each level's own L1 and L2 sizes;
- L2 masks that stay within the level.

**Which processors belong to which level.** The sysctls give counts, not processor numbers. The
slowest level is given the lowest numbers, as the i386 spin found: processors 0–3 slow, 4 and 5 fast.

**What the patch does not change:**
- `EfficiencyClass` stays 0. W5 gave the reasons, the main one being the risk that an engine keeps
  its workers on two cores.
- If the perf levels are missing or do not add up, the old equal-cluster code runs. That happens
  on an Intel Mac, or when `cpu-count` is set below the phone's count.

**What it logs.** Each path logs one `err:ntdll` line naming the path taken.

**The host test.** `tools/tests/test_apple_perflevel_topology.py` builds the patch's added
functions verbatim against a sysctl table and checks:
- the phone's layout;
- a level with two L2s and 64-bit values;
- the three cases that fall back.

## After: IPA `05d32187…`

The IPA is `05d3218781e0dd602a0a1e765db245b78ab6b7e10a9a0d93dc047823d5480ae9`. It was built from
`dev/pla-392-cpu-topology`, and verify-ipa gave 89 passed, 0 failed. It was installed with
`pp install --no-build` in one locked session, which then ran Hollow Knight and the probes.

**What the patch logged in each process** (`err:ntdll:create_apple_perflevel_info`):

```
Playport: processor topology from 2 perf levels; level 1 processors 0-3 l1i 131072 l1d 65536
l2 6291456 by 4; level 0 processors 4-5 l1i 196608 l1d 131072 l2 16777216 by 2
```

These are the phone's `hw.perflevel*` values:
- P cluster (level 0): 2 cores, L1I 192 KiB, L1D 128 KiB, a 16 MiB L2 shared by 2.
- E cluster (level 1): 4 cores, L1I 128 KiB, L1D 64 KiB, a 6 MiB L2 shared by 4.

**The probes.** The runs are `f3-after-cputopo` and `f3-after-cputopo-i386`. Both ended
`done ok`, with every CHECK ok:

| Source | Before | After |
| --- | --- | --- |
| CPUID leaf 1 `EBX[23:16]` | 1 | 6 (`EBX` `05060800`) |
| CPUID leaf 4 cores | 1 on every subleaf | 6 on every subleaf; the L3 subleaf says shared by 6 |
| CPUID 0x80000008 | 1 core | 6 cores, APIC ID size 8 (`ECX` `00008005`) |
| L1 on processors 4–5 | 128 KiB / 64 KiB | 192 KiB / 128 KiB |
| L2 | `0x0f` and `0xf0`, both 6 MiB | `0x0f` 6 MiB and `0x30` 16 MiB |
| Cores, package, NUMA, group | 6, `0x3f` | unchanged |

The i386 spin gave the same split again: processors 0–3 took 308.9 µs and 4–5 took 188.0 µs.

**Hollow Knight.** The run is `f3-hk`.
- First frame came at +9.19 s. The previous gate, `f2-hk` on `a4e14664`, took +9.47 s.
- The screenshot at first frame+10 shows the title menu: Start Game, Options, Achievements,
  Extras and Quit Game.
- The band reported 55 threads, the same as `f2-hk`.

This is a smoke gate. It does not measure gameplay or performance.

## Open

- **`EfficiencyClass` and CPU sets** still say one class. Revisit when a played title is seen to
  place work by class (W5's reopen condition). The processor-to-cluster split measured here is
  what such a change would use.
- **madeira.cfg `cpu-count` below the phone's count** still takes the equal-cluster code. That
  code is wrong in that case, as it was before: `hw.physicalcpu` exceeds the count, so its
  per-core division gives 0. Playport sets no `cpu-count`.
