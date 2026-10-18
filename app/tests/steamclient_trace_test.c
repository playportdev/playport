/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * steamclient_trace_test.c — the steamclient shim's per-call trace
 * (app/SteamClientShim/steamclient_trace.h) on the Linux host (pp test):
 * what a line shows of each kind of result, what it never shows (names,
 * SteamIDs, ticket handles' owners), which arguments appear, the bound on a
 * line's length and the policy that keeps the log small.
 */
#include "../SteamClientShim/steamclient_trace.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static const char *result_of(const char *method, uint64_t r, const void *hidden)
{
    static pp_tr_line l;
    pp_tr_reset(&l);
    pp_tr_result(&l, pp_tr_kind_of(method), r, hidden);
    return l.text;
}

int main(void)
{
    static const char persona[] = "Jane Example";
    static const char language[] = "english";
    uint64_t steam_id = 76561198000000042ull, none = 0;
    pp_tr_line l;

    /* Names are never shown, only their length. */
    CHECK(strcmp(result_of("GetPersonaName", (uint64_t)(uintptr_t)persona, NULL), "len=12") == 0);
    CHECK(strstr(result_of("GetPersonaName", (uint64_t)(uintptr_t)persona, NULL), "Jane") == NULL);
    CHECK(pp_tr_kind_of("GetFriendPersonaName") == 'S' && pp_tr_kind_of("GetPlayerNickname") == 'S');
    /* SteamIDs: set or zero, never the number. */
    CHECK(strcmp(result_of("GetSteamID", 0, &steam_id), "set") == 0);
    CHECK(strcmp(result_of("GetAppOwner", 0, &none), "zero") == 0);
    CHECK(strstr(result_of("GetSteamID", 0, &steam_id), "7656") == NULL);
    /* A short string is shown, sanitized and cut. */
    CHECK(strcmp(result_of("GetCurrentGameLanguage", (uint64_t)(uintptr_t)language, NULL), "\"english\"") == 0);
    CHECK(strcmp(result_of("GetIPCountry", (uint64_t)(uintptr_t)"", NULL), "\"\"") == 0);
    CHECK(strcmp(result_of("GetIPCountry", (uint64_t)(uintptr_t)"a\"b\nc", NULL), "\"a?b?c\"") == 0);
    CHECK(strcmp(result_of("GetSteamUILanguage", 0, NULL), "null") == 0);
    CHECK(strstr(result_of("GetAvailableGameLanguages", (uint64_t)(uintptr_t)"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", NULL),
                 "...\"") != NULL);
    /* Numbers by kind: a bool's low byte, a signed int, a call handle, an object, nothing. */
    CHECK(strcmp(result_of("BIsSubscribedApp", 0x101, NULL), "1") == 0);
    CHECK(strcmp(result_of("GetAPICallFailureReason", 0xffffffffu, NULL), "-1") == 0);
    CHECK(strcmp(result_of("RequestEncryptedAppTicket", 1ull << 40, NULL), "1099511627776") == 0);
    CHECK(strcmp(result_of("GetISteamApps", 0x1234, NULL), "obj") == 0);
    CHECK(strcmp(result_of("RunFrame", 99, NULL), "-") == 0);
    CHECK(pp_tr_kind_of("SomethingNew") == 'u');   /* not listed: a uint32 */

    /* Arguments: app ids and call handles only; UserHasLicenseForApp's SteamID is not shown. */
    pp_tr_reset(&l);
    CHECK(pp_tr_args(&l, "UserHasLicenseForApp", steam_id, 1174180, 0) == 1 && strcmp(l.text, "app=1174180") == 0);
    pp_tr_reset(&l);
    CHECK(pp_tr_args(&l, "GetAPICallResult", 7, 0, 154) == 2 && strcmp(l.text, "call=7 cb=154") == 0);
    pp_tr_reset(&l);
    CHECK(pp_tr_args(&l, "GetAuthSessionTicket", 0x7000, 1024, 0) == 0 && l.text[0] == 0);
    pp_tr_reset(&l);
    CHECK(pp_tr_args(&l, "BIsDlcInstalled", 1404210, 0, 0) == 1 && strcmp(l.text, "app=1404210") == 0);

    /* A line never runs past the log block. */
    pp_tr_reset(&l);
    for (int i = 0; i < 100; i++) { pp_tr_str(&l, "ISteamApps008.BIsSubscribedApp"); pp_tr_u64(&l, ~0ull); }
    CHECK(l.n == PP_SC_LOG_MAX - 1 && l.text[PP_SC_LOG_MAX - 1] == 0 && strlen(l.text) == PP_SC_LOG_MAX - 1);

    /* The policy: the first calls, then changes only, within the caps. */
    CHECK(pp_tr_should_log(1, 0, 0, 0));
    CHECK(pp_tr_should_log(PP_TR_FIRST, 0, 0, 0));
    CHECK(!pp_tr_should_log(PP_TR_FIRST + 1, 0, 0, 0));
    CHECK(pp_tr_should_log(PP_TR_FIRST + 1, 1, PP_TR_CHANGES - 1, 0));
    CHECK(!pp_tr_should_log(PP_TR_FIRST + 1, 1, PP_TR_CHANGES, 0));
    CHECK(!pp_tr_should_log(1, 1, 0, PP_TR_MAX_LINES));

    printf(failures ? "steamclient_trace_test: %d failure(s)\n" : "steamclient_trace_test: ok\n", failures);
    return failures ? 1 : 0;
}
