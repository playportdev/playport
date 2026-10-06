# SPDX-License-Identifier: GPL-3.0-or-later
"""What `pp test` and `pp sync` both check, in one place: the secret patterns,
the Swift packages, and the shape of the patch series (AGENTS.md, Rules)."""

import os
import re
import subprocess

# The app's Swift packages with host tests.
SWIFT_PACKAGES = ["app/HostIOKit", "app/ContentKit", "app/GOGClient", "app/SteamClient", "app/PlayportKit"]

# What must never be committed (AGENTS.md, Secrets): (what, pattern). Each
# pattern is both a `git grep -E` and a Python regular expression.
SECRETS = [
    ("JWT-shaped token (Steam)", r"ey[AJ][A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
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
    return bad
