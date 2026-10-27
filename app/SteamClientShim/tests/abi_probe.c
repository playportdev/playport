// SPDX-License-Identifier: GPL-3.0-or-later
// abi_probe.exe: calls every slot of every interface version of Playport's Steam client
// (steamclient.dll for i386, steamclient64.dll for x86-64) as MSVC's code would, under
// desktop Wine (tools/tests/test_steamclient_abi.py builds and runs it). For each slot:
// `this` in ECX (i386) or RCX, the slot's stack arguments as zeros (a hidden return pointer
// a buffer of 0xAA), and then checks that the slot popped exactly its arguments (i386: the
// callee pops), that a class it returns came back through the hidden pointer, and that a
// float it returns left the x87 stack balanced. Then the served methods' answers with no host.
//
//   abi_probe.exe DLL      prints "ok N slots" and exits 0, or the first failure and 1

#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../steamclient_slots.h"

typedef void *(*create_fn)(const char *, int *);

#ifdef __i386__
/* call_this(obj, fn, words, args, delta, fpu): calls fn with ECX = obj and `words` stack words
 * (args[0] nearest the return address); *delta is ESP after the call minus ESP before the
 * pushes (0 when the callee popped them), and with fpu non-NULL, st0 is stored there and the
 * status word after that in fpu[1] (its TOP: whether the stack is balanced again). */
uint64_t call_this(void *obj, void *fn, unsigned words, const uint32_t *args, int32_t *delta, double *fpu);
__asm__(
    ".text\n"
    ".globl _call_this\n"
    "_call_this:\n"
    "    pushl %ebp\n"
    "    movl %esp, %ebp\n"
    "    pushl %ebx\n"
    "    pushl %esi\n"
    "    pushl %edi\n"
    "    movl 16(%ebp), %ecx\n"
    "    movl 20(%ebp), %esi\n"
    "    movl %esp, %edi\n"
    "    leal (%esi,%ecx,4), %eax\n"
    "1:  testl %ecx, %ecx\n"
    "    jz 2f\n"
    "    subl $4, %eax\n"
    "    pushl (%eax)\n"
    "    decl %ecx\n"
    "    jmp 1b\n"
    "2:  movl 8(%ebp), %ecx\n"
    "    call *12(%ebp)\n"
    "    movl %esp, %ebx\n"
    "    subl %edi, %ebx\n"
    "    movl %edi, %esp\n"
    "    movl 24(%ebp), %ecx\n"
    "    movl %ebx, (%ecx)\n"
    "    movl 28(%ebp), %ecx\n"
    "    testl %ecx, %ecx\n"
    "    jz 3f\n"
    "    fstpl (%ecx)\n"
    "    fnstsw 8(%ecx)\n"
    "3:  popl %edi\n"
    "    popl %esi\n"
    "    popl %ebx\n"
    "    popl %ebp\n"
    "    ret\n");
#else
typedef uint64_t (*call6)(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
#endif

static int failures;
static void fail(const char *version, unsigned slot, const char *method, const char *what)
{
    if (failures++ < 20) printf("FAIL %s slot %u %s: %s\n", version, slot, method, what);
}

static uint8_t hidden_buf[64];

/* One slot, zeros for its arguments. Returns eax:edx (rax). */
static uint64_t call_slot(void *obj, unsigned slot, unsigned words, int hidden, int returns_float, const char *version,
                          const char *method)
{
    void **vt = *(void ***)obj;
    uint32_t args[64];
    uint64_t r;
    memset(args, 0, sizeof(args));
    memset(hidden_buf, 0xAA, sizeof(hidden_buf));
    if (hidden) args[0] = (uint32_t)(uintptr_t)hidden_buf;
#ifdef __i386__
    int32_t delta = 0x7777;
    double fpu[2] = { 1.5, 0 };
    r = call_this(obj, vt[slot], words, args, &delta, returns_float ? fpu : NULL);
    if (delta != 0) fail(version, slot, method, "the stack is off after the call");
    if (returns_float) {
        uint16_t sw = *(uint16_t *)&fpu[1];
        if (((sw >> 11) & 7) != 0) fail(version, slot, method, "the x87 stack is not balanced");
    }
#else
    (void)words; (void)returns_float;
    r = ((call6)vt[slot])(obj, hidden ? (uint64_t)(uintptr_t)hidden_buf : 0, 0, 0, 0, 0, 0, 0, 0);
#endif
    if (hidden) {
        if (r != (uint64_t)(uintptr_t)hidden_buf && (uint32_t)r != (uint32_t)(uintptr_t)hidden_buf)
            fail(version, slot, method, "the hidden return pointer did not come back");
        else if (hidden_buf[0] == 0xAA) fail(version, slot, method, "the returned class was not written");
    }
    return r;
}

typedef struct { const char *cls, *version, *const *names, *hidden, *floats; const unsigned char *words; unsigned slots; } entry;
#define ENTRY(n, v) { #n, v, pp_names_##n, pp_hidden_##n, pp_float_##n, pp_words_##n, PP_SLOTS_##n },
static const entry entries[] = { PP_SLOT_INTERFACES(ENTRY) };

static int find_slot(const entry *e, const char *method)
{
    for (unsigned i = 0; i < e->slots; i++) if (!strcmp(e->names[i], method)) return (int)i;
    return -1;
}

static const entry *entry_of(const char *version)
{
    for (size_t i = 0; i < sizeof(entries) / sizeof(*entries); i++) if (!strcmp(entries[i].version, version)) return &entries[i];
    return NULL;
}

int main(int argc, char **argv)
{
    HMODULE dll;
    create_fn create;
    unsigned calls = 0;
    if (argc < 2) return 2;
    dll = LoadLibraryA(argv[1]);
    if (!dll) { printf("FAIL cannot load %s (%lu)\n", argv[1], GetLastError()); return 1; }
    create = (create_fn)(void *)GetProcAddress(dll, "CreateInterface");
    if (!create) { printf("FAIL no CreateInterface\n"); return 1; }

    for (size_t i = 0; i < sizeof(entries) / sizeof(*entries); i++) {
        const entry *e = &entries[i];
        int code = 7;
        void *obj = create(e->version, &code);
        if (!obj || code != 0) { fail(e->version, 0, "-", "CreateInterface gave none"); continue; }
        for (unsigned s = 0; s < e->slots; s++) {
            call_slot(obj, s, e->words[s], e->hidden[s] == '1', e->floats[s] == '1', e->version, e->names[s]);
            calls++;
        }
    }

    /* Served answers with no host: what Steam's client says when nobody is logged on. */
    {
        int code;
        const entry *ce = entry_of("SteamClient012"), *ue = entry_of("SteamUser016"), *te = entry_of("SteamUtils005");
        void *client = create("SteamClient012", &code);
        if (!ce || !ue || !te || !client) fail("SteamClient012", 0, "-", "no old client");
        else {
            int pipe = (int)call_slot(client, (unsigned)find_slot(ce, "CreateSteamPipe"), 0, 0, 0, "SteamClient012", "CreateSteamPipe");
            if (pipe <= 0) fail("SteamClient012", 0, "CreateSteamPipe", "no pipe");
#ifdef __i386__
            {
                int32_t delta;
                uint32_t args[4] = { 0, 0, 0, 0 };
                args[0] = 1; args[1] = (uint32_t)pipe; args[2] = (uint32_t)(uintptr_t)"SteamUser016";
                void *user = (void *)(uintptr_t)(uint32_t)call_this(client, (*(void ***)client)[find_slot(ce, "GetISteamUser")], 3,
                                                                    args, &delta, NULL);
                if (!user || delta) fail("SteamClient012", 0, "GetISteamUser", "no SteamUser016");
                args[0] = (uint32_t)pipe; args[1] = (uint32_t)(uintptr_t)"SteamUtils005";
                void *utils = (void *)(uintptr_t)(uint32_t)call_this(client, (*(void ***)client)[find_slot(ce, "GetISteamUtils")], 2,
                                                                     args, &delta, NULL);
                if (!utils || delta) fail("SteamClient012", 0, "GetISteamUtils", "no SteamUtils005");
                if (user && (uint8_t)call_slot(user, (unsigned)find_slot(ue, "BLoggedOn"), 0, 0, 0, "SteamUser016", "BLoggedOn"))
                    fail("SteamUser016", 0, "BLoggedOn", "logged on with no host");
                if (user) call_slot(user, (unsigned)find_slot(ue, "GetSteamID"), 1, 1, 0, "SteamUser016", "GetSteamID");
                if (utils && (uint32_t)call_slot(utils, (unsigned)find_slot(te, "GetConnectedUniverse"), 0, 0, 0, "SteamUtils005",
                                                 "GetConnectedUniverse") != 1)
                    fail("SteamUtils005", 0, "GetConnectedUniverse", "not the public universe");
            }
#endif
        }
        /* A version no table has: x86-64 answers with trampolines, i386 with NULL. */
        void *unknown = create("SteamUser999", &code);
#ifdef __i386__
        if (unknown) fail("SteamUser999", 0, "-", "i386 answered a version it cannot size");
#else
        if (!unknown) fail("SteamUser999", 0, "-", "x86-64 did not answer an unknown version");
#endif
        if (create("NotSteam001", &code)) fail("NotSteam001", 0, "-", "answered a name that is no interface");
    }

    if (failures) { printf("%d failures in %u slot calls\n", failures, calls); return 1; }
    printf("ok %u slots in %u versions\n", calls, (unsigned)(sizeof(entries) / sizeof(*entries)));
    return 0;
}
