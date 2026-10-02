# 0.1.0 draft: LLVM verification and recipient re-sign/install/play

## Scope and identities

The draft targets `116001ca035d0b7b6350e94f6567c4c8bd4e1f23` on
`release/0.1.0`. These results do not cover later uncommitted app changes.
The GitHub release remains an unpublished draft pre-release; nothing here
approves publication or clears the source-payload audit.

- Original `Playport-0.1.0.ipa`: sha256
  `610e209a3a2a3c496ed35828a677244151cb14c62348f4d4428b0c74c764ed16`.
- Matching `Playport-0.1.0-source.tar`: sha256
  `eeea02c5943debcab8d858dc00c87aa176c2a2eef03a2180ac8537885585b041`.
- Source manifest: sha256
  `aeb746d46a262df01578060b6b20fc445da2da23ae02270e4b4ffc0a175a6445`;
  status complete, no catalogued missing sources.
- Locally re-signed IPA installed on the phone: sha256
  `8ef1451d0045d3b6de827e35ba8e94b4d0f93b9bac57cf44d3c1982455d80ae4`.
  It contains private provisioning data and is not a release asset.

The assets' outer `SHA256SUMS` all passed. The extracted source package
passed `pp source --check`. Earlier preparation passed full `pp test` and
all 69 unsigned IPA checks, followed by distribution-notice verification.

## LLVM's detached signature

Fetched `llvm-project-15.0.7.src.tar.xz.sig` from LLVM's GitHub release
`llvmorg-15.0.7`, and `release-keys.asc` from
<https://releases.llvm.org/release-keys.asc>, linked by
<https://releases.llvm.org/>. Used an isolated GPG home under
`$PLAYPORT_BUILD/release-prep/gnupg`, not the workstation's personal keyring.

GPG verified the exact LLVM archive from the matching source package:
`VALIDSIG 474E22316ABF4785A88C6E8EA2C794A986419D8A`, dated 2023-01-12,
Tom Stellard. GPG returned zero and reported a good signature, but also
`EXPKEYSIG`: the published key has since expired. This is verification of
this historical signature using the key LLVM publishes, not a claim of
current key validity or a personally trusted identity.

## Re-signing the exact IPA, not rebuilding

With the owner's approval, used the workstation's patched xtool 1.20.1
(`$XTOOL`, from `build/env.sh`) on the original draft IPA:
`xtool install --network IPA`. Source inspection confirmed that this command
unpacks, provisions and signs the supplied IPA, then installs it; it does not
compile the app. The installed tool has the increased-memory-limit patch.

Held the device lock across signing, verification and installation. Set
`XTL_TMPDIR` and `TMPDIR` under `$PLAYPORT_BUILD/release-prep/resign-tmp`;
`XTL_DEBUG_TMP=1` retained xtool's signed `app.ipa` for verification. Private
signing logs and the signed test copy remain under `.work/release-prep`.
No app was uninstalled.

`pp verify --variant release` passed all 63 signed checks, including the
memory entitlement, CMS signer/profile agreement, CodeResources seals and
the JIT helper's own App ID/profile. Comparing the original and signed ZIPs:

- Two provisioning profiles were added; no files were removed.
- The main app and helper Info.plists changed only `CFBundleIdentifier`.
- Other changes were the four Mach-O signatures and two CodeResources files.
- All four Mach-O code payloads matched after normalizing `LC_CODE_SIGNATURE`
  and the signature-dependent `__LINKEDIT` sizes.
- Every other file was byte-identical, including runtime resources and notices.

The retained signed copy then went through `pp install --variant release
--no-build --ipa ...` to confirm the profile/device, upgrade in place and
update the shared install record. The install preserved the container;
its profile expires on 2026-10-09. This validates patched xtool on this
workstation, not AltStore, SideStore or another recipient's account.

## Phone play

Reference phone: iPhone18,4, iOS 27.0. The owner opened the release from its UI
and confirmed Hollow Knight reached its first frame, ran for at least ten
seconds afterward, and Increased Memory Limit showed On.

Pulled `Documents/playport.log` after that report. It independently records:

- `increased-memory-limit yes`; 6144 MB at startup and 8192 MB for the play.
- Hollow Knight launched on DXMT with a 512 MiB JIT pool.
- The built-in helper ran `playport-universal.js`, blessed 32768 pages and
  detached after one prepare; activation took 2.47 seconds.
- `title: +9.98 s first frame`.
- No pool exhaustion at the last reported pool sample.

The log reports `controller=none` at launch, so this is not a controller-input
validation. The first-frame-plus-ten observation is the owner's manual report,
not an automated driver result (the release has no driver). The collected
screenshot showed the owner's terminal after switching away from the game,
not game artwork; it is not visual evidence of the first frame. No crash
report was returned for the interval starting before re-signing. The installed
IPA hash in `pp phone status` still matched the signed copy above.

## Source payload audit: OPEN, not cleared

`tools/source_payload_audit.py` examined the extracted exact source package.
It returned 2 with `scan_complete=false` and `release_cleared=false`:
271926 members, 251198 regular-file payloads and 4465940474 expanded bytes.
The payload-free report is `.work/release-prep/source-audit.json`; a local-only
path mapping was retained for triage, not attached or committed.

The scan blockers map to upstream material:

- Five `.git` pointer-file paths inside nested gbe_fork dependency archives.
- Five compressed-stream decode failures in crate compression-test fixtures.
- Four LLVM LLDB FreeBSD crash-dump fixtures exceeding the 64 MiB decoded-file
  limit.
- One unsupported/opaque PCRE2 compressed fixture and one special ZIP member
  in a crate fixture.

There are also heuristic secret, binary/media, game-path and private-path
review findings across upstream sources and Playport's fixtures, tooling and
committed evidence. A match is not by itself a discovered secret or game;
these findings have not all been manually adjudicated. Upstream provenance,
a valid LLVM signature and complete Corresponding Source do not clear them.
Do not publish until the outstanding payload review is resolved and the
owner approves the final package. The original draft assets were not changed
by this verification or phone test.
