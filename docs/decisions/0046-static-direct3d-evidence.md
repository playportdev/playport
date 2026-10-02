# 0046: Best-effort Direct3D detection follows API imports, not just DLL names

**Status:** accepted, 2026-10-02. Extends [0044](0044-vulkan-default-for-dx12.md)'s
executable-only `d3d12.dll` test; its backend and override precedence stay unchanged.

## Decision

- Adoption detects Direct3D 8/9/10/11/12 evidence in the **selected executable**
  and its reachable local DLL imports, including normal and delay-load tables.
  Recognise renderer library names and imported API function names independently:
  an interposer can export `D3D12CreateDevice` without being named `d3d12.dll`.
- DLL resolution is case-insensitive, beside the importing module, beside the
  executable, then at the title root. No whole-install DLL scan, other EXE scan,
  Wine system DLL scan, game-ID rules or launcher-specific metadata. Do not follow
  paths or symlinks outside the title. Cycles are visited once.
- Dynamic-loading evidence requires imported `LoadLibrary*` and `GetProcAddress`,
  plus exact renderer-DLL and creation-function string references in initialized,
  non-executable PE data (not resources). ASCII and UTF-16 references are supported.
  This is explicitly a heuristic; it cannot establish which code path runs.
- Bound the walk to 32 modules, depth 4, 128 MiB per file and 256 MiB overall.
  Persist relative module names, evidence kind and API names in the catalogue,
  with whether a budget was reached. Refresh on adoption, including after updates.
  Keep the old optional DX12 boolean for older catalogue readers.
- Unknown means **unknown**, not DX11. Multiple APIs mean references to multiple
  renderers, not a known active version. Game options describe this distinction;
  the launch log records the evidence. DX12 evidence defaults to Vulkan; explicit
  API arguments and per-game/global backend selections retain 0044's precedence.

## Why and limits

The installed Witcher EXE imports `sl.interposer.dll!D3D12CreateDevice`, not
`d3d12.dll`. Library-name-only detection missed it. Inspecting imported API names
fixes the generic class of interposed exports, without special-casing the game,
its directory name or its launcher configuration.

This is routing, not compatibility certification or feature-level detection.
Packed/encrypted code, indirect loaders without these references, dynamically
loaded engine/plugin DLLs not reachable through imports, DLL search paths not
covered by the bounded resolver, and renderer choices in game configuration
can still be missed. Delay imports or unused code paths can over-report available
APIs. There is no universally reliable static test of the API that arbitrary
Windows code will choose; the player retains the override. Runtime confirmation
would require a separate design (the backend must be chosen before launch).

Checks and device evidence: [record](../evidence/2026-10-02-direct3d-evidence.md).
