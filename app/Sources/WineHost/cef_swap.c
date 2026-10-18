/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * cef_swap — see include/cef_swap.h.
 *
 * Plain POSIX C with no Apple headers, so the host C tests (`pp test`, app/tests)
 * can build and exercise it on the Linux host.
 */

#include "cef_swap.h"

#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

/* NtCreateFile's constants (winnt.h, winternl.h). */
#define CS_DELETE                0x00010000u
#define CS_WRITE_DAC             0x00040000u
#define CS_WRITE_OWNER           0x00080000u
#define CS_MAXIMUM_ALLOWED       0x02000000u
#define CS_GENERIC_ALL           0x10000000u
#define CS_GENERIC_WRITE         0x40000000u
#define CS_FILE_WRITE_DATA       0x0002u
#define CS_FILE_APPEND_DATA      0x0004u
#define CS_FILE_WRITE_EA         0x0010u
#define CS_FILE_DELETE_CHILD     0x0040u
#define CS_FILE_WRITE_ATTRIBUTES 0x0100u
#define CS_FILE_OPEN             1u
#define CS_FILE_DELETE_ON_CLOSE  0x00001000u

#define CS_WRITE_ACCESS (CS_DELETE | CS_WRITE_DAC | CS_WRITE_OWNER | CS_MAXIMUM_ALLOWED | CS_GENERIC_ALL \
                         | CS_GENERIC_WRITE | CS_FILE_WRITE_DATA | CS_FILE_APPEND_DATA | CS_FILE_WRITE_EA \
                         | CS_FILE_DELETE_CHILD | CS_FILE_WRITE_ATTRIBUTES)

/* CEF's runtime files beside libcef.dll, as Playport's payload spells them
 * (build/generated/cef-143.0.14.sha256, flattened). The locales are matched apart. */
static const char *const top_level[] = {
    "libcef.dll", "chrome_elf.dll", "v8_context_snapshot.bin", "icudtl.dat",
    "resources.pak", "chrome_100_percent.pak", "chrome_200_percent.pak",
    "libEGL.dll", "libGLESv2.dll", "vk_swiftshader.dll", "vk_swiftshader_icd.json", "vulkan-1.dll",
};

static int ends_with(const char *s, size_t n, const char *suffix)
{
    size_t k = strlen(suffix);
    return n >= k && !strncasecmp(s + n - k, suffix, k);
}

const char *cef_swap_payload_name(const char *dir_base, size_t dir_base_len, const char *base,
                                  char *buf, size_t buflen)
{
    size_t n = strlen(base), i;
    /* The fast path for every other open: the extension alone. */
    if (!ends_with(base, n, ".dll") && !ends_with(base, n, ".pak") && !ends_with(base, n, ".bin")
        && !ends_with(base, n, ".dat") && !ends_with(base, n, ".json"))
        return NULL;
    if (dir_base_len == 7 && !strncasecmp(dir_base, "locales", 7)) {
        if (!ends_with(base, n, ".pak") || n == 4 || snprintf(buf, buflen, "locales/%s", base) >= (int)buflen)
            return NULL;
        return buf;
    }
    for (i = 0; i < sizeof(top_level) / sizeof(*top_level); i++)
        if (!strcasecmp(base, top_level[i])) return top_level[i];
    return NULL;
}

int cef_swap_read_only(unsigned int access, unsigned int disposition, unsigned int options)
{
    return disposition == CS_FILE_OPEN && !(access & CS_WRITE_ACCESS) && !(options & CS_FILE_DELETE_ON_CLOSE);
}

/* ---- the version guard: VS_FIXEDFILEINFO from the standard RT_VERSION resource ---- */

static int read_at(int fd, uint64_t off, void *buf, size_t n)
{
    return pread(fd, buf, n, (off_t)off) == (ssize_t)n ? 0 : -1;
}

static uint16_t u16(const unsigned char *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t u32(const unsigned char *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

struct pe { int fd; uint32_t nsec; uint64_t sec_off; };

/* An RVA's file offset, with at least need bytes inside its section's raw data. */
static int rva_to_offset(const struct pe *pe, uint32_t rva, uint32_t need, uint64_t *off)
{
    unsigned char s[40];
    uint32_t i;
    for (i = 0; i < pe->nsec; i++) {
        uint32_t va, vsize, raw_size, raw_ptr;
        if (read_at(pe->fd, pe->sec_off + 40ull * i, s, sizeof(s))) return -1;
        vsize = u32(s + 8); va = u32(s + 12); raw_size = u32(s + 16); raw_ptr = u32(s + 20);
        if (rva < va || rva - va >= (vsize > raw_size ? vsize : raw_size)) continue;
        if ((uint64_t)(rva - va) + need > raw_size) return -1;
        *off = (uint64_t)raw_ptr + (rva - va);
        return 0;
    }
    return -1;
}

/* The entry of a resource directory (at rsrc + dir) whose ID is id, or its first entry
 * when id is -1. Returns its OffsetToData, or -1. */
static int64_t resource_entry(const struct pe *pe, uint64_t rsrc, uint32_t rsize, uint32_t dir, int id)
{
    unsigned char d[16], e[8];
    uint32_t count, i;
    if ((uint64_t)dir + 16 > rsize || read_at(pe->fd, rsrc + dir, d, sizeof(d))) return -1;
    count = (uint32_t)u16(d + 12) + u16(d + 14);
    if (count > 4096) return -1;
    for (i = 0; i < count; i++) {
        uint64_t at = (uint64_t)dir + 16 + 8ull * i;
        if (at + 8 > rsize || read_at(pe->fd, rsrc + at, e, sizeof(e))) return -1;
        if (id < 0 || (!(u32(e) & 0x80000000u) && u32(e) == (uint32_t)id)) return u32(e + 4);
    }
    return -1;
}

int cef_swap_file_version(const char *path, unsigned int *ms, unsigned int *ls)
{
    static const char key[] = "VS_VERSION_INFO";
    unsigned char h[264], data[92];
    struct pe pe;
    uint32_t lfanew, optsz, magic, ndirs, dirs, rsrc_rva, rsrc_size, data_rva, data_size, i;
    uint64_t rsrc, off;
    int64_t e;
    int rc = -1;

    pe.fd = open(path, O_RDONLY | O_CLOEXEC);
    if (pe.fd < 0) return -1;
    if (read_at(pe.fd, 0, h, 64) || h[0] != 'M' || h[1] != 'Z') goto done;
    lfanew = u32(h + 0x3c);
    if (lfanew > (1u << 20) || read_at(pe.fd, lfanew, h, sizeof(h)) || memcmp(h, "PE\0\0", 4)) goto done;
    pe.nsec = u16(h + 6);
    optsz = u16(h + 20);
    magic = u16(h + 24);
    if (magic == 0x20b) { ndirs = u32(h + 24 + 108); dirs = 24 + 112; }
    else if (magic == 0x10b) { ndirs = u32(h + 24 + 92); dirs = 24 + 96; }
    else goto done;
    if (ndirs < 3 || dirs + 3 * 8 > 24 + optsz || dirs + 3 * 8 > sizeof(h) || pe.nsec > 96) goto done;
    rsrc_rva = u32(h + dirs + 16);
    rsrc_size = u32(h + dirs + 20);
    pe.sec_off = (uint64_t)lfanew + 24 + optsz;
    if (!rsrc_rva || rsrc_size < 16 || rva_to_offset(&pe, rsrc_rva, rsrc_size, &rsrc)) goto done;

    /* Type RT_VERSION (16), then its first name and first language. */
    if ((e = resource_entry(&pe, rsrc, rsrc_size, 0, 16)) < 0 || !(e & 0x80000000u)) goto done;
    if ((e = resource_entry(&pe, rsrc, rsrc_size, (uint32_t)e & 0x7fffffffu, -1)) < 0 || !(e & 0x80000000u)) goto done;
    if ((e = resource_entry(&pe, rsrc, rsrc_size, (uint32_t)e & 0x7fffffffu, -1)) < 0 || (e & 0x80000000u)) goto done;
    if ((uint64_t)e + 16 > rsrc_size || read_at(pe.fd, rsrc + (uint64_t)e, h, 16)) goto done;
    data_rva = u32(h);
    data_size = u32(h + 4);
    if (data_size < sizeof(data) || rva_to_offset(&pe, data_rva, sizeof(data), &off) || read_at(pe.fd, off, data, sizeof(data)))
        goto done;

    /* VS_VERSIONINFO: wLength, wValueLength, wType, L"VS_VERSION_INFO", padding to 4, VS_FIXEDFILEINFO. */
    if (u16(data) < 40 + 52 || u16(data + 2) < 52) goto done;
    for (i = 0; i < sizeof(key); i++)
        if (u16(data + 6 + 2 * i) != (unsigned char)key[i]) goto done;
    if (u32(data + 40) != 0xfeef04bdu) goto done;
    *ms = u32(data + 48);
    *ls = u32(data + 52);
    rc = 0;
done:
    close(pe.fd);
    return rc;
}

/* ---- the per-directory decisions and per-file logs ---- */

enum { DIR_MATCH, DIR_OTHER };
enum { MAX_DIRS = 32, MAX_LOGGED = 64 };

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct { char *dir; int state; } dirs[MAX_DIRS];
static int ndirs, dirs_full_logged;
static char *logged[MAX_LOGGED];
static int nlogged;
static int payload_state;   /* 0 unchecked, 1 present, -1 absent */

void cef_swap_reset(void)
{
    int i;
    pthread_mutex_lock(&lock);
    for (i = 0; i < ndirs; i++) free(dirs[i].dir);
    for (i = 0; i < nlogged; i++) free(logged[i]);
    ndirs = nlogged = dirs_full_logged = payload_state = 0;
    pthread_mutex_unlock(&lock);
}

/* The client's libcef.dll in dir, by any case of its name. */
static char *find_libcef(const char *dir)
{
    char *path;
    DIR *d;
    struct dirent *ent;
    if (asprintf(&path, "%s/libcef.dll", dir) < 0) return NULL;
    if (!access(path, F_OK)) return path;
    free(path);
    path = NULL;
    if (!(d = opendir(dir))) return NULL;
    while ((ent = readdir(d)))
        if (!strcasecmp(ent->d_name, "libcef.dll")) {
            if (asprintf(&path, "%s/%s", dir, ent->d_name) < 0) path = NULL;
            break;
        }
    closedir(d);
    return path;
}

/* The decision for a CEF directory, made and logged once (lock held). */
static int dir_decision(const char *dir)
{
    unsigned int ms, ls;
    char *libcef;
    int i, state;
    for (i = 0; i < ndirs; i++)
        if (!strcmp(dirs[i].dir, dir)) return dirs[i].state;
    libcef = find_libcef(dir);
    if (!libcef || cef_swap_file_version(libcef, &ms, &ls)) {
        dprintf(2, "[cef-swap] %s: libcef.dll has no readable version resource; left alone\n", dir);
        state = DIR_OTHER;
    } else if (ms != CEF_SWAP_VERSION_MS || ls != CEF_SWAP_VERSION_LS) {
        dprintf(2, "[cef-swap] %s: libcef.dll file version %u.%u.%u.%u, not %s.0; left alone\n",
                dir, ms >> 16, ms & 0xffff, ls >> 16, ls & 0xffff, CEF_SWAP_VERSION);
        state = DIR_OTHER;
    } else {
        dprintf(2, "[cef-swap] %s: libcef.dll file version %s.0 matches; its CEF files come from Playport's build\n",
                dir, CEF_SWAP_VERSION);
        state = DIR_MATCH;
    }
    free(libcef);
    if (ndirs < MAX_DIRS) {
        char *copy = strdup(dir);
        if (copy) { dirs[ndirs].dir = copy; dirs[ndirs].state = state; ndirs++; }
    } else if (!dirs_full_logged++) {
        dprintf(2, "[cef-swap] more than %d CEF directories; later ones are checked at each open\n", MAX_DIRS);
    }
    return state;
}

/* Whether key is new and recorded (lock held): a file is logged at its first use only,
 * and not at all once the table is full. */
static int first_time(const char *key)
{
    int i;
    for (i = 0; i < nlogged; i++)
        if (!strcmp(logged[i], key)) return 0;
    if (nlogged >= MAX_LOGGED || !(logged[nlogged] = strdup(key))) return 0;
    nlogged++;
    return 1;
}

char *playport_cef_swap_path(const char *unix_name, unsigned int access, unsigned int disposition,
                             unsigned int options, const char *bundle_dir)
{
    const char *slash, *base, *dir_base, *name, *cef_end;
    char locale[256], *cef_dir = NULL, *payload = NULL, *ours = NULL;
    struct stat st;
    size_t dir_base_len;

    if (!unix_name || !bundle_dir || !(slash = strrchr(unix_name, '/')) || slash == unix_name) return NULL;
    base = slash + 1;
    dir_base = slash;
    while (dir_base > unix_name && dir_base[-1] != '/') dir_base--;
    dir_base_len = (size_t)(slash - dir_base);
    if (!(name = cef_swap_payload_name(dir_base, dir_base_len, base, locale, sizeof(locale)))) return NULL;
    if (!cef_swap_read_only(access, disposition, options)) return NULL;

    /* The directory libcef.dll is in: a locale's is its parent. */
    cef_end = name == locale ? dir_base - 1 : slash;
    if (cef_end <= unix_name) return NULL;
    if (!(cef_dir = strndup(unix_name, (size_t)(cef_end - unix_name)))) return NULL;
    if (asprintf(&payload, "%s/cef/%s", bundle_dir, CEF_SWAP_VERSION) < 0) { payload = NULL; goto done; }
    if (!strncmp(unix_name, payload, strlen(payload)) && unix_name[strlen(payload)] == '/') goto done;

    pthread_mutex_lock(&lock);
    if (!payload_state) {
        char *probe;
        payload_state = -1;
        if (asprintf(&probe, "%s/libcef.dll", payload) >= 0) {
            if (!stat(probe, &st) && S_ISREG(st.st_mode)) payload_state = 1;
            free(probe);
        }
        if (payload_state < 0)
            dprintf(2, "[cef-swap] Playport's CEF %s is not in this build (%s); every client's CEF is left alone\n",
                    CEF_SWAP_VERSION, payload);
    }
    if (payload_state > 0 && dir_decision(cef_dir) == DIR_MATCH) {
        if (asprintf(&ours, "%s/%s", payload, name) < 0) ours = NULL;
        else if (stat(ours, &st) || !S_ISREG(st.st_mode)) {
            if (first_time(unix_name))
                dprintf(2, "[cef-swap] %s/%s: not in Playport's build; the client's file is used\n", cef_dir, name);
            free(ours);
            ours = NULL;
        } else if (first_time(unix_name)) {
            dprintf(2, "[cef-swap] %s/%s: opened from Playport's build\n", cef_dir, name);
        }
    }
    pthread_mutex_unlock(&lock);
done:
    free(cef_dir);
    free(payload);
    return ours;
}
