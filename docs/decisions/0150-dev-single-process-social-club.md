# 0150: Dev-only, build-locked single-process Social Club

**Status:** accepted by the owner, 2026-10-20: "Yes, port it (dev first)".
**Linear:** PLA-364

Amends [0109](0109-chromium-switches-for-a-cef-browser.md) and
[0110](0110-own-cef-build-for-a-clients-cef.md): the owner's exception to the no-patching
rule covers only the installed `SocialClubHelper.exe` page bridge described here.
It does not permit patching any other Rockstar component or build.

## Decision

- **Off by default, dev only.** The existing title Runtime options UI accepts
  `env.PLAYPORT_SC_SINGLE=1`. The host's `playport_sc_single_enabled` capability
  returns false in a release executable regardless of saved or inherited keys.
  No compatibility default changes before a phone A/B. `0` or an absent key
  keeps today's multi-process policy.
- **Exact build and code, not just a name.** Only `SocialClubHelper.exe`, x64,
  TimeDateStamp `0x6a86d563`, SizeOfImage `0x244000`, is eligible. Before changing
  flags or refusing a child, madeira-unix 0190 reads the already-open image into
  a private, non-executable buffer and runs willfaust/Madeira's `293cd39` guard:
  all 48 SHA-256 ranges, section layout, vtables, and zero code/data tails.
  Proprietary code bytes are not stored in the patch or tests. A different build,
  changed range, malformed file or allocation failure logs `[sc-single]` and
  retains today's multi-process policy, including its existing CEF switches.
- **One helper process per browser.** A verified browser gets `--single-process`,
  BackupRefPtr disabled (merged into its existing feature list), `--js-flags=--jitless`
  unless it already supplies its own JS flags, and `--no-proxy-server` unless
  it supplies a proxy. Every verified `--type=` helper child is refused with
  `STATUS_ACCESS_DENIED`. Other executables and unverified helper children keep
  today's policy. No generic child blocklist or stock-CEF address-space changes.
- **The in-memory compatibility change.** Port the helper adapter from
  willfaust/Madeira (`61dce1d`, originally `0f40502`/`fcfb69a`, guarded by `293cd39`):
  - Put position-independent x64 thunks in the checked zero tails of `.text`
    and `.data`; redirect the browser CefApp's `GetRenderProcessHandler` slot
    to construct/cache its own renderer CefApp and return its page-bridge handler.
  - Redirect `OnWebKitInitialized` to initialize the renderer thread's helper
    MessageLoop and pump it through CEF delayed tasks: at least 10 ms between
    tasks, at most 32 work iterations, scoped/nested RunState preserved.
  - Drain renderer startup work on that thread's TLS loop, never the browser's
    concurrently active global loop.
  - Give the renderer its own IPC manager, using the retained main command line
    and renderer role. Preserve the browser manager/global loop/channel and
    destroy the renderer manager with its owner. Page-channel replies retain
    prior connections within the existing 64-slot capacity; explicit disconnects
    and window-close delivery remain intact.
  - Add bounded RunState, IPC rebind and UI-close diagnostics. The UI-close hook
    records the source/caller and resumes the original constructor; it suppresses
    no notification. Fault diagnostics are read-only, bounded Mach reads.
- **Write-boundary check.** Carry the successful preflight decision on the
  new child thread, not in a global path/inode cache. After relocation and before
  protections or the JIT copy, run the complete guard again. If that selected
  image changed between preflight and mapping, fail its load closed with
  `STATUS_INVALID_IMAGE_FORMAT` and `[sc-single] race: image changed after preflight,
  load refused`. Never run single-process without its bridge. This exceptional
  race is not a multi-process retry; count it separately in evidence (expected 0).
  Unlike upstream, whose mismatch guard left `--single-process` active, ordinary
  preflight mismatches fall back before any policy change.
- **No checks bypassed.** Review of the ported thunks found only CefApp,
  MessageLoop, IPC ownership/channel lifetime and bounded tracing changes.
  No protection, licence, privilege or authentication check is changed, skipped,
  forged or made to succeed. Sign-in and its real result remain the helper's.
  No installed executable or DLL is changed on disk. Playport's version-matched
  CEF substitution from 0110 remains in place; no game-side libcef refusal is ported.

## Relationship to the memory experiments

[0130](0130-end-the-rockstar-launcher-at-the-games-sign-in-or-near-the-memory-limit.md)
(with 0140's margin) still ends the launcher's tree at the game's sign-in or near
its memory limit. It never ends the game's helper.

[0133](0133-a-dev-build-may-end-rdr2s-own-social-club-after-its-sign-in.md),
[0138](0138-refuse-rdr2s-social-club-restarts-at-process-creation.md) and
[0141](0141-end-rdr2s-own-social-club-no-sooner-than-120-s-after-its-sign-in.md)
are not retired or automatically overridden. For the A/B, turn both
`endGameSocialClubAfterSignIn` and `refuseGameSocialClubRestart` off in **both** arms:
ending/refusing the helper would confound a test of keeping it alive and signed in.
0141 has no separate switch; its delayed end is inactive when 0133 is off.

## Gates and risks

Host fixtures execute the thunks against synthetic Win64 ABIs, not a real CEF
or a sign-in service. Desktop proof uses only the authorized sway session and an
isolated copy of the scratch prefix, after the supervisor's account-use clearance.
The phone needs Hollow Knight first-frame+10 and RDR2 key-off/key-on runs with the
same settings, tracking helper count, threads, footprint, page/sign-in state,
`SC_INIT_ERR_WEBSITE_FAILED_LOAD`, guard fallbacks and race refusals.

Single-process merges browser/renderer fault domains and can still exhaust memory.
A helper update intentionally loses this optimization. No release enablement,
retirement of 0133/0138, gameplay success or memory saving is claimed by this record.
