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
    exercise(0);
    exercise(16384);
    exercise(65536);
    puts("guest32: memory contract only; no guest instructions executed");
    return 0;
}
