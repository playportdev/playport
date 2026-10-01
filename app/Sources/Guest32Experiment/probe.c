/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "guest32.h"
#include "guest32_probe.h"
#include <unistd.h>

/* A failed check short-circuits the probe; native VM failures poison a space,
 * so it must not be reused. Always release both windows before returning. */
#define CHECK(expression) do { ++report.checks; if (!(expression)) { ++report.failures; goto done; } } while (0)

g32_probe_report g32_probe_native(void)
{
    g32_probe_report report = {0};
    g32_space *a = NULL, *b = NULL;
    unsigned char marker = 0x5a, output = 0, pair[2] = {1, 2};
    void *host = NULL;
    uint32_t guest = 0;
    const uint32_t image = 0x400000;
    long page = sysconf(_SC_PAGESIZE);
    CHECK(page > 0);
    report.host_page = (uint64_t)page;
    CHECK(g32_create(0, &a) == G32_OK);
    report.backing_a = g32_backing_base(a);
    CHECK(g32_create(0, &b) == G32_OK);
    report.backing_b = g32_backing_base(b);
    CHECK(report.backing_a >= (UINT64_C(1) << 32) && report.backing_b >= (UINT64_C(1) << 32));
    CHECK(report.backing_a != report.backing_b);
    CHECK(g32_translate(a, 0, 1, G32_READ, &host) == G32_RANGE);
    CHECK(g32_reserve(a, image, 0x5c000) == G32_OK);
    CHECK(g32_commit(a, image, 3 * G32_PAGE, G32_READ | G32_WRITE | G32_EXEC) == G32_OK);
    CHECK(g32_write(a, image, &marker, 1) == G32_OK);
    CHECK(g32_fetch(a, image, &output, 1) == G32_OK && output == marker);
    CHECK(g32_translate(a, image, 1, G32_READ, &host) == G32_OK);
    CHECK((uintptr_t)host == report.backing_a + image);
    CHECK(g32_reverse(a, host, 1, G32_READ, &guest) == G32_OK && guest == image);
    CHECK(g32_reverse(b, host, 1, G32_READ, &guest) == G32_RANGE);
    CHECK(g32_read(b, image, &output, 1) == G32_ACCESS);
    CHECK(g32_protect(a, image + G32_PAGE, G32_PAGE, 0) == G32_OK);
    CHECK(g32_read(a, image + G32_PAGE, &output, 1) == G32_ACCESS);
    CHECK(g32_write(a, image + G32_PAGE - 1, pair, 2) == G32_ACCESS);
    CHECK(g32_read(a, image + G32_PAGE - 1, &output, 1) == G32_OK && output == 0);
    CHECK(g32_read(a, image, &output, 1) == G32_OK && output == marker);
    CHECK(g32_write(a, image + 2 * G32_PAGE, &marker, 1) == G32_OK);
    CHECK(g32_decommit(a, image, G32_PAGE) == G32_OK);
    CHECK(g32_read(a, image + 2 * G32_PAGE, &output, 1) == G32_OK && output == marker);
    CHECK(g32_commit(a, image, G32_PAGE, G32_READ | G32_WRITE) == G32_OK);
    CHECK(g32_read(a, image, &output, 1) == G32_OK && output == 0);
    CHECK(g32_reserve(a, 0xffff0000u, 0x10000) == G32_OK);
    CHECK(g32_commit(a, 0xfffff000u, G32_PAGE, G32_READ | G32_WRITE) == G32_OK);
    CHECK(g32_write(a, UINT32_MAX, &marker, 1) == G32_OK);
    CHECK(g32_read(a, UINT32_MAX, &output, 1) == G32_OK && output == marker);
    CHECK(g32_write(a, UINT32_MAX, pair, 2) == G32_RANGE);
    CHECK(g32_release(a, 0xffff0000u) == G32_OK);
    CHECK(g32_release(a, image) == G32_OK);
    CHECK(g32_read(a, image, &output, 1) == G32_ACCESS);
    CHECK(g32_reserve(a, image, G32_PAGE) == G32_OK);
    CHECK(g32_commit(a, image, G32_PAGE, G32_READ) == G32_OK);
    CHECK(g32_read(a, image, &output, 1) == G32_OK && output == 0);
done:
    g32_destroy(a);
    g32_destroy(b);
    return report;
}
