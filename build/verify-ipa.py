#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify a signed app IPA (S1Probe.ipa) as an artefact, without a Mac or a device.

  pp verify IPA [--variant dev|release] [--sha256 HEX] [--same-device-as OLD.ipa] [--dxmt-pe DIR]
                [--notices DIR] [--distribution]
  pp verify IPA --variant release --unsigned [--sha256 HEX] [--notices DIR] [--distribution]
  pp verify --app S1Probe.app [--variant dev|release] [--dxmt-pe DIR] [--notices DIR] [--distribution]
                an unsigned `xtool dev build`: every check below except
                checksum, zip, signature and profile

--variant (default dev) is the build variant (docs/BUILDING.md, "Variants"):
S1Probe.app for dev, Playport.app for release.

Each check reads the unpacked IPA, not a build summary. It fails (exit 1) on
any mismatch:

  checksum      sha256 of the IPA equals --sha256 (when given)
  zip           entries stored, no symlinks, no case collisions
  executable    arm64 MH_EXECUTE, NOUNDEFS, LC_BUILD_VERSION iOS minos equal to
                Info.plist MinimumOSVersion, cryptid 0, every dylib from a
                system path
  signature     each code directory: every code page, and special slots 1, 2,
                3, 5, 7 (Info.plist, requirements, CodeResources, entitlements,
                DER entitlements); the entitlements carry increased-memory-limit; CodeResources files2 seals every bundle file
                and every hash matches; CMS verifies over the first code
                directory and its signer is the profile's certificate
  unsigned      with --unsigned (a release's IPA, decision 0038) in place of
                signature and profile: every bundle's code directories match
                (ad hoc), the executable's entitlements are only
                increased-memory-limit, no CMS signer, no
                embedded.mobileprovision anywhere, no XTL- team prefix in the
                bundle ID, and CodeResources seals every file
  profile       CMS-valid; dates; one provisioned device; entitlements the
                signature carries are all allowed by it; with --same-device-as,
                its device list equals that IPA's profile's (compared, never
                printed)
  resources     Runtime/ at the app root (or, up to 075123b6, in the resource
                bundle); the bundled artifacts.tsv equals the committed one;
                every `resource` row present with its size and sha256; no
                extras
  dxmt          the unix dispatch table linked into the executable has
                TABLE_SLOTS entries and upstream's handler for
                MTLDevice_newLibraryWithSource at slot 144, the bundled
                winemetal.dll exports it and d3d11.dll imports it and embeds
                dxmt_command.metal as source (its quoted includes inlined by
                the build); with --dxmt-pe, each bundled DXMT DLL is
                byte-identical to that build's
  host-io       the host I/O app pieces (docs/ARCHITECTURE.md):
                IOSDisplayShim's macdrv_functions and its five fallbacks in
                the export trie (DXMT finds them with dlsym, so a stripped
                one fails only at the first swap chain); the Winios input
                extensions, the audio host-suspend hook and the controller
                writers and snapshot linked in; GameController and AVFAudio
                linked; the bundled xinput DLLs are Wine's builtins (P2)
  wow64         i386 Runtime DLLs are Wine PE32 builtins, the aarch64
                wow64.dll, wow64win.dll and xtajit.dll are ARM64 PE32+
                builtins; xtajit exports FEX's WoW64 CPU interface.
                Build scaffolding only: does not claim 32-bit execution works.
  steamapi      the Steam API emulator (P8-steamapi): steam_api64.dll (x86-64)
                and steam_api.dll (i386) under Runtime/steamapi, native (not
                marked Wine builtins) and exporting SteamAPI_Init,
                SteamAPI_RunCallbacks and SteamInternal_CreateInterface
  steam         the native Steam client (app/SteamClient): SteamClientKit's
                Keychain store (SecItem* and the ThisDeviceOnly class) and its
                URLSessionWebSocketTask transport are linked, Security.framework
                is loaded, and nothing of the Linux host's transport or stores
                is in the executable (no libcurl, no cws_* or curl_* symbol,
                no SecretServiceStore); an executable from before the
                integration has no SteamClientKit and is only reported
  jit-helper    the JIT helper extension (docs/ARCHITECTURE.md, "Built-in
                JIT"): PlugIns/ holds only PlayportJIT.appex, declared under
                com.apple.ar.viewer with a FALSEPREDICATE rule and the
                PlayportJITHelper principal class, bundle ID <app>.PlayportJIT;
                its executable is arm64 MH_EXECUTE with code (__text) and
                links only system libraries and StikJIT; the embedded
                StikJIT binary is byte-identical to the staged release
                (build/stages/stikjit.sh) and the framework carries no
                universal.js or legacy.js; the extension carries
                playport-universal.js, byte-identical to
                app/PlayportJIT/playport-universal.js; signed: the extension's and the
                framework's code directories match their code and Info.plist,
                and the extension's profile names its own App ID
  paths         no file in the app names this machine's $HOME or the
                repository: the build maps the repository, the run trees and
                the toolchains out of every binary
  notices       Licenses/ at the app root is a whole `pp notices` output
                (build/notices-bundle.py): every file listed in SHA256SUMS and
                inventory.json, none missing, changed, unlisted or a symlink;
                with --notices, byte-identical to that output; its
                components.json (build/notices-app.py) covers every provenance
                key in the bundled artifacts.tsv. An app without
                Licenses/, whose Licenses/ is not an app selection, or whose
                inventory is not release-reviewed, is
                reported as not distributable; --distribution (for an IPA given
                to anyone, docs/DISTRIBUTION.md) makes either a failure
  icon          Info.plist's CFBundleIconFile is AppIcon-dev (dev) or AppIcon
                (release), and that PNG at the app root is byte-identical to
                app/Icon's
  variant       the executable is S1Probe (dev) or Playport (release). A
                release executable holds no dev code: no Dev/ type, no Swift
                symbol of the S1Probe module, none of the UI driver's or the
                scripted pad's environment names or files (S1_MODE, TITLE_NONCE,
                UI_ACTIONS, HIO_VPAD, s1-host.log, run-events.jsonl), and its
                Info.plist queries no URL scheme; it carries
                the quiet-runtime switch MADEIRA_NO_DIAGNOSTICS and its log,
                playport.log

Identifiers (team, profile, UDID, certificate subject) are not printed.
Needs: openssl, llvm-nm, llvm-objdump (host LLVM), and llvm-mingw's llvm-objdump
for the PE tables (MINGW, else LLVM_MINGW from pp setup).
"""

import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PKG = REPO / "app"
sys.path.insert(0, str(REPO / "build"))
import inputs  # noqa: E402
_spec = importlib.util.spec_from_file_location("notices_bundle", REPO / "build/notices-bundle.py")
notices_bundle = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(notices_bundle)
_spec = importlib.util.spec_from_file_location("notices_app", REPO / "build/notices-app.py")
notices_app = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(notices_app)
MSL_SHA256 = "78cc2261e4259f43dd1478c2055031b2446aa40acfb2e47187c464397274323a"  # dxmt_command.metal at the dxmt pin, includes inlined
SLOT = 144         # upstream DXMT's MTLDevice_newLibraryWithSource (139 was Playport's own slot before the upstream rebase)
TABLE_SLOTS = 150  # upstream's 0-145, then patches/dxmt-port's 146-149
failures = []
EXECUTABLE = {"dev": "S1Probe", "release": "Playport"}
# What only a dev build's code holds (Sources/S1Probe/Dev/).
DEV_MODULES = ["7S1Probe"]
DEV_TYPES = ["UIDriver", "VirtualPad", "RunEvents",
             "DeveloperSettings"]
DEV_STRINGS = [b"S1_MODE", b"TITLE_NONCE", b"UI_ACTIONS", b"UI_SETTINGS", b"HIO_VPAD", b"s1-host.log",
               b"run-events.jsonl", b"steam-drive.log"]
RELEASE_STRINGS = [b"MADEIRA_NO_DIAGNOSTICS", b"playport.log"]


def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        failures.append(what)


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def cms_content(der):
    return subprocess.run(["openssl", "cms", "-verify", "-noverify", "-inform", "DER"],
                          input=der, capture_output=True, check=True).stdout


def macho(path):
    d = path.read_bytes()
    magic, cpu, sub, ftype, ncmds, _, flags, _ = struct.unpack_from("<IiiIIIII", d, 0)
    m = dict(data=d, cpu=cpu, sub=sub & 0xffffff, ftype=ftype, flags=flags, dylibs=[], weak=0)
    assert magic == 0xfeedfacf
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, off)
        if cmd == 0x32:  # LC_BUILD_VERSION
            plat, minos, sdk = struct.unpack_from("<III", d, off + 8)
            m["build"] = (plat, minos, sdk)
        elif cmd == 0x2c:  # LC_ENCRYPTION_INFO_64
            m["cryptid"] = struct.unpack_from("<I", d, off + 16)[0]
        elif cmd in (0xc, 0x80000018):  # LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB
            name = d[off + struct.unpack_from("<I", d, off + 8)[0]:off + size].split(b"\0")[0].decode()
            m["dylibs"].append(name)
            m["weak"] += cmd != 0xc
        elif cmd == 0x1d:  # LC_CODE_SIGNATURE
            m["sig"] = struct.unpack_from("<II", d, off + 8)
        off += size
    return m


def ver(v):
    return "%d.%d" % (v >> 16, (v >> 8) & 0xff)


def signature(m):
    d = m["data"]
    so, ssz = m["sig"]
    sb = d[so:so + ssz]
    magic, length, count = struct.unpack_from(">III", sb, 0)
    assert magic == 0xfade0cc0
    blobs = {}
    for i in range(count):
        t, o = struct.unpack_from(">II", sb, 12 + 8 * i)
        blen = struct.unpack_from(">I", sb, o + 4)[0]
        blobs[t] = sb[o:o + blen]
    return so, blobs


def verify_cd(cd, code, specials):
    (magic, length, version, flags, hoff, ioff, nspecial, ncode, climit, hsize, htype, _,
     pgshift) = struct.unpack_from(">IIIIIIIIIBBBB", cd, 0)
    assert magic == 0xfade0c02
    h = {1: hashlib.sha1, 2: hashlib.sha256}[htype]
    ps = 1 << pgshift
    bad = sum(h(code[i * ps:min((i + 1) * ps, climit)]).digest()[:hsize] != cd[hoff + i * hsize:hoff + (i + 1) * hsize]
              for i in range(ncode))
    sbad = [k for k, v in specials.items() if k <= nspecial
            and h(v).digest()[:hsize] != cd[hoff - k * hsize:hoff - (k - 1) * hsize]]
    ident = cd[ioff:].split(b"\0")[0].decode()
    execflags = struct.unpack_from(">Q", cd, 0x50)[0] if version >= 0x20400 else None
    return dict(name=h().name, version=version, ncode=ncode, bad=bad, sbad=sbad, ident=ident,
                nspecial=nspecial, execflags=execflags, climit=climit)


def unix_table(exe):
    """Slot targets of dxmt_winemetal_unix_call_funcs, from the linked executable."""
    syms = {}
    for line in subprocess.run(["llvm-nm", "--defined-only", "-n", str(exe)], capture_output=True,
                               text=True, check=True).stdout.splitlines():
        p = line.split()
        if len(p) == 3:
            syms.setdefault(int(p[0], 16), []).append(p[2])
    names = {n: a for a, ns in syms.items() for n in ns}
    base = names["_dxmt_winemetal_unix_call_funcs"]
    after = min(a for a in syms if a > base)
    # chained-fixup rebases give each pointer's target
    out = subprocess.run(["llvm-objdump", "--macho", "--dyld-info", str(exe)], capture_output=True,
                         text=True, check=True).stdout
    target = {}
    for line in out.splitlines():
        mm = re.search(r"(0x[0-9A-F]+)\s+.*rebase.*?(0x[0-9A-F]+)", line, re.I)
        if mm:
            target[int(mm.group(1), 16)] = int(mm.group(2), 16)
    n = (after - base) // 8
    slots = [target.get(base + 8 * i) for i in range(n)]
    return n, slots, syms, names


def pe_table(path, kind):
    objdump = Path(os.environ.get("MINGW") or inputs.need("LLVM_MINGW")) / "bin/llvm-objdump"
    out = subprocess.run([str(objdump), "-p", str(path)], capture_output=True, text=True, check=True).stdout
    return set(re.findall(r"^\s+\S+\s+\S+\s+(\S+)$" if kind == "export" else r"^\s+\d+\s+(\S+)$", out, re.M))


def signed_checks(a, app, info, m, tmp):
    """Signature and profile: only an IPA from `xtool dev build --sign` has them."""
    so, blobs = signature(m)
    code = m["data"][:so]
    cr = (app / "_CodeSignature/CodeResources").read_bytes()
    specials = {1: (app / "Info.plist").read_bytes(), 2: blobs.get(2, b""), 3: cr,
                5: blobs.get(5, b""), 7: blobs.get(7, b"")}
    cds = [blobs[t] for t in sorted(blobs) if t == 0 or 0x1000 <= t < 0x1005]
    for cd in cds:
        r = verify_cd(cd, code, specials)
        check(r["bad"] == 0 and not r["sbad"] and r["climit"] == so,
              f"signature: {r['name']} code directory v{r['version']:#x}, {r['ncode']} code pages and special slots "
              f"1-{r['nspecial']} match; exec seg flags {r['execflags']:#x}")
        check(r["ident"] == info["CFBundleIdentifier"], "signature: identifier equals the bundle ID")
    ents = plistlib.loads(blobs[5][8:])
    print(f"      entitlements: {sorted(ents)}; get-task-allow {ents.get('get-task-allow')}")
    check(ents.get("com.apple.developer.kernel.increased-memory-limit") is True,
          "signature: carries increased-memory-limit (FEX's arena needs it; stock xtool drops it)")

    seal = plistlib.loads(cr)["files2"]
    allf = {str(p.relative_to(app)) for p in app.rglob("*") if p.is_file()}
    unsealed = allf - set(seal) - {"_CodeSignature/CodeResources", "Info.plist", info["CFBundleExecutable"]}
    badseal = [k for k, v in seal.items()
               if not (app / k).is_file() or hashlib.sha256((app / k).read_bytes()).digest() != v["hash2"]]
    check(not unsealed and not badseal, f"signature: CodeResources files2 {len(seal)} entries all match; every bundle file sealed")

    cms = blobs[0x10000][8:]
    (tmp / "cms.der").write_bytes(cms)
    (tmp / "cd0.bin").write_bytes(cds[0])
    r = subprocess.run(["openssl", "cms", "-verify", "-noverify", "-binary", "-inform", "DER", "-in", str(tmp / "cms.der"),
                        "-content", str(tmp / "cd0.bin"), "-signer", str(tmp / "signer.pem"), "-out", "/dev/null"],
                       capture_output=True, text=True)
    check(r.returncode == 0, "signature: CMS verifies over the first code directory")

    prof = plistlib.loads(cms_content((app / "embedded.mobileprovision").read_bytes()))
    dev_cert = prof["DeveloperCertificates"][0]
    signer = subprocess.run(["openssl", "x509", "-in", str(tmp / "signer.pem"), "-outform", "DER"],
                            capture_output=True).stdout
    check(signer == dev_cert, "signature: CMS signer is byte-identical to the profile's DeveloperCertificate")
    dates = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout", "-startdate", "-enddate"], input=dev_cert,
                           capture_output=True).stdout.decode().split("\n")
    print(f"      certificate {'; '.join(x for x in dates if x)}")
    devs = prof.get("ProvisionedDevices", [])
    print(f"      profile: created {prof['CreationDate']} UTC, expires {prof['ExpirationDate']} UTC, "
          f"{len(devs)} device(s), IsXcodeManaged {prof.get('IsXcodeManaged')}")
    check(len(devs) == 1, "profile: one provisioned device")
    allowed = prof["Entitlements"]

    def allows(k, v):
        if k not in allowed:
            return False
        p = allowed[k]
        if isinstance(p, list):
            vs = v if isinstance(v, list) else [v]
            return all(any(x == q or (isinstance(q, str) and q.endswith("*") and x.startswith(q[:-1])) for q in p) for x in vs)
        if isinstance(p, str) and p.endswith("*"):
            return isinstance(v, str) and v.startswith(p[:-1])
        return p == v
    check(all(allows(k, v) for k, v in ents.items()), "profile: allows every entitlement the signature carries")
    if a.same_device_as:
        oz = zipfile.ZipFile(a.same_device_as)
        op = next(n for n in oz.namelist() if n.endswith(".app/embedded.mobileprovision"))
        old = plistlib.loads(cms_content(oz.read(op)))
        check(old.get("ProvisionedDevices") == devs, f"profile: same provisioned device as {a.same_device_as.name}")



def unsigned_checks(app, info, m):
    """An ad hoc signature with entitlements and nothing of a team, profile or device
    (xtool dev build without --sign), for a recipient to re-sign (decision 0038)."""
    if "sig" not in m:
        check(False, "unsigned: the executable has an ad hoc signature (LC_CODE_SIGNATURE)")
        return
    so, blobs = signature(m)
    cr = app / "_CodeSignature/CodeResources"
    specials = {1: (app / "Info.plist").read_bytes(), 2: blobs.get(2, b""),
                3: cr.read_bytes() if cr.is_file() else b"", 5: blobs.get(5, b""), 7: blobs.get(7, b"")}
    rs = [verify_cd(blobs[t], m["data"][:so], specials) for t in sorted(blobs) if t == 0 or 0x1000 <= t < 0x1005]
    check(bool(rs) and all(r["bad"] == 0 and not r["sbad"] and r["climit"] == so for r in rs),
          f"unsigned: {len(rs)} ad hoc code directories match the executable's code pages and special slots")
    check(len(blobs.get(0x10000, b"")) <= 8, "unsigned: no CMS signature (no certificate)")
    ents = plistlib.loads(blobs[5][8:]) if 5 in blobs else {}
    print(f"      entitlements: {sorted(ents)}")
    check(ents == {"com.apple.developer.kernel.increased-memory-limit": True},
          "unsigned: the entitlements are increased-memory-limit only (a re-signer carries it over)")
    profiles = sorted(str(p.relative_to(app)) for p in app.rglob("embedded.mobileprovision"))
    check(not profiles, "unsigned: no embedded.mobileprovision" + (f" ({', '.join(profiles)})" if profiles else ""))
    check(not info["CFBundleIdentifier"].startswith("XTL-"), "unsigned: the bundle ID carries no team prefix")
    if cr.is_file():
        seal = plistlib.loads(cr.read_bytes())["files2"]
        allf = {str(p.relative_to(app)) for p in app.rglob("*") if p.is_file()}
        unsealed = allf - set(seal) - {"_CodeSignature/CodeResources", "Info.plist", info["CFBundleExecutable"]}
        badseal = [k for k, v in seal.items() if not (app / k).is_file()
                   or hashlib.sha256((app / k).read_bytes()).digest() != v.get("hash2")]
        check(not unsealed and not badseal, f"unsigned: CodeResources files2 {len(seal)} entries all match; every file sealed")
    else:
        check(False, "unsigned: _CodeSignature/CodeResources present")


def jit_helper_checks(app, info, signed, profile=True):
    plugins = sorted(p.name for p in (app / "PlugIns").iterdir()) if (app / "PlugIns").is_dir() else []
    check(plugins == ["PlayportJIT.appex"], f"jit-helper: PlugIns/ holds only PlayportJIT.appex ({plugins})")
    if plugins != ["PlayportJIT.appex"]:
        return
    ext = app / "PlugIns/PlayportJIT.appex"
    einfo = plistlib.loads((ext / "Info.plist").read_bytes())
    nse = einfo.get("NSExtension", {})
    check(nse.get("NSExtensionPointIdentifier") == "com.apple.ar.viewer"
          and nse.get("NSExtensionAttributes", {}).get("NSExtensionActivationRule") == "FALSEPREDICATE"
          and nse.get("NSExtensionPrincipalClass") == "PlayportJITHelper"
          and einfo.get("CFBundleIdentifier") == info["CFBundleIdentifier"] + ".PlayportJIT",
          "jit-helper: Info.plist declares com.apple.ar.viewer, FALSEPREDICATE, PlayportJITHelper, <app>.PlayportJIT")
    em = macho(ext / einfo["CFBundleExecutable"])
    text = subprocess.run(["llvm-objdump", "--macho", "--section-headers", str(ext / einfo["CFBundleExecutable"])],
                          capture_output=True, text=True, check=True).stdout
    check(em["cpu"] == 0x0100000c and em["ftype"] == 2 and re.search(r"\b__text\b", text) is not None,
          "jit-helper: executable is arm64 MH_EXECUTE with a __text section (the principal class is linked)")
    check(all(p.startswith(("/System/Library/", "/usr/lib/")) or p == "@rpath/StikJIT.framework/StikJIT"
              for p in em["dylibs"]) and "@rpath/StikJIT.framework/StikJIT" in em["dylibs"],
          f"jit-helper: executable links {len(em['dylibs'])} dylibs, system ones and @rpath/StikJIT.framework only")
    script = ext / "playport-universal.js"
    check(script.is_file() and script.read_bytes() == (PKG / "PlayportJIT/playport-universal.js").read_bytes(),
          "jit-helper: the extension's playport-universal.js is the committed app/PlayportJIT/playport-universal.js")
    fw = ext / "Frameworks/StikJIT.framework"
    bundled = sorted(p.name for p in fw.rglob("*") if p.name in ("universal.js", "legacy.js"))
    check(not bundled, f"jit-helper: the StikJIT framework carries none of StikJIT's scripts ({bundled})")
    staged = PKG / "Staged/StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT"
    if staged.exists():
        got, want = (fw / "StikJIT").read_bytes(), staged.read_bytes()
        # The signer adds LC_CODE_SIGNATURE after the load commands, grows
        # __LINKEDIT and appends the signature; everything after the load
        # commands, up to the release's length, is the release's.
        cmds_end = 32 + struct.unpack_from("<I", got, 20)[0]
        check(len(got) >= len(want) and got[cmds_end:len(want)] == want[cmds_end:],
              "jit-helper: embedded StikJIT binary is the staged release's past its load commands (build/stages/stikjit.sh)")
    if not signed:
        return
    for bundle, exe_name in ((ext, einfo["CFBundleExecutable"]), (fw, "StikJIT")):
        bm = macho(bundle / exe_name)
        so, blobs = signature(bm)
        cr = bundle / "_CodeSignature/CodeResources"
        specials = {1: (bundle / "Info.plist").read_bytes(), 2: blobs.get(2, b""),
                    3: cr.read_bytes() if cr.exists() else b"", 5: blobs.get(5, b""), 7: blobs.get(7, b"")}
        rs = [verify_cd(blobs[t], bm["data"][:so], specials) for t in sorted(blobs) if t == 0 or 0x1000 <= t < 0x1005]
        check(rs and all(r["bad"] == 0 and not r["sbad"] and r["climit"] == so for r in rs),
              f"jit-helper: {bundle.name} code directories match its code pages and special slots")
    if not profile:
        return
    prof = plistlib.loads(cms_content((ext / "embedded.mobileprovision").read_bytes()))
    check(prof["Entitlements"].get("application-identifier", "").endswith("." + einfo["CFBundleIdentifier"]),
          "jit-helper: the extension's profile names its own App ID")


HOST_IO_EXPORTS = ["_macdrv_functions", "_get_win_data", "_release_win_data", "_macdrv_view_create_metal_view",
                   "_macdrv_view_get_metal_layer", "_macdrv_view_release_metal_view"]
HOST_IO_DEFINED = ["_madeira_display_set_layer", "_winios_post_client_pointer", "_winios_post_focus",
                   "_ios_audio_host_suspend", "_winemetal_host_gpu_gate", "_host_pad_set",
                   "_winios_gamepad_set_state", "_winios_gamepad_get_state", "_ios_gamepad_query",
                   "_audio_null_ios_unix_call_funcs"]


def workstation_path_checks(app):
    """This machine's home and repository, which the build maps out of every binary
    (build/ld64/swift-build, build/stages/unix.sh, wine-pe.sh, fex.sh, dxmt-*.sh).
    Prebuilt parts carry their own CI runners' home paths (StikJIT, llvm-mingw's
    libc++abi): not ours, not checked."""
    paths = [os.fsencode(str(p)) + b"/" for p in (Path.home(), REPO) if str(p) not in ("/", "")]
    paths = [w for w in paths if not any(w != v and w.startswith(v) for v in paths)]   # the repo is usually in $HOME
    found = {}
    for p in sorted(app.rglob("*")):
        if p.is_file() and not p.is_symlink():
            d = p.read_bytes()
            n = sum(d.count(w) for w in paths)
            if n:
                found[str(p.relative_to(app))] = n
    worst = ", ".join(f"{f} ({n})" for f, n in sorted(found.items(), key=lambda x: -x[1])[:5])
    check(not found, "paths: no file names this machine's home or the repository"
          + (f"; {len(found)} files do: {worst}" if found else ""))


def steamapi_checks(rt, rows):
    """The Steam API emulator (P8-steamapi): a native DLL per game architecture that
    exports what a game calls; not a Wine builtin, which a game folder's DLL must not be."""
    want = {"Runtime/steamapi/x86_64-windows/steam_api64.dll": 0x8664, "Runtime/steamapi/i386-windows/steam_api.dll": 0x14c}
    got = {r[1] for r in rows if r[0] == "resource" and r[6] == "P8-steamapi"}
    if not got:
        print("      steamapi: no P8-steamapi rows (an IPA from before the Steam API emulator)")
        return
    check(got == set(want), f"steamapi: rows are {', '.join(sorted(want))}")
    for k, machine in want.items():
        body = rt(k).read_bytes()
        pe = int.from_bytes(body[0x3c:0x40], "little")
        ok = body[pe:pe + 4] == b"PE\0\0" and int.from_bytes(body[pe + 4:pe + 6], "little") == machine
        ex = pe_table(rt(k), "export")
        check(ok and b"Wine builtin DLL" not in body[:0x200]
              and {"SteamAPI_Init", "SteamAPI_RunCallbacks", "SteamInternal_CreateInterface"} <= ex,
              f"steamapi: {k.split('/')[-1]} is a native {machine:#x} DLL exporting SteamAPI_Init, "
              "SteamAPI_RunCallbacks and SteamInternal_CreateInterface")


def pe_machine_magic(body):
    """COFF machine and optional-header magic, or None for a malformed PE."""
    if len(body) < 0x40 or body[:2] != b"MZ":
        return None
    pe = int.from_bytes(body[0x3c:0x40], "little")
    if pe < 0x40 or pe + 26 > len(body) or body[pe:pe + 4] != b"PE\0\0":
        return None
    return (int.from_bytes(body[pe + 4:pe + 6], "little"),
            int.from_bytes(body[pe + 24:pe + 26], "little"))


def wow64_checks(rt, rows):
    """Build scaffolding, not evidence that the WoW64 iOS port can run."""
    guest = [r[1] for r in rows if r[0] == "resource" and r[1].startswith("Runtime/i386-windows/")]
    check({"Runtime/i386-windows/ntdll.dll", "Runtime/i386-windows/kernel32.dll"} <= set(guest),
          "wow64: i386 ntdll.dll and kernel32.dll bundled")
    bad = []
    for name in guest:
        body = rt(name).read_bytes() if rt(name).is_file() else b""
        if pe_machine_magic(body) != (0x14c, 0x10b) or b"Wine builtin DLL" not in body[:0x200]:
            bad.append(name)
    check(bool(guest) and not bad, f"wow64: {len(guest)} i386 DLLs/drivers are PE32 Wine builtins"
          + (f" (bad: {', '.join(bad)})" if bad else ""))
    for name in ("wow64.dll", "wow64win.dll", "xtajit.dll"):
        path = rt(f"Runtime/aarch64-windows/{name}")
        body = path.read_bytes() if path.is_file() else b""
        check(pe_machine_magic(body) == (0xaa64, 0x20b) and b"Wine builtin DLL" in body[:0x200],
              f"wow64: aarch64 {name} is a PE32+ ARM64 Wine builtin")
        if name == "xtajit.dll" and path.is_file():
            check({"BTCpuProcessInit", "BTCpuThreadInit", "BTCpuSimulate"} <= pe_table(path, "export"),
                  "wow64: xtajit.dll exports BTCpuProcessInit, BTCpuThreadInit and BTCpuSimulate")


def host_io_checks(exe, rt, rows):
    """The host I/O app pieces (docs/ARCHITECTURE.md)."""
    trie = subprocess.run(["llvm-objdump", "--macho", "--exports-trie", str(exe)], capture_output=True,
                          text=True, check=True).stdout
    exported = set(re.findall(r"^\S+\s+(\S+)", trie, re.M))
    check(all(n in exported for n in HOST_IO_EXPORTS),
          "host-io: IOSDisplayShim's macdrv_functions and its 5 fallbacks are in the export trie (DXMT's dlsym finds them)")
    defined = {l.split()[-1] for l in subprocess.run(["llvm-nm", "--defined-only", str(exe)], capture_output=True,
                                                     text=True, check=True).stdout.splitlines() if l.strip()}
    missing = [n for n in HOST_IO_DEFINED if n not in defined]
    check(not missing, "host-io: display shim, Winios input and focus, audio host-suspend and controller block linked"
          + (f" (missing {', '.join(missing)})" if missing else ""))
    dylibs = subprocess.run(["llvm-objdump", "--macho", "--dylibs-used", str(exe)], capture_output=True,
                            text=True, check=True).stdout
    check("GameController.framework" in dylibs and "AVFAudio.framework" in dylibs,
          "host-io: GameController and AVFAudio linked")
    reg = rt("Runtime/registry/system.reg").read_bytes()
    check("_prefix_registry_seed" in defined
          and b"[Software\\\\Classes\\\\CLSID\\\\{BCDE0395-E52F-467C-8E3D-C4579291692E}\\\\InprocServer32]" in reg,
          "host-io: the prefix registry seed is linked and bundled, with the audio path's MMDeviceEnumerator class")
    # Wine's own XInput reads the controller snapshot (WiniosGamepad.c) through
    # win32u; the snapshot and its readers are the HOST_IO_DEFINED symbols above.
    xin = [r for r in rows if r[0] == "resource" and "/xinput" in r[1]]
    builtin = [r[1] for r in xin if b"Wine builtin DLL" in rt(r[1]).read_bytes()[:0x200]]
    check(xin and all(r[6] == "P2" for r in xin) and len(builtin) == len(xin),
          f"host-io: the {len(xin)} bundled xinput DLLs are Wine's builtins (P2)")


def release_checks(exe, info):
    """A release executable carries no dev code (docs/BUILDING.md, "Variants")."""
    check("LSApplicationQueriesSchemes" not in info, "variant: Info.plist queries no other app's URL scheme")
    syms = [l.split()[-1] for l in subprocess.run(["llvm-nm", str(exe)], capture_output=True,
                                                  text=True, check=True).stdout.splitlines() if l.strip()]
    # Swift mangles a type as <len><name> after its module's <len><name>.
    found = sorted({d for d in DEV_MODULES for n in syms if d in n}
                   | {t for t in DEV_TYPES for n in syms if "8Playport" in n and f"{len(t)}{t}" in n})
    check(not found, "variant: no dev code linked (Dev/, the S1Probe module)"
          + (f" (found {', '.join(found)})" if found else ""))
    body = exe.read_bytes()
    found = [d.decode() for d in DEV_STRINGS if d in body]
    check(not found, "variant: none of the dev code's environment names or files" + (f" (found {', '.join(found)})" if found else ""))
    missing = [d.decode() for d in RELEASE_STRINGS if d not in body]
    check(not missing, "variant: the quiet-runtime switch and playport.log are in the executable"
          + (f" (missing {', '.join(missing)})" if missing else ""))


def icon_checks(app, info, variant):
    """The home-screen icon: xtool.yml's iconPath, copied to the app root (app/Icon)."""
    name = "AppIcon-dev" if variant == "dev" else "AppIcon"
    got, src = app / f"{name}.png", PKG / "Icon" / f"{name}.png"
    check(info.get("CFBundleIconFile") == name and got.is_file() and src.is_file()
          and got.read_bytes() == src.read_bytes(),
          f"icon: CFBundleIconFile {name}, {name}.png equal to app/Icon's"
          + ("" if info.get("CFBundleIconFile") == name else f" (Info.plist names {info.get('CFBundleIconFile')})"))


def notice_checks(app, notices=None, distribution=False, artifacts=None):
    """Licenses/, the collected notices (build/notices-bundle.py). Its absence or an
    incomplete inventory fails only a distribution: no complete one exists yet."""
    d = app / "Licenses"
    if not d.exists() and not d.is_symlink():
        if distribution or notices:
            check(False, "notices: Licenses/ bundled")
        else:
            print("      notices: no Licenses/ (not distributable)")
        return
    try:
        r = notices_bundle.check(d)
        want = notices_bundle.read_sums(Path(notices)) if notices and notices_bundle.check(notices) else None
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        check(False, f"notices: Licenses/ and --notices are whole notice bundles ({exc})")
        return
    check(True, f"notices: Licenses/ holds {r['files']} files ({r['bytes']:,} B), every one listed and matching")
    if want is not None:
        check(notices_bundle.read_sums(d) == want, f"notices: Licenses/ is byte-identical to {Path(notices).name}")
    components = d / "components.json"
    if components.is_file():
        try:
            listed = json.loads(components.read_text(encoding="utf-8"))["components"]
            covered = {k for c in listed for k in c["covers"]}
        except (ValueError, KeyError, TypeError):
            covered = None
        missing = sorted(notices_app.artifact_keys(artifacts or "") - (covered or set()))
        check(covered is not None and not missing,
              "notices: components.json has a component for every provenance key in artifacts.tsv"
              + (f" (not: {', '.join(missing)})" if missing else ""))
    elif distribution:
        check(False, "notices: Licenses/ is an app selection (components.json; build/notices-app.py)")
    ready = r["status"] == notices_bundle.RELEASE_STATUS
    if distribution or ready:
        check(ready, f"notices: inventory status {r['status']} is {notices_bundle.RELEASE_STATUS}")
    else:
        print(f"      notices: inventory status {r['status']} (not distributable)")


STEAM_IMPORTS = ["_SecItemAdd", "_SecItemCopyMatching", "_SecItemUpdate", "_SecItemDelete",
                 "_kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", "_kSecAttrSynchronizable"]


def steam_checks(exe):
    """The native Steam client's two Apple seams (app/SteamClient/README.md)."""
    syms = [l.split()[-1] for l in subprocess.run(["llvm-nm", str(exe)], capture_output=True,
                                                  text=True, check=True).stdout.splitlines() if l.strip()]
    if not any("SteamClientKit" in n for n in syms):
        print("      steam: SteamClientKit not linked (an executable from before the app integration)")
        return
    undefined = {l.split()[-1] for l in subprocess.run(["llvm-nm", "--undefined-only", str(exe)], capture_output=True,
                                                       text=True, check=True).stdout.splitlines() if l.strip()}
    missing = [n for n in STEAM_IMPORTS if n not in undefined]
    check(not missing, "steam: Keychain store linked (SecItem add/copy/update/delete, AfterFirstUnlockThisDeviceOnly, synchronizable)"
          + (f" (missing {', '.join(missing)})" if missing else ""))
    ws = [n for n in undefined if "NSURLSessionWebSocketTask" in n]
    check(any("7receive" in n for n in ws) and any("4send" in n for n in ws),
          "steam: CM transport is URLSessionWebSocketTask (whole-message receive and send imported from Foundation)")
    dylibs = subprocess.run(["llvm-objdump", "--macho", "--dylibs-used", str(exe)], capture_output=True,
                            text=True, check=True).stdout
    linux = [n for n in syms if n.startswith(("_cws_", "_curl_")) or "SecretServiceStore" in n]
    check("Security.framework" in dylibs and "libcurl" not in dylibs and not linux,
          "steam: Security.framework loaded; no libcurl, CCurlWS or Secret Service code in the executable"
          + (f" (found {', '.join(sorted(set(linux))[:5])})" if linux else ""))


def main():
    ap = argparse.ArgumentParser(prog="pp verify", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ipa", type=Path, nargs="?")
    ap.add_argument("--app", type=Path, help="an unpacked, unsigned .app instead of an IPA")
    ap.add_argument("--sha256")
    ap.add_argument("--same-device-as", type=Path)
    ap.add_argument("--dxmt-pe", type=Path)
    ap.add_argument("--variant", choices=sorted(EXECUTABLE), default="dev")
    ap.add_argument("--unsigned", action="store_true",
                    help="a release's ad hoc signed IPA with no profile (pp build --unsigned)")
    ap.add_argument("--notices", type=Path, help="the `pp notices` output Licenses/ must equal")
    ap.add_argument("--distribution", action="store_true",
                    help="fail an app without release-reviewed notices (an IPA for anyone else)")
    a = ap.parse_args()
    if bool(a.ipa) == bool(a.app):
        ap.error("give an IPA or --app, not both")
    if a.unsigned and (a.app or a.variant != "release" or a.same_device_as):
        ap.error("--unsigned checks a release IPA, without --app or --same-device-as")

    # An IPA unpacks to ~650 MB: unpack it in the build area, not /tmp.
    tmpdir = os.environ.get("TMPDIR") or os.path.join(
        os.environ.get("PLAYPORT_BUILD") or str(REPO / ".work"), "tmp")
    os.makedirs(tmpdir, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="verify-ipa-", dir=tmpdir))
    try:
        if a.app:
            app = a.app
            print(f"APP   {app} (unsigned: checksum, zip, signature and profile checks skipped)")
        else:
            raw = a.ipa.read_bytes()
            digest = sha256(raw)
            print(f"IPA   {a.ipa.name} {len(raw):,} B sha256 {digest}")
            if a.sha256:
                check(digest == a.sha256, "checksum equals the recorded value")
            z = zipfile.ZipFile(a.ipa)
            infos = z.infolist()
            files = [i for i in infos if not i.is_dir()]
            check(all(i.compress_type == zipfile.ZIP_STORED for i in infos), f"zip: {len(infos)} entries ({len(files)} files), all stored")
            check(not any((i.external_attr >> 16) & 0o170000 == 0o120000 for i in infos), "zip: no symlinks")
            low = [i.filename.lower() for i in infos]
            check(len(set(low)) == len(low), "zip: no case collisions")
            z.extractall(tmp)
            app = next((tmp / "Payload").glob("*.app"))
        info = plistlib.loads((app / "Info.plist").read_bytes())
        exe = app / info["CFBundleExecutable"]
        check(info["CFBundleExecutable"] == EXECUTABLE[a.variant] and app.name == EXECUTABLE[a.variant] + ".app",
              f"variant: {a.variant} executable {info['CFBundleExecutable']} in {app.name}")

        m = macho(exe)
        check(m["cpu"] == 0x0100000c and m["ftype"] == 2, "executable: arm64 MH_EXECUTE")
        check(m["flags"] & 1 == 1, "executable: NOUNDEFS")
        plat, minos, sdk = m["build"]
        check(plat == 2 and ver(minos) == info.get("MinimumOSVersion"), f"executable: platform iOS, minos {ver(minos)} (sdk {ver(sdk)}); Info.plist MinimumOSVersion {info.get('MinimumOSVersion')}")
        check(m.get("cryptid", 0) == 0, "executable: cryptid 0")
        sysp = ("/System/Library/", "/usr/lib/")
        # KosmicKrisp, the Vulkan backend's driver (decision 0014), is the one
        # embedded framework: win32u dlopens it by its install name.
        embedded = ["@rpath/KosmicKrisp.framework/KosmicKrisp"]
        check(all(p.startswith(sysp) or p in embedded for p in m["dylibs"]),
              f"executable: {len(m['dylibs'])} dylibs ({m['weak']} weak), from system paths or {embedded}")
        fws = sorted(p.name for p in (app / "Frameworks").iterdir()) if (app / "Frameworks").exists() else []
        check(fws == ["KosmicKrisp.framework"], f"bundle: Frameworks/ holds KosmicKrisp.framework only ({fws})")
        kk = app / "Frameworks/KosmicKrisp.framework/KosmicKrisp"
        if kk.exists():
            km = macho(kk)
            check(km["cpu"] == 0x0100000c and km["ftype"] == 6 and km["build"][0] == 2,
                  "KosmicKrisp: arm64 MH_DYLIB for iOS")
            # The signer adds a code signature (and its load command) to the
            # staged binary, after padding it to 16 bytes; compare the code
            # and data pages before it.
            staged = PKG / "Staged/KosmicKrisp.xcframework/ios-arm64/KosmicKrisp.framework/KosmicKrisp"
            n = km["sig"][0] if "sig" in km else len(km["data"])
            sd = staged.read_bytes() if staged.exists() else b""
            pad = km["data"][len(sd):n]
            check(len(sd) > 4096 and len(pad) < 16 and not pad.strip(b"\0")
                  and sd[4096:n] == km["data"][4096:min(n, len(sd))],
                  "KosmicKrisp: the embedded driver is the staged build past its load commands (build/stages/mesa.sh)")
            check("sig" in km, "KosmicKrisp: signed")
        # Without it UIKit hands a mouse to the app as finger touches and GCMouse
        # delivers nothing (2026-09-23). The reference app sets it.
        check(info.get("UIApplicationSupportsIndirectInputEvents") is True,
              "Info.plist: UIApplicationSupportsIndirectInputEvents (mouse through GCMouse, not as touches)")
        print(f"      bundle id {re.sub(r'^XTL-[A-Z0-9]+', 'XTL-TEAMIDXXXX', info['CFBundleIdentifier'])}, "
              f"version {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')}), "
              f"display name {info.get('CFBundleDisplayName')}")

        if a.unsigned:
            unsigned_checks(app, info, m)
        elif not a.app:
            signed_checks(a, app, info, m, tmp)

        # Runtime/ ships at the app root (xtool.yml resources); IPAs up to 075123b6
        # carried it in the SwiftPM resource bundle. A row's Runtime/x is base/x.
        if (app / "artifacts.tsv").exists():
            base, where, dirs = app, "app root", ["arm64ec-windows", "aarch64-windows", "nls", "registry", "vulkan",
                                                  "steamapi", "i386-windows"]
            check(not any(b.joinpath("Runtime").exists() for b in app.glob("*.bundle")),
                  "resources: Runtime/ at the app root only, not also in a resource bundle")
        else:
            base = next(app.glob("*.bundle")) / "Runtime"
            where, dirs = "resource bundle", ["."]
        print(f"      runtime layout: {where}")

        def rt(k):
            return base / k.removeprefix("Runtime/")

        tsv = rt("Runtime/artifacts.tsv").read_bytes()
        committed = (PKG / "artifacts.tsv").read_text()
        check(tsv.decode() == committed, "resources: bundled artifacts.tsv equals the committed one")
        rows = [l.split("\t") for l in tsv.decode().splitlines() if l and not l.startswith("#")]
        res = {r[1]: (int(r[2]), r[3]) for r in rows if r[0] == "resource"}
        got = {"Runtime/" + str(p.relative_to(base)) for d in dirs for p in (base / d).rglob("*") if p.is_file()} \
            - {"Runtime/artifacts.tsv"}
        miss = [k for k, (n, h) in res.items() if not rt(k).is_file() or rt(k).stat().st_size != n
                or sha256(rt(k).read_bytes()) != h]
        check(not miss and got == set(res), f"resources: all {len(res)} rows match, no extras; gaps absent: "
              f"{sum(r[0] == 'gap' and not rt(r[1]).exists() for r in rows)}/{sum(r[0] == 'gap' for r in rows)}")
        empty = [p for p in app.rglob("*") if p.is_dir() and not any(p.iterdir())]
        check(not empty, "resources: no empty directories")

        # DXMT: both halves from the patched fork
        n, slots, syms, names = unix_table(exe)
        h = names.get("__MTLDevice_newLibraryWithSource")
        print(f"      unix table: {n} slots; slot {SLOT} -> {slots[SLOT] and hex(slots[SLOT])} "
              f"({', '.join(syms.get(slots[SLOT], ['?'])) if slots[SLOT] else '-'})" if n > SLOT else f"      unix table: {n} slots")
        check(n == TABLE_SLOTS and h is not None and slots[SLOT] == h,
              f"dxmt: linked unix table has {TABLE_SLOTS} slots and slot {SLOT} is _MTLDevice_newLibraryWithSource")
        for arch in ("arm64ec", "aarch64"):
            d = rt(f"Runtime/{arch}-windows")
            if not (d / "d3d11.dll").exists():
                check(False, f"dxmt: {arch} d3d11.dll bundled")
                continue
            ex = pe_table(d / "winemetal.dll", "export")
            im = pe_table(d / "d3d11.dll", "import")
            body = (d / "d3d11.dll").read_bytes()
            check("MTLDevice_newLibraryWithSource" in ex and "MTLDevice_newLibraryWithSource" in im,
                  f"dxmt: {arch} winemetal.dll exports and d3d11.dll imports MTLDevice_newLibraryWithSource")
            check(b"MTLB\x01\x80" not in body, f"dxmt: {arch} d3d11.dll holds no metallib container")
            if a.dxmt_pe:
                src = a.dxmt_pe.parent / f"build-{arch}/src/dxmt/dxmt_command.metal"
                msl = src.read_bytes()
                check(sha256(msl) == MSL_SHA256 and body.count(msl) == 1,
                      f"dxmt: {arch} d3d11.dll embeds the pin's dxmt_command.metal (includes inlined) once")
        if a.dxmt_pe:
            for r in rows:
                if r[0] == "resource" and r[6] == "P5-dxmt-pe":
                    same = (a.dxmt_pe / r[5]).read_bytes() == rt(r[1]).read_bytes()
                    check(same, f"dxmt: bundled {r[1]} is byte-identical to the patched build's {r[5]}")
        host_io_checks(exe, rt, rows)
        steamapi_checks(rt, rows)
        wow64_checks(rt, rows)
        steam_checks(exe)
        workstation_path_checks(app)
        jit_helper_checks(app, info, not a.app, profile=not a.unsigned)
        notice_checks(app, a.notices, a.distribution, tsv.decode())
        icon_checks(app, info, a.variant)
        if a.variant == "release":
            release_checks(exe, info)
    finally:
        shutil.rmtree(tmp)
    print("\n%d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
