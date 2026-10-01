# LLVM runtime notice collection (integrated superset, incomplete)

The exact-source payload blocker of the initial audit is
resolved for this collector, **not for binary derivation or legal release
approval**. The host-only continuation below integrates the standalone collection
without weakening its complete-directory verification contract.
`LICENSE`, `LICENSE-EXCEPTION.md` and `pins.lock` are unchanged.

## Reviewed source and lock

[The committed lock](../../build/llvm-runtime-notices.lock.json) records:

- LLVM `llvmorg-23.1.2`, commit
  `85ac560262434c9ccfc0c183ec22d4138ed647fb`, root tree
  `4094c6b0ce5e10ade6a508505b6fbb4ca8da3a71`;
- llvm-mingw `20260922`, commit
  `0eca5ac93da14a74bc81c249e841356ececc5d95`, root tree
  `a87876344eb7f65c3f6614ff96c8f45f1b32ee36`;
- Git blob IDs, SHA-256 and sizes for six release/build scripts and 21 mandatory
  root/credit/header inputs, plus the selection-policy identity.

Public source retrieval used a **new isolated** `.work/llvm-source` repository:
Git depth-one, blob-filtered fetch of the exact LLVM commit, with sparse checkout
of `libcxx`, `libcxxabi`, `libunwind`, `compiler-rt` and `clang/lib/Headers`.
Root files are included by cone-mode checkout. About 202 MB of source/metadata
was retained, not a toolchain or release binary archive. `git fsck --full` passed
with lazy fetching disabled. The commit/tree association was also read through
`gh-axi`'s public GitHub commit API. No independently verified publisher signature
is claimed. No existing shared input tree was fetched into, reset or checked out.

The existing clean llvm-mingw checkout was read only as script/default association
input. All six script hashes equal the preceding audit's reviewed hashes.
The collector verifies the exact commit and root-tree object hashes, script blob
bytes and checksums, and `build-llvm.sh`'s single repository/version default
assignments. Lock hashes for mandatory notices/credits are checked independently
of discovery. Defaults remain environment-overridable; this is **not** evidence
that installed runtime binaries were built with those defaults. The documented
22.04 versus reviewed Dockerfile 24.04 packaging discrepancy remains unresolved.

## Completed scope and inspected credits

[The collector](../../build/notices-llvm-runtime.py) scans every committed regular
file in the five subtrees above plus `LICENSE.TXT`. It copies recursively named
licence/notice/copyright/credits/authors files, every regular `LICENSES/` file,
and whole files containing case-insensitive credit/licence markers. Whole-file
copying preserves comment delimiters, complete embedded terms, non-UTF-8 bytes,
line endings and credits outside the first comment block. It intentionally
retains source code and false-positive marker matches rather than extracting or
reformatting a guessed licence paragraph. It is a large, unapplied superset,
including tests, tools, documentation, sanitizers and unrelated platforms.
Selected binary/NUL-bearing inputs fail rather than masquerading as notice text.

Mandatory inputs include the LLVM root licence, all four runtime root licences,
libc++/libc++abi/compiler-rt `CREDITS.TXT`, the builtins `README.txt` and inspected
header/source credit examples. Actual additional texts inspected and preserved:

| Source examples | Observed credit/terms, not an applicability conclusion |
| --- | --- |
| `libcxx/src/include/ryu/ryu.h` and recursive Ryu files | Ulf Adams and Microsoft; complete embedded Boost 1.0 text, alongside LLVM terms |
| `libcxx/src/include/to_chars_floating_point.h` | Microsoft copyright and dedication to Mary and Thavatchai |
| `libcxx/include/__format/{escaped_output,extended_grapheme_cluster,indic_conjunct_break,width_estimation}_table.h` | Unicode 1991–2022 copyright, permission conditions and disclaimer in generated data headers |
| `libcxx/include/__mdspan/extents.h` and related mdspan headers | NTESS/Sandia copyright, Kokkos identification and U.S. Government retained-rights statement |
| `libunwind/src/dwarf2.h` | Free Standards Group and UNIX International DWARF-constant attribution; not a separate permission determination |
| `compiler-rt/lib/BlocksRuntime/Block.h` and siblings | Apple 2008–2010 copyright and embedded MIT-style permission/disclaimer |
| `compiler-rt/lib/profile/WindowsMMap.c` | uClibc derivation, Mike Frysinger authorship and public-domain statement |
| `clang/lib/Headers/avxvnniintrin.h`, `cuda_wrappers/new` and other resource headers | Embedded MIT-style permission/disclaimer, not just the generic LLVM root text |

All these files are selected from verified source bytes. Examples listed in the
lock cannot be silently omitted. Other matching files are recursively collected,
not represented as individually reviewed. `libunwind/LICENSE.TXT` refers to
`CREDITS.TXT`, but that file is absent from this exact libunwind subtree; the
collector neither invents it nor claims the legacy contributor reference resolved.
There is no invented `clang/lib/Headers/LICENSE.txt` requirement. No LLVM 15
converter notice or installed generic notice was substituted.

## Interface and integration contract

Offline, read-only inputs; no fetch, checkout, reset, compiler or scratch Git
reconstruction occurs during collection. The lock must already be committed.
Supply a clean exact LLVM source checkout (all scoped files populated) and clean
exact llvm-mingw checkout. Sparse absent files **outside** the scope are supported.

```sh
python3 build/notices-llvm-runtime.py inspect . "$LLVM_RUNTIME_SOURCE" "$LLVM_MINGW_SOURCE"
python3 build/notices-llvm-runtime.py collect . "$LLVM_RUNTIME_SOURCE" "$LLVM_MINGW_SOURCE" .work/llvm-runtime-notices
python3 build/notices-llvm-runtime.py verify . "$LLVM_RUNTIME_SOURCE" "$LLVM_MINGW_SOURCE" .work/llvm-runtime-notices
```

`inspect` prints provenance JSON, writes nothing. `collect` requires a **new**
output directory whose parent exists. It stages privately beside that directory,
repeats source/lock/output validation, then publishes atomically with Linux
`renameat2(RENAME_NOREPLACE)`. Errors remove the stage and preserve existing or
racing destinations, including empty directories. Publication is Linux-specific
and fails closed if the no-replace primitive is unavailable.

Outputs: flat `llvm-runtime-*` byte copies, `llvm-runtime-provenance.json`,
`SCOPE.txt`, `SHA256SUMS`. Origins are source-relative with commit/tree/blob,
SHA-256/size, whole-file selector and discovery reasons; no workstation paths.
The manifest also records every scanned file, including unselected files.
`verify` regenerates the complete discovery/origin/lock manifest and all expected
bytes from current committed inputs, then checks the **entire** output file set,
texts, scope label and checksum list. Merely rewriting output checksums or origins
cannot legitimise changed/incomplete copies.

Symlinked paths/parents/Git metadata, non-regular scoped entries/gitlinks,
unsafe/control-character paths, dirty or wrong trees, staged/changed locks,
assume-unchanged or materialized skip-worktree inputs, untracked/ignored generated
files, missing mandatory/scanned payloads, flattened collisions and output/input
overlap fail. Output in the Playport repository's `.work` is expressly allowed;
output inside either supplied source checkout is not. Missing Git metadata must
fail offline, never lazy-fetch. Keep input trees immutable during use.

`pp notices` now adds this separate output as `llvm-runtime/`, retaining the
incomplete scope label, all texts, full origins and inner checksum list.
`notices-provenance.py` calls the original `verify` against the committed lock
and exact sources **before final inventory publication**. The outer inventory
and checksum list include every nested file, including the inner checksum list.
The tree gate requires this collection; deleting the entire directory cannot
silently remove it. No other nested inventory directories are accepted, and
flattening the LLVM collection into the root is rejected. Do not mark the broad
header/runtime coverage release item complete just because this collector succeeds.

## Host-only assembly continuation

Supply `LLVM_RUNTIME_SOURCE` and `LLVM_MINGW_SOURCE`; the LLVM source default is
`$PLAYPORT_BUILD/cache/llvm-runtime-notices`. These must be the runtime lock's
exact LLVM/llvm-mingw checkouts, not the separate LLVM 15 converter checkout.
Collection and verification remain offline and read only. The large roughly
82 MB superset is not staged into the app; eventual notice selection and resource
size require an applicability review, not unverified trimming.

Added nine integration regressions covering nested inventory, complete originals,
forged payload/origin/scope/checksums, required inputs/collection, symlinked/extra
folders, root-flattening refusal, outer/inner checksum coverage and whole-assembly
failure cleanup. Full unmodified `./pp test` passed: **361 Python tests**, four
available host C tests and Swift suites (27, 136 and 49; one sample skipped).
Gamepad C/ThreadSanitizer tests remain skipped for the absent Madeira submodule.

Exact-source collection and the actual outer inventory hook both passed for
**17,768 scanned files and 14,321 texts (81,916,394 payload bytes)**. Nested and
outer checksum verification passed. Local output/logs are private in
`.work/llvm-assembly-smoke`, `.work/llvm-assembly-smoke.log` and
`.work/llvm-assembly-full-tests.log`. This is an isolated assembly slice, not
complete branch notice/source packaging or an exact IPA. The same output was
then augmented with all 66 GStreamer payloads; combined inventory and checksum
verification passed (`.work/combined-notice-assembly-smoke.log`). No app/runtime
build, phone test, public push or upload.

## Checks and remaining blockers

- Targeted fixture suite: **23 tests**. Includes real Git sparse/offline inputs,
  exact-byte/path-independent copies, dirty/staged/hidden/untracked/unsafe/link
  input rejection, locks/defaults/mandatory credits, collisions, binary inputs,
  no-replace races, payload/manifest write rollback, prepublication source/lock
  changes, forged origins and complete output revalidation.
- Unmodified `./pp test --quick`: **273 Python tests**, names/secrets/patch gates
  and four available host C tests passed. Swift omitted by `--quick`;
  gamepad/ThreadSanitizer tests skipped for the absent Madeira submodule.
- Exact-source collect and verify smoke passed: **17,768 scanned files,
  14,321 collected whole-file texts (81,916,394 payload bytes)**. Eight are named
  root licence/credit files. Source scope counts (scanned/collected): libc++
  12,407/12,147; libc++abi 162/116; libunwind 78/57; compiler-rt 4,823/1,711;
  Clang resource headers 297/289; plus the LLVM root licence.
- Before the lock was committed in this worktree, smoke used identical pending
  lock bytes committed only in `.work/llvm-smoke-repo`, a disposable fixture.
  This is a collector/input smoke, not a release build. Inputs/output/logs remain
  private in `.work/llvm-source`, `.work/llvm-smoke-final`,
  `.work/llvm-smoke-final.log`, `.work/tests-llvm-runtime.log`,
  `.work/tests-quick.log` and `.work/llvm-source-fsck.log`.
- Python syntax, JSON syntax and `git diff --check` passed.

**Still open:** complete header/generated-data attribution (marker discovery is
not exhaustive); generated installed headers and sources outside these subtrees;
actual linked/header applicability and licence interpretations; libunwind's
legacy contributor reference; toolchain/runtime/local CRT binary derivation and
exact-IPA linkage; reviewed app notice selection/staging; full notices/source/relinking and all
publication/distribution approvals. Mingw-w64's Cephes FIXME is untouched. No
app/runtime build, phone use, account/release creation, upload or push occurred.
