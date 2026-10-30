# SPDX-License-Identifier: GPL-3.0-or-later
"""What `pp test` and `pp sync` both check, in one place: the secret patterns,
the Swift packages, and the shape of the patch series (AGENTS.md, Rules)."""

import os
import re
import subprocess

# The app's Swift packages with host tests.
SWIFT_PACKAGES = ["app/HostIOKit", "app/ContentKit", "app/GOGClient", "app/EpicClient", "app/XboxClient", "app/SteamClient", "app/PlayportKit"]

# What must never be committed (AGENTS.md, Secrets): (what, pattern). Each
# pattern is both a `git grep -E` and a Python regular expression.
SECRETS = [
    # Steam's refresh and access tokens (JWTs) and Xbox's device, user, title and XSTS tokens
    # (five-part JWEs).
    ("JWT or JWE token (Steam, Xbox)", r"ey[AJ][A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
    ("SteamID64", r"\b7656119[0-9]{10}\b"),
    ("bearer header", r"[Aa]uthorization: *[Bb]earer|[Bb]earer [A-Za-z0-9._-]{20,}"),
    ("private key", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("device identifier key", r'"(crashReporterKey|deviceIdentifierForVendor|bootSessionUUID|UniqueDeviceID|'
                              r'SerialNumber|UniqueChipID|EthernetMacAddress)"'),
    ("container UUID", r"/var/mobile/Containers/(Data|Shared)/[A-Za-z]+/[0-9A-F-]{36}"),
    ("team ID in a bundle ID", r"XTL-[A-Z0-9]{10}\."),
    # The repository names no path outside itself (build/inputs.py): write repo-relative
    # paths, or $PLAYPORT_BUILD, $LLVM_MINGW, $DARWIN_SDK, ~.
    ("a workstation's home path", r"/home/[A-Za-z_][A-Za-z0-9._-]*/|/Users/[A-Za-z][A-Za-z0-9._-]*/"),
    # gbe_fork's configs.user.ini line with a real ticket in it (decision 0017): a real one
    # is hundreds of base64 characters, a test's made-up one is short. Last: the source
    # payload audit names the patterns by their index.
    ("Steam encrypted app ticket", r"\b[Tt]icket *= *[A-Za-z0-9+/]{40,}"),
    # A signed-in Epic launch (decision 0059): the exchange code argument and the ownership
    # token. Appended for the same reason.
    ("Epic exchange code argument", r"AUTH_PASSWORD=[0-9A-Fa-f]{32}"),
    ("Epic ownership token", r"egoc1~[A-Za-z0-9_-]{20,}"),
    # Microsoft account and Xbox (decisions 0166, 0167). Appended for the same reason.
    # A refresh token (M.C507_BAY.0.U.-C…, M.R3_BAY.-C…), with its ! * $ characters.
    ("Microsoft account refresh token", r"\bM\.[CR][0-9]+_[A-Z0-9]+\.[A-Za-z0-9!*$%._-]{20,}"),
    # A compact ticket or access token (t=EwA…&p=, d=EwA…, an RpsTicket, a DeviceRps), a
    # thousand base64 characters: Ew at the start of a run, not inside one.
    ("Microsoft account ticket", r"(^|[^A-Za-z0-9+/])Ew[A-Za-z0-9+/%]{100,}"),
    ("Microsoft account ticket field",
     r'''([Rr]ps_?[Tt]icket|[Dd]evice_?[Rr]ps)["']? *[:=] *["']?([a-z]=)?[A-Za-z0-9+/%_-]{40,}'''),
    # Authorization: XBL3.0 x=<user hash>;<XSTS token>.
    ("Xbox Live authorization header", r"XBL3\.0 x=[A-Za-z0-9]{8,};"),
    # The account's identifiers in an Xbox token's DisplayClaims, like a SteamID64.
    ("Xbox user hash or XUID", r'"(uhs|xid)" *: *"[0-9]{8,}"'),
    # A legacy (SOAP) ticket's encrypted body, its session key, a licence's signed block.
    ("Microsoft account session secret or licence block",
     r"<([A-Za-z]+:)?(BinarySecret|CipherValue|SPLicenseBlock)>[A-Za-z0-9+/=]{20,}"),
    # An Xbox licence, as XML on one line or base64 (`<License ` or `<License>` at any of
    # base64's three alignments; not <LicenseInfo>).
    ("Xbox licence", r"<License( [^>]*)?><[A-Z]"),
    ("Xbox licence (base64)", r"(PExpY2Vuc2U[g+]|xMaWNlbnNl[IP]|8TGljZW5zZ[ST])[A-Za-z0-9+/]{20,}"),
    # A copy's content key (Xodus's `cik`), a device key or a session key, as hex or base64.
    ("content key", r'''([Cc]ontent_?[Kk]ey|\b[Cc][Ii][Kk]|[Dd]evice_?[Kk]ey|[Ss]ession_?[Kk]ey|[Bb]inary_?[Ss]ecret)'''
                    r'''["']? *[:=] *["']?([0-9A-Fa-f]{32,}|[A-Za-z0-9+/]{22,})'''),
    # The per-play key of the runtime's bridge (0167).
    ("Xbox bridge key", r'''XODUS_BRIDGE_KEY["']? *[:=] *["']?[A-Za-z0-9+/_-]{32,}'''),
]
# Made-up or public values the tests use; a line holding one is not a hit.
SECRET_FIXTURES = ("XTL-TEAMIDXXXX.", "XTL-A1B2C3D4E5.", "eyJhbGciOiJFZERTQSJ9.", "76561197960287930",
                   "/home/someone/")
SECRET_FILES = r"\.(p12|pfx|mobileprovision|cer|keystore|jks)$|(loginusers|config|local)\.vdf$|/ssfn[0-9]+$"
# Screenshots and recordings show games' artwork: evidence keeps them under .work and
# describes them in text (decision 0043).
EVIDENCE_MEDIA = r"^docs/evidence/.*\.(png|jpe?g|gif|webp|heic|bmp|tiff?|mov|mp4|m4v)$"
PAIRING_RECORDS = "/var/lib/lockdown"   # netmuxd's (tools/systemd): <UDID>.plist per paired phone
_SECRET_RES = [(what, re.compile(p)) for what, p in SECRETS]


# Split literals keep the gate's own definitions out of its matches.
NAME_PATTERNS = ("game" "native", r"\b" "gn[_-]")
_UPSTREAM_GN_TOKENS = re.compile(r"(?<![\w-])(?:" + "gn" + r"_args|" + "gn" + r"_helpers)(?![\w-])")


def name_scan_text(path, text):
    """Only the two upstream GN tokens are exempt, only in CEF/Chromium patches.

    The retired project name and every other retired-prefix word still fail.
    Callers pass a repository-relative path, never an archive or commit prefix.
    """
    if (path.startswith(("patches/cef/", "patches/chromium/"))
            and all(part not in ("", ".", "..") for part in path.split("/"))):
        return _UPSTREAM_GN_TOKENS.sub("", text)
    return text


def secret_hits(text):
    """(what, line) for each line of text that matches a secret pattern."""
    return [(what, line) for line in text.splitlines() if not any(f in line for f in SECRET_FIXTURES)
            for what, r in _SECRET_RES if r.search(line)]


TRAILERS = ("Class:", "Evidence:", "Offered-upstream:")
CLASSES = {"upstream-bug", "build-fix", "linux-build", "host-app", "diagnostics", "madeira-port", "ios-port", "feature",
           "valve"}
# Series other than *-port that may carry madeira-port patches: madeira-unix
# holds Madeira's own *_ios.c replacements ported onto patches/wine-port's base.
PORT_FOLLOWUPS = {"madeira-unix"}
# The one series that carries Valve's Wine commits (class valve, decision 0018).
VALVE_SERIES = "wine-valve"
VALVE_TRAILERS = ("Valve-commit:", "Picked:")
# The series of Xodus's and Xodus Nexus's Wine patches ported onto the PE tree (decision 0166):
# each names the commit it was ported from and how.
PORTED_SERIES = "wine-gdk"
PORTED_TRAILERS = ("Ported-from:", "Ported:")


def patch_problems(repo):
    """What is wrong with patches/ and the Madeira pin: the pins.lock madeira row
    against the upstream/madeira gitlink (in the index), every series entry a
    file, every patch in its series, and each patch's trailers
    (docs/ARCHITECTURE.md, "Patch series")."""
    bad = []
    with open(os.path.join(repo, "pins.lock")) as f:
        pin = next((line.split()[1] for line in f if line.split()[:1] == ["madeira"]), None)
    link = subprocess.run(["git", "-C", repo, "ls-files", "-s", "upstream/madeira"],
                          capture_output=True, text=True).stdout.split()
    if not link or link[1] != pin:
        bad.append(f"pins.lock madeira {pin} is not the upstream/madeira gitlink {link[1] if link else None}")
    root = os.path.join(repo, "patches")
    for target in sorted(os.listdir(root)):
        d = os.path.join(root, target)
        with open(os.path.join(d, "series")) as f:
            listed = [x.strip() for x in f if x.strip() and not x.startswith("#")]
        for name in listed:
            if not os.path.isfile(os.path.join(d, name)):
                bad.append(f"patches/{target}/series lists {name}, which does not exist")
        for name in sorted(os.listdir(d)):
            if not name.endswith(".patch"):
                continue
            if name not in listed:
                bad.append(f"patches/{target}/{name} is not in its series")
            with open(os.path.join(d, name), errors="replace") as f:
                head = f.read().split("\n---\n", 1)[0].splitlines()
            for t in TRAILERS:
                if not any(line.startswith(t + " ") for line in head):
                    bad.append(f"patches/{target}/{name} has no {t} trailer")
            cls = [line.split(None, 1)[1].strip() for line in head if line.startswith("Class: ")]
            if cls and cls[0] not in CLASSES:
                bad.append(f"patches/{target}/{name}: Class: {cls[0]} is not one of {sorted(CLASSES)}")
            elif cls and cls[0] == "madeira-port" and not (target.endswith("-port") or target in PORT_FOLLOWUPS):
                bad.append(f"patches/{target}/{name}: Class: madeira-port belongs in a *-port series "
                           f"or {', '.join(sorted(PORT_FOLLOWUPS))} only")
            elif cls and (cls[0] == "valve") != (target == VALVE_SERIES):
                bad.append(f"patches/{target}/{name}: patches/{VALVE_SERIES} holds class valve, and only it")
            if target == VALVE_SERIES:
                for t in VALVE_TRAILERS:
                    if not any(line.startswith(t + " ") for line in head):
                        bad.append(f"patches/{target}/{name} has no {t} trailer")
            if target == PORTED_SERIES:
                for t in PORTED_TRAILERS:
                    if not any(line.startswith(t + " ") for line in head):
                        bad.append(f"patches/{target}/{name} has no {t} trailer")
    return bad
