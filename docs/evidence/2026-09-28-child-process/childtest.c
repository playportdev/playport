/* SPDX-License-Identifier: GPL-3.0-or-later */
/* A child pseudo-process test, run as a title's main executable.
 *
 *   childtest.exe TITLE.EXE [ARGS...]   the parent: two window children of
 *                                        itself, then TITLE as a child
 *   childtest.exe --child-window CODE   a child: a window, its messages for
 *                                        about 2 s, then ExitProcess(CODE)
 *
 * Every step is a "[childtest] ..." line on the runtime's stderr (the host
 * log) through ntdll's __wine_dbg_output, and in C:\childtest.log. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <wchar.h>

static int (__cdecl *dbg_output)(const char *);

static void say(const char *fmt, ...)
{
    char line[1024];
    int n;
    va_list ap;
    HANDLE f;
    DWORD w;

    n = snprintf(line, sizeof(line), "[childtest] pid=%04lx tid=%04lx ",
                 GetCurrentProcessId(), GetCurrentThreadId());
    va_start(ap, fmt);
    n += vsnprintf(line + n, sizeof(line) - n - 2, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof(line) - 2) n = sizeof(line) - 2;
    line[n++] = '\n';
    line[n] = 0;
    if (dbg_output) dbg_output(line);
    f = CreateFileW(L"C:\\childtest.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) { WriteFile(f, line, n, &w, NULL); CloseHandle(f); }
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_CREATE: say("WM_CREATE hwnd=%p", hwnd); return 0;
    case WM_TIMER: say("WM_TIMER"); DestroyWindow(hwnd); return 0;
    case WM_DESTROY: say("WM_DESTROY"); PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static int child_window(int code)
{
    WNDCLASSW wc = { 0 };
    HWND hwnd;
    MSG m;
    int n = 0;

    say("child: start, exit code will be %d; peb image=%p", code, GetModuleHandleW(NULL));
    {
        HDESK d = GetThreadDesktop(GetCurrentThreadId());
        WCHAR name[128] = L"?";
        HWND top;
        GetUserObjectInformationW(d, UOI_NAME, name, sizeof(name), NULL);
        SetLastError(0);
        top = GetDesktopWindow();
        say("child: desktop %p (%ls), winstation %p, GetDesktopWindow %p (error %lu)", d, name,
            GetProcessWindowStation(), top, GetLastError());
    }
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"PlayportChildTest";
    if (!RegisterClassW(&wc)) say("child: RegisterClassW failed %lu", GetLastError());
    hwnd = CreateWindowExW(0, L"PlayportChildTest", L"child test", WS_OVERLAPPEDWINDOW,
                           0, 0, 320, 240, NULL, NULL, wc.hInstance, NULL);
    say("child: CreateWindowExW -> %p (error %lu)", hwnd, hwnd ? 0 : GetLastError());
    if (!hwnd) ExitProcess(100);
    ShowWindow(hwnd, SW_SHOW);
    SetTimer(hwnd, 1, 2000, NULL);
    while (GetMessageW(&m, NULL, 0, 0) > 0) { n++; TranslateMessage(&m); DispatchMessageW(&m); }
    say("child: message loop done after %d messages; exiting with %d", n, code);
    ExitProcess(code);
}

static DWORD run_child(const WCHAR *app, WCHAR *cmdline, const WCHAR *dir, DWORD timeout, const char *what)
{
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD t0 = GetTickCount(), wait, code = 0xdeadbeef;

    say("parent: starting %s", what);
    if (!CreateProcessW(app, cmdline, NULL, NULL, FALSE, 0, NULL, dir, &si, &pi))
    {
        say("parent: CreateProcessW for %s failed: %lu", what, GetLastError());
        return code;
    }
    say("parent: %s is pid %04lx; waiting", what, pi.dwProcessId);
    wait = WaitForSingleObject(pi.hProcess, timeout);
    GetExitCodeProcess(pi.hProcess, &code);
    say("parent: %s wait=%lu after %lu ms, exit code %lu (0x%lx)", what, wait, GetTickCount() - t0, code, code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return code;
}

int wmain(int argc, WCHAR **argv)
{
    WCHAR self[MAX_PATH], cmd[4096], dir[MAX_PATH], *slash;
    int i, ok = 1;
    size_t used;

    dbg_output = (void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "__wine_dbg_output");
    if (argc >= 3 && !wcscmp(argv[1], L"--child-window")) return child_window(_wtoi(argv[2]));

    GetModuleFileNameW(NULL, self, MAX_PATH);
    say("parent: start %ls, %d arguments", self, argc - 1);

    /* The window children are always the x86-64 build, beside this one. */
    if ((slash = wcsrchr(self, L'\\'))) wcscpy(slash + 1, L"childtest.exe");
    for (i = 1; i <= 2; i++)
    {
        DWORD code;
        char what[32];
        swprintf(cmd, 4096, L"\"%ls\" --child-window %d", self, 40 + i);
        snprintf(what, sizeof(what), "window child %d", i);
        code = run_child(self, cmd, NULL, 60000, what);
        if (code != (DWORD)(40 + i)) ok = 0;
    }
    say("parent: window children %s", ok ? "PASS" : "FAIL");
    if (argc < 2) return ok ? 0 : 1;

    /* The title, as a child, from its own directory, with its own arguments. */
    used = swprintf(cmd, 4096, L"\"%ls\"", argv[1]);
    for (i = 2; i < argc && used < 4000; i++) used += swprintf(cmd + used, 4096 - used, L" \"%ls\"", argv[i]);
    wcsncpy(dir, argv[1], MAX_PATH - 1);
    dir[MAX_PATH - 1] = 0;
    if ((slash = wcsrchr(dir, L'\\'))) *slash = 0;
    run_child(argv[1], cmd, dir, INFINITE, "the title");
    say("parent: done");
    return ok ? 0 : 1;
}
