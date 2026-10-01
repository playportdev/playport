# Plan: Increased Memory Limit through SideStore (GetMoreRam)

**Date:** 2026-10-01. **Status:** research plan. The SideStore and SideSign
source was read; nothing was signed, installed or run on a phone. **Blocks:**
the README's and the site's "sideload it with SideStore" advice, which stays
as it is until this plan has an answer.

## The problem

Playport needs `com.apple.developer.kernel.increased-memory-limit`
([DISTRIBUTION.md, section 6](../DISTRIBUTION.md#6-signing-tools-and-the-memory-limit)).
Without it an 8 GB phone gives the app about 3.3 GB, against 6 GB at start and
8 GB with Game Mode on the reference phone, and the 512 MiB JIT pool
([decision 0036](../decisions/0036-one-512-mib-jit-pool.md)), the runtime and
the game share that limit. The README and the site name SideStore as the way to
sideload and refresh, and SideStore drops the entitlement for a free Apple ID.

## What the source shows [code]

Read at SideStore `develop` `0dd743f` (2026-09-20, `MARKETING_VERSION`
0.7.0) and SideSign `main` `6b68651` (2026-09-19):

- SideStore asks for the entitlement:
  `OperationEntitlements.defaultAdditionalEntitlements` adds
  `increasedMemoryLimit`, `increasedDebuggingMemoryLimit` and
  `extendedVirtualAddressing` to every app.
- SideSign allows it in a free team's *entitlements*
  (`Entitlement.freeEntitlements`) but not in its *features*:
  `Feature.freeFeatures` is only `appGroups` and `interAppAudio`
  (`Sources/Models/Feature.swift`); `increasedMemoryLimit` is in
  `paidFeatures` only.
- `FetchProvisioningProfilesOperation.updateFeatures` drops every feature
  outside `team.type.allowedFeatures` before it updates the App ID, and logs
  "Dropped non-applicable features". The capability never reaches the App
  ID, so the profile lacks the entitlement.
- SideStore's App ID page (`AppIDDetailView.swift`) lists features but edits
  only App Groups: there is no switch to turn the capability on in the app.
- SideStore issue #1616 (open, filed 2026-09-24, no assignee or PR) reports
  this and names AltSign's separate `bundleIdCapabilities` request for
  `INCREASED_MEMORY_LIMIT` as what AltStore does differently.

`updateFeatures` sends an App ID update only when one of *its* target
features differs from the portal's, and the memory capability is never among
its targets. So a capability that something else turned on may survive a
SideStore install and refresh. That is the hypothesis to test **[hyp]**.

## GetMoreRam

GetMoreRam (hugeBlack/GetMoreRam) signs in with the Apple ID that signed the
app, lists its App IDs, and turns on Increased Memory Limit on one; the person
then reinstalls the app from SideStore or AltStore. Not yet read in source.

## Questions

1. Does GetMoreRam turn the capability on for a **free** team's App ID that
   SideStore created (SideStore's own bundle ID prefix, not `XTL-`)?
2. After that, does a SideStore reinstall give a profile with the
   entitlement, and does Settings › Memory show it On with the larger limit?
3. Does it last through SideStore's weekly refresh, and through a refresh
   after the profile expired? If SideStore does send an App ID update (an App
   Group change, say), does Apple's portal keep features the update leaves out?
4. Is the JIT helper extension's App ID affected? Only the app process needs
   the capability; check that a SideStore install signs the extension at all
   and that every Play still gets JIT.
5. AltStore Classic 2.3: does it keep the capability on a free team as #1616
   reports? DISTRIBUTION.md marks it "not tested here".

## Method

On the reference phone, with a **free** test Apple ID (never the workstation's
team; nothing identifying goes into the record, `pp secrets` before
committing):

1. Install the release IPA with SideStore. Record Settings › Memory (limit and
   On/Off) and SideStore's log line for dropped features.
2. Run GetMoreRam on the App ID, reinstall from SideStore, record Settings ›
   Memory again.
3. Play Hollow Knight to `first-frame+10`, then a title that needs the memory
   (Kingdom Come, [kcd-memory](../evidence/2026-10-01-kcd-memory.md)), and note
   the peak against the limit.
4. Refresh in SideStore (forced, then after expiry) and repeat step 1's check.
5. Repeat steps 1 and 3 with AltStore Classic 2.3.

The result goes to `docs/evidence/<date>-sideloader-memory-limit.md` with the
IPA's sha256, and DISTRIBUTION.md's signer table is updated from it.

## Outcomes and what follows

- **GetMoreRam works and survives refresh:** the README and the site keep
  SideStore and add the GetMoreRam step; the first-run checklist could link it
  when Settings › Memory reads Off.
- **It works but a refresh loses it:** recommend AltStore Classic (if step 5
  holds) and name SideStore as unsupported until #1616 is fixed.
- **Either way:** offer SideStore the fix #1616 points at (the capability in
  SideSign's free features plus AltSign's `bundleIdCapabilities` request), and
  remove the workaround once a SideStore release carries it.
