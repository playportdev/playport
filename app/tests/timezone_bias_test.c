/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * timezone_bias_test.c — timezone_bias.c on the Linux host (pp test).
 *
 * For each zone and date: the bias equals the zone's UTC offset, negated, in
 * 100 ns units, and system time minus it gives the local time libc reports
 * (Windows' contract: RtlSystemTimeToLocalTime subtracts KUSER_SHARED_DATA's
 * TimeZoneBias). The negative control is the iOS wineserver's old value, 0
 * (UTC), which is wrong anywhere but UTC (PLA-401).
 */
#include "timezone_bias.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

#define TICKS 10000000LL
#define OLD_IOS_BIAS 0LL   /* fd_ios.c never published it: the page's initial zero */

/* 2026-01-15 12:00 UTC and 2026-07-15 12:00 UTC */
static const time_t WINTER = 1768478400;
static const time_t SUMMER = 1784116800;

static long long bias_in(const char *zone, time_t now)
{
    setenv("TZ", zone, 1);
    tzset();
    return pp_timezone_bias(now);
}

/* Local time computed the Windows way (UTC minus the bias) is libc's local time. */
static void expect(const char *zone, time_t now, long long want_minutes)
{
    long long bias = bias_in(zone, now);
    struct tm local;
    localtime_r(&now, &local);
    time_t local_as_utc = timegm(&local);   /* the local fields, read as if UTC */
    printf("%-20s %lld: bias %lld min (want %lld)\n", zone, (long long)now, -bias / TICKS / 60, want_minutes);
    CHECK(bias == -want_minutes * 60 * TICKS);
    CHECK((long long)now - bias / TICKS == (long long)local_as_utc);
}

int main(void)
{
    expect("UTC", WINTER, 0);
    expect("UTC", SUMMER, 0);
    expect("Europe/Berlin", WINTER, 60);       /* CET */
    expect("Europe/Berlin", SUMMER, 120);      /* CEST */
    expect("Asia/Kolkata", WINTER, 330);       /* half-hour zone, no DST */
    expect("Asia/Kolkata", SUMMER, 330);
    expect("America/New_York", WINTER, -300);  /* west of UTC: a positive bias */
    expect("America/New_York", SUMMER, -240);
    expect("Australia/Adelaide", SUMMER, 570); /* half-hour zone, southern winter */
    expect("Australia/Adelaide", WINTER, 630); /* and its daylight time */

    /* Negative control: the old constant is right in UTC only. */
    CHECK(bias_in("UTC", SUMMER) == OLD_IOS_BIAS);
    CHECK(bias_in("Europe/Berlin", SUMMER) != OLD_IOS_BIAS);
    CHECK(bias_in("Asia/Kolkata", WINTER) != OLD_IOS_BIAS);

    printf(failures ? "timezone_bias_test: %d failure(s)\n" : "timezone_bias_test: ok\n", failures);
    return failures ? 1 : 0;
}
