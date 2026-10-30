# Xbox add-ons in the runtime: mounts and associated products (patches/xgameruntime 0003)

**Date:** 2026-10-30. **Linear:** [PLA-502](https://linear.app/playportdev/issue/PLA-502).
**Kind:** host build and tests on the workstation, in a side copy (decision
[0117](../decisions/0117-side-copies-that-build.md)). Headless: no display, and no crash dialog
in the test prefixes. No phone run.

## Result

**Passed for the paths the patch adds.** Every test that covers them passes. The tests that
fail also fail the same way without the patch.

Before the patch, nexus-xgameruntime `ab2fac35` answered `E_NOTIMPL` for:
- `XPackageMount*` and `XPackageGetMountPath*`;
- `XStoreQueryAssociatedProducts`, `...ForStoreId` and `XStoreQueryProducts`.

With `patches/xgameruntime` 0003 they answer as follows:

| API | Answer |
| --- | --- |
| `XPackageMountWithUiAsync`/`Result`, `XPackageMountLegacy` | The current game's own folder, or an installed content package of the game or of a related game, found as `XPackageEnumeratePackages(Content)` finds it. A content package is mounted only with the account's signed Durable licence for it. That is the same bridge request `XStoreAcquireLicenseForPackage` sends. |
| `XPackageGetMountPathSize`/`GetMountPath`/`CloseMountHandle` | The package folder's path, in UTF-8. |
| `XStoreQueryAssociatedProducts` (`...ForStoreId` for the current game) | The game's related products, owned or not. These are its `RelatedProducts` plus `NEXUS_RELATED_PRODUCT_IDS`. |
| `XStoreQueryProducts` | The products asked for, owned or not. Only the game and its related products are sent for a licence. Any other product is described from the public catalogue as not owned. |

## What ran

| Part | What |
| --- | --- |
| Source | The pin `ab2fac35`, then `git am` of `patches/xgameruntime` 0001–0003. A clean worktree of the pin with the series applied gives the same tree as the build's. |
| Build | `cmake` with `ENABLE_TESTS=ON` and `ARCH=x86_64`, using llvm-mingw 20260922. The build was against the Wine tree and `widl` of the PLA-495 desktop proof. `xgameruntime.dll` was 2,770,432 B, sha256 `b8ed1922d8fbe7e9…`. |
| arm64ec | `-fsyntax-only` on `XStore.cpp` and `XPackage.cpp` with `arm64ec-w64-mingw32-clang++`: clean. |
| Baseline | The same build of the pin with 0001–0002 only, for comparison. |
| Wines | The host's Wine 11.20. Also the PLA-495 desktop build of Playport's Wine with `patches/wine-gdk` (x86_64), which has the WinRT JSON classes the receipt code needs. |

## Tests touched by the patch

| Test | Host Wine 11.20 | Playport's Wine (wine-gdk) |
| --- | --- | --- |
| `nexus_package-content` (mounts: licensed, unlicensed, related game's add-on, unrelated, unknown, malformed, handle lifetime, async; the DLL's mount without a licence) | **363/0**. The baseline gives 332/0. | Crashes. The baseline crashes the same way. |
| `nexus_package-legacy` (the own-package mount, its path, size, close; unknown and malformed identifiers) | **153/0** | Exit 0 |
| `nexus_store-entitlements` (catalog request, public description, catalog parsing and its ownership rules, the products and associated queries' arguments and bridge failures, the mount's licence) | Crashes at `test_metadata`, a JSON-dependent case. The baseline crashes at the same place. | **1032/0** |

## Other runtime tests, Playport's Wine, patched build

These pass:
- `test_xgameruntime` 81, `test_nexus_async_identity` 3, `test_nexus_timer` 2 and
  `test_nexus_save` 6;
- `store-context` 61, `user-device-association` 6309, `user-audio` 342 and
  `game-relaunch` 64;
- `async-provider-contract` 116, `system_device_id` 332, `async-schedule` 16 and
  `async-completion-lifetime` 2805;
- `taskqueue-teardown` 20, `-close` 1137 and `-contract` 1374;
- `package-monitors`, `-progress-bytes` and `-selection`;
- `gamesave-sync` 315, `-transfer` 263, `-files` 25 and `-file-paths` 55;
- `auth-metadata` 305.

These fail, and fail identically on the baseline build under the same Wine:
- `package-identity`: one child exit code;
- `package-chunks`: one child;
- `game-relaunch-search`: a stack overflow on the host Wine;
- `test_nexus_configuration`: hangs in `NexusXml.ProhibitsDtdAndExternalEntities` on both
  Wines.

`scripts/test-component.mjs` therefore stops at `configuration-unit` on this workstation,
with or without the patch. Its required counts for package-content and package-legacy rise
to 363 and 153.

## Not shown here

- A real game reading a mounted add-on. That is the PLA-502 phone gate.
- A successful licensed mount through a real bridge. On the host, the licence decision is a
  fixture in `package-content`. The DLL path is shown to refuse without one.
