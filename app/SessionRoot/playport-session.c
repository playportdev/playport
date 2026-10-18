// SPDX-License-Identifier: GPL-3.0-or-later
// playport-session.exe: the one Wine main process of an app run (decisions
// 0027, 0030).
//
// An app process plays one game and then restarts (decision 0029). This
// program is its one __wine_main. It starts the title the UI played as its
// child process, in a job with every process the title starts, waits for the
// job to empty (a launcher that exits after starting the game has not ended
// the title), puts the registry on disk and reports the exit code; then it
// idles until the app restarts. Before the title it may run the title's own
// prerequisite installers the same way, one request each (decision 0079). wine_host.c talks to it through files in its
// session directory (session_protocol.h), which is its one argument.
//
// It also does what explorer does at a Wine session's start: it brings up
// user32 before the title runs (GetDesktopWindow). win32u initialises once per
// session, in the process that first calls it, and writes the shared GDI
// handle table into that process's PEB only; a child's PEB is cloned from its
// parent's when it starts (Madeira loader_ios.c wine_ios_child_main), so the
// title, and every process it starts, gets the table from here, whichever of
// them first calls user32.
//
// While the title runs it also takes the in-game menu's controls
// (session_protocol.h): PAUSE suspends every thread of the title's processes
// with SuspendThread, which the wineserver holds only at a safe point (in
// guest code, outside a server call: patches/madeira-unix 0010), RESUME lets
// them go, and CLOSE posts WM_CLOSE to the title's top-level windows, as
// closing a window on Windows does, then ends the job if the title is still
// running when the wait it names is over.
//
// For a play that needs Windows services (decision 0107), it starts services.exe,
// Wine's SCM, before the title, logs each service's changes as `[service]`
// lines, and stops them all before it reports the title's end.
//
// For a play served by Playport's steamclient64.dll (decision 0115), it is the
// prefix's running Steam client: its process id is ActiveProcess's pid, which a
// genuine steam_api checks is alive, until the title's end; a crash's leftover
// is cleared at its start.
//
// x86-64, as every title is, GUI subsystem (no console, so no conhost),
// kernel32 and user32 only, no C runtime: nothing is loaded that a title would
// not load too (advapi32 only for the services, looked up). Its lines go to
// stderr, the app log, prefixed `session:`.

#include <windows.h>
#include <tlhelp32.h>
#include "../Sources/WineHost/include/session_protocol.h"
#include "command_line.h"

void *memset(void *d, int c, size_t n)
{
    volatile unsigned char *p = d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}

void *memcpy(void *d, const void *s, size_t n)
{
    volatile unsigned char *p = d;
    const unsigned char *q = s;
    while (n--) *p++ = *q++;
    return d;
}

static WCHAR dir[MAX_PATH], request_path[MAX_PATH + 16];
static WCHAR reply_path[MAX_PATH + 16], reply_tmp[MAX_PATH + 16];
static WCHAR control_path[MAX_PATH + 16], control_reply_path[MAX_PATH + 24], control_reply_tmp[MAX_PATH + 24];

/* --- output: `session: ` lines on stderr, %s (char *), %u, %x */
static int put_uint(char *o, unsigned long long v, int base)
{
    char t[24];
    int n = 0, i;
    do { t[n++] = "0123456789abcdef"[v % base]; v /= base; } while (v);
    for (i = 0; i < n; i++) o[i] = t[n - 1 - i];
    return n;
}

static void say(const char *fmt, ...)
{
    char buf[512];
    int n = 0;
    const char *p;
    DWORD w;
    va_list ap;

    for (p = "session: "; *p; p++) buf[n++] = *p;
    va_start(ap, fmt);
    for (p = fmt; *p && n < (int)sizeof(buf) - 32; p++) {
        if (*p != '%') { buf[n++] = *p; continue; }
        p++;
        if (*p == 's') {
            const char *s = va_arg(ap, const char *);
            while (*s && n < (int)sizeof(buf) - 32) buf[n++] = *s++;
        } else if (*p == 'u') {
            n += put_uint(buf + n, va_arg(ap, unsigned long long), 10);
        } else if (*p == 'x') {
            n += put_uint(buf + n, va_arg(ap, unsigned long long), 16);
        } else {
            buf[n++] = *p;
        }
    }
    va_end(ap);
    buf[n++] = '\n';
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), buf, n, &w, NULL);
}

/* --- wide strings */
static size_t wlen(const WCHAR *s)
{
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

static void wcopy(WCHAR *d, const WCHAR *s)
{
    while ((*d++ = *s++)) {}
}

static void wcat_a(WCHAR *d, const char *s)
{
    while (*d) d++;
    while ((*d++ = (WCHAR)(unsigned char)*s++)) {}
}

static WCHAR upper(WCHAR c)
{
    return c >= 'a' && c <= 'z' ? c - 'a' + 'A' : c;
}

/* The length of an environment entry's name; `=C:=C:\` style entries keep their leading `=`. */
static size_t name_len(const WCHAR *e)
{
    size_t n = e[0] == '=' ? 1 : 0;
    while (e[n] && e[n] != '=') n++;
    return n;
}

static int same_name(const WCHAR *a, const WCHAR *b)
{
    size_t na = name_len(a), nb = name_len(b), i;
    if (na != nb) return 0;
    for (i = 0; i < na; i++) if (upper(a[i]) != upper(b[i])) return 0;
    return 1;
}

/* UTF-8 to a new wide string on the process heap; NULL on failure. */
static WCHAR *wide(const char *s)
{
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    WCHAR *w = n > 0 ? HeapAlloc(GetProcessHeap(), 0, n * sizeof(WCHAR)) : NULL;
    if (w && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n) != n) {
        HeapFree(GetProcessHeap(), 0, w);
        w = NULL;
    }
    return w;
}

/* --- the transport */
static void reply_to(const WCHAR *path, const WCHAR *tmp, uint32_t sequence, uint32_t state, uint32_t code)
{
    pp_session_reply r = { PP_SESSION_MAGIC, sequence, state, code };
    DWORD n = 0;
    HANDLE h = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    BOOL ok = h != INVALID_HANDLE_VALUE && WriteFile(h, &r, sizeof(r), &n, NULL) && n == sizeof(r);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    if (!ok || !MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING)) {
        say("cannot write the reply (sequence %u, state %u): error %u", (unsigned long long)sequence,
            (unsigned long long)state, (unsigned long long)GetLastError());
        DeleteFileW(tmp);
    }
}

static void reply(uint32_t sequence, uint32_t state, uint32_t code)
{
    reply_to(reply_path, reply_tmp, sequence, state, code);
}

/* Reads and deletes a whole request file; the payload is on the heap (NULL for none). */
static int take(const WCHAR *path, pp_session_request *r, char **payload)
{
    HANDLE h = CreateFileW(path, GENERIC_READ, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD size, n = 0;
    int ok = 0;
    *payload = NULL;
    if (h == INVALID_HANDLE_VALUE) return -1;   /* none yet */
    size = GetFileSize(h, NULL);
    if (size >= sizeof(*r) && size - sizeof(*r) <= PP_SESSION_MAX_PAYLOAD &&
        ReadFile(h, r, sizeof(*r), &n, NULL) && n == sizeof(*r)) {
        uint32_t len = size - sizeof(*r);
        if (len == 0) ok = 1;
        else if ((*payload = HeapAlloc(GetProcessHeap(), 0, len)) &&
                 ReadFile(h, *payload, len, &n, NULL) && n == len) ok = 1;
        ok = ok && pp_session_request_valid(r, *payload, len);
    }
    CloseHandle(h);
    DeleteFileW(path);
    if (!ok && *payload) { HeapFree(GetProcessHeap(), 0, *payload); *payload = NULL; }
    return ok;
}

/* Processes in the job that have not ended. */
static DWORD job_active(HANDLE job)
{
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
    memset(&info, 0, sizeof(info));
    if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &info, sizeof(info), NULL)) return 0;
    return info.ActiveProcesses;
}

/* What a request starts, for its lines: the title or one of its prerequisites. */
static const char *what = "title";

/* --- the in-game menu's controls, while the title runs */

#define MAX_PIDS 256
#define MAX_HELD 4096

static HANDLE held[MAX_HELD];    /* the threads PAUSE suspended, until RESUME */
static DWORD nheld;

/* The title's processes: every one in its job, or the title alone without a job. */
static DWORD title_pids(HANDLE job, DWORD title, DWORD *pids)
{
    static struct {
        JOBOBJECT_BASIC_PROCESS_ID_LIST list;
        ULONG_PTR more[MAX_PIDS];
    } ids;
    DWORD n = 0, i;
    if (job) {
        memset(&ids, 0, sizeof(ids));
        if (QueryInformationJobObject(job, JobObjectBasicProcessIdList, &ids, sizeof(ids), NULL))
            for (i = 0; i < ids.list.NumberOfProcessIdsInList && n < MAX_PIDS; i++)
                pids[n++] = (DWORD)ids.list.ProcessIdList[i];
    }
    if (!n) pids[n++] = title;
    return n;
}

static int pid_in(DWORD pid, const DWORD *pids, DWORD n)
{
    DWORD i;
    for (i = 0; i < n; i++) if (pids[i] == pid) return 1;
    return 0;
}

/* Suspends every thread of the title's processes that is not held yet; how many are held. */
static DWORD pause_title(const DWORD *pids, DWORD n)
{
    THREADENTRY32 te;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE) return nheld;
    memset(&te, 0, sizeof(te));
    te.dwSize = sizeof(te);
    for (BOOL more = Thread32First(snap, &te); more && nheld < MAX_HELD; more = Thread32Next(snap, &te)) {
        HANDLE t;
        if (!pid_in(te.th32OwnerProcessID, pids, n)) continue;
        if (!(t = OpenThread(THREAD_SUSPEND_RESUME, FALSE, te.th32ThreadID))) continue;
        if (SuspendThread(t) == (DWORD)-1) CloseHandle(t);
        else held[nheld++] = t;
    }
    CloseHandle(snap);
    return nheld;
}

static DWORD resume_title(void)
{
    DWORD n = nheld;
    while (nheld) {
        nheld--;
        ResumeThread(held[nheld]);
        CloseHandle(held[nheld]);
    }
    return n;
}

struct closing {
    const DWORD *pids;
    DWORD npids, posted;
    int any;   /* every top-level window, not only the visible unowned ones */
};

static BOOL CALLBACK close_window(HWND w, LPARAM lp)
{
    struct closing *c = (struct closing *)lp;
    DWORD pid = 0;
    GetWindowThreadProcessId(w, &pid);
    if (!pid_in(pid, c->pids, c->npids)) return TRUE;
    if (!c->any && (!IsWindowVisible(w) || GetWindow(w, GW_OWNER))) return TRUE;
    if (PostMessageW(w, WM_CLOSE, 0, 0)) c->posted++;
    return TRUE;
}

/* WM_CLOSE to the title's main windows (visible, unowned), or to all its
 * top-level windows when it shows none; how many were posted. */
static DWORD close_title(const DWORD *pids, DWORD n)
{
    struct closing c = { pids, n, 0, 0 };
    EnumWindows(close_window, (LPARAM)&c);
    if (!c.posted) {
        c.any = 1;
        EnumWindows(close_window, (LPARAM)&c);
    }
    return c.posted;
}

/* One control, if the host wrote one: acts on it and answers. A CLOSE sets
 * *close_by, the tick after which a title still running is ended. */
static void control(uint32_t title_seq, HANDLE job, DWORD title, int *closing, DWORD *close_by)
{
    pp_session_control c;
    DWORD size, n = 0, pids[MAX_PIDS], npids, done = 0, t = GetTickCount();
    HANDLE h = CreateFileW(control_path, GENERIC_READ, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    int ok;
    if (h == INVALID_HANDLE_VALUE) return;
    memset(&c, 0, sizeof(c));
    size = GetFileSize(h, NULL);
    ok = size == sizeof(c) && ReadFile(h, &c, sizeof(c), &n, NULL) && n == sizeof(c) && pp_session_control_valid(&c, size);
    CloseHandle(h);
    DeleteFileW(control_path);
    if (!ok) {
        say("%s %u: refusing a malformed control", what, (unsigned long long)title_seq);
        if (n == sizeof(c) && c.sequence)
            reply_to(control_reply_path, control_reply_tmp, c.sequence, PP_CONTROL_REFUSED, ERROR_INVALID_DATA);
        return;
    }
    npids = title_pids(job, title, pids);
    switch (c.kind) {
    case PP_CONTROL_PAUSE:
        done = pause_title(pids, npids);
        say("%s %u: paused, %u threads of %u processes held in %u ms", what, (unsigned long long)title_seq,
            (unsigned long long)done, (unsigned long long)npids, (unsigned long long)(GetTickCount() - t));
        break;
    case PP_CONTROL_RESUME:
        done = resume_title();
        say("%s %u: resumed %u threads", what, (unsigned long long)title_seq, (unsigned long long)done);
        break;
    case PP_CONTROL_CLOSE:
        if (nheld) resume_title();   /* a paused title cannot close its windows */
        done = close_title(pids, npids);
        *closing = 1;
        *close_by = GetTickCount() + c.arg;
        say("%s %u: WM_CLOSE to %u windows of %u processes; ended in %u ms if still running", what,
            (unsigned long long)title_seq, (unsigned long long)done, (unsigned long long)npids, (unsigned long long)c.arg);
        break;
    }
    reply_to(control_reply_path, control_reply_tmp, c.sequence, PP_CONTROL_DONE, done);
}

/* --- Windows services (decision 0107) */

/* The SCM calls the root makes, from advapi32 (loaded only for a play with services). */
static struct {
    SC_HANDLE (WINAPI *open_manager)(LPCWSTR, LPCWSTR, DWORD);
    SC_HANDLE (WINAPI *open_service)(SC_HANDLE, LPCWSTR, DWORD);
    BOOL (WINAPI *enum_services)(SC_HANDLE, SC_ENUM_TYPE, DWORD, DWORD, LPBYTE, DWORD, LPDWORD, LPDWORD, LPDWORD, LPCWSTR);
    BOOL (WINAPI *control)(SC_HANDLE, DWORD, LPSERVICE_STATUS);
    BOOL (WINAPI *close)(SC_HANDLE);
} scm;
static HANDLE services_process;   /* services.exe, while it runs for this play */
static volatile LONG services_watching;

#define MAX_SERVICES 64
static struct { WCHAR name[80]; DWORD state, pid; } seen[MAX_SERVICES];
static DWORD nseen;

static const char *state_name(DWORD state)
{
    switch (state) {
    case SERVICE_STOPPED: return "stopped";
    case SERVICE_START_PENDING: return "starting";
    case SERVICE_STOP_PENDING: return "stopping";
    case SERVICE_RUNNING: return "running";
    case SERVICE_CONTINUE_PENDING: return "continuing";
    case SERVICE_PAUSE_PENDING: return "pausing";
    case SERVICE_PAUSED: return "paused";
    default: return "in an unknown state";
    }
}

/* Every Win32 service the SCM knows and its status, in buf; how many, or 0. */
static DWORD list_services(BYTE *buf, DWORD cap)
{
    SC_HANDLE m = scm.open_manager(NULL, NULL, SC_MANAGER_ENUMERATE_SERVICE);
    DWORD need = 0, count = 0, resume = 0;
    if (!m) return 0;
    if (!scm.enum_services(m, SC_ENUM_PROCESS_INFO, SERVICE_WIN32, SERVICE_STATE_ALL, buf, cap, &need, &count, &resume, NULL))
        count = 0;
    scm.close(m);
    return count;
}

/* `[service]` lines for each change since the last look: a service the SCM lists
 * for the first time (one CreateService installed, or the prefix had), and each
 * change of state, a stop with its exit codes. */
static void log_service_changes(void)
{
    static BYTE buf[32768];
    ENUM_SERVICE_STATUS_PROCESSW *e = (ENUM_SERVICE_STATUS_PROCESSW *)buf;
    DWORD n = list_services(buf, sizeof(buf)), i, k;
    char name[160];
    for (i = 0; i < n; i++) {
        SERVICE_STATUS_PROCESS *st = &e[i].ServiceStatusProcess;
        for (k = 0; k < nseen && !same_name(seen[k].name, e[i].lpServiceName); k++) {}
        if (k == nseen) {
            if (nseen == MAX_SERVICES || wlen(e[i].lpServiceName) >= 80) continue;
            wcopy(seen[nseen].name, e[i].lpServiceName);
            seen[nseen].state = 0;
            nseen++;
        }
        if (seen[k].state == st->dwCurrentState && seen[k].pid == st->dwProcessId) continue;
        if (!WideCharToMultiByte(CP_UTF8, 0, e[i].lpServiceName, -1, name, sizeof(name), NULL, NULL)) name[0] = 0;
        if (!seen[k].state && st->dwCurrentState == SERVICE_STOPPED)
            say("[service] %s: listed, stopped", name);
        else if (st->dwCurrentState == SERVICE_STOPPED)
            say("[service] %s: stopped, exit %u (service code %u)", name, (unsigned long long)st->dwWin32ExitCode,
                (unsigned long long)st->dwServiceSpecificExitCode);
        else
            say("[service] %s: %s, pid %u", name, state_name(st->dwCurrentState), (unsigned long long)st->dwProcessId);
        seen[k].state = st->dwCurrentState;
        seen[k].pid = st->dwProcessId;
    }
}

static DWORD WINAPI watch_services(void *unused)
{
    (void)unused;
    while (services_watching) {
        log_service_changes();
        Sleep(500);
    }
    return 0;
}

/* Starts services.exe and waits until its SCM listens (it sets Wine's
 * __wine_SvcctlStarted event): its process id, or 0 with the error in *error. */
static DWORD start_services(DWORD *error)
{
    static const char *const fns[] = { "OpenSCManagerW", "OpenServiceW", "EnumServicesStatusExW", "ControlService",
                                       "CloseServiceHandle" };
    void **slots[] = { (void **)&scm.open_manager, (void **)&scm.open_service, (void **)&scm.enum_services,
                       (void **)&scm.control, (void **)&scm.close };
    WCHAR exe[] = L"C:\\windows\\system32\\services.exe", line[] = L"services.exe";
    HMODULE advapi = LoadLibraryW(L"advapi32.dll");
    HANDLE started, wait[2], err = GetStdHandle(STD_ERROR_HANDLE);
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD i, w, t = GetTickCount();

    if (services_process) { *error = ERROR_SERVICE_ALREADY_RUNNING; return 0; }
    for (i = 0; i < sizeof(fns) / sizeof(*fns); i++)
        if (!advapi || !(*slots[i] = (void *)GetProcAddress(advapi, fns[i]))) { *error = ERROR_PROC_NOT_FOUND; return 0; }
    /* Made first, so the wait cannot miss the SCM setting it. */
    if (!(started = CreateEventW(NULL, TRUE, FALSE, L"__wine_SvcctlStarted"))) { *error = GetLastError(); return 0; }
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = si.hStdError = err;
    memset(&pi, 0, sizeof(pi));
    if (!CreateProcessW(exe, line, NULL, NULL, err && err != INVALID_HANDLE_VALUE, 0, NULL, NULL, &si, &pi)) {
        *error = GetLastError();
        CloseHandle(started);
        return 0;
    }
    CloseHandle(pi.hThread);
    wait[0] = started;
    wait[1] = pi.hProcess;
    w = WaitForMultipleObjects(2, wait, FALSE, 10000);
    CloseHandle(started);
    if (w != WAIT_OBJECT_0) {
        say("[service] services.exe %s after %u ms", w == WAIT_OBJECT_0 + 1 ? "ended" : "did not start its SCM",
            (unsigned long long)(GetTickCount() - t));
        TerminateProcess(pi.hProcess, ERROR_SERVICE_REQUEST_TIMEOUT);
        CloseHandle(pi.hProcess);
        *error = w == WAIT_OBJECT_0 + 1 ? ERROR_SERVICE_NOT_ACTIVE : ERROR_SERVICE_REQUEST_TIMEOUT;
        return 0;
    }
    services_process = pi.hProcess;
    say("[service] services.exe started, pid %u, its SCM listening after %u ms", (unsigned long long)pi.dwProcessId,
        (unsigned long long)(GetTickCount() - t));
    log_service_changes();
    services_watching = 1;
    CloseHandle(CreateThread(NULL, 0, watch_services, NULL, 0, NULL));
    return pi.dwProcessId;
}

/* Before the title's end is reported: every running service is asked to stop
 * (3 s at most), one still running is ended, then services.exe, so none
 * outlives the title. */
static void stop_services(void)
{
    static BYTE buf[32768];
    ENUM_SERVICE_STATUS_PROCESSW *e = (ENUM_SERVICE_STATUS_PROCESSW *)buf;
    SERVICE_STATUS status;
    DWORD n, i, t = GetTickCount(), ended = 0;
    SC_HANDLE m;

    if (!services_process) return;
    services_watching = 0;
    if ((m = scm.open_manager(NULL, NULL, SC_MANAGER_CONNECT))) {
        n = list_services(buf, sizeof(buf));
        for (i = 0; i < n; i++) {
            SC_HANDLE s;
            if (e[i].ServiceStatusProcess.dwCurrentState == SERVICE_STOPPED) continue;
            if ((s = scm.open_service(m, e[i].lpServiceName, SERVICE_STOP))) {
                scm.control(s, SERVICE_CONTROL_STOP, &status);
                scm.close(s);
            }
        }
        scm.close(m);
    }
    while (GetTickCount() - t < 3000) {
        int running = 0;
        n = list_services(buf, sizeof(buf));
        for (i = 0; i < n; i++) running |= e[i].ServiceStatusProcess.dwCurrentState != SERVICE_STOPPED;
        if (!running) break;
        Sleep(100);
    }
    log_service_changes();
    n = list_services(buf, sizeof(buf));
    for (i = 0; i < n; i++) {
        DWORD pid = e[i].ServiceStatusProcess.dwProcessId;
        HANDLE h;
        if (e[i].ServiceStatusProcess.dwCurrentState == SERVICE_STOPPED || !pid) continue;
        if ((h = OpenProcess(PROCESS_TERMINATE, FALSE, pid))) {
            if (TerminateProcess(h, ERROR_PROCESS_ABORTED)) ended++;
            CloseHandle(h);
        }
    }
    TerminateProcess(services_process, 0);
    WaitForSingleObject(services_process, 2000);
    CloseHandle(services_process);
    services_process = NULL;
    say("[service] services.exe and its services stopped with the title in %u ms (%u ended)",
        (unsigned long long)(GetTickCount() - t), (unsigned long long)ended);
}

/* --- the prefix's Steam client (decision 0115) */

typedef LONG (WINAPI *reg_create_fn)(HKEY, const WCHAR *, DWORD, WCHAR *, DWORD, REGSAM, void *, HKEY *, DWORD *);
typedef LONG (WINAPI *reg_open_fn)(HKEY, const WCHAR *, DWORD, REGSAM, HKEY *);
typedef LONG (WINAPI *reg_set_fn)(HKEY, const WCHAR *, DWORD, DWORD, const BYTE *, DWORD);
typedef LONG (WINAPI *reg_query_fn)(HKEY, const WCHAR *, DWORD *, DWORD *, BYTE *, DWORD *);
typedef LONG (WINAPI *reg_close_fn)(HKEY);
static const WCHAR active_process[] = L"Software\\Valve\\Steam\\ActiveProcess";
static int steam_client_set;

/* ActiveProcess's pid and ActiveUser, in HKCU: create makes the key, else only an
 * existing one is written (and only when its pid is not already 0). 0, or a Windows error. */
static DWORD steam_client_keys(DWORD pid, DWORD user, int create)
{
    HMODULE advapi = LoadLibraryW(L"advapi32.dll");
    reg_create_fn reg_create = advapi ? (reg_create_fn)(void *)GetProcAddress(advapi, "RegCreateKeyExW") : NULL;
    reg_open_fn reg_open = advapi ? (reg_open_fn)(void *)GetProcAddress(advapi, "RegOpenKeyExW") : NULL;
    reg_set_fn reg_set = advapi ? (reg_set_fn)(void *)GetProcAddress(advapi, "RegSetValueExW") : NULL;
    reg_query_fn reg_query = advapi ? (reg_query_fn)(void *)GetProcAddress(advapi, "RegQueryValueExW") : NULL;
    reg_close_fn reg_close = advapi ? (reg_close_fn)(void *)GetProcAddress(advapi, "RegCloseKey") : NULL;
    HKEY key;
    LONG rc;
    DWORD old = 0, size = sizeof(old), type = 0;

    if (!reg_create || !reg_open || !reg_set || !reg_query || !reg_close) return ERROR_PROC_NOT_FOUND;
    rc = create ? reg_create(HKEY_CURRENT_USER, active_process, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL)
                : reg_open(HKEY_CURRENT_USER, active_process, 0, KEY_SET_VALUE | KEY_QUERY_VALUE, &key);
    if (rc) return (DWORD)rc;
    if (!create && (reg_query(key, L"pid", NULL, &type, (BYTE *)&old, &size) || type != REG_DWORD || !old)) {
        reg_close(key);
        return 0;
    }
    rc = reg_set(key, L"pid", 0, REG_DWORD, (const BYTE *)&pid, sizeof(pid));
    if (!rc) rc = reg_set(key, L"ActiveUser", 0, REG_DWORD, (const BYTE *)&user, sizeof(user));
    reg_close(key);
    if (!rc && !create) say("steam client: ActiveProcess pid %u cleared", (unsigned long long)old);
    return (DWORD)rc;
}

/* The payload's decimal account ID (pp_session_request_valid checked it). */
static DWORD account_id(const char *payload)
{
    DWORD v = 0;
    while (*payload) v = v * 10 + (DWORD)(*payload++ - '0');
    return v;
}

/* --- one title */

/* Before a title's end is reported: the registry on disk. The app may end as
 * soon as it hears of the end (it restarts itself after every game), and the
 * server otherwise saves only every 30 s, or when the last process ends, which
 * this root never lets happen. patches/wine-unix 0003 makes the server's
 * flush_key save every branch. RegFlushKey is kernelbase's, which every process
 * has loaded; looked up, so the root imports kernel32 and user32 alone. */
static void flush_registry(uint32_t sequence)
{
    typedef LONG (WINAPI *flush_fn)(HKEY);
    HMODULE kb = GetModuleHandleW(L"kernelbase.dll");
    flush_fn flush = kb ? (flush_fn)(void *)GetProcAddress(kb, "RegFlushKey") : NULL;
    DWORD t = GetTickCount();
    LONG rc = flush ? flush(HKEY_CURRENT_USER) : -1;
    say("%s %u: registry flush %x in %u ms", what, (unsigned long long)sequence, (unsigned long long)(ULONG)rc,
        (unsigned long long)(GetTickCount() - t));
}

static void launch(const pp_session_request *r, const char *payload)
{
    const char *p = payload;
    const char *strings[2 + PP_SESSION_MAX_ARGS + PP_SESSION_MAX_ENV];
    WCHAR *wexe = NULL, *wcwd = NULL, *line = NULL, *env = NULL, *base = NULL, *wv = NULL;
    WCHAR *set[PP_SESSION_MAX_ENV];
    size_t used = 0, env_used = 0, env_cap = 0;
    uint32_t i, n = 2 + r->argc + r->envc, error = ERROR_INVALID_DATA;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    HANDLE job = NULL, err = GetStdHandle(STD_ERROR_HANDLE);
    DWORD code = 0, started = GetTickCount(), close_by = 0;
    int closing = 0, answered = 0;

    memset(set, 0, sizeof(set));
    what = r->kind == PP_REQUEST_LAUNCH ? "title" : "prerequisite";
    for (i = 0; i < n; i++) {
        strings[i] = p;
        while (*p) p++;
        p++;
    }
    say("%s %u: %s in %s, %u arguments, %u variables", what, (unsigned long long)r->sequence, strings[0], strings[1],
        (unsigned long long)r->argc, (unsigned long long)r->envc);
    if (!(wexe = wide(strings[0])) || !(wcwd = wide(strings[1])) ||
        !(line = HeapAlloc(GetProcessHeap(), 0, 32768 * sizeof(WCHAR))))
        goto refuse;
    line[0] = 0;
    if (!append_arg(line, 32768, &used, wexe, 1)) goto refuse;
    for (i = 0; i < r->argc; i++) {
        if (!(wv = wide(strings[2 + i])) ||
            !(r->kind == PP_REQUEST_PREREQUISITE_LINE ? append_line(line, 32768, &used, wv)
                                                      : append_arg(line, 32768, &used, wv, 0)))
            goto refuse;
        HeapFree(GetProcessHeap(), 0, wv);
        wv = NULL;
    }
    for (i = 0; i < r->envc; i++)
        if (!(set[i] = wide(strings[2 + r->argc + i]))) goto refuse;

    /* The root's own environment, which Wine made from the app's for the first
     * process (PATH, TEMP and the rest in Windows form), with this title's
     * variables over it. Nothing a previous title set is in it. */
    if (!(base = GetEnvironmentStringsW())) goto refuse;
    for (WCHAR *e = base; *e; e += wlen(e) + 1) env_cap += wlen(e) + 1;
    for (i = 0; i < r->envc; i++) env_cap += wlen(set[i]) + 1;
    if (!(env = HeapAlloc(GetProcessHeap(), 0, (env_cap + 2) * sizeof(WCHAR)))) goto refuse;
    for (WCHAR *e = base; *e; e += wlen(e) + 1) {
        int replaced = 0;
        for (i = 0; i < r->envc && !replaced; i++) replaced = same_name(e, set[i]);
        if (replaced) continue;
        wcopy(env + env_used, e);
        env_used += wlen(e) + 1;
    }
    for (i = 0; i < r->envc; i++) {
        wcopy(env + env_used, set[i]);
        env_used += wlen(set[i]) + 1;
    }
    env[env_used] = 0;

    /* The title's output goes where the root's does: the app log. */
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = si.hStdError = err;
    memset(&pi, 0, sizeof(pi));
    /* Suspended until it is in the job, so everything it starts is in the job too. */
    if (!CreateProcessW(wexe, line, NULL, NULL, err && err != INVALID_HANDLE_VALUE,
                        CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED, env, wcwd, &si, &pi)) {
        error = GetLastError();
        goto refuse;
    }
    job = CreateJobObjectW(NULL, NULL);
    if (!job || !AssignProcessToJobObject(job, pi.hProcess)) {
        say("%s %u: no job (error %u): only the title itself is waited for", what, (unsigned long long)r->sequence,
            (unsigned long long)GetLastError());
        if (job) CloseHandle(job);
        job = NULL;
    }
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    say("%s %u: started, pid %u", what, (unsigned long long)r->sequence, (unsigned long long)pi.dwProcessId);
    reply(r->sequence, PP_TITLE_STARTED, pi.dwProcessId);

    /* Until the title and everything it started have ended, taking the
     * in-game menu's controls meanwhile, and answering the messages sent to
     * the desktop window, as explorer's desktop thread does on a Wine host.
     * wineserver names this thread as the window's (it made it), so a title's
     * SendMessage to it waits for this thread: a modal dialog owned by the
     * desktop (DialogBoxParam(..., GetDesktopWindow(), ...)) disables its
     * owner first, and EnableWindow sends WM_CANCELMODE (Tomb Raider:
     * Anniversary's setup dialog hung there). */
    for (;;) {
        DWORD w = MsgWaitForMultipleObjects(1, &pi.hProcess, FALSE, 50, QS_SENDMESSAGE);
        if (w == WAIT_OBJECT_0 + 1) {
            MSG msg;
            if (!answered) say("%s %u: answering messages sent to the desktop window", what,
                               (unsigned long long)r->sequence);
            answered = 1;
            PeekMessageW(&msg, NULL, 0, 0, PM_NOREMOVE | PM_QS_SENDMESSAGE);   /* calls the sent ones */
        }
        if (w == WAIT_OBJECT_0 && (!job || !job_active(job))) break;
        if (w == WAIT_FAILED) { Sleep(100); if (!job || !job_active(job)) break; }
        if (w == WAIT_OBJECT_0) Sleep(50);   /* a launcher that ended before the processes it started */
        control(r->sequence, job, pi.dwProcessId, &closing, &close_by);
        if (closing && (LONG)(GetTickCount() - close_by) >= 0) {
            closing = 0;
            say("%s %u: still running after WM_CLOSE; ending it", what, (unsigned long long)r->sequence);
            if (job) TerminateJobObject(job, ERROR_PROCESS_ABORTED);
            else TerminateProcess(pi.hProcess, ERROR_PROCESS_ABORTED);
        }
    }
    resume_title();
    DeleteFileW(control_path);
    if (r->kind == PP_REQUEST_LAUNCH) stop_services();
    if (r->kind == PP_REQUEST_LAUNCH && steam_client_set) steam_client_keys(0, 0, 0);
    if (!GetExitCodeProcess(pi.hProcess, &code)) code = GetLastError();
    CloseHandle(pi.hProcess);
    if (job) CloseHandle(job);
    say("%s %u: ended, exit code %x after %u ms", what, (unsigned long long)r->sequence, (unsigned long long)code,
        (unsigned long long)(GetTickCount() - started));
    flush_registry(r->sequence);
    reply(r->sequence, PP_TITLE_EXITED, code);
    goto done;

refuse:
    if (error == ERROR_INVALID_DATA && GetLastError()) error = GetLastError();
    say("%s %u: not started, error %u", what, (unsigned long long)r->sequence, (unsigned long long)error);
    if (r->kind == PP_REQUEST_LAUNCH) stop_services();
    if (r->kind == PP_REQUEST_LAUNCH && steam_client_set) {
        steam_client_keys(0, 0, 0);
        flush_registry(r->sequence);
    }
    reply(r->sequence, PP_TITLE_REFUSED, error);
done:
    for (i = 0; i < r->envc; i++) if (set[i]) HeapFree(GetProcessHeap(), 0, set[i]);
    if (wv) HeapFree(GetProcessHeap(), 0, wv);
    if (base) FreeEnvironmentStringsW(base);
    if (env) HeapFree(GetProcessHeap(), 0, env);
    if (line) HeapFree(GetProcessHeap(), 0, line);
    if (wcwd) HeapFree(GetProcessHeap(), 0, wcwd);
    if (wexe) HeapFree(GetProcessHeap(), 0, wexe);
}

/* The directory from the command line: the program's path, then the directory, quoted or not. */
static int directory_argument(void)
{
    const WCHAR *c = GetCommandLineW();
    size_t n = 0;
    if (*c == '"') { c++; while (*c && *c != '"') c++; if (*c) c++; }
    else while (*c && *c != ' ' && *c != '\t') c++;
    while (*c == ' ' || *c == '\t') c++;
    if (*c == '"') {
        c++;
        while (c[n] && c[n] != '"') n++;
    } else {
        while (c[n] && c[n] != ' ' && c[n] != '\t') n++;
    }
    if (!n || n > MAX_PATH - 16) return 0;
    memcpy(dir, c, n * sizeof(WCHAR));
    dir[n] = 0;
    return 1;
}

void __stdcall entry(void)
{
    pp_session_request r;
    char *payload;
    int got;

    if (!directory_argument()) {
        say("usage: playport-session.exe SESSION-DIRECTORY");
        ExitProcess(ERROR_INVALID_PARAMETER);
    }
    wcopy(request_path, dir); wcat_a(request_path, "\\request");
    wcopy(reply_path, dir); wcat_a(reply_path, "\\reply");
    wcopy(reply_tmp, dir); wcat_a(reply_tmp, "\\reply.tmp");
    wcopy(control_path, dir); wcat_a(control_path, "\\control");
    wcopy(control_reply_path, dir); wcat_a(control_reply_path, "\\control-reply");
    wcopy(control_reply_tmp, dir); wcat_a(control_reply_tmp, "\\control-reply.tmp");
    CreateDirectoryW(dir, NULL);
    DeleteFileW(request_path);
    DeleteFileW(control_path);
    {
        HWND desktop = GetDesktopWindow();
        say("desktop window %x, GDI handle table %x", (unsigned long long)(ULONG_PTR)desktop,
            (unsigned long long)((ULONG_PTR *)__readgsqword(0x60))[0xf8 / sizeof(ULONG_PTR)]);   /* TEB->Peb->GdiSharedHandleTable */
    }
    /* A Steam client pid a crash left (decision 0115): no title runs yet, so none is running. */
    steam_client_keys(0, 0, 0);
    say("ready, pid %u", (unsigned long long)GetCurrentProcessId());
    reply(0, PP_ROOT_READY, GetCurrentProcessId());

    /* The one title of this app process, after any prerequisites it runs first;
     * malformed requests are refused and waited past. */
    for (;;) {
        memset(&r, 0, sizeof(r));
        got = take(request_path, &r, &payload);
        if (got < 0) { Sleep(50); continue; }
        if (got && r.kind == PP_REQUEST_LAUNCH) break;
        if (got && r.kind == PP_REQUEST_SERVICES) {
            DWORD error = 0, pid = start_services(&error);
            if (pid) reply(r.sequence, PP_TITLE_STARTED, pid);
            else {
                say("services %u: not started, error %u", (unsigned long long)r.sequence, (unsigned long long)error);
                reply(r.sequence, PP_TITLE_REFUSED, error);
            }
            continue;
        }
        if (got && r.kind == PP_REQUEST_STEAM_CLIENT) {
            DWORD error = steam_client_keys(GetCurrentProcessId(), account_id(payload), 1);
            if (!error) {
                steam_client_set = 1;
                say("steam client %u: ActiveProcess pid %u", (unsigned long long)r.sequence,
                    (unsigned long long)GetCurrentProcessId());
                reply(r.sequence, PP_TITLE_STARTED, GetCurrentProcessId());
            } else {
                say("steam client %u: keys not written, error %u", (unsigned long long)r.sequence, (unsigned long long)error);
                reply(r.sequence, PP_TITLE_REFUSED, error);
            }
            if (payload) HeapFree(GetProcessHeap(), 0, payload);
            continue;
        }
        if (got && (r.kind == PP_REQUEST_PREREQUISITE || r.kind == PP_REQUEST_PREREQUISITE_LINE)) {
            launch(&r, payload);
            HeapFree(GetProcessHeap(), 0, payload);
            continue;
        }
        say("refusing a malformed request");
        if (got) reply(r.sequence, PP_TITLE_REFUSED, ERROR_INVALID_DATA);
        if (payload) HeapFree(GetProcessHeap(), 0, payload);
    }
    launch(&r, payload);
    HeapFree(GetProcessHeap(), 0, payload);

    /* The app restarts once it hears the title ended (decision 0029); nothing follows it here. */
    for (;;) Sleep(INFINITE);
}
