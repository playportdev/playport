/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * timezone_bias — KUSER_SHARED_DATA.TimeZoneBias for the iOS wineserver.
 *
 * Windows' local time is the system time minus this bias (ntdll
 * RtlSystemTimeToLocalTime reads it through SystemTimeOfDayInformation), and
 * GetTimeZoneInformation describes the same zone. Upstream wineserver
 * recomputes it in set_user_shared_data_time (server/fd.c); Madeira's iOS
 * wineserver does not, because gmtime/localtime/mktime take libc's time zone
 * lock in a process every guest thread shares (fd_ios.c), so it stayed 0 and
 * GetLocalTime returned UTC while the zone said otherwise (PLA-401). The host
 * computes it here once, before the wineserver thread or any guest thread
 * exists, and hands it to the server (patches/madeira-unix 0159), which
 * publishes it when it creates the shared page.
 */

#ifndef TIMEZONE_BIAS_H
#define TIMEZONE_BIAS_H

#include <time.h>

/* UTC minus local time at `now`, in 100 ns units, as upstream's
 * set_user_shared_data_time computes it (including its daylight-saving
 * adjustment): 0 in UTC, -36000000000 in CET, -72000000000 in CEST,
 * -198000000000 in India. Reads the process's zone (TZ, else the system's). */
long long pp_timezone_bias(time_t now);

#endif
