# CEF 143.0.14, low address-space Windows x64 build

**Linear:** [PLA-370](https://linear.app/playportdev/issue/PLA-370).
[Decision 0110](../../docs/decisions/0110-own-cef-build-for-a-clients-cef.md),
[stage C evidence](../../docs/evidence/2026-10-16-cef-low-va-build.md).

CEF is built separately, **not by `pp build`**: allow about 200 GB and several
hours. These adapters preserve the stage C configuration. The prebuilt input is
`$PLAYPORT_BUILD/cef-src/out-stage-c`; its complete 233-file record is
`build/generated/cef-143.0.14.sha256`. Verify it without a build or download:

```sh
python3 build/cef/verify-payload.py
```

Missing or changed files fail; extra files are not part of the recorded input.
`Release/libcef.lib` is recorded for provenance but is an import library, not a
runtime file. The pipeline's dev `app` stage runs `stage-payload.py` before every
pack, including warm builds. It verifies all inputs before copying, omits that
library, and flattens `Release/` and `Resources/` into `Runtime/cef/143.0.14/`
(preserving `locales/`). xtool puts Runtime's directories at the app root, so the
installed path is `cef/143.0.14/`. The snapshot is mandatory: pointer compression
is disabled. Wine's file layer (patches/wine-unix 0039, guard in
`app/Sources/WineHost/cef_swap.c`) opens these files in place of a client's when
the client's `libcef.dll` has exactly file version 143.0.14.0.

Generate notices separately, from the pinned source tree, before `pp build`:

```sh
python3 build/cef/generate-notices.py
```

This runs Chromium's own `tools/licenses/licenses.py credits --target-os=win`,
the `components/resources:about_credits` action, without GN, ninja or an SDK.
It writes `$PLAYPORT_BUILD/cef-src/notices`: the generated `about_credits.html`,
CEF's BSD licence, FFmpeg's licence summary and LGPL-2.1 text, and the Playport
build notice (including the statically linked MSVC CRT under the owner-accepted
Visual Studio licence). Their hashes
are in `build/generated/cef-143.0.14-notices.sha256`; the dev stage requires them
and puts them under `cef/143.0.14/notices/`. The generated credits are identical
to stage C's about_credits output. Regeneration never updates the record silently.

The payload is authorized for **owner-only dev use**, never release, until the
owner decides otherwise. Release staging excludes it; `pp verify --variant
release` rejects it anywhere in the bundle. Dev verification checks its exact
runtime/notice set and hashes independently of the common `app/artifacts.tsv`.
`pp verify --distribution` also rejects a CEF-bearing dev IPA.

**Not yet distributable:** before any release or tester copy,
[PLA-372](https://linear.app/playportdev/issue/PLA-372) must add the CEF/Chromium
pins and patch series to the `pp source` catalog and meet the rebuild route and
FFmpeg source/relinking duties in [LICENSING.md](../../docs/LICENSING.md) and
[DISTRIBUTION.md](../../docs/DISTRIBUTION.md). Local sources/adapters are retained;
notices alone do not discharge those duties. No Microsoft redistributable DLL is in
this payload; the client retains its own d3dcompiler, dxcompiler and dxil. libcef
and chrome_elf nevertheless contain statically linked MSVC CRT code.

## Source and patch order

1. Check out `pins.lock`'s Chromium at `$PLAYPORT_BUILD/cef-src/src` and CEF at
   `src/cef`. Sync Chromium's DEPS for Windows as in stage A, using the pinned
   CEF checkout's configuration. CEF's automation script is not changed.
2. Apply `patches/cef/series` at `src/cef`.
3. Run CEF's version manager and stock patcher **once**. Stage A applied 107
   stock patches. This post-stock-patch tree, not bare Chromium, is the baseline
   for Playport's Chromium series.
4. Apply `patches/chromium/series` in order at `src`, with `git apply` **without
   `--index`**. Paths include nested DEPS repositories. ANGLE patches name
   `Upstream-repo: angle`, Dawn patches `Upstream-repo: dawn` and SwiftShader
   patches `Upstream-repo: swiftshader`. These are not independently pinned
   components. The source snapshot used here has ANGLE
   `2dfb5b7603d09c1d06f9d7a894752431d98b9a3e`, Dawn
   `479f62d2194fd6e44c37d07654ca6e41c42bd332` and SwiftShader
   `3d536c0fc62b1cdea0f78c3c38d79be559855b88`.
5. Never rerun the stock patcher over these changes. For regeneration use only
   `run-project-files.sh` below.

The formal series reproduces the 25 touched live source files byte-for-byte.
`pp test`'s series/trailer checker discovers all directories, including these
new ones without an allowlist. `pp sync` does have an allowlist: both are
classified in `NOT_REPLAYED` because they are built separately. The special pin
consistency check is only Madeira's gitlink; CEF/Chromium have no repository
gitlinks. Neither check replays these series or fetches their sources.

## Existing owner-provided toolchain

Agents must ask before touching xwin or Microsoft components. The owner already
accepted the licence and provided `cef-src/tools/xwin-sdk`. Do not download or
splat anything as part of these adapters. `create-xwin-layout.py` consumes that
existing input; it writes symlinks, `SetEnv.x64.json` and `overlay.json` under
`cef-src/tools/vs-xwin`. No generated layout or Microsoft file is committed.

Other pre-existing tools from stages A/B:

- Chromium's pinned clang-cl/lld-link, Linux rc hook, GN and ninja;
- `cef-src/depot_tools` (updates and Windows toolchain downloads disabled);
- `cef-src/tools/py-venv`, a Python venv without system site-packages;
- `cef-src/tools/gperf`, GNU gperf 3.1 built with `CXXFLAGS=-std=gnu++14`.
  Source tarball sha256:
  `588546b945bba4b70b6a3a616e80b4ab466e3f33024a352fc2198112cdbb3ae2`.

With those inputs already present, from the repository root, in Bash:

```sh
export PLAYPORT_BUILD="${PLAYPORT_BUILD:-$PWD/.work}"
export TMPDIR="$PLAYPORT_BUILD/tmp"
mkdir -p "$TMPDIR"
# Only after approval to use the existing owner-provided SDK:
python3 build/cef/create-xwin-layout.py
build/cef/run-project-files.sh
build/cef/run-ninja-lowva.sh run1 12
python3 build/cef/assemble-payload.py
python3 build/cef/generate-notices.py
```

`args.gn` holds the stage C settings; the GN wrapper appends the two local
SDK/layout paths, without storing workstation paths in the repository. The env
adapter keeps caches and temporary files under the build area. The wrappers
record the producer's exit code under `cef-src/logs` and return it to the caller;
redirect stdout/stderr there when launching the multi-hour build. No wrapper
performs a source sync, stock patch application, input download or IPA build.

`assemble-payload.py` copies only the recorded files from the ninja output into
`out-stage-c/Release` and `Resources`, preserving locale names and renaming the
import library `libcef.dll.lib` to `libcef.lib`. It verifies all hashes before
replacing an existing payload. A different build requires an explicitly reviewed
record update; records use byte filename order (`LC_ALL=C sort -k2`).
