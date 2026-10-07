# Evidence: the guest's trusted roots (PLA-40)

**Date:** 2026-10-07. **IPA:** `Playport-26.5-afe0403c.ipa` (dev), sha256
`afe0403cf4e865413244e180bd51a846f11ec36eb503f7e40fd2dcf6351684c0`, built from the change
committed with this record: madeira-unix 0088 (crypt32's root list walked for every Wine
process of a session), `wine_host.c` naming `Runtime/certs/cacert.pem` in
`MADEIRA_CA_BUNDLE`, and the bundle itself, Mozilla's root store as published in curl's
CA extract of 2026-09-25 (121 roots, sha256 `a41b5d35…0505`), a locked input
(pins.lock `ca-bundle`, `build/stages/ca-bundle.sh`). Phone: iPhone18,4, iOS 27.0, Wi-Fi.
Epic signed in with the owner's account. Run directories are under
`$PLAYPORT_BUILD/ui-runs/`; screenshots stay there.

## Before

Step 1 of the store sign-in plan ([evidence](2026-10-07-epic-game-auth.md)): Snakebird
Complete's `Player.log` showed `Curl error 60: Cert verify failed. Certificate is not
correctly signed by a trusted CA. UnityTls error code: 7` (four times) and then
`Tried to login auth: NoConnection` from its EOS client; `s1-host.log` had
`load_root_certs: MADEIRA_CA_BUNDLE=(NULL!)` and `0 root certs imported`. The host never
set the variable and the IPA carried no bundle, so the prefix's ROOT store held Wine's six
built-in roots only.

## Snakebird Complete (`epic-8337d1f975514d35ad0c1176e8a29f26`)

`pp ui --play epic-8337d1f975514d35ad0c1176e8a29f26 --until first-frame+30 --shot`
(`20261007T133928`): exchange code fetched in 0.40 s, JIT 2.71 s, game +3.14 s, first frame
+5.04 s, the title menu (Start, Settings, Credits, Quit) in the screenshot. Pool head 188 MiB
of 512, 90 images. `pull/s1-host.log`:

    [wine_host] trusted roots: …/S1Probe.app/certs/cacert.pem
    [crypt32-ios] load_root_certs: MADEIRA_CA_BUNDLE=…/S1Probe.app/certs/cacert.pem
    [crypt32-ios] load_root_certs: 121 root certs imported

The game's `Player.log` (pulled after the run) has no `Curl error 60` and no
`NoConnection`. The prefix's `system.reg`, pulled after it, holds 126 keys under
`Software\\Microsoft\\SystemCertificates\\Root\\Certificates` (6 before), including GTS
Root R4 (`77D30367…4D47`, api.epicgames.dev), Amazon Root CA 1 (`8DA7F965…DE16`) and
Starfield Services G2 (`925A8F8D…3F3F`).

**EOS did not sign in.** Its log line is now `Tried to login auth: UnexpectedError` (was
`NoConnection`). The certificate refusal is gone, but no EOS sign-in has been shown yet:
the SDK logs nothing more through the game, and `s1-host.log` has no crypt32, schannel,
winhttp or socket error around it. This is open (see the plan's PLA-40 note).

## Hollow Knight (`app-367520`), regression

`pp ui --play app-367520 --until first-frame+10 --shot` (`20261007T134042`): JIT 2.58 s,
game +3.57 s, first frame +9.67 s, the menu as before; pool head 138 MiB.

## Host checks

`pp test --quick` passes, with `tools/tests/test_ca_bundle.py` (the pin's date, the stage
script's sha256 and the source catalogue's entry agree; the bundle is packaged in both
variants, checked by `pp verify` and covered by a notice component). `pp verify`: 80 checks
passed; the IPA's `certs/cacert.pem` matches its `artifacts.tsv` row.
