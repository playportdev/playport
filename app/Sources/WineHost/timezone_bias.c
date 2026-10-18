/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * timezone_bias — see include/timezone_bias.h.
 *
 * Plain POSIX C with no Apple headers, so the host C tests (`pp test`, app/tests)
 * can build and exercise it on the Linux host. The reentrant gmtime_r and
 * localtime_r keep it off libc's shared static struct tm.
 */

#include "timezone_bias.h"

#define TICKS_PER_SEC 10000000LL

long long pp_timezone_bias(time_t now)
{
    struct tm tm, tm1, tm2;
    long long bias;

    tzset();
    if (!gmtime_r(&now, &tm)) return 0;
    /* UTC's fields read as local standard time (gmtime's tm_isdst is 0). */
    bias = (long long)(mktime(&tm) - now);
    if (!localtime_r(&now, &tm)) return bias * TICKS_PER_SEC;
    if (tm.tm_isdst > 0) {
        tm1 = tm2 = tm;
        tm1.tm_isdst = 0;
        tm2.tm_isdst = 1;
        bias += mktime(&tm1) < mktime(&tm2) ? 3600 : -3600;
    }
    return bias * TICKS_PER_SEC;
}
