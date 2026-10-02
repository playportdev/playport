# Best-effort Direct3D evidence: interposers, dependencies and dynamic loading

## Result

The installed Witcher build **25646871** now shows **Default: Vulkan** in Game
options without a backend override or reading its launcher configuration.
The missed import is `sl.interposer.dll!D3D12CreateDevice`, not `d3d12.dll`.
The correction recognises API-function imports from any DLL, rather than
special-casing the game. [Decision 0046](../decisions/0046-static-direct3d-evidence.md)
covers the detector's scope and limits.

This establishes backend inference and its UI, **not Witcher gameplay**. Its
previous AVX failure remains a separate blocker
([record](2026-10-02-witcher3-executable.md)); no new Witcher play was attempted.

Final dev IPA: `.work/out/20261002-155157-e0960e4e/Playport-26.5-e0960e4e.ipa`

SHA256: `e0960e4e8c10365f619848ff510a6d2904e9891685e8e8504d823923d7d449b1`

## Inspection

Only installed files, code and existing device evidence were used; no online
sources or launcher-specific metadata enter detection.

`llvm-readobj --coff-imports` on the EXE pulled from the phone confirms
`sl.interposer.dll` exports `D3D12CreateDevice`, `D3D12SerializeRootSignature`
and `D3D12SerializeVersionedRootSignature` to it. A scratch host harness using
the product detector on that EXE records DX12 function-import evidence without
any adjacent renderer DLL or launcher file (about 0.26 s in an unoptimised host
build; not an iPhone benchmark). The EXE and inspection output stay under
`.work/witcher-directory-check/`, not in the repository's committed files.

Adoption also follows reachable local DLLs. The phone's catalogue recorded:

- Witcher: 16 modules, no budget reached. DX12 function imports in the selected
  EXE, DX12 library imports in reachable SDK DLLs, and dynamic DX11/DX12
  references in shared helpers. The latter **do not mean this build offers a
  DX11 executable**. The picker says "Found references to Direct3D 11,
  Direct3D 12" and warns that static evidence does not establish the active API.
- Hollow Knight: two modules, no budget reached. UnityPlayer has DX11 and DX12
  imports; explicit launch arguments still select the renderer/backend.
- Portal 2: no API evidence in the selected EXE's reachable imports; **Unknown**,
  not a claim of DX11. A dynamically loaded renderer remains a detection limit.

## Checks

- `./pp test`: all passed, including **142 PlayportKit tests**. New coverage:
  arbitrary-name interposers, PE32/PE32+ normal/delay function imports, VA-based
  PE32 delay imports, nested/case-insensitive/cyclic dependencies, unused
  sibling DLLs and EXEs, ASCII/UTF-16 dynamic references with mixed-case DLL
  names, resource/substring negatives, ordinal/malformed/truncated PEs, path
  escapes/symlinks, depth/module/file-size budgets, unknown and dual APIs,
  catalogue round-trip/backward decoding and refresh after replacement.
- `./pp check` and `./pp check --variant release`: both compile. Final install:
  **71 IPA checks**, upgraded in place; no committed artifact records changed.
- `.work/direct3d-final-options`: open Witcher Game options, move to Direct3D
  and open its picker. Four actions passed. The final screenshot shows Default
  selected, Vulkan as its inherited value, DXMT/Vulkan alternatives and the
  evidence disclaimer. No per-game override was saved.
- `.work/direct3d-final-hk-retry`: the final IPA, a temporary `-force-d3d11`
  argument through Game options, DXMT selected automatically despite Unity's
  DX12 evidence. First frame at **9.46 s**, ran another 10 s; result passed,
  self-check passed, no pool exhaustion. The earlier candidate also passed
  DX11/DXMT (8.99 s) and the phone's existing `-force-d3d12` setting on Vulkan
  (8.61 s). Temporary test settings are restored at the next external launch.

### Interrupted final launch

The first final-IPA Hollow Knight run (`.work/direct3d-final-hk-dx11`) stalled
after asking for JIT. The host call was interrupted after the user reported
it; it has no passing result. The subsequent phone log
(`.work/direct3d-interrupted/s1-host.log`) says the pool was blessed and the
debugger detached, but has no `acquire` return, runtime start or first frame
before the app's next launch. This record does not establish the cause or
claim that a detector change fixed it. With the user's permission, one bounded
retry (`--wait 60`, final IPA unchanged) passed as above.

Screenshots and raw logs stay under `.work/`; `pp names` and `pp secrets` clean.
