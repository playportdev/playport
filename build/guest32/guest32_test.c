/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "guest32.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define OK(call) assert((call) == G32_OK)
#define IS(call, error) assert((call) == (error))

static uint32_t random_word(uint32_t *state)
{
    *state = *state * UINT32_C(1664525) + UINT32_C(1013904223);
    return *state;
}

static void allocation(size_t granule)
{
    const uint64_t limit = UINT64_C(1) << 32;
    g32_space *s;
    OK(g32_create(granule, &s));
    uint32_t base = 123;
    IS(g32_reserve_any(NULL, 0, limit, G32_PAGE, &base), G32_SYSTEM);
    IS(g32_reserve_any(s, 0, limit, G32_PAGE, NULL), G32_RANGE);
    IS(g32_reserve_any(s, 0, limit + 1, G32_PAGE, &base), G32_RANGE);
    IS(g32_reserve_any(s, 0, 0, G32_PAGE, &base), G32_RANGE);
    IS(g32_reserve_any(s, 0x20000, 0x10000, G32_PAGE, &base), G32_RANGE);
    IS(g32_reserve_any(s, 0, limit, 0, &base), G32_RANGE);
    IS(g32_reserve_any(s, 0, limit, UINT64_MAX, &base), G32_RANGE);
    IS(g32_reserve_any(s, 0, limit, limit, &base), G32_RANGE);
    IS(g32_reserve_any(s, 0, limit, 1, &base), G32_ALIGNMENT);
    IS(g32_reserve_any(s, 0, G32_GRANULE, G32_PAGE, &base), G32_NO_SPACE);
    assert(base == 123);
    OK(g32_reserve_any(s, 0, limit, G32_PAGE, &base));
    assert(base == G32_GRANULE);
    void *host = NULL;
    IS(g32_translate(s, base, 1, G32_READ, &host), G32_ACCESS);
    IS(g32_reserve(s, base, G32_PAGE), G32_CONFLICT);
    OK(g32_release(s, base));

    /* A later occupied page invalidates a candidate, even if its base is free.
     * Adjacent reservation identity and live bytes must remain unchanged. */
    OK(g32_reserve(s, 0x20000, G32_PAGE));
    OK(g32_commit(s, 0x20000, G32_PAGE, G32_READ | G32_WRITE));
    unsigned char byte = 0xab, output = 0;
    OK(g32_write(s, 0x20000, &byte, 1));
    OK(g32_reserve_any(s, 0x10001, 0x80000, 0x11000, &base));
    assert(base == 0x30000);
    OK(g32_release(s, base));
    OK(g32_reserve_any(s, 0x10000, 0x80000, 0x11000, &base));
    assert(base == 0x30000);
    OK(g32_decommit(s, base, 0x11000));
    IS(g32_reserve_any(s, base, base + 0x11000, G32_PAGE, &base), G32_NO_SPACE);
    assert(base == 0x30000);
    OK(g32_read(s, 0x20000, &output, 1));
    assert(output == byte);
    IS(g32_commit(s, 0x20000, 0x20000, G32_READ), G32_NOT_RESERVED);
    OK(g32_release(s, 0x30000));
    OK(g32_release(s, 0x20000));

    /* Nonaligned exclusive bounds; highest valid base; no 32-bit wrap. */
    OK(g32_reserve_any(s, 0x10001, 0x21001, G32_PAGE, &base));
    assert(base == 0x20000);
    OK(g32_release(s, base));
    IS(g32_reserve_any(s, 0x10001, 0x20fff, G32_PAGE, &base), G32_NO_SPACE);
    assert(base == 0x20000);
    OK(g32_reserve_any(s, 0xffff0000u, limit, G32_GRANULE, &base));
    assert(base == 0xffff0000u);
    IS(g32_reserve_any(s, 0xffff0001u, limit, G32_PAGE, &base), G32_NO_SPACE);
    IS(g32_reserve_any(s, UINT32_MAX, limit, G32_PAGE, &base), G32_NO_SPACE);
    assert(base == 0xffff0000u);
    OK(g32_release(s, base));

    /* Installed launcher layout: automatic placement skips a preferred-base
     * collision and aligns the next base, without rounding its image extent. */
    OK(g32_reserve(s, 0x400000, 0x5c000));
    OK(g32_reserve_any(s, 0x400000, 0x800000, 0x5c000, &base));
    assert(base == 0x460000);
    IS(g32_reserve(s, 0x4b0000, 0xd000), G32_CONFLICT);
    OK(g32_release(s, base));
    OK(g32_release(s, 0x400000));
    OK(g32_reserve_any(s, 0x400000, 0x800000, 0x5c000, &base));
    assert(base == 0x400000);
    OK(g32_release(s, base));

    /* Independent brute-force page oracle: mixed allocation/release, partial
     * granules, fragmentation and tight byte bounds. No native commits. */
    enum { N = 256 };
    uint32_t owners[N] = {0}, rng = 0x620;
    unsigned allocated = 0, failed = 0, released = 0;
    const uint32_t origin = 0x100000;
    for (unsigned step = 0; step < 2048; ++step) {
        if (random_word(&rng) & 0x10000) {
            unsigned page = random_word(&rng) % N;
            uint32_t owner = owners[page];
            if (owner) {
                OK(g32_release(s, origin + (owner - 1) * G32_PAGE));
                ++released;
                for (unsigned p = 0; p < N; ++p)
                    if (owners[p] == owner) owners[p] = 0;
            }
        } else {
            uint32_t low = origin + random_word(&rng) % (N * G32_PAGE);
            uint64_t high = (uint64_t)low + 1 +
                random_word(&rng) % (origin + N * G32_PAGE - low);
            uint64_t size = (1 + random_word(&rng) % 48) * G32_PAGE;
            uint32_t expected = 0;
            for (unsigned p = 0; p < N; p += G32_GRANULE / G32_PAGE) {
                uint32_t candidate = origin + p * G32_PAGE;
                if (candidate < low || (uint64_t)candidate + size > high) continue;
                int free = 1;
                for (unsigned q = p; q < p + size / G32_PAGE; ++q)
                    if (owners[q]) free = 0;
                if (free) { expected = candidate; break; }
            }
            base = 123;
            if (!expected) {
                ++failed;
                IS(g32_reserve_any(s, low, high, size, &base), G32_NO_SPACE);
                assert(base == 123);
            } else {
                OK(g32_reserve_any(s, low, high, size, &base));
                assert(base == expected);
                ++allocated;
                unsigned first = (base - origin) / G32_PAGE;
                for (unsigned p = first; p < first + size / G32_PAGE; ++p)
                    owners[p] = first + 1;
                IS(g32_reserve(s, base, size), G32_CONFLICT);
            }
        }
    }
    assert(allocated > 100 && failed > 100 && released > 100);
    /* Reservation identity agrees with the oracle after failed selections. */
    for (unsigned p = 0; p < N; ++p)
        if (owners[p] == p + 1) OK(g32_release(s, origin + p * G32_PAGE));
    OK(g32_reserve_any(s, 0, limit, limit - G32_GRANULE, &base));
    assert(base == G32_GRANULE);
    IS(g32_reserve_any(s, 0, limit, G32_PAGE, &base), G32_NO_SPACE);
    assert(base == G32_GRANULE);
    g32_destroy(s); /* Exhaustion reserves metadata only, not 4 GiB of RAM. */
    printf("guest32: allocation granule=%zu ok\n", granule);
}

static void region_is(g32_space *s, uint32_t address, uint32_t base,
                      uint64_t size, uint32_t allocation_base,
                      g32_region_state state, unsigned permissions)
{
    g32_region region;
    OK(g32_query(s, address, &region));
    assert(region.region_base == base && region.size == size);
    assert(region.allocation_base == allocation_base && region.state == state);
    assert(region.permissions == permissions);
}

static void queries(size_t granule)
{
    const uint64_t limit = UINT64_C(1) << 32;
    g32_space *s, *other;
    OK(g32_create(granule, &s));
    OK(g32_create(granule, &other));
    g32_region output, saved;
    memset(&output, 0xa5, sizeof(output));
    memcpy(&saved, &output, sizeof(saved));
    IS(g32_query(NULL, 0, &output), G32_SYSTEM);
    assert(!memcmp(&output, &saved, sizeof(output)));
    IS(g32_query(s, 0, NULL), G32_RANGE);
    region_is(s, 0, 0, G32_GRANULE, 0, G32_REGION_BLOCKED, 0);
    region_is(s, 0xffff, 0xf000, G32_PAGE, 0, G32_REGION_BLOCKED, 0);
    region_is(s, G32_GRANULE, G32_GRANULE, limit - G32_GRANULE,
              0, G32_REGION_FREE, 0);
    region_is(s, UINT32_MAX, 0xfffff000u, G32_PAGE, 0, G32_REGION_FREE, 0);

    const uint32_t base = 0x400000;
    OK(g32_reserve(s, base, G32_GRANULE));
    OK(g32_reserve(s, base + G32_GRANULE, G32_GRANULE));
    region_is(s, base - 1, base - G32_PAGE, G32_PAGE, 0, G32_REGION_FREE, 0);
    region_is(s, base + 1, base, G32_GRANULE, base, G32_REGION_RESERVED, 0);
    region_is(s, base + G32_GRANULE - 1, base + G32_GRANULE - G32_PAGE,
              G32_PAGE, base, G32_REGION_RESERVED, 0);
    region_is(s, base + G32_GRANULE, base + G32_GRANULE, G32_GRANULE,
              base + G32_GRANULE, G32_REGION_RESERVED, 0);
    OK(g32_commit(s, base, G32_GRANULE, G32_READ | G32_WRITE));
    OK(g32_commit(s, base + G32_GRANULE, G32_GRANULE, G32_READ | G32_WRITE));
    /* Identical access permissions still must not hide ownership boundaries. */
    region_is(s, base + 7, base, G32_GRANULE, base,
              G32_REGION_COMMITTED, G32_READ | G32_WRITE);
    unsigned char byte = 0x62, readback = 0;
    OK(g32_write(s, base, &byte, 1));
    for (unsigned permission = 0; permission < 8; ++permission) {
        OK(g32_protect(s, base + G32_PAGE, G32_PAGE, permission));
        region_is(s, base + G32_PAGE + 19, base + G32_PAGE,
                  permission == (G32_READ | G32_WRITE) ? G32_GRANULE - G32_PAGE : G32_PAGE,
                  base, G32_REGION_COMMITTED, permission);
    }
    OK(g32_protect(s, base + G32_PAGE, G32_PAGE, 0));
    region_is(s, base, base, G32_PAGE, base, G32_REGION_COMMITTED, G32_READ | G32_WRITE);
    void *host = NULL;
    IS(g32_translate(s, base + G32_PAGE, 1, G32_READ, &host), G32_ACCESS);
    OK(g32_decommit(s, base + 2 * G32_PAGE, G32_PAGE));
    region_is(s, base + G32_PAGE, base + G32_PAGE, G32_PAGE, base, G32_REGION_COMMITTED, 0);
    region_is(s, base + 2 * G32_PAGE, base + 2 * G32_PAGE, G32_PAGE, base, G32_REGION_RESERVED, 0);
    region_is(s, base + 3 * G32_PAGE + 1, base + 3 * G32_PAGE,
              G32_GRANULE - 3 * G32_PAGE, base, G32_REGION_COMMITTED, G32_READ | G32_WRITE);
    OK(g32_read(s, base, &readback, 1));
    assert(readback == byte);
    region_is(other, base, base, limit - base, 0, G32_REGION_FREE, 0);
    OK(g32_release(s, base));
    region_is(s, base, base, G32_GRANULE, 0, G32_REGION_FREE, 0);
    region_is(s, base + G32_GRANULE, base + G32_GRANULE, G32_GRANULE,
              base + G32_GRANULE, G32_REGION_COMMITTED, G32_READ | G32_WRITE);
    OK(g32_release(s, base + G32_GRANULE));
    region_is(s, base, base, limit - base, 0, G32_REGION_FREE, 0);

    OK(g32_reserve(s, 0xffff0000u, G32_GRANULE));
    OK(g32_commit(s, 0xfffff000u, G32_PAGE, G32_EXEC));
    region_is(s, 0xffff0001u, 0xffff0000u, G32_GRANULE - G32_PAGE,
              0xffff0000u, G32_REGION_RESERVED, 0);
    region_is(s, UINT32_MAX, 0xfffff000u, G32_PAGE, 0xffff0000u,
              G32_REGION_COMMITTED, G32_EXEC);
    OK(g32_release(s, 0xffff0000u));
    /* Full metadata-only reservation: no native backing access is needed. */
    OK(g32_reserve(s, G32_GRANULE, limit - G32_GRANULE));
    region_is(s, G32_GRANULE, G32_GRANULE, limit - G32_GRANULE,
              G32_GRANULE, G32_REGION_RESERVED, 0);
    OK(g32_release(s, G32_GRANULE));
    g32_destroy(other);
    g32_destroy(s);
    printf("guest32: queries granule=%zu ok\n", granule);
}

static void query_oracle(size_t granule)
{
    enum { N = 256, SLOT = G32_GRANULE / G32_PAGE };
    const uint32_t origin = 0x100000;
    g32_space *s;
    OK(g32_create(granule, &s));
    /* Bound free runs without borrowing implementation metadata. */
    OK(g32_reserve(s, origin + N * G32_PAGE, G32_PAGE));
    uint32_t owners[N] = {0}, rng = 0x620;
    int permissions[N]; /* -1 is reserved/uncommitted; >=0 is committed. */
    for (unsigned p = 0; p < N; ++p) permissions[p] = -1;
    unsigned operations[5] = {0}, states[3] = {0};
    for (unsigned step = 0; step < 1024; ++step) {
        unsigned slot = (random_word(&rng) >> 16) % (N / SLOT);
        unsigned first = slot * SLOT, op = (random_word(&rng) >> 16) % 5;
        uint32_t address = origin + first * G32_PAGE;
        if (op == 0 && !owners[first]) {
            OK(g32_reserve(s, address, G32_GRANULE));
            for (unsigned p = first; p < first + SLOT; ++p) owners[p] = address;
            ++operations[op];
        } else if (op == 1 && owners[first]) {
            OK(g32_release(s, address));
            for (unsigned p = first; p < first + SLOT; ++p) {
                owners[p] = 0;
                permissions[p] = -1;
            }
            ++operations[op];
        } else if (op >= 2 && owners[first]) {
            unsigned p = first + (random_word(&rng) >> 16) % SLOT;
            unsigned count = 1 + (random_word(&rng) >> 16) % (first + SLOT - p);
            unsigned perm = (random_word(&rng) >> 16) % 8;
            int committed = 1;
            for (unsigned q = p; q < p + count; ++q)
                if (permissions[q] < 0) committed = 0;
            address = origin + p * G32_PAGE;
            if (op == 2) OK(g32_commit(s, address, count * G32_PAGE, perm));
            if (op == 3) OK(g32_decommit(s, address, count * G32_PAGE));
            if (op == 4) {
                IS(g32_protect(s, address, count * G32_PAGE, perm),
                   committed ? G32_OK : G32_ACCESS);
            }
            if (op != 4 || committed)
                for (unsigned q = p; q < p + count; ++q)
                    permissions[q] = op == 3 ? -1 : (int)perm;
            ++operations[op];
        }
        for (unsigned p = 0; p < N; ++p) {
            unsigned end = p + 1;
            while (end < N && owners[end] == owners[p] && permissions[end] == permissions[p]) ++end;
            g32_region_state state = !owners[p] ? G32_REGION_FREE :
                permissions[p] < 0 ? G32_REGION_RESERVED : G32_REGION_COMMITTED;
            ++states[state - G32_REGION_FREE];
            region_is(s, origin + p * G32_PAGE + (step * 17 + p * 31) % G32_PAGE,
                      origin + p * G32_PAGE, (end - p) * G32_PAGE,
                      owners[p], state, permissions[p] < 0 ? 0 : (unsigned)permissions[p]);
        }
    }
    for (unsigned op = 0; op < 5; ++op) assert(operations[op] > 10);
    for (unsigned state = 0; state < 3; ++state) assert(states[state] > 100);
    g32_destroy(s);
    printf("guest32: query oracle granule=%zu ok\n", granule);
}

static void exercise(size_t granule)
{
    g32_space *a, *b;
    OK(g32_create(granule, &a));
    OK(g32_create(granule, &b));
    assert(g32_backing_base(a) >= (UINT64_C(1) << 32));
    assert(g32_backing_base(a) != g32_backing_base(b));
    assert(g32_backing_base(a) % (granule ? granule : G32_PAGE) == 0);
    void *host = NULL;
    uint32_t guest = 123;
    unsigned char byte = 0xcc, output = 0xaa;
    IS(g32_reserve(a, 0, G32_PAGE), G32_RANGE);
    IS(g32_reserve(a, G32_GRANULE + 1, G32_PAGE), G32_ALIGNMENT);
    IS(g32_reserve(a, G32_GRANULE, 1), G32_ALIGNMENT);
    IS(g32_reserve(a, G32_GRANULE, 0), G32_RANGE);
    IS(g32_reserve(a, G32_GRANULE, UINT64_MAX), G32_RANGE);
    IS(g32_commit(a, G32_GRANULE, G32_PAGE, G32_READ), G32_NOT_RESERVED);
    IS(g32_translate(a, 0, 1, G32_READ, &host), G32_RANGE);
    assert(host == NULL);
    IS(g32_translate(a, G32_GRANULE, 0, G32_READ, &host), G32_RANGE);
    IS(g32_translate(a, G32_GRANULE, 1, 0, &host), G32_ACCESS);
    IS(g32_translate(a, G32_GRANULE, 1, 8, &host), G32_ACCESS);
    IS(g32_reverse(a, NULL, 1, G32_READ, &guest), G32_RANGE);
    assert(guest == 123);

    /* The installed Portal 2 launcher's preferred image address and SizeOfImage.
     * This tests memory placement only, NOT PE loading or game execution. */
    const uint32_t image = 0x400000;
    const uint64_t image_size = 0x5c000;
    OK(g32_reserve(a, image, image_size));
    IS(g32_reserve(a, image, G32_PAGE), G32_CONFLICT);
    IS(g32_reserve(a, image + 0x50000, 0x20000), G32_CONFLICT);
    IS(g32_translate(a, image, 1, G32_READ, &host), G32_ACCESS);
    IS(g32_protect(a, image, G32_PAGE, G32_READ), G32_ACCESS);
    OK(g32_commit(a, image, image_size, G32_READ | G32_WRITE | G32_EXEC));
    OK(g32_translate(a, image, image_size, G32_READ, &host));
    assert((uintptr_t)host == g32_backing_base(a) + image);
    assert((uintptr_t)host > UINT32_MAX);
    assert(((unsigned char *)host)[0] == 0);
    OK(g32_reverse(a, host, image_size, G32_READ, &guest));
    assert(guest == image);
    IS(g32_reverse(b, host, 1, G32_READ, &guest), G32_RANGE);
    OK(g32_write(a, image, &byte, 1));
    OK(g32_read(a, image, &output, 1));
    assert(output == byte);
    OK(g32_fetch(a, image, &output, 1));
    assert(output == byte);
    IS(g32_read(b, image, &output, 1), G32_ACCESS);
    IS(g32_translate(a, image + (uint32_t)image_size - 1, 2, G32_READ, &host), G32_ACCESS);

    /* A protected/uncommitted 4 KiB guest page shares native backing with a
     * writable neighbor on a 16 KiB host. Software checks must still reject it. */
    OK(g32_protect(a, image + G32_PAGE, G32_PAGE, 0));
    IS(g32_read(a, image + G32_PAGE, &output, 1), G32_ACCESS);
    IS(g32_fetch(a, image + G32_PAGE, &output, 1), G32_ACCESS);
    OK(g32_write(a, image, &byte, 1));
    unsigned char pair[2] = {0x77, 0x88};
    IS(g32_write(a, image + G32_PAGE - 1, pair, 2), G32_ACCESS);
    OK(g32_read(a, image + G32_PAGE - 1, &output, 1));
    assert(output == 0); /* No partial write before detecting the second page. */
    IS(g32_read(a, image + G32_PAGE - 1, pair, 2), G32_ACCESS);
    assert(pair[0] == 0x77 && pair[1] == 0x88);
    OK(g32_protect(a, image + 2 * G32_PAGE, G32_PAGE, G32_READ));
    IS(g32_write(a, image + 2 * G32_PAGE, &byte, 1), G32_ACCESS);
    IS(g32_fetch(a, image + 2 * G32_PAGE, &output, 1), G32_ACCESS);
    OK(g32_protect(a, image + 3 * G32_PAGE, G32_PAGE, G32_EXEC));
    IS(g32_read(a, image + 3 * G32_PAGE, &output, 1), G32_ACCESS);
    OK(g32_fetch(a, image + 3 * G32_PAGE, &output, 1));
    OK(g32_commit(a, image, G32_PAGE, G32_READ | G32_WRITE));
    OK(g32_read(a, image, &output, 1));
    assert(output == byte); /* Recommit keeps existing data. */
    OK(g32_decommit(a, image + G32_PAGE, G32_PAGE));
    IS(g32_translate(a, image + G32_PAGE, 1, G32_READ, &host), G32_ACCESS);
    OK(g32_read(a, image, &output, 1));
    assert(output == byte); /* Decommit does not zero the live native neighbor. */
    OK(g32_commit(a, image + G32_PAGE, G32_PAGE, G32_READ | G32_WRITE));
    OK(g32_read(a, image + G32_PAGE, &output, 1));
    assert(output == 0);

    /* VM operations cannot span distinct reservations, even if adjacent. */
    OK(g32_reserve(a, 0x800000, 0x10000));
    OK(g32_reserve(a, 0x810000, 0x10000));
    IS(g32_commit(a, 0x800000, 0x20000, G32_READ), G32_NOT_RESERVED);
    IS(g32_decommit(a, 0x800000, 0x20000), G32_NOT_RESERVED);
    OK(g32_commit(a, 0x800000, 0x10000, G32_READ));
    OK(g32_commit(a, 0x810000, 0x10000, G32_READ));
    OK(g32_translate(a, 0x80ffff, 2, G32_READ, &host)); /* Access may cross them. */
    IS(g32_release(a, 0x801000), G32_NOT_RESERVED);
    OK(g32_release(a, 0x800000));
    IS(g32_read(a, 0x800000, &output, 1), G32_ACCESS);
    OK(g32_read(a, 0x810000, &output, 1));
    OK(g32_release(a, 0x810000));

    /* Upper edge: a last-page access is valid; a straddling access faults.
     * 32-bit arithmetic wrapping before an access cannot expose page zero. */
    OK(g32_reserve(a, 0xffff0000u, 0x10000));
    OK(g32_commit(a, 0xfffff000u, G32_PAGE, G32_READ | G32_WRITE));
    OK(g32_write(a, UINT32_MAX, &byte, 1));
    OK(g32_read(a, UINT32_MAX, &output, 1));
    assert(output == byte);
    IS(g32_write(a, UINT32_MAX, pair, 2), G32_RANGE);
    IS(g32_translate(a, UINT32_MAX, UINT64_MAX, G32_READ, &host), G32_RANGE);
    uint32_t wrapped = UINT32_MAX;
    wrapped += 1;
    IS(g32_translate(a, wrapped, 1, G32_READ, &host), G32_RANGE);
    IS(g32_reverse(a, (void *)(g32_backing_base(a) + (UINT64_C(1) << 32)),
                   1, G32_READ, &guest), G32_RANGE);
    OK(g32_release(a, 0xffff0000u));

    /* Zero after decommit and after release/reallocation; no native alias leak. */
    OK(g32_decommit(a, image, image_size));
    OK(g32_decommit(a, image, image_size));
    OK(g32_commit(a, image, G32_PAGE, G32_READ | G32_WRITE));
    OK(g32_read(a, image, &output, 1));
    assert(output == 0);
    OK(g32_write(a, image, &byte, 1));
    OK(g32_release(a, image));
    IS(g32_release(a, image), G32_NOT_RESERVED);
    OK(g32_reserve(a, image, image_size));
    OK(g32_commit(a, image, image_size, G32_READ));
    OK(g32_read(a, image, &output, 1));
    assert(output == 0);
    OK(g32_release(a, image));
    g32_destroy(a);
    g32_destroy(b);
    printf("guest32: granule=%zu ok\n", granule);
}

int main(void)
{
    g32_space *s = NULL;
    IS(g32_create(12345, &s), G32_ALIGNMENT);
    assert(s == NULL);
    g32_destroy(NULL);
    allocation(0);
    allocation(16384);
    allocation(65536);
    queries(0);
    queries(16384);
    queries(65536);
    query_oracle(0);
    query_oracle(16384);
    query_oracle(65536);
    exercise(0);
    exercise(16384);
    exercise(65536);
    puts("guest32: memory contract only; no guest instructions executed");
    return 0;
}
