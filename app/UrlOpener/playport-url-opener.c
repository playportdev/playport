// SPDX-License-Identifier: GPL-3.0-or-later
// playport-url-opener.exe: the prefix's http and https handler (decision 0064).
//
// A game that opens a web page calls ShellExecute (or `start`, or Unity's
// Application.OpenURL) on an http or https URL; shell32 runs the command the
// prefix registry seed gives the scheme (app/tools/prefix-registry.py
// ASSOCIATIONS): this program with the URL as its one argument. It hands the
// URL to the host app through the unix call table the runtime gives its
// export name (url_opener_protocol.h, patches/madeira-unix), and exits: 0
// when the host took it, 1 when it refused it or there is no host. It never
// waits for the page; the game polls its own sign-in.
//
// x86-64, as every title is, GUI subsystem (no console, so no conhost),
// kernel32 only, no C runtime. It logs a `url-opener:` line on stderr (the app
// log) only when the URL is refused, without the URL.

#include <windows.h>
#include "../Sources/WineHost/include/url_opener_protocol.h"

extern IMAGE_DOS_HEADER __ImageBase;

typedef LONG (NTAPI *query_virtual_memory_fn)(HANDLE, const void *, ULONG, void *, SIZE_T, SIZE_T *);
typedef LONG (NTAPI *wine_unix_call_fn)(UINT64, unsigned int, void *);

#define MemoryWineLoadUnixLib 1000

// The export that gives the image an export directory named
// playport-url-opener.exe, which the runtime matches.
__declspec(dllexport) const unsigned playport_url_opener_protocol = PP_URL_PROTOCOL;

void *memset(void *d, int c, size_t n)
{
    volatile unsigned char *p = d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}

static pp_url_open block;

static void say(const char *what, unsigned long status)
{
    char buf[96];
    int n = 0;
    const char *p;
    DWORD w;
    for (p = "url-opener: "; *p; p++) buf[n++] = *p;
    for (p = what; *p && n < 80; p++) buf[n++] = *p;
    if (status) {
        int i;
        buf[n++] = ' ';
        buf[n++] = '0';
        buf[n++] = 'x';
        for (i = 28; i >= 0; i -= 4) buf[n++] = "0123456789abcdef"[(status >> i) & 15];
    }
    buf[n++] = '\n';
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), buf, n, &w, NULL);
}

// The URL from the command line: the program's path, then the URL, quoted or
// not, as UTF-8 in block.url. 0 when there is none or it does not fit.
static int url_argument(void)
{
    const WCHAR *c = GetCommandLineW();
    int n = 0, len;
    if (*c == '"') { c++; while (*c && *c != '"') c++; if (*c) c++; }
    else while (*c && *c != ' ' && *c != '\t') c++;
    while (*c == ' ' || *c == '\t') c++;
    if (*c == '"') {
        c++;
        while (c[n] && c[n] != '"') n++;
    } else {
        while (c[n] && c[n] != ' ' && c[n] != '\t') n++;
    }
    if (!n) return 0;
    len = WideCharToMultiByte(CP_UTF8, 0, c, n, block.url, PP_URL_MAX - 1, NULL, NULL);
    if (len <= 0) return 0;
    block.url[len] = 0;
    return 1;
}

void __stdcall entry(void)
{
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    query_virtual_memory_fn query;
    wine_unix_call_fn call;
    UINT64 handle = 0;
    LONG status;

    block.magic = PP_URL_MAGIC;
    block.size = sizeof(block);
    block.version = PP_URL_PROTOCOL;
    if (!url_argument() || !pp_url_block_valid(&block)) {
        say("refused: not an http or https URL of at most 2047 bytes", 0);
        ExitProcess(1);
    }
    query = ntdll ? (query_virtual_memory_fn)GetProcAddress(ntdll, "NtQueryVirtualMemory") : NULL;
    call = ntdll ? (wine_unix_call_fn)GetProcAddress(ntdll, "__wine_unix_call") : NULL;
    if (!query || !call
        || query(GetCurrentProcess(), &__ImageBase, MemoryWineLoadUnixLib, &handle, sizeof(handle), NULL) != 0
        || !handle) {
        say("no host", 0);
        ExitProcess(1);
    }
    status = call(handle, PP_URL_OPEN, &block);
    if (status != 0) {
        say("refused by the host", (unsigned long)status);
        ExitProcess(1);
    }
    ExitProcess(0);
}
