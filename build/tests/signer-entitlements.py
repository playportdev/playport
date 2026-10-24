# SPDX-License-Identifier: GPL-3.0-or-later
"""macOS integration test; synthetic Mach-O bundles, no developer credentials.

UV_CACHE_DIR=.work/uv-cache uv run --no-project python build/tests/signer-entitlements.py
"""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

REPO = Path(__file__).resolve().parents[2]
WORK = REPO / ".work/signer-tests"
ROOT = REPO / ".work/inputs/xtool-src"


def run(args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    temporary = WORK / "tmp"
    temporary.mkdir(exist_ok=True)
    os.environ["TMPDIR"] = str(temporary)
    release = next((ROOT / ".build").glob("*-apple-macosx/release"))
    source = ROOT / ".build/checkouts/zsign/src"
    support = ROOT / ".build/checkouts/xtool-core/Sources/SignerSupport/include"
    framework = ROOT / ".build/artifacts/xtool-core/OpenSSL/OpenSSL.xcframework/macos-arm64_x86_64"
    compiler = run(["xcrun", "--find", "clang++"]).strip()
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
    # SwiftPM may retain obsolete .o files after a dependency update. Link the
    # exact members used by the built tool, never every file in its directory.
    objects = [Path(line) for line in (release / "xtool.product/Objects.LinkFileList").read_text().splitlines()
               if "/Zupersign.build/" in line or "/SignerSupport.build/" in line]
    assert objects
    harness = WORK / "signer-test"
    run([compiler, "-isysroot", sdk, "-std=c++11", REPO / "build/tests/signer-entitlements.cpp", *objects,
         "-I", source, "-I", source / "common", "-I", source / "include", "-I", support,
         "-I", framework / "OpenSSL.framework/Headers", "-F", framework,
         "-Xlinker", "-rpath", "-Xlinker", framework,
         "-framework", "OpenSSL", "-framework", "Security", "-framework", "CoreFoundation", "-lz", "-o", harness])
    stub = WORK / "stub.c"
    stub.write_text("int main(void) { return 0; }\n")
    executable = WORK / "stub"
    run([compiler, "-isysroot", sdk, "-x", "c", stub, "-o", executable])
    dylib = WORK / "stub.dylib"
    run([compiler, "-isysroot", sdk, "-x", "c", "-dynamiclib", stub, "-o", dylib])
    spec = importlib.util.spec_from_file_location("verify_signer", REPO / "build/verify-ipa.py")
    verify = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verify)
    identities = ["TEST.main", "TEST.helper"]
    entitlements = []
    for identity in identities:
        path = WORK / (identity + ".plist")
        path.write_bytes(plistlib.dumps({"application-identifier": identity,
                                        "keychain-access-groups": [identity]}))
        entitlements.append(path)
    for mode in ("forward", "reverse", "missing-root", "missing-helper"):
        app = WORK / mode / "Fixture.app"
        for bundle, name, package, binary in ((app, "Main", "APPL", executable),
                (app / "PlugIns/Helper.appex", "Helper", "XPC!", executable),
                (app / "Frameworks/Fixture.framework", "Fixture", "FMWK", dylib)):
            bundle.mkdir(parents=True, exist_ok=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": name,
                "CFBundleIdentifier": "test." + name, "CFBundlePackageType": package, "CFBundleVersion": "1"}))
            shutil.copyfile(binary, bundle / name)
        run([harness, app, mode, *entitlements])
        if mode.startswith("missing"):
            continue
        for binary, expected in ((app / "Main", identities[0]), (app / "PlugIns/Helper.appex/Helper", identities[1])):
            _, blobs = verify.signature(verify.macho(binary))
            signed = plistlib.loads(blobs[5][8:])
            assert signed["application-identifier"] == expected
            assert signed["keychain-access-groups"] == [expected]
        _, blobs = verify.signature(verify.macho(app / "Frameworks/Fixture.framework/Fixture"))
        signed = plistlib.loads(blobs[5][8:]) if 5 in blobs else {}
        assert not signed.get("application-identifier") and not signed.get("keychain-access-groups")
    print("signer: mapping order, distinct identities, empty framework rights, missing mappings: PASS")


if __name__ == "__main__":
    main()
