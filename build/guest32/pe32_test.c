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

static void mutations(void)
{
    unsigned char original[FILE_SIZE], f[FILE_SIZE]; fixture(original);
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
            OK(g32_pe_unmap(s, &image));
        }
        OK(g32_reserve(s, 0x500000, 0x5000)); OK(g32_release(s, 0x500000));
    }
    g32_destroy(s);
    puts("pe32: 4096 deterministic malformed-file mutations ok");
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
    for (unsigned relocated = 0; relocated < 2; ++relocated) {
        g32_pe_image image;
        PE_OK(g32_pe_map(s, bytes, (size_t)length, relocated ? 0x20000000 : 0, &image));
        unsigned calls = 0;
        PE_OK(g32_pe_imports(s, &image, count_import, &calls));
        void *entry;
        OK(g32_translate(s, image.entry, 1, G32_EXEC, &entry));
        printf("pe32: %s base=%08x size=%08x entry=%08x sections=%u relocations=%u imports=%u backing_above_4GiB=%s\n",
               path, image.base, image.size, image.entry, image.sections, image.relocations, calls,
               (uintptr_t)entry > UINT32_MAX ? "yes" : "no");
        OK(g32_pe_unmap(s, &image));
    }
    g32_destroy(s); free(bytes);
}

int main(int argc, char **argv)
{
    cases(0); cases(16384); cases(65536);
    relocations_and_imports(); mutations();
    for (int n = 1; n < argc; ++n) private_image(argv[n]);
    puts("pe32: image materialization only; no imports bound or guest instructions executed");
    return 0;
}
