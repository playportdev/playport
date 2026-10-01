/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * session_protocol_test.c — session_protocol.h on the Linux host (pp test):
 * the request validator the session root runs before it starts anything, and
 * the control validator it runs before it pauses, resumes or closes the title.
 */
#include "session_protocol.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static uint32_t pack(char *out, const char *const *s, int n)
{
    uint32_t at = 0;
    for (int i = 0; i < n; i++) {
        size_t len = strlen(s[i]) + 1;
        memcpy(out + at, s[i], len);
        at += (uint32_t)len;
    }
    return at;
}

int main(void)
{
    char buf[512];
    const char *ok[] = { "C:\\Games\\T\\t.exe", "C:\\Games\\T", "-a", "b c", "SteamAppId=367520" };
    uint32_t n = pack(buf, ok, 5);
    pp_session_request r = { PP_SESSION_MAGIC, 1, PP_REQUEST_LAUNCH, n, 2, 1 };
    CHECK(pp_session_request_valid(&r, buf, n));

    /* the length, counts, magic and sequence must all agree */
    pp_session_request bad = r;
    bad.length = n - 1;
    CHECK(!pp_session_request_valid(&bad, buf, n - 1));   /* the last string runs past the end */
    bad = r; bad.argc = 3;
    CHECK(!pp_session_request_valid(&bad, buf, n));       /* one string too few */
    bad = r; bad.argc = 1;
    CHECK(!pp_session_request_valid(&bad, buf, n));       /* "b c" read as a variable: no '=' */
    bad = r; bad.magic ^= 1;
    CHECK(!pp_session_request_valid(&bad, buf, n));
    bad = r; bad.sequence = 0;
    CHECK(!pp_session_request_valid(&bad, buf, n));
    bad = r; bad.kind = 9;
    CHECK(!pp_session_request_valid(&bad, buf, n));
    bad = r; bad.envc = PP_SESSION_MAX_ENV + 1;
    CHECK(!pp_session_request_valid(&bad, buf, n));
    CHECK(!pp_session_request_valid(&r, NULL, n));

    /* trailing bytes after the last string */
    buf[n] = 'x';
    CHECK(!pp_session_request_valid(&r, buf, n + 1));

    /* no executable, no directory, a variable with no name */
    const char *noexe[] = { "", "C:\\" };
    n = pack(buf, noexe, 2);
    pp_session_request e = { PP_SESSION_MAGIC, 2, PP_REQUEST_LAUNCH, n, 0, 0 };
    CHECK(!pp_session_request_valid(&e, buf, n));
    const char *nodir[] = { "C:\\t.exe", "" };
    n = pack(buf, nodir, 2);
    e.length = n;
    CHECK(!pp_session_request_valid(&e, buf, n));
    const char *noname[] = { "C:\\t.exe", "C:\\", "=x" };
    n = pack(buf, noname, 3);
    e.length = n; e.envc = 1;
    CHECK(!pp_session_request_valid(&e, buf, n));
    const char *empty_value[] = { "C:\\t.exe", "C:\\", "X=" };
    n = pack(buf, empty_value, 3);
    e.length = n;
    CHECK(pp_session_request_valid(&e, buf, n));

    /* controls: a known kind, a sequence, an arg only for CLOSE and within its bound */
    pp_session_control c = { PP_SESSION_MAGIC, 3, PP_CONTROL_PAUSE, 0 };
    CHECK(pp_session_control_valid(&c, sizeof(c)));
    CHECK(!pp_session_control_valid(&c, sizeof(c) - 1));
    CHECK(!pp_session_control_valid(NULL, sizeof(c)));
    c.kind = PP_CONTROL_RESUME;
    CHECK(pp_session_control_valid(&c, sizeof(c)));
    c.arg = 5;
    CHECK(!pp_session_control_valid(&c, sizeof(c)));    /* only CLOSE waits */
    c.kind = PP_CONTROL_CLOSE; c.arg = 10000;
    CHECK(pp_session_control_valid(&c, sizeof(c)));
    c.arg = PP_CONTROL_MAX_WAIT_MS + 1;
    CHECK(!pp_session_control_valid(&c, sizeof(c)));
    c.arg = 0; c.kind = PP_REQUEST_LAUNCH;
    CHECK(!pp_session_control_valid(&c, sizeof(c)));   /* a launch is not a control */
    c.kind = PP_CONTROL_PAUSE; c.sequence = 0;
    CHECK(!pp_session_control_valid(&c, sizeof(c)));
    c.sequence = 1; c.magic = 0;
    CHECK(!pp_session_control_valid(&c, sizeof(c)));

    printf("%s\n", failures ? "session protocol: FAILED" : "session protocol: ok");
    return failures != 0;
}
