/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * steamclient_trace.h — the per-call trace of Playport's steamclient64.dll
 * (steamclient.c), for a dev build only: the host arms it in HELLO's `trace`
 * (SteamClientHost, `#if !PLAYPORT_RELEASE`); a release app never does, and
 * then nothing here runs (PLA-401).
 *
 * A traced call becomes one `steamclient: trace` line: the time since the
 * client's first use, the calling thread, the interface and method, the few
 * arguments that are app ids or call handles, and a compact result. What it
 * never shows: ticket bytes, SteamIDs ("set" or "zero"), the persona or any
 * other name ("len=N"), tokens, pointers' targets. Bounded: each method's
 * first PP_TR_FIRST calls, then only calls whose result changed (at most
 * PP_TR_CHANGES more), and every PP_TR_SUMMARY_MS a summary of how many
 * times each method was called since the last one; PP_TR_MAX_LINES in all.
 *
 * Freestanding (no C runtime), as the DLL is; the host C test
 * (app/tests/steamclient_trace_test.c) builds it on Linux.
 */

#ifndef STEAMCLIENT_TRACE_H
#define STEAMCLIENT_TRACE_H

#include <stdint.h>
#include "../Sources/WineHost/include/steam_client_protocol.h"

#define PP_TR_FIRST 30
#define PP_TR_CHANGES 200
#define PP_TR_SUMMARY_MS 250
#define PP_TR_MAX_LINES 8000

/* A line under construction: always NUL-terminated, never past PP_SC_LOG_MAX. */
typedef struct { char text[PP_SC_LOG_MAX]; unsigned n; } pp_tr_line;

static inline void pp_tr_reset(pp_tr_line *l) { l->n = 0; l->text[0] = 0; }

static inline void pp_tr_str(pp_tr_line *l, const char *s)
{
    while (s && *s && l->n < PP_SC_LOG_MAX - 1) l->text[l->n++] = *s++;
    l->text[l->n] = 0;
}

static inline void pp_tr_u64(pp_tr_line *l, uint64_t v)
{
    char t[24];
    int n = 0;
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n && l->n < PP_SC_LOG_MAX - 1) l->text[l->n++] = t[--n];
    l->text[l->n] = 0;
}

static inline void pp_tr_i64(pp_tr_line *l, int64_t v)
{
    if (v < 0) { pp_tr_str(l, "-"); pp_tr_u64(l, (uint64_t)0 - (uint64_t)v); }
    else pp_tr_u64(l, (uint64_t)v);
}

static inline void pp_tr_hex(pp_tr_line *l, uint64_t v)
{
    char t[17];
    int n = 0;
    do { t[n++] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v);
    while (n && l->n < PP_SC_LOG_MAX - 1) l->text[l->n++] = t[--n];
    l->text[l->n] = 0;
}

static inline int pp_tr_same(const char *a, const char *b)
{
    if (!a || !b) return 0;
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

/* How a method's result is shown, by its name:
 *   b bool (the low byte)    i int32    u uint32    q uint64 (a call handle)
 *   v nothing (void)         p an object: "obj" or "null"
 *   h a class through the hidden return pointer (CSteamID): "set" or "zero"
 *   s a short string, shown (languages, a country code)
 *   S a string never shown: its length only (names)
 * Anything not listed is shown as a uint32. */
static const struct { const char *method; char kind; } pp_tr_kinds[] = {
    { "CreateSteamPipe", 'i' }, { "BReleaseSteamPipe", 'b' }, { "ConnectToGlobalUser", 'i' },
    { "ReleaseUser", 'v' }, { "GetIPCCallCount", 'u' }, { "SetWarningMessageHook", 'v' }, { "RunFrame", 'v' },
    { "BShutdownIfAllPipesClosed", 'b' }, { "Set_SteamAPI_CCheckCallbackRegisteredInProcess", 'v' },
    { "DestroyAllInterfaces", 'v' },
    { "GetHSteamUser", 'i' }, { "BLoggedOn", 'b' }, { "GetSteamID", 'h' }, { "GetAuthSessionTicket", 'u' },
    { "GetAuthTicketForWebApi", 'u' }, { "CancelAuthTicket", 'v' }, { "UserHasLicenseForApp", 'i' },
    { "RequestEncryptedAppTicket", 'q' }, { "GetEncryptedAppTicket", 'b' },
    { "GetSecondsSinceAppActive", 'u' }, { "GetSecondsSinceComputerActive", 'u' }, { "GetConnectedUniverse", 'i' },
    { "GetServerRealTime", 'u' }, { "GetIPCountry", 's' }, { "GetCurrentBatteryPower", 'b' }, { "GetAppID", 'u' },
    { "IsAPICallCompleted", 'b' }, { "GetAPICallFailureReason", 'i' }, { "GetAPICallResult", 'b' },
    { "SetOverlayNotificationPosition", 'v' }, { "SetOverlayNotificationInset", 'v' }, { "IsOverlayEnabled", 'b' },
    { "BOverlayNeedsPresent", 'b' }, { "GetSteamUILanguage", 's' }, { "IsSteamRunningInVR", 'b' },
    { "IsSteamInBigPictureMode", 'b' }, { "IsSteamChinaLauncher", 'b' }, { "IsSteamRunningOnSteamDeck", 'b' },
    { "BIsSubscribed", 'b' }, { "BIsLowViolence", 'b' }, { "BIsCybercafe", 'b' }, { "BIsVACBanned", 'b' },
    { "GetCurrentGameLanguage", 's' }, { "GetAvailableGameLanguages", 's' }, { "BIsSubscribedApp", 'b' },
    { "BIsDlcInstalled", 'b' }, { "BIsSubscribedFromFreeWeekend", 'b' }, { "GetDLCCount", 'i' },
    { "BIsAppInstalled", 'b' }, { "GetAppOwner", 'h' }, { "GetLaunchQueryParam", 's' },
    { "BIsSubscribedFromFamilySharing", 'b' }, { "BIsTimedTrial", 'b' },
    { "GetPersonaName", 'S' }, { "GetPersonaState", 'i' }, { "GetFriendCount", 'i' },
    { "GetFriendPersonaName", 'S' }, { "GetPlayerNickname", 'S' }, { "GetFriendPersonaNameHistory", 'S' },
    { "GetUserDataFolder", 'S' }, { "GetAppInstallDir", 'u' }, { "GetCurrentBetaName", 'b' },
};

static inline char pp_tr_kind_of(const char *method)
{
    if (method && method[0] == 'G' && method[1] == 'e' && method[2] == 't' && method[3] == 'I' && method[4] == 'S'
        && method[5] == 't' && method[6] == 'e' && method[7] == 'a' && method[8] == 'm') return 'p';   /* GetISteam* */
    for (unsigned i = 0; i < sizeof(pp_tr_kinds) / sizeof(*pp_tr_kinds); i++)
        if (pp_tr_same(pp_tr_kinds[i].method, method)) return pp_tr_kinds[i].kind;
    return 'u';
}

/* The result. `hidden` is the hidden return pointer for 'h' (else unused). */
static inline void pp_tr_result(pp_tr_line *l, char kind, uint64_t r, const void *hidden)
{
    switch (kind) {
    case 'b': pp_tr_u64(l, r & 0xff); break;
    case 'i': pp_tr_i64(l, (int32_t)(uint32_t)r); break;
    case 'q': pp_tr_u64(l, r); break;
    case 'v': pp_tr_str(l, "-"); break;
    case 'p': pp_tr_str(l, r ? "obj" : "null"); break;
    case 'h': pp_tr_str(l, hidden && *(const uint64_t *)hidden ? "set" : "zero"); break;
    case 's': {
        const char *s = (const char *)(uintptr_t)r;
        int n = 0;
        if (!s) { pp_tr_str(l, "null"); break; }
        pp_tr_str(l, "\"");
        for (; s[n] && n < 32 && l->n < PP_SC_LOG_MAX - 2; n++) {
            char c = s[n];
            l->text[l->n++] = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ',' || c == '_'
                              || c == '-' ? c : '?';
        }
        l->text[l->n] = 0;
        pp_tr_str(l, s[n] ? "...\"" : "\"");
        break;
    }
    case 'S': {
        const char *s = (const char *)(uintptr_t)r;
        uint64_t n = 0;
        if (!s) { pp_tr_str(l, "null"); break; }
        while (s[n]) n++;
        pp_tr_str(l, "len=");
        pp_tr_u64(l, n);
        break;
    }
    default: pp_tr_u64(l, (uint32_t)r); break;
    }
}

/* The arguments shown: app ids and call handles only, by method (a1 is the
 * first argument after `this`). Returns how many it wrote. */
static inline int pp_tr_args(pp_tr_line *l, const char *method, uint64_t a1, uint64_t a2, uint64_t a4)
{
    static const char *const app_first[] = { "BIsSubscribedApp", "BIsDlcInstalled", "BIsAppInstalled", "GetAppInstallDir",
                                             "GetEarliestPurchaseUnixTime", "GetDlcDownloadProgress", "InstallDLC",
                                             "UninstallDLC" };
    for (unsigned i = 0; i < sizeof(app_first) / sizeof(*app_first); i++)
        if (pp_tr_same(method, app_first[i])) { pp_tr_str(l, "app="); pp_tr_u64(l, (uint32_t)a1); return 1; }
    if (pp_tr_same(method, "UserHasLicenseForApp")) { pp_tr_str(l, "app="); pp_tr_u64(l, (uint32_t)a2); return 1; }
    if (pp_tr_same(method, "IsAPICallCompleted") || pp_tr_same(method, "GetAPICallFailureReason")) {
        pp_tr_str(l, "call="); pp_tr_u64(l, a1); return 1;
    }
    if (pp_tr_same(method, "GetAPICallResult")) {
        pp_tr_str(l, "call="); pp_tr_u64(l, a1); pp_tr_str(l, " cb="); pp_tr_i64(l, (int32_t)(uint32_t)a4); return 2;
    }
    if (pp_tr_same(method, "CancelAuthTicket")) { pp_tr_str(l, "handle="); pp_tr_u64(l, (uint32_t)a1); return 1; }
    return 0;
}

/* Whether a call is a line of its own: its method's first PP_TR_FIRST calls,
 * then one whose result differs from the last, PP_TR_CHANGES times at most;
 * within PP_TR_MAX_LINES in all. The rest are counted for the summaries. */
static inline int pp_tr_should_log(unsigned calls, int changed, unsigned changes_logged, unsigned lines)
{
    if (lines >= PP_TR_MAX_LINES) return 0;
    if (calls <= PP_TR_FIRST) return 1;
    return changed && changes_logged < PP_TR_CHANGES;
}

#endif /* STEAMCLIENT_TRACE_H */
