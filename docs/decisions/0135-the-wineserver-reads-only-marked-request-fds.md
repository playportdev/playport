# 0135: The wineserver reads only the request fds of threads that marked one

**Status:** accepted, 2026-10-20, by the worker under the owner's brief for PLA-364 (CPU lever 1:
the brief asks for this change, an environment switch for the A/B, and a record if behaviour
changes). Phone gates not run yet: the change is on by default, and the main checkout's HK, Steam
and RDR2 runs confirm it or turn it off (below).

## Context

- **The cost.** In RDR2's gameplay (run `20261020T081946-rdr2-r3`) the wineserver thread used
  48–85 % of a core. Almost all its samples were in `read ← read_request ← thread_poll_event ←
  main_loop`.
- **Why.** The iOS server loop cannot poll its AF_UNIX client fds, so on every pass it set a
  synthetic `POLLIN` on every client fd and tried a non-blocking `read()` on each. With 220–280
  threads that was O(threads) failed syscalls per pass. The loop also stopped sleeping: every
  request signalled the wake semaphore and nothing drained it, so at 5–6 k requests a second its
  count never reached zero.
- **What is shared.** Server and clients are one process, and a client already signalled the
  server after each request (`server_call_unlocked`).

## Decision

- **A client marks its thread id** in a shared set (`pp_srv_pending.h`: a bitmap of thread ids
  with one summary word per 64 words) after it writes a request, and after it closes its request
  fd as it ends (`pthread_exit_wrapper`).
- **The server drains the set each pass** and reads only the marked threads' request fds. The
  sweep still reads every other client fd (the process sockets) on every pass.
- **A full sweep every 50 ms** also reads every thread's request fd: the net for a missed mark.
  An id the set cannot hold (0 before `init_first_thread`'s reply, or above 0xfffc) asks for one
  at once.
- **Edge cases.** A partly read request is marked again. A mark that arrives while the request fd
  waits for a reply's `POLLOUT` is retried on each pass and does not keep the loop awake.
- **The wake is coalesced.** Only the first mark since the loop last re-armed (once per pass,
  before it sleeps) signals the semaphore. The loop does not sleep while marks wait, so no mark
  waits for the 1 ms tick.
- **Unchanged.** INET fds keep their real zero-timeout `poll()` each pass, and the loop still
  wakes at least every 1 ms for timers, so Steam's CM pings keep their budget.
  `MADEIRA_SRV_NOSEM` keeps its meaning.
- **The switch.** `MADEIRA_SRV_PENDING=0` (runtime key `env.MADEIRA_SRV_PENDING=0`) restores the
  old sweep, for an A/B or as a fallback. The server reads it once, as its loop starts.
- **Logging.** At start: `[srv-pending] MADEIRA_SRV_PENDING=1|0`. With each 50,000-pass heartbeat:
  `[srv-pending] … marked= stale= partial= deferred= full= forced= found=`. `found` counts request
  fds that a full sweep found with a request waiting: a missed mark, or one that was about to be
  made.
- **Where.** madeira-unix 0175, `wineserver/pp_srv_pending.h`, `tools/tests/test_srv_pending.py`.

## Costs and risks

- **A missed mark costs up to 50 ms.** Every path that writes a request goes through
  `server_call_unlocked`, so only an unknown path would miss one. `found` shows whether it
  happens.
- **A thread that ends without `pthread_exit_wrapper`** (a crash) is seen as ended at the next
  full sweep, up to 50 ms later.
- **Every title is affected.** The server loop handles every request of every title and Steam's
  networking, so the change needs the Hollow Knight gate, a Steam sign-in and RDR2 on the phone.
  Until those runs, it is checked on the host only
  ([evidence](../evidence/2026-10-20-wineserver-pending-set.md)).
