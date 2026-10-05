/* Production guest placement and Wine relocation kernel on real mappings.
 * View tree/page metadata are mocked; the PE section mapper/server are not run.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define IMAGE_TEST_ENTRY image_baseline_main
#include "image_test.c"
#include <string.h>
#define max(a,b) ((a) > (b) ? (a) : (b))
#define min(a,b) ((a) < (b) ? (a) : (b))
#define IMAGE_FILE_RELOCS_STRIPPED 1
#define IMAGE_FILE_DLL 0x2000
#define IMAGE_FLAGS_ImageMappedFlat 8
#define IMAGE_FLAGS_ImageDynamicallyRelocated 4
#define STATUS_INVALID_IMAGE_FORMAT 6
#define STATUS_IMAGE_NOT_AT_BASE 7
#define IMAGE_REL_BASED_ABSOLUTE 0
#define IMAGE_REL_BASED_HIGH 1
#define IMAGE_REL_BASED_LOW 2
#define IMAGE_REL_BASED_HIGHLOW 3
#define IMAGE_REL_BASED_THUMB_MOV32 7
#define IMAGE_REL_BASED_DIR64 10
#define LOWORD(x) ((uint16_t)(x))
#define HIWORD(x) ((uint16_t)((uint64_t)(x) >> 16))
#define MAKELONG(a,b) ((uint32_t)(a) | ((uint32_t)(b) << 16))
#define FIXME(...) ((void)0)
typedef uint16_t WORD, USHORT;
typedef uint32_t DWORD;
typedef int64_t INT64;
typedef intptr_t INT_PTR;
typedef struct { DWORD VirtualAddress, Size; } IMAGE_DATA_DIRECTORY;
typedef struct { DWORD VirtualAddress, SizeOfBlock; } IMAGE_BASE_RELOCATION;
#include "image_reloc.h"
#include "wow64_placement.h"

static void reject_placement(uintptr_t base, struct pe_image_info *image, size_t size,
                             uint64_t low, uint64_t high, int expected)
{
    struct file_view *out = (void *)1;
    struct pe_image_info saved = *image;
    int count = descriptor_count;
    assert(ios_wow64_place_image(base, image, size, low, high, &out) == expected);
    assert(out == (void *)1 && !memcmp(&saved, image, sizeof(saved)) && descriptor_count == count);
    if (ios_wow64_valid_base(base)) check_cover(base);
}
static void relocations(void *host)
{
    char *ptr = host;
    IMAGE_DATA_DIRECTORY dir = {0x8000, 12};
    IMAGE_BASE_RELOCATION *rel = (void *)(ptr + dir.VirtualAddress);
    USHORT *entry = (void *)(rel + 1);
    *rel = (IMAGE_BASE_RELOCATION){0x1000, 12};
    entry[0] = (IMAGE_REL_BASED_HIGHLOW << 12) | 3; /* unaligned x86 target */
    entry[1] = 0;
    uint32_t value = 0x4017d1, actual;
    memcpy(ptr + 0x1003, &value, 4);
    assert(!ios_wow64_relocate_image(ptr, 0x10000, &dir, 0x400000, 0x60000000));
    memcpy(&actual, ptr + 0x1003, 4);
    assert(actual == 0x600017d1); /* ONLY guest delta, never the high host base */
    assert(!ios_wow64_relocate_image(ptr, 0x10000, &dir, 0x60000000, 0x400000));
    memcpy(&actual, ptr + 0x1003, 4);
    assert(actual == value);
    value = 0xfffffff0;
    memcpy(ptr + 0x1003, &value, 4);
    assert(!ios_wow64_relocate_image(ptr, 0x10000, &dir, 0x400000, 0x410000));
    memcpy(&actual, ptr + 0x1003, 4);
    assert(actual == 0xfff0); /* modulo-2^32, no signed overflow */
    entry[0] = (IMAGE_REL_BASED_HIGH << 12) | 1;
    entry[1] = (IMAGE_REL_BASED_LOW << 12) | 5;
    uint16_t hi = 0xffff, lo = 0xfffe, result;
    memcpy(ptr + 0x1001, &hi, 2); memcpy(ptr + 0x1005, &lo, 2);
    assert(!ios_wow64_relocate_image(ptr, 0x10000, &dir, 0x400000, 0x410002));
    memcpy(&result, ptr + 0x1001, 2); assert(!result);
    memcpy(&result, ptr + 0x1005, 2); assert(!result);
    assert(!ios_wow64_relocate_image(ptr, 0x10000, NULL, 0x400000, 0x400000));
    assert(ios_wow64_relocate_image(ptr, 0x10000, NULL, 0x400000, 0x410000) == STATUS_CONFLICTING_ADDRESSES);
    /* Every malformed directory fails before the first valid target changes. */
    entry[0] = (IMAGE_REL_BASED_HIGHLOW << 12) | 3;
    value = 0x4017d1;
    memcpy(ptr + 0x1003, &value, 4);
    for (unsigned int fault = 0; fault < 12; ++fault)
    {
        IMAGE_DATA_DIRECTORY bad = dir;
        *rel = (IMAGE_BASE_RELOCATION){0x1000, 12};
        entry[1] = 0;
        switch (fault)
        {
        case 0: bad.Size = 7; break;
        case 1: bad.Size = 0xffff; break;
        case 2: bad.VirtualAddress = 0xffff; break;
        case 3: rel->SizeOfBlock = 0; break;
        case 4: rel->SizeOfBlock = 10; break;
        case 5: rel->SizeOfBlock = 16; break;
        case 6: rel->VirtualAddress = 0x10000; break;
        case 7: entry[1] = IMAGE_REL_BASED_DIR64 << 12; break;
        case 8: entry[1] = IMAGE_REL_BASED_THUMB_MOV32 << 12; break;
        case 9: rel->VirtualAddress = 0xf000; entry[1] = (IMAGE_REL_BASED_HIGHLOW << 12) | 0xfff; break;
        case 10: rel->VirtualAddress = 0x8000; break; /* metadata self-modification */
        case 11: bad.VirtualAddress++; break; /* unaligned header */
        }
        assert(ios_wow64_relocate_image(ptr, 0x10000, &bad, 0x400000, 0x410000) == STATUS_INVALID_IMAGE_FORMAT);
        memcpy(&actual, ptr + 0x1003, 4); assert(actual == value);
    }
    /* A bad later block must not leave the earlier valid target relocated. */
    *rel = (IMAGE_BASE_RELOCATION){0x1000, 12};
    entry[0] = (IMAGE_REL_BASED_HIGHLOW << 12) | 3; entry[1] = 0;
    IMAGE_BASE_RELOCATION *second = (void *)(ptr + dir.VirtualAddress + 12);
    USHORT *second_entry = (void *)(second + 1);
    *second = (IMAGE_BASE_RELOCATION){0x2000, 12};
    second_entry[0] = IMAGE_REL_BASED_DIR64 << 12; second_entry[1] = 0;
    dir.Size = 24;
    assert(ios_wow64_relocate_image(ptr, 0x10000, &dir, 0x400000, 0x410000) == STATUS_INVALID_IMAGE_FORMAT);
    memcpy(&actual, ptr + 0x1003, 4); assert(actual == value);
    second_entry[0] = IMAGE_REL_BASED_HIGHLOW << 12;
    memcpy(ptr + 0x2000, &value, 4);
    assert(!ios_wow64_relocate_image(ptr, 0x10000, &dir, 0x400000, 0x410000));
    memcpy(&actual, ptr + 0x1003, 4); assert(actual == value + 0x10000);
    memcpy(&actual, ptr + 0x2000, 4); assert(actual == value + 0x10000);
    /* Native DIR64 behavior in the moved Wine kernel is still available. */
    second_entry[0] = IMAGE_REL_BASED_DIR64 << 12;
    int64_t native = INT64_C(0x100400000);
    memcpy(ptr + 0x2000, &native, 8);
    assert(process_relocation_block(ptr + 0x2000, second, 0x10000));
    memcpy(&native, ptr + 0x2000, 8); assert(native == INT64_C(0x100410000));
}
int main(void)
{
    assert(!image_baseline_main());
    uintptr_t a = reserve(), b = reserve();
    struct pe_image_info image = {0x400000, 0x60000000, IMAGE_FILE_MACHINE_I386,
                                 IMAGE_FILE_LARGE_ADDRESS_AWARE | IMAGE_FILE_DLL,
                                 IMAGE_FLAGS_ImageDynamicallyRelocated};
    struct file_view *va, *vb;
    assert(ios_wow64_place_image(a, NULL, 0x10000, 0, 0, &va) == STATUS_INVALID_PARAMETER);
    assert(ios_wow64_place_image(a, &image, 0x10000, 0, 0, NULL) == STATUS_INVALID_PARAMETER);
    reject_placement(0, &image, 0x10000, 0, 0, STATUS_INVALID_PARAMETER);
    reject_placement(a, &image, SIZE_MAX, 0, 0, STATUS_INVALID_PARAMETER);
    reject_placement(a, &image, 0x10000, 0x80000000, 0x7fffffff, STATUS_CONFLICTING_ADDRESSES);
    assert(!ios_wow64_place_image(a, &image, 0x10000, 0, 0, &va));
    assert(image.base == 0x400000 && image.map_addr == 0x60000000 && va->base == (void *)(a + image.map_addr));
    assert(!ios_wow64_place_image(b, &image, 0x10000, 0, 0, &vb));
    relocations(va->base);
    assert(!*(uint32_t *)vb->base);
    /* Occupied server suggestion falls back to preferred; an occupied
     * preferred base then finds the highest local 64K-aligned hole. */
    image.map_addr = 0x60000000;
    assert(!ios_wow64_place_image(a, &image, 0x10000, 0, 0, &va));
    assert(image.map_addr == 0x400000);
    image.map_addr = 0x60000000;
    assert(!ios_wow64_place_image(a, &image, 0x10000, 0, 0, &va));
    assert(image.map_addr == 0xffff0000 && image.base == 0x400000);
    /* ASLR hints above 4G/unaligned are ignored, not truncated. Non-DLL
     * collisions use bottom-up placement and respect inclusive caller bounds. */
    image.image_charact = 0;
    image.map_addr = UINT64_C(0x10060000000);
    assert(!ios_wow64_place_image(a, &image, 0x10000, 0x100000, 0x11ffff, &va));
    assert(image.map_addr == 0x100000);
    image.map_addr = 0x100001;
    assert(!ios_wow64_place_image(a, &image, 0x10000, 0x100000, 0x11ffff, &va));
    assert(image.map_addr == 0x110000);
    reject_placement(a, &image, 0x10000, 0x100000, 0x11ffff, STATUS_CONFLICTING_ADDRESSES);
    /* Stripped and flat images never move, even with an ASLR flag. */
    image.image_charact = IMAGE_FILE_RELOCS_STRIPPED;
    reject_placement(a, &image, 0x10000, 0, 0, STATUS_CONFLICTING_ADDRESSES);
    image.image_charact = 0; image.image_flags |= IMAGE_FLAGS_ImageMappedFlat;
    reject_placement(a, &image, 0x10000, 0, 0, STATUS_CONFLICTING_ADDRESSES);
    image.image_flags = IMAGE_FLAGS_ImageDynamicallyRelocated;
    image.map_addr = 0x200000;
    fail_after = 0;
    reject_placement(a, &image, 0x10000, 0, 0, STATUS_NO_MEMORY);
    fail_after = -1; fail_protect = 1;
    reject_placement(a, &image, 0x10000, 0, 0, STATUS_ACCESS_DENIED);
    fail_protect = 0;
    /* Preferred validation and rounded 2G/4G end bounds. */
    image.base = 0x80000000;
    reject_placement(a, &image, 0x10000, 0, 0, STATUS_INVALID_PARAMETER);
    image.base = 0x7fff0000; image.map_addr = 0;
    reject_placement(a, &image, 0x10001, 0, 0, STATUS_INVALID_PARAMETER);
    assert(!ios_wow64_place_image(a, &image, 0x10000, 0, 0, &va));
    image.base = 0x400000;
    image.image_charact = IMAGE_FILE_LARGE_ADDRESS_AWARE | IMAGE_FILE_DLL;
    image.map_addr = 0;
    assert(!ios_wow64_place_image(a, &image, 0x10000, 0, UINT64_MAX, &va));
    assert(image.map_addr == 0xfffe0000);
    assert(ios_wow64_mapped_image_status(va, STATUS_IMAGE_NOT_AT_BASE) == STATUS_SUCCESS);
    assert(ios_wow64_mapped_image_status(va, STATUS_NO_MEMORY) == STATUS_NO_MEMORY);
    struct file_view native = {0};
    assert(ios_wow64_mapped_image_status(&native, STATUS_IMAGE_NOT_AT_BASE) == STATUS_IMAGE_NOT_AT_BASE);
    assert(!ios_wow64_rollback_image(va));
    image.map_addr = 0xfffe0000;
    assert(!ios_wow64_place_image(a, &image, 0x10000, 0, 0, &va));
    assert(image.map_addr == 0xfffe0000 && !*(uint32_t *)va->base);
    check_cover(a); check_cover(b); check_guard(a); check_guard(b);
    ios_wow64_delete_views(a); check_cover(b); ios_wow64_delete_views(b);
    assert(!descriptor_count);
    puts("WoW64 guest placement: PASS (ASLR hints, gap search, limits, fail-closed relocation, Wine kernel, no double relocation)");
    return 0;
}
