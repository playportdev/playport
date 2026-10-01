#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only, payload-free triage of an explicitly supplied pp source directory.

Recheck exact checksums/manifest/catalog; inventory archive members and recursively
scan containers/compressed streams without extracting or running them. Findings contain
only rule IDs, hashes, sizes and counts: no literal paths, values, lines or errors.
This is heuristic review, NOT permission to redistribute or proof of secret
absence. Catalog binary allowances/omissions are recorded, never broadened.
"""

import argparse
from collections import Counter
import bz2
import fnmatch
import hashlib
import io
import json
import lzma
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
import zipfile
import zlib

try:
    from compression import zstd
except ImportError:
    zstd = None  # Python before 3.14: explicitly blocked, never silently skipped.

try:
    from .checks import SECRETS, SECRET_FILES
except ImportError:
    from checks import SECRETS, SECRET_FILES

# Keep in sync with pp cmd_names; split literals avoid matching our own source.
NAME_PATTERNS = ("game" "native", r"\b" "gn[_-]")
CONTENT_RULES = [("secret-pattern-%02d" % i, re.compile(p, re.ASCII))
                 for i, (_, p) in enumerate(SECRETS)]
CONTENT_RULES += [("retired-name-%d" % i, re.compile(p, re.I | re.ASCII))
                  for i, p in enumerate(NAME_PATTERNS)]
CONTENT_RULES += [
    ("device-udid-shaped", re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b")),
    ("labelled-device-or-team-id", re.compile(
        r"(?i)(?:udid|uniquedeviceid|teamidentifier|teamid)[\s\"':=<>/-]+[A-Z0-9-]{10,40}\b")),
    ("pairing-or-provisioning-marker", re.compile(
        r"(?:HostPrivateKey|RootPrivateKey|PairRecord|EscrowBag|ProvisionedDevices|DeveloperCertificates)")),
    ("credential-assignment", re.compile(
        r"(?i)(?:password|refresh[_-]?token|access[_-]?token|session[_-]?token|api[_-]?key)"
        r"[\"']?\s*[:=]\s*[\"'][^\"'\r\n]{8,}[\"']")),
    ("service-token-shaped", re.compile(
        r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})")),
    ("other-absolute-local-path", re.compile(
        r"(?:[A-Za-z]:[\\/]Users[\\/][^\s\"'<>]+|/tmp/[^\s\"'<>]+|/private/var/[^\s\"'<>]+)")),
    ("opaque-encoded-text", re.compile(r"(?m)^[A-Za-z0-9+/]{256,}={0,2}\r?$")),
]
PATH_RULES = [
    ("secret-file-pattern", re.compile(SECRET_FILES, re.I)),
    ("private-input-path", re.compile(
        r"(?i)(?:^|/)(?:\.work|\.env(?:\.[^/]*)?|inputs\.local|device-state\.json|"
        r"pairing[^/]*|rppair[^/]*|account[^/]*|credentials[^/]*|session[^/]*|"
        r"steam-session[^/]*|lockdown|ssfn[0-9]+)(?:/|$)")),
    ("private-evidence-path", re.compile(
        r"(?i)(?:^|/)(?:evidence|crashes|logs|install-runs|ui-runs)(?:/|$)|\.(?:log|crash|ips|pcap|pcapng)$")),
    ("game-content-path", re.compile(
        r"(?i)(?:^|/)(?:steamapps|userdata|wineprefix|drive_c|depotcache|"
        r"appmanifest_[0-9]+\.acf|[^/]+_Data)(?:/|$)|\.(?:pak|vpk|unity3d|bundle|sav)$")),
    ("tool-input-path", re.compile(
        r"(?i)(?:^|/)(?:[^/]*\.sdk|[^/]*\.xcframework|[^/]*\.framework|"
        r"toolchains?|Xcode[^/]*|Staged)(?:/|$)|libmetalirconverter")),
    ("binary-or-media-path", re.compile(
        r"(?i)\.(?:pem|key|ipa|exe|dll|dylib|so(?:\.[0-9]+)*|a|o|obj|lib|class|wasm|"
        r"bin|png|jpe?g|gif|webp|pdf|mp[34]|wav|ogg|ttf|otf|metallib|air)$")),
    ("archive-path", re.compile(r"(?i)\.(?:zip|gz|xz|bz2|zst|7z|rar|tar|xip|dmg|deb|rpm|crate)$")),
]

ARCHIVES = (".tar", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".crate", ".zip")
OPAQUE = (".7z", ".rar", ".zst", ".gz", ".xz", ".bz2", ".xip", ".dmg")
BINARY = re.compile(r"(?i)\.(?:exe|dll|dylib|so(?:\.[0-9]+)*|a|o|obj|lib|pdb|nls|framework)$")
LIMITATIONS = [
    "Heuristic triage only; no legal/provenance/secret-absence or release approval.",
    "No network, execution, extraction, external symlink targets or normal Git trees read.",
    "Tar/zip/crate and gzip/xz/bzip2/zstd streams decoded within byte/member/depth limits.",
    "Decoded streams are virtual payloads, not extracted files; counts include each layer.",
    "Zstd requires Python's compression.zstd; unavailable support remains a blocker.",
    "Unsupported compression, encrypted archives and resource limits stay explicit blockers.",
    "Media, executable code, databases and encoded text are not semantically decoded.",
    "Public fixtures, source examples and intentional data can match private/binary rules.",
    "Catalog allowances remain review findings, not new permissions or packer rules.",
    "Only this bundle; not Git history, IPA, release/CI attachments or recipient rebuilds.",
]



def text_rules(data):
    """Pattern IDs only; strict (no blanket line-level fixture exemptions)."""
    views = [data.decode("latin1")]
    if b"\0" in data:
        # Both alignments handle a UTF-16 string embedded in arbitrary binary data.
        views.extend(data[start:].decode(enc, errors="replace")
                     for enc in ("utf-16-le", "utf-16-be") for start in (0, 1))
    return sorted({rule for rule, pattern in CONTENT_RULES
                   if any(pattern.search(view) for view in views)})


def payload_rules(data):
    rules = text_rules(data)
    try:
        data.decode("utf-8")
        binary = any(c < 32 and c not in (9, 10, 13) for c in data)
    except UnicodeDecodeError:
        binary = True
    if binary:
        rules.append("binary-payload-review")
    if (data.startswith((b"PK\x03\x04", b"\x1f\x8b", b"\xfd7zXZ\0", b"7z\xbc\xaf\x27\x1c", b"Rar!"))
            or data[257:262] == b"ustar"):
        rules.append("archive-payload-unexpanded")
    if data.startswith((b"MZ", b"\x7fELF", b"!<arch>\n", b"\0asm", b"\xcf\xfa\xed\xfe",
                        b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xce",
                        b"\xce\xfa\xed\xfe", b"\xbe\xba\xfe\xca")):
        rules.append("executable-or-library-payload-review")
    if data.startswith(b"SQLite format 3\0"):
        rules.append("database-payload-review")
    if data.startswith(b"version https://git-lfs.github.com/spec/v1\n"):
        rules.append("lfs-payload-unavailable")
    return sorted(set(rules))

class AuditError(Exception):
    """Constant payload-free failure code; never echo parser/OS exceptions."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def regular(path):
    if any(p.is_symlink() for p in (path, *path.parents)) or not stat.S_ISREG(path.stat().st_mode):
        raise AuditError("non-regular-or-linked-input")


def safe_path(name):
    # Source release archives sometimes use an initial ./, which does not escape.
    name = name.removeprefix("./").rstrip("/")
    return bool(name) and not name.startswith("/") and "\\" not in name and ":" not in name \
        and all(p not in ("", ".", "..", ".git") for p in name.split("/")) \
        and not any(ord(c) < 32 or ord(c) == 127 for c in name)


def inventory(bundle):
    regular(bundle / "SHA256SUMS")
    sums = {}
    for line in (bundle / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or not safe_path(match[2]) or "/" in match[2] or match[2] in sums or match[2] == "SHA256SUMS":
            raise AuditError("unsafe-or-duplicate-checksum-inventory")
        sums[match[2]] = match[1]
    files = list(bundle.iterdir())
    for path in files:
        regular(path)
    if set(sums) != {p.name for p in files} - {"SHA256SUMS"}:
        raise AuditError("checksum-inventory-mismatch")
    if any(file_digest(bundle / name) != sha for name, sha in sums.items()):
        raise AuditError("checksum-mismatch")
    manifest = json.loads((bundle / "SOURCE-MANIFEST.json").read_text())
    if manifest.get("schema") != 1 or not isinstance(manifest.get("missing"), list) \
            or not re.fullmatch(r"[0-9a-f]{40}", str(manifest.get("playport", ""))) \
            or manifest.get("status") != ("incomplete" if manifest["missing"] else "complete"):
        raise AuditError("invalid-source-manifest-status")
    entries = manifest["git"] + manifest["files"] + manifest["run_files"]
    if manifest.get("crates"):
        entries.append(manifest["crates"])
    names = [e["archive"] for e in entries]
    if len(set(names)) != len(names) or set(names) != set(sums) - {"SOURCE-MANIFEST.json", "README.md"}:
        raise AuditError("manifest-inventory-mismatch")
    if any(e.get("sha256", sums[e["archive"]]) != sums[e["archive"]] for e in entries):
        raise AuditError("manifest-checksum-mismatch")
    playports = [e for e in manifest["git"] if e["name"] == "playport"]
    if len(playports) != 1 or playports[0]["commit"] != manifest["playport"]:
        raise AuditError("playport-identity-mismatch")
    with tarfile.open(bundle / playports[0]["archive"]) as archive:
        catalogs = [m for m in archive if m.isfile() and m.name.endswith("/build/source-bundle.json")]
        if len(catalogs) != 1 or catalogs[0].size > 1 << 20:
            raise AuditError("missing-or-ambiguous-catalog")
        data = archive.extractfile(catalogs[0]).read()
    if digest(data) != manifest["catalog_sha256"]:
        raise AuditError("catalog-checksum-mismatch")
    catalog = json.loads(data)
    if catalog.get("schema") != 1 or any(m not in manifest["missing"] for m in catalog.get("missing", [])):
        raise AuditError("catalog-missing-sources-hidden")
    return sums, manifest, catalog


class Scanner:
    def __init__(self, *, max_file_bytes, max_total_bytes, max_members, max_depth):
        self.max_file_bytes, self.max_total_bytes = max_file_bytes, max_total_bytes
        self.max_members, self.max_depth = max_members, max_depth
        self.counts = Counter()
        self.rules = Counter()
        self.findings = []
        self.complete = True
        self.archives = []
        self.compressed_payloads = []

    def finding(self, context, path, rules, data=None, size=None):
        rules = sorted(set(rules))
        if not rules:
            return
        row = {"container_sha256": context, "path_sha256": digest(path.encode("utf-8", errors="surrogatepass")),
               "rules": rules}
        if data is not None:
            row["payload_sha256"] = digest(data)
        if size is not None:
            row["size"] = size
        self.findings.append(row)
        self.rules.update(rules)

    def blocked(self, context, name, reason, size=None):
        self.complete = False
        self.finding(context, name, [reason], size=size)

    def reserve(self, context, name, size):
        self.counts["members"] += 1
        if self.counts["members"] > self.max_members:
            raise AuditError("member-limit-exceeded")
        if size < 0 or size > self.max_file_bytes:
            self.blocked(context, name, "member-size-limit", size)
            return False
        self.counts["expanded_bytes"] += size
        if self.counts["expanded_bytes"] > self.max_total_bytes:
            raise AuditError("expanded-byte-limit-exceeded")
        return True

    def payload(self, data, name, context, depth, allowed=()):
        self.counts["regular_files"] += 1
        rules = text_rules(data)
        rules += [rule for rule, pattern in PATH_RULES if pattern.search(name)]
        binary = payload_rules(data)
        # Recursive archive decoding replaces the opaque-archive label.
        rules += [r for r in binary if r not in rules and r != "archive-payload-unexpanded"]
        if BINARY.search(name):
            rules.append("binary-extension-review")
        rel = "/".join(PurePosixPath(name).parts[1:])
        if any(fnmatch.fnmatchcase(rel, p) for p in allowed):
            rules.append("catalog-allow-binary-review")
        self.finding(context, name, rules, data, len(data))
        lower = name.lower()
        nested = lower.endswith(ARCHIVES) or data.startswith(b"PK\x03\x04") or data[257:262] == b"ustar"
        codec = self.compression(data)
        if nested:
            if depth >= self.max_depth:
                self.blocked(context, name, "archive-depth-limit")
            else:
                self.archive(io.BytesIO(data), digest(data), depth + 1, zip_hint=lower.endswith(".zip"))
        elif codec:
            if depth >= self.max_depth:
                self.blocked(context, name, "compressed-depth-limit")
            else:
                self.decompress(data, name, codec, depth + 1)
        elif lower.endswith(OPAQUE):
            self.blocked(context, name, "opaque-compressed-payload-unexpanded")

    @staticmethod
    def compression(data):
        if data.startswith(b"\x1f\x8b"):
            return "gzip"
        if data.startswith(b"\xfd7zXZ\0"):
            return "xz"
        if data.startswith(b"BZh"):
            return "bzip2"
        if data.startswith(b"\x28\xb5\x2f\xfd") or (
                len(data) >= 4 and 0x184D2A50 <= int.from_bytes(data[:4], "little") <= 0x184D2A5F):
            return "zstd"
        return None

    @staticmethod
    def decode_stream(data, codec, limit):
        """Bound every decoder call; verify EOF and all concatenated frames.

        Unlike BZ2File/LZMAFile, do not silently ignore trailing invalid bytes.
        Accept only the formats' defined gzip/xz stream padding. No output larger
        than limit+1 is materialised, even when a frame advertises a huge size.
        """
        factories = {"gzip": lambda: zlib.decompressobj(31),
                     "xz": lambda: lzma.LZMADecompressor(format=lzma.FORMAT_XZ),
                     "bzip2": bz2.BZ2Decompressor}
        if zstd is not None:
            factories["zstd"] = zstd.ZstdDecompressor
        output = bytearray()
        pending = data
        while pending:
            decoder = factories[codec]()
            feed = pending
            while True:
                output.extend(decoder.decompress(feed, max_length=limit + 1 - len(output)))
                if len(output) > limit:
                    return bytes(output)
                if decoder.eof:
                    pending = decoder.unused_data
                    if codec in ("gzip", "xz"):
                        padding = len(pending) - len(pending.lstrip(b"\0"))
                        if codec == "xz" and padding % 4:
                            raise ValueError("invalid xz padding")
                        pending = pending[padding:]
                    break
                if codec == "gzip":
                    feed = decoder.unconsumed_tail
                    if not feed:
                        raise EOFError("truncated gzip frame")
                else:
                    if decoder.needs_input:
                        raise EOFError("truncated compressed frame")
                    feed = b""
        return bytes(output)

    def decompress(self, data, name, codec, depth):
        """Decode a virtual payload, never extract/execute or echo parser errors.

        Invalid/truncated streams are local blockers; other fixtures still get
        scanned. Member/total/depth limits apply to every decoded layer.
        """
        context = digest(data)
        record = {"sha256": context, "codec": codec, "depth": depth, "status": "blocked"}
        self.compressed_payloads.append(record)
        self.counts["compressed_streams"] += 1
        if codec == "zstd" and zstd is None:
            self.blocked(context, name, "zstd-decoder-unavailable")
            return
        remaining = self.max_total_bytes - self.counts["expanded_bytes"]
        limit = min(self.max_file_bytes, remaining)
        try:
            decoded = self.decode_stream(data, codec, limit)
        except (OSError, EOFError, ValueError, lzma.LZMAError, zlib.error):
            self.blocked(context, name, "compressed-payload-read-failed")
            return
        except Exception as exc:
            # ZstdError is not an OSError; catch only that optional decoder type.
            if zstd is None or not isinstance(exc, zstd.ZstdError):
                raise
            self.blocked(context, name, "compressed-payload-read-failed")
            return
        if len(decoded) > limit:
            if remaining < self.max_file_bytes:
                raise AuditError("expanded-byte-limit-exceeded")
            record["decoded_size_lower_bound"] = len(decoded)
            self.blocked(context, name, "decoded-member-size-limit")
            return
        suffix = {"gzip": ".gz", "xz": ".xz", "bzip2": ".bz2", "zstd": ".zst"}[codec]
        decoded_name = name[:-len(suffix)] if name.lower().endswith(suffix) else name
        # A misleading name must not cause an infinite re-decode; dispatch is
        # by decoded magic (or a remaining actual container suffix), not codec.
        if self.reserve(context, decoded_name, len(decoded)):
            record.update(status="decoded", decoded_sha256=digest(decoded), decoded_size=len(decoded))
            self.payload(decoded, decoded_name, context, depth)

    def archive(self, source, context, depth=0, allowed=(), zip_hint=False):
        self.counts["archives"] += 1
        start = self.counts["members"]
        if zip_hint or zipfile.is_zipfile(source):
            source.seek(0) if hasattr(source, "seek") else None
            self.zip(source, context, depth, allowed)
        else:
            source.seek(0) if hasattr(source, "seek") else None
            self.tar(source, context, depth, allowed)
        self.archives.append({"sha256": context, "depth": depth, "members": self.counts["members"] - start})

    def zip(self, source, context, depth, allowed):
        names = set()
        try:
            with zipfile.ZipFile(source) as archive:
                for member in archive.infolist():
                    name = member.filename
                    rules = []
                    if not safe_path(name):
                        rules.append("unsafe-archive-path")
                    if name.rstrip("/") in names:
                        rules.append("duplicate-archive-member")
                    names.add(name.rstrip("/"))
                    mode = member.external_attr >> 16
                    if stat.S_IFMT(mode) not in (0, stat.S_IFDIR if member.is_dir() else stat.S_IFREG):
                        rules.append("special-or-linked-zip-member")
                    if rules:
                        self.complete = False
                    self.finding(context, name, rules, size=member.file_size)
                    if not self.reserve(context, name, member.file_size):
                        continue
                    if member.is_dir():
                        self.counts["directories"] += 1
                        continue
                    if member.flag_bits & 1:
                        self.blocked(context, name, "encrypted-archive-member")
                        continue
                    self.payload(archive.read(member), name, context, depth, allowed)
        except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
            raise AuditError("zip-payload-read-failed") from None

    def tar(self, source, context, depth, allowed):
        names, links, kinds = set(), {}, {}
        try:
            kwargs = {"fileobj": source} if hasattr(source, "read") else {"name": source}
            with tarfile.open(mode="r:*", **kwargs) as archive:
                for member in archive:
                    name = member.name.removeprefix("./").rstrip("/")
                    rules = []
                    if not safe_path(member.name):
                        rules.append("unsafe-archive-path")
                    if name in names:
                        rules.append("duplicate-archive-member")
                    names.add(name)
                    kinds[name] = "dir" if member.isdir() else "other"
                    if member.mode & 0o7000:
                        rules.append("privileged-archive-mode")
                    metadata = json.dumps({"uname": member.uname, "gname": member.gname,
                                           "pax": member.pax_headers, "link": member.linkname}).encode()
                    rules += ["archive-metadata-" + r for r in text_rules(metadata)]
                    if member.issym() or member.islnk():
                        self.counts["links"] += 1
                        links[name] = (member.linkname, member.islnk())
                    elif not (member.isdir() or member.isfile()):
                        rules.append("special-archive-member")
                    if any(r in rules for r in ("unsafe-archive-path", "duplicate-archive-member", "special-archive-member")):
                        self.complete = False
                    self.finding(context, member.name, rules, size=member.size)
                    if not self.reserve(context, member.name, member.size):
                        continue
                    if member.isdir():
                        self.counts["directories"] += 1
                    elif member.isfile():
                        data = archive.extractfile(member).read(self.max_file_bytes + 1)
                        if len(data) != member.size:
                            raise AuditError("truncated-archive-member")
                        self.payload(data, member.name, context, depth, allowed)
            for name in names:
                if any(str(p) in kinds and kinds[str(p)] != "dir" for p in PurePosixPath(name).parents):
                    self.blocked(context, name, "archive-parent-collision")
            for name in links:
                self.link(context, name, links)
        except (OSError, ValueError, tarfile.TarError):
            raise AuditError("tar-payload-read-failed") from None

    def link(self, context, name, links):
        """Resolve lexical link chains without touching disk; detect escapes/cycles."""
        target, hard = links[name]
        if not target or target.startswith("/") or "\\" in target or ":" in target or any(ord(c) < 32 for c in target):
            self.blocked(context, name, "escaping-archive-link")
            return
        pending = (PurePosixPath(name).parts[:-1] if not hard else ()) + tuple(target.split("/"))
        stack, seen = [], {name}
        expansions = 0
        while pending:
            part, *rest = pending
            pending = tuple(rest)
            if part in ("", "."):
                continue
            if part == "..":
                if not stack:
                    self.blocked(context, name, "escaping-archive-link")
                    return
                stack.pop()
                continue
            stack.append(part)
            current = "/".join(stack)
            if current in links:
                expansions += 1
                if current in seen or expansions > len(links):
                    self.blocked(context, name, "cyclic-archive-link")
                    return
                seen.add(current)
                value, is_hard = links[current]
                stack = [] if is_hard else stack[:-1]
                if value.startswith("/") or "\\" in value or ":" in value:
                    self.blocked(context, name, "escaping-archive-link")
                    return
                pending = tuple(value.split("/")) + pending
        if hard:
            self.finding(context, name, ["hardlink-member-review"])


def audit(bundle, *, max_file_bytes=64 << 20, max_total_bytes=12 << 30, max_members=1000000, max_depth=8):
    if min(max_file_bytes, max_total_bytes, max_members, max_depth) < 1:
        raise AuditError("positive-resource-limits-required")
    bundle = Path(bundle).absolute()
    sums, manifest, catalog = inventory(bundle)
    scanner = Scanner(max_file_bytes=max_file_bytes, max_total_bytes=max_total_bytes,
                      max_members=max_members, max_depth=max_depth)
    by_archive = {e["archive"]: e for e in manifest["git"]}
    allowances = {e["name"]: e.get("allow_binary", {}) for e in catalog["git"]}
    for path in sorted(bundle.iterdir()):
        context = file_digest(path)
        if path.name.lower().endswith(ARCHIVES):
            entry = by_archive.get(path.name, {})
            scanner.archive(path, context, allowed=allowances.get(entry.get("name"), ()))
        else:
            if scanner.reserve(context, path.name, path.stat().st_size):
                scanner.payload(path.read_bytes(), path.name, context, 0)
    omission_counts = Counter()
    for entry in manifest["git"]:
        omission_counts["submodules_left_out"] += len(entry.get("submodules_left_out", []))
        for rule in entry.get("dropped", {}).values():
            omission_counts["drop_rules"] += 1
            omission_counts["dropped_members"] += rule["members"]
    return {"schema": 1, "scope": {"source_manifest_sha256": sums["SOURCE-MANIFEST.json"],
                                     "checksum_file_sha256": file_digest(bundle / "SHA256SUMS"),
                                     "playport_commit": manifest["playport"], "source_status": manifest["status"],
                                     "missing_count": len(manifest["missing"]), "top_level_files": len(sums) + 1},
            "scan_complete": scanner.complete, "release_cleared": False,
            "limits": {"max_file_bytes": max_file_bytes, "max_total_bytes": max_total_bytes,
                       "max_members": max_members, "max_depth": max_depth},
            "counts": dict(sorted(scanner.counts.items())), "catalog_omissions": dict(omission_counts),
            "rule_counts": dict(sorted(scanner.rules.items())), "archives": scanner.archives,
            "compressed_payloads": scanner.compressed_payloads,
            "findings": scanner.findings, "limitations": LIMITATIONS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--output", type=Path, help="new payload-free JSON report (default stdout)")
    args = parser.parse_args()
    try:
        report = audit(args.bundle)
        text = json.dumps(report, indent=2) + "\n"
        if args.output:
            # Reports can fingerprint sensitive material; keep real reports under .work.
            if ".work" not in args.output.absolute().parts:
                raise AuditError("report-output-must-be-local-work")
            with args.output.open("x") as f:
                f.write(text)
        else:
            print(text, end="")
        return 0 if report["scan_complete"] else 2
    except AuditError as exc:
        print(json.dumps({"error": str(exc), "release_cleared": False}), file=sys.stderr)
        return 1
    except Exception:
        # Parser/library errors can embed untrusted names or values. Never echo them.
        print(json.dumps({"error": "input-read-or-schema-failed", "release_cleared": False}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
