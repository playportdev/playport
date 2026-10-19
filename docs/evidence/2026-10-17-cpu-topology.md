# CPU topology on iOS: what the guest is told about P and E cores (source reading)

**Date:** 2026-10-17. **Linear:** [PLA-76](https://linear.app/playportdev/issue/PLA-76),
alignment item B7. **Kind:** a reading of source, plus a host model of one function. There was
no build, no install and no phone run, and nothing at runtime changed: this was done in a
host-only side copy (decision 0069). No sysctl value was read on the phone. **Read:**
- The patched unix-side Wine tree that the side copy's run built
  (`$PLAYPORT_BUILD/run/unix/wine`: wine-11.19 with the `wine-port`, `wine-valve` and
  `wine-unix` series). Madeira's `build/ntdll-unix/build.sh` (`$PLAYPORT_BUILD/run/unix/mythic`)
  replaces `loader`, `process`, `server`, `env`, `cdrom`, `virtual`, `signal_arm64` and `thread`
  with `*_ios.c` files, but compiles `dlls/ntdll/unix/system.c` itself (`build.sh:137-169`). The
  built `obj/system.o` holds only the Apple branch's selectors (`hw.packages`, `hw.physicalcpu`,
  `hw.cacheconfig`, `hw.l1icachesize` …; no `/sys/devices` path).
- ValveSoftware/Wine bleeding-edge `750fd011` (the `wine-valve` pin), `dlls/ntdll/unix/system.c`.
- ValveSoftware/Proton bleeding-edge `47c39230`, the `proton` script.
- FEX at the `fex` pin with `patches/fex` (`$PLAYPORT_BUILD/run/fex`).
- The iOS SDK's `sys/sysctl.h` (the `hw.perflevelN.*` selectors).

Line numbers below are in those trees; `system.c` means the patched unix tree's.

## 1. What a guest sees on a 2 P + 4 E phone

**The processor count is the phone's.** `init_cpu_info` sets `cpu_count` from
`sysconf(_SC_NPROCESSORS_ONLN)` (`system.c:1746`), 6 on iPhone18,4. A madeira.cfg `cpu-count`
key (Madeira's ml1122, `system.c:1762`) can replace it; Playport sets none. `GetSystemInfo` takes
`NumberOfProcessors` and the mask from it (Madeira's `build/ntdll-unix/virtual_ios.c:15738-15739`),
and the registry and environment say the same (decision 0098).

**The topology is built once, by the Apple branch of `create_logical_proc_info`**
(`system.c:1350-1483`), from these sysctls:

| Input | Selector | Use |
| --- | --- | --- |
| packages | `hw.packages` (`:1366`), 1 if absent | one package |
| cores | `hw.physicalcpu` (`:1370`) | 6 cores, one logical CPU each |
| line size | `hw.cachelinesize` (`:1398`) | every cache level |
| associativity | `machdep.cpu.cache.L2_associativity` (`:1405`), x86 only | absent on arm64: 8 for L1 and L2 |
| sizes | `hw.l1icachesize`, `hw.l1dcachesize`, `hw.l2cachesize`, `hw.l3cachesize` (`:1409-1419`) | one size per level, for every core |
| sharing | `hw.cacheconfig` (`:1422`) | how many CPUs share each level |

What it reports:
- **Packages:** one, mask `0x3f`.
- **Cores:** six `RelationProcessorCore` entries, one bit each.
  - `Flags` is 0, so no SMT (`:905`, `LTP_PC_SMT` only for a multi-bit mask).
  - `EfficiencyClass` is 0 on every core. It comes from `performance_cores` (`:909`), which
    only the Linux path fills, from `/sys/devices/cpu_core/cpus` (`:1115-1146`, Intel's hybrid
    PMU). On Apple it stays empty (`:315-316`).
- **Caches:** an L1I, an L1D and an L2 entry. An L3 entry appears only if `hw.l3cachesize`
  succeeds. Apple silicon is expected to have no such value (not read on the phone); without
  it, the level is skipped.
  - The top-level `hw.*` selectors give one value for the whole machine, for a single cluster.
    The other cluster's cores are told the same sizes.
  - The code assumes equal clusters. With sharing *n*, it adds an L2 for every *n* cores
    (`:1456-1468`). The host model below shows what that gives.
- **NUMA and groups:** one NUMA node, mask `0x3f` (`:1476`). One group, 6 active
  (`:1479`, `:1045`).

The Windows calls read that one table:

| Call | Path | Result |
| --- | --- | --- |
| `GetLogicalProcessorInformation` | `kernelbase/memory.c:1545-1555`, then class 73 (`system.c:3904-3917`) | the entries above |
| `GetLogicalProcessorInformationEx` | `memory.c:1564-1574`, then `system.c:4179-4209` | the same entries, filtered by relationship |
| `GetSystemCpuSetInformation` | `memory.c:1584-1592`, then `system.c:4212-4234` and `create_cpuset_info` (`:1799-1874`) | 6 sets, IDs `0x100`-`0x105`, `CoreIndex` 0-5. `EfficiencyClass` is copied from the core (`:1848`), so 0 |
| `GetActiveProcessorCount(ALL_PROCESSOR_GROUPS)` | `kernel32/process.c:639-661` | the group's active count, 6 |

**Host model.** `$PLAYPORT_BUILD/agent-notes/pla-76/w5/topology-model/`, in the side copy's
build area (not committed), slices the helpers, the Apple function and `create_cpuset_info`
from `system.c` verbatim and runs them against a table of sysctl values. The sizes in the table are placeholders, not the phone's.
Only the shape matters, and it depends on which cluster the top-level selectors describe:

| Top-level selectors describe | `hw.cacheconfig` | L2 entries the guest gets |
| --- | --- | --- |
| the 4-core E cluster | 6 1 4 | two of the E size: CPUs 0-3, then `0xf0` (CPUs 4-7, two of which do not exist) |
| the 2-core P cluster | 6 1 2 | three of the P size: CPUs 0-1, 2-3, 4-5 |

Either way every core gets one cluster's L1 and L2 sizes, and every `EfficiencyClass` is 0.

**Other places a guest can look:**
- **FEX's CPUID describes a single core.** iOS gives user space no MIDR, so the iOS
  host-features path adds one MIDR entry (`Source/Windows/Common/CPUFeatures.cpp:135-137`), and
  CPUID's `Cores` is the number of entries (`FEXCore/Source/Interface/Core/CPUID.cpp:1364`).
  What the guest reads:
  - leaf 1: `EBX[23:16]` = 1, and the HTT bit is clear (`:458`, `:524`);
  - leaf 4: 1 core (`:557-620`);
  - leaf 0x80000008: `ECX` `NC` = 0, so 1 core (`:1237-1240`).

  The hybrid flag and leaf 0x1A are off (`:157-178`, `:934-942`).
- **Affinity has no effect on the scheduler.** iOS has no `sched_setaffinity`.
  `HAVE_SCHED_SETAFFINITY` is undefined (`build-macos/include/config.h:365`), and the
  wineserver's `set_thread_affinity` (`server/thread.c:764-790`) only records the mask; in the
  wineserver's built `thread.o` it is 12 bytes long. A thread pinned to a core still runs wherever iOS puts
  it. Its QoS class is what steers it.
- **The processor number is real.** `NtGetCurrentProcessorNumber` returns
  `pthread_cpu_number_np` (Madeira's `build/ntdll-unix/thread_ios.c:3297-3310`; the built ntdll
  `thread.o` imports it), so the guest sees the host's CPU numbering.

## 2. `WINE_CPU_TOPOLOGY` in Playport's tree

**It is not honoured: the variable appears nowhere in the patched tree.** It is Valve's:
`fill_cpu_override` (Valve `system.c:857-1051`) reads it, and the Linux topology path and the
server's affinity mapping use the result (`:1140`, `:1426-1578`; `server.c:1679-1685`). The
`wine-valve` series did not pick it.

What it would change on the phone, even if picked:
- Valve's Apple branch (`:1626` on) uses only the count. A value `N:…` would lower
  `cpu_count`, and so `NumberOfProcessors`, `GetSystemInfo` and the topology's core count.
- The host-CPU mapping needs `/sys` and `sched_setaffinity`, which iOS lacks, so it would map
  nothing.
- The `P` form needs `performance_cores`, which only Intel's `/sys/devices/cpu_core/cpus`
  fills (`:1348-1385`). On the phone it would log "No performance cores" and change nothing.

Playport's own count knob is madeira.cfg `cpu-count` (`system.c:1759-1769`), which also changes
only the count.

## 3. Valve's value on a phone, and P and E cores elsewhere

**Proton sets nothing when the affinity covers every core.** Proton's commit `9ccc0607` (2026-08,
"Set WINE_CPU_TOPOLOGY to match process affinity on aarch64"):
- `get_current_cpu_affinity` (`proton:1494-1501`) returns `""` when
  `len(sched_getaffinity(0)) >= os.cpu_count()`;
- `Session.__init__` (`proton:1545-1552`) sets the variable only for a non-empty string.

On a 6-core phone where every core is allowed, Valve's value is unset, which is the default. iOS
has no `sched_getaffinity` either, so the function would raise and return `""`. None of the
played titles is in Proton's `default_cpu_limit` table (`proton:1463-1484`).

**Valve does not tell P and E cores apart on ARM either.** Its only P-core source is Intel's
`/sys/devices/cpu_core/cpus` (Valve `system.c:1357`), which ARM Linux kernels do not have, so
Proton on an ARM machine also reports `EfficiencyClass` 0 everywhere. Playport matches it.
Neither WineHQ (11.19, 11.20, master) nor Valve's Wine reads `hw.nperflevels` or
`hw.perflevelN.*`.

**What iOS offers.** The SDK documents these selectors (`sys/sysctl.h:679-699`):
- `hw.nperflevels`;
- per level: `hw.perflevelN.logicalcpu`, `.l1icachesize`, `.l1dcachesize`, `.l2cachesize`,
  `.cpusperl2`. Level 0 is the fastest.

They give each level's **count and cache sizes, not which CPU numbers belong to it**. A correct
`EfficiencyClass` needs that mapping, because the guest sees real CPU numbers (section 1). The
mapping would have to be measured on the phone (`pthread_cpu_number_np` on threads of each QoS
class) or assumed from the cluster order. Neither has been done.

## 4. Do played titles size work by efficiency class?

- **Unity** (Hollow Knight, Among Us, Death's Door and others). `SystemInfo.processorCount` is
  "the number of logical processors (threads) as reported by the operating system". The job
  system's default worker count is "the default value that the runtime selects for the specific
  platform and hardware" (Unity's ScriptReference for `SystemInfo.processorCount` and
  `JobsUtility.JobWorkerMaximumCount`, read 2026-10-17). Neither page mentions efficiency
  classes. Unity's player source is not public, so this was not checked further.
- **Unreal** (Final Fantasy VII Remake): its source is not public without an Epic-linked
  account. `FPlatformMisc::NumberOfCores*` was not read here.
- **Imports of two titles' Windows binaries,** from the desktop Steam installs on this
  workstation, read only:
  - `RDR2.exe` names `GetLogicalProcessorInformation(Ex)`, `GetSystemInfo` and
    `SetThreadAffinityMask`;
  - Kingdom Come: Deliverance's `WHGame.dll` names `GetLogicalProcessorInformation`,
    `GetSystemInfo` and `SetThreadAffinityMask`;
  - neither names `GetSystemCpuSetInformation` or `SetThreadSelectedCpuSets`.

  `GetLogicalProcessorInformationEx` can carry `EfficiencyClass`; whether RDR2 reads it was not
  checked, and RDR2 does not run for other reasons.
- **No played title is known to read `EfficiencyClass`.**

## 5. Conclusion

**Closed with a reason.** On the phone the guest sees six equal, single-threaded cores in one
package. This is what Valve's Proton shows on an ARM machine, where its `WINE_CPU_TOPOLOGY` value
would be unset.

Reporting the two P cores as `EfficiencyClass` 1 was not adopted:
- **No mapping:** the sysctls give counts, not CPU numbers, and the guest sees real CPU numbers.
- **No benefit shown:** affinity cannot steer a thread on iOS, and no played title is known to
  read the class.
- **A risk:** an engine that keeps its workers on the higher class would use 2 cores instead of
  6.

No decision record was written, because nothing changed.

**Reopen when:**
- a played title is seen to size or place work by `EfficiencyClass` or CPU sets; or
- a phone reading gives the cluster-to-CPU-number mapping.

The change then would be a `wine-unix` patch to the Apple branch, with a Hollow Knight
first frame+10 gate on the phone. It would:
- read `hw.nperflevels` and `hw.perflevelN.{logicalcpu,cpusperl2,l1icachesize,l1dcachesize,l2cachesize}`;
- set `performance_cores` for the measured P CPU numbers;
- give each cluster its own L1 and L2 entries.

**Seen in passing, not fixed here.** Both were fixed later (PLA-392); the phone run is in
[2026-10-19-cpu-topology-phone.md](2026-10-19-cpu-topology-phone.md).
- With unequal clusters, the Apple branch's L2 masks can name CPUs that do not exist (the
  `0xf0` case above), and every core gets one cluster's cache sizes. This is upstream WineHQ
  code. Which case the phone hits needs its `hw.cacheconfig`.
- FEX's CPUID tells the guest it has one core (one MIDR entry on iOS), while `GetSystemInfo`
  says six. A title that counts cores through CPUID would see one. The likely fix is a FEX
  patch that repeats the MIDR for each CPU.
