/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PLAYPORT_GUEST32_H
#define PLAYPORT_GUEST32_H

#include <stddef.h>
#include <stdint.h>

/* Memory experiment (host tests/dev Settings), NOT the game's memory manager.
 * All calls and borrowed
 * pointers require external serialization. No Windows ABI types cross this API.
 * Guests have 4 KiB pages and 64 KiB allocation granularity, even on a 16 KiB
 * host. Permissions must be checked in software for EVERY guest access. */
#define G32_PAGE 4096u
#define G32_GRANULE 65536u
#define G32_READ 1u
#define G32_WRITE 2u
#define G32_EXEC 4u

typedef struct g32_space g32_space;
typedef enum {
    G32_OK, G32_RANGE, G32_ALIGNMENT, G32_CONFLICT, G32_NOT_RESERVED,
    G32_ACCESS, G32_SYSTEM, G32_NO_SPACE
} g32_result;

/* host_granule=0 uses the real host page size. A larger power-of-two multiple
 * simulates coarser host pages in host tests. Backing is non-executable and
 * entirely above 4 GiB; the low 64 KiB and the end of the window stay guarded. */
g32_result g32_create(size_t host_granule, g32_space **out);
void g32_destroy(g32_space *space);
uintptr_t g32_backing_base(const g32_space *space);

g32_result g32_reserve(g32_space *space, uint32_t address, uint64_t size);
/* First-fit reservation within [lower, upper), upper may be 2^32. Bases are
 * rounded UP to 64 KiB; size must be a nonzero multiple of 4 KiB (not rounded).
 * The low 64 KiB remains unavailable even when lower=0. No commit or permission
 * change occurs. Occupied pages, including decommitted reservations, are skipped.
 * NO_SPACE means valid bounds/size but no fit; invalid bounds return RANGE.
 * Failure leaves output and all reservations unchanged. External serialization
 * is required between selection and publication, as for every other VM call.
 * This is native metadata, not a Windows VirtualAlloc/WoW64 implementation. */
g32_result g32_reserve_any(g32_space *space, uint32_t lower, uint64_t upper,
                           uint64_t size, uint32_t *allocation_base);
g32_result g32_commit(g32_space *space, uint32_t address, uint64_t size, unsigned permissions);
g32_result g32_protect(g32_space *space, uint32_t address, uint64_t size, unsigned permissions);
g32_result g32_decommit(g32_space *space, uint32_t address, uint64_t size);
/* Release accepts only the original allocation base; never a subrange. */
g32_result g32_release(g32_space *space, uint32_t allocation_base);

/* Read-only guest metadata query, NOT Windows MEMORY_BASIC_INFORMATION.
 * Accepts any byte address, including the inaccessible low 64 KiB. region_base
 * is address rounded DOWN to a guest page; size scans FORWARD through matching
 * state/permissions/ownership, never across reservations. size is wide so a
 * region can end at 2^32. FREE and BLOCKED have allocation_base=permissions=0;
 * RESERVED reports its allocation base with permissions=0. COMMITTED with zero
 * permissions is distinct from RESERVED. No native pointer/host protection is
 * returned or consulted. Failure leaves output unchanged. Serialized snapshot
 * only: it grants no access or lifetime, and expires at the next VM change.
 * Worst-case scan is the guest page count; no concurrent VM protocol. */
typedef enum {
    G32_REGION_BLOCKED, G32_REGION_FREE, G32_REGION_RESERVED, G32_REGION_COMMITTED
} g32_region_state;
typedef struct {
    uint32_t region_base, allocation_base;
    uint64_t size;
    g32_region_state state;
    unsigned permissions;
} g32_region;
g32_result g32_query(g32_space *space, uint32_t address, g32_region *output);

/* Translation never truncates a native pointer into a guest pointer. A loan is
 * valid only until a mapping changes; callers must not dereference it with
 * permissions/width other than those checked here. Crossing 2^32 faults (not
 * wrapping the access); guest arithmetic wraps BEFORE this function is called.
 * EXEC checks instruction fetch, not permission to execute backing natively. */
g32_result g32_translate(g32_space *space, uint32_t address, uint64_t width,
                         unsigned permissions, void **host);
g32_result g32_reverse(g32_space *space, const void *host, uint64_t width,
                       unsigned permissions, uint32_t *guest);
g32_result g32_read(g32_space *space, uint32_t address, void *destination, size_t size);
g32_result g32_write(g32_space *space, uint32_t address, const void *source, size_t size);
g32_result g32_fetch(g32_space *space, uint32_t address, void *destination, size_t size);

#endif
