# Plan: runtime DLL coverage before the first play

**Date:** 2026-10-07. **Kind:** execution plan; implementation not started.
**Source:** `.work/agent-notes/dll-survey/report.md`, research baseline `7c9de03`.
Plan prepared against `13c3522`; all four build manifests have changed since the
survey, so its counts and costs must be remeasured before changing staging.
No build, installation or phone run was performed while writing this plan.

## Goal and settled direction

Stop discovering statically visible missing Wine DLLs one failed play at a time.
Inspect exact Windows builds across the owned libraries, bundle the complete built
ARM64EC DLL/driver set, and show specific compatibility warnings after installation
or adoption. This covers missing files, not every Windows API's behaviour.

**Owner choices, 2026-10-07:**

1. **All built ARM64EC DLLs**, not the survey's curated 16-name union. Stage the
   production DLL/driver set from the generated build manifest, excluding tests and
   programs, while preserving the existing FEX and graphics replacements. Do not
   introduce per-title runtime packages or downloads.
2. **UI warnings are in this plan**, in both app variants, not a follow-up.
3. **Complete owned-library PE coverage gates staging.** A missing-input ledger is
   useful progress, but cannot substitute for the complete census. No early
   staging batch based only on available samples. If authorised bytes cannot be
   obtained, stop at that gate and ask the owner; do not quietly relax it.

Write the lasting staging policy in a new decision record during implementation;
this plan records the owner's choice but does not allocate a decision number.
The existing complete i386 set stays complete. Aarch64 remains the loader/native
companion set, with any additional closure justified separately; it is not another
copy of the guest's ARM64EC set.

### Scope and boundaries

- Host analysis reads files and saved manifests, never launches, installs, adopts
  or imports a game. `pp compat imports` and its inventory aggregation mode are
  proposed commands, not commands available today. Coordinate the `compat` command
  namespace with [the reported-games plan](2026-10-07-compat-testing-without-owning.md).
- Research collection may read authorised binary chunks using an already-valid
  session without changing it. No new terminal store client, login, credential
  export or token-refresh path. If obtaining bytes needs a new product capability,
  add it to the app's UI first, or use an existing authorised local installation.
- No component pin changes, in-place upstream edits, downloaded system DLLs,
  automatic runtime repair, renderer change, compatibility allowlist by game name,
  or fixes to unrelated game failures. Upstream fixes, if separately approved, use
  format-patch and the trailers required by [ARCHITECTURE](../ARCHITECTURE.md#patch-series).
- Broad staging does not add missing unix libraries/services. Missing exports,
  explicit stubs and unsupported behaviours stay visible and get separate issues.
  Anti-cheat, third-party launchers, graphics features and DRM are not solved here.
- No game binaries, copyrighted screenshots, credentials, signed URLs, account
  inventories or raw logs in git. Scratch, caches and downloads stay under `.work/`.
  Track scrubbed methods, aggregate results and evidence; tests use synthetic PEs.

## Research baseline (not current-build certification)

The survey read 81 Steam, 34 Epic and 46 GOG entries: **161 storefront entries**, not
161 distinct titles. It inspected 1,337 PE-named files across 44 displayed title
families, including 355 managed assembly copies excluded from native import roots.
Two PE-named placeholders did not parse. It listed 15 phone game folders, not their
complete binaries. Epic contributed 965 hash-verified files from 33 manifests; the
34th is a batch stub. Most Steam and GOG payloads remain missing. Another store's
copy of a title does not certify the selected build in this store.

| Architecture | Built DLL/driver names | Matching staged names | Built but unstaged |
| --- | ---: | ---: | ---: |
| i386 | 624 | 624 | 0 |
| ARM64EC | 597 | 144 | 453 |
| aarch64 | 597 | 111 | 486 |

Survey costs, from stripped files (MiB = 2^20 bytes):

| Alternative | Additional raw bytes | Raw MiB | Estimated deflate-6 MiB |
| --- | ---: | ---: | ---: |
| Sampled 16-name ARM64EC union, **not selected** | 13,697,024 | 13.062 | 1.356 |
| Remaining built ARM64EC set, **selected policy** | 375,521,280 | 358.125 | 36.627 |

These are not measured IPA or installed-size deltas. Full staging mostly costs disk
when unused; loaded native images consume the fixed JIT pool. Registration or loader
changes may activate paths that never loaded before, so memory regression is a gate,
not an assumption that unused files are free.

The sampled union was `advpack`, `cabinet`, `iertutil`, `shdocvw`, `glu32`,
`twinapi.appcore`, `sensapi`, `dbgeng`, `dxcore`, `evr`, `faultrep`, `msvcp90`,
`msvcp_win`, `msvcr90`, `tbs`, `wer` (all `.dll`). Its classification remains useful:

- `twinapi.appcore`: Among Us/Moonscars Xbox thunks and Valheim XCurl;
  `msvcp_win`: Valheim XCurl; `sensapi`: Vivox in Rogue Company/Roller Champions.
- `faultrep`: Rocket League; `evr`: Marvel Rivals' media plugin;
  `msvcp90/msvcr90`: Elite Dangerous' decoder.
- `dbgeng` is from a crash reporter, `tbs` from an uninstaller. They are not proven
  gameplay requirements. Many common candidates arise only through Wine delay loads.
- House of Golf 2's shipped D3D12Core delay-load path requests **91 exports absent
  from the survey's built dxcore**. Bundling dxcore cannot satisfy that path.
- Literal DLL strings are hints, not measured calls. Spec `stub` imports are
  different from a missing DLL/export and from implemented-but-unsupported APIs.
- The recent `gdiplus`, `mlang`, `cryptsp`, `sspicli` additions are already staged.
  In particular `cryptsp.SystemFunction032` is **not** an explicit spec stub; a
  missing delay-loaded provider can still produce an "unimplemented function" error.

The survey validated all 16 candidate hashes/sizes and cross-checked import-library
sets with LLVM for PartyWin32, JWE.exe, Moonscars UnityPlayer, Portal 2 engine.dll and
built advapi32. This is research validation, not product CI or runtime confirmation.
Its app-local basename index, API-set family mapping and string scans are bounded
approximations; do not copy them into production unchanged.

**Local evidence:** report SHA256
`8052bd4f80ec3922bace05cec74ad6c5a0e0493dc4a9ae554624019574e52135`.
Supporting files beside it: `validated-imports.json`, `built-staged.tsv`,
`coverage.json`, `epic-inventory.json`, `phone-inventory.json`, `validation.json`,
`stage-all-cost.json`. Preserve those locally and record fresh input fingerprints
when execution starts. The aggregate baseline above survives without that scratch.

### Later Linear inventory reconciled during planning

A read-only PLA issue query on 2026-10-07 resolves the report's missing PLA-42..57
mapping. These are identities, **not new plays or proof of binary coverage**:

| Issue | Title / scope |
| --- | --- |
| PLA-42 | Hollow Knight (Steam 367520) |
| PLA-43 | The Witcher 3 (Steam 292030; classic and current branches differ) |
| PLA-44 | Snakebird Complete (Epic) |
| PLA-45 | En Garde! (Steam 1654660) |
| PLA-46 | Death's Door (Epic) |
| PLA-47 | MultiVersus (Steam 1818750) |
| PLA-48 | Shogun Showdown (GOG 1104084973) |
| PLA-49 | Kingdom Come: Deliverance (Steam 379430) |
| PLA-50 | secur32 authentication packages; runtime issue, not another title |
| PLA-51 | Valheim (Steam 892970) |
| PLA-52 | Duck Paradox (GOG 1816031813) |
| PLA-53 | Soccer Online: Ball 3D (Steam 485610) |
| PLA-54 | Monster Train (GOG 1304291300) |
| PLA-55 | Galaxy SDK runtime issue (Moonscars/Monster Train), not another title |
| PLA-56 | Moonscars (GOG 2106173825) |
| PLA-57 | GOG install driver check, not another title |

Keep the earlier reported titles and the installed Echoes of Mystralia Demo in the
supplemental ledger. Unowned reported titles are not an owned-library coverage gate:
record unavailable exact binaries and use legal demos/probes under the other plan.
Runtime issues PLA-58..65 remain residuals, not evidence that DLL staging fixes them.
Do not overwrite a game's best-known result with a static scan's conclusion.

## Evidence model and coverage contract

The analyser has two distinct views:

- **Whole-folder census:** every shipped PE is a root, including helpers,
  uninstallers, launchers and alternate renderers. This deliberately over-approximates
  requirements and finds plugins that the main EXE's imports cannot reach.
- **Selected-launch view:** selected EXE, actual local search paths/overrides and
  reachable providers, with separately evidenced feature/plugin roots. Optional
  paths remain optional; it cannot prove every runtime choice.

Each result carries schema/parser version, store/app/build/branch/depot or manifest
identity, file-relative path, content hash and verification level, Machine/CHPE/CLR
classification, file role, scan status and budgets. Each edge retains raw DLL/API-set
spelling, mapped provider, architecture, import name **or ordinal**, normal/delay/
requested-forward/PInvoke/COM/literal/runtime evidence, and its root-to-provider path.
Deduplicate counts by exact store/build identity, not display name. Keep normal-only
and optional closures separately; never describe whole-folder counts as launch needs.

Classify findings separately: missing staged provider; not built; unresolved local
provider; unknown API contract/search context; architecture mismatch; missing export;
explicit spec stub; independently evidenced unsupported behaviour; incomplete scan.
No inferred implementation claim from the mere existence of an export or spec entry.

**Complete owned-library PE coverage means:** freeze a dated owned-inventory snapshot,
select the Windows branch/language/depot/build the app would install for every entry,
and enumerate every EXE/DLL and identified PE with another extension, including
helpers and alternative renderers. Obtain and verify each selected PE's bytes, scan
it and reconcile the result against the manifest. Managed assemblies are included
as metadata roots, not mislabelled as native i386 because they use PE32 headers.
Installed alternate branches (notably Witcher classic) are additional build rows,
not replacements for the selected current Windows build. Shared/dependency depots
and selected DLC/plugin payloads are part of that install configuration.

There must be **zero unknown/unfetched/unverified PE inputs** at the staging gate.
A row with no Windows payload or a manifest-verified non-PE placeholder is an explicit
reviewed classification, not a skipped game. Parse failures must be investigated;
packed files may have all bytes verified while import inference is still incomplete.
Report that distinction: complete byte/file coverage is achievable, complete dynamic
compatibility proof is not. Neither anti-cheat nor an unsupported launcher permits
omitting its binaries from the census. New acquisitions/updates after the frozen
snapshot trigger new scan rows; they do not change the denominator silently.

## Ordered chunks and acceptance gates

One writer/build/device session at a time. Commit each coherent chunk only after
its relevant checks pass, with documentation and caused build records. Host-only
analysis chunks need no phone play. App/runtime chunks need their phone gates; if
blocked, report that rather than claiming completion. Every implementation chunk
runs its focused tests and `./pp test` before commit.

### 0. Refresh the baseline and freeze the inventory

Reconcile the survey with current pins, patched source, generated Wine manifests
and `app/artifacts.tsv`; hash the actual providers. Freeze all owned Windows install
configurations, plus supplemental phone/report identities, into a private coverage
ledger under `.work/compat/`. Preserve the original survey, not rewritten history.
Publish a scrubbed aggregate research record with methods, fingerprints and gaps.

**Gate:** every inventory row has an exact build/configuration or an explicit input
blocker; no title-family samples counted as certified exact-store builds. The later
Linear identities above are reconciled, without treating runtime/tools issues as
new games. Check the census's total rather than hard-coding 161 forever.

### 1. Implement bounded PE and managed-metadata parsing

Add host analysis modules under `tools/compat/` and synthetic fixtures under
`tools/tests/`; wire the analysis-only command through `pp`. Reuse `pefile` where
suitable (already used by `app/tools/prefix-registry.py`), but validate bounds and
surface malformed/incomplete input rather than trusting its successful return.

Read normal directory 1, delay directory 13 (RVA and legacy VA forms), import names
and ordinals, exports/forwarders, Machine, CHPE and CLR flags. Distinguish native
PE32 from managed AnyCPU; decode CLR ModuleRef/ImplMap for P/Invoke, including
extensionless names and remapping. Do not execute a PE to discover its contents.

**Gate:** fixtures for PE32/PE32+, ordinal/name imports, delay forms, ILT/IAT fallback,
CHPE, AnyCPU/native mixed files, malformed directories/RVAs/section overlap, truncation
and all budgets. LLVM `--coff-imports`/`--coff-exports` cross-checks use the toolchain
from `.work/inputs.local`, including symbols/ordinals, not just library names.

### 2. Resolve the exact runtime dependency graph

Read the actual staged/built provider images, patched specs and generated API-set
schema. Model architecture-correct local DLL resolution, explicit native/builtin
and graphics overrides, the Steam API replacement, and Wine search behaviour.
Prefer an actual resolved local provider, not any same-basename file elsewhere.
If LoadLibrary flags, working directory or AddDllDirectory state cannot be known
statically, return ambiguous resolution instead of pretending to mirror it exactly.

Resolve API-set family/version rules and default/parent-specific aliases from this
Wine build; retain raw contract and host. Follow **requested exports only**, including
forwarded names/ordinals and cycles. Audit explicit spec stubs with architecture
guards against the selected provider; a Wine graphics spec is not the selected
DXMT/Vulkan provider's implementation. Separate installed vs merely built closure.

**Gate:** deterministic per-build JSON and human summaries; fixtures for alias parent
selection, unknown contracts, duplicate/case-colliding paths, path/symlink escape,
overrides/backend variants, missing local bytes, wrong architecture, forwarder cycles
and missing exports. Reproduce the survey's edges where unchanged, explaining drift.

### 3. Add guarded dynamic and feature evidence

Add exact CLR P/Invoke edges to the closure. Inspect IL2CPP GameAssembly and authorised
local `global-metadata.dat` with version-aware parsing; unsupported versions are
incomplete, not empty. Native literals correlated with loader APIs remain heuristic;
unlinked literals never become mandatory roots. Derive COM providers from the actual
registry resources/seed and installation registrations, not guessed CLSID mappings.
Retain unresolved dynamic plugin/registry paths and packer evidence explicitly.

**Gate:** fixtures for extensionless/remapped P/Invoke, managed architecture, IL2CPP
version mismatch, dead strings, runtime-built names, COM registrations and packed
files. Whole-folder and selected-launch summaries stay separate. Provide an import
format for scrubbed runtime evidence, but do not start trial plays as the collector.

### 4. Finish the full owned-library census — hard pre-staging gate

Produce a PE-only retrieval cost sheet before fetching: selected files, manifest
identity, compressed bytes/chunk reuse, local cache hits and remaining bytes per
store/build. Bound concurrency, total bytes and retry counts; present changed cost
estimates before increasing a budget. No full game downloads merely to scan imports.

- **Steam:** authorised selected depot PE subsets or exact-build local/phone files.
  Saved library/depot metadata is not an import table or payload authorisation.
- **Epic:** finish all selected PE chunks, including large launch EXEs and skipped
  installer/anti-cheat/helper files. Cover binary and legacy JSON manifest formats.
- **GOG:** the scratch session was expired and the unauthenticated request returned
  429. No refresh or repeated unauthenticated retry. The owner signs in through the
  existing UI if needed. Use authorised gen-2 chunks and gen-1 container ranges
  (Quake II Original); public file manifests do not imply public payload access.
- **Phone:** read-only copies under the shared lock, tied to exact install receipts;
  the old five-pulls-per-title sample is not enough. Do not uninstall Playport or
  remove existing titles to make room without the owner's approval.

Verify store chunk and whole-file hashes where available, plus local content hashes;
keep transport verification distinct from manifest file verification. Reject unsafe
paths/symlinks and partial cache entries. Import-directory range fetching is an
optional optimisation, **not a substitute for this full-file gate**: it cannot claim
recomputed whole-file hashes or complete managed/literal coverage.

**Gate:** every frozen owned entry passes the coverage contract above. Recompute
normal/delay/helper/dynamic counts, unresolved symbols and stripped-size estimates.
An independent LLVM cross-check across architectures and each store must agree.
Publish scrubbed aggregate coverage/results; retain the detailed account ledger
privately. Missing authorised bytes block chunk 6 even though all-built is selected.

### 5. Audit the full staging policy and its risks

Review every production built ARM64EC DLL/driver, not just the sampled union. Audit
normal/delay/requested-forward closure, native/aarch64 companions, unix-call table
availability and registry/COM activation. Explicitly retain unsupported services
(e.g. PLA-50), symbol residuals (e.g. dxcore), and not-built modules. Review embedded
third-party notices, source/relink obligations and ancillary registration/data needs
under [NOTICES](../NOTICES.md#the-apps-selection) and [LICENSING](../LICENSING.md).

The decision record specifies manifest-derived all-built selection, replacement
precedence, architecture boundaries, no auto-loading/downloads, costs and unresolved
behaviour. Refresh the 453-name/358.125-MiB estimate and describe any drift. If the
audit finds an unsafe broad-registration path, stop for an owner decision rather
than silently excluding DLLs or loading them all to see what happens.

**Gate:** completed census, reviewed deterministic staging/provider report, all
exceptions/replacements explained and residuals assigned; current source/licensing
review and activation risks settled. The policy is all-built, not a dependency union.

### 6. Stage all built ARM64EC DLLs and verify both variants

Change `build/stages/stage-artifacts.py` to derive the production ARM64EC `.dll`/`.drv`
set from the generated manifest, as i386 already does, excluding tests/programs.
Do not paste 453 filenames into `EXTRA_PE`. Deduplicate destinations and preserve
special ntdll provenance, FEX `xtajit64`, DXMT overrides and separate Vulkan/Steam API
providers. Keep intentional reference-only resources and explicit gap rows intact.
The all-built rule applies to provider names; replacement modules must not be
accidentally overwritten by Wine's versions. Aarch64 additions require their audit.

Add stager and IPA verifier tests for completeness, replacement hashes/provenance,
missing/stale manifests, excluded tests/programs and case/destination collisions.
Regenerate `app/artifacts.tsv`, caused `build/generated/wine-pe-*.tsv` changes and
registry via `./pp registry`; never hand-patch a few seed lines. Run notices collection,
review/selection and both dev/release build/verify paths according to
[BUILDING](../BUILDING.md). Retain the outputs' hashes, exact provider manifest,
real IPA compressed delta and uncompressed bundle delta against the refreshed base.

**Gate:** both actual IPAs match the all-built policy and selected backend providers;
registry/notices checks pass, no unintended programs/tests or host paths ship.
Phone: upgrade in place, Hollow Knight and Portal 2 to `first-frame+10`, exercising
ARM64EC and WoW64. Compare JIT pool use/footprint and loaded-module changes with the
same settings baseline; explain increases and stop on a new failure or memory limit.

### 7. Generate exact-bundle compatibility metadata

Generate a versioned compact catalogue from the files actually staged for each
variant: architecture, provider path/hash, export names/ordinals/requested forwards,
API-set mappings, explicit spec-stub classification and reviewed unsupported features.
Tie its digest to that variant's artifact inputs and verify it against the IPA.
Unknown source/backend implementation status stays unknown. Do not embed build-tree
paths or the owner's game inventory. Bound its size and app-side lookup cost.

**Gate:** catalogue generation is deterministic, invalidated by provider/pin/spec/
override changes, and fails on stale hashes. Tests prove dev/release catalogue parity
where providers are equal and correct differences where they are not. `pp verify`
checks catalogue consistency, not a hard-coded list of "working" Windows APIs.

### 8. Add bounded install/adoption compatibility warnings

Extract a reusable bounds-checked PE reader from
`app/PlayportKit/Sources/PlayportKit/Direct3D.swift` or add a sibling analyser, retaining
Direct3D's selected-EXE/reachable-local-DLL semantics. Whole-folder survey evidence
must never turn an unused renderer into routing evidence. Use shared synthetic
fixtures to keep Swift and host results aligned without shipping a host tool.

After Steam/Epic/GOG install, update/repair or Local adoption, compute selected-launch
findings asynchronously and persist a versioned result tied to selected EXE, game
content identity, override settings and runtime catalogue digest. Invalidate on
changes; rescan existing adopted titles when the app's runtime changes. A small
bounded scan must not stall catalogue refresh, downloads, UI or Play. Budget stops,
read/parse errors and unsupported metadata report incomplete, never success.

Show a non-blocking **Runtime checks** section on the game's page, available with
controller and touch, with expandable relative file/DLL/symbol details:

- "This build does not include a runtime DLL referenced by this game."
- "This game references an export this runtime does not provide."
- "This game references an API that is not implemented in this runtime."
- "Runtime checks are incomplete" with the specific reason.
- With no findings: "No missing runtime imports found in the scanned files" — not
  "Compatible", "Works" or a green guarantee.

Label normal, delay/plugin/helper and heuristic findings distinctly. Optional or
string-only paths must not falsely declare the launch broken; even a spec stub's
presence does not prove it is called. Existing anti-cheat/launcher refusals remain
separate. No automatic backend switch, install rejection or runtime download.

**Gate:** Swift fixtures cover architecture/provider parity, missing DLL/export/stub,
uncertainty/budgets, optional paths, invalidation and warning wording. `./pp check`,
`./pp test`, both builds/verifications pass. Show positive/incomplete warnings on the
phone by importing source-built synthetic fixtures through the existing UI; show
an ordinary game's page without a blanket compatibility claim. Dev-only driver
support stays in Dev/ or behind the release guard; a person checks the release UI.

### 9. Confirm feature paths and close the plan honestly

Use the existing UI and shared device lock; no analysis CLI launch route. First
answer hidden-window or game/runtime questions under isolated desktop Wine using
[HOST-DEBUGGING](../HOST-DEBUGGING.md), rather than repeated no-frame phone plays.
Record which DLL/symbol/feature each run actually exercised:

| Gate | What must be demonstrated |
| --- | --- |
| Hollow Knight, Portal 2 | First frame +10, gameplay regression; ARM64EC and i386 paths |
| Valheim (DXMT), Moonscars | Party/XCurl/GDK paths and online features where actually reached; never assume a shipped plugin executed |
| Snakebird Complete | EOS sign-in/credential persistence on successive plays; already-staged cryptsp regression |
| Among Us | GDK/plugin path if reachable; PLA-39's unrelated crash remains a separate blocker |
| Jurassic World Evolution | Packed/static findings and loader diagnostics; existing DRM/no-frame issue is not a DLL-staging success |
| Additional census findings | Feature-specific run or a source-built UI-imported probe for each newly claimed working API path |

Do not require purchases or online anti-cheat games just to exercise an export.
Cross-check post-launch DLL/export failures with predicted findings. An unrelated
failure is filed in Linear, not fixed in passing; a blocked feature is explicitly
unvalidated. Do not call an untested plugin "needed" or "working". Owner approval
is required for account-changing actions such as permanent achievement unlocks.

Install dev and release in place in sequence (same bundle/container); release has
no driver, so its manual warning and play checks need the owner. Restore the desired
variant afterwards. Capture actual full IPA SHA256s, run directories, settings,
loaded-module/JIT pool/footprint observations and screenshot descriptions in a
scrubbed `docs/evidence/` record. Every played title updates its existing Compatibility
issue with Status, Best known, full IPA hash and run directory; search before creating.

**Final gate:** complete frozen owned-library PE inputs; both IPAs satisfy the
all-built ARM64EC policy without overwriting replacements; exact-bundle metadata,
registry and notices pass; UI warning states shown in both variants; regressions
pass and claimed feature paths have evidence. Residual missing exports/stubs,
unsupported features and packed/dynamic uncertainty remain explicit. Any blocked
mandatory gate leaves the plan partial — static analysis never proves all future
features or downloaded plugins compatible.

## Execution handoff

Start with chunk 0, then host parsing/resolution/evidence (1–3), the complete census
(4), audit/decision (5), staging (6), catalogue (7), UI (8) and final features (9).
Collection can overlap independent read-only analysis once exact input contracts
are stable, but it must not bypass chunk 4's pre-staging gate. Do not launch a writer
or use the phone merely because this plan now exists.

The first external blocker is authorised exact-build Steam/GOG payload access; the
survey alone cannot satisfy the owner's coverage choice. Present the frozen
inventory, retrieval cost sheet and precise missing inputs before asking for access.
If that access cannot be provided, finish and commit the host-analysis chunks and
report **blocked before staging**, not a completed runtime/UI rollout.
