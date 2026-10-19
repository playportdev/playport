/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The session root's protocol (decisions 0027, 0030): how wine_host.c asks
 * playport-session.exe, the one Wine main process of an app run, to start
 * the run's one title as its child and learns how it ended, and before it the
 * title's own prerequisite installers (decision 0079). Both sides run in the app's one
 * Mach process; files in a directory of the prefix are only the transport,
 * written whole and renamed into place, never an entry point: the host writes
 * them only for a Play the UI started.
 *
 *   request   host -> root: a pp_session_request and its payload; the root
 *             reads it, deletes it and answers under the same sequence
 *   reply     root -> host: the last pp_session_reply, replaced whole
 *   control   host -> root, while the title runs: a pp_session_control from
 *             the in-game menu (pause, resume, close), or the launch's own
 *             (end the launcher once the game signed in); the root reads it,
 *             deletes it and answers in control-reply under its sequence
 *
 * Shared by the host (C, libc) and the root (freestanding x86-64 PE): no
 * library calls here. */
#ifndef PLAYPORT_SESSION_PROTOCOL_H
#define PLAYPORT_SESSION_PROTOCOL_H

#include <stdint.h>

#define PP_SESSION_MAGIC 0x32535050u          /* "PPS2" */
#define PP_SESSION_MAX_PAYLOAD (128u * 1024u)
#define PP_SESSION_MAX_ARGS 64u
#define PP_SESSION_MAX_ENV 128u

/* The session directory, relative to the prefix's drive_c and as the root sees it. */
#define PP_SESSION_DIR_UNIX "drive_c/users/playport/AppData/Local/Playport/session"
#define PP_SESSION_DIR_DOS "C:\\users\\playport\\AppData\\Local\\Playport\\session"
#define PP_SESSION_ROOT_DOS "C:\\windows\\system32\\playport-session.exe"

enum {
    PP_REQUEST_LAUNCH = 1,
    /* Controls, while the title runs (the in-game menu). */
    PP_CONTROL_PAUSE = 2,   /* suspend every thread of the title's processes */
    PP_CONTROL_RESUME = 3,  /* resume the threads PAUSE suspended */
    PP_CONTROL_CLOSE = 4,   /* WM_CLOSE to the title's top-level windows; arg ms
                               later, a title still running is ended (its job) */
    /* A title's own prerequisite installer (decision 0079), before the title:
     * started, waited for and answered as a LAUNCH is (STARTED, EXITED,
     * REFUSED), and the controls reach it; then the root takes the next request. */
    PP_REQUEST_PREREQUISITE = 5,
    /* A PREREQUISITE whose one argument is the command line after the executable's
     * quoted path, used as it is: a store's own command-line string, as its client
     * passes it to CreateProcess (GOG's nested quotes, decision 0090). */
    PP_REQUEST_PREREQUISITE_LINE = 6,
    /* The Windows services of a play that needs them (decision 0107): the root starts
     * services.exe, Wine's SCM, outside the title's job, and answers STARTED (its process
     * id) once the SCM listens, or REFUSED; no payload. The services it starts are stopped
     * before the title's end is reported. */
    PP_REQUEST_SERVICES = 7,
    /* A play served by Playport's steamclient64.dll (decision 0115): the root writes
     * HKCU\Software\Valve\Steam\ActiveProcess's pid (its own process id) and ActiveUser
     * (the payload: one argument, the account ID in decimal), and answers STARTED (its
     * process id) or REFUSED. It sets both to 0 at the title's end, and at its own start
     * when a crash left them. */
    PP_REQUEST_STEAM_CLIENT = 8,
    /* A control, while the title runs: the game has signed in, or the app's footprint is
     * near its limit (decision 0130, amending 0125), so the root ends the Rockstar Games Launcher's tree in the
     * title's job in one step, never the game or a process under it (launcher_end.h):
     * Launcher.exe, RockstarErrorHandler.exe and the launcher's SocialClubHelper.exe
     * processes. Then it counts every start of those images, ends the first restarts it
     * finds running once more, and reports the rest. It carries no names or arg; code is
     * the processes it ended. */
    PP_CONTROL_END_LAUNCHER = 9,
};

/* The most a CLOSE waits before it ends the title. */
#define PP_CONTROL_MAX_WAIT_MS 60000u

/* The payload of a LAUNCH or a PREREQUISITE (or PREREQUISITE_LINE), `length` bytes of NUL-terminated UTF-8 strings:
 * the executable's DOS path, its working directory, argc arguments and envc
 * `NAME=VALUE` variables set over the root's own environment for this title
 * only. */
typedef struct {
    uint32_t magic, sequence, kind, length, argc, envc;
} pp_session_request;

enum {
    PP_ROOT_READY = 1,      /* sequence 0: the root runs; code is its process id */
    PP_TITLE_STARTED = 2,   /* code is the title's process id */
    PP_TITLE_EXITED = 3,    /* the title and every process it started have ended; code is its exit code */
    PP_TITLE_REFUSED = 4,   /* nothing was started; code is the Windows error */
    PP_CONTROL_DONE = 5,    /* control-reply: done; code is the threads or windows it touched */
    PP_CONTROL_REFUSED = 6, /* control-reply: malformed, or no title runs; code is the Windows error */
};

typedef struct {
    uint32_t magic, sequence, state, code;
} pp_session_reply;

/* A control; nothing follows it in the file. */
typedef struct {
    uint32_t magic, sequence, kind, arg;
} pp_session_control;

/* Whether a control is whole and well formed: a known kind, a sequence, and
 * an arg only a CLOSE has (its wait, at most PP_CONTROL_MAX_WAIT_MS). */
static inline int pp_session_control_valid(const pp_session_control *c, uint32_t size)
{
    if (!c || size != sizeof(*c) || c->magic != PP_SESSION_MAGIC || !c->sequence) return 0;
    if (c->kind == PP_CONTROL_CLOSE) return c->arg <= PP_CONTROL_MAX_WAIT_MS;
    return (c->kind == PP_CONTROL_PAUSE || c->kind == PP_CONTROL_RESUME || c->kind == PP_CONTROL_END_LAUNCHER) &&
           c->arg == 0;
}

/* Whether a request and its payload are whole and well formed: every string
 * ends inside the payload, nothing follows the last, and the executable and
 * working directory are not empty. A malformed request must never start a
 * title, least of all the previous one. */
static inline int pp_session_request_valid(const pp_session_request *r, const char *payload, uint32_t size)
{
    uint32_t want, i = 0, at = 0;
    if (!r || r->magic != PP_SESSION_MAGIC || !r->sequence || r->length != size) return 0;
    if (r->kind == PP_REQUEST_SERVICES) return size == 0 && r->argc == 0 && r->envc == 0;
    if (r->kind == PP_REQUEST_STEAM_CLIENT) {
        /* One decimal account ID that fits a DWORD: 1 to 10 digits, then its NUL. */
        uint64_t v = 0;
        if (r->argc != 1 || r->envc != 0 || !payload || size < 2 || size > 11 || payload[size - 1]) return 0;
        for (i = 0; i + 1 < size; i++) {
            if (payload[i] < '0' || payload[i] > '9') return 0;
            v = v * 10 + (uint64_t)(payload[i] - '0');
        }
        return v <= 0xffffffffu;
    }
    if ((r->kind != PP_REQUEST_LAUNCH && r->kind != PP_REQUEST_PREREQUISITE && r->kind != PP_REQUEST_PREREQUISITE_LINE) ||
        !payload || size > PP_SESSION_MAX_PAYLOAD || r->argc > PP_SESSION_MAX_ARGS || r->envc > PP_SESSION_MAX_ENV) return 0;
    if (r->kind == PP_REQUEST_PREREQUISITE_LINE && r->argc != 1) return 0;
    want = 2 + r->argc + r->envc;
    while (i < want) {
        uint32_t start = at;
        while (at < size && payload[at]) at++;
        if (at == size) return 0;                 /* a string runs past the end */
        if (i < 2 && at == start) return 0;       /* no executable or directory */
        if (i >= 2 + r->argc) {                   /* NAME=VALUE with a name */
            uint32_t eq = start;
            while (eq < at && payload[eq] != '=') eq++;
            if (eq == start || eq == at) return 0;
        }
        at++;
        i++;
    }
    return at == size;
}

#endif
