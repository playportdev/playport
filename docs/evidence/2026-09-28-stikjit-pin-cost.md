# What moving the stikjit pin costs, and the iOS versions JIT is known on

**Date:** 2026-09-28. **Plan:** [runtime risks](../plans/2026-09-27-runtime-risks.md),
item 1. **Result:** moving the `stikjit` pin from StikJIT 1.6.0 to 1.9.0, the
newest release, costs one line in `build/stages/stikjit.sh` (the check after the
swiftinterface rewrite) and nothing in the script protocol, the idevice notice or
`prepare_memory_region`. A trial IPA built with 1.9.0 enabled JIT for Hollow Knight
on the phone as 1.6.0 does. The pin was not moved: this record measures only.
DEVICE.md now names the tested iOS versions and has the pin-move procedure
([Known-good iOS versions](../DEVICE.md#known-good-ios-versions)).

## What there is to move to

StikDebug publishes two things, and only one of them can be our pin:

| Repository | What | Newest |
| --- | --- | --- |
| StikDebug/StikJIT | the embeddable framework (MPL-2.0), a prebuilt `StikJIT.xcframework.zip` per tag: our `stikjit` pin | 1.9.0, 2026-09-27 (commit `32287268fa5824f9edce4cb359f5833ce0cf7b00`) |
| StikDebug/StikDebug | the JIT app (AGPL-3.0), an IPA per tag | 3.1.12, 2026-09-27 |

The StikDebug app does not use the StikJIT framework: it has its own copy of the
same JIT code (`JSSupport/`, `Support/ProcessInfo+TXM.swift`) and its own
`idevice/` directory. So "moving to StikDebug 3.x" means one of two things:

- **Moving to the StikJIT release that goes with a StikDebug 3.x release.** They
  are released together: StikJIT 1.9.0 and StikDebug 3.1.12 both carry the commit
  "fix: restore personalized DDI mounting" on the same day, and StikJIT 1.6.0 came
  one day after StikDebug 3.1.11's cryptex DDI change. This is the move measured
  below.
- **Taking code from the StikDebug app.** It is AGPL-3.0, and
  [decision 0010](../decisions/0010-jit-without-a-host.md) and LICENSING.md keep the
  app out of the IPA. The only StikDebug change that StikJIT lacks and that
  matters to us is its iOS 27 TXM detection (below). It is ten lines of logic,
  and it is not worth that licence change.

StikJIT releases from 1.6.0 to 1.9.0 (`git diff 1.6.0 1.9.0` in StikJIT):

| Tag | Change |
| --- | --- |
| 1.6.0 (our pin) | the binary is stripped; DDI mounting moved to the cryptex DDI (five files) on every iOS version |
| 1.7.0 | built with Xcode 27 (the CI runner) |
| 1.8.0 | `Script.customBase64(String)`, a script passed as data instead of a file |
| 1.9.0 | the personalized DDI (three files) again below iOS 26.4; the cryptex DDI from iOS 26.4 |

## The cost, part by part

| Part | 1.6.0 to 1.9.0 | How it was measured |
| --- | --- | --- |
| Script protocol (`app/PlayportJIT/playport-universal.js`) | **none.** `Sources/ScriptRunner.swift` and `Sources/JITSession.swift` are the same in both tags: the same four host functions (`get_pid`, `send_command`, `prepare_memory_region`, `log`), `QStartNoAckMode` before the script, the same TXM gate. `Script.custom(URL)`, which the helper uses, is unchanged; `customBase64` is new. | `git diff --stat 1.6.0 1.9.0 -- Sources/ScriptRunner.swift Sources/JITSession.swift` is empty; the swiftinterfaces differ in the added case and the module selectors only |
| idevice library notice | **none.** The `idevice/` directory (`libidevice_ffi.a`, `idevice.h`) is the same tree in 1.6.0 to 1.9.0 (`9ed43240…`), last changed in `4e08cec` before 1.6.0. StikDebug 3.1.12's `libidevice_ffi.a` is byte-identical (sha256 `4db23fe1…`). The `idevice` pin in `pins.lock` and `IDEVICE_LICENSE_SHA256` stay. | `git ls-tree <tag> idevice` per tag; sha256 of both `.a` files |
| `prepare_memory_region` | **none.** Same code: one `$M<addr>,1:69` packet per 16 KiB page, 128 packets per batch, arguments taken as JavaScript numbers (`Double`). The address is written as 9 hex digits, so a region must lie below 2^36 (64 GiB); our pool is at `0x119000000`. StikDebug 3.1.12's version (`handleJITPageWrite`) sends the same packets and takes `UInt64` arguments. | the source at both tags; the phone run below: `Blessed 57344 JIT page(s) at 0x119000000` with 1.9.0 |
| Swift interface | **one line.** 1.7.0 and later are built by Swift 6.4, whose interfaces spell names with module selectors (`Swift::String`, `StikJIT::StikJIT.StikJIT::Configuration`). These need no rewrite, and our Swift 6.4 builds the module from them unchanged. But the check after the rewrite in `build/stages/stikjit.sh` finds `StikJIT.StikJIT` inside `StikJIT::StikJIT.StikJIT::` and stops the stage. Excluding a match after `::` fixes it: `'(^\|[^:])\bStikJIT\.(StikJIT\|DDIPaths\|DeveloperDiskImageService\|StikJITError)\b'`. | the trial build: first without that change (the stage failed: "module-qualified names left in the interface"), then with it (built; `verify-ipa`: 66 checks passed) |
| DDI | on iOS 26.4 and later, none: both tags mount the cryptex DDI. Below 26.4, 1.6.0 cannot mount (it downloads only the cryptex DDI), and 1.9.0 mounts the personalized one. The helper's DDI cache in its own Library is shared: 1.9.0 removes the cryptex-only files below 26.4. | the source at both tags; not run on a phone below 26.4 (we have none) |
| Docs | the tag and commit in `docs/LICENSING.md` and `docs/NOTICES.md`; the pin and the checksums in `pins.lock` and `build/stages/stikjit.sh` | `grep -rn 1.6.0` |

## On the phone

iPhone Air (`iPhone18,4`, A19 Pro), iOS 27.0 (build 24A437), over the network, on
battery (80 %). All three runs as one session (`pp phone lock`), each
`pp install --no-build --ipa …` then
`pp ui --expect-ipa … --play app-367520 --until first-frame+10 --shot`:

| Run | StikJIT | IPA sha256 | JIT acquire | First frame | Result |
| --- | --- | --- | --- | --- | --- |
| `ui-runs/20260928T020634` | 1.6.0 (the pin) | `111e26ecb100215f1b70ec79ef6b0a9a6c4118054b8c0a2dc7170cfd53e1c2a1` | 3.19 s | +8.92 s | ok, main menu at about 100 FPS |
| `ui-runs/20260928T021227` | 1.9.0 (trial) | `dafbaee1b6b90ccf3102d0f6d56fec50427b7ac814fbd9ae96e481e6b5137bed` | 3.19 s | +9.95 s | ok |
| `ui-runs/20260928T021355` | 1.6.0 again, after 1.9.0 had used the DDI cache | `111e26ec…` | 2.92 s | +9.91 s | ok |

The 1.9.0 run's `jit:` lines are the same as 1.6.0's: `ready, TXM present`,
`Running playport-universal.js`, `attached`, `Blessed 57344 JIT page(s) at
0x119000000`, `prepared 0x119000000 (57344 pages)`, `detached after 1
prepare(s)`, `enableJIT done`. The trial IPA was built from this branch with only
`pins.lock`, the two checksums and the check line changed, then those changes were
reverted. The phone was left with the 1.6.0 IPA installed.

Not run: a DDI download or mount with 1.9.0. The DDI stays mounted until the phone
reboots, and a reboot needs a person to unlock the phone.

## What the survey found (2026-09-28)

- **iOS 27 on A15 and later works.** Our phone is an A19 on iOS 27.0, with
  StikJIT 1.6.0 and 1.9.0 alike. StikDebug issue #463 ("support ios27?") was
  answered "Yes" and closed. The iOS 27 failures reported since were a DDI that
  was not yet published for the iPhone 18 Pro models (#464, #465, #469, fixed by
  StikDebug 3.1.11's cryptex DDI) and pairing files in the old format (#459).
- **iOS 27.2 is not known good.** Issue #471 (open): on an iPad on iOS 27.2 the
  tunnel fails with `missing field public_key`, then `TLS tunnel: Operation
  Timeout`. The maintainer suspects the pairing file. Until that is settled, do
  not update the phone to 27.2.
- **TXM detection differs.** StikJIT reads TXM from the device tree
  (`IODeviceTree:/chosen/memory-map` has a `TXM` key). StikDebug 3.1.6 and later
  instead treat every device on iOS 27 as TXM except the A12X iPad Pro, and on
  iOS 26 decide by model (iPhone14,2 and later, iPad14,5 and later). Where
  StikJIT reads TXM absent it only attaches and detaches, without the script.
  Playport always issues the `brk #0xf00d` calls, so on such a device the first
  one would kill the app. That cannot happen on our phone (TXM present). It could
  for a tester with an A13, A14 or M1 device on iOS 27, which is the case
  StikDebug's change was for. Passing `forceScript: true` to
  `StikJIT.enableJIT` in `app/Sources/PlayportJIT/JITHelper.swift` would run
  the script whatever the detection says. This is not done here: nothing can
  test it without such a device.
- **The DDI comes from GitHub at run time.** StikJIT downloads it from
  `doronz88/DeveloperDiskImage` (the `PersonalizedImages/Xcode_iOS_DDI_Cryptex`
  or `…_Personalized` directory). A new iPhone model works only once that
  repository has its image (#464, #465).
- **The idevice notice is not the whole story.** The StikJIT binary also links
  about 58 Rust crates statically (from its `libidevice_ffi.a`; the static
  library names 111), among them `tokio`, `rustls`, `aws-lc-rs` and `rsa`.
  LICENSING.md and NOTICES.md name only idevice. The set is the same in 1.6.0 and
  1.9.0, so a pin move changes nothing here, but the notices for the pin we have
  are incomplete. That is a distribution question, left open for LICENSING.md.
