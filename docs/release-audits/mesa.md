# Mesa vendored Vulkan/SPIR-V header notice collection

## Completed scope

`build/notices-mesa.py`, called by `build/notices-assemble.sh` **after** the
existing exact pin-plus-series tree gate, now preserves header attribution from:

- every `.h` recursively in Mesa's `include/vulkan/` and `include/vk_video/`;
- every top-level `.h` in `src/compiler/spirv/`, including five mandatory vendored
  headers: `spirv.h`, `GLSL.std.450.h`, `GLSL.ext.AMD.h`, `OpenCL.std.h` and
  `NonSemanticShaderDebugInfo100.h`.

The second selection intentionally also includes Mesa-local SPIR-V headers.
It does not recursively select test headers or claim complete Mesa attribution.
Mandatory Vulkan inputs include core/platform/loader/layer/Android headers and
the video common header; deleting them from a new committed tree fails closed.
Other header removals are also caught by the assembly's exact tree gate.

### Full-header fallback, not a guessed excerpt

Outputs are `mesa-header-superset-<flattened-source-path>.txt`. They contain
**full original header bytes, including code**, not just a licence identifier or
generic text. There is no exhaustive, reviewed extractor that proves all applicable
notice blocks for these layouts. For example, the Android copyright/Apache notice
in `vk_android_native_buffer.h` appears after Mesa commentary and C definitions;
`GLSL.ext.AMD.h` combines copyright, permission, normative warning and warranty
in one block. Trimming an arbitrary first-line range or only SPDX comments could
lose these terms. Full headers avoid that loss, retain CRLF/non-UTF-8 bytes, and
are explicitly a notice superset, not an applicability determination.

This preserves Khronos attribution and SPIR-V normative-version warnings,
Valve/LunarG loader/layer credits, Android attribution/permission, and the
Mesa-local Intel/Valve header credits. Existing Mesa licence texts remain separate;
they do not replace these attributions. The collector changes no source bytes,
licences, pins or submodule checkout.

### Origin and failure checks

`mesa-provenance.json` (schema 1) records the exact Git tree, selection rule,
mandatory source paths, and each output's component-relative source path, Git
blob ID, source/payload SHA-256, size and inclusive LF-based line range `1..N`.
Every range covers the entire file; archive member selectors are not applicable
because these inputs are directly committed headers, not archive extracts.
No workstation paths are recorded. Standalone collection requires committed
bytes and cleanliness, but **does not replace the assembly's pin/series gate**.

The collector rejects tracked/staged changes anywhere in the Mesa tree,
non-ignored untracked inputs, ignored header additions in the selected scope,
missing/empty/non-regular headers, nested/undeclared Git roots, source/output
symlinks (including parents), control-character selected paths, flattened-name
collisions, existing outputs and input/output overlap. It discovers both Git and
filesystem candidates and requires identical selected sets. Ignored non-header
build bookkeeping is not claimed as verified source.

Failed writes, including manifest writes, remove only newly created outputs.
Assembly still removes its entire temporary destination on failure. Before
publication, `notices-provenance.py inventory` recomputes source selection/origins
and checks every payload byte, missing/extra outputs, manifest omissions and the
Mesa tree ID against `tree-provenance.json`. A tree manifest naming Mesa requires
Mesa collection provenance even if all header outputs were omitted. Revalidation
requires the same `MESA` source input; collector metadata alone is not trusted.

## Source-level applicability review (not build-member proof)

Reviewed the exact reconstructed Mesa tree
`0b56cf47a13d78e355606b9b8809453931545167`, from pin
`82d4f86a0a1e9f76b2de4fa77c6c8e6acaf06aa9` plus this branch's 13 Mesa patches.
Source inclusion/dependency evidence is:

| Header group | Source evidence | What remains unproved |
| --- | --- | --- |
| Vulkan core/platform and Metal | KosmicKrisp source directly includes `vulkan_core.h`, `vulkan.h`, `vulkan_metal.h`; Metal WSI includes core/Metal; core includes `vk_platform.h` | Exact compiled preprocessor inputs and surviving linked definitions |
| Loader ICD | `src/vulkan/wsi/wsi_common.h` includes `vulkan.h` and `vk_icd.h`; KosmicKrisp uses WSI | Exact build/header applicability, including individual Valve/LunarG credits |
| Video | `vulkan_core.h` includes H.264/H.265/AV1/VP9 standard headers, which include the common header | Header inclusion does not establish video functionality or codec linkage |
| SPIR-V / GLSL / OpenCL / AMD / nonsemantic | `vtn_private.h`, `vtn_glsl450.c`, `vtn_opencl.c`, `vtn_amd.c`, `spirv_to_nir.c` include their respective headers; SPIR-V Meson declares `libvtn`; KosmicKrisp Meson references `idep_vtn` | Exact host-versus-iOS build, generated code, linked members and credit applicability |
| Other platform Vulkan headers, Android buffer and layers | Present in the source superset, with their original notices | No claim that Android, Windows, X11, layers or other-platform code is shipped |

The iOS script selects KosmicKrisp, no Gallium/OpenGL, `platforms=macos`, disables
LLVM for iOS, and uses separate Linux shader tools. These intended options and
source include edges are **not** a compiler dependency trace, clean release
record or link map. No member/header applicability is marked complete.

Additional generated-input credits (`src/vulkan/registry/vk.xml`, SPIR-V grammar
JSON/XML), other vendored headers/dependencies and all remaining Mesa source-file
attribution are outside this collector's scope and need review/collection as
applicable. No generic licence text is asserted to discharge these gaps.

## Checks and local evidence

- **19 targeted real-Git regressions** passed: full bytes/ranges/origins, recursive
  discovery, local-header superset, dirty/staged/untracked/ignored/missing/empty
  inputs, symlinks, nested repositories, path injection, collisions/overlap,
  rollback, CLI failure, exact-tree refusal and inventory/source-map revalidation.
- Plain `./pp test --quick` ran 260 tests but encountered **four unrelated
  `AF_UNIX path too long` errors** in mocked netmuxd tests: this assigned worktree's
  deeply nested absolute fixture paths exceed Linux's socket pathname limit.
  No test source was changed. A diagnostic rerun with
  `PYTHONPATH="$PWD/.work/short-socket-fixtures" ./pp test --quick` passed all
  **260 Python tests**, name/secret/pin/patch gates and available host C tests.
  The private `sitecustomize.py` only passes a short relative name to `bind()`
  for the identical socket file under this worktree's `.work`; it neither moves
  fixtures nor skips assertions. Plain quick tests should be rerun in the shorter
  coordinator worktree after integration. Logs: `.work/mesa-quick-tests.log` and
  `.work/mesa-quick-short-socket-tests.log`.
- Read-only exact-tree smoke initially **refused the shared Mesa run** as different
  from this branch's series. Reconstructed isolated `.work/mesa-review/mesa` using
  local Git objects and the declared patches, with no fetch or build. The exact
  tree gate then accepted it; collection and inventory revalidation preserved
  **43 headers** (23 Vulkan, 12 video, 8 SPIR-V), **1,968,209 payload bytes**.
  All output checksums passed. Output is `.work/mesa-notice-smoke`, with
  `.work/notices-mesa-exact-smoke.log`; shared sources/cache trees were unchanged.
- Shell/Python syntax, collected-text secret/home-path pattern scan and
  `git diff --check` passed. Full smoke inventory remains `incomplete-inventory`.
  No app/runtime build, install, device command, publication or upload occurred;
  this was not checked on the phone.

## Integration and open gates

Cherry-pick the task commit; it owns the Mesa collector/tests, assembly and
necessary provenance revalidation only. No extra downloads, pins or input
variables are required: assembly already exports `MESA`. Keep the full-header
superset labels and origin manifest with the payloads. The coordinator should
reconcile its shared notice/licensing/plan documents; this task deliberately did
not edit them.

This fixes missing **collection** of the scoped vendored header credits only.
Actual compiled-header/linked-member applicability, complete notice coverage,
exact IPA linkage, app notice resources/UI, Corresponding Source/relinking and
source/binary publication gates remain open. The smoke is source-inventory
engineering evidence, not release provenance or legal clearance.
