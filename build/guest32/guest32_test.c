/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "guest32.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define OK(call) assert((call) == G32_OK)
#define IS(call, error) assert((call) == (error))

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
    exercise(0);
    exercise(16384);
    exercise(65536);
    puts("guest32: memory contract only; no guest instructions executed");
    return 0;
}
