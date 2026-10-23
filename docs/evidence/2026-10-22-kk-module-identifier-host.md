# KosmicKrisp shader module identifier: host results

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431). **Plan:**
[kk-proton-parity](../plans/2026-10-22-kk-proton-parity.md#b3-vk_ext_shader_module_identifier),
chunk B3. **Where:** the workstation's host mock of KosmicKrisp (`build/mesa-host-test`), from
the side copy `.work/worktrees/kkparity` (decision 0117). **Not run on the phone.**

**Rebase note (2026-10-23):** These are historical side-copy results, not validation of the
rebased driver. Original Mesa 0105 is now 0120, experimental bit 17, on main base
`26699f6`; fresh validation and the B1 phone gate are in
[phone evidence](2026-10-23-kk-memory-priority-phone.md).

## What changed: `patches/mesa` 0105 (2026-10-22)

- `MESA_KK_EXPERIMENTAL=module_identifier` (`KK_EXPERIMENTAL_MODULE_IDENTIFIER`, `1ull << 8`)
  advertises `VK_EXT_shader_module_identifier` and its `shaderModuleIdentifier` feature. Without
  the flag nothing changes.
- The rest is Mesa's common runtime, as Honeykrisp uses it:
  - the identifier is the SPIR-V's BLAKE3 (`vk_shader_module.c`);
  - the algorithm UUID is `MESA-BLAKE3`, which KosmicKrisp already reported with or without the
    flag;
  - `vk_pipeline.c` hashes an identifier where it would hash the module, so the precompiled and
    compiled shader keys are the same either way.
- A pipeline made from an identifier must carry `VK_PIPELINE_CREATE_FAIL_ON_PIPELINE_COMPILE_REQUIRED_BIT`.
  It is made only when its compiled shaders are found in the pipeline cache it is given, the
  device's own cache (none given) or Mesa's disk cache. Otherwise it returns
  `VK_PIPELINE_COMPILE_REQUIRED` and compiles nothing.
- No MSL or cache-key change. `pipelineCacheUUID` and the disk-cache ID hash the same inputs as
  before, and the flag only switches the extension and feature.

## What the layers do with it

- **vkd3d-proton** (`libs/vkd3d`, pin `567710d`):
  - With `shaderModuleIdentifier` its internal disk cache stores identifiers instead of full
    SPIR-V (`cache.c:3292-3295`).
  - The cache header then carries `shaderModuleIdentifierAlgorithmUUID` instead of
    `pipelineCacheUUID`, and a mismatch rejects the cache (`cache.c:2433-2442`).
  - A PSO from the cache is created from identifiers with `FAIL_ON_PIPELINE_COMPILE_REQUIRED`
    (`state.c:3590-3591`, `6998-7001`). On `VK_PIPELINE_COMPILE_REQUIRED` it compiles the
    DXIL to SPIR-V again and creates the pipeline from that:
    - compute: `state.c:3642-3660`;
    - graphics: `state.c:7065-7080` (`vkd3d_late_compile_shader_stages`).
  - With `VKD3D_CONFIG=pipeline_library_log` it logs `[IDENTIFIER] Successfully created …
    from identifier` or `… falling back`.
- **Consequence of the fixed `MESA-BLAKE3` UUID:** after a KosmicKrisp rebuild, the
  pipeline-cache UUID and the Mesa disk-cache ID change, so the driver's cache starts empty.
  vkd3d keeps its identifier cache, since the algorithm UUID is unchanged. Each of its PSOs then
  misses once with `VK_PIPELINE_COMPILE_REQUIRED` and falls back as above: correct, at the cost
  of one DXIL-to-SPIR-V compile per PSO. Settings › Storage's Clear and disk-cache eviction have
  the same effect.
- **DXVK** (`src/dxvk`, pin `d942d78`) uses identifiers only for its shader pipeline libraries:
  - only with `pipelineCreationCacheControl` and `shaderModuleIdentifier`
    (`dxvk_shader.cpp:775`), so on KosmicKrisp it also needs `gpl`;
  - it retries a library from its identifier and falls back to SPIR-V when that fails
    (`dxvk_shader.cpp:296-303`).

## Host test

`build/mesa-host-test/run.sh .work/run/mesa/mesa .work/run/mesa/host .work/run/mesa/hosttest`
exits 0 with 62 `ok` lines (59 before).

- **Without the flag** (every other run in `run.sh`):
  - `main` checks that neither the extension nor `shaderModuleIdentifier` is reported;
  - `check_module_identifier` checks that the algorithm UUID is `MESA-BLAKE3` and that the device
    has no `vkGetShaderModuleIdentifierEXT` or `vkGetShaderModuleCreateInfoIdentifierEXT`;
  - it makes no device, so the flag-off MSL is numbered as before.
- **With `MESA_KK_EXPERIMENTAL=module_identifier`** (`module-identifier.log`), main's device
  enables the extension and `check_module_identifier` runs last:
  - **Identifiers.** A module's identifier equals the one from its create info, a second module
    from the same SPIR-V gets the same one, and other SPIR-V gets another.
  - **Miss path.** `texel.comp`'s compute pipeline from its identifier returns
    `VK_PIPELINE_COMPILE_REQUIRED` with a null pipeline and no MSL in three cases: without a
    pipeline cache on a fresh device, with an empty cache, and for an identifier no module has.
  - **Hit path.** Once the pipeline was built from the module into a cache, the identifier makes
    it from that cache. A second device makes it from a cache created from the first cache's
    data, still with `VK_PIPELINE_COMPILE_REQUIRED` without a cache.
- **With `MESA_KK_EXPERIMENTAL=gpl,module_identifier`** (`module-identifier-gpl.log`), the same
  checks run, and then a GPL pre-rasterization library with `pass.vert` from its identifier:
  - it returns `VK_PIPELINE_COMPILE_REQUIRED` in an empty cache;
  - it is made once the module's library is in that cache;
  - it links fast with the other three parts and draws.

```
ok module_identifier: identifiers stable, VK_PIPELINE_COMPILE_REQUIRED without a cache, from an empty one and for an unknown identifier; from the cache the module was built into 0 MSL libraries, on a second device from its data 1, as the module's 1
MESA_KK_EXPERIMENTAL=module_identifier: 181 MSL libraries, each the one made without it, then 36 of the identifier checks
ok module_identifier gpl: a vertex library from an identifier: VK_PIPELINE_COMPILE_REQUIRED in an empty cache, made from the cache with 0 MSL libraries (the build 1), linked fast and drawn
MESA_KK_EXPERIMENTAL=gpl,module_identifier: 234 MSL libraries, each the one made without it, then 38 of the identifier checks
```

- **MSL.**
  - `run.sh` compares every flag-off `.metal` with the flag run: 181/181 (`msl`) and, for
    `gpl,module_identifier`, 234/234 (`msl-gpl`) are byte-identical. The identifier checks'
    own libraries come after them: the two devices' internal libraries, and texel.comp's,
    which the second device rebuilds from the cache byte-identical to the module's build.
  - Against the MSL saved from a run before 0105, all files are byte-identical: 181/181 `msl`,
    234/234 `msl-gpl`, 181/181 `msl-memory-priority` and 25/25 `msl-zink`, with the same file
    counts.

## Build

- `./pp build` in the side copy exits 0. It reran `vulkan` (the series changed), `stage`,
  `notices`, `app` and `verify`.
- The IPA is `.work/out/20261022-092656-c88649a7/Playport-26.5-c88649a7.ipa` (in the side copy),
  sha256 `c88649a7a0e9f4af4b56cbf48b8932f23ed0a506ffeaa45ebf01c854e4b1b845`.
- verify-ipa: 89 checks passed, 0 failed. `./pp test --quick` passes.

## Phone gate: not run

Queued for the main checkout, after the branch moves there:

```sh
./pp ui --play app-367520 --until first-frame+10 --shot
./pp ui --play app-367520 --until first-frame+10 --shot \
  --settings 'app-367520:{"arguments":"-force-d3d12","graphicsOptions":"MESA_KK_EXPERIMENTAL=module_identifier VKD3D_CONFIG=pipeline_library_log"}'
./pp ui --play app-367520 --until first-frame+10 --shot \
  --settings 'app-367520:{"arguments":"-force-d3d12","graphicsOptions":"MESA_KK_EXPERIMENTAL=module_identifier VKD3D_CONFIG=pipeline_library_log"}'
./pp ui --play app-367520 --until first-frame+10 --shot \
  --settings 'app-367520:{"graphicsOptions":"MESA_KK_EXPERIMENTAL=gpl,module_identifier"}'
```

- **Order.** The first run is the flag-off smoke check. The two `-force-d3d12` runs are
  identical: the second finds vkd3d's cache from the first, written with identifiers.
- **Pass:**
  - vkd3d-proton's log lists `VK_EXT_shader_module_identifier`;
  - the second d3d12 run logs `[IDENTIFIER] Successfully created … from identifier` lines;
  - any `… falling back` line is followed by a working pipeline;
  - first frame is not later than with the flag off;
  - no GPU errors;
  - the DXVK run with `gpl,module_identifier` reaches first frame +10.
