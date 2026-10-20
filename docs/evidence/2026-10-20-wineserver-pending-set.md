# The wineserver reads only marked request fds: host checks (PLA-364, CPU lever 1)

**Linear:** PLA-364 (RDR2 gameplay CPU).
**Decision:** [0135](../decisions/0135-the-wineserver-reads-only-marked-request-fds.md).
**Change:** madeira-unix 0175 (`build/wineserver/pp_srv_pending.h`, `fd_ios.c`'s `main_loop`,
`server_call_unlocked`, `pthread_exit_wrapper`), test `tools/tests/test_srv_pending.py`.
**Switch:** `MADEIRA_SRV_PENDING`, on by default; the runtime key `env.MADEIRA_SRV_PENDING=0`
restores the old sweep.

**Phone gates not run.** This was built and checked on the host only, in a side worktree
(decision 0117). Neither the Hollow Knight gate, nor a Steam sign-in, nor RDR2 has run on this IPA.

## 1. Why: what run r3 showed

These figures are from the CPU research notes on run `20261020T081946-rdr2-r3`, read again in the
code. No new phone run was made.

- **The server thread.** It used 48–85 % of a core in RDR2's gameplay. Its samples were almost
  all `read+0x8 ← read_request ← thread_poll_event ← main_loop`.
- **The sweep.** The iOS `main_loop` (`fd_ios.c`, from madeira-unix 0021) set a synthetic `POLLIN`
  on every client fd and tried a non-blocking `read()` on each, every pass ("ioctl broken for
  AF_UNIX on iOS"). RDR2 had 220–280 threads, each with its own request pipe.
- **The wake.** `server_call_unlocked` signalled `ios_srv_wake_sem` after every request, and
  nothing drained it. The code's own `MADEIRA_SRV_NOSEM` comment records that once requests
  outrun the loop the count never reaches zero and the loop stops sleeping (2,935 passes/s
  measured, against a floor of about 1,000).
- **The request rate.** RDR2 made about 5–6 k requests a second, about 27 % of them
  `release_semaphore`.

## 2. The change

Decision 0135 describes it. In short:

- **The client marks its thread id** in a shared bitmap after it writes a request, and after it
  closes its request fd as it ends.
- **The server drains the bitmap** each pass and reads only those threads' request fds. Every
  other client fd is still read each pass.
- **A full sweep every 50 ms** reads every thread's request fd as well. A mark the set cannot
  hold asks for a full sweep at once.
- **The wake semaphore is signalled** only by the first mark after the loop re-arms.
- **INET `poll()`, the 1 ms timer tick and `MADEIRA_SRV_NOSEM` are unchanged.**
- **`ios_fd_is_inet` was already cached** per (poll user, fd) (ml579); the change adds no call to
  it. The new per-pass check that skips a thread's request fd is a few pointer reads, with no
  syscall.

## 3. Host tests

`tools/tests/test_srv_pending.py` takes `pp_srv_pending.h` out of the patch and compiles a C test
with `-Wall -Wextra -Werror`. All of it passed. It was also built once with
`-fsanitize=thread` (`cc` is GCC 16.2.1 on a 16-thread host): no report, and it passed.

- **Unit.** These cases pass:
  - an empty set drains nothing;
  - the first mark after a rearm signals, and later marks do not until the next rearm;
  - a duplicate mark is drained once, and marks drain in id order;
  - id 0, an id above 0xfffc and an id that is not a multiple of 4 each ask for one full sweep;
  - a quiet re-mark is pending but does not take the wake.
- **Concurrent marks and drains.** 16 threads each mark 50,000 times, spread over different words
  and summary words. Each waits until a drain has taken its mark; one drain loop rearms and
  drains. No mark was lost: a lost mark would hang the test until its 300 s timeout.
- **A server loop shaped like `main_loop`**, against client threads that make synchronous
  round trips over a request pipe and a reply pipe each. Each pass rearms, waits on a semaphore
  only if nothing is marked, drains and reads the marked pipes, and makes a full sweep when one
  is due. With no full sweep the wait is 1 s (it stands in for the 1 ms tick), so a lost wake
  would show as a timeout while a client is still waiting.

Typical results from the same machine follow. The timings vary with load; the counts in bold are
the asserted ones.

| Run | Requests | Wake signals | Passes | Failed reads | Wake timeouts |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 clients × 2,000 | 128,000 | 4,034 | 4,778 | **0** | **0** |
| 280 clients × 300 | 84,000 | 301 | 300 | **0** | **0** |
| 280 × 300, loop before 0175 | 84,000 | 84,000 | 300 | 0 | 0 |
| 280 × 100, clients wait 0–2 ms between requests | 28,000 | 9,506 | 12,571 | **0** | **0** |
| the same, loop before 0175 | 28,000 | 28,000 | 6,818 | 1,881,040 | 0 |
| 32 × 40, every 4th request unmarked, 50 ms sweep | 1,280 | 65 | 136 | **0** | n/a |

What the table shows:

- **With the pending set**, every request is read through its mark, exactly once, with no failed
  read, in every run. The asserted bound holds: there are at most passes + 1 wake signals, so the
  semaphore count cannot grow without limit.
- **The loop before 0175** signals once per request. When the clients wait between requests, as
  game threads do, it made 67 failed reads per request (280 pipes per pass). When the clients
  write in lock step, each pass finds every pipe full; that pattern is the host's, not a game's.
- **Unmarked requests.** In the last run, all 320 unmarked requests were served by a full sweep,
  and the test took about 0.5 s (ten 50 ms sweeps).

## 4. Build

- **Where.** This was built in the side worktree `.work/worktrees/srvpoll` (branch `srvpoll`),
  with reflinked copies of the main checkout's `cache`, `inputs`, `run`,
  `cef-src/out-stage-c` and `cef-src/notices`, and the build paths rewritten (0117).
- **The dev IPA.** `pp build` (dev) made `Playport-26.5-af0424f1.ipa`, sha256
  `af0424f15283a2a3e964218f1e761f58baf809d0d5fd27e177ff4d6df83ae2d3`. `verify-ipa` passed
  89 checks, and `pp verify` on the IPA reported 0 failures.
- **The compile.** `fd_ios.c` compiled with no diagnostics (`obj/err-fd_ios.txt` is empty). The
  `[srv-pending]` strings are in `libwineserver.a`.
- **Build records.** Only the `libntdll_unix.a` and `libwineserver.a` rows change. They are
  path-independent: built without 0175 in the copy, both archives matched the main checkout's
  committed rows byte for byte (`0505f9e1…`, `066f3580…`). The copy's `libdxmt_combined.a` and
  `libidevice_ffi.a` rows keep main's values (0117).
- **Main's `.work` was not written by the copy.** A marker was touched before the copy. Afterwards
  `find <main>/.work -path '*/worktrees' -prune -o -newer <marker> -print` listed 20,155 entries.
  All of them are the main session's own: its builds at 09:50 and 10:09–10:14, its mesa patch work
  in `run/mesa` (09:38–09:48 and 10:17), and its installs, `ui-runs` and agent notes. No entry's
  content names the copy's path.
- **A gap in the path rewrite.** Meson's pickled `coredata.dat` in the copy's `run/mesa/ios` and
  `ios-gl` still held main's cached compiler checks and host-tool paths (`mesa_clc`,
  `vtn_bindgen2`, `kk_clc` under main's `run/mesa/host`). The copy's vulkan stage may have run
  those tools from main's tree: a read, not a write. Its vulkan rows came out unchanged. A later
  copy should delete `run/mesa/{ios,ios-gl}` so that meson configures them afresh.

## 5. Phone checks still to run (main checkout, after the branch is rebased onto `main`)

1. **The Hollow Knight gate.** `./pp ui --play app-367520 --until first-frame+10 --shot`. The host
   log should have `[srv-pending] MADEIRA_SRV_PENDING=1`.
2. **A Steam sign-in.** It checks the CM ping budget and the INET path.
3. **RDR2 on the r3 route to gameplay.** Check the wineserver thread's `[thread-sample]` cpu %,
   the PROF-BT share of `read_request`, the `[srv]` rt per request, the fps, and the
   `[srv-pending]` heartbeat. Its `found` count should stay near 0, and no thread should hang.
4. **The `pp perf` A/B on RDR2**, with the switch on (the default) and off (runtime key
   `env.MADEIRA_SRV_PENDING=0`), from the same thermal state.
