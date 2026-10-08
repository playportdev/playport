# Giving an IPA to a tester or customer

**Scope: the current GPL build, not a proprietary edition.** Charging for an
IPA or supporter early access is permitted by the reviewed open-source
licences, but recipients keep their licence rights and get matching source
at no additional charge. There is no supporter-only no-sharing restriction.
Apple's terms and the delivery channel require separate review; a working
personal-team signature is not public-distribution permission.
[RELEASE-HOSTING.md](RELEASE-HOSTING.md) covers the chosen hosting: free IPAs
on GitHub Releases with donations on Ko-fi or Patreon; recipients still retain
their redistribution rights.

**What a release owes** ([decision 0042](decisions/0042-the-source-bundle-is-complete.md)):
the notices in the app, the Corresponding Source of every GPL, LGPL and MPL part
(`pp source`), the build scripts, and relinking by rebuilding from that source
([decision 0041](decisions/0041-codecs-supersets-and-relinking.md)).

An IPA that leaves the workstation, even for one tester, is a distribution:
the duties in [LICENSING.md](LICENSING.md) apply to that copy. This page is
the procedure: build from a committed tree, assemble the Corresponding
Source, collect the notices, and give the recipient what they
need to install a modified build. Do all of it for every IPA, before the
first copy goes out; the source bundle travels with the IPA through the same
channel.

Run the commands from the repository root. `pin NAME` below is
`awk -v k=NAME '$1 == k {print $2}' pins.lock`.

## 1. Build from a committed tree

A tester gets the release build ([decision
0009](decisions/0009-dev-and-release-builds.md)): no UI driver, a quiet
runtime and a size-limited log.

```sh
git status --porcelain            # must print nothing: the IPA's source is this commit
pp build --clean --variant release   # every tree afresh from its pin
REV=$(git rev-parse HEAD)
OUTDIR=$(ls -dt $PLAYPORT_BUILD/out/*-release-*/ | head -1)
grep -q "(with local changes)" $OUTDIR/provenance.txt && echo "not a clean build"
SRC=$PLAYPORT_BUILD/dist/$REV; mkdir -p $SRC
cp $OUTDIR/Playport-26.5-*.ipa $OUTDIR/artifacts.tsv $OUTDIR/provenance.txt $SRC/
```

The `verify` stage has already run `pp verify`; its resources check
ties the bundle to this commit's `app/artifacts.tsv`. If the run rewrote
`app/artifacts.tsv` or `build/generated/`, commit that first and build again,
so the bundle and the commit agree. Build-output series digests use byte filename
order, independent of the host locale. An older output whose locale-sorted digest
fails `pp source` needs a fresh build/export; do not edit its provenance to pass.

## 2. Corresponding Source

Our procedure requires a complete source bundle for that exact build next
to the IPA. GPL-3.0 section 6(d) also permits equivalent source access on a
different server, including a third party's, with clear directions beside
the binary and no further source charge; we remain responsible for completeness
and availability. A generic upstream link is not enough.

```sh
pp source $SRC/source --build $OUTDIR     # the build of section 1
pp source $SRC/source --check             # again, on the copy that goes out
```

`pp source` (`build/source-bundle.py`) packs every source that
[build/source-bundle.json](../build/source-bundle.json) lists, from the commits the
build's `pins.lock` names, never from a working copy. The packing catalog also
comes from that build commit (its hash is in the manifest), so a newer or locally
edited policy cannot change an older build's omissions or completeness status:

- **Git trees**: Playport at the build's commit (the app, the build scripts, every
  patch series, the AIR helper port), and Madeira, Wine, FEX, DXMT, Mesa, DXVK,
  vkd3d-proton, gbe_fork, Abseil, FreeType, idevice, StikJIT and xtool, each one
  `tar.gz` with its submodules expanded in place. A tag-pinned tree is packed from
  the commit the catalog records for its tag, so a moved tag stops it. The patched
  trees are these plus the series in the Playport archive. Wine's committed
  `nls/*.nls` locale/codepage data is included with `tools/make_unicode`; it is
  build/runtime data, not executable code. Objects come from the
  build's own clones and mirrors, else a fetch by commit into
  `$PLAYPORT_BUILD/cache/source` (`--offline` fetches nothing).
- **Tarballs**: LLVM 15.0.7's source release and Rust's `rust-src`, checked against
  their sha256. The GnuTLS, Nettle and GMP tarballs are in the Madeira archive
  under `build/gnutls-ios/src`.
- **GStreamer**: Cerbero 1.28.7 (the recipes, patches and configuration GStreamer's
  iOS release is built with) and the 17 source archives
  [build/gstreamer-notices.sources.json](../build/gstreamer-notices.sources.json) locks
  (GStreamer and its plugin sets, GLib, FFmpeg, libvpx, Opus, Vorbis, ...), each
  checked against the lock's sha256 and taken from the notice inputs' cache
  (`build/notices-inputs.py`) when it is there. The lock must be for the pinned
  release and reviewed against the current `build/stages/gstreamer.sh`, or packing stops.
- **Crates**: every `.crate` idevice's `Cargo.lock` names, checked against its
  checksum (a superset of what the app links).
- **Generated files**: Wine's unix-side `config.h` from the run tree.

What is left out is named in the catalog with its reason, and the manifest records
it: submodules the build never checks out (FEX's test binaries, gbe_fork's prebuilt
toolchains), Madeira's own app with its prebuilt DLLs and Apple's converter library,
and a few prebuilt files. Any other prebuilt binary, submodule, or rule that
matches nothing stops the packing, as do a build with local changes, a
`pins.lock` or series that is not the build commit's, a checksum mismatch, or a
machine path in a generated file. The output appears only once it is complete
and checked: `SOURCE-MANIFEST.json` (every repository and submodule commit, the
build and its IPA's sha256), `README.md` and `SHA256SUMS`. `pp release` packs it
into the draft's `Playport-VERSION-source.tar`.

**Complete** ([decision 0042](decisions/0042-the-source-bundle-is-complete.md)): the
catalog's `missing` list is empty. GStreamer's permissive parts (MoltenVK, the Rust
standard library and crates in `libgstaws`) and the MIT idevice inside StikJIT owe
their notices, which the app carries, not their source. LLVM's tarball sha256 was
recorded from the release download; check its detached signature on the workstation.

**The recipient's build.** Clone the public repository at the release's tag with
its submodules and run `pp build --clean`: it checks out each pin from
`upstream/madeira` or its public repository and applies the series. The bundle
holds every one of those sources at the same commits, so they stay available
whatever happens upstream. `pp build` does not read the bundle's archives directly.

## 3. LGPL relinking

A recipient relinks any statically linked LGPL component (Wine's unix side,
DXMT, GnuTLS, Nettle/Hogweed, GMP, GStreamer and its libraries) by changing its
source or series in the source bundle and rebuilding with `pp build`, which
rebuilds every tree from its pin and series. That is the relinking route; no
per-component relink test is required before a release
([decision 0041](decisions/0041-codecs-supersets-and-relinking.md)).

Replacing one library without rebuilding the rest also works. For the crypto
libraries:

`$XTOOL` is the patched xtool (`build/lib.sh`); `$SOCK` below is netmuxd's
socket, `$PLAYPORT_USBMUX_SOCKET` in `.work/inputs.local` ([DEVICE.md](DEVICE.md#setup-once)).

```sh
T=$PLAYPORT_BUILD/dist/relink-${REV:0:10}
build/stages/unix.sh $T clones shims gnutls          # the crypto statics again, in another root
cd app/.release                                           # the release package pp build made
export PLAYPORT_VARIANT=release SWIFTPM_CUSTOM_BIN_DIR=$PWD/../../build/ld64
$XTOOL dev build --ipa < /dev/null
unzip -p xtool/Playport.ipa Payload/Playport.app/Playport | sha256sum     # before
cp $T/mythic/toolchains/gnutls-ios/lib/lib{gnutls,nettle,hogweed,gmp}.a Staged/lib/
$XTOOL dev build --ipa < /dev/null
unzip -p xtool/Playport.ipa Payload/Playport.app/Playport | sha256sum     # after: must differ
unset PLAYPORT_VARIANT SWIFTPM_CUSTOM_BIN_DIR
cd ../..
python3 build/stages/stage-artifacts.py stage                    # put the recorded libraries back
```

Nettle and Hogweed embed their build root, so the rebuild in another root
gives different archives, and the executable must change. A recipient
relinks the same way with a modified library in `app/Staged/lib/`, and adds
`--sign` to sign with their own Apple ID.

## 4. Notices

```sh
pp notices $SRC/notices
```

It collects the notice inventory described in [NOTICES.md](NOTICES.md), checks
its checksums and publishes the output only after successful collection. The
pipeline selects it with `pp notices --app` and bundles `Licenses/` in both
variants; Settings › About › Licences displays it. The selected bundle carries
the owner's `release-reviewed` status, while the whole collector retains its
inventory limitations. Dev UI and dev/unsigned-release packaging are verified
([evidence](evidence/2026-10-01-licences-ui.md)); the release app on the phone is the
owner's sign-off ([decision 0068](decisions/0068-release-owner-signoff.md)).

`pp verify IPA --variant release --notices APP_NOTICES --distribution` checks
that the IPA's `Licenses/` equals the **selected app bundle**, not the entire
collection, and that it is release-reviewed. Use `run/licenses` or
`app/Staged/Licenses` as `APP_NOTICES`; add `--unsigned` for an ad hoc release IPA.
A passed check is not publication approval or a completed source/relinking package.

### Local draft assembly versus upload

`pp release VERSION --no-github` assembles a private draft; it supplies no upload command or publication approval. The normal
draft-upload route additionally requires `pp verify --distribution` against the
IPA's own extracted notices. `NOTICES.tar`, `INSTALL-REBUILD.tar`, notes and the
release manifest are attached and checksummed with the IPA/source/build records.
Producer `logs/` and `records/` are never attached. Build-output `SHA256SUMS`
covers the IPA and `artifacts.tsv`; the release separately checks original
provenance/pins and produces a complete outer asset checksum inventory.

`tools/source_payload_audit.py` checks the source payload.

## 5. Installation for the recipient

What the recipient needs to build, sign, install and run a modified build on
their own iPhone with their own Apple ID. Include this section with the
bundle regardless of whether Installation Information is legally required
for the transaction. Applicability depends on GPL-3.0 section 6's transaction
conditions (not just the phone being a User Product), and whether these
instructions suffice when the duty applies still needs review
([LICENSING.md](LICENSING.md)). These are technical instructions, not approval
under Apple's SDK, provisioning or distribution agreements.

**What the recipient needs**

- An x86-64 Linux host to build, sign and install, and again every seven
  days when the profile expires. Launches need only the
  phone (LocalDevVPN and a pairing file, below).
- Their own Apple ID. A free personal team works: three sideloaded apps at
  once, and each provisioning profile lasts about seven days.
- An `Xcode.xip` (26.6) downloaded with that Apple ID; xtool builds the iOS
  SDK from it.
- The iPhone with Developer Mode on (Settings, Privacy & Security, Developer
  Mode), paired with the host.
- A clone of the public repository at the release's tag
  (`git clone --recurse-submodules`); the source bundle holds the same sources.

**Host setup, once** ([BUILDING.md, "Prerequisites"](BUILDING.md#prerequisites)):

```sh
xtool sdk install <Xcode.xip> --slim
xtool auth login                 # their Apple ID; needs a terminal
build/toolchain/ld64.sh              # Apple ld64 for Linux; the app does not link without it
build/toolchain/xtool.sh             # xtool that keeps the increased-memory-limit entitlement
# llvm-mingw with the arm64ec CRT rebuild: BUILDING.md, "llvm-mingw"
# idevice-tools (the pairing file), netmuxd, pymobiledevice3: DEVICE.md
env USBMUXD_SOCKET_ADDRESS=$SOCK pymobiledevice3 usbmux list                  # the phone is listed
env USBMUXD_SOCKET_ADDRESS=$SOCK pymobiledevice3 amfi developer-mode-status   # true
```

**Build and sign.** Make the change, then `pp build --variant
release` (or without `--variant` for the dev build, which the workstation
drivers need). The `app` stage signs `app/.release/xtool/Playport.ipa`
(dev: `app/xtool/S1Probe.ipa`) with the Apple ID that `xtool auth` holds
and prefixes the bundle ID with `XTL-<their team>.`. To relink only a
library, use section 3 and add `--sign`. **Re-sign a received IPA without rebuilding.** The patched xtool's
`install` command provisions and signs the supplied IPA, including its helper,
then installs it. This route passed the 0.1.0 reference-phone play
([evidence](evidence/2026-10-02-release-010-resign.md)); other re-signers are not
validated by that test. After the host setup above, close a running Playport
first, keep the phone unlocked, and run:

```sh
. build/env.sh                   # selects the patched $XTOOL and the recorded socket
mkdir -p "$PLAYPORT_BUILD/resign-tmp"
./pp phone lock -- env USBMUXD_SOCKET_ADDRESS="UNIX:$PLAYPORT_USBMUX_SOCKET" \
  XTL_TMPDIR="$PLAYPORT_BUILD/resign-tmp" TMPDIR="$PLAYPORT_BUILD/resign-tmp" \
  "$XTOOL" install --network RECEIVED.ipa
```

This upgrades an existing app under the same team in place; do not uninstall
it. Signing output and any retained signed IPA contain private device/profile
information: do not publish them. Check Settings › Memory afterward; a
re-signer must keep the memory entitlement
([section 6](#6-signing-tools-and-the-memory-limit)).

**Install.**

```sh
env USBMUXD_SOCKET_ADDRESS=$SOCK pymobiledevice3 apps install app/.release/xtool/Playport.ipa   # needs a free slot of the team's three
```

If signing fails with "no current IOS devices", register the phone with the
team first ([DEVICE.md, "Free-team limits"](DEVICE.md#free-team-limits): with the unsigned
IPA, never a signed one). When the profile
expires, the app stops launching: build, sign and install again, in place.

**Every launch needs a debugger for JIT.** In the release build it comes
from the phone: LocalDevVPN (App Store) and a pairing file on the phone let a
Home Screen launch start a staged title, and the app's own helper extension
does the attach. The dev build's driven launches use the same helper; no
host provides JIT ([DEVICE.md, "JIT activation"](DEVICE.md#jit-activation)).
The helper needs no free-team slot, but its App ID counts against the team's
ten per week. Neither build has another JIT method. Playport plays one game
per app process: when a game ends, it restarts itself over LocalDevVPN and
comes back on the library, and the next game asks for JIT again
([decision 0029](decisions/0029-restart-after-each-game.md)). The player
installs LocalDevVPN and opens it once to allow its VPN; after that Playport
turns it on by itself when a Play or a restart finds it off (it opens
LocalDevVPN, which switches back to Playport), and opens its App Store page
when it is not installed. If the tunnel still does not come up for the
restart, Playport says so and the game's page offers Close Playport: connect
LocalDevVPN and reopen it from the Home Screen.

## 6. Signing tools and the memory limit

Playport needs the `com.apple.developer.kernel.increased-memory-limit`
entitlement. iOS ends a process that passes its memory limit (jetsam), and the
JIT pool (all of it dirty once blessed), the runtime and the game share
that one limit. The pool is 512 MB under any limit
([decision 0036](decisions/0036-one-512-mib-jit-pool.md)).
With the entitlement the reference phone (12 GB) gives
the app 6 GB at start and 8 GB once iOS turns Game Mode on, a few seconds
after the app comes to the front
([memory-limit](evidence/2026-09-28-memory-limit.md)); without it an 8 GB
phone gives about 3.3 GB (SideStore issue #1616). Apple offers the capability to free
teams, but a signer must ask for it on the App ID, and not all do. Which
tools keep it:

| Signer | Keeps it | How it is known |
| --- | --- | --- |
| `pp build`, `pp install` (the patched xtool 1.20.1) | yes | `pp verify` fails an IPA without it ([BUILDING.md, "Signing"](BUILDING.md#signing)) |
| stock xtool 1.20.1 | no, for a free team | [BUILDING.md, "Signing"](BUILDING.md#signing) |
| Xcode with a Personal Team | yes | reported in SideStore issue #1616; not tested here |
| AltStore Classic 2.2 and later | yes | its 2.2 release notes (April 2025); 2.3 reported in SideStore issue #1616; not tested here |
| SideStore 0.7.0 | no | SideStore issue #1616 (open, 2026-09-24): the App ID never gets the capability; GetMoreRam once, then a reinstall, should add it (the README's "SideStore: when Memory has no tick"; from source, not tested here) |
| Impactor (PlumeImpactor) | likely | its source asks for every capability the entitlements name; not tested here |
| any other re-signer | unknown | check the app's Settings, below |

So give a tester the IPA with section 5's build and install, or tell them to
install it with a signer marked yes. The README's "Install" section is the
player's version of this table, with the SideStore steps. The app shows what it
got:

- **The first-run checklist's Memory step** has a tick when the signature
  carries Increased Memory Limit. When it does not, A (**How to fix**) names
  the signers that keep it and the GetMoreRam step, and X (**Not now**) puts it
  off: smaller games still play.

- **Settings, Memory** shows the memory limit and whether the signature
  carries Increased Memory Limit (On or Off), with a warning when it is Off.
  The app log's first lines have the same, from before Game Mode:
  `memory: limit 6144 MB (footprint 3 MB), phone 11734 MB, increased-memory-limit yes`.
- **Play** is refused before any JIT is spent when the limit is below what a
  tested game reached on the reference phone (`memoryMB` in
  `app/PlayportKit/Titles/titles.json`), with an alert that says why
  ("Not enough memory for …") instead of iOS closing the game partway. When
  the limit is less than a quarter above that, or an untested game has under
  4 GB, the game's page warns under Play and the play goes on
  (PlayportKit `MemoryNeed`).
