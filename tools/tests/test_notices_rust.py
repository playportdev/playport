# SPDX-License-Identifier: GPL-3.0-or-later
"""Rust notices must come from the locked archives and regenerated inventory."""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("notices_rust", REPO / "build/notices-rust.py")
rust_notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rust_notices)
spec = importlib.util.spec_from_file_location("notices_cache", REPO / "build/notices-rust-cache.py")
cache_notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache_notices)


class RustNotices(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.idevice = self.root / "idevice"
        self.run = self.root / "run"
        self.rust = self.root / "rust"
        for folder in (self.repo, self.idevice, self.run, self.rust):
            folder.mkdir()
        for args in (("init", "-q"), ("config", "user.name", "fixture"),
                     ("config", "user.email", "fixture@localhost")):
            rust_notices.provenance.git(self.idevice, *args)
        for path in ("ffi", "idevice"):
            (self.idevice / path).mkdir()
            (self.idevice / path / "Cargo.toml").write_text("# fixture\n")
        self.home = self.rust / "cargo"
        self.source = self.home / "registry/src/index/example-1.0.0"
        self.source.mkdir(parents=True)
        self.archive = self.home / "registry/cache/index/example-1.0.0.crate"
        self.archive.parent.mkdir(parents=True)
        self.files = {"Cargo.toml": b'[package]\nname = "example"\nversion = "1.0.0"\nlicense = "MIT"\n',
                      "LICENSE": b"notice\r\n", "src/lib.rs": b"// source\n"}
        self.make_archive()
        for name, data in self.files.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (self.source / ".cargo-ok").write_text("cache marker\n")
        self.lock = {"name": "example", "version": "1.0.0", "source": rust_notices.REGISTRY,
                     "checksum": hashlib.sha256(self.archive.read_bytes()).hexdigest()}
        self.package = {"name": "example", "version": "1.0.0", "license": "MIT",
                        "source": rust_notices.REGISTRY, "manifest_path": str(self.source / "Cargo.toml")}
        self.save_lock()
        self.inventory = self.run / "crates.tsv"
        self.inventory.write_text("example\t1.0.0\tMIT\t$CARGO_HOME/registry/src/index/example-1.0.0\n"
                                  f"idevice\t0.1.0\tMIT\t{self.run}/src/idevice\n"
                                  f"idevice-ffi\t0.1.0\t-\t{self.run}/src/ffi\n")

    def tearDown(self):
        self.temp.cleanup()

    def make_archive(self, extra=(), omit=()):
        with tarfile.open(self.archive, "w:gz") as tar:
            for name, data in self.files.items():
                if name in omit:
                    continue
                member = tarfile.TarInfo("example-1.0.0/" + name)
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
            for name, kind in extra:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = "LICENSE"
                tar.addfile(member, io.BytesIO(b""))

    def save_lock(self):
        text = "version = 4\n\n[[package]]\n" + "\n".join(f'{k} = "{v}"' for k, v in self.lock.items())
        text += '\n\n[[package]]\nname = "idevice"\nversion = "0.1.0"\n'
        text += '\n[[package]]\nname = "idevice-ffi"\nversion = "0.1.0"\n'
        (self.idevice / "Cargo.lock").write_text(text)
        rust_notices.provenance.git(self.idevice, "add", ".")
        rust_notices.provenance.git(self.idevice, "commit", "-qm", "fixture")
        pin = rust_notices.provenance.git(self.idevice, "rev-parse", "HEAD").decode().strip()
        (self.repo / "pins.lock").write_text(f"idevice {pin}\nrust 1.98.1\n")

    def resolve(self, src, rust, version, cache=None):
        self.assertNotEqual(cache, rust / "cargo")
        registry_package = {**self.package, "manifest_path": str(cache / "registry/src/index/example-1.0.0/Cargo.toml")}
        local = [{"name": name, "version": "0.1.0", "license": license_text, "source": None,
                  "manifest_path": str(src / directory / "Cargo.toml")}
                 for name, directory, license_text in (("idevice", "idevice", "MIT"), ("idevice-ffi", "ffi", None))]
        return [registry_package, *local], [registry_package, *local]

    def verify(self):
        with patch.object(rust_notices.cargo, "resolve", side_effect=self.resolve):
            return rust_notices.verify(self.repo, self.idevice, self.run, self.rust, self.root)

    def crate(self):
        return rust_notices.verify_crate(self.package, self.lock, self.rust)

    def prepare(self, output=None):
        index = self.home / "registry/index/index"
        index.mkdir(parents=True, exist_ok=True)
        (index / "config.json").write_text('{"fixture":true}\n')
        return cache_notices.prepare(self.repo, self.idevice, self.home, self.root,
                                     output or self.root / "notice-cargo")

    def snapshot(self, root):
        return {path.relative_to(root).as_posix(): path.read_bytes()
                for path in root.rglob("*") if path.is_file()}

    def update_files(self, declaration=None, extra=None, omit=()):
        for name in omit:
            self.files.pop(name, None)
            (self.source / name).unlink(missing_ok=True)
        if declaration is not None:
            self.files["Cargo.toml"] += f'license-file = {declaration}\n'.encode()
        self.files.update(extra or {})
        self.make_archive()
        self.lock["checksum"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        for name, data in self.files.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.save_lock()

    def collect(self, record=None, out=None):
        out = out or self.root / "out"
        out.mkdir(exist_ok=True)
        record = record or self.verify()
        record["collected_notices"] = rust_notices.collect_registry_notices(self.home, record, out)
        (out / "rust-provenance.json").write_text(json.dumps(record))
        return record, out

    def test_metadata_notices_do_not_enter_the_locked_registry_namespace(self):
        _, out = self.collect()
        selection = json.loads((REPO / "build/app-notices.json").read_text())
        component = next(c for c in selection["components"] if c["name"] == "idevice and its Rust crates")
        assembly = (REPO / "build/notices-assemble.sh").read_text()
        self.assertIn('cp_ "crate-notice-from-metadata-$c.txt"', assembly)
        self.assertNotIn('cp_ "rust-notice-from-metadata-$c.txt"', assembly)
        for crate in ("ns-keyed-archive", "plist-macro", "plist_ffi"):
            name = f"crate-notice-from-metadata-{crate}.txt"
            self.assertIn(name, component["include"])
            (out / name).write_bytes((REPO / "build/notices-extra" / f"{crate}-NOTICE-from-metadata").read_bytes())
        rust_notices.provenance.validate_rust_registry_notices(out)
        # Unknown payloads in the reserved registry namespace still fail closed.
        (out / "rust-notice-from-metadata-extra.txt").write_text("not from a locked archive")
        with self.assertRaisesRegex(ValueError, "payload/origin set"):
            rust_notices.provenance.validate_rust_registry_notices(out)

    def attribution_fixture(self):
        self.update_files(extra={"README.md": b"Original licence distinctions\r\n",
                                 "cpp/plist.h": b"/* Original authors, LGPL-2.1-or-later */\r\n"},
                          omit=("LICENSE",))
        sources = {name: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
                   for name, data in self.files.items()}
        entry = {"name": "example", "version": "1.0.0", "archive_sha256": self.lock["checksum"], "sources": sources}
        self.attribution_catalog_bytes = json.dumps({"schema": 1, "crates": [entry]}).encode()
        self.attribution_catalog_digest = hashlib.sha256(self.attribution_catalog_bytes).hexdigest()
        mock = patch.object(rust_notices, "attribution_catalog", return_value=(self.attribution_catalog_digest, {("example", "1.0.0"): entry}))
        mock.start()
        self.addCleanup(mock.stop)
        return sources

    def attribution_inventory(self, out):
        # Feed the dynamically reloaded production module the same in-memory catalog.
        original = Path.open
        def catalog_open(path, *args, **kwargs):
            if path == REPO / "build/rust-attribution.lock.json":
                mode = args[0] if args else kwargs.get("mode", "r")
                return io.BytesIO(self.attribution_catalog_bytes) if "b" in mode else io.StringIO(self.attribution_catalog_bytes.decode())
            return original(path, *args, **kwargs)
        with patch.object(Path, "open", catalog_open):
            return rust_notices.provenance.inventory(out)

    def test_attribution_copies_preserve_full_headers_readmes_and_source_without_closing_missing_notices(self):
        sources = self.attribution_fixture()
        before = self.snapshot(self.home)
        record, out = self.collect()
        self.assertEqual(record["schema"], 3)
        self.assertEqual(record["attribution_catalog_sha256"], self.attribution_catalog_digest)
        self.assertEqual(len(record["collected_notices"]), len(sources))
        for name, origin in record["collected_notices"].items():
            self.assertTrue(origin["attribution_superset"])
            self.assertEqual(origin["archive_sha256"], self.lock["checksum"])
            self.assertEqual(origin["member"], "example-1.0.0/" + origin["source"])
            self.assertEqual((out / name).read_bytes(), self.files[origin["source"]])
        self.assertEqual((out / "rust-crates-without-licence-files.txt").read_text(), "example 1.0.0 (MIT)\n")
        self.attribution_inventory(out)
        self.assertEqual(self.snapshot(self.home), before)
        self.assertNotIn(str(self.root), json.dumps(record))

    def test_attribution_catalog_refuses_changed_archive_source_size_and_missing_member(self):
        sources = self.attribution_fixture()
        with self.assertRaisesRegex(ValueError, "archive differs from reviewed"):
            rust_notices.attribution_sources("example", "1.0.0", "0" * 64)
        for case in ("changed", "missing", "size"):
            with self.subTest(case=case):
                files = dict(self.files)
                if case == "changed":
                    files["README.md"] = b"changed"
                elif case == "missing":
                    del files["README.md"]
                else:
                    sources["README.md"]["size"] += 1
                with self.assertRaisesRegex(ValueError, "source differs from reviewed"):
                    rust_notices.registry_collection_candidates(files, self.lock["checksum"])
                if case == "size":
                    sources["README.md"]["size"] -= 1

    def test_attribution_inventory_refuses_joint_file_candidate_origin_and_payload_omission(self):
        self.attribution_fixture()
        record, out = self.collect()
        for case in ("omission", "hash", "size", "label", "catalog", "downgrade", "scope"):
            with self.subTest(case=case):
                changed = json.loads(json.dumps(record))
                crate = changed["crates"][0]
                candidate = crate["notice_candidates"]["README.md"]
                if case == "omission":
                    del crate["files"]["README.md"]
                    del crate["notice_candidates"]["README.md"]
                    del changed["collected_notices"]["rust-example-1.0.0-README.md"]
                elif case == "hash":
                    crate["files"]["README.md"] = candidate["sha256"] = "0" * 64
                elif case == "size":
                    candidate["size"] += 1
                elif case == "label":
                    del candidate["attribution_superset"]
                elif case == "catalog":
                    changed["attribution_catalog_sha256"] = "0" * 64
                elif case == "scope":
                    changed["scope"] = "complete permission notices"
                else:
                    changed["schema"] = 2
                (out / "rust-provenance.json").write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    self.attribution_inventory(out)

    def test_attribution_discovery_and_declared_license_are_deduplicated(self):
        self.update_files('"LICENSE"')
        sources = {"LICENSE": {"sha256": hashlib.sha256(self.files["LICENSE"]).hexdigest(),
                               "size": len(self.files["LICENSE"])}}
        with patch.object(rust_notices, "attribution_catalog", return_value=("a" * 64, {
                ("example", "1.0.0"): {"archive_sha256": self.lock["checksum"], "sources": sources}})):
            record, out = self.collect()
            self.assertEqual(len(record["collected_notices"]), 1)
            candidate = record["crates"][0]["notice_candidates"]["LICENSE"]
            self.assertTrue(candidate["attribution_superset"])
            self.assertEqual(candidate["declared_by"], ["Cargo.toml"])
            self.assertEqual((out / "rust-crates-without-licence-files.txt").read_bytes(), b"")

    def test_attribution_collection_rechecks_archives_and_rolls_back_failed_writes(self):
        self.attribution_fixture()
        record = self.verify()
        out = self.root / "out"
        out.mkdir()
        original = Path.open
        def fail(path, *args, **kwargs):
            if path == out / "rust-example-1.0.0-cpp-plist.h":
                raise OSError("fixture attribution write failure")
            return original(path, *args, **kwargs)
        with patch.object(Path, "open", fail), self.assertRaises(OSError):
            rust_notices.collect_registry_notices(self.home, record, out)
        self.assertEqual(list(out.iterdir()), [])
        self.archive.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "archive differs"):
            rust_notices.collect_registry_notices(self.home, record, out)
        self.assertEqual(list(out.iterdir()), [])

    def test_attribution_inventory_refuses_missing_extra_changed_and_symlinked_payloads(self):
        self.attribution_fixture()
        _, out = self.collect()
        payload = out / "rust-example-1.0.0-cpp-plist.h"
        original = payload.read_bytes()
        for case in ("missing", "extra", "changed", "symlink"):
            with self.subTest(case=case):
                extra = out / "rust-example-1.0.0-injected.h"
                if case == "missing":
                    payload.unlink()
                elif case == "extra":
                    extra.write_text("extra")
                elif case == "changed":
                    payload.write_bytes(b"changed")
                else:
                    payload.unlink()
                    payload.symlink_to(self.source / "cpp/plist.h")
                with self.assertRaises(ValueError):
                    self.attribution_inventory(out)
                payload.unlink(missing_ok=True)
                payload.write_bytes(original)
                extra.unlink(missing_ok=True)
        self.attribution_inventory(out)

    def test_attribution_cli_manifest_failure_cleans_up_all_evidence_and_summaries(self):
        self.attribution_fixture()
        out = self.root / "out"
        out.mkdir()
        output = out / "rust-provenance.json"
        output.mkdir()
        args = ["notices-rust.py", str(self.repo), str(self.idevice), str(self.run), str(self.rust),
                str(self.root), str(output), "--collect-notices", str(out)]
        with patch.object(rust_notices.cargo, "resolve", side_effect=self.resolve), patch.object(sys, "argv", args):
            with self.assertRaises(SystemExit) as result:
                rust_notices.main()
        self.assertEqual(result.exception.code, 1)
        self.assertEqual(list(out.iterdir()), [output])

    def test_reviewed_attribution_catalog_scope_identities_and_source_hashes(self):
        digest, entries = rust_notices.attribution_catalog()
        self.assertEqual(len(digest), 64)
        self.assertEqual(set(entries), {("ns-keyed-archive", "0.1.5"), ("plist-macro", "0.1.6"), ("plist_ffi", "0.1.6")})
        self.assertEqual(sum(len(c["sources"]) for c in entries.values()), 103)
        self.assertEqual(sum(s["size"] for c in entries.values() for s in c["sources"].values()), 299542)
        for (name, version), entry in entries.items():
            self.assertEqual(rust_notices.attribution_sources(name, version, entry["archive_sha256"]), entry["sources"])
            self.assertFalse(any(path.startswith("test/data/") for path in entry["sources"]))
            self.assertIn("README.md", entry["sources"])
        self.assertIn("src/m.rs", entries[("plist-macro", "0.1.6")]["sources"])
        self.assertIn("cpp/include/plist/plist.h", entries[("plist_ffi", "0.1.6")]["sources"])
        self.assertIn("tools/plistutil.c", entries[("plist_ffi", "0.1.6")]["sources"])
        self.assertEqual(rust_notices.attribution_sources("plist_ffi", "0.1.7", "0" * 64), {})

    def test_declared_non_candidate_and_recursive_notices_are_collected_byte_for_byte(self):
        self.update_files('"./legal/terms"', {"legal/terms": b"declared\r\n", "nested/NOTICE": b"nested\n"})
        before = self.snapshot(self.home)
        record, out = self.collect()
        crate = record["crates"][0]
        self.assertEqual(crate["license_file_source"], "legal/terms")
        origins = record["collected_notices"]
        self.assertEqual(set(origins), {"rust-example-1.0.0-LICENSE", "rust-example-1.0.0-legal-terms",
                                      "rust-example-1.0.0-nested-NOTICE"})
        declared = origins["rust-example-1.0.0-legal-terms"]
        self.assertEqual(declared["declared_by"], ["Cargo.toml"])
        self.assertEqual(declared["member"], "example-1.0.0/legal/terms")
        self.assertEqual((out / "rust-example-1.0.0-legal-terms").read_bytes(), b"declared\r\n")
        self.assertEqual((out / "rust-crates-without-licence-files.txt").read_bytes(), b"")
        rust_notices.provenance.inventory(out)
        self.assertNotIn(str(self.root), json.dumps(record))
        self.assertEqual(self.snapshot(self.home), before)

    def test_declared_discovered_notice_is_deduplicated_and_internal_parent_path_resolves(self):
        self.update_files('"src/../LICENSE"')
        record, out = self.collect()
        self.assertEqual(list(record["collected_notices"]), ["rust-example-1.0.0-LICENSE"])
        self.assertEqual(record["crates"][0]["notice_candidates"]["LICENSE"]["declared_by"], ["Cargo.toml"])
        rust_notices.provenance.inventory(out)

    def test_crates_without_notice_files_stay_explicit_not_silently_satisfied_by_license_expression(self):
        self.update_files(omit=("LICENSE",))
        record, out = self.collect()
        self.assertEqual(record["collected_notices"], {})
        self.assertEqual((out / "rust-crates-without-licence-files.txt").read_text(), "example 1.0.0 (MIT)\n")
        rust_notices.provenance.inventory(out)

    def test_registry_declarations_refuse_missing_directory_escape_absolute_control_and_inheritance(self):
        original = self.files["Cargo.toml"]
        declarations = ['"missing"', '"src"', '"../LICENSE"', '"src/../../LICENSE"',
                        '"/LICENSE"', '"C:/LICENSE"', '"LICENSE\\\\file"', '"LICENSE\\t"',
                        '"LICENSE\\u007f"', '""', '"src/"', '"src/.."', 'true', '42', '{workspace = true}']
        for declaration in declarations:
            with self.subTest(declaration=declaration):
                self.files["Cargo.toml"] = original
                self.update_files(declaration)
                with self.assertRaisesRegex(ValueError, "license-file"):
                    self.verify()

    def test_registry_flattened_names_collide_without_partial_output(self):
        self.update_files(extra={"NOTICE/NOTICE": b"a", "NOTICE-NOTICE": b"b"})
        out = self.root / "out"
        out.mkdir()
        with self.assertRaisesRegex(ValueError, "colliding"):
            rust_notices.collect_registry_notices(self.home, self.verify(), out)
        self.assertEqual(list(out.iterdir()), [])

    def test_registry_collection_rechecks_archives_and_candidate_coverage(self):
        record = self.verify()
        out = self.root / "out"
        out.mkdir()
        self.archive.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "archive differs"):
            rust_notices.collect_registry_notices(self.home, record, out)
        self.make_archive()
        record["crates"][0]["archive_sha256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        record["crates"][0]["notice_candidates"]["LICENSE"]["size"] += 1
        with self.assertRaisesRegex(ValueError, "changed after archive"):
            rust_notices.collect_registry_notices(self.home, record, out)
        record["crates"][0]["notice_candidates"].clear()
        with self.assertRaisesRegex(ValueError, "omit/add"):
            rust_notices.collect_registry_notices(self.home, record, out)
        self.assertEqual(list(out.iterdir()), [])

    def test_registry_collection_refuses_existing_symlinked_outputs_and_rolls_back_failed_writes(self):
        record = self.verify()
        out = self.root / "out"
        out.mkdir()
        name = "rust-example-1.0.0-LICENSE"
        payload = out / name
        payload.write_bytes(b"existing")
        with self.assertRaisesRegex(ValueError, "already exists"):
            rust_notices.collect_registry_notices(self.home, record, out)
        self.assertEqual(payload.read_bytes(), b"existing")
        payload.unlink()
        payload.symlink_to(self.source / "LICENSE")
        with self.assertRaisesRegex(ValueError, "already exists"):
            rust_notices.collect_registry_notices(self.home, record, out)
        payload.unlink()
        alias = self.root / "alias"
        alias.symlink_to(out)
        with self.assertRaisesRegex(ValueError, "symlink"):
            rust_notices.collect_registry_notices(self.home, record, alias)
        original = Path.open
        def fail(path, *args, **kwargs):
            if path == payload:
                raise OSError("fixture write failure")
            return original(path, *args, **kwargs)
        with patch.object(Path, "open", fail), self.assertRaises(OSError):
            rust_notices.collect_registry_notices(self.home, record, out)
        self.assertEqual(list(out.iterdir()), [])

    def test_registry_inventory_refuses_missing_extra_changed_symlinked_notices_and_changed_summaries(self):
        record, out = self.collect()
        payload = out / "rust-example-1.0.0-LICENSE"
        for case in ("missing", "extra", "changed", "symlink", "summary"):
            with self.subTest(case=case):
                original = payload.read_bytes()
                extra = out / "rust-injected-1.0.0-NOTICE"
                summary = out / "rust-crates.tsv"
                saved = summary.read_bytes()
                if case == "missing":
                    payload.unlink()
                elif case == "extra":
                    extra.write_text("extra")
                elif case == "changed":
                    payload.write_text("changed")
                elif case == "symlink":
                    payload.unlink()
                    payload.symlink_to(self.source / "LICENSE")
                else:
                    summary.write_text("changed")
                with self.assertRaises(ValueError):
                    rust_notices.provenance.inventory(out)
                payload.unlink(missing_ok=True)
                payload.write_bytes(original)
                extra.unlink(missing_ok=True)
                summary.write_bytes(saved)

    def test_registry_inventory_refuses_omitted_candidates_declarations_origins_and_collection(self):
        self.update_files('"terms"', {"terms": b"declared"})
        record, out = self.collect()
        manifest = out / "rust-provenance.json"
        for case in ("candidate", "declaration", "resolved", "crate", "origin", "hash", "collection", "manifest", "schema"):
            with self.subTest(case=case):
                changed = json.loads(json.dumps(record))
                crate = changed["crates"][0]
                if case == "candidate":
                    del crate["notice_candidates"]["terms"]
                elif case == "declaration":
                    del crate["notice_candidates"]["terms"]["declared_by"]
                elif case == "resolved":
                    crate["license_file_source"] = "LICENSE"
                elif case == "crate":
                    changed["crates"] = []
                elif case == "schema":
                    changed["schema"] = 1
                elif case == "origin":
                    del changed["collected_notices"]["rust-example-1.0.0-terms"]
                elif case == "hash":
                    crate["files"]["terms"] = "0" * 64
                elif case == "collection":
                    del changed["collected_notices"]
                manifest.write_text(json.dumps(changed))
                if case == "manifest":
                    manifest.unlink()
                with self.assertRaises(ValueError):
                    rust_notices.provenance.inventory(out)
                manifest.write_text(json.dumps(record))

    def test_registry_cli_collection_and_manifest_failure_cleanup(self):
        out = self.root / "out"
        out.mkdir()
        output = out / "rust-provenance.json"
        args = ["notices-rust.py", str(self.repo), str(self.idevice), str(self.run), str(self.rust),
                str(self.root), str(output), "--collect-notices", str(out)]
        with patch.object(rust_notices.cargo, "resolve", side_effect=self.resolve), patch.object(sys, "argv", args):
            rust_notices.main()
        rust_notices.provenance.inventory(out)
        for path in out.iterdir():
            path.unlink()
        output.mkdir()
        with patch.object(rust_notices.cargo, "resolve", side_effect=self.resolve), patch.object(sys, "argv", args):
            with self.assertRaises(SystemExit) as result:
                rust_notices.main()
        self.assertEqual(result.exception.code, 1)
        self.assertEqual(list(out.iterdir()), [output])

    def test_registry_archive_control_characters_and_windows_paths_fail_closed(self):
        for name in ("example-1.0.0/NOTICE\\t", "example-1.0.0/C:NOTICE", "example-1.0.0/NOTICE\\x7f"):
            with self.subTest(name=name):
                self.make_archive([(name, tarfile.REGTYPE)])
                self.lock["checksum"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    self.crate()

    def test_pristine_cache_ignores_generated_and_modified_sources_without_writing_shared_inputs(self):
        (self.source / "generated.h").write_text("generated\n")
        (self.source / "LICENSE").write_text("modified\n")
        (self.source / "outside").symlink_to(self.repo)
        before = self.snapshot(self.home)
        record = self.prepare()
        self.assertEqual(self.snapshot(self.home), {**before, "registry/index/index/config.json": b'{"fixture":true}\n'})
        prepared = self.root / "notice-cargo"
        source = prepared / "registry/src/index/example-1.0.0"
        self.assertEqual((source / "LICENSE").read_bytes(), self.files["LICENSE"])
        self.assertFalse((source / "generated.h").exists())
        self.assertFalse((source / "outside").exists())
        self.assertNotIn(str(self.root), json.dumps(record))
        self.assertEqual(list(self.root.glob("notice-cargo.partial.*")), [])
        with patch.object(rust_notices.cargo, "resolve", side_effect=self.resolve):
            verified = rust_notices.verify(self.repo, self.idevice, self.run, self.rust, self.root,
                                           registry_home=prepared)
        self.assertEqual(verified["crates"][0]["files"], record["crates"][0]["files"])

    def test_preparation_rejects_missing_corrupt_and_ambiguous_archives_without_output(self):
        for case in ("missing", "corrupt", "ambiguous"):
            with self.subTest(case=case):
                self.make_archive()
                duplicate = self.home / "registry/cache/other/example-1.0.0.crate"
                if case == "missing":
                    self.archive.unlink()
                elif case == "corrupt":
                    self.archive.write_bytes(b"corrupt")
                else:
                    duplicate.parent.mkdir()
                    duplicate.write_bytes(self.archive.read_bytes())
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse((self.root / "notice-cargo").exists())
                self.assertEqual(list(self.root.glob("notice-cargo.partial.*")), [])
                if duplicate.exists():
                    duplicate.unlink()
                    duplicate.parent.rmdir()

    def test_preparation_rejects_dirty_lock_and_unsupported_sources(self):
        (self.idevice / "Cargo.lock").write_text("dirty\n")
        with self.assertRaises(ValueError):
            self.prepare()
        self.lock["source"] = "git+https://example.invalid/repo"
        self.save_lock()
        with self.assertRaisesRegex(ValueError, "unsupported locked"):
            self.prepare()
        self.assertFalse((self.root / "notice-cargo").exists())

    def test_preparation_refuses_existing_or_overlapping_output(self):
        for output in (self.home, self.home / "notices", self.rust):
            with self.subTest(output=output), self.assertRaises(ValueError):
                self.prepare(output)
        output = self.root / "notice-cargo"
        output.symlink_to(self.home)
        with self.assertRaises(ValueError):
            self.prepare(output)
        self.assertTrue(output.is_symlink())

    def test_preparation_refuses_index_and_archive_symlinks(self):
        self.prepare()
        output = self.root / "second-cargo"
        for path in (self.home / "registry/index/index/config.json", self.archive):
            with self.subTest(path=path):
                saved = path.with_name(path.name + ".saved")
                path.rename(saved)
                path.symlink_to(saved)
                with self.assertRaisesRegex(ValueError, "symlink"):
                    self.prepare(output)
                self.assertFalse(output.exists())
                path.unlink()
                saved.rename(path)

    def test_preparation_rejects_unsafe_link_duplicate_and_colliding_members(self):
        cases = [("example-1.0.0/../escape", tarfile.REGTYPE),
                 ("example-1.0.0/link", tarfile.SYMTYPE),
                 ("example-1.0.0/link", tarfile.LNKTYPE),
                 ("example-1.0.0/LICENSE", tarfile.REGTYPE),
                 ("example-1.0.0/LICENSE/child", tarfile.REGTYPE),
                 ("example-1.0.0/.cargo-ok", tarfile.REGTYPE)]
        for member in cases:
            with self.subTest(member=member):
                self.make_archive([member])
                self.lock["checksum"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
                self.save_lock()
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse((self.root / "notice-cargo").exists())
                self.assertFalse((self.root / "escape").exists())
                self.assertEqual(list(self.root.glob("notice-cargo.partial.*")), [])

    def test_preparation_preserves_racing_destination(self):
        output = self.root / "notice-cargo"
        original = cache_notices.subprocess.run
        def race(command, **kwargs):
            output.mkdir()
            return original(command, **kwargs)
        # subprocess is shared with verify_tree; race only the publication.
        def publication(command, **kwargs):
            if command[0] == "mv":
                return race(command, **kwargs)
            return original(command, **kwargs)
        with patch.object(cache_notices.subprocess, "run", side_effect=publication):
            with self.assertRaisesRegex(ValueError, "appeared during"):
                self.prepare()
        self.assertTrue(output.is_dir())
        self.assertEqual(list(output.iterdir()), [])
        self.assertEqual(list(self.root.glob("notice-cargo.partial.*")), [])

    def test_separate_registry_copy_origins_reverify_notices(self):
        self.prepare()
        home = self.root / "notice-cargo"
        out = self.root / "out"
        out.mkdir()
        source = home / "registry/src/index/example-1.0.0/LICENSE"
        (out / "rust.txt").write_bytes(source.read_bytes())
        log = out / ".copy-sources.tsv"
        log.write_text(f"rust.txt\t{source}\n")
        with patch.object(rust_notices.cargo, "resolve", side_effect=self.resolve):
            record = rust_notices.verify(self.repo, self.idevice, self.run, self.rust, self.root, registry_home=home)
        (out / "rust-provenance.json").write_text(json.dumps(record))
        with patch.object(rust_notices.provenance, "source_roots", return_value=[]), patch.dict(
                os.environ, {"RUST_ROOT": str(self.rust), "RUST_NOTICE_CARGO_HOME": str(home)}):
            copies = rust_notices.provenance.validate_copies(self.repo, log)
            self.assertEqual(copies["files"][0]["verification"], "locked-registry-archive-bytes")
            self.assertNotIn(str(self.root), json.dumps(copies))
            source.write_bytes(b"changed")
            (out / "rust.txt").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "changed after archive"):
                rust_notices.provenance.validate_copies(self.repo, log)

    def test_regenerated_inventory_and_path_independent_archive_record(self):
        record = self.verify()
        crate = record["crates"][0]
        self.assertEqual(crate["verification"], "locked-registry-archive-bytes")
        self.assertEqual(crate["files"]["LICENSE"], hashlib.sha256(b"notice\r\n").hexdigest())
        self.assertEqual(crate["archive_sha256"], self.lock["checksum"])
        self.assertNotIn(str(self.root), json.dumps(record))
        self.assertFalse((self.run / "src").exists())
        self.assertEqual(list(self.root.glob("tmp*")), [])

    def series(self, diff):
        folder = self.repo / "patches/idevice"
        folder.mkdir(parents=True)
        (folder / "0001-fixture.patch").write_text(diff)
        (folder / "series").write_text("0001-fixture.patch\n")

    def test_inventory_resolves_the_pin_plus_its_series_without_changing_the_checkout(self):
        self.series("diff --git a/ffi/Cargo.toml b/ffi/Cargo.toml\n--- a/ffi/Cargo.toml\n"
                    "+++ b/ffi/Cargo.toml\n@@ -1 +1 @@\n-# fixture\n+# patched\n")
        seen = []
        original = self.resolve

        def resolve(src, rust, version, cache=None):
            seen.append((src / "ffi/Cargo.toml").read_text())
            return original(src, rust, version, cache)
        self.resolve = resolve
        record = self.verify()
        self.assertEqual(seen, ["# patched\n"])
        self.assertEqual([p["name"] for p in record["idevice_series"]], ["0001-fixture.patch"])
        self.assertNotEqual(record["idevice_resolved_tree"], record["idevice_tree"])
        self.assertEqual((self.idevice / "ffi/Cargo.toml").read_text(), "# fixture\n")
        rust_notices.provenance.git(self.idevice, "diff", "--exit-code", "HEAD")

    def test_series_that_does_not_apply_to_the_pin_rejected(self):
        self.series("diff --git a/ffi/Cargo.toml b/ffi/Cargo.toml\n--- a/ffi/Cargo.toml\n"
                    "+++ b/ffi/Cargo.toml\n@@ -1 +1 @@\n-# other\n+# patched\n")
        with self.assertRaisesRegex(ValueError, "apply"):
            self.verify()

    def test_missing_duplicate_changed_and_extra_inventory_rows_rejected(self):
        original = self.inventory.read_text()
        cases = ["", original + original.splitlines()[0] + "\n", original.replace("MIT", "Apache-2.0", 1),
                 original.replace("example\t1.0.0", "example\t9.0.0", 1),
                 "\n".join(original.splitlines()[1:]) + "\n",
                 original + "extra\t1.0.0\tMIT\t$CARGO_HOME/registry/src/index/extra-1.0.0\n",
                 original.replace("$CARGO_HOME/registry", "$CARGO_HOME/../registry", 1),
                 original.replace(str(self.run / "src/ffi"), str(self.root / "other/ffi"))]
        for text in cases:
            with self.subTest(text=text):
                self.inventory.write_text(text)
                with self.assertRaises(ValueError):
                    self.verify()

    def test_dirty_committed_lock_rejected(self):
        with (self.idevice / "Cargo.lock").open("a") as file:
            file.write("# changed\n")
        with self.assertRaises(ValueError):
            self.verify()

    def test_archive_missing_or_mutated_rejected(self):
        self.archive.write_bytes(b"corrupted")
        with self.assertRaisesRegex(ValueError, "archive differs"):
            self.crate()
        self.archive.unlink()
        with self.assertRaisesRegex(ValueError, "archive differs"):
            self.crate()

    def test_source_notice_manifest_and_non_notice_mutations_rejected(self):
        for name in self.files:
            with self.subTest(name=name):
                (self.source / name).write_bytes(b"modified\n")
                with self.assertRaisesRegex(ValueError, "source differs"):
                    self.crate()
                (self.source / name).write_bytes(self.files[name])

    def test_forged_cache_checksum_does_not_authorize_changed_notice(self):
        (self.source / "LICENSE").write_bytes(b"modified")
        (self.source / ".cargo-checksum.json").write_text(json.dumps({"package": self.lock["checksum"], "files": {}}))
        with self.assertRaisesRegex(ValueError, "source differs"):
            self.crate()

    def test_extra_notice_rejected(self):
        (self.source / "NOTICE-extra").write_text("injected\n")
        with self.assertRaisesRegex(ValueError, "extra crate source"):
            self.crate()

    def test_symlinked_notice_source_directory_and_archive_rejected(self):
        for path in (self.source / "LICENSE", self.source, self.archive):
            with self.subTest(path=path):
                moved = path.with_name(path.name + ".saved")
                path.rename(moved)
                path.symlink_to(moved)
                with self.assertRaisesRegex(ValueError, "symlink"):
                    self.crate()
                with patch.object(rust_notices.cargo, "resolve") as command:
                    with self.assertRaisesRegex(ValueError, "symlink"):
                        rust_notices.verify(self.repo, self.idevice, self.run, self.rust, self.root)
                    command.assert_not_called()
                path.unlink()
                moved.rename(path)

    def test_duplicate_unsafe_link_and_wrong_root_archive_members_rejected(self):
        for name, kind in (("example-1.0.0/LICENSE", tarfile.REGTYPE),
                           ("example-1.0.0/../escape", tarfile.REGTYPE),
                           ("/escape", tarfile.REGTYPE), ("other/LICENSE", tarfile.REGTYPE),
                           ("example-1.0.0/link", tarfile.SYMTYPE),
                           ("example-1.0.0/link", tarfile.LNKTYPE)):
            with self.subTest(name=name, kind=kind):
                self.make_archive([(name, kind)])
                self.lock["checksum"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
                with self.assertRaises(ValueError):
                    self.crate()

    def test_archive_without_manifest_rejected(self):
        self.make_archive(omit=("Cargo.toml",))
        self.lock["checksum"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, "lacks Cargo.toml"):
            self.crate()

    def test_metadata_license_and_source_substitution_rejected(self):
        self.package["license"] = "Apache-2.0"
        with self.assertRaisesRegex(ValueError, "metadata differs"):
            self.crate()
        self.package["source"] = "git+https://example.invalid/repo"
        with self.assertRaisesRegex(ValueError, "unsupported crate source"):
            self.crate()

    def test_rust_shell_failure_removes_partial_output(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        python = bin_dir / "python3"
        python.write_text('#!/bin/sh\n'
                          'case "$1:$2" in *notices-provenance.py:trees) '
                          'printf "{}\\n" > "$5"; exit 0 ;; esac\n'
                          f'exec "{sys.executable}" "$@"\n')
        python.chmod(0o755)
        self.inventory.write_text("")
        destination = self.root / "notices"
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   PLAYPORT_BUILD=str(self.root / "build"), IDEVICE=str(self.idevice),
                   IDEVICE_RUN=str(self.run), RUST_ROOT=str(self.rust))
        # This fixture's pin does not match Playport's pin, so failure precedes
        # Cargo. The real verifier runs and the shell must remove its debris.
        result = subprocess.run(["bash", str(REPO / "build/notices-assemble.sh"), str(destination)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Rust notice provenance:", result.stderr)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob("notices.partial.*")), [])

    def test_inventory_symlink_and_cli_failure_leave_no_manifest(self):
        saved = self.inventory.with_suffix(".saved")
        self.inventory.rename(saved)
        self.inventory.symlink_to(saved)
        output = self.root / "rust-provenance.json"
        result = subprocess.run([sys.executable, str(REPO / "build/notices-rust.py"),
                                 str(self.repo), str(self.idevice), str(self.run), str(self.rust),
                                 str(self.root), str(output)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("regular file", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(output.exists())

    def test_copy_origin_requires_manifest_and_rechecks_verified_notice(self):
        out = self.root / "out"
        out.mkdir()
        log = out / ".copy-sources.tsv"
        (out / "rust-notice.txt").write_bytes(self.files["LICENSE"])
        log.write_text(f"rust-notice.txt\t{self.source / 'LICENSE'}\n")
        with patch.object(rust_notices.provenance, "source_roots", return_value=[]), patch.dict(os.environ, {"RUST_ROOT": str(self.rust)}):
            with self.assertRaisesRegex(ValueError, "lacks locked archive verification"):
                rust_notices.provenance.validate_copies(self.repo, log)
            (out / "rust-provenance.json").write_text(json.dumps(self.verify()))
            record = rust_notices.provenance.validate_copies(self.repo, log)
            self.assertEqual(record["files"][0]["verification"], "locked-registry-archive-bytes")
            (self.source / "LICENSE").write_bytes(b"changed after verification")
            (out / "rust-notice.txt").write_bytes(b"changed after verification")
            with self.assertRaisesRegex(ValueError, "changed after archive verification"):
                rust_notices.provenance.validate_copies(self.repo, log)

    def test_cargo_resolution_uses_offline_locked_pinned_target_features(self):
        def run(command, **kwargs):
            self.assertEqual(kwargs["env"]["RUSTUP_TOOLCHAIN"], "1.98.1-x86_64-unknown-linux-gnu")
            if command[0].endswith("rustc"):
                return subprocess.CompletedProcess(command, 0, "rustc 1.98.1 (fixture)\n", "")
            self.assertIn("--locked", command)
            self.assertIn("--offline", command)
            self.assertIn(rust_notices.cargo.FEATURES, command)
            self.assertIn(rust_notices.cargo.TARGET, command)
            if "tree" in command:
                self.assertIn("normal", command)
                return subprocess.CompletedProcess(command, 0, "example v1.0.0\nexample v1.0.0 (*)\n", "")
            return subprocess.CompletedProcess(command, 0, json.dumps({"packages": [self.package]}), "")
        with patch.object(rust_notices.cargo.subprocess, "run", side_effect=run):
            _, selected = rust_notices.cargo.resolve(self.idevice, self.rust, "1.98.1")
        self.assertEqual(selected, [self.package])


if __name__ == "__main__":
    unittest.main()
