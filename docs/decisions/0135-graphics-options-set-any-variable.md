# 0135: A dev build's Graphics options set any environment variable

**Status:** accepted, 2026-10-20, by the owner (relayed by the supervisor during PLA-364).
Supersedes [0060](0060-graphics-options.md)'s allowlist; the rest of 0060 holds. Dev builds
only; [0012](0012-the-ui-is-the-only-entry-point.md) holds, since the row is in the app's UI.

## Decision

- **Any variable.** An item of a game's Graphics options row (`LaunchSettings.graphicsOptions`)
  may be `NAME=value` for any NAME matching `[A-Za-z_][A-Za-z0-9_]*`, besides the DXVK
  `section.option=value` items, which still go into `DXVK_CONFIG`
  (`LaunchSettings.graphicsEnvironment`).
- **Joining.** A repeated `DXVK_CONFIG` joins with `;`, a repeated `VKD3D_CONFIG`,
  `MESA_KK_DEBUG`, `MESA_KK_EXPERIMENTAL` or `MESA_KK_DISABLE_WORKAROUNDS` with `,`
  (`LaunchSettings.graphicsVariables`), as 0060. For any other variable the last item wins.
- **Unchanged from 0060:** a line with an item that is neither form is not used at all, and the
  row says so; the launch sets the variables over the backend's environment and logs
  `graphics options: …`; the release app ignores the row (`LibraryModel`) and shows none.

## Why

Experiments kept needing a variable outside the allowlist, and each one meant an app change
before a phone A/B could start. The dev build is the owner's and the agents' tool; what a
player gets still goes through `GraphicsBackend.runtimeEnvironment` or the compatibility table.

## Costs

A dev build's row can now set variables that change Wine, FEX or the loader (`DYLD_*`
included), and a typo is set rather than refused. The variables still reach the whole app
process, as under 0060.
