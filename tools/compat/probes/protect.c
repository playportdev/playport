/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * protect: what one-page NtProtectVirtualMemory calls cost, and the
 * user shared data read an anti-tamper layer makes (PLA-118). Football
 * Manager 2022's fm.exe changes single pages of its image to
 * PAGE_EXECUTE_READ, about 21,000 of them at start, and reads
 * KUSER_SHARED_DATA's interrupt time from x86 code.
 *
 *   usd     read InterruptTime (0x7ffe0008, its High1Time, LowPart and
 *           High2Time) as Windows' KSYSTEM_TIME loop does, 100,000 times; the
 *           value must not go back and must move across a 50 ms Sleep
 *   data    one page of a 1 MiB allocation, PAGE_READONLY then back to
 *           PAGE_READWRITE, 4,096 times each
 *   rx      the same with PAGE_EXECUTE_READ and PAGE_READWRITE
 *   image   the same on a 1 MiB section of the probe's own image
 *   exec    write `mov eax, N; ret` into a page, PAGE_EXECUTE_READ, call it,
 *           PAGE_EXECUTE_READWRITE again: 256 pages of a PAGE_EXECUTE_READWRITE
 *           allocation, 16 rounds; each call must return its N
 *   exec-rw (only when named on the command line) the same in a
 *           PAGE_READWRITE allocation, made PAGE_EXECUTE_READ before each call
 *           and PAGE_READWRITE after; runs first, on address space no earlier
 *           phase has made executable (PLA-203)
 *   exec-rw-reuse (only when named) exec-rw again at the end, where it gets
 *           the address range the data, rx and exec phases made executable
 *           and freed
 *   purge   (only when named; then the only phase after usd) whole-object
 *           freeing in the dev donor pool (PLA-363): 5 cycles of committing
 *           six 256 MiB PAGE_READWRITE regions, each page of which must read
 *           zero, writing a pattern to every page, holding them PURGE_HOLD_MS,
 *           releasing them all (MEM_RELEASE), committing 1 MiB so the pool's
 *           deferred purge runs, and holding PURGE_HOLD_MS again; the next
 *           cycle's commits must read zero, never an earlier pattern. Then a
 *           256 MiB region written, MEM_DECOMMIT of a 64 MiB part and of the
 *           whole, MEM_COMMIT again: the recommitted pages must read zero. The
 *           holds are longer than the pool's 30 s stats interval, so each
 *           state has a `donor-pool: stats` line in the app's log
 *
 * Each line goes to OutputDebugString, stdout and <dir>\protect.log; the
 * timings are microseconds per VirtualProtect call. The last line is
 * "protect: done ok" (exit 0) or "protect: done FAIL" (1).
 * Built with llvm-mingw for x86-64 (protect.exe) by
 * tools/compat/probes/build.sh.
 */
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define PAGE 4096
#define PAGES 256
#define PURGE_BLOCK ((SIZE_T)256 << 20)
#define PURGE_BLOCKS 6
#define PURGE_CYCLES 5
#ifndef PURGE_HOLD_MS
#define PURGE_HOLD_MS 35000
#endif

static HANDLE log_file = INVALID_HANDLE_VALUE;
static int failed;
static LARGE_INTEGER freq;

/* 1 MiB of the image, page-aligned, flipped by the image phase. */
__attribute__((aligned(PAGE))) static unsigned char image_pages[PAGES * PAGE] = { 1 };

static void probe_log(const char *fmt, ...)
{
    char line[512];
    va_list ap;
    DWORD written;
    int n = snprintf(line, sizeof(line), "protect: ");

    va_start(ap, fmt);
    vsnprintf(line + n, sizeof(line) - n, fmt, ap);
    va_end(ap);
    OutputDebugStringA(line);
    printf("%s", line);
    fflush(stdout);
    if (log_file != INVALID_HANDLE_VALUE) WriteFile(log_file, line, (DWORD)strlen(line), &written, NULL);
}

static double now_us(void)
{
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart * 1e6 / (double)freq.QuadPart;
}

/* KUSER_SHARED_DATA through a register, so each read is a load at an offset
 * from a base (as the game's is), not from an absolute address. */
static const unsigned char *volatile usd_base = (const unsigned char *)(ULONG_PTR)0x7ffe0000;

/* KSYSTEM_TIME at KUSER_SHARED_DATA+0x8: LowPart, High1Time, High2Time. */
static unsigned long long interrupt_time(void)
{
    volatile const unsigned char *usd = usd_base;
    LONG high1, high2;
    ULONG low;

    do
    {
        high1 = *(volatile const LONG *)(usd + 0x0c);
        low = *(volatile const ULONG *)(usd + 0x08);
        high2 = *(volatile const LONG *)(usd + 0x10);
    } while (high1 != high2);
    return ((unsigned long long)(ULONG)high1 << 32) | low;
}

static void usd_phase(void)
{
    unsigned long long first = interrupt_time(), last = first, t;
    int back = 0;
    double t0 = now_us();

    for (int i = 0; i < 100000; i++)
    {
        t = interrupt_time();
        if (t < last) back++;
        last = t;
    }
    probe_log("usd 100000 reads %.1f ns each, first %llu last %llu\n", (now_us() - t0) * 1000 / 100000, first, last);
    Sleep(50);
    t = interrupt_time();
    probe_log("CHECK usd interrupt time never back (%d) and moves across Sleep(50) (+%llu x 100 ns) %s\n",
              back, t - last, !back && t > last ? "ok" : "FAIL");
    if (back || t <= last) failed = 1;
}

/* One page at a time, `to` then `back`, 4,096 times each; returns us per call. */
static void flip_phase(const char *name, unsigned char *base, DWORD to, DWORD back)
{
    DWORD old;
    int bad = 0;
    double t0 = now_us(), us;

    for (int i = 0; i < 4096; i++)
    {
        unsigned char *page = base + (size_t)(i % PAGES) * PAGE;
        if (!VirtualProtect(page, PAGE, to, &old)) bad++;
        if (!VirtualProtect(page, PAGE, back, &old)) bad++;
    }
    us = (now_us() - t0) / 8192;
    probe_log("%s 8192 one-page VirtualProtect calls (0x%lx <-> 0x%lx): %.1f us each\n", name, to, back, us);
    probe_log("CHECK %s every call succeeded (%d failed) %s\n", name, bad, bad ? "FAIL" : "ok");
    if (bad) failed = 1;
}

static void exec_phase(const char *name, DWORD alloc_prot)
{
    unsigned char *base = VirtualAlloc(NULL, PAGES * PAGE, MEM_RESERVE | MEM_COMMIT, alloc_prot);
    DWORD old;
    int wrong = 0, bad = 0;
    double t0 = now_us();

    if (!base)
    {
        probe_log("CHECK %s VirtualAlloc FAIL (%lu)\n", name, GetLastError());
        failed = 1;
        return;
    }
    for (int round = 0; round < 16; round++)
        for (int p = 0; p < PAGES; p++)
        {
            unsigned char *code = base + (size_t)p * PAGE;
            int (*fn)(void) = (int (*)(void))code;
            int want = round * PAGES + p;

            code[0] = 0xb8; /* mov eax, imm32 */
            memcpy(code + 1, &want, 4);
            code[5] = 0xc3; /* ret */
            if (!VirtualProtect(code, PAGE, PAGE_EXECUTE_READ, &old)) bad++;
            FlushInstructionCache(GetCurrentProcess(), code, 6);
            if (fn() != want) wrong++;
            if (!VirtualProtect(code, PAGE, alloc_prot, &old)) bad++;
        }
    probe_log("%s 4096 rounds of write, PAGE_EXECUTE_READ, call, 0x%lx: %.1f us each\n",
              name, alloc_prot, (now_us() - t0) / 4096);
    probe_log("CHECK %s every call returned what was written (%d stale) and every protect succeeded (%d failed) %s\n",
              name, wrong, bad, wrong || bad ? "FAIL" : "ok");
    if (wrong || bad) failed = 1;
    VirtualFree(base, 0, MEM_RELEASE);
}

/* Pages of [base, base + bytes) with any non-zero word. */
static SIZE_T nonzero_pages(const unsigned char *base, SIZE_T bytes)
{
    SIZE_T bad = 0;

    for (SIZE_T off = 0; off < bytes; off += PAGE)
    {
        const volatile unsigned long long *w = (const volatile unsigned long long *)(base + off);
        for (int i = 0; i < PAGE / 8; i++)
            if (w[i])
            {
                bad++;
                break;
            }
    }
    return bad;
}

/* Every word of every page: the cycle, block and page in a tag word, then a fill byte. */
static unsigned long long purge_tag(int cycle, int block, SIZE_T page)
{
    return 0x5055524745000000ULL | ((unsigned long long)(cycle + 1) << 20) | ((unsigned long long)block << 16)
           | (page & 0xffff);
}

static void write_pattern(unsigned char *base, SIZE_T bytes, int cycle, int block)
{
    for (SIZE_T off = 0; off < bytes; off += PAGE)
    {
        memset(base + off, 0xa0 + cycle, PAGE);
        *(unsigned long long *)(base + off) = purge_tag(cycle, block, off / PAGE);
    }
}

/* Pages whose tag word is not what write_pattern wrote. */
static SIZE_T pattern_lost(const unsigned char *base, SIZE_T bytes, int cycle, int block)
{
    SIZE_T bad = 0;

    for (SIZE_T off = 0; off < bytes; off += PAGE)
        if (*(const volatile unsigned long long *)(base + off) != purge_tag(cycle, block, off / PAGE)
            || base[off + PAGE - 1] != (unsigned char)(0xa0 + cycle))
            bad++;
    return bad;
}

static void purge_phase(void)
{
    unsigned char *block[PURGE_BLOCKS], *trigger;
    SIZE_T stale_total = 0, lost_total = 0;
    int alloc_failed = 0, free_failed = 0;

    for (int c = 0; c < PURGE_CYCLES; c++)
    {
        SIZE_T stale = 0, lost = 0;
        double t0 = now_us(), t_check, t_write;

        for (int b = 0; b < PURGE_BLOCKS; b++)
        {
            block[b] = VirtualAlloc(NULL, PURGE_BLOCK, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
            if (!block[b])
            {
                probe_log("purge cycle %d block %d VirtualAlloc FAIL (%lu)\n", c, b, GetLastError());
                alloc_failed++;
            }
        }
        for (int b = 0; b < PURGE_BLOCKS; b++)
            if (block[b]) stale += nonzero_pages(block[b], PURGE_BLOCK);
        t_check = now_us();
        for (int b = 0; b < PURGE_BLOCKS; b++)
            if (block[b]) write_pattern(block[b], PURGE_BLOCK, c, b);
        t_write = now_us();
        for (int b = 0; b < PURGE_BLOCKS; b++)
            if (block[b]) lost += pattern_lost(block[b], PURGE_BLOCK, c, b);
        probe_log("purge cycle %d committed %d x 256 MiB at %p %p %p %p %p %p: %llu stale pages (check %.0f ms), "
                  "written in %.0f ms, %llu pages lost the pattern; holding %d ms\n",
                  c, PURGE_BLOCKS, block[0], block[1], block[2], block[3], block[4], block[5],
                  (unsigned long long)stale, (t_check - t0) / 1000, (t_write - t_check) / 1000,
                  (unsigned long long)lost, PURGE_HOLD_MS);
        Sleep(PURGE_HOLD_MS);
        t0 = now_us();
        for (int b = 0; b < PURGE_BLOCKS; b++)
            if (block[b] && !VirtualFree(block[b], 0, MEM_RELEASE)) free_failed++;
        /* A fresh RW commit calls the pool's hook, which runs the purge the last release deferred. */
        trigger = VirtualAlloc(NULL, 1 << 20, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (trigger) trigger[0] = 1;
        probe_log("purge cycle %d released all (%.1f ms), trigger commit at %p; holding %d ms\n", c,
                  (now_us() - t0) / 1000, trigger, PURGE_HOLD_MS);
        Sleep(PURGE_HOLD_MS);
        if (trigger && !VirtualFree(trigger, 0, MEM_RELEASE)) free_failed++;
        stale_total += stale;
        lost_total += lost;
    }

    /* Decommit a part, then the whole, of a written region; each recommit must read zero. */
    SIZE_T part = 64 << 20, part_stale = 0, whole_stale = 0;
    unsigned char *r = VirtualAlloc(NULL, PURGE_BLOCK, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    int decommit_failed = 0;
    if (!r)
    {
        probe_log("purge decommit VirtualAlloc FAIL (%lu)\n", GetLastError());
        alloc_failed++;
    }
    else
    {
        stale_total += nonzero_pages(r, PURGE_BLOCK);
        write_pattern(r, PURGE_BLOCK, PURGE_CYCLES, 0);
        if (!VirtualFree(r + part, part, MEM_DECOMMIT)) decommit_failed++;
        if (VirtualAlloc(r + part, part, MEM_COMMIT, PAGE_READWRITE) != r + part) decommit_failed++;
        else part_stale = nonzero_pages(r + part, part);
        lost_total += pattern_lost(r, part, PURGE_CYCLES, 0);
        if (!VirtualFree(r, PURGE_BLOCK, MEM_DECOMMIT)) decommit_failed++;
        if (VirtualAlloc(r, PURGE_BLOCK, MEM_COMMIT, PAGE_READWRITE) != r) decommit_failed++;
        else whole_stale = nonzero_pages(r, PURGE_BLOCK);
        probe_log("purge decommit at %p: 64 MiB part recommitted %llu stale pages, whole recommitted %llu stale pages, "
                  "%d calls failed\n", r, (unsigned long long)part_stale, (unsigned long long)whole_stale,
                  decommit_failed);
        if (!VirtualFree(r, 0, MEM_RELEASE)) free_failed++;
    }
    stale_total += part_stale + whole_stale;
    probe_log("CHECK purge %d cycles: stale pages %llu, pattern lost %llu, failed allocations %d, frees %d, "
              "decommits %d %s\n", PURGE_CYCLES, (unsigned long long)stale_total, (unsigned long long)lost_total,
              alloc_failed, free_failed, decommit_failed,
              stale_total || lost_total || alloc_failed || free_failed || decommit_failed ? "FAIL" : "ok");
    if (stale_total || lost_total || alloc_failed || free_failed || decommit_failed) failed = 1;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show)
{
    char dir[MAX_PATH], path[MAX_PATH + 16], *slash;
    unsigned char *data;

    QueryPerformanceFrequency(&freq);
    GetModuleFileNameA(NULL, dir, sizeof(dir));
    if ((slash = strrchr(dir, '\\'))) *slash = 0;
    snprintf(path, sizeof(path), "%s\\protect.log", dir);
    log_file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);
    probe_log("start: %d-bit, image pages at %p\n", (int)sizeof(void *) * 8, (void *)image_pages);

    usd_phase();
    if (strstr(cmdline, "purge"))
    {
        purge_phase();
        goto done;
    }
    if (strstr(cmdline, "exec-rw")) exec_phase("exec-rw", PAGE_READWRITE);

    data = VirtualAlloc(NULL, PAGES * PAGE, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!data)
    {
        probe_log("CHECK VirtualAlloc FAIL (%lu)\n", GetLastError());
        failed = 1;
    }
    else
    {
        memset(data, 0x5a, PAGES * PAGE);
        flip_phase("data", data, PAGE_READONLY, PAGE_READWRITE);
        flip_phase("rx", data, PAGE_EXECUTE_READ, PAGE_READWRITE);
        VirtualFree(data, 0, MEM_RELEASE);
    }
    flip_phase("image", image_pages, PAGE_EXECUTE_READ, PAGE_READWRITE);
    exec_phase("exec", PAGE_EXECUTE_READWRITE);
    if (strstr(cmdline, "exec-rw-reuse")) exec_phase("exec-rw-reuse", PAGE_READWRITE);

done:
    probe_log("done %s\n", failed ? "FAIL" : "ok");
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    return failed;
}
