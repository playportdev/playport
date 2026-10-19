/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * console: a console-subsystem program (no -mwindows) started from the app,
 * which has no console, so kernelbase must start conhost.exe for it; then cmd
 * started as a child (PLA-390). On iOS an x86-64 process cannot start a pure
 * ARM64 one, so conhost and cmd must be system32's arm64ec builds (decision
 * 0082, wine-pe 0047); without them a console program's start fails
 * (c0000135).
 *
 *   a  the console it was given: CONOUT$ opens, GetConsoleMode succeeds on
 *      it and WriteConsoleA writes to it (conhost answers both); the
 *      standard output handle's type and GetConsoleWindow are only reported
 *      (a parent may hand over its own output, a headless conhost has no
 *      window)
 *   b  "cmd.exe /c echo <marker>" with its output in a pipe: exit code 0,
 *      the marker in what it wrote, and nothing else in the pipe (the
 *      runtime's own lines once arrived there, PLA-403); a NUL in the
 *      output is shown as \0
 *   c  "cmd.exe /c exit 7" with CREATE_NEW_CONSOLE (a second conhost start):
 *      exit code 7
 *
 * Each line goes to OutputDebugString, stdout and <dir>\console.log. A line
 * ends "ok" or "BAD"; the last is "console: done ok" (exit 0) or
 * "console: done FAIL" (1). Built with llvm-mingw for x86-64 (console.exe) by
 * tools/compat/probes/build.sh.
 */
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define CMD_MARKER "console-probe-cmd-echo"
#define CHILD_WAIT_MS 30000

static HANDLE log_file = INVALID_HANDLE_VALUE;
static int failed;

static void probe_log(const char *fmt, ...)
{
    char line[512];
    va_list ap;
    DWORD written;
    int n = snprintf(line, sizeof(line), "console: ");

    va_start(ap, fmt);
    vsnprintf(line + n, sizeof(line) - n, fmt, ap);
    va_end(ap);
    OutputDebugStringA(line);
    printf("%s", line);
    fflush(stdout);
    if (log_file != INVALID_HANDLE_VALUE) WriteFile(log_file, line, (DWORD)strlen(line), &written, NULL);
}

static const char *verdict(int ok)
{
    if (!ok) failed = 1;
    return ok ? "ok" : "BAD";
}

static void phase_console(void)
{
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE con = CreateFileA("CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                             OPEN_EXISTING, 0, NULL);
    DWORD mode = 0, written = 0, error;
    BOOL has_mode, wrote;
    static const char text[] = "console: a-write through WriteConsoleA\n";

    probe_log("a-console GetConsoleWindow=%p stdout handle %p type %lu\n", (void *)GetConsoleWindow(), out,
              (out && out != INVALID_HANDLE_VALUE) ? GetFileType(out) : FILE_TYPE_UNKNOWN);
    error = con == INVALID_HANDLE_VALUE ? GetLastError() : 0;
    probe_log("CHECK a-conout CONOUT$ %p error %lu: %s\n", con, error, verdict(con != INVALID_HANDLE_VALUE));
    if (con == INVALID_HANDLE_VALUE) return;
    has_mode = GetConsoleMode(con, &mode);
    probe_log("CHECK a-mode GetConsoleMode %d mode %lx error %lu: %s\n", has_mode, mode,
              has_mode ? 0 : GetLastError(), verdict(has_mode));
    wrote = WriteConsoleA(con, text, (DWORD)strlen(text), &written, NULL);
    probe_log("CHECK a-write WriteConsoleA %d wrote %lu of %u: %s\n", wrote, written, (unsigned)strlen(text),
              verdict(wrote && written == strlen(text)));
    CloseHandle(con);
}

/* Runs cmdline, its output into a pipe when output is not NULL (the bytes
 * read into *output_len); returns the exit code, or -1 if it did not start or
 * end in time. */
static long run_child(const char *what, char *cmdline, DWORD flags, char *output, DWORD output_size,
                      DWORD *output_len)
{
    SECURITY_ATTRIBUTES inherit = {sizeof(inherit), NULL, TRUE};
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    HANDLE read_end = NULL, write_end = NULL;
    DWORD code = 0, got = 0, wait;

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    if (output) {
        output[0] = 0;
        if (!CreatePipe(&read_end, &write_end, &inherit, 0)) {
            probe_log("%s CreatePipe error %lu\n", what, GetLastError());
            return -1;
        }
        SetHandleInformation(read_end, HANDLE_FLAG_INHERIT, 0);
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        si.hStdOutput = write_end;
        si.hStdError = write_end;
    }
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, output != NULL, flags, NULL, NULL, &si, &pi)) {
        probe_log("%s CreateProcess \"%s\" error %lu\n", what, cmdline, GetLastError());
        if (output) {
            CloseHandle(read_end);
            CloseHandle(write_end);
        }
        return -1;
    }
    if (output) {
        CloseHandle(write_end);
        while (got + 1 < output_size) {
            DWORD n = 0;
            if (!ReadFile(read_end, output + got, output_size - 1 - got, &n, NULL) || !n) break;
            got += n;
        }
        output[got] = 0;
        *output_len = got;
        CloseHandle(read_end);
    }
    wait = WaitForSingleObject(pi.hProcess, CHILD_WAIT_MS);
    if (wait == WAIT_OBJECT_0) GetExitCodeProcess(pi.hProcess, &code);
    else probe_log("%s did not end in %d ms (wait %lu)\n", what, CHILD_WAIT_MS, wait);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return wait == WAIT_OBJECT_0 ? (long)code : -1;
}

static void phase_cmd_echo(void)
{
    static const char expected[] = CMD_MARKER "\r\n";
    char cmdline[] = "cmd.exe /c echo " CMD_MARKER;
    char output[512], shown[400];
    DWORD len = 0, i, n = 0;
    long code = run_child("b-echo", cmdline, 0, output, sizeof(output), &len);

    for (i = 0; i < len && n + 3 < sizeof(shown); i++) {
        if (output[i] == 0) { shown[n++] = '\\'; shown[n++] = '0'; }
        else if (output[i] != '\r' && !(output[i] == '\n' && i + 1 == len)) shown[n++] = output[i];
    }
    shown[n] = 0;
    probe_log("b-echo output %lu bytes \"%s\"\n", len, shown);
    probe_log("CHECK b-echo exit code %ld: %s\n", code, verdict(code == 0));
    probe_log("CHECK b-echo marker in its output: %s\n", verdict(memchr(output, 0, len) == NULL && strstr(output, CMD_MARKER) != NULL));
    probe_log("CHECK b-echo nothing else in the pipe: %s\n",
              verdict(len == strlen(expected) && !memcmp(output, expected, len)));
}

static void phase_cmd_new_console(void)
{
    char cmdline[] = "cmd.exe /c exit 7";
    long code = run_child("c-new-console", cmdline, CREATE_NEW_CONSOLE, NULL, 0, NULL);

    probe_log("CHECK c-new-console exit code %ld (7 expected): %s\n", code, verdict(code == 7));
}

int main(void)
{
    char dir[MAX_PATH], path[MAX_PATH + 16], *slash;

    GetModuleFileNameA(NULL, dir, sizeof(dir));
    if ((slash = strrchr(dir, '\\'))) *slash = 0;
    snprintf(path, sizeof(path), "%s\\console.log", dir);
    log_file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);
    probe_log("start: %d-bit console subsystem\n", (int)sizeof(void *) * 8);

    phase_console();
    phase_cmd_echo();
    phase_cmd_new_console();

    probe_log("done %s\n", failed ? "FAIL" : "ok");
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    return failed;
}
