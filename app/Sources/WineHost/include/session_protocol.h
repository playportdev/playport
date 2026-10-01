/* SPDX-License-Identifier: GPL-3.0-or-later */
/* The session root's protocol (decisions 0027, 0030): how wine_host.c asks
 * playport-session.exe, the one Wine main process of an app run, to start
 * the run's one title as its child and learns how it ended. Both sides run in the app's one
 * Mach process; files in a directory of the prefix are only the transport,
 * written whole and renamed into place, never an entry point: the host writes
 * them only for a Play the UI started.
 *
 *   request   host -> root: a pp_session_request and its payload; the root
 *             reads it, deletes it and answers under the same sequence
 *   reply     root -> host: the last pp_session_reply, replaced whole
 *   control   host -> root, while the title runs: a pp_session_control from
 *             the in-game menu (pause, resume, close); the root reads it,
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
};

/* The most a CLOSE waits before it ends the title. */
#define PP_CONTROL_MAX_WAIT_MS 60000u

/* The payload of a LAUNCH, `length` bytes of NUL-terminated UTF-8 strings:
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
    return (c->kind == PP_CONTROL_PAUSE || c->kind == PP_CONTROL_RESUME) && c->arg == 0;
}

/* Whether a request and its payload are whole and well formed: every string
 * ends inside the payload, nothing follows the last, and the executable and
 * working directory are not empty. A malformed request must never start a
 * title, least of all the previous one. */
static inline int pp_session_request_valid(const pp_session_request *r, const char *payload, uint32_t size)
{
    uint32_t want, i = 0, at = 0;
    if (!r || r->magic != PP_SESSION_MAGIC || !r->sequence || r->length != size) return 0;
    if (r->kind != PP_REQUEST_LAUNCH || !payload || size > PP_SESSION_MAX_PAYLOAD ||
        r->argc > PP_SESSION_MAX_ARGS || r->envc > PP_SESSION_MAX_ENV) return 0;
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
