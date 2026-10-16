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
runtime file. Future packing must use only the verified list, omit that library,
and flatten `Release/` and `Resources/` into `Runtime/cef/143.0.14/` (preserving
`locales/`). The snapshot is mandatory: pointer compression is disabled.

**Stage D integration is not done yet:** neither packing nor the loader swap is
wired up. The payload is authorized for **dev only**, never release, until the
owner decides otherwise. Before packing, also include CEF's BSD licence and
Chromium's generated credits and meet ffmpeg's source/relinking duties (0110).
Those notices are not in the stage C payload record. No Microsoft redistributable
is in this payload; the client retains its own d3dcompiler, dxcompiler and dxil.

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
   `Upstream-repo: angle`; Dawn patches name `Upstream-repo: dawn`. These are not
   independently pinned components. The source snapshot used here has ANGLE
   `2dfb5b7603d09c1d06f9d7a894752431d98b9a3e` and Dawn
   `479f62d2194fd6e44c37d07654ca6e41c42bd332`.
5. Never rerun the stock patcher over these changes. For regeneration use only
   `run-project-files.sh` below.

The formal series reproduces the 14 touched live source files byte-for-byte.
`pp test`'s series/trailer checker discovers all directories, including these
new ones; it needs no target allowlist extension. Its special pin consistency
check is only Madeira's gitlink; CEF/Chromium have no repository gitlinks.
It does not replay these series or fetch their sources.

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
```

`args.gn` holds the stage C settings; the GN wrapper appends the two local
SDK/layout paths, without storing workstation paths in the repository. The env
adapter keeps caches and temporary files under the build area. The wrappers
record the producer's exit code under `cef-src/logs` and return it to the caller;
redirect stdout/stderr there when launching the multi-hour build. No wrapper
performs a source sync, stock patch application, input download or IPA build.
