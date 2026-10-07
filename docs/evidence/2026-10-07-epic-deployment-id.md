# Epic launch sidecar deployment ID (PLA-61)

**Date:** 2026-10-07. **Scope:** launcher argument parity, not a runtime fix or a
claim that another EOS game signs in. Dev IPA sha256
`e88913324971efec7676d61c04f8c14e6f071336411b3433e9e87172d713bf56`;
iPhone18,4, iOS 27.0. The owner approved installing House of Golf 2 for this check.

## Change

`EpicContent` reads the optional Live asset `sidecar.config` JSON string and accepts
`deploymentId` only as 32 ASCII hex digits; it retains `sidecar.rvn`. Missing or bad
config gives no ID. Neither is a credential or player identity.

`EpicInstalled` keeps `deploymentID` and `sidecarRvn` at install/update; old records
still decode without them. The page's existing asset/update request refreshes those
values and the receipt's deployment argument, even without a build change. An absent
sidecar removes the old argument. The receipt's install date, installed build and
other arguments stay unchanged; a check also heals a two-file write interrupted
between receipt and record. A no-op check writes nothing. Repair refreshes metadata
when it fetches an asset for damaged files.

The receipt includes `-epicdeploymentid` alongside the public Epic arguments, online
and offline. Play reads the kept record again to avoid a stale adoption/page snapshot,
validates the ID, and replaces any cached deployment argument. No asset request is
added at Play, and no secret or token handling changes (decision 0059).

## Host and IPA checks

- `./pp test`: all passed, including name/secret gates, C and Swift tests.
  EpicClientKit: 22 tests, zero failures.
- New coverage: valid/missing/null sidecars; absent revisions; malformed JSON, missing,
  wrong-type, short, non-hex, Unicode and argument-injection IDs; persistence and old
  records; metadata refresh/removal; unchanged build/date/other receipt fields; no-op
  checks; duplicate stale arguments; interrupted-write healing; same public ID with
  and without sign-in; deployment ID remains visible under both argument redactors.
- `./pp build`: all 80 IPA checks passed; runtime trees unchanged, Swift app rebuilt.
- One initial test failed because the refresh helper moved an unchanged argument to
  the end, rewriting an otherwise identical receipt. Fixed by retaining the first
  argument's position while removing duplicates; the full suite then passed.
- Logs stay in `.work/pla61-host-tests.log`, `.work/pla61-build.log` and
  `.work/pla61-install-ipa.log`. No committed build records changed.

## Phone: House of Golf 2

Epic app `48cfbcf29a4441a894d05a203e03dc74`, build `1.2.6.1.0`.

1. `.work/ui-runs/pla61-install`: installed through the UI in 399 s,
   21,891,515,028 bytes. Adoption reports Ready and arguments:
   `-epicapp=… -epicenv=Prod -epicdeploymentid=305d8b4aee794b02914830a3825f3eaf
   -EpicPortal -epiclocale=en`. This is the real Live asset's sidecar ID, not a test
   launch-setting argument.
2. `.work/ui-runs/pla61-golf`: opened its page, waited 3 s for the update check, then
   Play. The exchange code was fetched in 0.42 s; JIT in 2.39 s. Both the in-app start
   line and Wine's `NtCreateUserProcess` command line carry that deployment ID; the
   credential fields remain redacted. **PLA-61's argument delivery is phone-confirmed.**
3. **The game itself is Broken (PLA-67), separately:** no first frame. Its default
   `house_of_golf.exe` bootstrap asks for Microsoft Visual C++ Runtime in a MessageBox,
   then starts `Engine\\Extras\\Redist\\en-us\\UEPrereqSetup_x64.exe`. The installer
   reaches an i386 child which ends on unaudited win32u call `15d0` (`0xc00000bb`). The
   bootstrap ends `0x0000232c` (9004) after 5 s. The screenshot shows Playport after
   the failed launch, not gameplay. The shipping executable and EOS sign-in were not
   reached or tested, and no runtime/prerequisite workaround was added in this task.
4. Read-only pulls after the plays confirm the phone's install record has the same
   `deploymentID`, `sidecarRvn: 1`, 35 files and the installed build; its store receipt
   contains the same deployment argument. Kept under `.work/pla61-records/` and
   `.work/pla61-receipts/`, not committed.

## Phone regressions (same IPA)

| Game | Run | Result |
| --- | --- | --- |
| Snakebird Complete (Epic, no sidecar) | `.work/ui-runs/pla61-snakebird` | first frame +4.82 s, JIT 2.64 s, through `first-frame+10`; screenshot shows its main menu; exchange code fetched in 0.42 s; no deployment argument added |
| Hollow Knight (Steam, Vulkan) | `.work/ui-runs/pla61-hk` | first frame +9.84 s, JIT 2.50 s, through `first-frame+10`; screenshot shows its main menu |

Both return `ok: true`, with no pool exhaustion or FEX refused requests. This is a
launch/menu regression check, not gameplay or a fresh EOS consent/sign-in measurement.
Linear compatibility results: PLA-44, PLA-42 and PLA-67.

## Limits

Host tests, not phone manipulation, cover sidecar revision changes, disappearance,
pre-sidecar migration and offline argument parity. Epic's real sidecar was not changed.
No release build, sign-out, offline-mode page, permanent achievement write or token
storage sweep was performed for this public-ID-only change. Screenshots remain under
`.work/ui-runs/`; no game artwork is committed.
