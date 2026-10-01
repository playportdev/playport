# Two builds of the same sources give the same artifacts

Status: build only; not run on the phone (the runtime code is unchanged).

**Result:** a build of every tree from `unix` on, run twice from the same
pins and series, now writes identical `app/artifacts.tsv` rows and
`build/generated/wine-pe-*.tsv` files. Before, every build changed the rows of
the unix archives and of every DXMT, DXVK, vkd3d-proton and FEX DLL, so a row
diff did not say whether anything had changed.

What differed, and the fix:

- **`libwin32u_unix.a` and `libntdll_unix.a`.** Madeira's `build.sh` ran
  `ar rcs` into the archive the previous build left. `libwin32u_unix.a` then
  took libfreetype.a's members again on every build: it was 9.3 MB in the
  committed record, 7.5 MB after one fresh tree, and is 4.76 MB made afresh.
  `libntdll_unix.a` kept members no longer in its list (2796472 bytes, now
  2725168). `patches/madeira-unix` 0033 removes each archive first.
- **DXMT's and DXVK/vkd3d-proton's DLLs** (same size, other hash). A byte
  compare of two `winemetal.dll` builds differed in 4 bytes: the PE header's
  link time and its copy in the debug directory, which lld writes by
  default. `build/stages/dxmt-patched.sh` and `build/stages/vulkan-pe.sh` link
  with `-Wl,--no-insert-timestamp`.
- **FEX's `xtajit64.dll`.** Its `[build-id]` log line (`Module.cpp`) has
  `__DATE__ __TIME__`, and lld stamps the link time. `build/stages/fex.sh`
  sets `SOURCE_DATE_EPOCH` to the FEX pin's commit time (the line now reads
  `compiled Sep 21 2026 18:44:20` with the revision) and links without the
  timestamp.

Wine's own PE DLLs (`wine-pe-*.tsv`) and the KosmicKrisp framework already
built the same each time.

Check: `./pp build` (C), then `rm -rf .work/run/fex/build-arm64ec` and
`./pp build --from unix` (D); `diff` of C's and D's `app/artifacts.tsv` and
`wine-pe-*.tsv`: no difference. Both IPAs passed `verify-ipa` (63 checks).
