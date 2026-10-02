/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _DEFAULT_SOURCE
#include "guest32.h"
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define G32_LIMIT (UINT64_C(1) << 32)
#define G32_PAGES (G32_LIMIT / G32_PAGE)
#define COMMITTED 8u
#define PERMISSIONS (G32_READ | G32_WRITE | G32_EXEC)

struct g32_space {
    void *mapping;
    size_t mapping_size, host_granule;
    unsigned char *base, *state;
    uint32_t *owner;
    int poisoned;
};

static g32_result bounds(g32_space *s, uint32_t address, uint64_t size)
{
    if (!s || s->poisoned) return G32_SYSTEM;
    if (!size || address < G32_GRANULE || size > G32_LIMIT - address) return G32_RANGE;
    return G32_OK;
}

static g32_result pages(g32_space *s, uint32_t address, uint64_t size)
{
    g32_result r = bounds(s, address, size);
    if (r != G32_OK) return r;
    if (address % G32_PAGE || size % G32_PAGE) return G32_ALIGNMENT;
    return G32_OK;
}

static g32_result reservation(g32_space *s, uint32_t address, uint64_t size)
{
    g32_result r = pages(s, address, size);
    if (r != G32_OK) return r;
    uint64_t first = address / G32_PAGE, end = first + size / G32_PAGE;
    uint32_t owner = s->owner[first];
    if (!owner) return G32_NOT_RESERVED;
    for (uint64_t p = first; p < end; ++p)
        if (s->owner[p] != owner) return G32_NOT_RESERVED;
    return G32_OK;
}

/* A system failure poisons the space: partial native protection changes must
 * never be mistaken for a successful VM transaction. Destroy it, don't retry.
 * Guest protection changes themselves need no host mprotect: 4 KiB permissions
 * cannot be enforced by a 16 KiB host page. Backing is RW, never executable. */
static g32_result native_protect(g32_space *s, uint64_t offset, uint64_t size, int prot)
{
    if (mprotect(s->base + offset, (size_t)size, prot)) {
        s->poisoned = 1;
        return G32_SYSTEM;
    }
    return G32_OK;
}

g32_result g32_create(size_t granule, g32_space **out)
{
    if (!out || sizeof(uintptr_t) < 8) return G32_RANGE;
    *out = NULL;
    long actual = sysconf(_SC_PAGESIZE);
    if (actual <= 0) return G32_SYSTEM;
    if (!granule) granule = (size_t)actual;
    if (granule < G32_PAGE || granule > G32_GRANULE ||
        (granule & (granule - 1)) || granule % (size_t)actual) return G32_ALIGNMENT;
    g32_space *s = calloc(1, sizeof(*s));
    if (!s) return G32_SYSTEM;
    s->host_granule = granule;
    s->mapping_size = (size_t)G32_LIMIT + 3 * granule;
    /* No MAP_FIXED: never replace another mapping. Reject a low result. */
    s->mapping = mmap(NULL, s->mapping_size,
                      PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (s->mapping == MAP_FAILED) { free(s); return G32_SYSTEM; }
    uintptr_t base = ((uintptr_t)s->mapping + 2 * granule - 1) & ~(uintptr_t)(granule - 1);
    s->base = (unsigned char *)base;
    s->state = calloc((size_t)G32_PAGES, sizeof(*s->state));
    s->owner = calloc((size_t)G32_PAGES, sizeof(*s->owner));
    if (base < G32_LIMIT || !s->state || !s->owner) {
        g32_destroy(s);
        return G32_SYSTEM;
    }
    *out = s;
    return G32_OK;
}

void g32_destroy(g32_space *s)
{
    if (!s) return;
    munmap(s->mapping, s->mapping_size);
    free(s->state);
    free(s->owner);
    free(s);
}

uintptr_t g32_backing_base(const g32_space *s) { return s ? (uintptr_t)s->base : 0; }

g32_result g32_reserve(g32_space *s, uint32_t address, uint64_t size)
{
    g32_result r = pages(s, address, size);
    if (r != G32_OK) return r;
    if (address % G32_GRANULE) return G32_ALIGNMENT;
    uint64_t first = address / G32_PAGE, end = first + size / G32_PAGE;
    for (uint64_t p = first; p < end; ++p)
        if (s->owner[p]) return G32_CONFLICT;
    for (uint64_t p = first; p < end; ++p) s->owner[p] = (uint32_t)first + 1;
    return G32_OK;
}

g32_result g32_reserve_any(g32_space *s, uint32_t lower, uint64_t upper,
                           uint64_t size, uint32_t *allocation_base)
{
    if (!s || s->poisoned) return G32_SYSTEM;
    if (!allocation_base || !size || upper > G32_LIMIT || upper <= lower ||
        size > G32_LIMIT - G32_GRANULE) return G32_RANGE;
    if (size % G32_PAGE) return G32_ALIGNMENT;
    uint64_t candidate = ((uint64_t)lower + G32_GRANULE - 1) &
                         ~(uint64_t)(G32_GRANULE - 1);
    if (candidate < G32_GRANULE) candidate = G32_GRANULE;
    while (candidate < upper && size <= upper - candidate) {
        uint64_t first = candidate / G32_PAGE, end = first + size / G32_PAGE;
        uint64_t p = first;
        while (p < end && !s->owner[p]) ++p;
        if (p == end) {
            /* Selection and reservation are one externally serialized call.
             * No native VM operation (and thus no partial system failure). */
            for (p = first; p < end; ++p) s->owner[p] = (uint32_t)first + 1;
            *allocation_base = (uint32_t)candidate;
            return G32_OK;
        }
        /* Every base up to this occupied page would also overlap it. Jump
         * beyond it, then align in wide arithmetic (never wrap at 2^32). */
        candidate = ((p + 1) * G32_PAGE + G32_GRANULE - 1) &
                    ~(uint64_t)(G32_GRANULE - 1);
    }
    return G32_NO_SPACE;
}

g32_result g32_commit(g32_space *s, uint32_t address, uint64_t size, unsigned permissions)
{
    if (permissions & ~PERMISSIONS) return G32_ACCESS;
    g32_result r = reservation(s, address, size);
    if (r != G32_OK) return r;
    uint64_t begin = address & ~(uint64_t)(s->host_granule - 1);
    uint64_t end = ((uint64_t)address + size + s->host_granule - 1) & ~(uint64_t)(s->host_granule - 1);
    r = native_protect(s, begin, end - begin, PROT_READ | PROT_WRITE);
    if (r != G32_OK) return r;
    for (uint64_t p = address / G32_PAGE; p < ((uint64_t)address + size) / G32_PAGE; ++p) {
        if (!(s->state[p] & COMMITTED)) memset(s->base + p * G32_PAGE, 0, G32_PAGE);
        s->state[p] = COMMITTED | permissions;
    }
    return G32_OK;
}

g32_result g32_protect(g32_space *s, uint32_t address, uint64_t size, unsigned permissions)
{
    if (permissions & ~PERMISSIONS) return G32_ACCESS;
    g32_result r = reservation(s, address, size);
    if (r != G32_OK) return r;
    uint64_t first = address / G32_PAGE, end = first + size / G32_PAGE;
    for (uint64_t p = first; p < end; ++p)
        if (!(s->state[p] & COMMITTED)) return G32_ACCESS;
    for (uint64_t p = first; p < end; ++p) s->state[p] = COMMITTED | permissions;
    return G32_OK;
}

static g32_result discard(g32_space *s, uint32_t address, uint64_t size, int release)
{
    uint64_t first = address / G32_PAGE, end = first + size / G32_PAGE;
    for (uint64_t p = first; p < end; ++p) {
        if (s->state[p] & COMMITTED) memset(s->base + p * G32_PAGE, 0, G32_PAGE);
        s->state[p] = 0;
        if (release) s->owner[p] = 0;
    }
    uint64_t begin = address & ~(uint64_t)(s->host_granule - 1);
    uint64_t limit = ((uint64_t)address + size + s->host_granule - 1) & ~(uint64_t)(s->host_granule - 1);
    for (uint64_t offset = begin; offset < limit; offset += s->host_granule) {
        int live = 0;
        for (uint64_t p = offset / G32_PAGE; p < (offset + s->host_granule) / G32_PAGE; ++p)
            live |= s->state[p] & COMMITTED;
        if (!live) {
            g32_result r = native_protect(s, offset, s->host_granule, PROT_NONE);
            if (r != G32_OK) return r;
            /* Advisory physical reclamation only after the whole host page is
             * unused. Its guest bytes were already zeroed, on every platform. */
            (void)madvise(s->base + offset, s->host_granule, MADV_DONTNEED);
        }
    }
    return G32_OK;
}

g32_result g32_decommit(g32_space *s, uint32_t address, uint64_t size)
{
    g32_result r = reservation(s, address, size);
    return r == G32_OK ? discard(s, address, size, 0) : r;
}

g32_result g32_release(g32_space *s, uint32_t address)
{
    g32_result r = pages(s, address, G32_PAGE);
    if (r != G32_OK) return r;
    uint64_t first = address / G32_PAGE, end = first;
    if (s->owner[first] != first + 1) return G32_NOT_RESERVED;
    while (end < G32_PAGES && s->owner[end] == first + 1) ++end;
    return discard(s, address, (end - first) * G32_PAGE, 1);
}

g32_result g32_query(g32_space *s, uint32_t address, g32_region *output)
{
    if (!s || s->poisoned) return G32_SYSTEM;
    if (!output) return G32_RANGE;
    uint64_t first = address / G32_PAGE, end = first + 1;
    g32_region region = {0};
    region.region_base = (uint32_t)(first * G32_PAGE);
    if (address < G32_GRANULE) {
        region.state = G32_REGION_BLOCKED;
        end = G32_GRANULE / G32_PAGE;
    } else {
        uint32_t owner = s->owner[first];
        unsigned state = s->state[first];
        region.state = !owner ? G32_REGION_FREE :
            (state & COMMITTED) ? G32_REGION_COMMITTED : G32_REGION_RESERVED;
        if (owner) region.allocation_base = (owner - 1) * G32_PAGE;
        region.permissions = state & PERMISSIONS;
        while (end < G32_PAGES && s->owner[end] == owner && s->state[end] == state)
            ++end;
    }
    region.size = (end - first) * G32_PAGE;
    *output = region;
    return G32_OK;
}

g32_result g32_translate(g32_space *s, uint32_t address, uint64_t width,
                         unsigned permissions, void **host)
{
    if (!host || !permissions || (permissions & ~PERMISSIONS)) return G32_ACCESS;
    g32_result r = bounds(s, address, width);
    if (r != G32_OK) return r;
    uint64_t end = ((uint64_t)address + width - 1) / G32_PAGE;
    for (uint64_t p = address / G32_PAGE; p <= end; ++p)
        if ((s->state[p] & (COMMITTED | permissions)) != (COMMITTED | permissions)) return G32_ACCESS;
    *host = s->base + address;
    return G32_OK;
}

g32_result g32_reverse(g32_space *s, const void *host, uint64_t width,
                       unsigned permissions, uint32_t *guest)
{
    if (!s || s->poisoned) return G32_SYSTEM;
    uintptr_t value = (uintptr_t)host, base = (uintptr_t)s->base;
    if (!guest || value < base || value - base >= G32_LIMIT) return G32_RANGE;
    uint32_t address = (uint32_t)(value - base);
    void *checked;
    g32_result r = g32_translate(s, address, width, permissions, &checked);
    if (r == G32_OK) *guest = address;
    return r;
}

static g32_result copy(g32_space *s, uint32_t address, void *buffer, size_t size, unsigned permissions)
{
    if (!buffer) return G32_RANGE;
    void *host;
    g32_result r = g32_translate(s, address, size, permissions, &host);
    if (r != G32_OK) return r;
    if (permissions == G32_WRITE) memmove(host, buffer, size);
    else memmove(buffer, host, size);
    return G32_OK;
}

g32_result g32_read(g32_space *s, uint32_t address, void *destination, size_t size)
{ return copy(s, address, destination, size, G32_READ); }
g32_result g32_write(g32_space *s, uint32_t address, const void *source, size_t size)
{ return copy(s, address, (void *)source, size, G32_WRITE); }
g32_result g32_fetch(g32_space *s, uint32_t address, void *destination, size_t size)
{ return copy(s, address, destination, size, G32_EXEC); }
