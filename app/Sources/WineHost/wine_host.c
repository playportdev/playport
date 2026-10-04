/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * wine_host — see include/wine_host.h.
 *
 * Besides the ABI, this file defines the symbols the unix-side archives
 * expect the host app to own (the reference app defines them in
 * WineServerBridge.m, WineProcessBridge.m, wine_stubs.c and Winios.m):
 * fatal_error, g_wineserver_should_stop, wine_build, the wine_ios_exit_*
 * thread-locals of ntdll's exit() shim, winios_phase and __clear_cache.
 * The Winios display driver and the DXMT unix slice are NOT defined here;
 * they are separate components (app/artifacts.tsv gap rows).
 */

#include "wine_host.h"
#include "prefix_registry.h"
#include "selfcheck.h"
#include "title_path.h"
#include "session_protocol.h"

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

/* --- unix-side archive entry points ------------------------------------ */

extern int wineserver_main(int argc, char *argv[]);          /* libwineserver.a (-Dmain=) */
extern void wineserver_log_set_file(const char *path);       /* libwineserver.a */
extern void wineserver_set_nls_dir(const char *path);        /* libwineserver.a */
extern void wineserver_inject_client_fd(int fd);             /* libwineserver.a */
extern int foreground;                                       /* libwineserver.a */
extern void __wine_main(int argc, char *argv[]);             /* libntdll_unix.a */

/* --- host state -------------------------------------------------------- */

static char g_runtime[1024], g_prefix[1024];
static FILE *g_log;
static wine_host_log_fn g_log_fn;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;
static size_t g_log_limit;   /* wine_host_set_log_limit; 0 is none */
static pthread_t g_server_thread, g_guest_thread;
static int g_server_started, g_guest_started;
/* The guest's argv: "wine", the session root's DOS path and its directory. */
static char g_exe_path[1024];
static char *g_guest_argv[4];
static int g_guest_argc;
static const char *g_pe_arch;
static int g_guest_exit = -1;
static volatile int g_guest_done;
static pthread_mutex_t g_guest_lock = PTHREAD_MUTEX_INITIALIZER;

static void host_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void host_log(const char *fmt, ...)
{
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    struct timeval tv;
    struct tm tm;
    gettimeofday(&tv, NULL);
    localtime_r(&tv.tv_sec, &tm);
    char line[1100];
    snprintf(line, sizeof(line), "[%02d:%02d:%02d.%03d] [wine_host] %s", tm.tm_hour, tm.tm_min,
             tm.tm_sec, (int)(tv.tv_usec / 1000), msg);

    pthread_mutex_lock(&g_log_lock);
    struct stat st;
    if (g_log && !(g_log_limit && !fstat(fileno(g_log), &st) && (size_t)st.st_size >= g_log_limit)) {
        fprintf(g_log, "%s\n", line);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_log_lock);
    if (g_log_fn) g_log_fn(line);
}

/* --- start-up sampler (WINE_HOST_SAMPLE=<seconds>) ----------------------- */

/* For a start-up profile: every millisecond for the first <seconds> after
 * wine_host_init, the PC of the busiest thread (re-chosen every 100 ms),
 * and every 250 ms one `[sample]` line with that window's top buckets:
 * x64-JIT (code FEX translated from the guest), a native PE image in the
 * JIT pool by its export name (libarm64ecfex.dll is FEX itself, the rest
 * Wine's and the app's ARM64EC DLLs), or a host image and symbol (the
 * runtime's unix side, libsystem_kernel's syscalls). A Wine thread is named
 * -<tid> from its TEB (x18); a native one m<thread id>, as the [xp-t]
 * census names them. Memory is read with vm_read_overwrite, so a stale
 * pointer costs a failed read, never a fault. */
extern int ios_jit_pool_image_pc(uintptr_t pc, uintptr_t *pe_addr_out);
extern void *ios_jit_rx_base_global;
extern size_t ios_jit_pool_size_global;

static int peek(uint64_t addr, void *buf, size_t n)
{
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)addr, n, (vm_address_t)buf, &got) == KERN_SUCCESS && got == n;
}

/* The export name of the PE image around a (64 KB aligned, within 128 MB below). */
static const char *pe_name(uint64_t a)
{
    static struct { uint64_t page; char name[48]; } cache[512];
    uint64_t page = a >> 16;
    unsigned slot = (unsigned)(page % 512);
    if (cache[slot].page == page) return cache[slot].name;
    const char *found = "PE?";
    static char name[48];
    for (uint64_t b = a & ~0xffffull; b + (128ull << 20) > a && b; b -= 0x10000) {
        uint16_t mz = 0;
        if (!peek(b, &mz, 2)) continue;
        if (mz != 0x5a4d) continue;
        uint32_t lfanew = 0, sig = 0, exp_rva = 0, name_rva = 0;
        if (!peek(b + 0x3c, &lfanew, 4) || lfanew > 0x1000 || !peek(b + lfanew, &sig, 4) || sig != 0x4550) continue;
        if (peek(b + lfanew + 24 + 112, &exp_rva, 4) && exp_rva && peek(b + exp_rva + 12, &name_rva, 4)
            && peek(b + name_rva, name, sizeof(name) - 1)) {
            name[sizeof(name) - 1] = 0;
            found = name;
        }
        break;
    }
    cache[slot].page = page;
    snprintf(cache[slot].name, sizeof(cache[slot].name), "%s", found);
    return cache[slot].name;
}

static void pc_bucket(uint64_t pc, char *out, size_t cap)
{
    uint64_t rx = (uint64_t)(uintptr_t)ios_jit_rx_base_global;
    uintptr_t pe = 0;
    Dl_info di;
    if (rx && pc >= rx && pc < rx + ios_jit_pool_size_global) {
        if (!ios_jit_pool_image_pc((uintptr_t)pc, &pe)) { snprintf(out, cap, "x64-JIT"); return; }
        snprintf(out, cap, "%s", pe_name(pe));
        return;
    }
    if (dladdr((void *)(uintptr_t)pc, &di) && di.dli_fname) {
        const char *img = strrchr(di.dli_fname, '/');
        snprintf(out, cap, "%s`%s", img ? img + 1 : di.dli_fname, di.dli_sname ? di.dli_sname : "?");
        return;
    }
    if (pc >= 0x7000000000ull && pc < 0x7400000000ull) { snprintf(out, cap, "%s", pe_name(pc)); return; }
    snprintf(out, cap, "?%llx", (unsigned long long)(pc >> 20));
}

static void *sample_thread(void *arg)
{
    const double seconds = *(double *)arg;
    free(arg);
    enum { SLOTS = 96 };
    static struct { char key[96]; unsigned n; } b[SLOTS];
    const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t window = t0, pick = 0;
    mach_port_t self = mach_thread_self(), target = MACH_PORT_NULL;
    char who[16] = "?";
    unsigned total = 0;
    for (;;) {
        usleep(1000);
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now - t0 > (uint64_t)(seconds * 1e9)) break;
        if (now - pick > 100000000ull || target == MACH_PORT_NULL) {
            thread_act_array_t list;
            mach_msg_type_number_t count;
            pick = now;
            if (task_threads(mach_task_self(), &list, &count) == KERN_SUCCESS) {
                integer_t best = -1;
                mach_port_t chosen = MACH_PORT_NULL;
                for (unsigned i = 0; i < count; i++) {
                    thread_basic_info_data_t bi;
                    mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
                    if (list[i] != self && thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &n) == KERN_SUCCESS
                        && !(bi.flags & TH_FLAGS_IDLE) && bi.cpu_usage > best) { best = bi.cpu_usage; chosen = list[i]; }
                }
                for (unsigned i = 0; i < count; i++) if (list[i] != chosen) mach_port_deallocate(mach_task_self(), list[i]);
                vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof(*list));
                if (target != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), target);
                target = chosen;
            }
        }
        if (target != MACH_PORT_NULL && thread_suspend(target) == KERN_SUCCESS) {
            arm_thread_state64_t st;
            mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
            kern_return_t kr = thread_get_state(target, ARM_THREAD_STATE64, (thread_state_t)&st, &n);
            thread_resume(target);
            if (kr == KERN_SUCCESS) {
                char key[96];
                uint64_t teb = st.__x[18], tid = 0;
                if (teb >= 0x7000000000ull && teb < 0x7400000000ull && peek(teb + 0x48, &tid, 8) && tid && tid < 0x10000)
                    snprintf(who, sizeof(who), "-%04llx", (unsigned long long)tid);
                else {
                    thread_identifier_info_data_t ii;
                    mach_msg_type_number_t in = THREAD_IDENTIFIER_INFO_COUNT;
                    if (thread_info(target, THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &in) == KERN_SUCCESS)
                        snprintf(who, sizeof(who), "m%llu", (unsigned long long)ii.thread_id);
                }
                pc_bucket(arm_thread_state64_get_pc(st), key, sizeof(key));
                unsigned i;
                for (i = 0; i < SLOTS && b[i].n && strcmp(b[i].key, key); i++) {}
                if (i < SLOTS) { if (!b[i].n) snprintf(b[i].key, sizeof(b[i].key), "%s", key); b[i].n++; total++; }
            }
        }
        if (now - window >= 250000000ull && total) {
            char line[1024];
            int len = snprintf(line, sizeof(line), "[sample] +%.2f %s n=%u:", (now - t0) / 1e9, who, total);
            for (int k = 0; k < 6; k++) {
                int best = -1;
                for (int i = 0; i < SLOTS; i++) if (b[i].n && (best < 0 || b[i].n > b[best].n)) best = i;
                if (best < 0) break;
                len += snprintf(line + len, sizeof(line) - len, " %s=%u%%", b[best].key, b[best].n * 100 / total);
                b[best].n = 0;
                if (len >= (int)sizeof(line) - 100) break;
            }
            dprintf(STDERR_FILENO, "%s\n", line);
            memset(b, 0, sizeof(b));
            total = 0;
            window = now;
        }
    }
    return NULL;
}

static void start_sampler(double seconds)
{
    double *arg = malloc(sizeof(*arg));
    pthread_t t;
    pthread_attr_t attr;
    if (!arg) return;
    *arg = seconds;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    if (pthread_create(&t, &attr, sample_thread, arg)) free(arg);
    pthread_attr_destroy(&attr);
}

/* --- the log limit (wine_host.h, wine_host_set_log_limit) --------------- */

void wine_host_set_log_limit(size_t bytes)
{
    g_log_limit = bytes;
}

/* --- stamped stderr (WINE_HOST_LOG_STAMP=1) ------------------------------ */

/* For a start-up profile: most of what the runtime logs goes to stderr with
 * no time. With WINE_HOST_LOG_STAMP=1 (a dev launch; not under a log limit,
 * whose check needs stderr to be the file) stderr becomes a pipe, and this
 * thread writes each line to the log prefixed with `[+s.mmm]`, the seconds
 * since wine_host_init. A line is stamped when the thread reads it, within
 * a millisecond or so of its write unless the pipe is backed up. */
static uint64_t g_stamp_t0;
void madeira_set_diag_enabled(int on);   /* libntdll_unix.a, virtual_ios.c */

static void *log_stamp_thread(void *arg)
{
    int in = ((int *)arg)[0], out = ((int *)arg)[1];
    free(arg);
    static char buf[65536], line[65536 + 65536 / 2];
    int at_start = 1;
    for (;;) {
        ssize_t n = read(in, buf, sizeof(buf));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NULL;
        uint64_t ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - g_stamp_t0) / 1000000;
        char stamp[32];
        int sl = snprintf(stamp, sizeof(stamp), "[+%llu.%03llu] ", ms / 1000, ms % 1000);
        size_t o = 0;
        for (ssize_t i = 0; i < n; i++) {
            if (at_start) {
                if (o + sl > sizeof(line)) { write(out, line, o); o = 0; }
                memcpy(line + o, stamp, sl);
                o += sl;
            }
            if (o == sizeof(line)) { write(out, line, o); o = 0; }
            line[o++] = buf[i];
            at_start = buf[i] == '\n';
        }
        write(out, line, o);
    }
}

static void stamp_stderr(void)
{
    int p[2];
    int *fds = malloc(2 * sizeof(int));
    if (!fds || pipe(p)) { free(fds); return; }
    fds[0] = p[0];
    fds[1] = dup(STDERR_FILENO);
    dup2(p[1], STDERR_FILENO);
    close(p[1]);
    g_stamp_t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_create(&t, &attr, log_stamp_thread, fds);
    pthread_attr_destroy(&attr);
}

/* Once a second: when stderr (the log since wine_host_init) has reached the
 * limit, say so once and stop writing. Everything that logs goes through
 * stderr or g_log: ntdll's dprintf(2), the guest's debug output, Winios,
 * FEX, DXMT, this file and HostIO's host_log.c (which also checks the size
 * itself). The wineserver's own file is never opened under a limit. */
static void *log_limit_thread(void *arg)
{
    (void)arg;
    for (;;) {
        struct stat st;
        sleep(1);
        if (fstat(STDERR_FILENO, &st) || !S_ISREG(st.st_mode) || (size_t)st.st_size < g_log_limit) continue;
        /* Past the limit host_log writes nothing; this one line goes anyway. */
        dprintf(STDERR_FILENO, "[wine_host] log: %zu bytes reached; nothing more is logged this session\n", g_log_limit);
        int null = open("/dev/null", O_WRONLY);
        if (null >= 0) {
            dup2(null, STDERR_FILENO);
            close(null);
        }
        pthread_mutex_lock(&g_log_lock);
        if (g_log) {
            fclose(g_log);
            g_log = NULL;
        }
        pthread_mutex_unlock(&g_log_lock);
        return NULL;
    }
}

/* --- symbols the archives expect from the host -------------------------- */

const char wine_build[] = "wine-11.18 winehq@7b3fff76fa + patches/wine-port (Playport)";

/* Polled by the wineserver event loop (Madeira build/wineserver/fd_ios.c). */
volatile int g_wineserver_should_stop = 0;

/* Wineserver's fatal_error: exit() would take the whole app down, so log and
 * end only the server thread. */
void fatal_error(const char *err, ...)
{
    char msg[1024];
    va_list ap;
    va_start(ap, err);
    vsnprintf(msg, sizeof(msg), err, ap);
    va_end(ap);
    host_log("wineserver fatal: %s", msg);
    pthread_exit(NULL);
}

/* ntdll's exit() shim (Madeira build/ntdll-unix/shims/wine_ios_exit.h)
 * longjmps back to the guest process thread that armed these. */
_Thread_local jmp_buf wine_ios_exit_jmpbuf;
_Thread_local volatile int wine_ios_exit_code;
_Thread_local pthread_t wine_ios_main_thread;
_Thread_local int wine_ios_exit_initialized;

/* Startup-phase milestones from ntdll's process_ios.c. */
void winios_phase(const char *name)
{
    host_log("phase %s", name);
}

/* compiler-rt builtin behind NtFlushInstructionCache; neither the xtool slim
 * SDK's libSystem nor its libclang_rt.ios.a exports it. */
void __clear_cache(void *start, void *end)
{
    sys_icache_invalidate(start, (size_t)((char *)end - (char *)start));
}

/* --- prefix ------------------------------------------------------------ */

static int mkdirs(const char *path)
{
    char buf[1024];
    snprintf(buf, sizeof(buf), "%s", path);
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(buf, 0755) && errno != EEXIST) return -1;
        *p = '/';
    }
    return (mkdir(buf, 0755) && errno != EEXIST) ? -1 : 0;
}

/* Link every file of src_dir into sys32, replacing what is there; the count linked. */
static int link_dir_into(const char *src_dir, const char *sys32)
{
    char src[1600], dst[1600];
    DIR *d = opendir(src_dir);
    if (!d) return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(src, sizeof(src), "%s/%s", src_dir, e->d_name);
        snprintf(dst, sizeof(dst), "%s/%s", sys32, e->d_name);
        unlink(dst);
        if (symlink(src, dst) == 0) n++;
    }
    closedir(d);
    return n;
}

/* PLAYPORT_DLL_OVERLAY when it names one directory of the runtime, else NULL. */
static const char *dll_overlay(void)
{
    const char *o = getenv("PLAYPORT_DLL_OVERLAY");
    if (!o || !o[0] || strchr(o, '/') || strchr(o, ':') || strstr(o, "..")) return NULL;
    return o;
}

/* Remove every link in sys32 into an <arch>-windows set, the bundle's or an
 * overlay's, of this or an earlier bundle path; other entries stay. */
static void unlink_runtime_links(const char *sys32)
{
    static const char set[] = "-windows/";
    char dst[1600], target[1600];
    char **names = NULL;
    size_t count = 0, cap = 0;
    DIR *d = opendir(sys32);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(dst, sizeof(dst), "%s/%s", sys32, e->d_name);
        ssize_t len = readlink(dst, target, sizeof(target) - 1);
        if (len <= 0) continue;
        target[len] = 0;
        char *leaf = strrchr(target, '/');
        if (!leaf) continue;
        size_t sl = sizeof(set) - 1;
        if ((size_t)(leaf + 1 - target) < sl || strncmp(leaf + 1 - sl, set, sl)) continue;
        if (count == cap) {
            size_t ncap = cap ? 2 * cap : 64;
            char **grown = realloc(names, ncap * sizeof(*names));
            if (!grown) break;
            names = grown;
            cap = ncap;
        }
        if ((names[count] = strdup(e->d_name))) count++;
    }
    closedir(d);
    for (size_t i = 0; i < count; i++) {
        snprintf(dst, sizeof(dst), "%s/%s", sys32, names[i]);
        unlink(dst);
        free(names[i]);
    }
    free(names);
}

/* The WoW64 (i386) title's farms, since system32 is the session's ARM64EC
 * set: drive_c/windows/sysarm64, the aarch64 set its native loader takes
 * (wine-pe 0015), and drive_c/windows/syswow64, the i386 set its guest loader
 * reaches through wow64's system32 redirection. The launch's backend overlay
 * (PLAYPORT_DLL_OVERLAY) goes over a set it has one for: the Vulkan backend's
 * i386 d3d9.dll (DXVK) over Wine's. Every link is recreated, so a later
 * launch without the overlay gets Wine's DLL back. A failure is logged: only
 * i386 titles need them. */
static void link_wow64_farm(const char *name, const char *pe_arch)
{
    char src_dir[1200], dir[1200];
    snprintf(src_dir, sizeof(src_dir), "%s/%s-windows", g_runtime, pe_arch);
    snprintf(dir, sizeof(dir), "%s/drive_c/windows/%s", g_prefix, name);
    if (mkdirs(dir)) {
        host_log("cannot create %s: %s", dir, strerror(errno));
        return;
    }
    host_log("%s: %d links -> %s", name, link_dir_into(src_dir, dir), src_dir);
    const char *overlay = dll_overlay();
    if (overlay) {
        char over_dir[1400];
        snprintf(over_dir, sizeof(over_dir), "%s/%s/%s-windows", g_runtime, overlay, pe_arch);
        int m = link_dir_into(over_dir, dir);   /* -1: the overlay has no such set */
        if (m >= 0) host_log("%s: %d links from %s over them", name, m, over_dir);
    }
}

/* Both the native session and WoW64 titles use win32u's prefix font scan.
 * Recreate links before the session starts GDI: bundle paths change on install.
 * Do not remove unrelated user/game-installed fonts. */
static void link_fonts(void)
{
    char src_dir[1200], dir[1200];
    snprintf(src_dir, sizeof(src_dir), "%s/fonts", g_runtime);
    snprintf(dir, sizeof(dir), "%s/drive_c/windows/fonts", g_prefix);
    if (mkdirs(dir)) {
        host_log("cannot create %s: %s", dir, strerror(errno));
        return;
    }
    host_log("fonts: %d links -> %s", link_dir_into(src_dir, dir), src_dir);
}

/* Point drive_c/windows/system32 at the bundle's PE set. The bundle path
 * changes on every reinstall, so the links are always recreated. A Direct3D
 * backend other than DXMT (PLAYPORT_DLL_OVERLAY, PlayportKit
 * GraphicsBackend.runtimeOverlay) has its own <arch>-windows set, linked over
 * the bundle's: DLLs load through these links, not through WINEDLLPATH's
 * builtin search, so this is where its d3d11.dll replaces DXMT's. Every
 * earlier link into a runtime set is removed first, so a later DXMT launch
 * gets exactly DXMT's set back, without an overlay's extra DLLs. */
static int link_system32(const char *pe_arch)
{
    char src_dir[1200], sys32[1200], src[1600], dst[1600];
    snprintf(src_dir, sizeof(src_dir), "%s/%s-windows", g_runtime, pe_arch);
    snprintf(sys32, sizeof(sys32), "%s/drive_c/windows/system32", g_prefix);
    if (mkdirs(sys32)) {
        host_log("cannot create %s: %s", sys32, strerror(errno));
        return -1;
    }
    unlink_runtime_links(sys32);
    DIR *d = opendir(src_dir);
    if (!d) {
        host_log("cannot open %s: %s", src_dir, strerror(errno));
        return -1;
    }
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(src, sizeof(src), "%s/%s", src_dir, e->d_name);
        snprintf(dst, sizeof(dst), "%s/%s", sys32, e->d_name);
        unlink(dst);
        if (symlink(src, dst) == 0) n++;
    }
    closedir(d);
    host_log("system32: %d links -> %s", n, src_dir);
    const char *overlay = dll_overlay();
    if (n > 0 && overlay) {
        char over_dir[1400];
        snprintf(over_dir, sizeof(over_dir), "%s/%s/%s-windows", g_runtime, overlay, pe_arch);
        int m = link_dir_into(over_dir, sys32);
        host_log("system32: %d links from %s over them", m, over_dir);
        if (m <= 0) return -1;
    }
    if (n > 0) {
        link_wow64_farm("sysarm64", "aarch64");
        link_wow64_farm("syswow64", "i386");
    }
    return n > 0 ? 0 : -1;
}

/* The builtins' registrations (COM classes: the audio path starts with
 * CoCreateInstance(CLSID_MMDeviceEnumerator)), generated at build time by
 * app/tools/prefix-registry.py because the app never runs wineboot. Must run
 * before the wineserver loads the hives. A failure is logged, not fatal:
 * titles that need no registered class still run. */
static void seed_registry(void)
{
    static const char *const hives[] = { "system.reg", "user.reg" };
    for (size_t i = 0; i < sizeof(hives) / sizeof(hives[0]); i++) {
        char seed[1200], hive[1200], msg[256];
        snprintf(seed, sizeof(seed), "%s/registry/%s", g_runtime, hives[i]);
        snprintf(hive, sizeof(hive), "%s/%s", g_prefix, hives[i]);
        int n = prefix_registry_seed(seed, hive, msg, sizeof(msg));
        host_log("registry %s: %s%s", hives[i], n < 0 ? "seed failed: " : "", msg);
    }
}

/* The guest's Windows user: ntdll reports USER as the user name, and shell32
 * resolves %USERPROFILE% to C:\\users\\<name>. app/tools/prefix-registry.py
 * writes the same name into the seeded Volatile Environment (its USER). */
#define WINE_HOST_USER "playport"

/* The profile directories wineboot would create. shell32 fails a folder
 * lookup without CSIDL_FLAG_CREATE when the directory is absent, so without
 * them Unity's persistent-data path (LocalLow) comes back empty and a title
 * cannot save. Documents (CSIDL_PERSONAL) likewise: Witcher 3 looks it up
 * without the flag and, when it fails (0x80070003), reads no user.settings
 * and has nowhere to save (docs/evidence/2026-09-25-witcher3-setup.md). Saved
 * Games is the other common save folder. C:\windows\temp is %TEMP% and %TMP%
 * (the seeded Session Manager\Environment, as wine.inf has them). Existing
 * directories and their contents are left alone. */
static void seed_profile(void)
{
    static const char *const dirs[] = {
        "drive_c/users/" WINE_HOST_USER "/AppData/Local",
        "drive_c/users/" WINE_HOST_USER "/AppData/LocalLow",
        "drive_c/users/" WINE_HOST_USER "/AppData/Roaming",
        "drive_c/users/" WINE_HOST_USER "/Documents",
        "drive_c/users/" WINE_HOST_USER "/Saved Games",
        "drive_c/users/Public",
        "drive_c/ProgramData",
        "drive_c/windows/temp",
    };
    for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
        char path[1200];
        snprintf(path, sizeof(path), "%s/%s", g_prefix, dirs[i]);
        if (mkdirs(path)) host_log("profile: cannot create %s: %s", path, strerror(errno));
    }
    host_log("profile: C:\\users\\%s", WINE_HOST_USER);
}

/* --- wineserver thread -------------------------------------------------- */

static void *server_thread(void *arg)
{
    (void)arg;
    char nls[1200];
    snprintf(nls, sizeof(nls), "%s/nls", g_runtime);
    wineserver_set_nls_dir(nls);
    foreground = 1;
    char *argv[] = { "wineserver", "--foreground", NULL };
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);   /* the runtime's [xp-t] census names threads m<tid> */
    host_log("wineserver_main starting (nls=%s) on thread m%llu", nls, (unsigned long long)tid);
    int rc = wineserver_main(2, argv);
    host_log("wineserver_main returned %d", rc);
    return NULL;
}

/* --- guest process thread ----------------------------------------------- */

/* The session root's main thread is ending through pthread_exit, not through
 * guest_thread's return (a killed Wine thread leaves that way, ntdll's
 * abort_thread). The root never ends its main thread itself, so it is gone:
 * no title can start or be heard from any more. */
static void guest_thread_exiting(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&g_guest_lock);
    g_guest_done = 1;
    pthread_mutex_unlock(&g_guest_lock);
    host_log("session root's main thread ended through pthread_exit");
}

static void *guest_thread(void *arg)
{
    (void)arg;
    wine_ios_main_thread = pthread_self();
    wine_ios_exit_initialized = 1;
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    host_log("__wine_main %s (%s set) on thread m%llu", g_exe_path, g_pe_arch, (unsigned long long)tid);
    pthread_cleanup_push(guest_thread_exiting, NULL);
    if (setjmp(wine_ios_exit_jmpbuf) == 0) {
        __wine_main(g_guest_argc, g_guest_argv);
        host_log("__wine_main returned");
        wine_ios_exit_code = 0;
    }
    pthread_cleanup_pop(0);
    host_log("guest exit code %d", wine_ios_exit_code);
    pthread_mutex_lock(&g_guest_lock);
    g_guest_exit = wine_ios_exit_code;
    g_guest_done = 1;
    pthread_mutex_unlock(&g_guest_lock);
    return NULL;
}

/* --- JIT pool ---------------------------------------------------------- */

/* The slim SDK rejects <mach/mach_vm.h> and omits <sys/codesign.h>; these are
 * the stable prototypes. */
kern_return_t mach_vm_remap(mach_port_t, vm_address_t *, vm_size_t, vm_address_t, int, mach_port_t,
                            vm_address_t, int, vm_prot_t *, vm_prot_t *, vm_inherit_t);
kern_return_t mach_vm_protect(mach_port_t, vm_address_t, vm_size_t, int, int);
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define HOST_CS_OPS_STATUS 0
#define HOST_CS_DEBUGGED 0x10000000

/* Universal JIT protocol, served by app/PlayportJIT/playport-universal.js:
 * x16=1 prepare (x0=NULL: debugserver allocates x1 bytes RX and blesses every
 * 16 KiB page), x16=0 detach. An unserved brk kills the app, so neither is
 * issued before a debugger is attached. */
__attribute__((noinline, optnone, naked)) static void *jit26_prepare_region(void *addr, size_t len)
{
    __asm__("mov x16, #1\n"
            "brk #0xf00d\n"
            "ret\n");
}

__attribute__((noinline, optnone, naked)) static void jit26_detach(void)
{
    __asm__("mov x16, #0\n"
            "brk #0xf00d\n"
            "ret\n");
}

static int debugger_attached(void)
{
    uint32_t flags = 0;
    return csops(getpid(), HOST_CS_OPS_STATUS, &flags, sizeof(flags)) == 0 && (flags & HOST_CS_DEBUGGED);
}

/* One line per mapped run of >= 64 MiB (adjacent regions with the same user
 * tag merged) and per gap of >= 64 MiB, up to TASK_VM_INFO.max_address: the
 * address-space layout FEX has to find a band in. */
static void log_vm_layout(void)
{
    task_vm_info_data_t vmi;
    mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &cnt) == KERN_SUCCESS)
        host_log("vm: max_address=0x%llx min_address=0x%llx", (unsigned long long)vmi.max_address,
                 (unsigned long long)vmi.min_address);
    vm_address_t addr = 0, run_lo = 0, run_hi = 0, prev_end = 0;
    unsigned run_tag = ~0u;
    unsigned long long mapped = 0;
    for (;;) {
        vm_size_t size = 0;
        vm_region_extended_info_data_t info;
        mach_msg_type_number_t n = VM_REGION_EXTENDED_INFO_COUNT;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_EXTENDED_INFO, (vm_region_info_t)&info, &n,
                         &obj) != KERN_SUCCESS)
            break;
        if (addr - prev_end >= (64ull << 20)) {
            if (run_hi - run_lo >= (64ull << 20))
                host_log("vm: map  0x%lx-0x%lx %6llu MiB tag %u", (unsigned long)run_lo, (unsigned long)run_hi,
                         (unsigned long long)((run_hi - run_lo) >> 20), run_tag);
            host_log("vm: gap  0x%lx-0x%lx %6llu MiB", (unsigned long)prev_end, (unsigned long)addr,
                     (unsigned long long)((addr - prev_end) >> 20));
            run_lo = addr;
            run_tag = info.user_tag;
        } else if (info.user_tag != run_tag || addr != run_hi) {
            if (run_hi - run_lo >= (64ull << 20))
                host_log("vm: map  0x%lx-0x%lx %6llu MiB tag %u", (unsigned long)run_lo, (unsigned long)run_hi,
                         (unsigned long long)((run_hi - run_lo) >> 20), run_tag);
            run_lo = addr;
            run_tag = info.user_tag;
        }
        mapped += size;
        run_hi = prev_end = addr + size;
        addr += size;
    }
    if (run_hi - run_lo >= (64ull << 20))
        host_log("vm: map  0x%lx-0x%lx %6llu MiB tag %u", (unsigned long)run_lo, (unsigned long)run_hi,
                 (unsigned long long)((run_hi - run_lo) >> 20), run_tag);
    host_log("vm: last region ends 0x%lx; %llu MiB mapped in all", (unsigned long)prev_end, mapped >> 20);
}

/* The pool's address space, reserved at exec. libmalloc places its start-up
 * heap (~20 MiB) at a random spot in the only low range that can hold the
 * pool, [the executable's end, the thread stacks), before any code of the
 * app's own runs, and in about one launch in four no piece is left that holds
 * 896 MiB on the device. This zero-fill array lives in the executable's
 * __DATA,__bss, which the kernel maps with the image, so nothing can be placed
 * inside it first. Untouched, it costs no footprint. It holds a pool of 896
 * MiB plus the slack below and starts where the image ends, which the slide
 * moves (0x103ea8000 to 0x108540000 seen on the phone).
 * wine_host_jit_pool_acquire frees the pool's range at its start
 * just before debugserver allocates it; its `_M` is a first-fit allocation
 * and nothing below the array can hold the pool, so it lands there. Pool
 * addresses then fall inside the main image's __DATA range as dyld records
 * it, which only changes what dladdr names for a pool pc.
 *
 * No floor applies any more: the 0x119000000 one taken from the reference
 * guarded against "mode A", which belonged to its trap-mode JIT writes
 * (docs/ARCHITECTURE.md, "JIT pool placement"). The rules a placement must
 * meet are selfcheck_pool_placement's. */
#define HOST_POOL_RESERVE_BYTES (960ull << 20)
#define HOST_POOL_SLACK (64ull << 20)   /* for a stray allocation between the free and `_M` */
static char host_pool_reserve[HOST_POOL_RESERVE_BYTES] __attribute__((aligned(0x4000), used));

/* The largest unmapped gap inside [lo, hi), and where it starts. */
static vm_address_t largest_gap(vm_address_t lo, vm_address_t hi, vm_address_t *at)
{
    vm_address_t addr = lo, prev_end = lo, best = 0;
    *at = 0;
    for (;;) {
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t n = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &n,
                         &obj) != KERN_SUCCESS || addr >= hi)
            addr = hi;
        if (addr > prev_end && addr - prev_end > best) {
            best = addr - prev_end;
            *at = prev_end;
        }
        if (addr >= hi) break;
        prev_end = addr + size > prev_end ? addr + size : prev_end;
        addr += size;
    }
    return best;
}

int wine_host_jit_pool_acquire(const char *log_path, size_t size, int wait_ms, void **rx_out, void **rw_out)
{
    if (!rx_out || !rw_out || !size || (size & 0x3fff)) return -1;
    *rx_out = *rw_out = NULL;
    if (log_path && !g_log) g_log = fopen(log_path, "a");

    for (int waited = 0; !debugger_attached(); waited += 50) {
        if (waited >= wait_ms) {
            host_log("JIT pool: no debugger attached after %d ms; no brk issued", wait_ms);
            return -2;
        }
        usleep(50 * 1000);
    }

    /* Free the pool's range at the start of the exec-time reservation
     * (host_pool_reserve). */
    const vm_address_t res_lo = (vm_address_t)host_pool_reserve, res_hi = res_lo + HOST_POOL_RESERVE_BYTES;
    const vm_address_t pool_lo = res_lo;
    vm_address_t freed_hi = 0;
    if (pool_lo + size + HOST_POOL_SLACK <= res_hi) {
        kern_return_t kr = vm_deallocate(mach_task_self(), pool_lo, size + HOST_POOL_SLACK);
        if (kr == KERN_SUCCESS) freed_hi = pool_lo + size + HOST_POOL_SLACK;
        host_log("JIT pool: reserve 0x%lx-0x%lx; freed 0x%lx+%zu MiB for the pool (kr=%d)", (unsigned long)res_lo,
                 (unsigned long)res_hi, (unsigned long)pool_lo, (size + HOST_POOL_SLACK) >> 20, kr);
    } else {
        /* Too large for the reservation: give it back and place the pool the
         * old way, first fit in whatever is free. */
        kern_return_t kr = vm_deallocate(mach_task_self(), res_lo, res_hi - res_lo);
        host_log("JIT pool: reserve 0x%lx-0x%lx holds %lu MiB, pool needs %zu + %llu MiB; "
                 "released (kr=%d), unreserved placement", (unsigned long)res_lo, (unsigned long)res_hi,
                 (unsigned long)((res_hi - res_lo) >> 20), size >> 20, HOST_POOL_SLACK >> 20, kr);
    }

    /* Without the reservation, libmalloc's start-up heap could split the low
     * range below the shared cache so no piece held the pool, and the
     * debugger's allocation went to 0x7000000000 and was refused below. This
     * line says which case a launch was in. */
    {
        vm_address_t gap_at, gap = largest_gap(SELFCHECK_POOL_MIN, SELFCHECK_POOL_END_MAX, &gap_at);
        host_log("JIT pool: largest gap in [4 GiB, 2^36): %lu MiB at 0x%lx (pool needs %zu MiB)",
                 (unsigned long)(gap >> 20), (unsigned long)gap_at, size >> 20);
    }
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    void *rx = jit26_prepare_region(NULL, size);
    gettimeofday(&t1, NULL);
    double bless_s = (t1.tv_sec - t0.tv_sec) + (t1.tv_usec - t0.tv_usec) / 1e6;
    vm_address_t a = (vm_address_t)rx;
    host_log("JIT pool: prepare(NULL, 0x%zx) -> %p in %.2f s", size, rx, bless_s);
    int rc = 0;
    if (!rx) rc = -3;
    else {
        int placed = selfcheck_pool_placement(a, size);
        if (placed != SELFCHECK_OK) {
            host_log("JIT pool: refused placement %p+0x%zx (%s: it must lie in [4 GiB, 2^36), "
                     "outside the guest window)", rx, size, selfcheck_name(placed));
            rc = -4;
        }
    }
    if (freed_hi) {
        int in_reserve = rx && a >= pool_lo && a + size <= freed_hi;
        host_log("JIT pool: placement %s the reservation (+0x%lx)", in_reserve ? "inside" : "OUTSIDE",
                 in_reserve ? (unsigned long)(a - pool_lo) : 0ul);
        /* The rest of the reservation above the pool goes back to the system:
         * the start-up heap and thread stacks share this range with it. */
        if (freed_hi < res_hi) vm_deallocate(mach_task_self(), freed_hi, res_hi - freed_hi);
    }
    vm_address_t rw = 0;
    if (!rc) {
        vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
        kern_return_t kr = mach_vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), a,
                                         FALSE, &cur, &max, VM_INHERIT_NONE);
        if (kr == KERN_SUCCESS) kr = mach_vm_protect(mach_task_self(), rw, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS) {
            host_log("JIT pool: RW alias failed kr=%d", kr);
            rc = -5;
        }
    }
    /* Early detach, as the reference does before the wineserver starts: the
     * pool stays executable, and ntdll's trap handler skips any later stray
     * brk #0xf00d (signal_arm64_ios.c trap_handler). */
    jit26_detach();
    if (rc) return rc;
    *rx_out = rx;
    *rw_out = (void *)rw;
    host_log("JIT pool: rx=%p rw=%p size=0x%zx; debugger detached", rx, (void *)rw, size);
    log_vm_layout();
    return 0;
}

/* --- start-up self-check ------------------------------------------------ */

/* A fresh pthread key's raw TSD slot, found the way ntdll finds the TEB's
 * (loader_ios.c): a sentinel stored through pthread_setspecific, looked for
 * off TPIDRRO_EL0. The translated code reads the TEB through that base. */
static int tsd_probe(int *key_out)
{
    pthread_key_t key;
    *key_out = -1;
    if (pthread_key_create(&key, NULL)) return -1;
    *key_out = (int)key;
    uintptr_t base;
    __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(base));
    base &= ~(uintptr_t)7;
    void *const sentinel = (void *)(uintptr_t)0x504c50545344534bULL;
    int slot = -1;
    if (base && !pthread_setspecific(key, sentinel)) {
        for (int s = 0; s < SELFCHECK_TSD_SLOTS; s++)
            if (((void *const *)base)[s] == sentinel) {
                slot = s;
                break;
            }
    }
    pthread_setspecific(key, NULL);
    pthread_key_delete(key);
    return slot;
}

int wine_host_selfcheck(const void *rx, const void *rw, size_t size, char *report, size_t len)
{
    selfcheck_facts f = { .page_size = vm_page_size };
    f.tsd_slot = tsd_probe(&f.tsd_key);
    if (rx) {
        f.pool = 1;
        f.pool_rx = (uintptr_t)rx;
        f.pool_rw = (uintptr_t)rw;
        f.pool_size = size;
        /* The pool's first word after the page's blessing marker: nothing
         * uses the pool before wine_host_init. */
        if (rw && size >= 16) {
            volatile uint64_t *w = (volatile uint64_t *)((char *)(uintptr_t)rw + 8);
            const volatile uint64_t *r = (const volatile uint64_t *)((const char *)rx + 8);
            uint64_t was = *w;
            *w = 0x5053454c46434b31ULL;
            f.alias_ok = *r == 0x5053454c46434b31ULL;
            *w = was;
            f.alias_ok &= *r == was;
        }
    }
    char line[384];
    int rc = selfcheck_judge(&f, line, sizeof(line));
    if (report && len) snprintf(report, len, "%s", line);
    return rc;
}

/* --- ABI ---------------------------------------------------------------- */

int wine_host_abi_version(void)
{
    return WINE_HOST_ABI_VERSION;
}

static void setenv_hex(const char *name, unsigned long long v)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%llx", v);
    setenv(name, buf, 1);
}

int wine_host_init(const wine_host_config *c)
{
    if (!c || c->abi_version != WINE_HOST_ABI_VERSION) return -1;
    if (g_server_started) return -2;
    g_log_fn = c->log;
    if (c->log_path) {
        if (!g_log) g_log = fopen(c->log_path, "a");
        int fd = open(c->log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {   /* ntdll and wineserver report through stderr */
            dup2(fd, STDERR_FILENO);
            close(fd);
        }
        if (g_log_limit) {
            pthread_t t;
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
            pthread_attr_set_qos_class_np(&attr, QOS_CLASS_UTILITY, 0);
            pthread_create(&t, &attr, log_limit_thread, NULL);
            pthread_attr_destroy(&attr);
        } else {
            wineserver_log_set_file(c->log_path);
            if (getenv("WINE_HOST_LOG_STAMP")) stamp_stderr();
            /* The runtime's diagnostic probes ([EXC_SAMPLE] and the rest), off
             * by default: they cost time, so only for a profile run. */
            if (getenv("WINE_HOST_DIAG")) madeira_set_diag_enabled(1);
            if (getenv("WINE_HOST_SAMPLE")) start_sampler(atof(getenv("WINE_HOST_SAMPLE")) > 0 ? atof(getenv("WINE_HOST_SAMPLE")) : 15);
        }
    }
    host_log("init abi=%d runtime=%s prefix=%s", WINE_HOST_ABI_VERSION, c->runtime_dir, c->prefix_dir);
    if (!c->runtime_dir || !c->prefix_dir) return -3;
    if (!c->jit_rx || !c->jit_rw || !c->jit_size) {
        host_log("refused: no debugger-blessed JIT pool (SP1 S1.1/S1.3)");
        return -4;
    }
    snprintf(g_runtime, sizeof(g_runtime), "%s", c->runtime_dir);
    snprintf(g_prefix, sizeof(g_prefix), "%s", c->prefix_dir);
    if (mkdirs(g_prefix)) return -5;

    /* DXMT keeps its converted shaders (DXBC to AIR, per variant) in an
     * SQLite file under the per-user cache directory, which it finds with
     * confstr(_CS_DARWIN_USER_CACHE_DIR). On iOS that call fails in this
     * process (the log says "[CacheReader] Failed to resolve cache path"), so
     * every launch converted every shader again, on the draw that first
     * needed it. An absolute DXMT_SHADER_CACHE_PATH skips the lookup; it must
     * be taken from HOME before HOME becomes the prefix. The keys are shader
     * and variant hashes, so one file serves every title. */
    /* KosmicKrisp (mesa 0015) keeps the MSL of every pipeline in Mesa's disk
     * cache, in MESA_SHADER_CACHE_DIR/mesa_shader_cache, trimmed to the size
     * limit; without the directory it would go under HOME/.cache, which is
     * the prefix by then. */
    const char *home = getenv("HOME");
    if (home && home[0] == '/' && strcmp(home, g_prefix) != 0) {
        char cache[1024];
        snprintf(cache, sizeof(cache), "%s/Library/Caches/dxmt/", home);
        setenv("DXMT_SHADER_CACHE_PATH", cache, 0);
        int n = snprintf(cache, sizeof(cache), "%s/Library/Caches/kosmickrisp", home);
        if (n > 0 && (size_t)n < sizeof(cache) && mkdirs(cache) == 0)
            setenv("MESA_SHADER_CACHE_DIR", cache, 0);
    }
    setenv("MESA_SHADER_CACHE_MAX_SIZE", "256M", 0);
    host_log("DXMT shader cache: %s", getenv("DXMT_SHADER_CACHE_PATH") ? getenv("DXMT_SHADER_CACHE_PATH") : "(none)");
    host_log("Mesa shader cache: %s (limit %s)",
             getenv("MESA_SHADER_CACHE_DIR") ? getenv("MESA_SHADER_CACHE_DIR") : "HOME/.cache",
             getenv("MESA_SHADER_CACHE_MAX_SIZE"));

    setenv("WINEPREFIX", g_prefix, 1);
    setenv("HOME", g_prefix, 1);
    setenv("USER", WINE_HOST_USER, 1);
    setenv("WINELOADERNOEXEC", "1", 1);   /* no re-exec of a loader binary */
    /* A Direct3D backend other than DXMT ships its builtins in a directory of
     * the runtime (PlayportKit GraphicsBackend.runtimeOverlay), which the
     * launch names in PLAYPORT_DLL_OVERLAY; its <arch>-windows builtins are
     * found before the runtime's own. */
    const char *overlay = dll_overlay();
    if (overlay) {
        char dllpath[2 * sizeof(g_runtime) + 64];
        snprintf(dllpath, sizeof(dllpath), "%s/%s:%s", g_runtime, overlay, g_runtime);
        setenv("WINEDLLPATH", dllpath, 1);
    } else {
        setenv("WINEDLLPATH", g_runtime, 1);
    }
    host_log("WINEDLLPATH=%s", getenv("WINEDLLPATH"));
    setenv_hex("WINE_IOS_JIT_RX", (unsigned long long)(uintptr_t)c->jit_rx);
    setenv_hex("WINE_IOS_JIT_RW", (unsigned long long)(uintptr_t)c->jit_rw);
    setenv_hex("WINE_IOS_JIT_SIZE", (unsigned long long)c->jit_size);
    char off[32];
    snprintf(off, sizeof(off), "%lld", (long long)((char *)c->jit_rw - (char *)c->jit_rx));
    setenv("MADEIRA_JIT_WRITE_OFFSET", off, 1);
    /* wineserver publishes KUSER_SHARED_DATA's clock only when this is 1;
     * without it GetTickCount/GetTickCount64 never advance. */
    setenv("MADEIRA_USD_TIME", "1", 1);
    /* wineserver only snapshots a suspended thread's registers and lets it run
     * unless this is 1 (Madeira ml730); SuspendThread then does not suspend.
     * The hold is taken at a safe point (patches/madeira-unix/0010-wineserver-hold-a-really-suspended-thread-only-at-a-.patch). */
    setenv("MADEIRA_REAL_SUSPEND", "1", 1);
    /* Without this, ntdll registers no win32u syscall table (Madeira
     * virtual_ios.c load_builtin_unixlib: "win32u unix lib linked but
     * dormant"), so every NtUser/NtGdi call from user32 and gdi32 fails and
     * leaves its outputs unwritten: PeekMessageW "succeeds" with the caller's
     * MSG untouched and DispatchMessageW calls stack garbage as a window
     * procedure. The reference sets it
     * unconditionally (WineProcessBridge.m). */
    setenv("MADEIRA_WIN32U", "1", 1);
    host_log("JIT pool rx=%p rw=%p size=0x%zx write_offset=%s", c->jit_rx, c->jit_rw, c->jit_size, off);

    seed_profile();
    seed_registry();

    g_wineserver_should_stop = 0;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    /* the server is on the critical path of every guest request */
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    int rc = pthread_create(&g_server_thread, &attr, server_thread, NULL);
    pthread_attr_destroy(&attr);
    if (rc) {
        host_log("wineserver thread: %s", strerror(rc));
        return -6;
    }
    g_server_started = 1;
    return 0;
}

/* Start the guest process thread (the session root) on g_guest_argv. */
static int start_guest(void)
{
    /* The guest reaches the server through a socketpair: pair[0] is injected
     * into the server loop, pair[1] is the client fd ntdll picks up from
     * WINESERVERSOCKET instead of connecting to a socket path. */
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) {
        host_log("socketpair: %s", strerror(errno));
        return -3;
    }
    char fd[16];
    snprintf(fd, sizeof(fd), "%d", pair[1]);
    setenv("WINESERVERSOCKET", fd, 1);
    wineserver_inject_client_fd(pair[0]);

    g_guest_done = 0;
    g_guest_exit = -1;
    int rc = pthread_create(&g_guest_thread, NULL, guest_thread, NULL);
    if (rc) {
        host_log("guest thread: %s", strerror(rc));
        close(pair[0]);
        close(pair[1]);
        return -4;
    }
    g_guest_started = 1;
    return 0;
}

/* --- the session root (decisions 0027, 0030) ---------------------------- */

/* The one __wine_main of the app process is the session root,
 * playport-session.exe (app/SessionRoot). It starts the process's one title as
 * its child, in a job with everything the title starts, and reports through
 * files in the session directory (session_protocol.h). After that title the
 * app restarts itself (decision 0029): nothing here starts a second one. */
static char g_session_dir[1200];
static const uint32_t g_session_seq = 1; /* the one request's sequence */
static int g_session_ready;            /* the root answered READY */
static int g_session_launched;         /* the one launch was asked for */
static int g_session_title;            /* the title is running (STARTED, no EXITED yet) */

static int guest_ended(void)
{
    pthread_mutex_lock(&g_guest_lock);
    int done = g_guest_done;
    pthread_mutex_unlock(&g_guest_lock);
    return done;
}

static void session_path(char *out, size_t cap, const char *name)
{
    snprintf(out, cap, "%s/%s", g_session_dir, name);
}

/* The root's last reply, when it is whole and names this sequence. */
static int session_reply(uint32_t sequence, pp_session_reply *out)
{
    char path[sizeof(g_session_dir) + 16];
    session_path(path, sizeof(path), "reply");
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, out, sizeof(*out));
    close(fd);
    return n == (ssize_t)sizeof(*out) && out->magic == PP_SESSION_MAGIC && out->sequence == sequence;
}

/* Writes a request whole under a temporary name and renames it into place. */
static int session_send(const char *name, const pp_session_request *r, const char *payload)
{
    char path[sizeof(g_session_dir) + 16], tmp[sizeof(g_session_dir) + 24];
    session_path(path, sizeof(path), name);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    int ok = fd >= 0 && write(fd, r, sizeof(*r)) == (ssize_t)sizeof(*r) &&
             (!r->length || write(fd, payload, r->length) == (ssize_t)r->length);
    if (fd >= 0) close(fd);
    if (ok && rename(tmp, path) == 0) return 0;
    host_log("session: cannot write %s: %s", path, strerror(errno));
    unlink(tmp);
    return -1;
}

/* Waits up to timeout_ms for a reply to sequence in one of the states in want
 * (a bit mask of 1 << state); 1 with it in out, 0 on timeout, -1 when the root has ended. */
static int session_await(uint32_t sequence, unsigned want, int timeout_ms, pp_session_reply *out)
{
    for (int waited = 0;; waited += 20) {
        if (session_reply(sequence, out) && (want & (1u << out->state))) return 1;
        if (guest_ended()) return -1;
        if (waited >= timeout_ms) return 0;
        usleep(20 * 1000);
    }
}

int wine_host_session_start(int timeout_ms)
{
    if (!g_server_started || g_guest_started) return -1;
    link_fonts();
    if (link_system32("arm64ec")) return -2;
    snprintf(g_session_dir, sizeof(g_session_dir), "%s/%s", g_prefix, PP_SESSION_DIR_UNIX);
    if (mkdirs(g_session_dir)) {
        host_log("session: cannot create %s: %s", g_session_dir, strerror(errno));
        return -2;
    }
    char path[sizeof(g_session_dir) + 16];
    session_path(path, sizeof(path), "reply");
    unlink(path);
    session_path(path, sizeof(path), "control-reply");   /* an earlier process's, under the same sequences */
    unlink(path);
    /* The root's own working directory is ntdll's default; each title gets its own. */
    unsetenv("MADEIRA_INITIAL_CWD");
    snprintf(g_exe_path, sizeof(g_exe_path), "%s", PP_SESSION_ROOT_DOS);
    g_pe_arch = "arm64ec";
    g_guest_argv[0] = "wine";
    g_guest_argv[1] = g_exe_path;
    g_guest_argv[2] = PP_SESSION_DIR_DOS;
    g_guest_argv[3] = NULL;
    g_guest_argc = 3;
    int rc = start_guest();
    if (rc) return rc;
    pp_session_reply r;
    rc = session_await(0, 1u << PP_ROOT_READY, timeout_ms, &r);
    if (rc != 1) {
        host_log("session: the root %s", rc < 0 ? "ended before it was ready" : "was not ready in time");
        return -5;
    }
    g_session_ready = 1;
    host_log("session: root ready (pid %04x); the title starts as its child", r.code);
    return 0;
}

int wine_host_session_launch(const char *dos_path, const char *const *args, int nargs,
                             const char *const *env, int nenv, int timeout_ms)
{
    if (!g_session_ready || g_session_launched || !dos_path || nargs < 0 ||
        nargs > (int)PP_SESSION_MAX_ARGS || (nargs && !args) || nenv < 0 || nenv > (int)PP_SESSION_MAX_ENV ||
        (nenv && !env))
        return -1;
    for (int i = 0; i < nargs; i++)
        if (!args[i] || strlen(args[i]) >= 1024) {
            host_log("session: argument %d missing or too long", i + 1);
            return -1;
        }
    for (int i = 0; i < nenv; i++)
        if (!env[i] || !strchr(env[i], '=') || env[i][0] == '=' || strlen(env[i]) >= 4096) {
            host_log("session: variable %d missing or malformed", i + 1);
            return -1;
        }
    title_path tp;
    char msg[512];
    int rc = title_path_resolve(g_prefix, dos_path, &tp, msg, sizeof(msg));
    host_log("session: %s -> %d %s", dos_path, rc, msg);
    if (rc) return -5;
    /* The title's own DLLs load from its directory; everything else from the
     * runtime's set, with this launch's backend overlay (PLAYPORT_DLL_OVERLAY). */
    if (link_system32(g_pe_arch)) return -2;

    char *payload = malloc(PP_SESSION_MAX_PAYLOAD);
    if (!payload) return -3;
    size_t used = 0;
    int fits = 1;
#define ADD(str) do { size_t n_ = strlen(str) + 1; \
        if (used + n_ > PP_SESSION_MAX_PAYLOAD) fits = 0; else { memcpy(payload + used, str, n_); used += n_; } } while (0)
    ADD(tp.dos);
    ADD(tp.dos_dir);
    for (int i = 0; i < nargs; i++) ADD(args[i]);
    for (int i = 0; i < nenv; i++) ADD(env[i]);
#undef ADD
    if (!fits) {
        free(payload);
        host_log("session: the request is over %u bytes", PP_SESSION_MAX_PAYLOAD);
        return -1;
    }
    g_session_launched = 1;
    pp_session_request req = { PP_SESSION_MAGIC, g_session_seq, PP_REQUEST_LAUNCH, (uint32_t)used,
                               (uint32_t)nargs, (uint32_t)nenv };
    host_log("session: title %u: %s in %s, %d arguments, %d variables", req.sequence, tp.dos, tp.dos_dir, nargs, nenv);
    for (int i = 0; i < nargs; i++) host_log("session: title %u: argv[%d] = \"%s\"", req.sequence, i + 1, args[i]);
    rc = session_send("request", &req, payload);
    free(payload);
    if (rc) return -4;
    pp_session_reply r;
    rc = session_await(req.sequence, (1u << PP_TITLE_STARTED) | (1u << PP_TITLE_REFUSED) | (1u << PP_TITLE_EXITED),
                       timeout_ms, &r);
    if (rc != 1) {
        host_log("session: title %u: the root %s", req.sequence, rc < 0 ? "has ended" : "did not answer in time");
        return -6;
    }
    if (r.state == PP_TITLE_REFUSED) {
        host_log("session: title %u: not started, Windows error %u", req.sequence, r.code);
        return -7;
    }
    g_session_title = 1;
    host_log("session: title %u: started", req.sequence);
    return 0;
}

int wine_host_session_wait(int timeout_ms, int *exit_code)
{
    if (!g_session_title) return -1;
    pp_session_reply r;
    int rc = session_await(g_session_seq, 1u << PP_TITLE_EXITED, timeout_ms, &r);
    if (rc < 0) {
        g_session_title = 0;
        host_log("session: the root ended while title %u ran", g_session_seq);
        return -2;
    }
    if (!rc) return 1;
    g_session_title = 0;
    if (exit_code) *exit_code = (int)r.code;
    host_log("session: title %u: ended, exit code 0x%08x", g_session_seq, r.code);
    return 0;
}

/* The in-game menu's controls (session_protocol.h): a file of their own and
 * an answer of their own, so the title's reply, which wine_host_session_wait
 * reads, is never replaced by one. */
static pthread_mutex_t g_control_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_control_seq;

int wine_host_session_control(int kind, unsigned wait_ms, int timeout_ms, unsigned *count)
{
    if (count) *count = 0;
    if (!g_session_title) return -1;
    pp_session_control c = { PP_SESSION_MAGIC, 0, (uint32_t)kind, kind == PP_CONTROL_CLOSE ? wait_ms : 0 };
    pthread_mutex_lock(&g_control_lock);
    c.sequence = ++g_control_seq;
    if (!pp_session_control_valid(&c, sizeof(c))) {
        pthread_mutex_unlock(&g_control_lock);
        return -1;
    }
    char path[sizeof(g_session_dir) + 24], tmp[sizeof(g_session_dir) + 32];
    session_path(path, sizeof(path), "control");
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    int ok = fd >= 0 && write(fd, &c, sizeof(c)) == (ssize_t)sizeof(c);
    if (fd >= 0) close(fd);
    if (!ok || rename(tmp, path) != 0) {
        host_log("session: cannot write %s: %s", path, strerror(errno));
        unlink(tmp);
        pthread_mutex_unlock(&g_control_lock);
        return -4;
    }
    int rc = -6;
    session_path(path, sizeof(path), "control-reply");
    for (int waited = 0; waited <= timeout_ms && !guest_ended(); waited += 10) {
        pp_session_reply r;
        int rfd = open(path, O_RDONLY);
        ssize_t n = rfd >= 0 ? read(rfd, &r, sizeof(r)) : -1;
        if (rfd >= 0) close(rfd);
        if (n == (ssize_t)sizeof(r) && r.magic == PP_SESSION_MAGIC && r.sequence == c.sequence) {
            if (count) *count = r.code;
            rc = r.state == PP_CONTROL_DONE ? 0 : -7;
            break;
        }
        usleep(10 * 1000);
    }
    pthread_mutex_unlock(&g_control_lock);
    if (rc) host_log("session: control %d (sequence %u) -> %d", kind, c.sequence, rc);
    return rc;
}

extern int ios_jit_pool_stats(unsigned long long *v, int n);

int wine_host_pool_stats_read(wine_host_pool_stats *out)
{
    enum { FIELDS = sizeof(wine_host_pool_stats) / sizeof(unsigned long long) };
    unsigned long long v[FIELDS];
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    int n = ios_jit_pool_stats(v, FIELDS);
    if (n <= 0) return -1;
    memcpy(out, v, (size_t)n * sizeof(v[0]));   /* the fields are the runtime's, in its order */
    return 0;
}

extern int ios_runtime_limit_stats(unsigned long long *v, int n);

int wine_host_limit_stats_read(wine_host_limit_stats *out)
{
    enum { FIELDS = sizeof(wine_host_limit_stats) / sizeof(unsigned long long) };
    unsigned long long v[FIELDS];
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    int n = ios_runtime_limit_stats(v, FIELDS);
    if (n <= 0) return -1;
    memcpy(out, v, (size_t)n * sizeof(v[0]));   /* the fields are the runtime's, in its order */
    return 0;
}

extern int ios_fex_band_stats(unsigned long long *v, int n);
extern void ios_fex_band_dump(const char *why);

int wine_host_band_stats_read(wine_host_band_stats *out)
{
    enum { FIELDS = sizeof(wine_host_band_stats) / sizeof(unsigned long long) };
    unsigned long long v[FIELDS];
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    int n = ios_fex_band_stats(v, FIELDS);
    if (n <= 0) return -1;
    memcpy(out, v, (size_t)n * sizeof(v[0]));   /* the fields are the runtime's, in its order */
    return 0;
}

void wine_host_band_dump(const char *why)
{
    ios_fex_band_dump(why);
}
