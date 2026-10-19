/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * cputopo: how many processors, and what topology, a guest is told by each
 * place it can ask (PLA-392).
 *
 *   system  GetSystemInfo's count and mask, GetActiveProcessorCount
 *   cpuid   leaf 1 EBX[23:16] and the HTT bit, every leaf 4 subleaf (type,
 *           level, size, both sharing fields), leaves 0xB and 0x1F when the
 *           maximum leaf reaches them, 0x80000008 ECX's core count
 *   glpi    every GetLogicalProcessorInformationEx(RelationAll) entry: cores
 *           (mask, flags, EfficiencyClass), caches (level, type, size, line,
 *           associativity, mask), packages, NUMA nodes, groups
 *   speed   one thread a processor, all at once, each timing a fixed spin
 *           3000 times with the processor number read before and after; the
 *           fastest spin per processor number tells the fast cluster's
 *           processors from the slow one's (iOS ignores affinity, so the
 *           threads land wherever the scheduler puts them)
 *
 * The CHECKs: CPUID's counts cover the processors (leaf 1's logical IDs and
 * 0x80000008's count at least GetSystemInfo's count, leaf 4's cores at least
 * the cores GetLogicalProcessorInformationEx lists, when the leaf has
 * caches: AMD's has none); the cores are disjoint and together the active
 * mask; every cache mask lies inside the active mask; each processor is in
 * exactly one cache of each level and type. On the phone, with one thread a
 * core, every count is GetSystemInfo's. Each line goes to OutputDebugString, stdout and <dir>\cputopo.log;
 * the last line is "cputopo: done ok" (exit 0) or "cputopo: done FAIL" (1).
 * Built with llvm-mingw for x86-64 (cputopo.exe) and i386 (cputopo-i386.exe)
 * by tools/compat/probes/build.sh.
 */
#include <windows.h>
#include <cpuid.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_CPUS 64
#define SPIN_ITERATIONS 200000
#define SPIN_SAMPLES 3000

static HANDLE log_file = INVALID_HANDLE_VALUE;
static int failed;
static SYSTEM_INFO system_info;
static unsigned int glpi_cores;

static void probe_log(const char *fmt, ...)
{
    char line[1024];
    va_list ap;
    DWORD written;
    int n = snprintf(line, sizeof(line), "cputopo: ");

    va_start(ap, fmt);
    vsnprintf(line + n, sizeof(line) - n, fmt, ap);
    va_end(ap);
    OutputDebugStringA(line);
    printf("%s", line);
    fflush(stdout);
    if (log_file != INVALID_HANDLE_VALUE) WriteFile(log_file, line, (DWORD)strlen(line), &written, NULL);
}

static void check(const char *what, int ok)
{
    probe_log("CHECK %s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) failed = 1;
}

static void system_phase(void)
{
    GetSystemInfo(&system_info);
    probe_log("system: GetSystemInfo processors %lu mask %llx\n", system_info.dwNumberOfProcessors,
              (unsigned long long)system_info.dwActiveProcessorMask);
    probe_log("system: GetActiveProcessorCount(ALL_PROCESSOR_GROUPS) %lu\n",
              GetActiveProcessorCount(ALL_PROCESSOR_GROUPS));
}

static void cpuid_phase(void)
{
    unsigned int a, b, c, d, max_leaf, max_ext, sub, logical, leaf4_ok = 1, leaf4_seen = 0;
    unsigned int processors = system_info.dwNumberOfProcessors;

    __cpuid(0, max_leaf, b, c, d);
    __cpuid(0x80000000, max_ext, b, c, d);
    probe_log("cpuid: maximum leaf %#x, maximum extended leaf %#x\n", max_leaf, max_ext);

    __cpuid(1, a, b, c, d);
    logical = (b >> 16) & 0xff;
    probe_log("cpuid: leaf 1 EBX %08x: logical processors %u, APIC ID %u, HTT %u\n", b, logical, b >> 24,
              (d >> 28) & 1);
    check("cpuid leaf 1 EBX[23:16] covers GetSystemInfo's count", logical >= processors);

    for (sub = 0; max_leaf >= 4 && sub < 8; sub++)
    {
        unsigned int type, sharing, cores;

        __cpuid_count(4, sub, a, b, c, d);
        type = a & 0x1f;
        if (!type) break;
        sharing = ((a >> 14) & 0xfff) + 1;
        cores = (a >> 26) + 1;
        probe_log("cpuid: leaf 4.%u type %u level %u, %u bytes (%u-way, %u-byte lines), shared by %u, cores %u\n",
                  sub, type, (a >> 5) & 7, (((b >> 22) & 0x3ff) + 1) * (((b >> 12) & 0x3ff) + 1) * ((b & 0xfff) + 1) * (c + 1),
                  ((b >> 22) & 0x3ff) + 1, (b & 0xfff) + 1, sharing, cores);
        leaf4_seen = 1;
        if (cores < glpi_cores) leaf4_ok = 0;
    }
    if (leaf4_seen)
        check("cpuid leaf 4 EAX[31:26] covers the listed cores on every subleaf", leaf4_ok);
    else
        probe_log("cpuid: leaf 4 lists no cache\n");

    if (max_leaf >= 0xb)
    {
        for (sub = 0; sub < 4; sub++)
        {
            __cpuid_count(0xb, sub, a, b, c, d);
            probe_log("cpuid: leaf 0xb.%u eax %08x ebx %08x ecx %08x edx %08x\n", sub, a, b, c, d);
            if (!(b & 0xffff)) break;
        }
    }
    else
        probe_log("cpuid: leaf 0xb beyond the maximum leaf\n");
    if (max_leaf >= 0x1f)
    {
        __cpuid_count(0x1f, 0, a, b, c, d);
        probe_log("cpuid: leaf 0x1f.0 eax %08x ebx %08x ecx %08x edx %08x\n", a, b, c, d);
    }
    else
        probe_log("cpuid: leaf 0x1f beyond the maximum leaf\n");

    if (max_ext >= 0x80000008)
    {
        __cpuid(0x80000008, a, b, c, d);
        probe_log("cpuid: leaf 0x80000008 ECX %08x: cores %u, APIC ID size %u\n", c, (c & 0xff) + 1, (c >> 12) & 0xf);
        check("cpuid leaf 0x80000008 ECX[7:0] + 1 covers GetSystemInfo's count", (c & 0xff) + 1 >= processors);
    }
    else
        check("cpuid leaf 0x80000008 present", 0);
}

static const char *cache_type_name(PROCESSOR_CACHE_TYPE type)
{
    switch (type)
    {
    case CacheUnified: return "unified";
    case CacheInstruction: return "instruction";
    case CacheData: return "data";
    case CacheTrace: return "trace";
    default: return "?";
    }
}

static void glpi_phase(void)
{
    SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX *info;
    unsigned long long active = system_info.dwActiveProcessorMask, cores_mask = 0;
    /* in_cache[level][type][cpu]: how many caches of that level and type list the processor */
    unsigned char in_cache[4][4][MAX_CPUS];
    int cores = 0, cores_disjoint = 1, caches_inside = 1, cover_ok = 1;
    DWORD len = 0;
    BYTE *p, *end;

    memset(in_cache, 0, sizeof(in_cache));
    GetLogicalProcessorInformationEx(RelationAll, NULL, &len);
    if (!len || !(info = malloc(len)) || !GetLogicalProcessorInformationEx(RelationAll, info, &len))
    {
        probe_log("glpi: GetLogicalProcessorInformationEx failed %lu\n", GetLastError());
        check("glpi GetLogicalProcessorInformationEx", 0);
        return;
    }
    for (p = (BYTE *)info, end = p + len; p < end; p += ((SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX *)p)->Size)
    {
        SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX *entry = (void *)p;

        switch (entry->Relationship)
        {
        case RelationProcessorCore:
        {
            unsigned long long mask = entry->Processor.GroupMask[0].Mask;

            probe_log("glpi: core mask %llx flags %u efficiency class %u\n", mask, entry->Processor.Flags,
                      entry->Processor.EfficiencyClass);
            cores++;
            if (!mask || (cores_mask & mask)) cores_disjoint = 0;
            cores_mask |= mask;
            break;
        }
        case RelationProcessorPackage:
            probe_log("glpi: package mask %llx\n", (unsigned long long)entry->Processor.GroupMask[0].Mask);
            break;
        case RelationNumaNode:
            probe_log("glpi: numa node %lu mask %llx\n", entry->NumaNode.NodeNumber,
                      (unsigned long long)entry->NumaNode.GroupMask.Mask);
            break;
        case RelationCache:
        {
            CACHE_RELATIONSHIP *cache = &entry->Cache;
            unsigned long long mask = cache->GroupMask.Mask;
            int cpu;

            probe_log("glpi: cache L%u %s %lu bytes, %u-way, %u-byte lines, mask %llx\n", cache->Level,
                      cache_type_name(cache->Type), cache->CacheSize, cache->Associativity, cache->LineSize, mask);
            if (mask & ~active) caches_inside = 0;
            if (cache->Level < 4 && (unsigned int)cache->Type < 4)
                for (cpu = 0; cpu < MAX_CPUS; cpu++)
                    if (mask >> cpu & 1) in_cache[cache->Level][cache->Type][cpu]++;
            break;
        }
        case RelationGroup:
        {
            GROUP_RELATIONSHIP *group = &entry->Group;

            probe_log("glpi: groups %u active %u; group 0 maximum %u active %u mask %llx\n",
                      group->MaximumGroupCount, group->ActiveGroupCount, group->GroupInfo[0].MaximumProcessorCount,
                      group->GroupInfo[0].ActiveProcessorCount,
                      (unsigned long long)group->GroupInfo[0].ActiveProcessorMask);
            break;
        }
        default:
            probe_log("glpi: relationship %u, %lu bytes\n", entry->Relationship, entry->Size);
            break;
        }
    }
    free(info);

    for (int level = 1; level < 4; level++)
        for (int type = 0; type < 4; type++)
        {
            int listed = 0, cpu;

            for (cpu = 0; cpu < MAX_CPUS; cpu++) listed |= in_cache[level][type][cpu];
            if (!listed) continue;
            for (cpu = 0; cpu < MAX_CPUS; cpu++)
                if ((active >> cpu & 1) && in_cache[level][type][cpu] != 1)
                {
                    probe_log("glpi: processor %d is in %u L%d %s caches\n", cpu, in_cache[level][type][cpu], level,
                              cache_type_name(type));
                    cover_ok = 0;
                }
        }
    glpi_cores = cores;
    probe_log("glpi: %d cores\n", cores);
    check("glpi cores disjoint and together the active mask", cores && cores_disjoint && cores_mask == active);
    check("glpi every cache mask inside the active mask", caches_inside);
    check("glpi each processor in exactly one cache of each level and type", cover_ok);
}

struct speed_samples
{
    double fastest_us[MAX_CPUS];
    unsigned int samples[MAX_CPUS];
    unsigned int moved;
};

static double qpc_us;

static unsigned int spin(unsigned int x)
{
    for (unsigned int i = 0; i < SPIN_ITERATIONS; i++)
    {
        x = x * 1664525u + 1013904223u;
        __asm__ volatile("" : "+r"(x));
    }
    return x;
}

static DWORD WINAPI speed_thread(void *arg)
{
    struct speed_samples *s = arg;
    unsigned int i, x = GetCurrentThreadId();

    for (i = 0; i < SPIN_SAMPLES; i++)
    {
        LARGE_INTEGER t0, t1;
        DWORD before = GetCurrentProcessorNumber(), after;
        double us;

        QueryPerformanceCounter(&t0);
        x = spin(x);
        QueryPerformanceCounter(&t1);
        after = GetCurrentProcessorNumber();
        if (before != after || before >= MAX_CPUS)
        {
            s->moved++;
            continue;
        }
        us = (double)(t1.QuadPart - t0.QuadPart) * qpc_us;
        if (!s->samples[before]++ || us < s->fastest_us[before]) s->fastest_us[before] = us;
    }
    return x == 0x12345678; /* keeps the spin's result live */
}

static void speed_phase(void)
{
    struct speed_samples all, per_thread[MAX_CPUS];
    HANDLE threads[MAX_CPUS];
    unsigned int n = system_info.dwNumberOfProcessors < MAX_CPUS ? system_info.dwNumberOfProcessors : MAX_CPUS;
    unsigned int i, cpu, moved = 0, started = 0;
    double fastest = 0;
    unsigned long long near_fastest = 0, seen = 0;
    LARGE_INTEGER f;

    QueryPerformanceFrequency(&f);
    qpc_us = 1e6 / (double)f.QuadPart;
    memset(&all, 0, sizeof(all));
    memset(per_thread, 0, sizeof(per_thread));
    for (i = 0; i < n; i++)
        if ((threads[started] = CreateThread(NULL, 0, speed_thread, &per_thread[started], 0, NULL))) started++;
    WaitForMultipleObjects(started, threads, TRUE, INFINITE);
    for (i = 0; i < started; i++)
    {
        CloseHandle(threads[i]);
        moved += per_thread[i].moved;
        for (cpu = 0; cpu < MAX_CPUS; cpu++)
        {
            if (!per_thread[i].samples[cpu]) continue;
            if (!all.samples[cpu] || per_thread[i].fastest_us[cpu] < all.fastest_us[cpu])
                all.fastest_us[cpu] = per_thread[i].fastest_us[cpu];
            all.samples[cpu] += per_thread[i].samples[cpu];
        }
    }
    for (cpu = 0; cpu < MAX_CPUS; cpu++)
        if (all.samples[cpu] && (!fastest || all.fastest_us[cpu] < fastest)) fastest = all.fastest_us[cpu];
    for (cpu = 0; cpu < MAX_CPUS; cpu++)
    {
        if (!all.samples[cpu]) continue;
        seen |= 1ull << cpu;
        if (all.fastest_us[cpu] < fastest * 1.3) near_fastest |= 1ull << cpu;
        probe_log("speed: processor %u: %u spins, fastest %.1f us (%.2fx the fastest)\n", cpu, all.samples[cpu],
                  all.fastest_us[cpu], all.fastest_us[cpu] / fastest);
    }
    probe_log("speed: %u threads, %u spins moved processor; processors seen %llx, within 1.3x of the fastest %llx\n",
              started, moved, seen, near_fastest);
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show)
{
    char dir[MAX_PATH], path[MAX_PATH + 16], *slash;

    GetModuleFileNameA(NULL, dir, sizeof(dir));
    if ((slash = strrchr(dir, '\\'))) *slash = 0;
    snprintf(path, sizeof(path), "%s\\cputopo.log", dir);
    log_file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);
    probe_log("start: %d-bit\n", (int)sizeof(void *) * 8);

    system_phase();
    glpi_phase();
    cpuid_phase();
    speed_phase();

    probe_log("done %s\n", failed ? "FAIL" : "ok");
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    return failed;
}
