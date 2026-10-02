/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "pe32.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OK(call) assert((call) == G32_OK)
#define PE_OK(call) assert((call) == G32_PE_OK)
#define IS(call, error) assert((call) == (error))
#define FILE_SIZE 0x800
#define OPTIONAL 0x98
#define TABLE 0x178
#define IMPORT_FILE 0x500
#define RELOC_FILE 0x480
#define PREFERRED UINT32_C(0x400000)

static void p16(unsigned char *p, uint16_t value)
{ p[0] = (unsigned char)value; p[1] = (unsigned char)(value >> 8); }
static void p32(unsigned char *p, uint32_t value)
{ for (unsigned i = 0; i < 4; ++i) p[i] = (unsigned char)(value >> (i * 8)); }
static uint32_t u32(const unsigned char *p)
{ return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

static void fixture(unsigned char *f)
{
    memset(f, 0, FILE_SIZE);
    p16(f, 0x5a4d); p32(f + 0x3c, 0x80);
    p32(f + 0x80, 0x4550); p16(f + 0x84, 0x14c);
    p16(f + 0x86, 3); p16(f + 0x94, 224); p16(f + 0x96, 0x102);
    unsigned char *o = f + OPTIONAL;
    p16(o, 0x10b); p32(o + 16, 0x1000); p32(o + 28, PREFERRED);
    p32(o + 32, 0x1000); p32(o + 36, 0x200);
    p32(o + 56, 0x5000); p32(o + 60, 0x200); p32(o + 92, 16);
    p32(o + 96 + 8, 0x2100); p32(o + 100 + 8, 40);
    p32(o + 96 + 5 * 8, 0x2080); p32(o + 100 + 5 * 8, 12);
    for (unsigned n = 0; n < 3; ++n) {
        unsigned char *s = f + TABLE + n * 40;
        const char *names[] = {".text", ".rdata", ".data"};
        memcpy(s, names[n], strlen(names[n]));
        p32(s + 8, n == 2 ? 0x800 : n == 0 ? 0x80 : 0x200);
        p32(s + 12, (n + 1) * 0x1000); p32(s + 16, 0x200);
        p32(s + 20, (n + 1) * 0x200);
        p32(s + 36, n == 0 ? 0x60000020 : n == 1 ? 0x40000040 : 0xc0000040);
    }
    f[0x200] = 0xc3; /* RET byte: fetched, never executed. */
    p32(f + 0x204, PREFERRED + 0x3000);
    p32(f + RELOC_FILE, 0x1000); p32(f + RELOC_FILE + 4, 12);
    p16(f + RELOC_FILE + 8, 0x3004); p16(f + RELOC_FILE + 10, 0);
    p32(f + IMPORT_FILE, 0x2140);
    p32(f + IMPORT_FILE + 12, 0x2180); p32(f + IMPORT_FILE + 16, 0x2150);
    p32(f + 0x540, 0x2160); p32(f + 0x544, 0x80000007);
    p32(f + 0x550, 0x2160); p32(f + 0x554, 0x80000007);
    memcpy(f + 0x562, "GetTickCount", 13);
    memcpy(f + 0x580, "KERNEL32.dll", 13);
    memcpy(f + 0x600, "raw-data", 8);
}

static int expected_import(void *context, const char *dll, const char *symbol,
                           uint16_t ordinal, uint32_t iat)
{
    unsigned *calls = context;
    assert(strcmp(dll, "KERNEL32.dll") == 0);
    if (!*calls) {
        assert(symbol && strcmp(symbol, "GetTickCount") == 0 && ordinal == 0);
        assert((iat & 0xffff) == 0x2150);
    } else {
        assert(!symbol && ordinal == 7 && (iat & 0xffff) == 0x2154);
    }
    ++*calls;
    return 0;
}

static int count_import(void *context, const char *dll, const char *symbol,
                        uint16_t ordinal, uint32_t iat)
{
    (void)dll; (void)symbol; (void)ordinal;
    assert(iat >= G32_GRANULE);
    ++*(unsigned *)context;
    return 0;
}

static void rejected(g32_space *s, const unsigned char *f, size_t size,
                     uint32_t base, g32_pe_result result)
{
    g32_pe_image output, before;
    memset(&output, 0xa5, sizeof(output));
    memcpy(&before, &output, sizeof(before));
    IS(g32_pe_map(s, f, size, base, &output), result);
    assert(memcmp(&before, &output, sizeof(before)) == 0);
    /* Neither parser nor post-reservation failure may leak a reservation. */
    OK(g32_reserve(s, base ? base : PREFERRED, 0x5000));
    OK(g32_release(s, base ? base : PREFERRED));
}

static void cases(size_t granule)
{
    unsigned char original[FILE_SIZE], f[FILE_SIZE];
    fixture(original);
    g32_space *s, *other;
    OK(g32_create(granule, &s)); OK(g32_create(granule, &other));
    for (unsigned n = 0; n < 2; ++n) {
        uint32_t base = n ? 0x500000 : PREFERRED;
        g32_pe_image image;
        PE_OK(g32_pe_map(s, original, sizeof(original), n ? base : 0, &image));
        assert(image.space == s && image.base == base && image.preferred_base == PREFERRED);
        assert(image.entry == base + 0x1000 && image.sections == 3 && image.size == 0x5000);
        assert(image.relocations == n);
        unsigned char bytes[8];
        OK(g32_fetch(s, image.entry, bytes, 1)); assert(bytes[0] == 0xc3);
        OK(g32_read(s, base + 0x1004, bytes, 4)); assert(u32(bytes) == base + 0x3000);
        OK(g32_read(s, base + 0x3000, bytes, 8)); assert(memcmp(bytes, "raw-data", 8) == 0);
        OK(g32_read(s, base + 0x3200, bytes, 8));
        for (unsigned b = 0; b < 8; ++b) assert(bytes[b] == 0); /* BSS */
        IS(g32_read(s, base + 0x4000, bytes, 1), G32_ACCESS); /* reserved gap */
        IS(g32_write(s, base + 0x1000, bytes, 1), G32_ACCESS);
        IS(g32_write(s, base, bytes, 1), G32_ACCESS);
        IS(g32_fetch(s, base + 0x2000, bytes, 1), G32_ACCESS);
        OK(g32_write(s, base + 0x3000, bytes, 1));
        unsigned calls = 0;
        PE_OK(g32_pe_imports(s, &image, expected_import, &calls)); assert(calls == 2);
        IS(g32_pe_imports(other, &image, expected_import, &calls), G32_PE_FORMAT);
        IS(g32_pe_unmap(other, &image), G32_RANGE);
        OK(g32_pe_unmap(s, &image));
        IS(g32_read(s, base, bytes, 1), G32_ACCESS);
    }
    assert(memcmp(original + 0x204, "\0\x30\x40\0", 4) == 0); /* Input not relocated. */

    /* Conflicts must preserve a pre-existing mapping instead of releasing it. */
    OK(g32_reserve(s, PREFERRED, G32_PAGE));
    OK(g32_commit(s, PREFERRED, G32_PAGE, G32_READ | G32_WRITE));
    unsigned char marker = 0x77, value;
    OK(g32_write(s, PREFERRED, &marker, 1));
    g32_pe_image output;
    IS(g32_pe_map(s, original, sizeof(original), 0, &output), G32_PE_ADDRESS);
    OK(g32_read(s, PREFERRED, &value, 1)); assert(value == marker);
    OK(g32_release(s, PREFERRED));

    for (size_t truncated = 0; truncated < sizeof(original); ++truncated)
        rejected(s, original, truncated, 0, G32_PE_FORMAT);
#define BAD32(offset, value, base, result) do { \
    memcpy(f, original, sizeof(f)); p32(f + (offset), (value)); \
    rejected(s, f, sizeof(f), (base), (result)); \
} while (0)
    BAD32(0x3c, UINT32_MAX, 0, G32_PE_FORMAT);
    BAD32(0x80, 0, 0, G32_PE_FORMAT);
    memcpy(f, original, sizeof(f)); p16(f + 0x84, 0x8664);
    rejected(s, f, sizeof(f), 0, G32_PE_UNSUPPORTED);
    memcpy(f, original, sizeof(f)); p16(f + OPTIONAL, 0x20b);
    rejected(s, f, sizeof(f), 0, G32_PE_UNSUPPORTED);
    memcpy(f, original, sizeof(f)); p16(f + 0x86, 97);
    rejected(s, f, sizeof(f), 0, G32_PE_FORMAT);
    memcpy(f, original, sizeof(f)); p16(f + 0x94, 95);
    rejected(s, f, sizeof(f), 0, G32_PE_FORMAT);
    BAD32(OPTIONAL + 92, 17, 0, G32_PE_FORMAT);
    BAD32(OPTIONAL + 32, 512, 0, G32_PE_UNSUPPORTED);
    BAD32(OPTIONAL + 36, 513, 0, G32_PE_UNSUPPORTED);
    BAD32(OPTIONAL + 56, 0, 0, G32_PE_FORMAT);
    BAD32(OPTIONAL + 56, UINT32_MAX, 0, G32_PE_FORMAT);
    BAD32(OPTIONAL + 60, 0xfffffffeu, 0, G32_PE_FORMAT);
    BAD32(OPTIONAL + 60, 0x100, 0, G32_PE_FORMAT);
    BAD32(TABLE + 20, UINT32_MAX, 0, G32_PE_FORMAT);
    BAD32(TABLE + 20, 0, 0, G32_PE_FORMAT);
    BAD32(TABLE + 8, UINT32_MAX, 0, G32_PE_FORMAT);
    BAD32(TABLE + 12, 0, 0, G32_PE_FORMAT);
    BAD32(TABLE + 40 + 12, 0x1000, 0, G32_PE_FORMAT); /* section overlap */
    BAD32(OPTIONAL + 16, 0x2000, 0, G32_PE_FORMAT); /* Entry is not executable. */
    BAD32(OPTIONAL + 16, 0x5000, 0, G32_PE_FORMAT);
    BAD32(OPTIONAL + 96, 0x2000, 0, G32_PE_FORMAT); /* unpaired exports */
    BAD32(OPTIONAL + 100, 40, 0, G32_PE_FORMAT);
#undef BAD32
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 28, 0);
    PE_OK(g32_pe_map(s, f, sizeof(f), PREFERRED, &output));
    OK(g32_pe_unmap(s, &output));
    g32_destroy(s); g32_destroy(other);
    printf("pe32: granule=%zu mapping checks ok\n", granule);
}

static void relocations_and_imports(void)
{
    g32_space *s;
    OK(g32_create(16384, &s));
    unsigned char original[FILE_SIZE], f[FILE_SIZE]; fixture(original);
    const uint32_t base = 0x500000;
    memcpy(f, original, sizeof(f)); p32(f + RELOC_FILE + 4, 7);
    rejected(s, f, sizeof(f), base, G32_PE_RELOCATION);
    memcpy(f, original, sizeof(f)); p32(f + RELOC_FILE + 4, 11);
    rejected(s, f, sizeof(f), base, G32_PE_RELOCATION);
    memcpy(f, original, sizeof(f)); p32(f + RELOC_FILE + 4, 14);
    rejected(s, f, sizeof(f), base, G32_PE_RELOCATION);
    memcpy(f, original, sizeof(f)); p32(f + RELOC_FILE, 0x1001);
    rejected(s, f, sizeof(f), base, G32_PE_RELOCATION);
    memcpy(f, original, sizeof(f)); p32(f + RELOC_FILE, 0x4000);
    rejected(s, f, sizeof(f), base, G32_PE_RELOCATION); /* uncommitted target */
    memcpy(f, original, sizeof(f)); p16(f + RELOC_FILE + 8, 0xa004);
    rejected(s, f, sizeof(f), base, G32_PE_UNSUPPORTED);
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 96 + 5 * 8, 0x4000);
    rejected(s, f, sizeof(f), base, G32_PE_RELOCATION); /* directory in gap */
    memcpy(f, original, sizeof(f)); p16(f + 0x96, 0x103);
    rejected(s, f, sizeof(f), base, G32_PE_RELOCATION); /* stripped */
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 96 + 5 * 8, 0);
    p32(f + OPTIONAL + 100 + 5 * 8, 0);
    rejected(s, f, sizeof(f), base, G32_PE_RELOCATION);
    /* Relocation must not change subsequent records in a mutable table. */
    memcpy(f, original, sizeof(f)); p32(f + RELOC_FILE, 0x2000);
    p16(f + RELOC_FILE + 8, 0x3088);
    g32_pe_image image;
    PE_OK(g32_pe_map(s, f, sizeof(f), 0x10400000, &image)); assert(image.relocations == 1);
    OK(g32_pe_unmap(s, &image));
    /* A high address can end exactly at 2^32, but cannot extend past it. */
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 56, 0x10000);
    PE_OK(g32_pe_map(s, f, sizeof(f), 0xffff0000u, &image));
    OK(g32_pe_unmap(s, &image));
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 56, 0x11000);
    IS(g32_pe_map(s, f, sizeof(f), 0xffff0000u, &image), G32_PE_ADDRESS);
    IS(g32_pe_map(s, original, sizeof(original), 0x500001, &image), G32_PE_ADDRESS);

    const uint32_t corruptions[][2] = {
        {IMPORT_FILE + 12, 0x4000}, /* Name in reserved gap */
        {IMPORT_FILE + 16, 0x4ffc}, /* IAT in gap */
        {0x540, 0xffffffffu},      /* malformed ordinal */
        {0x540, 0x4000},           /* import name in gap */
        {0x540, 0x4fff},           /* name wraps image end */
        {OPTIONAL + 100 + 8, 20},  /* no terminating descriptor */
    };
    for (unsigned n = 0; n < sizeof(corruptions) / sizeof(corruptions[0]); ++n) {
        memcpy(f, original, sizeof(f)); p32(f + corruptions[n][0], corruptions[n][1]);
        PE_OK(g32_pe_map(s, f, sizeof(f), 0, &image));
        unsigned calls = 0;
        IS(g32_pe_imports(s, &image, count_import, &calls), G32_PE_FORMAT);
        OK(g32_pe_unmap(s, &image));
    }
    /* OriginalFirstThunk=0 uses FirstThunk, and DLL images may have entry=0. */
    memcpy(f, original, sizeof(f)); p32(f + IMPORT_FILE, 0); p32(f + OPTIONAL + 16, 0);
    PE_OK(g32_pe_map(s, f, sizeof(f), 0, &image)); assert(image.entry == 0);
    unsigned calls = 0;
    PE_OK(g32_pe_imports(s, &image, expected_import, &calls)); assert(calls == 2);
    OK(g32_pe_unmap(s, &image));
    g32_destroy(s);
}

typedef struct {
    unsigned calls, fail_at;
    uint64_t named, ordinal;
} resolver_state;

static int resolve_fixture(void *context, const char *dll, const char *symbol,
                           uint16_t ordinal, uint64_t *address)
{
    resolver_state *state = context;
    assert(strcmp(dll, "KERNEL32.dll") == 0);
    ++state->calls;
    if (state->calls == state->fail_at) return 0;
    if (symbol) {
        assert(strcmp(symbol, "GetTickCount") == 0 && ordinal == 0);
        *address = state->named;
    } else {
        assert(ordinal == 7);
        *address = state->ordinal;
    }
    return 1;
}

static void auto_rejected(g32_space *s, const unsigned char *f,
                           uint32_t lower, uint64_t upper, g32_pe_result expected,
                           uint32_t free_base)
{
    g32_pe_image image, sentinel;
    memset(&image, 0xa5, sizeof(image)); memcpy(&sentinel, &image, sizeof(image));
    IS(g32_pe_map_auto(s, f, FILE_SIZE, lower, upper, &image), expected);
    assert(memcmp(&image, &sentinel, sizeof(image)) == 0);
    if (free_base) { OK(g32_reserve(s, free_base, 0x5000)); OK(g32_release(s, free_base)); }
}

static void auto_mapping_cases(size_t granule)
{
    g32_space *s;
    OK(g32_create(granule, &s));
    unsigned char original[FILE_SIZE], f[FILE_SIZE], value[8]; fixture(original);
    const uint64_t limit = UINT64_C(1) << 32;
    g32_pe_image first, second;
    /* Preferred base wins even when lower addresses are free. */
    PE_OK(g32_pe_map_auto(s, original, sizeof(original), 0, limit, &first));
    assert(first.base == PREFERRED && first.relocations == 0);
    PE_OK(g32_pe_map_auto(s, original, sizeof(original), PREFERRED, limit, &second));
    assert(second.base == PREFERRED + G32_GRANULE && second.relocations == 1);
    OK(g32_read(s, second.base + 0x1004, value, 4));
    assert(u32(value) == second.base + 0x3000);
    OK(g32_read(s, first.base + 0x1004, value, 4));
    assert(u32(value) == first.base + 0x3000);
    OK(g32_pe_unmap(s, &second));
    /* No relocations needed at the preferred base, even when stripped. */
    memcpy(f, original, sizeof(f)); p16(f + 0x96, 0x103);
    auto_rejected(s, f, PREFERRED, limit, G32_PE_RELOCATION, PREFERRED + G32_GRANULE);
    OK(g32_pe_unmap(s, &first));
    PE_OK(g32_pe_map_auto(s, f, sizeof(f), 0, limit, &first));
    assert(first.base == PREFERRED && !first.relocations);
    OK(g32_pe_unmap(s, &first));
    p16(f + 0x96, 0x102); /* Not stripped, but no relocation directory. */
    p32(f + OPTIONAL + 96 + 5 * 8, 0); p32(f + OPTIONAL + 100 + 5 * 8, 0);
    PE_OK(g32_pe_map_auto(s, f, sizeof(f), 0, limit, &first));
    assert(first.base == PREFERRED && !first.relocations); OK(g32_pe_unmap(s, &first));
    auto_rejected(s, f, PREFERRED + 1, limit, G32_PE_RELOCATION, PREFERRED + G32_GRANULE);

    /* Decommit preserves ownership, and must not free preferred placement. */
    OK(g32_reserve(s, PREFERRED, 0x2000));
    OK(g32_commit(s, PREFERRED, 0x2000, G32_READ | G32_WRITE));
    unsigned char marker = 0x77;
    OK(g32_write(s, PREFERRED, &marker, 1));
    OK(g32_decommit(s, PREFERRED + G32_PAGE, G32_PAGE));
    OK(g32_reserve(s, PREFERRED + G32_GRANULE, 0x5000));
    PE_OK(g32_pe_map_auto(s, original, sizeof(original), PREFERRED, limit, &second));
    assert(second.base == PREFERRED + 2 * G32_GRANULE);
    OK(g32_pe_unmap(s, &second));
    auto_rejected(s, original, PREFERRED, PREFERRED + 2 * G32_GRANULE,
                  G32_PE_NO_SPACE, PREFERRED + 2 * G32_GRANULE);
    OK(g32_release(s, PREFERRED + G32_GRANULE));
    OK(g32_reserve(s, PREFERRED + G32_GRANULE, G32_PAGE));
    OK(g32_commit(s, PREFERRED + G32_GRANULE, G32_PAGE, G32_READ));
    OK(g32_decommit(s, PREFERRED + G32_GRANULE, G32_PAGE));
    PE_OK(g32_pe_map_auto(s, original, sizeof(original), PREFERRED, limit, &second));
    assert(second.base == PREFERRED + 2 * G32_GRANULE);
    OK(g32_pe_unmap(s, &second));
    OK(g32_release(s, PREFERRED + G32_GRANULE));

    /* A malformed relocation or failed finalization rolls back the chosen
     * fallback, preserving the live blocker and output. No retry at later bases. */
    memcpy(f, original, sizeof(f)); p32(f + RELOC_FILE + 4, 7);
    auto_rejected(s, f, PREFERRED, limit, G32_PE_RELOCATION, PREFERRED + G32_GRANULE);
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 16, 0x2000);
    auto_rejected(s, f, PREFERRED, limit, G32_PE_FORMAT, PREFERRED + G32_GRANULE);
    memcpy(f, original, sizeof(f)); p16(f + RELOC_FILE + 8, 0xa004);
    auto_rejected(s, f, PREFERRED, limit, G32_PE_UNSUPPORTED, PREFERRED + G32_GRANULE);

    resolver_state state = { .named = PREFERRED, .ordinal = PREFERRED };
    PE_OK(g32_pe_map_bound_auto(s, original, sizeof(original), PREFERRED, limit,
                               resolve_fixture, &state, &second));
    assert(second.base == PREFERRED + G32_GRANULE && state.calls == 2);
    OK(g32_read(s, second.base + 0x2150, value, 8));
    assert(u32(value) == PREFERRED && u32(value + 4) == PREFERRED);
    IS(g32_write(s, second.base + 0x2150, value, 4), G32_ACCESS);
    OK(g32_pe_unmap(s, &second));
    g32_pe_image sentinel; memset(&sentinel, 0xa5, sizeof(sentinel));
    memcpy(&second, &sentinel, sizeof(second));
    state.calls = 0; state.fail_at = 2;
    IS(g32_pe_map_bound_auto(s, original, sizeof(original), PREFERRED, limit,
                            resolve_fixture, &state, &second), G32_PE_IMPORT);
    assert(state.calls == 2 && memcmp(&second, &sentinel, sizeof(second)) == 0);
    OK(g32_reserve(s, PREFERRED + G32_GRANULE, 0x5000));
    OK(g32_release(s, PREFERRED + G32_GRANULE));
    IS(g32_pe_map_bound_auto(s, original, sizeof(original), 0, limit, NULL, NULL, &second),
       G32_PE_FORMAT);
    assert(memcmp(&second, &sentinel, sizeof(second)) == 0);
    OK(g32_read(s, PREFERRED, value, 1)); assert(value[0] == marker);
    IS(g32_read(s, PREFERRED + G32_PAGE, value, 1), G32_ACCESS);
    OK(g32_release(s, PREFERRED));

    /* Collision at a later page in a larger image, not just its first page. */
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 56, 0x25000);
    OK(g32_reserve(s, PREFERRED + G32_GRANULE, G32_PAGE));
    PE_OK(g32_pe_map_auto(s, f, sizeof(f), PREFERRED, limit, &first));
    assert(first.base == PREFERRED + 2 * G32_GRANULE); OK(g32_pe_unmap(s, &first));
    OK(g32_release(s, PREFERRED + G32_GRANULE));

    /* Tight half-open bounds, unaligned lower bounds and exact top-of-space fit. */
    PE_OK(g32_pe_map_auto(s, original, sizeof(original), PREFERRED + 1,
                         PREFERRED + G32_GRANULE + 0x5000, &first));
    assert(first.base == PREFERRED + G32_GRANULE); OK(g32_pe_unmap(s, &first));
    auto_rejected(s, original, PREFERRED + 1, PREFERRED + G32_GRANULE + 0x4fff,
                  G32_PE_NO_SPACE, PREFERRED + G32_GRANULE);
    auto_rejected(s, original, 0, G32_GRANULE, G32_PE_NO_SPACE, PREFERRED);
    auto_rejected(s, original, PREFERRED, PREFERRED, G32_PE_ADDRESS, PREFERRED);
    auto_rejected(s, original, PREFERRED + 1, PREFERRED, G32_PE_ADDRESS, PREFERRED);
    auto_rejected(s, original, 0, limit + 1, G32_PE_ADDRESS, PREFERRED);
    auto_rejected(s, original, UINT32_MAX, limit, G32_PE_NO_SPACE, PREFERRED);
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 56, 0x10000);
    PE_OK(g32_pe_map_auto(s, f, sizeof(f), 0xffff0000u, limit, &first));
    assert(first.base == 0xffff0000u); OK(g32_pe_unmap(s, &first));
    p32(f + OPTIONAL + 56, 0x11000);
    auto_rejected(s, f, 0xffff0000u, limit, G32_PE_NO_SPACE, 0xffff0000u);
    /* Invalid preferred addresses may be overridden only with relocations. */
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 28, 0x400001);
    PE_OK(g32_pe_map_auto(s, f, sizeof(f), PREFERRED, limit, &first));
    assert(first.base == PREFERRED && first.relocations == 1); OK(g32_pe_unmap(s, &first));
    p16(f + 0x96, 0x103);
    auto_rejected(s, f, PREFERRED, limit, G32_PE_RELOCATION, PREFERRED);
    IS(g32_pe_map_auto(NULL, original, sizeof(original), 0, limit, &first), G32_PE_FORMAT);
    IS(g32_pe_map_auto(s, original, sizeof(original), 0, limit, NULL), G32_PE_FORMAT);
    IS(g32_pe_map_auto(s, original, 0, 0, limit, &first), G32_PE_FORMAT);
    assert(memcmp(original + 0x204, "\0\x30\x40\0", 4) == 0);
    g32_destroy(s);
    printf("pe32: granule=%zu automatic placement and rollback checks ok\n", granule);
}

static void binding_cases(size_t granule)
{
    g32_space *s, *other;
    OK(g32_create(granule, &s)); OK(g32_create(granule, &other));
    unsigned char original[FILE_SIZE], f[FILE_SIZE], before[8], after[8];
    fixture(original);
    g32_pe_image dependency, image;
    const uint32_t dep = 0x600000, base = 0x500000;
    PE_OK(g32_pe_map(s, original, sizeof(original), dep, &dependency));
    OK(g32_reserve(other, 0x900000, G32_PAGE));
    OK(g32_commit(other, 0x900000, G32_PAGE, G32_READ | G32_EXEC));
    /* Function and DATA imports, with high native backing for both images. */
    for (unsigned fallback = 0; fallback < 2; ++fallback) {
        memcpy(f, original, sizeof(f));
        if (fallback) p32(f + IMPORT_FILE, 0);
        PE_OK(g32_pe_map(s, f, sizeof(f), base, &image));
        OK(g32_protect(s, base + 0x2000, G32_PAGE, G32_READ | G32_WRITE));
        resolver_state state = { .named = dep + 0x1000, .ordinal = dep + 0x3000 };
        PE_OK(g32_pe_bind_imports(s, &image, resolve_fixture, &state));
        assert(state.calls == 2);
        OK(g32_read(s, base + 0x2150, after, sizeof(after)));
        assert(u32(after) == dep + 0x1000 && u32(after + 4) == dep + 0x3000);
        void *loan;
        IS(g32_translate(s, base + 0x2000, 1, G32_EXEC, &loan), G32_ACCESS);
        if (!fallback) { /* Separate lookup table survives rebind. */
            state.calls = 0;
            PE_OK(g32_pe_bind_imports(s, &image, resolve_fixture, &state));
        }
        OK(g32_pe_unmap(s, &image));
    }
    /* A late unresolved symbol, a high host pointer, null/guard/uncommitted
     * targets, and another space's address must all leave both slots intact. */
    const uint64_t bad_targets[] = {
        0, 0xffff, UINT64_C(1) << 32, UINT64_MAX,
        dep + 0x4000, 0x900000, g32_backing_base(other) + 0x900000,
        g32_backing_base(s) + dep + 0x1000
    };
    for (unsigned n = 0; n <= sizeof(bad_targets) / sizeof(bad_targets[0]); ++n) {
        PE_OK(g32_pe_map(s, original, sizeof(original), base, &image));
        OK(g32_protect(s, base + 0x2000, G32_PAGE, G32_READ | G32_WRITE));
        OK(g32_read(s, base + 0x2150, before, sizeof(before)));
        resolver_state state = { .named = dep + 0x1000, .ordinal = dep + 0x3000 };
        if (!n) state.fail_at = 2;
        else state.ordinal = bad_targets[n - 1];
        IS(g32_pe_bind_imports(s, &image, resolve_fixture, &state), G32_PE_IMPORT);
        OK(g32_read(s, base + 0x2150, after, sizeof(after)));
        assert(memcmp(before, after, sizeof(before)) == 0 && state.calls == 2);
        OK(g32_pe_unmap(s, &image));
    }
    /* Read-only IAT: don't silently broaden permissions to bind it. */
    PE_OK(g32_pe_map(s, original, sizeof(original), base, &image));
    resolver_state state = { .named = dep + 0x1000, .ordinal = dep + 0x3000 };
    OK(g32_read(s, base + 0x2150, before, sizeof(before)));
    IS(g32_pe_bind_imports(s, &image, resolve_fixture, &state), G32_PE_IMPORT);
    OK(g32_read(s, base + 0x2150, after, sizeof(after)));
    assert(memcmp(before, after, sizeof(before)) == 0);
    IS(g32_write(s, base + 0x2150, after, 4), G32_ACCESS);
    state.calls = 0;
    IS(g32_pe_bind_imports(other, &image, resolve_fixture, &state), G32_PE_FORMAT);
    assert(state.calls == 0);
    IS(g32_pe_bind_imports(s, &image, NULL, NULL), G32_PE_FORMAT);
    OK(g32_pe_unmap(s, &image));
    /* Invalid later metadata is rejected before ANY resolver callbacks. */
    for (unsigned n = 0; n < 3; ++n) {
        memcpy(f, original, sizeof(f));
        if (!n) p32(f + 0x544, 0xffffffffu);
        if (n == 1) p32(f + OPTIONAL + 100 + 8, 20);
        if (n == 2) { /* Two descriptors with byte-overlapping IAT writes. */
            p32(f + OPTIONAL + 100 + 8, 60);
            memcpy(f + IMPORT_FILE + 20, f + IMPORT_FILE, 20);
            p32(f + IMPORT_FILE + 20 + 16, 0x2151);
        }
        PE_OK(g32_pe_map(s, f, sizeof(f), base, &image));
        OK(g32_protect(s, base + 0x2000, G32_PAGE, G32_READ | G32_WRITE));
        OK(g32_read(s, base + 0x2150, before, sizeof(before)));
        state.calls = 0;
        IS(g32_pe_bind_imports(s, &image, resolve_fixture, &state), G32_PE_FORMAT);
        assert(state.calls == 0);
        OK(g32_read(s, base + 0x2150, after, sizeof(after)));
        assert(memcmp(before, after, sizeof(before)) == 0);
        OK(g32_pe_unmap(s, &image));
    }
    /* Late protected slot shares a host page with a writable slot. */
    memcpy(f, original, sizeof(f)); p32(f + IMPORT_FILE + 16, 0x2ffc);
    PE_OK(g32_pe_map(s, f, sizeof(f), base, &image));
    OK(g32_protect(s, base + 0x2000, G32_PAGE, G32_READ | G32_WRITE));
    OK(g32_protect(s, base + 0x3000, G32_PAGE, G32_READ));
    OK(g32_read(s, base + 0x2ffc, before, sizeof(before)));
    state.calls = 0;
    IS(g32_pe_bind_imports(s, &image, resolve_fixture, &state), G32_PE_IMPORT);
    OK(g32_read(s, base + 0x2ffc, after, sizeof(after)));
    assert(memcmp(before, after, sizeof(before)) == 0);
    OK(g32_pe_unmap(s, &image));
    /* Targets may be execute-only, but cannot be inaccessible committed pages. */
    OK(g32_protect(s, dep + 0x1000, G32_PAGE, G32_EXEC));
    PE_OK(g32_pe_map(s, original, sizeof(original), base, &image));
    OK(g32_protect(s, base + 0x2000, G32_PAGE, G32_READ | G32_WRITE));
    PE_OK(g32_pe_bind_imports(s, &image, resolve_fixture, &state));
    OK(g32_read(s, base + 0x2150, before, sizeof(before)));
    OK(g32_protect(s, dep + 0x3000, G32_PAGE, 0));
    IS(g32_pe_bind_imports(s, &image, resolve_fixture, &state), G32_PE_IMPORT);
    OK(g32_read(s, base + 0x2150, after, sizeof(after)));
    assert(memcmp(before, after, sizeof(before)) == 0);
    OK(g32_pe_unmap(s, &image));
    /* No imports is a successful no-op, without resolver calls. */
    memcpy(f, original, sizeof(f));
    p32(f + OPTIONAL + 96 + 8, 0); p32(f + OPTIONAL + 100 + 8, 0);
    PE_OK(g32_pe_map(s, f, sizeof(f), base, &image)); state.calls = 0;
    PE_OK(g32_pe_bind_imports(s, &image, resolve_fixture, &state));
    assert(state.calls == 0); OK(g32_pe_unmap(s, &image));
    /* Binding has a bounded staging budget, with no partial guest writes. */
    memcpy(f, original, sizeof(f));
    p32(f + OPTIONAL + 56, 0x90000);
    p32(f + TABLE + 80 + 8, 0x87000);
    p32(f + IMPORT_FILE, 0x3000); p32(f + IMPORT_FILE + 16, 0x48000);
    PE_OK(g32_pe_map(s, f, sizeof(f), base, &image));
    unsigned char slot[4]; p32(slot, 0x80000007);
    for (unsigned n = 0; n <= G32_PE_MAX_BIND_IMPORTS; ++n)
        OK(g32_write(s, base + 0x3000 + n * 4, slot, 4));
    state.calls = 0;
    OK(g32_read(s, base + 0x48000, before, sizeof(before)));
    IS(g32_pe_bind_imports(s, &image, resolve_fixture, &state), G32_PE_UNSUPPORTED);
    assert(state.calls == 0);
    OK(g32_read(s, base + 0x48000, after, sizeof(after)));
    assert(memcmp(before, after, sizeof(before)) == 0);
    OK(g32_pe_unmap(s, &image));
    OK(g32_pe_unmap(s, &dependency));
    g32_destroy(s); g32_destroy(other);
    printf("pe32: granule=%zu transactional guest-import binding checks ok\n", granule);
}

static void bound_rejected(g32_space *s, const unsigned char *f, size_t size,
                            uint32_t base, resolver_state *state, g32_pe_result error)
{
    g32_pe_image output, before;
    memset(&output, 0xa5, sizeof(output)); memcpy(&before, &output, sizeof(before));
    IS(g32_pe_map_bound(s, f, size, base, resolve_fixture, state, &output), error);
    assert(memcmp(&output, &before, sizeof(output)) == 0);
    OK(g32_reserve(s, base ? base : PREFERRED, 0x5000));
    OK(g32_release(s, base ? base : PREFERRED));
}

static void bound_mapping_cases(size_t granule)
{
    unsigned char original[FILE_SIZE], f[FILE_SIZE], source[FILE_SIZE], slots[8]; fixture(original);
    g32_space *s; OK(g32_create(granule, &s));
    g32_pe_image dependency, image;
    const uint32_t dep = 0x600000;
    PE_OK(g32_pe_map(s, original, sizeof(original), dep, &dependency));
    for (unsigned n = 0; n < 6; ++n) {
        memcpy(f, original, sizeof(f));
        uint32_t base = n & 1 ? 0x500000 : PREFERRED;
        uint32_t iat = n & 4 ? 0x2ffe : 0x2150;
        if (n & 2) p32(f + IMPORT_FILE, 0); /* FirstThunk-only snapshot. */
        if (n & 4) {
            p32(f + IMPORT_FILE + 16, iat);
            /* An unaligned slot spans two guest pages within one host granule.
             * Both pages will be read-only again after binding. */
            p32(f + TABLE + 80 + 36, 0x40000040);
        }
        memcpy(source, f, sizeof(source));
        resolver_state state = { .named = dep + 0x1000, .ordinal = dep + 0x3000 };
        PE_OK(g32_pe_map_bound(s, f, sizeof(f), base == PREFERRED ? 0 : base,
                               resolve_fixture, &state, &image));
        assert(memcmp(source, f, sizeof(source)) == 0);
        assert(state.calls == 2 && image.base == base && image.entry == base + 0x1000 &&
               image.relocations == (base != PREFERRED));
        OK(g32_read(s, base + iat, slots, sizeof(slots)));
        assert(u32(slots) == dep + 0x1000 && u32(slots + 4) == dep + 0x3000);
        IS(g32_write(s, base + iat, slots, sizeof(slots)), G32_ACCESS);
        IS(g32_write(s, base, slots, 1), G32_ACCESS);
        IS(g32_write(s, base + 0x1000, slots, 1), G32_ACCESS);
        OK(g32_fetch(s, base + 0x1000, slots, 1)); assert(slots[0] == 0xc3);
        IS(g32_fetch(s, base + 0x2000, slots, 1), G32_ACCESS);
        IS(g32_read(s, base + 0x4000, slots, 1), G32_ACCESS);
        if (!(n & 4)) OK(g32_write(s, base + 0x3000, slots, 1));
        OK(g32_pe_unmap(s, &image));
    }
    const uint32_t base = 0x500000;
    /* Self-targets are checked under final permissions, not just initial RW.
     * An execute-only function remains valid; no-access data cannot escape. */
    memcpy(f, original, sizeof(f)); p32(f + TABLE + 36, 0x20000020);
    resolver_state state = { .named = base + 0x1000, .ordinal = base + 0x3000 };
    PE_OK(g32_pe_map_bound(s, f, sizeof(f), base, resolve_fixture, &state, &image));
    OK(g32_read(s, base + 0x2150, slots, sizeof(slots)));
    assert(u32(slots) == base + 0x1000 && u32(slots + 4) == base + 0x3000);
    IS(g32_read(s, base + 0x1000, slots, 1), G32_ACCESS);
    OK(g32_fetch(s, base + 0x1000, slots, 1)); OK(g32_pe_unmap(s, &image));
    p32(f + TABLE + 80 + 36, 0); state.calls = 0;
    bound_rejected(s, f, sizeof(f), base, &state, G32_PE_IMPORT); assert(state.calls == 2);
    /* Failure after binding/finalization must also discard the reservation. */
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 16, 0x2000); state.calls = 0;
    bound_rejected(s, f, sizeof(f), base, &state, G32_PE_FORMAT); assert(state.calls == 2);
    const uint64_t bad[] = { 0, base + 0x4000, UINT64_C(1) << 32,
                             g32_backing_base(s) + dep + 0x1000 };
    for (unsigned n = 0; n <= sizeof(bad) / sizeof(bad[0]); ++n) {
        state = (resolver_state){ .named = dep + 0x1000, .ordinal = dep + 0x3000 };
        if (!n) state.fail_at = 2; else state.ordinal = bad[n - 1];
        bound_rejected(s, original, sizeof(original), base, &state, G32_PE_IMPORT);
        assert(state.calls == 2);
    }
    /* Import snapshot, parsing and relocation failures happen before callbacks. */
    memcpy(f, original, sizeof(f)); p32(f + 0x544, 0xffffffffu); state.calls = 0;
    bound_rejected(s, f, sizeof(f), base, &state, G32_PE_FORMAT); assert(!state.calls);
    memcpy(f, original, sizeof(f)); p16(f + RELOC_FILE + 8, 0xa004);
    bound_rejected(s, f, sizeof(f), base, &state, G32_PE_UNSUPPORTED); assert(!state.calls);
    bound_rejected(s, original, 63, base, &state, G32_PE_FORMAT); assert(!state.calls);
    /* No-import images still finalize, with no resolver callbacks. */
    memcpy(f, original, sizeof(f)); p32(f + OPTIONAL + 96 + 8, 0); p32(f + OPTIONAL + 100 + 8, 0);
    PE_OK(g32_pe_map_bound(s, f, sizeof(f), base, resolve_fixture, &state, &image));
    assert(!state.calls); IS(g32_write(s, base + 0x2150, slots, 4), G32_ACCESS);
    OK(g32_pe_unmap(s, &image));
    g32_pe_image output, before;
    memset(&output, 0xa5, sizeof(output)); memcpy(&before, &output, sizeof(before));
    IS(g32_pe_map_bound(s, original, sizeof(original), base, NULL, NULL, &output), G32_PE_FORMAT);
    assert(memcmp(&output, &before, sizeof(output)) == 0);
    /* A conflict must not release or alter a previously mapped dependency. */
    state.calls = 0;
    IS(g32_pe_map_bound(s, original, sizeof(original), dep, resolve_fixture, &state, &output),
       G32_PE_ADDRESS);
    assert(!state.calls && memcmp(&output, &before, sizeof(output)) == 0);
    unsigned char unchanged[0x4000], expected[0x4000];
    OK(g32_read(s, dep, unchanged, 0x4000));
    OK(g32_pe_unmap(s, &dependency));
    PE_OK(g32_pe_map(s, original, sizeof(original), dep, &dependency));
    OK(g32_read(s, dep, expected, 0x4000)); assert(memcmp(unchanged, expected, 0x4000) == 0);
    OK(g32_pe_unmap(s, &dependency));
    fixture(f); assert(memcmp(f, original, sizeof(f)) == 0);
    g32_destroy(s);
    printf("pe32: granule=%zu map-bind-finalize and rollback checks ok\n", granule);
}

/* Export directory fits before the independent relocation/import fixtures. */
static void export_fixture(unsigned char *f)
{
    fixture(f);
    p32(f + OPTIONAL + 96, 0x2000); p32(f + OPTIONAL + 100, 0x80);
    p32(f + 0x410, 6); p32(f + 0x414, 5); p32(f + 0x418, 3);
    p32(f + 0x41c, 0x2028); p32(f + 0x420, 0x2040); p32(f + 0x424, 0x204c);
    p32(f + 0x428, 0x1000); p32(f + 0x42c, 0x3000); /* function and data */
    p32(f + 0x430, 0); p32(f + 0x434, 0x2070); p32(f + 0x438, 0x1004);
    p32(f + 0x440, 0x2052); p32(f + 0x444, 0x205f); p32(f + 0x448, 0x2064);
    p16(f + 0x44c, 0); p16(f + 0x44e, 1); p16(f + 0x450, 0);
    memcpy(f + 0x452, "GetTickCount", 13); memcpy(f + 0x45f, "Data", 5);
    memcpy(f + 0x464, "Alias", 6); memcpy(f + 0x470, "OTHER.#7", 9);
}

static void export_rejected(g32_space *s, const g32_pe_image *image,
                            const char *name, uint32_t ordinal, g32_pe_result error)
{
    g32_pe_export output, before;
    memset(&output, 0xa5, sizeof(output)); memcpy(&before, &output, sizeof(before));
    IS(g32_pe_find_export(s, image, name, ordinal, &output), error);
    assert(memcmp(&output, &before, sizeof(output)) == 0);
}

typedef struct { g32_space *space; const g32_pe_image *dependency; unsigned calls; } export_resolver;
static int resolve_export(void *context, const char *dll, const char *name,
                          uint16_t ordinal, uint64_t *address)
{
    export_resolver *r = context;
    assert(strcmp(dll, "KERNEL32.dll") == 0); ++r->calls;
    g32_pe_export found;
    if (g32_pe_find_export(r->space, r->dependency, name, ordinal, &found) != G32_PE_OK ||
        found.kind != G32_PE_EXPORT_ADDRESS) return 0;
    *address = found.address;
    return 1;
}

static void export_cases(size_t granule)
{
    unsigned char original[FILE_SIZE], f[FILE_SIZE]; export_fixture(original);
    g32_space *s, *other;
    OK(g32_create(granule, &s)); OK(g32_create(granule, &other));
    const uint32_t bases[] = { PREFERRED, 0x600000, 0xffff0000u };
    for (unsigned n = 0; n < sizeof(bases) / sizeof(bases[0]); ++n) {
        uint32_t base = bases[n];
        g32_pe_image image; g32_pe_export found;
        PE_OK(g32_pe_map(s, original, sizeof(original), base, &image));
        PE_OK(g32_pe_find_export(s, &image, "GetTickCount", 99, &found));
        assert(found.kind == G32_PE_EXPORT_ADDRESS && found.address == base + 0x1000 &&
               found.ordinal == 6 && !found.forwarder[0]);
        PE_OK(g32_pe_find_export(s, &image, "Alias", 0, &found));
        assert(found.address == base + 0x1000 && found.ordinal == 6);
        PE_OK(g32_pe_find_export(s, &image, "Data", 0, &found));
        assert(found.address == base + 0x3000 && found.ordinal == 7);
        PE_OK(g32_pe_find_export(s, &image, NULL, 7, &found));
        assert(found.address == base + 0x3000);
        PE_OK(g32_pe_find_export(s, &image, NULL, 10, &found));
        assert(found.address == base + 0x1004 && found.ordinal == 10);
        PE_OK(g32_pe_find_export(s, &image, NULL, 9, &found));
        assert(found.kind == G32_PE_EXPORT_FORWARDER && !found.address && found.ordinal == 9 &&
               strcmp(found.forwarder, "OTHER.#7") == 0);
        const uint32_t absent[] = { 0, 5, 8, 11, UINT32_MAX };
        for (unsigned a = 0; a < sizeof(absent) / sizeof(absent[0]); ++a)
            export_rejected(s, &image, NULL, absent[a], G32_PE_NOT_FOUND);
        export_rejected(s, &image, "gettickcount", 6, G32_PE_NOT_FOUND);
        export_rejected(other, &image, "Data", 0, G32_PE_FORMAT);
        IS(g32_pe_find_export(s, &image, NULL, 7, NULL), G32_PE_FORMAT);
        OK(g32_protect(s, base + 0x1000, G32_PAGE, G32_EXEC));
        PE_OK(g32_pe_find_export(s, &image, "Alias", 0, &found));
        OK(g32_protect(s, base + 0x3000, G32_PAGE, 0));
        export_rejected(s, &image, "Data", 0, G32_PE_FORMAT);
        OK(g32_pe_unmap(s, &image));
    }
    /* Full guest-page checks, even when a neighbor shares native backing.
     * A later name and the complete EAT span must remain readable. */
    g32_pe_image boundary; g32_pe_export boundary_export;
    PE_OK(g32_pe_map(s, original, sizeof(original), 0, &boundary));
    OK(g32_protect(s, PREFERRED + 0x2000, G32_PAGE, G32_READ | G32_WRITE));
    unsigned char pointer[4]; p32(pointer, 0x2fff);
    OK(g32_write(s, PREFERRED + 0x2048, pointer, 4));
    OK(g32_write(s, PREFERRED + 0x2fff, "Alias", 6));
    PE_OK(g32_pe_find_export(s, &boundary, "GetTickCount", 0, &boundary_export));
    OK(g32_protect(s, PREFERRED + 0x3000, G32_PAGE, 0));
    export_rejected(s, &boundary, "GetTickCount", 0, G32_PE_FORMAT);
    OK(g32_protect(s, PREFERRED + 0x3000, G32_PAGE, G32_READ | G32_WRITE));
    p32(pointer, 0x2064); OK(g32_write(s, PREFERRED + 0x2048, pointer, 4));
    p32(pointer, 0x2ffc); OK(g32_write(s, PREFERRED + 0x201c, pointer, 4));
    OK(g32_write(s, PREFERRED + 0x2ffc, original + 0x428, 20));
    PE_OK(g32_pe_find_export(s, &boundary, "GetTickCount", 0, &boundary_export));
    OK(g32_protect(s, PREFERRED + 0x3000, G32_PAGE, 0));
    export_rejected(s, &boundary, "GetTickCount", 0, G32_PE_FORMAT);
    OK(g32_pe_unmap(s, &boundary));
    const uint32_t bad[][2] = {
        {OPTIONAL + 100, 39}, /* truncated directory */
        {0x410, UINT32_MAX}, /* ordinal range overflow */
        {0x41c, 0x4ffc}, {0x420, UINT32_MAX}, {0x424, 0x4000}, /* table spans/gaps */
        {0x428, 0x4000}, {0x428, 0x5000}, {0x428, UINT32_MAX}, /* selected target */
        {0x440, 0x4000}, {0x440, 0x4fff}, /* name pointer */
        {0x448, 0x2052}, /* duplicate matching name */
        {0x434, 0x207f}, /* forwarder NUL lies outside export directory */
    };
    for (unsigned n = 0; n < sizeof(bad) / sizeof(bad[0]); ++n) {
        memcpy(f, original, sizeof(f)); p32(f + bad[n][0], bad[n][1]);
        if (bad[n][0] == 0x434) f[0x47f] = 'X';
        g32_pe_image image;
        PE_OK(g32_pe_map(s, f, sizeof(f), 0, &image));
        export_rejected(s, &image, bad[n][0] == 0x434 ? NULL : "GetTickCount", 9, G32_PE_FORMAT);
        OK(g32_pe_unmap(s, &image));
    }
    for (unsigned n = 0; n < 10; ++n) {
        memcpy(f, original, sizeof(f));
        if (n == 0) p16(f + 0x450, 5); /* malformed later name ordinal after match */
        if (n == 1) p32(f + 0x414, G32_PE_MAX_EXPORTS + 1);
        if (n == 2) p32(f + 0x418, G32_PE_MAX_EXPORTS + 1);
        if (n == 3) { p32(f + 0x440, 0x3000); memset(f + 0x600, 'X', 260); }
        if (n == 4) { p32(f + 0x414, 0); p32(f + 0x418, 0); } /* empty exports */
        if (n == 5) { p32(f + OPTIONAL + 96, 0); p32(f + OPTIONAL + 100, 0); }
        if (n == 6) { p32(f + 0x410, 0x10000); } /* not limited to 16-bit ordinal */
        if (n == 7) { /* named export forwarding to a name rather than ordinal */
            memcpy(f + 0x470, "OTHER.Func", 11); p16(f + 0x450, 3);
        }
        if (n == 8) f[0x470] = 0; /* empty forwarder */
        if (n == 9) { /* forwarder string has no NUL within the 260-byte limit */
            p32(f + OPTIONAL + 100, 0x1200); p32(f + 0x434, 0x3000);
            memset(f + 0x600, 'X', 260);
        }
        g32_pe_image image; g32_pe_export found;
        PE_OK(g32_pe_map(s, f, sizeof(f), 0, &image));
        if (n == 6) {
            PE_OK(g32_pe_find_export(s, &image, NULL, 0x10001, &found));
            assert(found.address == PREFERRED + 0x3000 && found.ordinal == 0x10001);
        } else if (n == 7) {
            PE_OK(g32_pe_find_export(s, &image, "Alias", 0, &found));
            assert(found.kind == G32_PE_EXPORT_FORWARDER && !found.address &&
                   strcmp(found.forwarder, "OTHER.Func") == 0);
        } else if (n >= 8) export_rejected(s, &image, NULL, 9, G32_PE_FORMAT);
        else export_rejected(s, &image, "GetTickCount", 0,
                              n == 1 || n == 2 ? G32_PE_UNSUPPORTED :
                              n == 4 || n == 5 ? G32_PE_NOT_FOUND : G32_PE_FORMAT);
        OK(g32_pe_unmap(s, &image));
    }
    /* Named and ordinal exports supply actual synthetic dependency addresses
     * to transactional binding; no hard-coded resolver targets. */
    g32_pe_image dependency, importer;
    PE_OK(g32_pe_map(s, original, sizeof(original), 0x600000, &dependency));
    fixture(f); PE_OK(g32_pe_map(s, f, sizeof(f), 0, &importer));
    OK(g32_protect(s, PREFERRED + 0x2000, G32_PAGE, G32_READ | G32_WRITE));
    export_resolver resolver = { .space = s, .dependency = &dependency };
    PE_OK(g32_pe_bind_imports(s, &importer, resolve_export, &resolver));
    unsigned char slots[8]; OK(g32_read(s, PREFERRED + 0x2150, slots, sizeof(slots)));
    assert(resolver.calls == 2 && u32(slots) == 0x601000 && u32(slots + 4) == 0x603000);
    OK(g32_pe_unmap(s, &importer));
    resolver.calls = 0;
    PE_OK(g32_pe_map_bound(s, f, sizeof(f), 0, resolve_export, &resolver, &importer));
    OK(g32_read(s, PREFERRED + 0x2150, slots, sizeof(slots)));
    assert(resolver.calls == 2 && u32(slots) == 0x601000 && u32(slots + 4) == 0x603000);
    IS(g32_write(s, PREFERRED + 0x2150, slots, sizeof(slots)), G32_ACCESS);
    OK(g32_pe_unmap(s, &importer)); OK(g32_pe_unmap(s, &dependency));
    g32_destroy(s); g32_destroy(other);
    printf("pe32: granule=%zu checked guest-export lookup and binding checks ok\n", granule);
}

static void resolution_rejected(const g32_pe_modules *modules, const char *dll,
                                 const char *name, uint32_t ordinal, g32_pe_result error)
{
    uint32_t address = 0xa5a5a5a5;
    IS(g32_pe_resolve_export(modules, dll, name, ordinal, &address), error);
    assert(address == 0xa5a5a5a5);
    if (ordinal <= UINT16_MAX) {
        uint64_t wide = UINT64_C(0xa5a5a5a5a5a5a5a5);
        assert(!g32_pe_resolve_import((void *)modules, dll, name, (uint16_t)ordinal, &wide));
        assert(wide == UINT64_C(0xa5a5a5a5a5a5a5a5));
    }
}

/* Modify one synthetic EAT entry and its string, restoring READ-only access.
 * Alias and GetTickCount select the SAME export, useful for alias-cycle tests. */
static void forward_to(g32_space *s, const g32_pe_image *image, const char *forwarder)
{
    unsigned char rva[4]; p32(rva, 0x2200);
    OK(g32_protect(s, image->base + 0x2000, G32_PAGE, G32_READ | G32_WRITE));
    OK(g32_write(s, image->base + 0x2028, rva, 4));
    OK(g32_write(s, image->base + 0x2200, forwarder, strlen(forwarder) + 1));
    OK(g32_protect(s, image->base + 0x2000, G32_PAGE, G32_READ));
}

static void module_creation_rejected(g32_space *s, const g32_pe_module *modules,
                                     size_t count, g32_pe_result error)
{
    g32_pe_modules *output = NULL;
    IS(g32_pe_modules_create(s, modules, count, &output), error);
    assert(output == NULL);
}

static void resolution_cases(size_t granule)
{
    g32_space *s, *other;
    OK(g32_create(granule, &s)); OK(g32_create(granule, &other));
    unsigned char f[FILE_SIZE]; export_fixture(f);
    p32(f + OPTIONAL + 100, 0x400); /* Extra room for forwarders. */
    g32_pe_image a, b, importer;
    PE_OK(g32_pe_map(s, f, sizeof(f), 0x600000, &a));
    PE_OK(g32_pe_map(s, f, sizeof(f), 0x700000, &b));
    char mutable_name[] = "KERNEL32.dll";
    g32_pe_image mutable_image = a;
    g32_pe_module entries[] = {
        {mutable_name, &mutable_image}, {"Other.DLL", &b}, {"ModuleAlias", &a}
    };
    g32_pe_modules *modules;
    PE_OK(g32_pe_modules_create(s, entries, 3, &modules));
    mutable_name[0] = 'X'; mutable_image.base = 0; /* Native metadata was copied. */
    uint32_t address;
    PE_OK(g32_pe_resolve_export(modules, "KeRnEl32", "GetTickCount", 0, &address));
    assert(address == a.base + 0x1000);
    PE_OK(g32_pe_resolve_export(modules, "OTHER.dll", NULL, 7, &address));
    assert(address == b.base + 0x3000);
    PE_OK(g32_pe_resolve_export(modules, "KERNEL32", NULL, 9, &address));
    assert(address == b.base + 0x3000); /* Existing OTHER.#7 forwarder. */
    forward_to(s, &a, "oThEr.dLl.GetTickCount"); /* Split at LAST dot. */
    PE_OK(g32_pe_resolve_export(modules, "kernel32.dll", "Alias", 0, &address));
    assert(address == b.base + 0x1000);
    forward_to(s, &b, "ModuleAlias.#7"); /* Multi-hop to data in original module. */
    PE_OK(g32_pe_resolve_export(modules, "kernel32", "GetTickCount", 0, &address));
    assert(address == a.base + 0x3000);
    /* The built-in adapter binds a new image to actual synthetic exports;
     * forwarded and ordinary imports retain final READ-only IAT protection. */
    fixture(f);
    PE_OK(g32_pe_map_bound(s, f, sizeof(f), 0, g32_pe_resolve_import, modules, &importer));
    unsigned char slots[8]; OK(g32_read(s, importer.base + 0x2150, slots, 8));
    assert(u32(slots) == a.base + 0x3000 && u32(slots + 4) == a.base + 0x3000);
    IS(g32_write(s, importer.base + 0x2150, slots, 8), G32_ACCESS);
    OK(g32_pe_unmap(s, &importer));
    resolution_rejected(modules, "absent", "Data", 0, G32_PE_NOT_FOUND);
    resolution_rejected(modules, "other", "data", 0, G32_PE_NOT_FOUND);
    resolution_rejected(modules, "other", NULL, 8, G32_PE_NOT_FOUND);
    resolution_rejected(modules, "other", "", 0, G32_PE_FORMAT);
    resolution_rejected(modules, "dir/other.dll", "Data", 0, G32_PE_FORMAT);
    resolution_rejected(modules, NULL, "Data", 0, G32_PE_FORMAT);
    resolution_rejected(NULL, "other", "Data", 0, G32_PE_FORMAT);
    IS(g32_pe_resolve_export(modules, "other", "Data", 0, NULL), G32_PE_FORMAT);
    assert(!g32_pe_resolve_import(modules, "other", "Data", 0, NULL));

    const char *bad[] = {
        "OTHER", ".Data", "OTHER.", "OTHER.#", "OTHER.#-1", "OTHER.#+7",
        "OTHER.#7x", "OTHER.#4294967296", "OTHER.# 7", "../OTHER.Data",
        "C:OTHER.Data", "dir\\OTHER.Data", "OTHER..Data", "\x80OTHER.Data"
    };
    for (unsigned n = 0; n < sizeof(bad) / sizeof(bad[0]); ++n) {
        forward_to(s, &a, bad[n]);
        resolution_rejected(modules, "kernel32", "Alias", 0, G32_PE_FORMAT);
    }
    forward_to(s, &a, "MISSING.Data");
    resolution_rejected(modules, "kernel32", "Alias", 0, G32_PE_NOT_FOUND);
    forward_to(s, &a, "OTHER.Missing");
    resolution_rejected(modules, "kernel32", "Alias", 0, G32_PE_NOT_FOUND);
    forward_to(s, &a, "OTHER.#0007");
    PE_OK(g32_pe_resolve_export(modules, "kernel32", "Alias", 0, &address));
    assert(address == b.base + 0x3000);
    forward_to(s, &a, "OTHER.GetTickCount");
    forward_to(s, &b, "ModuleAlias.Alias");
    resolution_rejected(modules, "kernel32", "GetTickCount", 0, G32_PE_CYCLE);
    forward_to(s, &a, "ModuleAlias.#6"); /* Module + name/ordinal aliases cycle. */
    resolution_rejected(modules, "kernel32", "Alias", 0, G32_PE_CYCLE);
    /* A cycle must fail map-bound transactionally and preserve dependencies. */
    unsigned char before[0x4000], after[0x4000];
    OK(g32_read(s, a.base, before, sizeof(before)));
    g32_pe_image sentinel, unchanged;
    memset(&sentinel, 0xa5, sizeof(sentinel)); memcpy(&unchanged, &sentinel, sizeof(sentinel));
    IS(g32_pe_map_bound(s, f, sizeof(f), 0, g32_pe_resolve_import, modules, &sentinel), G32_PE_IMPORT);
    assert(!memcmp(&sentinel, &unchanged, sizeof(sentinel)));
    OK(g32_reserve(s, PREFERRED, 0x5000)); OK(g32_release(s, PREFERRED));
    OK(g32_read(s, a.base, after, sizeof(after))); assert(!memcmp(before, after, sizeof(before)));
    forward_to(s, &a, "OTHER.Data");
    OK(g32_protect(s, b.base + 0x3000, G32_PAGE, 0));
    resolution_rejected(modules, "kernel32", "Alias", 0, G32_PE_FORMAT);
    OK(g32_protect(s, b.base + 0x3000, G32_PAGE, G32_READ | G32_WRITE));
    /* Strict full-width forwarded ordinals, including zero and UINT32_MAX. */
    OK(g32_protect(s, b.base + 0x2000, G32_PAGE, G32_READ | G32_WRITE));
    unsigned char word[4]; p32(word, UINT32_MAX - 4);
    OK(g32_write(s, b.base + 0x2010, word, 4));
    forward_to(s, &a, "OTHER.#4294967295");
    PE_OK(g32_pe_resolve_export(modules, "kernel32", "Alias", 0, &address));
    assert(address == b.base + 0x1004);
    p32(word, 0); OK(g32_write(s, b.base + 0x2010, word, 4));
    OK(g32_protect(s, b.base + 0x2000, G32_PAGE, G32_READ));
    forward_to(s, &b, "kernel32.Data"); forward_to(s, &a, "OTHER.#0");
    PE_OK(g32_pe_resolve_export(modules, "kernel32", "Alias", 0, &address));
    assert(address == a.base + 0x3000);
    g32_pe_modules_destroy(modules);
    OK(g32_read(s, a.base, after, 1)); /* Destruction never unmaps dependencies. */

    g32_pe_module invalid[] = {{"OTHER", &a}, {"other.DLL", &b}};
    module_creation_rejected(s, invalid, 2, G32_PE_FORMAT);
    module_creation_rejected(other, invalid, 1, G32_PE_FORMAT);
    module_creation_rejected(s, NULL, 1, G32_PE_FORMAT);
    module_creation_rejected(s, invalid, G32_PE_MAX_MODULES + 1, G32_PE_UNSUPPORTED);
    const char *bad_names[] = {NULL, "", "../other", "dir\\other", "other:", ".dll", "other.", "with space", "\x80"};
    for (unsigned n = 0; n < sizeof(bad_names) / sizeof(bad_names[0]); ++n) {
        invalid[0].name = bad_names[n];
        module_creation_rejected(s, invalid, 1, G32_PE_FORMAT);
    }
    char long_name[261]; memset(long_name, 'x', sizeof(long_name)); long_name[260] = 0;
    invalid[0].name = long_name;
    module_creation_rejected(s, invalid, 1, G32_PE_FORMAT);
    long_name[259] = 0; /* Appending .dll would exceed the bound. */
    module_creation_rejected(s, invalid, 1, G32_PE_FORMAT);
    long_name[255] = 0; /* Longest accepted bare name: 255 + .dll + NUL. */
    PE_OK(g32_pe_modules_create(s, invalid, 1, &modules));
    PE_OK(g32_pe_resolve_export(modules, long_name, "Data", 0, &address));
    assert(address == a.base + 0x3000); g32_pe_modules_destroy(modules);
    invalid[0].name = "OTHER"; invalid[0].image = NULL;
    module_creation_rejected(s, invalid, 1, G32_PE_FORMAT);
    OK(g32_pe_unmap(s, &a)); OK(g32_pe_unmap(s, &b));
    invalid[0].image = &a; /* An unmapped image cannot enter a new table. */
    module_creation_rejected(s, invalid, 1, G32_PE_FORMAT);
    PE_OK(g32_pe_modules_create(s, NULL, 0, &modules));
    resolution_rejected(modules, "other", "Data", 0, G32_PE_NOT_FOUND);
    g32_pe_modules_destroy(modules); g32_pe_modules_destroy(NULL);
    g32_destroy(s); g32_destroy(other);
    printf("pe32: granule=%zu module/forwarder resolution and binding checks ok\n", granule);
}

static void resolution_depth(void)
{
    g32_space *s; OK(g32_create(16384, &s));
    g32_pe_image images[G32_PE_MAX_RESOLVE_DEPTH + 1];
    g32_pe_module entries[G32_PE_MAX_MODULES];
    char names[G32_PE_MAX_MODULES][20];
    unsigned char f[FILE_SIZE]; export_fixture(f); p32(f + OPTIONAL + 100, 0x400);
    for (unsigned n = 0; n < G32_PE_MAX_MODULES; ++n) {
        snprintf(names[n], sizeof(names[n]), "module%u", n);
        entries[n].name = names[n];
        if (n <= G32_PE_MAX_RESOLVE_DEPTH) {
            PE_OK(g32_pe_map(s, f, sizeof(f), 0x600000 + n * G32_GRANULE, &images[n]));
            entries[n].image = &images[n];
        } else entries[n].image = &images[0]; /* Registry capacity uses aliases. */
    }
    g32_pe_modules *modules;
    PE_OK(g32_pe_modules_create(s, entries, G32_PE_MAX_MODULES, &modules));
    for (unsigned n = 0; n + 1 < G32_PE_MAX_RESOLVE_DEPTH; ++n) {
        char forwarder[64]; snprintf(forwarder, sizeof(forwarder), "module%u.Alias", n + 1);
        forward_to(s, &images[n], forwarder);
    }
    uint32_t address;
    PE_OK(g32_pe_resolve_export(modules, names[0], "Alias", 0, &address));
    assert(address == images[G32_PE_MAX_RESOLVE_DEPTH - 1].base + 0x1000);
    char forwarder[64]; snprintf(forwarder, sizeof(forwarder), "module%u.Alias", G32_PE_MAX_RESOLVE_DEPTH);
    forward_to(s, &images[G32_PE_MAX_RESOLVE_DEPTH - 1], forwarder);
    resolution_rejected(modules, names[0], "Alias", 0, G32_PE_UNSUPPORTED);
    g32_pe_modules_destroy(modules);
    for (unsigned n = 0; n <= G32_PE_MAX_RESOLVE_DEPTH; ++n) OK(g32_pe_unmap(s, &images[n]));
    g32_destroy(s);
    puts("pe32: exact forwarder-depth and module-count resource bounds checked");
}

static void mutations(void)
{
    unsigned char original[FILE_SIZE], f[FILE_SIZE]; export_fixture(original);
    g32_space *s;
    OK(g32_create(16384, &s));
    uint32_t random = 0x12345678;
    for (unsigned n = 0; n < 4096; ++n) {
        memcpy(f, original, sizeof(f));
        for (unsigned change = 0; change < 3; ++change) {
            random = random * 1664525u + 1013904223u;
            f[random % sizeof(f)] ^= (unsigned char)(random >> 24);
        }
        /* Bound physical memory in this deterministic mutation test. */
        p32(f + OPTIONAL + 56, 0x5000);
        g32_pe_image image;
        if (g32_pe_map(s, f, sizeof(f), 0x500000, &image) == G32_PE_OK) {
            unsigned calls = 0;
            (void)g32_pe_imports(s, &image, count_import, &calls);
            g32_pe_export found;
            (void)g32_pe_find_export(s, &image, "GetTickCount", 0, &found);
            (void)g32_pe_find_export(s, &image, NULL, 9, &found);
            g32_pe_module entry = {"mutated", &image};
            g32_pe_modules *modules;
            PE_OK(g32_pe_modules_create(s, &entry, 1, &modules));
            uint32_t address;
            (void)g32_pe_resolve_export(modules, "mutated", "Alias", 0, &address);
            (void)g32_pe_resolve_export(modules, "mutated", NULL, 9, &address);
            g32_pe_modules_destroy(modules);
            OK(g32_pe_unmap(s, &image));
        }
        OK(g32_reserve(s, 0x500000, 0x5000)); OK(g32_release(s, 0x500000));
    }
    g32_destroy(s);
    puts("pe32: 4096 deterministic malformed-file mutations ok");
}

static int unresolved_import(void *context, const char *dll, const char *symbol,
                             uint16_t ordinal, uint64_t *address)
{
    (void)dll; (void)symbol; (void)ordinal; (void)address;
    ++*(unsigned *)context;
    return 0; /* No game dependency is supplied by this test. */
}

/* Independent raw-file RVA conversion for the optional private fixtures.
 * This does not call the mapper/parser to obtain the expected export RVAs. */
static const unsigned char *file_rva(const unsigned char *f, size_t size,
                                      uint32_t rva, size_t width)
{
    uint32_t nt = u32(f + 0x3c);
    assert((uint64_t)nt + 24 + 96 <= size);
    const unsigned char *o = f + nt + 24;
    uint32_t headers = u32(o + 60);
    if (rva < headers && width <= (uint64_t)headers - rva) {
        assert((uint64_t)rva + width <= size); return f + rva;
    }
    unsigned count = f[nt + 6] | (unsigned)f[nt + 7] << 8;
    unsigned optional_size = f[nt + 20] | (unsigned)f[nt + 21] << 8;
    const unsigned char *table = o + optional_size;
    assert((uint64_t)(table - f) + count * 40 <= size);
    for (unsigned n = 0; n < count; ++n) {
        const unsigned char *section = table + n * 40;
        uint32_t start = u32(section + 12), raw = u32(section + 16), offset = u32(section + 20);
        if (rva >= start && (uint64_t)rva - start + width <= raw) {
            uint64_t position = (uint64_t)offset + rva - start;
            assert(position + width <= size); return f + position;
        }
    }
    assert(0 && "private fixture RVA has no raw file bytes"); return NULL;
}

static void private_exports(g32_space *s, const g32_pe_image *image,
                            const unsigned char *f, size_t size)
{
    uint32_t optional = u32(f + 0x3c) + 24;
    uint32_t rva = u32(f + optional + 96), extent = u32(f + optional + 100);
    g32_pe_module entry = {"inspected", image};
    g32_pe_modules *modules;
    PE_OK(g32_pe_modules_create(s, &entry, 1, &modules));
    if (!rva) {
        export_rejected(s, image, "CreateInterface", 0, G32_PE_NOT_FOUND);
        resolution_rejected(modules, "INSPECTED.dll", "CreateInterface", 0, G32_PE_NOT_FOUND);
        g32_pe_modules_destroy(modules);
        puts("pe32: raw file has no exports; lookup/resolution report not found"); return;
    }
    const unsigned char *d = file_rva(f, size, rva, 40);
    uint32_t first = u32(d + 16), functions = u32(d + 20), names = u32(d + 24);
    assert(functions <= G32_PE_MAX_EXPORTS && names <= G32_PE_MAX_EXPORTS);
    const unsigned char *eat = file_rva(f, size, u32(d + 28), functions * 4);
    for (uint32_t n = 0; n < functions; ++n) {
        uint32_t target = u32(eat + n * 4);
        if (!target) { export_rejected(s, image, NULL, first + n, G32_PE_NOT_FOUND); continue; }
        g32_pe_export found;
        PE_OK(g32_pe_find_export(s, image, NULL, first + n, &found));
        assert(found.ordinal == first + n);
        if (target >= rva && (uint64_t)target < (uint64_t)rva + extent) {
            size_t capacity = (size_t)((uint64_t)rva + extent - target);
            if (capacity > sizeof(found.forwarder)) capacity = sizeof(found.forwarder);
            const char *forwarder = (const char *)file_rva(f, size, target, capacity);
            assert(memchr(forwarder, 0, capacity));
            assert(found.kind == G32_PE_EXPORT_FORWARDER && !found.address &&
                   strcmp(found.forwarder, forwarder) == 0);
        } else {
            assert(found.kind == G32_PE_EXPORT_ADDRESS && found.address == image->base + target);
            uint32_t address;
            PE_OK(g32_pe_resolve_export(modules, "INSPECTED.dll", NULL, first + n, &address));
            assert(address == image->base + target);
        }
    }
    const unsigned char *name_table = file_rva(f, size, u32(d + 32), names * 4);
    const unsigned char *ordinals = file_rva(f, size, u32(d + 36), names * 2);
    for (uint32_t n = 0; n < names; ++n) {
        uint32_t name_rva = u32(name_table + n * 4);
        char name[260];
        for (unsigned c = 0; c < sizeof(name); ++c) {
            name[c] = (char)*file_rva(f, size, name_rva + c, 1);
            if (!name[c]) break;
            assert(c + 1 < sizeof(name));
        }
        uint32_t index = ordinals[n * 2] | (uint32_t)ordinals[n * 2 + 1] << 8;
        assert(index < functions);
        if (!u32(eat + index * 4)) {
            export_rejected(s, image, name, 0, G32_PE_NOT_FOUND); continue;
        }
        g32_pe_export named, ordinal;
        PE_OK(g32_pe_find_export(s, image, name, 0, &named));
        PE_OK(g32_pe_find_export(s, image, NULL, first + index, &ordinal));
        assert(named.kind == ordinal.kind && named.ordinal == ordinal.ordinal &&
               named.address == ordinal.address && strcmp(named.forwarder, ordinal.forwarder) == 0);
        if (named.kind == G32_PE_EXPORT_ADDRESS) {
            uint32_t address;
            PE_OK(g32_pe_resolve_export(modules, "inspected", name, 0, &address));
            assert(address == image->base + u32(eat + index * 4));
        }
        printf("pe32: raw-file export matches name=%s ordinal=%u rva=%08x\n",
               name, named.ordinal, u32(eat + index * 4));
    }
    g32_pe_modules_destroy(modules);
    printf("pe32: %u ordinal entries and %u named exports match independent raw-file tables; direct targets resolve through module snapshot\n", functions, names);
}

/* PRIVATE layout experiment only: the target is inert readable test data,
 * NOT a Windows API implementation. Never execute any of these IAT entries. */
typedef struct {
    g32_space *space;
    uint32_t base, target;
    unsigned char *expected;
    unsigned inspected, resolved;
} private_layout;

static int placeholder_import(void *context, const char *dll, const char *symbol,
                               uint16_t ordinal, uint64_t *address)
{
    (void)dll; (void)symbol; (void)ordinal;
    private_layout *layout = context;
    ++layout->resolved; *address = layout->target;
    return 1;
}

static int readonly_slot(void *context, const char *dll, const char *symbol,
                         uint16_t ordinal, uint32_t iat)
{
    (void)dll; (void)symbol; (void)ordinal;
    private_layout *layout = context;
    void *loan;
    IS(g32_translate(layout->space, iat, 4, G32_WRITE, &loan), G32_ACCESS);
    if (layout->expected) p32(layout->expected + iat - layout->base, layout->target);
    ++layout->inspected;
    return 0;
}

static void private_image(const char *path)
{
    FILE *file = fopen(path, "rb"); assert(file);
    assert(fseek(file, 0, SEEK_END) == 0);
    long length = ftell(file); assert(length > 0 && length < 128 * 1024 * 1024);
    rewind(file);
    unsigned char *bytes = malloc((size_t)length); assert(bytes);
    assert(fread(bytes, 1, (size_t)length, file) == (size_t)length); fclose(file);
    g32_space *s;
    OK(g32_create(16384, &s));
    const uint32_t placeholder = 0x30000000;
    OK(g32_reserve(s, placeholder, G32_PAGE));
    OK(g32_commit(s, placeholder, G32_PAGE, G32_READ));
    uint32_t optional = u32(bytes + 0x3c) + 24;
    uint32_t preferred = u32(bytes + optional + 28), extent = u32(bytes + optional + 56);
    for (unsigned relocated = 0; relocated < 3; ++relocated) {
        g32_pe_image image;
        if (relocated == 2) {
            OK(g32_reserve(s, preferred, extent));
            OK(g32_commit(s, preferred, G32_PAGE, G32_READ | G32_WRITE));
            unsigned char marker = 0x77; OK(g32_write(s, preferred, &marker, 1));
            PE_OK(g32_pe_map_auto(s, bytes, (size_t)length, preferred, UINT64_C(1) << 32, &image));
            uint32_t expected = (uint32_t)(((uint64_t)preferred + extent + G32_GRANULE - 1) &
                                         ~(uint64_t)(G32_GRANULE - 1));
            assert(image.base == expected && image.relocations);
            /* Separate space, explicit same-base reference: compare every byte,
             * not just entry/export addresses or a handful of relocation slots. */
            g32_space *reference; g32_pe_image explicit_image;
            OK(g32_create(16384, &reference));
            PE_OK(g32_pe_map(reference, bytes, (size_t)length, expected, &explicit_image));
            unsigned char *a = malloc(extent), *b = malloc(extent); assert(a && b);
            OK(g32_read(s, expected, a, extent)); OK(g32_read(reference, expected, b, extent));
            assert(memcmp(a, b, extent) == 0 && image.entry == explicit_image.entry &&
                   image.relocations == explicit_image.relocations);
            free(a); free(b); g32_destroy(reference);
            puts("pe32: automatic collision placement matches explicit same-base mapping byte-for-byte");
        } else {
            PE_OK(g32_pe_map(s, bytes, (size_t)length, relocated ? 0x20000000 : 0, &image));
        }
        unsigned calls = 0;
        PE_OK(g32_pe_imports(s, &image, count_import, &calls));
        unsigned char *before = malloc(image.size), *after = malloc(image.size);
        assert(before && after);
        OK(g32_read(s, image.base, before, image.size));
        private_exports(s, &image, bytes, (size_t)length);
        unsigned unresolved = 0;
        IS(g32_pe_bind_imports(s, &image, unresolved_import, &unresolved), G32_PE_IMPORT);
        assert(unresolved == 1); /* Fully parsed, but deliberately NOT resolved. */
        OK(g32_read(s, image.base, after, image.size));
        assert(memcmp(before, after, image.size) == 0);
        /* A registry containing only the inspected image cannot substitute for
         * missing Windows dependencies; real IAT bytes must remain untouched. */
        g32_pe_module module = {"inspected", &image};
        g32_pe_modules *modules;
        PE_OK(g32_pe_modules_create(s, &module, 1, &modules));
        IS(g32_pe_bind_imports(s, &image, g32_pe_resolve_import, modules), G32_PE_IMPORT);
        g32_pe_modules_destroy(modules);
        OK(g32_read(s, image.base, after, image.size));
        assert(memcmp(before, after, image.size) == 0);
        void *entry;
        OK(g32_translate(s, image.entry, 1, G32_EXEC, &entry));
        printf("pe32: %s base=%08x size=%08x entry=%08x sections=%u relocations=%u imports=%u backing_above_4GiB=%s\n",
               path, image.base, image.size, image.entry, image.sections, image.relocations, calls,
               (uintptr_t)entry > UINT32_MAX ? "yes" : "no");
        puts("pe32: real exports inspected, unresolved import rejected; entire mapped image unchanged");
        private_layout layout = { .space = s, .base = image.base, .target = placeholder,
                                  .expected = before };
        PE_OK(g32_pe_imports(s, &image, readonly_slot, &layout));
        assert(layout.inspected == calls);
        uint32_t base = image.base, image_size = image.size;
        OK(g32_pe_unmap(s, &image));
        g32_pe_image output, sentinel;
        memset(&output, 0xa5, sizeof(output)); memcpy(&sentinel, &output, sizeof(sentinel));
        unresolved = 0;
        g32_pe_result rejected_result = relocated == 2 ?
            g32_pe_map_bound_auto(s, bytes, (size_t)length, preferred, UINT64_C(1) << 32,
                                  unresolved_import, &unresolved, &output) :
            g32_pe_map_bound(s, bytes, (size_t)length, base, unresolved_import, &unresolved, &output);
        IS(rejected_result, G32_PE_IMPORT);
        assert(unresolved == 1 && memcmp(&output, &sentinel, sizeof(output)) == 0);
        OK(g32_reserve(s, base, image_size)); OK(g32_release(s, base));
        if (relocated == 2) {
            PE_OK(g32_pe_map_bound_auto(s, bytes, (size_t)length, preferred, UINT64_C(1) << 32,
                                        placeholder_import, &layout, &image));
            assert(image.base == base);
        } else {
            PE_OK(g32_pe_map_bound(s, bytes, (size_t)length, base, placeholder_import, &layout, &image));
        }
        assert(layout.resolved == calls);
        OK(g32_read(s, base, after, image.size));
        assert(memcmp(before, after, image.size) == 0); /* Only IAT words differ. */
        layout.expected = NULL; layout.inspected = 0;
        PE_OK(g32_pe_imports(s, &image, readonly_slot, &layout)); assert(layout.inspected == calls);
        printf("pe32: private layout only: %u IAT words patched to inert test DATA; final slots read-only; unresolved map rolled back\n", calls);
        OK(g32_pe_unmap(s, &image));
        free(before); free(after);
        if (relocated == 2) {
            unsigned char marker; OK(g32_read(s, preferred, &marker, 1)); assert(marker == 0x77);
            OK(g32_release(s, preferred));
        }
    }
    OK(g32_release(s, placeholder));
    g32_destroy(s); free(bytes);
}

int main(int argc, char **argv)
{
    cases(0); cases(16384); cases(65536);
    relocations_and_imports();
    auto_mapping_cases(0); auto_mapping_cases(16384); auto_mapping_cases(65536);
    binding_cases(0); binding_cases(16384); binding_cases(65536);
    bound_mapping_cases(0); bound_mapping_cases(16384); bound_mapping_cases(65536);
    export_cases(0); export_cases(16384); export_cases(65536);
    resolution_cases(0); resolution_cases(16384); resolution_cases(65536);
    resolution_depth();
    mutations();
    for (int n = 1; n < argc; ++n) private_image(argv[n]);
    puts("pe32: synthetic dependencies bound; private IAT patches are inert layout tests; no game APIs or guest execution");
    return 0;
}
