# Descriptor sink: preserve append through Wine's fd import

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431).
Host-only A0 device-prep increment; no phone commands, install, gameplay, or A2.

## Cause and scope

`app/Sources/WineHost/wine_host.c:1291–1296` opens the log with
`O_WRONLY | O_CREAT | O_APPEND` and duplicates that open file description onto fd2.
The actual old arm64 wineserver archive's `fd_ios.o:create_anonymous_fd` passes
`F_SETFL=4, O_NONBLOCK=4`, with no preceding `F_GETFL` (retained disassembly under
`.work/agent-notes/kk-parity/sink-append/server-before.asm`).

Concrete import chain in the reconstructed build trees:

- `.work/run/unix/mythic/build/ntdll-unix/env_ios.c:1433–1435,1730` exports fd2
  via `wine_server_fd_to_handle`.
- `ntdll-unix/server_ios.c:3691–3706,3176–3225` sends it with `SCM_RIGHTS` and
  requests `alloc_file_handle`; `wineserver/request_ios.c:401–466` receives it.
- `.work/run/unix/wine/server/file.c:656–672,114–143` consumes the received fd
  and calls `create_anonymous_fd`.
- `mythic/build/wineserver/fd_ios.c:2874–2896` formerly replaced the status flags
  with `O_NONBLOCK` alone. SCM_RIGHTS, like dup, shares an **open file description**:
  this clears `O_APPEND` on the original fd2 as well as on the received alias.
  It needs no fd2 rebind, failed append open, stamp relay, or FEX syscall translation.

Darwin target preprocessing confirms `O_WRONLY=1`, `O_NONBLOCK=4`, `O_APPEND=8`.
The SDK has no `O_*` name for `0x10000`, but Apple's published kernel explains
it: [`FWASWRITTEN=0x10000`, `OFLAGS`, `FCNTLFLAGS`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/fcntl.h#L144-L245).
Its [`F_GETFL`/`F_SETFL` handlers](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_descrip.c#L2865-L2891)
return `OFLAGS(f_flag)` and replace only the `FCNTLFLAGS` subset, which includes
append/nonblock but not FWASWRITTEN or access mode. For a written write-only log,
the old setter yields kernel flags `0x10000 | FWRITE(2) | FNONBLOCK(4)`;
`OFLAGS` subtracts one, yielding **exactly `0x10005`**. Thus no unexplained
open flag or fd2 rebind is needed. This is supplemental primary-source evidence
(pinned public kernel revision, fetched 2026-10-24), not identification of the
phone's exact kernel build; excerpts/full sources stay in ignored scratch
(`xnu-flag-proof.txt`). The saved device record cannot prove which inode was
used or reconstruct the exact flag history. This is a concrete, artifact-confirmed,
real-fd-reproduced cause consistent with the complete value, not a new live trace.

Append open/dup2 itself preserves append. Failed initialization could retain an
older fd, but does not specifically predict NONBLOCK; there is no recorded
initialization syscall failure. Stamp installs a FIFO; release cap installs a
pipe then null, and the dev cap installs null: none predicts a regular fd.
HostIO's direct append fallback changes neither fd2 nor its flags. Wine's
`set_stdio_fd` touches only 0/1. The FEX Windows emulator is not the Mach
libSystem fcntl path here. Socket-only setters do not explain a regular log;
`create_anonymous_fd` explicitly covers imported regular stdio descriptors.
The previously established full-log stamp/cap contradictions remain unchanged.

## Repair and retained fail-closed transport

Madeira-unix **0221** preserves queried flags when adding NONBLOCK. Its P2
hardening retains the legacy SETFL(NONBLOCK) fallback if GETFL fails, prioritizing
non-blocking busy-polling over unknown flags (including append). The emitter
still rejects a non-append regular sink. This tightly related second patch is
necessary because the proven setter lives in Madeira, not Mesa; the upstream
pin and vendored checkout are unchanged. Mesa **0125** keeps the regular-file
append requirement, FIFO PIPE_BUF bound, single whole-row write, EINTR limit,
permanent failure latch and errno restoration. No independent sink, EOF seek,
second log file, relaxed shared-file rule, new measurement, or accepted v1 schema.

For any unexpected rejection, 0125 adds exact `sink_dev`/`sink_ino` after a
successful fstat. Only the Darwin missing-append branch queries F_GETPATH:
`sink_path_tail_hex` encodes the last at most 64 path bytes and
`sink_path_truncated` explicitly distinguishes a suffix from a full path.
Failure emits `sink_path=unavailable sink_path_errno=N`, capturing that query's
errno immediately, not attributing it to the logical append predicate. These
failure-only additions stay within the 512-byte poison buffer, retain every
0124 stage name, and remain **malformed diagnostic poison**, not accepted rows.
Strict-parser fixtures explicitly retain old/new source poisoning. The strict
consumer implementation is unchanged.

An independently opened same-file sink was deliberately not chosen: its append
writes could be overwritten by fd2's stale, non-append offset. Repairing the
shared description restores the app's intended append contract for all aliases.
Other writers can still split their own records; arbitrary future fd rebinding
or concurrent status-flag mutation is not made safe by a GETFL check.

## Initial verification (before P2 hardening)

The GETFL-error behavior below is historical; the P2 closure supersedes it.
All retained initial check logs are under `.work/agent-notes/kk-parity/sink-append/`.

- **Red before repair:** `red/server-import-1.stdout` reports
  `server-import: shared fd2 append=0 nonblock=1`; actual source setter + real
  SCM_RIGHTS import fails the append assertion (producer exit1). Metadata test
  `identity-red.log` fails against 0124's emitter, which has no sink identity.
- **Green:** `final-focused.log`, exit0, 38 seeded real-emitter cases. Imported
  regular fd2 retains append/nonblock and emits 1 banner, 16 calibration rows
  and 20 snapshot rows; strict CLI accepts its interval. Failed setter GETFL
  performs zero SETFLs and preserves append. Existing actual open/dup2/FIFO,
  unsupported/null, append loss after init, errno/latch, pipe bounds, short/error/
  EINTR and independent-writer stress branches remain covered. F_GETPATH alone
  is simulated on Linux: full/whitespace/newline, 1023-byte suffix, unavailable
  and query-errno cases pass, all poisons bounded and strictly rejected.
- **Full Mesa host suite:** producer exit0 (`mesa-host.log`). `kk-host-test`:
  `all 26 pipelines built and drawn`; Zink `zink-host-test: ok`. Replay:
  `secondary recorded/executed1/executed2/submitted=0/1/2/2; reusable
  recorded/submit1/submit2/submit3=3/3/4/5 (bind, push, push_template each)`.
  `descriptor MSL: 236 off/on identical files`. Additionally, all **236/236**
  files match the historical `emission-reasons-baseline-msl` bytes/names;
  **185/185** initial flag-off files match the immediate pre-chunk copy
  (`msl-identity.txt`). No MSL changed or was added.
- **Parser:** 34 fixture tests pass, including old/new poison rejection with
  zero usable intervals. Consumer implementation is byte-identical to initial
  HEAD. Twelve entire saved raws run through both CLI modes remain exit1,
  zero usable intervals and byte-identical to the committed consumer's result.
  Primary original/retry/reason captures retain **86/60/20** rejected intervals
  and **17/2/2** malformed records. Ninety-one raw/parser artifacts retain their
  hashes. Current saved original/retry/reason JSON outputs also compare equal;
  no filtering, reconstruction, normalization or cross-layer subtraction.
- **Repository host gates:** `pp test --quick` exit0, **761 tools tests** and
  host C tests (including their TSAN/ASAN checks), `pp test: all passed`
  (`quick.log`). `pp names: clean`; `pp secrets: clean`.
- **Dev IPA:** `./pp build` producer exit0 (`build.log`),
  `.work/out/20261024-152847-eff44cd0/Playport-26.5-eff44cd0.ipa`, SHA256
  **`eff44cd0665a86cec97aa1d75ff42054d6fe039c6ba0e9827a9d14f9fd021022`**;
  `verify-ipa: 89 checks passed, 0 failed`. Built from the pre-commit chunk
  working tree on `1570ff0`; not a claim of clean-HEAD archive provenance.
  **Uninstalled.** Actual packaged app `_create_anonymous_fd` at `0x1009d61a4`
  now calls GETFL=3, branches on -1, ORs the result with 4, then calls SETFL=4
  (`ipa-server-after.asm`, also corroborated by `server-after.asm`). Packaged
  KosmicKrisp contains the new sink-identity/path-error literals. The only build
  record change is `app/artifacts.tsv`'s libwineserver archive row
  (1,214,424 bytes, SHA256 `2491374215256cf862f03b95915df34dc5f32df0d9777b536f7ee30f35d28294`);
  Wine PE TSV records unchanged. Patched Mesa/server sources reconstruct
  byte-for-byte from their series; no direct vendored-tree deliverable or pin
  movement.

No sink behavior is device-verified. The new IPA must remain **uninstalled**;
next authorized capture must observe the native banner, 16 calibration rows and
complete 10-row captures, or retain the new sink-identifying poison. Native
values in old logs remain unobserved, never zero. Failure-time stat/flags/path
queries do not form an atomic snapshot against arbitrary concurrent rebinding;
path suffixes are not full paths. A0 justification/A2 remain gated.
**Games observed: none.**

## P2 closure: GETFL failure keeps the fd non-blocking

The independent review of `1a2c06d` accepted the chunk with one P2: on a failed
`F_GETFL` the imported fd kept its blocking status, losing the one guarantee the
old unconditional `F_SETFL(O_NONBLOCK)` provided under iOS busy-polling (no
epoll/kqueue). The writer's continuation of that session ended before it could
finish its checks, so the supervisor completed the verification and committed it;
all numbers below are the supervisor's own reruns on this working tree.

- **Patch.** `madeira-unix` 0221 now reads `flags = F_GETFL(unix_fd);` then
  `F_SETFL, flags | O_NONBLOCK` on success and `F_SETFL, O_NONBLOCK` on failure.
  Unknown flags (including append) cannot be preserved on that fallback, and the
  emitter still rejects a non-append regular sink, so the diagnostic stays
  fail-closed. The patch body and `Subject` describe both paths; the tree
  reconstructs from the series (`madeira-unix: 189 patches on c3b84da17ae2` →
  `f5dc1468`).
- **Red before, green after.** The old test had encoded the P2 as expected
  behaviour: `assert(!!(current & O_NONBLOCK) == !query_failed)` and
  `assert(server_sets == !query_failed)`. Against the unhardened 0221 the real
  `SCM_RIGHTS` seam aborts (`p2-append/red.log`, `SIGABRT` in
  `server-import-getfl-error`). After the hunk the same case asserts
  `current & O_NONBLOCK`, `append` only when the query succeeded, and exactly one
  `SETFL` on either path, and the full suite passes.
- **Full Mesa host suite** (`p2-append/mesa-host-final.log`, producer exit0):
  `all 26 pipelines built and drawn`; `descriptor replay: secondary
  recorded/executed1/executed2/submitted=0/1/2/2; reusable
  recorded/submit1/submit2/submit3=3/3/4/5 (bind, push, push_template each)`;
  `descriptor MSL: 236 off/on identical files`; `zink-host-test: ok`. Imported
  aliases emit 20 strict-schema rows with 0 malformed; the rejected
  `server-import-getfl-error` sink poisons once with `sink_dev`/`sink_ino`.
- **Parser and repository gates:** 34 fixture tests pass; `pp test --quick` exit0
  with **761 tools tests** and the host C tests (`p2-append/quick-final.log`);
  `pp names: clean`; `pp secrets: clean`.
- **Dev IPA:** `.work/out/20261024-205911-31430e96/Playport-26.5-31430e96.ipa`,
  SHA256 **`31430e9639275c6df96aa70c9905bd6f5f398dbd80b2d7d28355bbcfa50b1122`**,
  `verify-ipa: 89 checks passed, 0 failed` (`p2-append/build-final.log`). Build
  record: only `app/artifacts.tsv`'s libwineserver row changed again
  (1,214,432 bytes, SHA256
  `78f505018ee5ac887b8d8f7f77e9716662e28108cb17feeb432f0c273865399f`); Wine PE
  rows unchanged. **Uninstalled.**

Still unverified: everything device-side. A fresh authorized capture must show the
native banner, 16 calibration rows and complete 10-row captures, or retain the
new sink-identifying poison; A0 justification and A2 remain gated.
