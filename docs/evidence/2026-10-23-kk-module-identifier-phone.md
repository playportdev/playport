# KosmicKrisp shader module identifier: phone gate

**Linear:** [PLA-431](https://linear.app/playportdev/issue/PLA-431). **Plan:**
[Proton parity](../plans/finished.md#kosmickrisp-proton-parity), B3 (Mesa **0120**, experimental
bit **17**). **Result:** functional launch smoke passed on both Vulkan routes; vkd3d's
second launch demonstrably loaded disk-cached PSOs and created **25 graphics pipelines
from identifiers**. No performance, gameplay, cache-size improvement or conformance claim.
The uncached-identifier fallback was not exercised on the phone.

## Build and scope

Reused the already installed main-built dev IPA, with `--expect-ipa` on every UI run:
`$PLAYPORT_BUILD/out/20261023-071927-5e3fc6a8/Playport-26.5-5e3fc6a8.ipa`, SHA256
`5e3fc6a89019ef10f054d3ce47f4191e0354ff5df66c73d65814d7fd0241da7d`.
No build, install, cache deletion, app-file modification or runtime/instrumentation change.
Branch `dev/kk-proton-parity`, starting HEAD `d198ee6`; main stayed `26699f6`.

**Local-source qualification:** this IPA includes the owner's uncommitted
`app/Sources/S1Probe/UI/SettingsView.swift` edit, SHA256
`14f47ed236724bf1250e2d7447f4fa9f16f4c93eb305c5fe5f8ee4d863b3a3fe`.
It is **not an exact committed-source IPA**. File and binary diff were compared with the
inherited private snapshots before and after this chunk; neither was changed or staged.
Rebased host cache hit/miss/second-device/GPL tests and 185/239 MSL comparisons were already
passed in [B1 integration evidence](2026-10-23-kk-memory-priority-phone.md); those mock tests
alone do not prove iOS disk persistence. The phone logs below provide separate evidence.

## Commands and runs

Held one `pp phone lock` for the three planned launches. Used `PLAYPORT_BUILD=$PWD/.work`
and `TMPDIR=$PLAYPORT_BUILD/agent-notes/kk-parity/tmp`. Every play used:

```sh
./pp ui --action hud:off \
  --settings 'app-367520:{"graphics":"vulkan","screen":"720","frameLimit":60,"arguments":"-force-d3d12","graphicsOptions":"MESA_KK_EXPERIMENTAL=module_identifier VKD3D_CONFIG=pipeline_library_log"}' \
  --play app-367520 --until first-frame+10 --wait 120 --pad --shot \
  --expect-ipa "$PLAYPORT_BUILD/out/20261023-071927-5e3fc6a8/Playport-26.5-5e3fc6a8.ipa"
```

The D3D12 command ran twice unchanged. DXVK used `arguments=-force-d3d11` and
`graphicsOptions=MESA_KK_EXPERIMENTAL=gpl,module_identifier`, otherwise identical.
Settings were session-scoped, never `--keep-settings`; no unsafe workaround flags.
Existing same-IPA, flag-off 720p/60/Vulkan baselines from B1 were reused, not rerun:
DXVK `20261023T072230` (+10.86 s first frame), D3D12 `20261023T072320` (+12.93 s).

All directories in this table are under `$PLAYPORT_BUILD/ui-runs/`. All five final
`event:result` records have `ok:true`, `exit:0`, `until_reached:true`, and the full IPA hash.

| Run | Directory | Until | First frame | Identifier graphics results |
| --- | --- | --- | --- | --- |
| D3D12 first | `20261023T073649` | first-frame+10 | +10.89 s | 25 `No graphics identifier` |
| D3D12 warm | `20261023T073744` | first-frame+10 | +10.91 s | 25 successful identifier pipelines |
| DXVK GPL + identifier | `20261023T073832` | first-frame+10 | +11.38 s | not a vkd3d run |
| D3D12 visual check | `20261023T074036` | first-frame+20 | +10.92 s | 25 successful identifier pipelines |
| DXVK visual check | `20261023T074141` | first-frame+20 | +11.41 s | not a vkd3d run |

First-frame times are descriptive single launches only. The warm D3D12 run was **0.02 s
later than the first flag-on run**, not evidence of a speedup. Both were earlier than the
single B1 D3D12 baseline; GPL DXVK was later than B1's DXVK baseline. This does not establish
performance or a literal universal "first frame no later" guarantee.

## Cache proof and logging limits

Read current source before launching: `$PLAYPORT_BUILD/run/vulkan-pe/vkd3d-proton/`:
`libs/vkd3d/state.c:3629–3639,7052–7062` logs identifier success/miss at **INFO**, controlled
by `PIPELINE_LIBRARY_LOG`. `include/private/vkd3d_debug.h:29–32,115` compiles out TRACE,
**not INFO**. `build-vkd3d/compile_commands.json` (beside that source tree) confirms
`VKD3D_NO_TRACE_MESSAGES`; no redundant trace run or rebuild was attempted.

Raw evidence: each directory's `pull/s1-host.log`.

- First D3D12: line 15005 rejects the inherited on-disk cache due to driver version mismatch;
  all 25 PSOs report `[IDENTIFIER] No graphics identifier`. They compile and render normally.
  This is an ordinary uncached/SPIR-V route, **not** an identifier lookup miss or proof of
  `VK_PIPELINE_COMPILE_REQUIRED` fallback.
- Second D3D12: lines 14986–15279 merge caches, discard the out-of-date read cache, promote
  the write cache, then `Loading stream pipeline library (7448 bytes)` with **25 D3D12 PSOs,
  0 unique SPIR-V, 0 unique VkPipelineCache**. Exactly 25 INFO messages say
  `[IDENTIFIER] Successfully created graphics pipeline from identifier.`
- Visual D3D12 check loads the same 7448-byte disk library and repeats 25 successes, after an
  intervening DXVK launch. This is real cross-process phone persistence/hit evidence, not a
  timing inference or a host mock result.
- No identifier `falling back` messages in any run; phone identifier misses/fallback remain
  **unobserved**, without clearing caches to force them. The existing host tests cover them.
- DXVK 3.1.1 reports `VK_EXT_shader_module_identifier`, `shaderModuleIdentifier : 1` and
  `Graphics pipeline libraries supported` with the combined flags. D3D12's DXGI client also
  lists the identifier feature; vkd3d's own TRACE extension enumeration remains unavailable.
  Its INFO pipeline successes provide stronger direct usage evidence. No DXVK-specific
  identifier-hit count is claimed.

The D3D12 logs identify vkd3d-proton build `567710d877bb3d4` and its 1564 × 720 swapchain.
All runs report the Vulkan/Khronos route. No new GPU fault, device-loss, Vulkan-error or
shader/pipeline compilation-error signatures were found. Existing DXGI EDID errors and
vkd3d alignment/shared-fence/present-wait/line fixmes also occur in the B1 flag-off logs;
these logs are not claimed to be globally error-free.

## Screenshots, bounded visual follow-up, restoration

First D3D12 `screen-stop.png` shows the expected title/main menu without obvious corruption.
The original warm D3D12 and GPL DXVK **stop screenshots are pure black**, retained unchanged.
Their screenshot events are 1.84/1.89 s after the harness's stop marker. Source
`tools/ui.py:838–846` takes the stop screenshot **before** ending the app; there was no
recorded rest/background event explaining these captures. Do not attribute them to the
unattended rest hook or claim those original images show the menu. Their cause is unproven.

Supervisor approved at most one bounded visual follow-up per route, with identical settings,
`--until first-frame+20 --screenshot-after 20 --screenshot-after 30 --shot`. These hold another
single phone-lock session. Both `screen-0020s.png` images show the game's autosave notice
(DXVK's dimmer), and both `screen-0030s.png` images show the same expected title/main menu,
without obvious corruption. The latter screenshot events precede stop by **7.51/7.56 s**,
so they establish visible rendering while the game is running. No gameplay input was sent.
Screenshots remain private in the run directories; no game artwork is committed.

Next-session UI inspection `20261023T074303` shows restored defaults: **720p, 60 fps, Vulkan,
launch arguments None**, inherited controller overrides retained. `20261023T074507` opens
Developer and navigates down (no value changes); its second action screenshot explicitly
shows **Graphics options None** and Runtime keys None. HUD/settings were session-restored.
Phone before/after: **80%, external power, not charging, 6.2 GB free**; built-in JIT succeeded
in 2.95–3.11 s. Existing unattended setting (until 2026-10-23T17:44:05+02:00) was unchanged.
Last explicitly inspected foreground page is Game options with Graphics options selected,
**not a confirmed black rest screen**.

Private scripts/logs: `$PLAYPORT_BUILD/agent-notes/kk-parity/b3-phone-session.sh`,
`b3-visual-session.sh`, their `.log` outputs, `b3-identifier-*.jsonl`,
`b3-{settings,options}-restored.jsonl`, `b3-phone-status-{before,after}.log`.
`pp test --quick`, `pp names`, `pp secrets` and owned-doc whitespace/staged review passed.

## Next

**A0 CPU profile** is next, separately assigned; it was not run here. Descriptor buffers
(A2–A4) remain gated on A0. Both `module_identifier` and GPL stay experimental/default off.
Hollow Knight (Steam 367520) is the only game observed: launch/menu smoke works on both
routes, not new gameplay evidence. Supervisor updates PLA-42/Compatibility without replacing
historical best-known gameplay with this menu-only result. No merge or push.
