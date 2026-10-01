# SPDX-License-Identifier: GPL-3.0-or-later
"""Release archive notice checks are read-only and fail closed."""

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
spec = importlib.util.spec_from_file_location("stdlib_notices", REPO / "build/notices-rust-stdlib.py")
stdlib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stdlib)


class RustStdlibNotices(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo, self.rust, self.dist = (self.root / name for name in ("repo", "rust", "dist"))
        for folder in (self.repo / "build", self.rust, self.dist):
            folder.mkdir(parents=True)
        self.version = "1.98.1"
        (self.repo / "pins.lock").write_text(f"rust {self.version}\n")
        self.lock = {"schema": 1, "rust": self.version, "manifest_url": "https://example.invalid/manifest",
                     "manifest_sha256": "0" * 64, "source_commit": "a" * 40,
                     "release": self.version + " (aaaaaaaaa 2026-09-01)", "components": {}}
        self.toolchain = Path("rustup/toolchains") / f"{self.version}-{stdlib.HOST}"
        self.prefixes = {}
        self.archives = {}
        for component, target, folder, files in (
                ("rustc", stdlib.HOST, "share/doc/rust/", {n: b"notice\r\n" + n.encode() for n in stdlib.NOTICES}),
                ("rust-std", stdlib.TARGET, f"lib/rustlib/{stdlib.TARGET}/lib/",
                 {"libstd-fixture.rlib": b"fixture library", "libcore-fixture.rmeta": b"fixture metadata"})):
            name = f"{component}-{self.version}-{target}.tar.xz"
            prefix = name[:-7] + "/" + (component if component == "rustc" else f"rust-std-{target}") + "/" + folder
            self.prefixes[component] = prefix
            self.archives[component] = self.dist / name
            self.archive(component, [(prefix + n, data, tarfile.REGTYPE) for n, data in files.items()])
            self.lock["components"][component] = {"target": target, "archive": name,
                "url": "https://example.invalid/" + name, "sha256": stdlib.rust.provenance.digest(self.archives[component])}
            for n, data in files.items():
                installed = self.rust / self.toolchain / folder / n
                installed.parent.mkdir(parents=True, exist_ok=True)
                installed.write_bytes(data)
        name = f"rust-src-{self.version}.tar.xz"
        self.prefixes["rust-src"] = name[:-7] + "/"
        self.archives["rust-src"] = self.dist / name
        self.source_files = {path: b"source\r\n" for path in stdlib.SOURCE_REQUIRED
                             if path not in ("version", "git-commit-hash")}
        self.source_files[stdlib.SOURCE + "library/Cargo.toml"] = b"[workspace]\n"
        self.source_files[stdlib.SOURCE + "library/Cargo.lock"] = b"version = 4\n"
        self.source_files[stdlib.SOURCE + "library/std/Cargo.toml"] = (
            b'[package]\nname = "std"\nversion = "0.0.0"\nlicense = "MIT OR Apache-2.0"\n')
        self.source_files[stdlib.SOURCE + "library/vendor/fixture/LICENSE"] = b"vendored notice\r\n"
        self.archive("rust-src", [(self.prefixes["rust-src"] + n, data, tarfile.REGTYPE)
                                  for n, data in self.source_files.items()])
        self.lock["components"]["rust-src"] = {"target": "*", "archive": name,
            "url": "https://example.invalid/" + name, "sha256": stdlib.rust.provenance.digest(self.archives["rust-src"])}
        self.lockfile = self.repo / "build/rust-dist.lock.json"
        for args in (("init", "-q"), ("config", "user.name", "fixture"),
                     ("config", "user.email", "fixture@localhost")):
            stdlib.rust.provenance.git(self.repo, *args)
        self.commit_lock()

    def archive(self, component, entries, identity=True):
        entries = list(entries)
        if identity:
            top = self.archives[component].name[:-7] + "/"
            entries.extend((top + name, self.lock[key].encode(), tarfile.REGTYPE)
                           for name, key in (("version", "release"), ("git-commit-hash", "source_commit"))
                           if top + name not in {entry[0] for entry in entries})
        with tarfile.open(self.archives[component], "w:xz") as archive:
            for name, data, kind in entries:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.size = len(data) if kind == tarfile.REGTYPE else 0
                member.linkname = "outside"
                archive.addfile(member, io.BytesIO(data) if member.isfile() else None)

    def commit_lock(self):
        self.lockfile.write_text(json.dumps(self.lock))
        stdlib.rust.provenance.git(self.repo, "add", ".")
        stdlib.rust.provenance.git(self.repo, "commit", "--allow-empty", "-qm", "fixture")

    def verify(self):
        return stdlib.verify(self.repo, self.rust, self.dist)

    def notice(self):
        return self.rust / self.toolchain / "share/doc/rust/COPYRIGHT-library.html"

    def test_exact_archives_notices_and_installed_stdlib(self):
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        record = self.verify()
        self.assertEqual(len(record["notices"]), 5)
        self.assertEqual(len(record["components"]["rust-std"]["files"]), 2)
        self.assertNotIn(str(self.root), json.dumps(record))
        self.assertIn("not build derivation", record["scope"])
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_all_archive_licence_texts_are_verified_as_superset(self):
        name = "licenses/Unicode-3.0.txt"
        data = b"extra release licence text"
        entries = [(self.prefixes["rustc"] + n, b"notice\r\n" + n.encode(), tarfile.REGTYPE)
                   for n in stdlib.NOTICES]
        entries.append((self.prefixes["rustc"] + name, data, tarfile.REGTYPE))
        self.archive("rustc", entries)
        installed = self.rust / self.toolchain / "share/doc/rust" / name
        installed.write_bytes(data)
        self.lock["components"]["rustc"]["sha256"] = stdlib.rust.provenance.digest(self.archives["rustc"])
        self.commit_lock()
        record = self.verify()
        self.assertIn((self.toolchain / "share/doc/rust" / name).as_posix(), record["notices"])
        installed.write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "differs from locked archive"):
            self.verify()

    def test_missing_and_corrupt_archive(self):
        archive = self.archives["rustc"]
        archive.write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "differs from lock"):
            self.verify()
        archive.unlink()
        with self.assertRaisesRegex(ValueError, "differs from lock"):
            self.verify()

    def test_archive_and_parent_symlinks(self):
        archive = self.archives["rustc"]
        saved = self.root / "saved.xz"
        archive.rename(saved)
        archive.symlink_to(saved)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()
        archive.unlink()
        saved.rename(archive)
        alias = self.root / "alias"
        alias.symlink_to(self.dist, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            stdlib.verify(self.repo, self.rust, alias)

    def test_changed_missing_and_symlinked_notice(self):
        notice = self.notice()
        notice.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "differs from locked archive"):
            self.verify()
        notice.unlink()
        with self.assertRaisesRegex(ValueError, "differs from locked archive"):
            self.verify()
        notice.symlink_to(self.lockfile)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()

    def test_installed_notice_parent_symlink(self):
        doc = self.notice().parent
        saved = self.root / "docs"
        doc.rename(saved)
        doc.symlink_to(saved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()

    def test_changed_missing_extra_or_symlinked_stdlib(self):
        lib = self.rust / self.toolchain / f"lib/rustlib/{stdlib.TARGET}/lib"
        original = lib / "libstd-fixture.rlib"
        data = original.read_bytes()
        original.write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "differs from locked archive"):
            self.verify()
        original.unlink()
        with self.assertRaisesRegex(ValueError, "differs from locked archive"):
            self.verify()
        original.write_bytes(data)
        extra = lib / "extra.rlib"
        extra.write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "extra installed"):
            self.verify()
        extra.unlink()
        extra.symlink_to(original)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()

    def test_pin_mismatch_dirty_and_untracked_lock(self):
        (self.repo / "pins.lock").write_text("rust 1.99.0\n")
        with self.assertRaisesRegex(ValueError, "disagrees"):
            self.verify()
        (self.repo / "pins.lock").write_text(f"rust {self.version}\n")
        self.lockfile.write_text(self.lockfile.read_text() + "\n")
        with self.assertRaisesRegex(ValueError, "bytes differ"):
            self.verify()
        stdlib.rust.provenance.git(self.repo, "rm", "--cached", "build/rust-dist.lock.json")
        stdlib.rust.provenance.git(self.repo, "commit", "-qm", "remove lock")
        with self.assertRaisesRegex(ValueError, "untracked"):
            self.verify()

    def test_wrong_component_identity(self):
        self.lock["components"]["rust-std"]["target"] = stdlib.HOST
        self.commit_lock()
        with self.assertRaisesRegex(ValueError, "component identity"):
            self.verify()

    def test_unsafe_duplicate_link_and_colliding_archive_members(self):
        p = self.prefixes["rustc"]
        for entries, message in (
                ([("../outside", b"bad", tarfile.REGTYPE)], "unsafe"),
                ([(p + "COPYRIGHT-library.html", b"a", tarfile.REGTYPE)] * 2, "duplicate"),
                ([(p + "COPYRIGHT-library.html", b"", tarfile.SYMTYPE)], "non-regular"),
                ([(p + "COPYRIGHT-library.html", b"", tarfile.LNKTYPE)], "non-regular"),
                ([(p + "licenses", b"a", tarfile.REGTYPE), (p + "licenses/MIT.txt", b"b", tarfile.REGTYPE)], "collision")):
            with self.subTest(message=message):
                self.archive("rustc", entries)
                self.lock["components"]["rustc"]["sha256"] = stdlib.rust.provenance.digest(self.archives["rustc"])
                self.commit_lock()
                with self.assertRaisesRegex(ValueError, message):
                    self.verify()

    def test_all_required_notices_must_exist_in_archive(self):
        p = self.prefixes["rustc"]
        self.archive("rustc", [(p + "COPYRIGHT-library.html", b"a", tarfile.REGTYPE)])
        self.lock["components"]["rustc"]["sha256"] = stdlib.rust.provenance.digest(self.archives["rustc"])
        self.commit_lock()
        with self.assertRaisesRegex(ValueError, "lacks required"):
            self.verify()

    def test_copy_reverification_requires_manifest_and_exact_bytes(self):
        out = self.root / "out"
        out.mkdir()
        payload = out / "notice.txt"
        payload.write_bytes(self.notice().read_bytes())
        log = out / ".copy-sources.tsv"
        log.write_text(f"notice.txt\t{self.notice()}\n")
        with patch.object(stdlib.rust.provenance, "source_roots", return_value=[]), patch.dict(
                os.environ, {"RUST_ROOT": str(self.rust), "RUST_NOTICE_CARGO_HOME": str(self.rust / "cargo")}):
            with self.assertRaisesRegex(ValueError, "lacks locked release"):
                stdlib.rust.provenance.validate_copies(self.repo, log)
            (out / "rust-stdlib-provenance.json").write_text(json.dumps(self.verify()))
            record = stdlib.rust.provenance.validate_copies(self.repo, log)
            self.assertEqual(record["files"][0]["verification"], "locked-release-archive-bytes")
            self.assertIn("member", record["files"][0])
            self.notice().write_bytes(b"mutated after verification")
            payload.write_bytes(self.notice().read_bytes())
            with self.assertRaisesRegex(ValueError, "changed after release"):
                stdlib.rust.provenance.validate_copies(self.repo, log)

    def test_cli_failure_no_manifest(self):
        self.archives["rust-std"].unlink()
        out = self.root / "provenance.json"
        result = subprocess.run([sys.executable, str(REPO / "build/notices-rust-stdlib.py"),
                                 str(self.repo), str(self.rust), str(self.dist), str(out)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Rust standard-library notice provenance:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(out.exists())

    def test_shell_failure_cleans_partial_output(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        python = bin_dir / "python3"
        python.write_text('#!/bin/sh\ncase "$1:$2" in *notices-provenance.py:trees) '
                          'printf "{}\\n" > "$5"; exit 0 ;; *notices-rust.py:*) '
                          'printf "{}\\n" > "$7"; exit 0 ;; esac\n'
                          f'exec "{sys.executable}" "$@"\n')
        python.chmod(0o755)
        destination = self.root / "notices"
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   PLAYPORT_BUILD=str(self.root / "build"), RUST_ROOT=str(self.rust), RUST_NOTICE_DIST=str(self.dist))
        result = subprocess.run(["bash", str(REPO / "build/notices-assemble.sh"), str(destination)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Rust standard-library notice provenance:", result.stderr)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob("notices.partial.*")), [])

    def rewrite_source(self, files=None, extra=(), identity=True):
        entries = [(self.prefixes["rust-src"] + path, data, tarfile.REGTYPE)
                   for path, data in (self.source_files if files is None else files).items()]
        self.archive("rust-src", entries + list(extra), identity=identity)
        self.lock["components"]["rust-src"]["sha256"] = stdlib.rust.provenance.digest(self.archives["rust-src"])
        self.commit_lock()

    def test_source_inventory_is_exact_read_only_and_path_independent(self):
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        record = self.verify()["source"]
        self.assertEqual(record["source_commit"], "a" * 40)
        self.assertEqual(len(record["files"]), len(self.source_files) + 2)
        for name, data in self.source_files.items():
            self.assertEqual(record["files"][name], {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
        self.assertNotIn(str(self.root), json.dumps(record))
        self.assertEqual(record["packages"][0]["name"], "std")
        self.assertIn("not collected notices", record["scope"])
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_source_notice_candidates_include_nested_and_unlicense(self):
        files = dict(self.source_files)
        files[stdlib.SOURCE + "library/vendor/fixture/UNLICENSE"] = b"public domain"
        files[stdlib.SOURCE + "library/backtrace/NOTICE.txt"] = b"credit"
        files[stdlib.SOURCE + "library/backtrace/src/lib.rs"] = b"not a notice file"
        self.rewrite_source(files)
        notices = self.verify()["source"]["notice_candidates"]
        for name in ("COPYRIGHT", "LICENSE-MIT", stdlib.SOURCE + "src/llvm-project/libunwind/LICENSE.TXT",
                     stdlib.SOURCE + "library/vendor/fixture/UNLICENSE", stdlib.SOURCE + "library/backtrace/NOTICE.txt"):
            self.assertEqual(notices[name]["member"], self.prefixes["rust-src"] + name)
            self.assertEqual(notices[name]["sha256"], hashlib.sha256(files[name]).hexdigest())
        self.assertNotIn(stdlib.SOURCE + "library/backtrace/src/lib.rs", notices)

    def collect_source(self, out, record=None):
        record = self.verify() if record is None else record
        origins = stdlib.collect_source_notices(self.dist, record, out)
        record["source"]["collected_notices"] = origins
        (out / "rust-stdlib-provenance.json").write_text(json.dumps(record))
        return record

    def test_source_notice_collection_is_exact_and_path_independent(self):
        out = self.root / "out"
        out.mkdir()
        before = {p: p.read_bytes() for folder in (self.repo, self.rust, self.dist)
                  for p in folder.rglob("*") if p.is_file()}
        record = self.collect_source(out)
        origins = record["source"]["collected_notices"]
        self.assertEqual(len(origins), len(record["source"]["notice_candidates"]))
        for name, origin in origins.items():
            self.assertEqual((out / name).read_bytes(), self.source_files[origin["source"]])
            self.assertEqual(origin["member"], self.prefixes["rust-src"] + origin["source"])
            self.assertEqual(origin["archive_sha256"], self.lock["components"]["rust-src"]["sha256"])
        self.assertNotIn(str(self.root), json.dumps(record))
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        stdlib.rust.provenance.inventory(out)

    def test_source_notice_flattening_collision_and_existing_output(self):
        files = dict(self.source_files)
        # Both basenames must be notice candidates to exercise flattening.
        files["a/LICENSE-b-COPYRIGHT"] = b"first"
        files["a-LICENSE/b/COPYRIGHT"] = b"second"
        self.rewrite_source(files)
        out = self.root / "out"
        out.mkdir()
        with self.assertRaisesRegex(ValueError, "colliding/invalid"):
            self.collect_source(out)
        self.assertEqual(list(out.iterdir()), [])
        self.rewrite_source()
        (out / "rust-source-COPYRIGHT").write_bytes(b"keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.collect_source(out)
        self.assertEqual({p.name: p.read_bytes() for p in out.iterdir()}, {"rust-source-COPYRIGHT": b"keep"})

    def test_source_notice_destination_symlinks(self):
        out = self.root / "out"
        out.mkdir()
        alias = self.root / "alias"
        alias.symlink_to(out, target_is_directory=True)
        for destination in (alias, alias / "nested"):
            with self.subTest(destination=destination), self.assertRaisesRegex(ValueError, "symlink"):
                self.collect_source(destination)
        (out / "rust-source-COPYRIGHT").symlink_to(self.lockfile)
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.collect_source(out)

    def test_source_archive_and_candidate_rechecked_before_copy(self):
        record = self.verify()
        out = self.root / "out"
        out.mkdir()
        self.archives["rust-src"].write_bytes(b"changed after verification")
        with self.assertRaisesRegex(ValueError, "differs from lock"):
            self.collect_source(out, record)
        self.assertEqual(list(out.iterdir()), [])
        self.rewrite_source()
        record = self.verify()
        record["source"]["notice_candidates"]["COPYRIGHT"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "changed after verification"):
            self.collect_source(out, record)
        self.assertEqual(list(out.iterdir()), [])

    def test_source_notice_write_failure_rolls_back_only_own_files(self):
        out = self.root / "out"
        out.mkdir()
        keep = out / "unrelated.txt"
        keep.write_bytes(b"keep")
        original = Path.open
        writes = 0

        def fail_second(path, mode="r", *args, **kwargs):
            nonlocal writes
            if mode == "xb":
                writes += 1
                if writes == 2:
                    raise OSError("fixture write failure")
            return original(path, mode, *args, **kwargs)

        with patch.object(Path, "open", fail_second), self.assertRaisesRegex(OSError, "fixture write failure"):
            self.collect_source(out)
        self.assertEqual(list(out.iterdir()), [keep])
        self.assertEqual(keep.read_bytes(), b"keep")

    def test_source_notice_inventory_refuses_missing_extra_changed_and_symlinked(self):
        out = self.root / "out"
        out.mkdir()
        self.collect_source(out)
        payload = out / "rust-source-COPYRIGHT"
        data = payload.read_bytes()
        payload.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "changed after collection"):
            stdlib.rust.provenance.inventory(out)
        payload.unlink()
        with self.assertRaisesRegex(ValueError, "payload set"):
            stdlib.rust.provenance.inventory(out)
        payload.symlink_to(self.lockfile)
        with self.assertRaisesRegex(ValueError, "not a regular notice"):
            stdlib.rust.provenance.inventory(out)
        payload.unlink()
        payload.write_bytes(data)
        extra = out / "rust-source-extra"
        extra.write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "payload set"):
            stdlib.rust.provenance.inventory(out)

    def test_source_notice_inventory_requires_complete_origin_map(self):
        out = self.root / "out"
        out.mkdir()
        record = self.collect_source(out)
        manifest = out / "rust-stdlib-provenance.json"
        original = manifest.read_bytes()
        for field, value in (("source", "LICENSE-MIT"), ("member", "wrong"),
                             ("archive_sha256", "0" * 64), ("sha256", "0" * 64), ("size", 999)):
            with self.subTest(field=field):
                record = json.loads(original)
                record["source"]["collected_notices"]["rust-source-COPYRIGHT"][field] = value
                manifest.write_text(json.dumps(record))
                with self.assertRaisesRegex(ValueError, "omits/duplicates|origin differs"):
                    stdlib.rust.provenance.inventory(out)
        record = json.loads(original)
        del record["source"]["collected_notices"]
        manifest.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, "lack collection provenance"):
            stdlib.rust.provenance.inventory(out)
        manifest.unlink()
        with self.assertRaisesRegex(ValueError, "lack release provenance"):
            stdlib.rust.provenance.inventory(out)

    def test_source_notice_cli_collects_superset_and_manifest_failure_rolls_back(self):
        out = self.root / "out"
        out.mkdir()
        manifest = out / "rust-stdlib-provenance.json"
        args = [sys.executable, str(REPO / "build/notices-rust-stdlib.py"), str(self.repo),
                str(self.rust), str(self.dist), str(manifest), "--collect-source-notices", str(out)]
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(manifest.read_text())
        self.assertEqual(record["schema"], 4)
        self.assertIn("not applicability", record["source"]["scope"])
        stdlib.rust.provenance.inventory(out)
        for path in out.iterdir():
            path.unlink()
        collision_args = args[:5] + [str(out / "rust-source-COPYRIGHT")] + args[6:]
        result = subprocess.run(collision_args, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("provenance output collides", result.stderr)
        self.assertEqual(list(out.iterdir()), [])
        manifest.mkdir()  # Collection succeeds, but the manifest cannot be written.
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(list(out.iterdir()), [manifest])

    def test_source_archive_missing_corrupt_and_symlinked(self):
        archive = self.archives["rust-src"]
        original = archive.read_bytes()
        archive.write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "differs from lock"):
            self.verify()
        archive.unlink()
        with self.assertRaisesRegex(ValueError, "differs from lock"):
            self.verify()
        saved = self.root / "source.xz"
        saved.write_bytes(original)
        archive.symlink_to(saved)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()

    def test_source_requires_core_sources_and_licences(self):
        for name in ("COPYRIGHT", "LICENSE-MIT", stdlib.SOURCE + "library/core/src/lib.rs",
                     stdlib.SOURCE + "library/Cargo.lock", stdlib.SOURCE + "src/llvm-project/libunwind/LICENSE.TXT"):
            with self.subTest(name=name):
                files = dict(self.source_files)
                del files[name]
                self.rewrite_source(files)
                with self.assertRaisesRegex(ValueError, "lacks required source/licence"):
                    self.verify()

    def test_source_archive_unsafe_duplicate_link_collision_and_wrong_root(self):
        p = self.prefixes["rust-src"]
        for extra, message in (
                ([("../outside", b"bad", tarfile.REGTYPE)], "unsafe"),
                ([(p + "COPYRIGHT", b"duplicate", tarfile.REGTYPE)], "duplicate"),
                ([(p + "link", b"", tarfile.SYMTYPE)], "non-regular"),
                ([(p + "link", b"", tarfile.LNKTYPE)], "non-regular"),
                ([(p + "parent", b"file", tarfile.REGTYPE), (p + "parent/child", b"file", tarfile.REGTYPE)], "collision"),
                ([("other-root/file", b"file", tarfile.REGTYPE)], "unexpected Rust archive root")):
            with self.subTest(message=message):
                self.rewrite_source(extra=extra)
                with self.assertRaisesRegex(ValueError, message):
                    self.verify()

    def test_all_archives_must_match_locked_release_and_source_commit(self):
        for component in self.archives:
            original = self.archives[component].read_bytes()
            checksum = self.lock["components"][component]["sha256"]
            with tarfile.open(self.archives[component]) as archive:
                entries = [(member.name, archive.extractfile(member).read(), tarfile.REGTYPE)
                           for member in archive if member.isfile()]
            for member, data in (("version", b"1.99.0 (bbbbbbbbb 2026-09-02)"),
                                 ("git-commit-hash", b"b" * 40), ("version", None)):
                with self.subTest(component=component, member=member, data=data):
                    changed = [(name, data if Path(name).name == member else payload, kind)
                               for name, payload, kind in entries if data is not None or Path(name).name != member]
                    self.archive(component, changed, identity=False)
                    self.lock["components"][component]["sha256"] = stdlib.rust.provenance.digest(self.archives[component])
                    self.commit_lock()
                    with self.assertRaisesRegex(ValueError, "release/source identity"):
                        self.verify()
            self.archives[component].write_bytes(original)
            self.lock["components"][component]["sha256"] = checksum
            self.commit_lock()

    def test_source_component_and_locked_commit_identity(self):
        self.lock["components"]["rust-src"]["target"] = stdlib.TARGET
        self.commit_lock()
        with self.assertRaisesRegex(ValueError, "source component identity"):
            self.verify()
        self.lock["components"]["rust-src"]["target"] = "*"
        self.lock["source_commit"] = "not-a-commit"
        self.commit_lock()
        with self.assertRaisesRegex(ValueError, "invalid locked Rust source commit"):
            self.verify()
        self.lock["source_commit"] = "b" * 40
        self.commit_lock()
        with self.assertRaisesRegex(ValueError, "release identity disagrees"):
            self.verify()

    def declared_source(self, declaration, payload="attribution.txt"):
        files = dict(self.source_files)
        manifest = stdlib.SOURCE + "library/std/Cargo.toml"
        files[manifest] += ("license-file = " + declaration + "\n").encode()
        if payload is not None:
            files[stdlib.SOURCE + "library/std/" + payload] = b"declared attribution\r\n"
        return files, manifest

    def test_declared_notice_without_candidate_basename_is_collected(self):
        files, manifest = self.declared_source('"attribution.txt"')
        self.rewrite_source(files)
        out = self.root / "out"
        out.mkdir()
        record = self.collect_source(out)
        path = stdlib.SOURCE + "library/std/attribution.txt"
        package = record["source"]["packages"][0]
        self.assertEqual(package["license_file"], "attribution.txt")
        self.assertEqual(package["license_file_source"], path)
        self.assertEqual(record["source"]["notice_candidates"][path]["declared_by"], [manifest])
        name = "rust-source-" + path.replace("/", "-")
        self.assertEqual((out / name).read_bytes(), files[path])
        self.assertEqual(record["source"]["collected_notices"][name]["declared_by"], [manifest])
        self.assertNotIn(str(self.root), json.dumps(record))
        stdlib.rust.provenance.inventory(out)

    def test_parent_relative_and_shared_declarations_are_deduplicated(self):
        files, manifest = self.declared_source('".././credits.txt"', payload=None)
        shared = stdlib.SOURCE + "library/credits.txt"
        files[shared] = b"shared copyright"
        second = stdlib.SOURCE + "library/vendor/fixture/Cargo.toml"
        files[second] = (b'[package]\nname = "fixture"\nversion = "1.0.0"\n'
                         b'license-file = "../../credits.txt"\n')
        self.rewrite_source(files)
        out = self.root / "out"
        out.mkdir()
        record = self.collect_source(out)
        self.assertEqual(record["source"]["notice_candidates"][shared]["declared_by"], [manifest, second])
        self.assertEqual(sum(o["source"] == shared for o in record["source"]["collected_notices"].values()), 1)
        stdlib.rust.provenance.inventory(out)

    def test_declared_filename_candidate_is_copied_only_once(self):
        files, manifest = self.declared_source('"LICENSE"', payload="LICENSE")
        self.rewrite_source(files)
        out = self.root / "out"
        out.mkdir()
        record = self.collect_source(out)
        path = stdlib.SOURCE + "library/std/LICENSE"
        self.assertEqual(record["source"]["notice_candidates"][path]["declared_by"], [manifest])
        self.assertEqual(sum(o["source"] == path for o in record["source"]["collected_notices"].values()), 1)
        stdlib.rust.provenance.inventory(out)

    def test_missing_and_directory_declared_notices_fail_closed(self):
        for declaration in ('"missing.txt"', '"src"'):
            with self.subTest(declaration=declaration):
                files, _ = self.declared_source(declaration, payload=None)
                self.rewrite_source(files)
                with self.assertRaisesRegex(ValueError, "lacks regular archive payload"):
                    self.verify()

    def test_unsafe_and_unsupported_declarations_fail_closed(self):
        for declaration in ('""', '"/outside"', "'C:/outside'", "'path\\file'",
                            '"../../../../../../../../outside"', '"bad\\npath"',
                            '"attribution.txt/"', '"attribution.txt/."',
                            '42', 'false', '{ workspace = true }', '[]'):
            with self.subTest(declaration=declaration):
                files, _ = self.declared_source(declaration)
                self.rewrite_source(files)
                with self.assertRaisesRegex(ValueError, "license-file"):
                    self.verify()

    def test_declared_notice_flattening_collision_is_refused(self):
        files, _ = self.declared_source('"../credits-a.txt"', payload=None)
        path = stdlib.SOURCE + "library/credits-a.txt"
        files[path] = b"first"
        second = stdlib.SOURCE + "library-credits/a.txt"
        files[second] = b"second"
        manifest = stdlib.SOURCE + "library/vendor/fixture/Cargo.toml"
        files[manifest] = (b'[package]\nname = "fixture"\nversion = "1.0.0"\n'
                           b'license-file = "../../../library-credits/a.txt"\n')
        self.rewrite_source(files)
        out = self.root / "out"
        out.mkdir()
        with self.assertRaisesRegex(ValueError, "colliding/invalid"):
            self.collect_source(out)
        self.assertEqual(list(out.iterdir()), [])

    def test_inventory_rechecks_declared_notice_coverage_and_origins(self):
        files, _ = self.declared_source('"attribution.txt"')
        self.rewrite_source(files)
        out = self.root / "out"
        out.mkdir()
        self.collect_source(out)
        manifest = out / "rust-stdlib-provenance.json"
        original = manifest.read_bytes()
        path = stdlib.SOURCE + "library/std/attribution.txt"
        name = "rust-source-" + path.replace("/", "-")
        for mutation in ("missing-reference", "candidate-declaration", "origin-declaration", "file-hash", "omit"):
            with self.subTest(mutation=mutation):
                record = json.loads(original)
                source = record["source"]
                if mutation == "missing-reference":
                    del source["packages"][0]["license_file_source"]
                elif mutation == "candidate-declaration":
                    del source["notice_candidates"][path]["declared_by"]
                elif mutation == "origin-declaration":
                    del source["collected_notices"][name]["declared_by"]
                elif mutation == "file-hash":
                    source["files"][path]["sha256"] = "0" * 64
                else:
                    del source["notice_candidates"][path]
                    del source["collected_notices"][name]
                    (out / name).unlink()
                manifest.write_text(json.dumps(record))
                with self.assertRaisesRegex(ValueError, "declared license-file|declaration/file|origin differs"):
                    stdlib.rust.provenance.inventory(out)
                if mutation == "omit":
                    (out / name).write_bytes(files[path])
        manifest.write_bytes(original)
        stdlib.rust.provenance.inventory(out)

    def test_bad_declaration_cli_leaves_no_notices_or_manifest(self):
        files, _ = self.declared_source('{ workspace = true }', payload=None)
        self.rewrite_source(files)
        out = self.root / "out"
        out.mkdir()
        result = subprocess.run([sys.executable, str(REPO / "build/notices-rust-stdlib.py"),
                                 str(self.repo), str(self.rust), str(self.dist), str(out / "provenance.json"),
                                 "--collect-source-notices", str(out)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid/unsupported Rust license-file", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(list(out.iterdir()), [])

    def test_malformed_source_manifest_fails_without_cli_output(self):
        files = dict(self.source_files)
        files[stdlib.SOURCE + "library/std/Cargo.toml"] = b"not valid TOML"
        self.rewrite_source(files)
        out = self.root / "source-provenance.json"
        result = subprocess.run([sys.executable, str(REPO / "build/notices-rust-stdlib.py"),
                                 str(self.repo), str(self.rust), str(self.dist), str(out)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
