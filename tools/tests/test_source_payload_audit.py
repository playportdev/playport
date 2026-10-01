# SPDX-License-Identifier: GPL-3.0-or-later
"""Payload-free, read-only source archive triage; no publication approval."""

import bz2
import contextlib
import gzip
import io
import json
import lzma
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

from tools import source_payload_audit as audit

REPO = Path(__file__).resolve().parents[2]


def tar_bytes(entries, mode="w:gz"):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode=mode) as archive:
        for name, payload in entries:
            info = tarfile.TarInfo(name)
            if isinstance(payload, tarfile.TarInfo):
                info = payload
                archive.addfile(info)
            else:
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
    return output.getvalue()


def zip_bytes(entries):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, payload in entries:
            archive.writestr(name, payload)
    return output.getvalue()


class SourcePayloadAudit(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        self.catalog = {"schema": 1, "git": [{"name": "playport", "allow_binary": {
            "data/*.nls": "explicit non-executable data allowance"}}],
            "missing": [{"what": "recipient rebuild", "why": "not tested"}]}
        catalog = json.dumps(self.catalog).encode()
        self.archive = tar_bytes([("playport/build/source-bundle.json", catalog),
                                  ("playport/source.c", b"int source;\n"),
                                  ("playport/data/locale.nls", b"\x00locale-data")])
        (self.bundle / "playport.tar.gz").write_bytes(self.archive)
        self.manifest = {"schema": 1, "playport": "a" * 40,
                         "catalog_sha256": audit.digest(catalog), "status": "incomplete",
                         "missing": self.catalog["missing"],
                         "git": [{"name": "playport", "archive": "playport.tar.gz", "commit": "a" * 40,
                                  "dropped": {"prebuilt/*": {"members": 2}}, "submodules_left_out": [{}]}],
                         "files": [], "run_files": [], "crates": None}
        self.refresh()

    def tearDown(self):
        self.temp.cleanup()

    def refresh(self):
        (self.bundle / "SOURCE-MANIFEST.json").write_text(json.dumps(self.manifest))
        (self.bundle / "README.md").write_text("Incomplete source bundle\n")
        (self.bundle / "SHA256SUMS").write_text("".join(
            f"{audit.file_digest(p)}  {p.name}\n" for p in sorted(self.bundle.iterdir()) if p.name != "SHA256SUMS"))

    def scanner(self, **overrides):
        limits = dict(max_file_bytes=1 << 20, max_total_bytes=8 << 20, max_members=1000, max_depth=4)
        limits.update(overrides)
        return audit.Scanner(**limits)

    def scan(self, data, **limits):
        scanner = self.scanner(**limits)
        scanner.archive(io.BytesIO(data), audit.digest(data))
        return scanner

    def test_exact_inventory_catalog_and_explicit_omissions_are_preserved(self):
        before = {p.name: p.read_bytes() for p in self.bundle.iterdir()}
        with mock.patch.object(subprocess, "run", side_effect=AssertionError("no child execution")):
            result = audit.audit(self.bundle)
        self.assertTrue(result["scan_complete"])
        self.assertFalse(result["release_cleared"])
        self.assertEqual(result["scope"]["source_status"], "incomplete")
        self.assertEqual(result["catalog_omissions"], {
            "submodules_left_out": 1, "drop_rules": 1, "dropped_members": 2})
        self.assertEqual(result["rule_counts"]["catalog-allow-binary-review"], 1)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.bundle.iterdir()})

    def test_nested_crate_tar_and_zip_are_read_without_extracting(self):
        nested = zip_bytes([("root/source.c", b"int nested;\n")])
        crate = tar_bytes([("crate-1.0/code.zip", nested)])
        scanner = self.scan(tar_bytes([("root/crate-1.0.crate", crate)]))
        self.assertTrue(scanner.complete)
        self.assertEqual(scanner.counts["archives"], 3)
        self.assertEqual(scanner.counts["regular_files"], 3)
        self.assertEqual({a["depth"] for a in scanner.archives}, {0, 1, 2})
        self.assertNotIn("archive-payload-unexpanded", scanner.rules)

    def test_reports_contain_no_literal_paths_payloads_or_match_values(self):
        name = "private/unique-filename.txt"
        payload = ("/" + "home/fixtureperson/private\n" + "password=" + '"unique-fixture-credential"\n').encode()
        scanner = self.scan(tar_bytes([(name, payload)]))
        text = json.dumps(scanner.findings)
        self.assertNotIn(name, text)
        self.assertNotIn("fixtureperson", text)
        self.assertNotIn("unique-fixture-credential", text)
        self.assertIn("credential-assignment", text)
        self.assertIn("secret-pattern-07", text)
        self.assertIn(audit.digest(payload), text)
        self.assertIn(audit.digest(name.encode()), text)

    def test_magic_binaries_are_detected_without_binary_filename_extensions(self):
        scanner = self.scan(tar_bytes([("root/fixture.dat", b"MZ" + b"\0" * 32)]))
        self.assertEqual(scanner.rules["executable-or-library-payload-review"], 1)
        self.assertNotIn("binary-extension-review", scanner.rules)

    def test_allowance_does_not_suppress_binary_or_privacy_findings(self):
        payload = (b"MZ\0" + ("/" + "home/fixtureperson/source").encode())
        scanner = self.scanner()
        data = tar_bytes([("root/data/test.nls", payload), ("root/elsewhere/test.nls", payload)])
        scanner.archive(io.BytesIO(data), audit.digest(data), allowed={"data/*.nls": "data only"})
        self.assertEqual(scanner.rules["catalog-allow-binary-review"], 1)
        self.assertEqual(scanner.rules["secret-pattern-07"], 2)
        self.assertEqual(scanner.rules["executable-or-library-payload-review"], 2)

    def test_unsafe_duplicate_and_special_members_remain_blockers(self):
        special = tarfile.TarInfo("root/fifo")
        special.type = tarfile.FIFOTYPE
        data = tar_bytes([("../escape", b"x"), ("root/duplicate", b"a"),
                          ("root/duplicate", b"b"), ("root/fifo", special)])
        scanner = self.scan(data)
        self.assertFalse(scanner.complete)
        for rule in ("unsafe-archive-path", "duplicate-archive-member", "special-archive-member"):
            self.assertEqual(scanner.rules[rule], 1)

    def test_symlink_escape_cycle_and_parent_collision_do_not_touch_disk(self):
        escape = tarfile.TarInfo("root/escape")
        escape.type, escape.linkname = tarfile.SYMTYPE, "../../outside"
        a, b = tarfile.TarInfo("root/a"), tarfile.TarInfo("root/b")
        a.type = b.type = tarfile.SYMTYPE
        a.linkname, b.linkname = "b", "a"
        scanner = self.scan(tar_bytes([("root/escape", escape), ("root/a", a), ("root/b", b),
                                       ("root/a/child", b"content")]))
        self.assertFalse(scanner.complete)
        self.assertEqual(scanner.rules["escaping-archive-link"], 1)
        self.assertEqual(scanner.rules["cyclic-archive-link"], 2)
        self.assertEqual(scanner.rules["archive-parent-collision"], 1)
        self.assertEqual(list(self.root.iterdir()), [self.bundle])

    def test_contained_symlink_and_hardlink_are_inventory_not_permissions(self):
        link, hard = tarfile.TarInfo("root/link"), tarfile.TarInfo("root/hard")
        link.type, link.linkname = tarfile.SYMTYPE, "file"
        hard.type, hard.linkname = tarfile.LNKTYPE, "root/file"
        scanner = self.scan(tar_bytes([("root/file", b"data"), ("root/link", link), ("root/hard", hard)]))
        self.assertTrue(scanner.complete)
        self.assertEqual(scanner.counts["links"], 2)
        self.assertEqual(scanner.rules["hardlink-member-review"], 1)

    def test_zip_links_are_flagged_and_never_followed(self):
        info = zipfile.ZipInfo("root/link")
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        scanner = self.scan(zip_bytes([(info, "../../outside")]))
        self.assertFalse(scanner.complete)
        self.assertEqual(scanner.rules["special-or-linked-zip-member"], 1)

    def test_resource_and_opaque_compression_limits_are_not_silently_clean(self):
        scanner = self.scan(tar_bytes([("root/large", b"0123456789")]), max_file_bytes=4)
        self.assertFalse(scanner.complete)
        self.assertEqual(scanner.rules["member-size-limit"], 1)
        nested = tar_bytes([("root/child.tar", tar_bytes([("nested/file", b"x")]))])
        scanner = self.scan(nested, max_depth=0)
        self.assertFalse(scanner.complete)
        self.assertEqual(scanner.rules["archive-depth-limit"], 1)
        scanner = self.scan(tar_bytes([("root/opaque.zst", b"opaque-compression")]))
        self.assertFalse(scanner.complete)
        self.assertEqual(scanner.rules["opaque-compressed-payload-unexpanded"], 1)
        with self.assertRaisesRegex(audit.AuditError, "member-limit"):
            self.scan(tar_bytes([("root/a", b"x"), ("root/b", b"x")]), max_members=1)
        with self.assertRaisesRegex(audit.AuditError, "expanded-byte-limit"):
            self.scan(tar_bytes([("root/a", b"xx")]), max_total_bytes=1)

    def codecs(self):
        codecs = [("gzip", ".gz", gzip.compress), ("xz", ".xz", lzma.compress),
                  ("bzip2", ".bz2", bz2.compress)]
        if audit.zstd is not None:
            codecs.append(("zstd", ".zst", audit.zstd.compress))
        return codecs

    def test_compressed_magic_without_suffix_is_decoded_and_payload_free(self):
        payload = ("/" + "home/fixtureperson/private\npassword=" + '"unique-credential"\n').encode()
        for codec, suffix, compress in self.codecs():
            with self.subTest(codec=codec):
                encoded = compress(payload)
                scanner = self.scan(tar_bytes([("root/hidden.dat", encoded)]))
                self.assertTrue(scanner.complete)
                self.assertEqual(scanner.counts["compressed_streams"], 1)
                self.assertEqual(scanner.counts["expanded_bytes"], len(encoded) + len(payload))
                self.assertEqual(scanner.counts["members"], 2)
                self.assertTrue(any(f.get("payload_sha256") == audit.digest(payload) and
                                    "credential-assignment" in f["rules"] for f in scanner.findings))
                record = scanner.compressed_payloads[0]
                self.assertEqual(record, {"sha256": audit.digest(encoded), "codec": codec,
                    "depth": 1, "status": "decoded", "decoded_sha256": audit.digest(payload),
                    "decoded_size": len(payload)})
                text = json.dumps([scanner.findings, scanner.compressed_payloads])
                for private in ("fixtureperson", "unique-credential", "hidden.dat"):
                    self.assertNotIn(private, text)

    def test_decoded_binary_still_requires_review(self):
        for codec, suffix, compress in self.codecs():
            with self.subTest(codec=codec):
                scanner = self.scan(tar_bytes([("root/tool.exe" + suffix, compress(b"MZ" + b"\0" * 32))]))
                self.assertTrue(scanner.complete)  # coverage, never release clearance
                self.assertEqual(scanner.rules["executable-or-library-payload-review"], 1)
                self.assertEqual(scanner.rules["binary-extension-review"], 1)

    def test_concatenated_compression_frames_scan_all_plaintext(self):
        payload = ("/" + "home/fixtureperson/second-frame").encode()
        for codec, suffix, compress in self.codecs():
            with self.subTest(codec=codec):
                scanner = self.scan(tar_bytes([("root/data" + suffix, compress(b"first\n") + compress(payload))]))
                self.assertTrue(scanner.complete)
                self.assertEqual(scanner.compressed_payloads[0]["decoded_size"], 6 + len(payload))
                self.assertTrue(any(f.get("payload_sha256") == audit.digest(b"first\n" + payload) and
                                    "secret-pattern-07" in f["rules"] for f in scanner.findings))

    def test_truncated_corrupt_and_trailing_compressed_bytes_are_local_blockers(self):
        for codec, suffix, compress in self.codecs():
            encoded = compress(b"fixture" * 100)
            for broken in (encoded[:-1], encoded + b"not-a-valid-next-frame"):
                with self.subTest(codec=codec, size=len(broken)):
                    scanner = self.scan(tar_bytes([("root/broken" + suffix, broken),
                                                   ("root/later.exe", b"MZ\0later")]))
                    self.assertFalse(scanner.complete)
                    self.assertEqual(scanner.rules["compressed-payload-read-failed"], 1)
                    self.assertEqual(scanner.rules["executable-or-library-payload-review"], 1)
                    self.assertEqual(scanner.compressed_payloads[0]["status"], "blocked")

    def test_compressed_checksums_are_verified_not_just_decoded(self):
        for codec, suffix, compress in self.codecs():
            if codec == "zstd":
                encoded = audit.zstd.compress(b"fixture" * 100,
                    options={audit.zstd.CompressionParameter.checksum_flag: 1})
            else:
                encoded = compress(b"fixture" * 100)
            damaged = bytearray(encoded)
            damaged[-8] ^= 1
            with self.subTest(codec=codec):
                scanner = self.scan(tar_bytes([("root/broken" + suffix, bytes(damaged))]))
                self.assertFalse(scanner.complete)
                self.assertEqual(scanner.rules["compressed-payload-read-failed"], 1)

    def test_gzip_and_xz_defined_padding_is_accepted_but_not_arbitrary_trailers(self):
        for codec, suffix, compress, padding in (("gzip", ".gz", gzip.compress, b"\0" * 3),
                                               ("xz", ".xz", lzma.compress, b"\0" * 4)):
            with self.subTest(codec=codec):
                encoded = compress(b"first") + padding + compress(b"second") + padding
                scanner = self.scan(tar_bytes([("root/data" + suffix, encoded)]))
                self.assertTrue(scanner.complete)
                self.assertEqual(scanner.compressed_payloads[0]["decoded_sha256"], audit.digest(b"firstsecond"))
        scanner = self.scan(tar_bytes([("root/data.xz", lzma.compress(b"fixture") + b"\0")]))
        self.assertFalse(scanner.complete)
        self.assertEqual(scanner.rules["compressed-payload-read-failed"], 1)

    def test_compressed_size_limit_is_bounded_and_not_an_exact_size_claim(self):
        for codec, suffix, compress in self.codecs():
            with self.subTest(codec=codec):
                encoded = compress(b"a" * (1 << 20))
                scanner = self.scan(tar_bytes([("root/bomb" + suffix, encoded)]), max_file_bytes=2048)
                self.assertFalse(scanner.complete)
                self.assertEqual(scanner.rules["decoded-member-size-limit"], 1)
                self.assertEqual(scanner.compressed_payloads[0]["decoded_size_lower_bound"], 2049)
                self.assertNotIn("decoded_size", scanner.compressed_payloads[0])
                self.assertNotIn("decoded_sha256", scanner.compressed_payloads[0])
        scanner = self.scanner(max_file_bytes=2048)
        with mock.patch.object(audit.zlib, "decompressobj") as factory:
            factory.return_value.decompress.return_value = b"a" * 2049
            scanner.decompress(b"compressed", "root/data.gz", "gzip", 1)
            factory.return_value.decompress.assert_called_once_with(b"compressed", max_length=2049)

    def test_compression_shares_total_member_and_depth_limits(self):
        encoded = gzip.compress(b"a" * 100)
        with self.assertRaisesRegex(audit.AuditError, "expanded-byte-limit"):
            self.scan(tar_bytes([("root/data.gz", encoded)]), max_total_bytes=len(encoded) + 50)
        with self.assertRaisesRegex(audit.AuditError, "member-limit"):
            self.scan(tar_bytes([("root/data.gz", encoded)]), max_members=1)
        scanner = self.scan(tar_bytes([("root/data.gz.gz", gzip.compress(encoded))]), max_depth=1)
        self.assertFalse(scanner.complete)
        self.assertEqual(scanner.rules["compressed-depth-limit"], 1)
        self.assertEqual(scanner.counts["compressed_streams"], 1)

    def test_compressed_tar_zip_and_nested_streams_reach_inner_members(self):
        payload = b"MZ\0fixture"
        for name, data in (("root/file.zip.gz", gzip.compress(zip_bytes([("root/code", payload)]))),
                           ("root/file.gz.gz", gzip.compress(gzip.compress(payload)))):
            scanner = self.scan(tar_bytes([(name, data)]))
            self.assertTrue(scanner.complete)
            self.assertEqual(scanner.rules["executable-or-library-payload-review"], 1)
        if audit.zstd is not None:
            data = audit.zstd.compress(tar_bytes([("root/code", payload)], mode="w"))
            scanner = self.scan(tar_bytes([("root/file.tar.zst", data)]))
            self.assertTrue(scanner.complete)
            self.assertEqual(scanner.counts["archives"], 2)
            self.assertEqual(scanner.rules["executable-or-library-payload-review"], 1)

    def test_empty_streams_are_decoded_not_opaque(self):
        for codec, suffix, compress in self.codecs():
            with self.subTest(codec=codec):
                scanner = self.scan(tar_bytes([("root/empty" + suffix, compress(b""))]))
                self.assertTrue(scanner.complete)
                self.assertEqual(scanner.compressed_payloads[0]["decoded_size"], 0)

    def test_missing_optional_zstd_decoder_is_explicit_blocker(self):
        with mock.patch.object(audit, "zstd", None):
            scanner = self.scan(tar_bytes([("root/data", b"\x28\xb5\x2f\xfdcompressed")]))
        self.assertFalse(scanner.complete)
        self.assertEqual(scanner.rules["zstd-decoder-unavailable"], 1)
        self.assertEqual(scanner.compressed_payloads[0]["status"], "blocked")

    def test_skippable_zstd_magic_cannot_hide_following_frames(self):
        if audit.zstd is None:
            self.skipTest("compression.zstd unavailable")
        skip = b"\x50\x2a\x4d\x18" + (4).to_bytes(4, "little") + b"skip"
        scanner = self.scan(tar_bytes([("root/data", skip + audit.zstd.compress(b"MZ\0fixture"))]))
        self.assertTrue(scanner.complete)
        self.assertEqual(scanner.rules["executable-or-library-payload-review"], 1)

    def test_checksum_corruption_missing_extra_duplicate_and_escape_fail(self):
        path = self.bundle / "playport.tar.gz"
        original = path.read_bytes()
        path.write_bytes(original + b"corrupted")
        with self.assertRaisesRegex(audit.AuditError, "checksum-mismatch"):
            audit.audit(self.bundle)
        path.write_bytes(original)
        (self.bundle / "extra").write_text("extra")
        with self.assertRaisesRegex(audit.AuditError, "inventory-mismatch"):
            audit.audit(self.bundle)
        (self.bundle / "extra").unlink()
        sums = (self.bundle / "SHA256SUMS").read_text()
        for malformed in (sums * 2, "0" * 64 + "  ../escape\n", "0" * 64 + "  missing\n"):
            (self.bundle / "SHA256SUMS").write_text(malformed)
            with self.assertRaises(audit.AuditError):
                audit.audit(self.bundle)

    def test_symlink_input_is_not_read_even_when_it_matches_checksum(self):
        path = self.bundle / "README.md"
        copy = self.root / "readme"
        copy.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(copy)
        with self.assertRaisesRegex(audit.AuditError, "non-regular-or-linked-input"):
            audit.audit(self.bundle)

    def test_catalog_manifest_and_completeness_disagreements_fail(self):
        original = json.loads(json.dumps(self.manifest))
        for mutate in (lambda m: m.update(catalog_sha256="0" * 64),
                       lambda m: m.update(status="complete"),
                       lambda m: m.update(status="complete", missing=[]),
                       lambda m: m["git"].clear()):
            self.manifest = json.loads(json.dumps(original))
            mutate(self.manifest)
            self.refresh()
            with self.assertRaises(audit.AuditError):
                audit.audit(self.bundle)

    def test_cli_parser_errors_are_constant_payload_free_and_output_is_exclusive(self):
        output = self.root / "report.json"
        with mock.patch("sys.argv", ["audit", str(self.bundle), "--output", str(output)]):
            self.assertEqual(audit.main(), 0)
        self.assertFalse(json.loads(output.read_text())["release_cleared"])
        with mock.patch("sys.argv", ["audit", str(self.bundle), "--output", str(output)]), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(audit.main(), 1)
        self.assertNotIn(str(output), errors.getvalue())
        with mock.patch("sys.argv", ["audit", "missing-private-input"]), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(audit.main(), 1)
        self.assertNotIn("missing-private-input", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
