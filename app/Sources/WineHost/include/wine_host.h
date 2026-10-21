/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * wine_host — the small versioned C ABI between the S1Probe app and the
 * statically linked Madeira runtime (libntdll_unix.a, libwineserver.a,
 * libwin32u_unix.a, crypto statics). docs/ARCHITECTURE.md.
 *
 * Reference architecture: one Mach process, wineserver as a thread, each
 * guest "process" as a thread running __wine_main. The launch sequence
 * follows the reference app's WineServerBridge.m / WineProcessBridge.m
 * (willfaust/Madeira @ 97e2ce26e6, app/Madeira) as a pattern; no code is
 * copied from it.
 *
 * Call order, once per app process: wine_host_jit_pool_acquire →
 * wine_host_init → wine_host_session_start → (wine_host_session_prerequisite
 * → wine_host_session_wait)* → wine_host_session_launch → wine_host_session_wait. Every call is from one app thread at a time
 * (decisions 0027, 0030: one Wine session per app process, its one title a
 * child of its root; the app restarts itself after it, decision 0029).
 */

#ifndef WINE_HOST_H
#define WINE_HOST_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WINE_HOST_ABI_VERSION 11

typedef void (*wine_host_log_fn)(const char *line);

typedef struct {
    int abi_version;           /* WINE_HOST_ABI_VERSION */
    const char *runtime_dir;   /* holds aarch64-windows/, arm64ec-windows/, nls/ */
    const char *prefix_dir;    /* writable Wine prefix, created if absent */
    const char *log_path;      /* file the host, wineserver and stderr append to */
    wine_host_log_fn log;      /* optional; every host log line is also sent here */
    /* JIT pool: an RX region blessed by the debugger and its RW
     * alias. The ntdll layer reads it from WINE_IOS_JIT_{RX,RW,SIZE}; the FEX
     * PE takes the alias distance from WINE_IOS_JIT_RW and WINE_IOS_JIT_RX, and
     * refuses to start without them (patches/fex 0007). */
    void *jit_rx;
    void *jit_rw;
    size_t jit_size;
} wine_host_config;

int wine_host_abi_version(void);

#include "jit_debugger.h"

/* Acquire the JIT pool for wine_host_config through the universal debugserver
 * protocol (app/PlayportJIT/playport-universal.js): wait up to wait_ms for
 * a debugger to attach, have it allocate and bless size bytes
 * RX, map an RW alias, then detach. size is a multiple of 16 KiB. The pool is
 * placed in address space the executable reserves at exec (host_pool_reserve in
 * wine_host.c), which holds up to 896 MiB (the most a Play asks for:
 * PlayportKit JitPool sizes it from the memory limit); a larger pool is placed
 * first fit, as before the reservation. A placement must meet
 * selfcheck_pool_placement (selfcheck.h). Lines go to
 * log_path (opened if the host log is not yet open). 0 on success; -2 means no
 * live debugger at timeout or a breakpoint gate; -3..-5 mean the debugger
 * allocated nothing, the placement was refused, or the alias failed. -6 means
 * CS_DEBUGGED without a live tracer; -7 means its status could not be read.
 * Both brk sites recheck the tracer; on a failed gate no brk is issued at that
 * site. Protocol support and check-to-brk detach races remain unverified. */
int wine_host_jit_pool_acquire(const char *log_path, size_t size, int wait_ms, void **rx, void **rw);

/* The start-up self-check (selfcheck.h): the host page size and the TEB's TSD
 * mechanism, and with rx set the pool too (its placement, and a word written
 * through rw read back through rx). Returns SELFCHECK_OK or the first
 * assumption that fails; report gets the one-line verdict and facts. */
int wine_host_selfcheck(const void *rx, const void *rw, size_t size, char *report, size_t len);

/* Validate the config, publish the environment, link the prefix's system32
 * to the runtime's PE set and start the wineserver thread. 0 on success,
 * negative on error (the reason is logged). A config without a JIT pool is
 * refused: the reference layer cannot run guest code without one. */
int wine_host_init(const wine_host_config *config);

/* Start the session root, playport-session.exe (app/SessionRoot), as the
 * process's one __wine_main, and wait up to timeout_ms for it to be ready.
 * The root starts the title as its child (session_protocol.h), so that a
 * job holds the title and everything it starts. Once per process, after
 * wine_host_init. 0 when ready; -1 bad call or a second start, -2 the
 * prefix's system32 or session directory could not be made, -3/-4 the guest
 * thread could not start, -5 the root ended or did not answer in time. */
int wine_host_session_start(int timeout_ms);

/* Start the process's one title as the session root's child: the executable dos_path names
 * on drive C of the prefix (title_path_resolve, title_path.h: "C:\Games\T\t.exe",
 * "\Games\T\t.exe" or "Games\T\t.exe", matched case-insensitively), with its
 * own directory as the working directory, args[0..nargs-1] (at most 64, each
 * under 1024 bytes) as its arguments and env[0..nenv-1] (at most 128
 * "NAME=VALUE" entries) set over the root's environment for this title only.
 * The prefix's system32 is linked again first, with the launch's
 * overlays (PLAYPORT_DLL_OVERLAY). Everything the title starts runs in its job
 * and counts as the title. Waits up to timeout_ms for the root's answer.
 * Once per process: a second call is refused, whatever the first returned.
 * 0 started; -1 bad call (no session, a second launch, a prerequisite still
 * running, a malformed argument), -2 system32 could not be linked, -3 out of memory, -4 the
 * request could not be written, -5 dos_path does not resolve to a file, -6
 * the root ended or did not answer, -7 the root could not start it (the
 * Windows error is logged). */
int wine_host_session_launch(const char *dos_path, const char *const *args, int nargs,
                             const char *const *env, int nenv, int timeout_ms);

/* Before the title, one of its own prerequisite installers (decision 0079):
 * started as wine_host_session_launch starts the title, with the same
 * arguments, limits and returns, and waited for with wine_host_session_wait;
 * the controls reach it as they reach the title. One at a time, any number,
 * none after the title's launch. Added in ABI 6 without changing any existing
 * call. */
int wine_host_session_prerequisite(const char *dos_path, const char *const *args, int nargs,
                                   const char *const *env, int nenv, int timeout_ms);

/* wine_host_session_prerequisite with `line`, the command line after the
 * executable's quoted path, passed as it is rather than as arguments to quote: a
 * store's own command-line string, as its client passes it to CreateProcess (GOG's
 * redistributables, decision 0090). Added in ABI 7 without changing any existing call. */
int wine_host_session_prerequisite_line(const char *dos_path, const char *line,
                                        const char *const *env, int nenv, int timeout_ms);

/* Start services.exe, Wine's SCM, for this play (decision 0107), before any
 * prerequisite or the title; the root stops it and its services before it
 * reports the title's end. 0 when its SCM listens; -1 bad call (no session,
 * after the launch, or while a prerequisite runs), -4 the request could not
 * be written, -6 no answer in timeout_ms, -7 the root could not start it.
 * Added in ABI 8 without changing any existing call. */
int wine_host_session_services(int timeout_ms);

/* Make the session root the prefix's running Steam client for a play served by
 * Playport's steamclient64.dll (decision 0115): it writes its own process id as
 * HKCU\Software\Valve\Steam\ActiveProcess\pid and account_id as ActiveUser, and
 * sets both to 0 at the title's end. 0 once written; -1 bad call (no session,
 * after the launch, or while a prerequisite runs), -4 the request could not be
 * written, -6 no answer in timeout_ms, -7 the root could not write them.
 * Added in ABI 9 without changing any existing call. */
int wine_host_session_steam_client(unsigned account_id, int timeout_ms);

/* Wait up to timeout_ms for the running title (or prerequisite) and everything
 * it started to end. 0 and its exit code once they have, 1 on timeout, -1 with
 * nothing running, -2 when the root ended. */
int wine_host_session_wait(int timeout_ms, int *exit_code);

/* While the title runs, from any app thread but the one in
 * wine_host_session_wait: one of the in-game menu's controls to the session
 * root (session_protocol.h), waiting up to timeout_ms for its answer.
 * PP_CONTROL_PAUSE suspends every thread of the title's processes (each held
 * at a safe point by the wineserver), PP_CONTROL_RESUME lets them go, and
 * PP_CONTROL_CLOSE posts WM_CLOSE to the title's top-level windows and ends
 * its job wait_ms later if it is still running (wait_ms is only a CLOSE's, at
 * most PP_CONTROL_MAX_WAIT_MS). PP_CONTROL_END_LAUNCHER, the launch's own
 * at the game's sign-in (decision 0130), ends the Rockstar Games Launcher's
 * processes but never the game's; PP_CONTROL_END_GAME_SOCIAL_CLUB, a dev build's after the
 * sign-in (decision 0133), ends the game's own Social Club helpers but never the game;
 * PP_CONTROL_ALLOW_GAME_SOCIAL_CLUB, after a re-sign-in that follows that end (decision 0155),
 * stops the root ending their restarts, *count 1 when it did. 0 with *count the threads, windows or
 * processes it touched; -1 bad call or no title running, -4 the control could not be
 * written, -6 no answer in time or the root ended, -7 the root refused it.
 * Controls are one at a time (a lock). Added in ABI 3 without changing any
 * existing call. */
int wine_host_session_control(int kind, unsigned wait_ms, int timeout_ms, unsigned *count);

/* The JIT pool's use (Madeira virtual_ios.c ios_jit_pool_stats), in bytes or
 * counts. head is the head's bump cursor, the most of the pool image copies
 * and guest JIT blocks have reached; head_live and head_free are what live
 * modules hold and what dead processes gave back below it. tail is what FEX's
 * code buffers reserved from the top, tail_live the part in use. The
 * anonymous-alias table (guest JITs: Mono, V8) has alias_live entries in use,
 * alias_slots ever used, of alias_cap. images counts the pool's image
 * mappings, child_copies and child_bytes the private ntdll copies of
 * pseudo-processes. The last four count refusals a guest sees as failures:
 * the head had no room (head_exhausted), the tail refused a code buffer
 * (tail_refused; tail_fatal for one of 1 MiB or less, after which FEX
 * faults), the alias table had no slot (alias_full). head_trimmed is the
 * bytes image copies left out of their images (their trailing .rsrc and
 * .reloc, PLA-377) since the runtime started. 0 on success, -1 until
 * the runtime has taken the pool (as the first guest process starts). Added in ABI 1 without changing any
 * existing call; head_trimmed added at its end without changing one. */
typedef struct {
    unsigned long long size, head, head_live, head_free, tail, tail_live;
    unsigned long long alias_live, alias_slots, alias_cap, images, child_copies, child_bytes;
    unsigned long long head_exhausted, tail_refused, tail_fatal, alias_full;
    unsigned long long head_trimmed;
} wine_host_pool_stats;
int wine_host_pool_stats_read(wine_host_pool_stats *out);

/* The runtime's known limits (Madeira virtual_ios.c ios_runtime_limit_stats),
 * counts since the runtime started: W+X requests the kernel granted without
 * WRITE, which fail (wx_dropped); images whose x18 patching was refused or cut
 * short (x18_images) and the x18 sites left to fault at run time (x18_sites);
 * misaligned exclusives and CAS in native ARM64EC code emulated one at a time,
 * not atomic against other threads' plain stores (split_lock). 0 on success,
 * -1 for a NULL out. Added in ABI 1 without changing any existing call. */
typedef struct {
    unsigned long long wx_dropped, x18_images, x18_sites, split_lock;
} wine_host_limit_stats;
int wine_host_limit_stats_read(wine_host_limit_stats *out);

/* The FEX arena's use (Madeira virtual_ios.c ios_fex_band_stats), in bytes or
 * counts: the arena every emulator thread's host state lives in (its rpmalloc
 * spans, call-return stack and L1 lookup cache). used is what its views hold,
 * peak the most any reading saw, views their number, largest_free the largest
 * free range and span_slots the free 1 MiB-aligned 1 MiB blocks (new
 * rpmalloc spans that still fit). spans, callret and l1 count the views of
 * each kind (callret and l1: one per live emulator thread), other the bytes
 * of the rest. refused counts requests inside the arena it could not serve: a
 * thread that could not start, or an allocation the emulator could not make.
 * 0 on success, -1 before the runtime has an arena. Added in ABI 1 without
 * changing any existing call. */
typedef struct {
    unsigned long long size, used, peak, views, largest_free, span_slots;
    unsigned long long spans, callret, l1, other, refused;
} wine_host_band_stats;
int wine_host_band_stats_read(wine_host_band_stats *out);

/* The FEX arena's map into the log as `[band-map]` lines, runs of same-sized
 * views with the free space before each, headed by `why`. Added in ABI 1
 * without changing any existing call. */
void wine_host_band_dump(const char *why);

/* Memory by pseudo-process into the log as `[proc-mem]` lines (Madeira
 * virtual_ios.c ios_process_memory_log): each process's committed, resident
 * and compressed MiB in images, private memory and FEX's band, its FEX views
 * by kind, and the runtime's own, headed by `why` and what the walk cost.
 * It prints only when a process came or went or moved by 32 MiB since its
 * last print, or when `force` is nonzero; an unforced call within ten times
 * the last walk's cost after it does nothing. Added in ABI 10 without changing any
 * existing call. */
void wine_host_process_memory_log(const char *why, int force);

/* Allow (on nonzero) or refuse again (0) the game's later Social Club helper
 * starts that ntdll refuses under PLAYPORT_REFUSE_GAME_SC_RESTART=1 (decision
 * 0138): once the game signs in again after their end, its reload needs the
 * helper (decision 0155). Each start allowed is logged as `[game-sc] restart
 * allowed start N`. Any app thread. Added in ABI 11 without changing any
 * existing call. */
void wine_host_game_sc_allow_restarts(int on);

/* Bound the log a session writes (a release build, AppLog.swift). Call before
 * wine_host_jit_pool_acquire and wine_host_init. With a nonzero limit,
 * wine_host_init does not give the wineserver the log file (its own writes
 * would get past the limit), and a watchdog thread checks the file once a
 * second: once it reaches the limit, the watchdog logs one line saying so,
 * points stderr at /dev/null and closes the host's own handle, so nothing
 * more is written this session. 0, the default, is no limit. Added in ABI 1
 * without changing any existing call. */
void wine_host_set_log_limit(size_t bytes);

/* With no limit (a dev build), the runtime's lines past this many bytes of the
 * log in one session are counted, not written (log_cap.h). 256 MiB: a long
 * RDR2 run's whole log was about 40 MB. A literal, so Swift imports it
 * (AppLog.swift). */
#define WINE_HOST_DEV_LOG_CAP 268435456L

/* The host side of the game's Steam tickets (steam_ticket_protocol.h,
 * decision 0062): the calls playport_steam_unix_call_funcs (steam_ticket.c)
 * makes, on the game's thread, after it checked the block. Each returns an
 * NTSTATUS from steam_ticket_protocol.h and must not wait on the network.
 * hello answers 1 when the play's tickets are armed. create writes at most
 * cap bytes. Set (or cleared with NULL) from any app thread; with none set
 * every call answers PP_STEAM_NOT_SUPPORTED. Added in ABI 4 without changing
 * any existing call. */
typedef struct {
    unsigned (*hello)(void);
    unsigned (*create)(unsigned type, const char *identity, unsigned *handle,
                       unsigned char *ticket, unsigned cap, unsigned *size);
    unsigned (*status)(unsigned handle, unsigned *state, unsigned *eresult);
    unsigned (*cancel)(unsigned handle);
} wine_host_steam_ticket_provider;
void wine_host_set_steam_ticket_provider(const wine_host_steam_ticket_provider *provider);

/* The host side of Playport's URL opener (url_opener_protocol.h, decision
 * 0064): playport_url_unix_call_funcs (url_opener.c) calls open, on the
 * opener's thread, with a checked http(s) URL. It returns an NTSTATUS from
 * url_opener_protocol.h at once: it must not wait for the page or the main
 * thread. Set (or cleared with NULL) from any app thread; with none set the
 * call answers PP_URL_NOT_SUPPORTED. Added in ABI 5 without changing any
 * existing call. */
typedef struct {
    unsigned (*open)(const char *url);
} wine_host_url_opener;
void wine_host_set_url_opener(const wine_host_url_opener *opener);

/* The host side of Playport's steamclient64.dll (steam_client_protocol.h,
 * decision 0115): the calls playport_steamclient_unix_call_funcs
 * (steam_client.c) makes, on the guest's thread, with a block it checked.
 * Each returns an NTSTATUS from steam_client_protocol.h and must not wait on
 * the network. hello fills the snapshot's out fields and answers 1 when the
 * play is armed; call fills a CALL's out fields; poll a POLL's; log takes one
 * line of the shim's for the app log (a checked, NUL-terminated text). Set (or
 * cleared with NULL) from any app thread; with none set every call answers
 * PP_SC_NOT_SUPPORTED. Added in ABI 9 without changing any existing call. */
typedef struct {
    unsigned (*hello)(void *hello);   /* pp_sc_hello * */
    unsigned (*call)(void *call);     /* pp_sc_call * */
    unsigned (*poll)(void *poll);     /* pp_sc_poll * */
    void (*log)(const char *text);
} wine_host_steamclient_provider;
void wine_host_set_steamclient_provider(const wine_host_steamclient_provider *provider);

#ifdef __cplusplus
}
#endif

#endif /* WINE_HOST_H */
