/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Simulator-only fixture: no OS allocation/protection is executed. Including
 * the unchanged implementation lets C, not Python, own its private layout.
 * Dead OS functions are discarded at link time; access checks are real g32. */
#include "guest32.c"

unsigned char audit_states[G32_PAGES];
uint32_t audit_owners[G32_PAGES];
g32_space audit_space;

void audit_initialize(uintptr_t base, size_t granule, unsigned left,
                      unsigned right, unsigned poisoned)
{
    audit_space = (g32_space){
        .host_granule = granule, .base = (unsigned char *)base,
        .state = audit_states, .owner = audit_owners, .poisoned = (int)poisoned
    };
    const unsigned indices[] = {16, 17, G32_PAGES - 2, G32_PAGES - 1};
    for (unsigned i = 0; i < 4; ++i) {
        audit_states[indices[i]] = (unsigned char)(i & 1 ? right : left);
        audit_owners[indices[i]] = i < 2 ? 17 : G32_PAGES - 1;
    }
}

/* Freestanding C runtime byte copy, not a replacement for any g32 operation.
 * Full-width validation in the unmodified g32 copy() precedes this function. */
__attribute__((noinline))
void *memmove(void *destination, const void *source, size_t size)
{
    unsigned char *d = destination;
    const unsigned char *s = source;
    if ((uintptr_t)d < (uintptr_t)s) {
        for (size_t i = 0; i < size; ++i) d[i] = s[i];
    } else {
        while (size) { --size; d[size] = s[size]; }
    }
    return destination;
}
