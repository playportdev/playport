/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "scalar_access.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define BASE UINT32_C(0x200000)
#define SOURCE UINT32_C(0x89abcdef)
static unsigned calls;

static void same_region(const g32_region *a, const g32_region *b)
{
    assert(a->region_base == b->region_base && a->allocation_base == b->allocation_base);
    assert(a->size == b->size && a->state == b->state && a->permissions == b->permissions);
}

static void expect(g32_space *space, uint64_t address, unsigned operation,
                   g32_result status, uint32_t value)
{
    uint64_t result = g32_scalar_access(space, address, operation, SOURCE);
    assert(g32_scalar_status(result) == status && g32_scalar_value(result) == value);
    assert(result == ((uint64_t)status << 32 | value));
    ++calls;
}

static void permissions(g32_space *space)
{
    unsigned char before[3 * G32_PAGE], after[sizeof(before)];
    for (size_t i = 0; i < sizeof(before); ++i) before[i] = (unsigned char)(i * 73 + 19);
    assert(g32_write(space, BASE, before, sizeof(before)) == G32_OK);
    expect(space, BASE, 1, G32_OK, 0x89abcd13);
    expect(space, BASE, 2, G32_OK, 0x89ab5c13);
    expect(space, BASE, 4, G32_OK, 0xeea55c13);
    const unsigned offsets[] = {0, G32_PAGE - 4, G32_PAGE - 3, G32_PAGE - 2,
                                G32_PAGE - 1, G32_PAGE};
    for (unsigned first = 0; first < 8; ++first) {
        for (unsigned second = 0; second < 8; ++second) {
            for (unsigned width = 1; width <= 4; width *= 2) {
                for (unsigned store = 0; store < 2; ++store) {
                    for (size_t j = 0; j < sizeof(offsets) / sizeof(offsets[0]); ++j) {
                        unsigned offset = offsets[j], required = store ? G32_WRITE : G32_READ;
                        assert(g32_write(space, BASE, before, sizeof(before)) == G32_OK);
                        assert(g32_protect(space, BASE, G32_PAGE, first) == G32_OK);
                        assert(g32_protect(space, BASE + G32_PAGE, G32_PAGE, second) == G32_OK);
                        g32_region regions[3], observed;
                        for (unsigned page = 0; page < 3; ++page)
                            assert(g32_query(space, BASE + page * G32_PAGE, &regions[page]) == G32_OK);
                        int allowed = offset >= G32_PAGE ? !!(second & required) :
                            !!(first & required) && (offset + width <= G32_PAGE || (second & required));
                        uint32_t wanted = SOURCE;
                        unsigned char expected[sizeof(before)];
                        memcpy(expected, before, sizeof(expected));
                        if (allowed) {
                            for (unsigned i = 0; i < width; ++i) {
                                if (store) expected[offset + i] = (unsigned char)(SOURCE >> (i * 8));
                                else wanted = (wanted & ~(UINT32_C(0xff) << (i * 8))) |
                                              ((uint32_t)before[offset + i] << (i * 8));
                            }
                        }
                        expect(space, BASE + offset, width | (store ? G32_SCALAR_STORE : 0),
                               allowed ? G32_OK : G32_ACCESS, wanted);
                        for (unsigned page = 0; page < 3; ++page) {
                            assert(g32_query(space, BASE + page * G32_PAGE, &observed) == G32_OK);
                            same_region(&regions[page], &observed);
                        }
                        assert(g32_protect(space, BASE, 3 * G32_PAGE, G32_READ | G32_WRITE) == G32_OK);
                        assert(g32_read(space, BASE, after, sizeof(after)) == G32_OK);
                        assert(memcmp(after, expected, sizeof(after)) == 0);
                    }
                }
            }
        }
    }
}

static void rejection(g32_space *space)
{
    unsigned char before[G32_PAGE], after[G32_PAGE];
    assert(g32_read(space, BASE, before, sizeof(before)) == G32_OK);
    assert(g32_decommit(space, BASE + G32_PAGE, G32_PAGE) == G32_OK);
    assert(g32_protect(space, BASE + 2 * G32_PAGE, G32_PAGE, G32_EXEC) == G32_OK);
    for (unsigned width = 1; width <= 4; width *= 2) {
        for (unsigned store = 0; store < 2; ++store) {
            unsigned op = width | (store ? G32_SCALAR_STORE : 0);
            expect(space, BASE + G32_PAGE, op, G32_ACCESS, SOURCE);
            expect(space, BASE + 2 * G32_PAGE, op, G32_ACCESS, SOURCE);
            if (width > 1) expect(space, BASE + G32_PAGE - 1, op, G32_ACCESS, SOURCE);
            expect(space, 0, op, G32_RANGE, SOURCE);
            expect(space, G32_GRANULE - 1, op, G32_RANGE, SOURCE);
            expect(space, BASE + G32_GRANULE, op, G32_ACCESS, SOURCE);
            expect(space, UINT64_C(1) << 32 | BASE, op, G32_RANGE, SOURCE);
            expect(space, g32_backing_base(space) + BASE, op, G32_RANGE, SOURCE);
            expect(space, UINT64_MAX, op, G32_RANGE, SOURCE);
            expect(NULL, BASE, op, G32_SYSTEM, SOURCE);
        }
    }
    /* A native CPU-state-like buffer must never be reclassified by truncation. */
    unsigned char native[128], native_before[sizeof(native)];
    memset(native, 0xa5, sizeof(native));
    memcpy(native_before, native, sizeof(native));
    assert((uintptr_t)native > UINT32_MAX);
    expect(space, (uintptr_t)native, 4 | G32_SCALAR_STORE, G32_RANGE, SOURCE);
    assert(memcmp(native, native_before, sizeof(native)) == 0);
    const unsigned invalid[] = {0, 3, 8, G32_SCALAR_STORE, 0x201, 0x80000004, UINT32_MAX};
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i)
        expect(space, BASE, invalid[i], G32_RANGE, SOURCE);
    assert(g32_read(space, BASE, after, sizeof(after)) == G32_OK);
    assert(memcmp(before, after, sizeof(before)) == 0);
    g32_region region;
    assert(g32_query(space, BASE + G32_PAGE, &region) == G32_OK);
    assert(region.state == G32_REGION_RESERVED && region.permissions == 0);
    assert(g32_query(space, BASE + 2 * G32_PAGE, &region) == G32_OK);
    assert(region.state == G32_REGION_COMMITTED && region.permissions == G32_EXEC);
}

static void upper_edge(g32_space *space)
{
    assert(g32_reserve(space, 0xffff0000, G32_GRANULE) == G32_OK);
    assert(g32_commit(space, 0xfffff000, G32_PAGE, G32_READ | G32_WRITE) == G32_OK);
    unsigned char original[G32_PAGE], expected[G32_PAGE], observed[G32_PAGE];
    memset(original, 0xa5, sizeof(original));
    for (unsigned width = 1; width <= 4; width *= 2) {
        for (unsigned tail = 1; tail <= 4; ++tail) {
            uint32_t address = UINT32_MAX - tail + 1;
            for (unsigned store = 0; store < 2; ++store) {
                assert(g32_write(space, 0xfffff000, original, sizeof(original)) == G32_OK);
                memcpy(expected, original, sizeof(expected));
                int allowed = width <= tail;
                uint32_t value = SOURCE;
                if (allowed) {
                    for (unsigned i = 0; i < width; ++i) {
                        if (store) expected[G32_PAGE - tail + i] = (unsigned char)(SOURCE >> (i * 8));
                        else value = (value & ~(UINT32_C(0xff) << (i * 8))) | (UINT32_C(0xa5) << (i * 8));
                    }
                }
                expect(space, address, width | (store ? G32_SCALAR_STORE : 0), allowed ? G32_OK : G32_RANGE, value);
                assert(g32_read(space, 0xfffff000, observed, sizeof(observed)) == G32_OK);
                assert(memcmp(expected, observed, sizeof(expected)) == 0);
            }
        }
    }
}

static void isolation(g32_space *space)
{
    g32_space *other;
    assert(g32_create(0, &other) == G32_OK);
    assert(g32_reserve(other, BASE, G32_GRANULE) == G32_OK);
    assert(g32_commit(other, BASE, G32_PAGE, G32_READ | G32_WRITE) == G32_OK);
    const unsigned char a[] = {0x12, 0x34, 0x56, 0x78}, b[] = {0xab, 0xcd, 0xef, 0x89};
    assert(g32_write(space, BASE, a, sizeof(a)) == G32_OK);
    assert(g32_write(other, BASE, b, sizeof(b)) == G32_OK);
    expect(space, BASE, 4, G32_OK, 0x78563412);
    expect(other, BASE, 4, G32_OK, 0x89efcdab);
    expect(other, BASE, 4 | G32_SCALAR_STORE, G32_OK, SOURCE);
    expect(space, BASE, 4, G32_OK, 0x78563412);
    g32_destroy(other);
}

int main(void)
{
    const size_t granules[] = {0, 16384, 65536};
    for (size_t i = 0; i < sizeof(granules) / sizeof(granules[0]); ++i) {
        g32_space *space;
        assert(g32_create(granules[i], &space) == G32_OK);
        assert(g32_reserve(space, BASE, G32_GRANULE) == G32_OK);
        assert(g32_commit(space, BASE, 3 * G32_PAGE, G32_READ | G32_WRITE) == G32_OK);
        permissions(space);
        rejection(space);
        upper_edge(space);
        isolation(space);
        g32_destroy(space);
    }
    printf("PASS: checked scalar helper %u calls; permissions, complete widths, partial loads,\n"
           "little endian, unchanged failure values/bytes/metadata and native-pointer rejection; NO FEX call emission\n", calls);
    return 0;
}
