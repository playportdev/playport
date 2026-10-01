# SPDX-License-Identifier: GPL-3.0-or-later
"""MinGW notices are pinned source bytes, never a claim about linked members."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("notices_mingw_test", REPO / "build/notices-mingw.py")
mingw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mingw)
provenance = mingw.provenance


class MinGWNotices(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.repo, self.source, self.llvm = (self.root / n for n in ("repo", "source", "llvm"))
        for tree in (self.repo, self.source, self.llvm):
            tree.mkdir()
            for args in (("init", "-q"), ("config", "user.name", "fixture"),
                         ("config", "user.email", "fixture@localhost")):
                provenance.git(tree, *args)
        for path in (*mingw.REQUIRED, "unused/LICENSE", "nested/NOTICE.txt"):
            file = self.source / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"fixture copyright\r\n" + path.encode() + b"\xff\n")
        (self.source / "source.c").write_text("source, not a notice\n")
        self.source_commit = self.commit(self.source)
        self.script = self.llvm / "build-mingw-w64.sh"
        self.script.write_text(f": ${{MINGW_W64_VERSION:={self.source_commit}}}\n")
        self.llvm_commit = self.commit(self.llvm)
        self.lock = {
            "schema": 1,
            "llvm_mingw": {"release": "fixture", "repository": "fixture", "commit": self.llvm_commit,
                           "script": self.script.name, "script_sha256": mingw.sha(self.script.read_bytes())},
            "mingw_w64": {"repository": "fixture", "commit": self.source_commit},
        }
        self.lock_path = self.repo / "build/mingw-notices.lock.json"
        self.lock_path.parent.mkdir()
        self.save_lock()
        self.toolchain = self.root / "toolchain"
        for target in mingw.TARGETS:
            for name, source in mingw.INSTALLED.items():
                file = self.toolchain / target / "share/mingw32" / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes((self.source / source).read_bytes())
        self.out = self.root / "out"
        self.out.mkdir()
        self.scratch = self.root / "scratch"

    def tearDown(self):
        self.temp.cleanup()

    def commit(self, tree):
        provenance.git(tree, "add", ".")
        provenance.git(tree, "commit", "-qm", "fixture")
        return provenance.git(tree, "rev-parse", "HEAD").decode().strip()

    def save_lock(self):
        self.lock_path.write_text(json.dumps(self.lock))
        self.commit(self.repo)

    def collect(self):
        return mingw.collect(self.repo, self.source, self.llvm, self.toolchain, self.scratch, self.out)

    def reject(self, match=None):
        with self.assertRaisesRegex((ValueError, OSError), match or ".*"):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [])

    def test_exact_bytes_recursive_superset_readonly_and_path_independent(self):
        before = {t: provenance.git(t, "status", "--porcelain") for t in (self.repo, self.source, self.llvm)}
        record = self.collect()
        expected = set(mingw.REQUIRED) | {"unused/LICENSE", "nested/NOTICE.txt"}
        self.assertEqual(set(record["notice_candidates"]), expected)
        self.assertEqual(len(record["installed_notices"]), 15)
        self.assertNotIn(str(self.root), json.dumps(record))
        for name, origin in record["collected_notices"].items():
            self.assertEqual((self.out / name).read_bytes(), (self.source / origin["source"]).read_bytes())
        provenance.inventory(self.out)
        for tree, status in before.items():
            self.assertEqual(provenance.git(tree, "status", "--porcelain"), status)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_lock_must_be_committed_regular_and_full_identity(self):
        original = self.lock_path.read_bytes()
        self.lock_path.write_bytes(original + b" ")
        self.reject("differ")
        self.lock_path.write_bytes(original)
        self.lock["mingw_w64"]["commit"] = "HEAD"
        self.save_lock()
        self.reject("full commits")
        self.lock_path.unlink()
        self.lock_path.symlink_to(self.script)
        self.reject("non-symlink")

    def test_dirty_wrong_and_arbitrary_descendant_source_trees(self):
        for tree, file in ((self.source, self.source / "source.c"), (self.llvm, self.script)):
            original = file.read_bytes()
            file.write_bytes(original + b"changed\n")
            self.reject()
            self.commit(tree)
            self.reject("exact pin")
            provenance.git(tree, "reset", "--hard", self.source_commit if tree == self.source else self.llvm_commit)

    def test_build_script_checksum_and_named_revision_are_required(self):
        self.lock["llvm_mingw"]["script_sha256"] = "0" * 64
        self.save_lock()
        self.reject("checksum")
        self.script.write_text(": ${MINGW_W64_VERSION:=" + "0" * 40 + "}\n")
        self.lock["llvm_mingw"]["commit"] = self.commit(self.llvm)
        self.lock["llvm_mingw"]["script_sha256"] = mingw.sha(self.script.read_bytes())
        self.save_lock()
        self.reject("does not name")

    def test_missing_required_and_untracked_notice_inputs(self):
        missing = self.source / mingw.REQUIRED[0]
        missing.unlink()
        self.lock["mingw_w64"]["commit"] = self.commit(self.source)
        # Update the committed script too so the failure reaches notice coverage.
        self.script.write_text(f": ${{MINGW_W64_VERSION:={self.lock['mingw_w64']['commit']}}}\n")
        self.lock["llvm_mingw"]["commit"] = self.commit(self.llvm)
        self.lock["llvm_mingw"]["script_sha256"] = mingw.sha(self.script.read_bytes())
        self.save_lock()
        self.reject("required")
        missing.write_text("untracked replacement\n")
        self.reject("required")

    def test_installed_notices_missing_changed_and_symlinked(self):
        for target in mingw.TARGETS:
            file = self.toolchain / target / "share/mingw32/COPYING.MinGW-w64-runtime.txt"
            original = file.read_bytes()
            file.unlink()
            self.reject("regular")
            file.write_bytes(original + b"changed")
            self.reject("differs")
            file.unlink()
            file.symlink_to(self.source / mingw.INSTALLED[file.name])
            self.reject("non-symlink")
            file.unlink()
            file.write_bytes(original)

    def test_input_and_output_symlink_parents_are_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        for source, llvm, toolchain, out in (
            (alias / "source", self.llvm, self.toolchain, self.out),
            (self.source, alias / "llvm", self.toolchain, self.out),
            (self.source, self.llvm, alias / "toolchain", self.out),
            (self.source, self.llvm, self.toolchain, alias / "out"),
        ):
            with self.assertRaisesRegex(ValueError, "symlink"):
                mingw.collect(self.repo, source, llvm, toolchain, self.scratch, out)
            self.assertEqual(list(self.out.iterdir()), [])

    def test_scratch_and_output_cannot_modify_input_trees(self):
        for root in (self.source, self.llvm, self.toolchain):
            with self.assertRaisesRegex(ValueError, "inside an input tree"):
                mingw.collect(self.repo, self.source, self.llvm, self.toolchain, root / "scratch", self.out)
            self.assertFalse((root / "scratch").exists())
            with self.assertRaisesRegex(ValueError, "inside an input tree"):
                mingw.collect(self.repo, self.source, self.llvm, self.toolchain, self.scratch, root)
            self.assertEqual(list(self.out.iterdir()), [])

    def test_existing_and_symlinked_outputs_are_preserved(self):
        name = "mingw-source-COPYING"
        saved = self.out / name
        saved.write_bytes(b"keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.collect()
        self.assertEqual(saved.read_bytes(), b"keep")
        saved.unlink()
        saved.symlink_to(self.root / "missing")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.collect()
        self.assertTrue(saved.is_symlink())
        self.assertEqual(list(self.out.iterdir()), [saved])

    def test_failed_manifest_write_rolls_back_only_created_outputs(self):
        saved = self.out / "keep"
        saved.write_bytes(b"keep")
        original = Path.open
        def fail(path, *args, **kwargs):
            if path == self.out / mingw.MANIFEST:
                raise OSError("fixture write failure")
            return original(path, *args, **kwargs)
        with patch.object(Path, "open", fail), self.assertRaisesRegex(OSError, "write failure"):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [saved])
        self.assertEqual(saved.read_bytes(), b"keep")

    def test_inventory_rejects_missing_extra_changed_and_symlinked_payloads(self):
        record = self.collect()
        file = self.out / next(iter(record["collected_notices"]))
        original = file.read_bytes()
        file.unlink()
        with self.assertRaisesRegex(ValueError, "payload set"):
            provenance.inventory(self.out)
        file.write_bytes(original + b"changed")
        with self.assertRaisesRegex(ValueError, "changed"):
            provenance.inventory(self.out)
        file.unlink()
        file.symlink_to(self.source / record["collected_notices"][file.name]["source"])
        with self.assertRaisesRegex(ValueError, "regular"):
            provenance.inventory(self.out)
        file.unlink()
        file.write_bytes(original)
        (self.out / "mingw-source-extra").write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "payload set"):
            provenance.inventory(self.out)

    def test_inventory_rejects_manifest_coverage_origin_and_installed_omissions(self):
        record = self.collect()
        for mutate in (
            lambda r: r["collected_notices"].pop(next(iter(r["collected_notices"]))),
            lambda r: r["notice_candidates"].pop("COPYING"),
            lambda r: r["installed_notices"].pop(next(iter(r["installed_notices"]))),
            lambda r: r["collected_notices"]["mingw-source-COPYING"].update(source="AUTHORS"),
            lambda r: r["trees"]["mingw_w64"].update(base_commit="0" * 40),
        ):
            changed = copy.deepcopy(record)
            mutate(changed)
            (self.out / mingw.MANIFEST).write_text(json.dumps(changed))
            with self.assertRaises(ValueError):
                provenance.inventory(self.out)
        (self.out / mingw.MANIFEST).unlink()
        with self.assertRaisesRegex(ValueError, "lack source provenance"):
            provenance.inventory(self.out)

    def test_flattened_collisions_unsafe_and_nonregular_committed_notices(self):
        for path in ("a/LICENSE-COPYING", "a-LICENSE/COPYING"):
            file = self.source / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("collision\n")
        self.lock["mingw_w64"]["commit"] = self.commit(self.source)
        self.script.write_text(f": ${{MINGW_W64_VERSION:={self.lock['mingw_w64']['commit']}}}\n")
        self.lock["llvm_mingw"]["commit"] = self.commit(self.llvm)
        self.lock["llvm_mingw"]["script_sha256"] = mingw.sha(self.script.read_bytes())
        self.save_lock()
        self.reject("duplicate flattened")
        # The same locked-source path checks reject committed symlink notices.
        (self.source / "a/LICENSE-COPYING").unlink()
        (self.source / "a/LICENSE-COPYING").symlink_to("../COPYING")
        self.lock["mingw_w64"]["commit"] = self.commit(self.source)
        self.script.write_text(f": ${{MINGW_W64_VERSION:={self.lock['mingw_w64']['commit']}}}\n")
        self.lock["llvm_mingw"]["commit"] = self.commit(self.llvm)
        self.lock["llvm_mingw"]["script_sha256"] = mingw.sha(self.script.read_bytes())
        self.save_lock()
        self.reject("non-regular")
        for path in ("/LICENSE", "../COPYING", "C:/COPYING", "bad\t/LICENSE", "a\\LICENSE"):
            self.assertFalse(mingw.safe_source(path))

    def test_shell_failure_cleans_partial_destination(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        python = bin_dir / "python3"
        python.write_text('#!/bin/sh\n'
                          'case "$1" in *notices-provenance.py|*notices-rust.py|*notices-rust-stdlib.py) '
                          'exit 0 ;; esac\n'
                          f'exec "{sys.executable}" "$@"\n')
        python.chmod(0o755)
        destination = self.root / "notices"
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   PLAYPORT_BUILD=str(self.root / "build"), MINGW_SOURCE=str(self.root / "missing"),
                   LLVM_MINGW_SOURCE=str(self.llvm), LLVM_MINGW=str(self.toolchain))
        result = subprocess.run(["bash", str(REPO / "build/notices-assemble.sh"), str(destination)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MinGW notice collection", result.stderr)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob("notices.partial.*")), [])

    def test_cli_success_and_failure_without_partial_payloads(self):
        args = [sys.executable, str(REPO / "build/notices-mingw.py"),
                *map(str, (self.repo, self.source, self.llvm, self.toolchain, self.scratch, self.out))]
        subprocess.run(args, check=True, capture_output=True)
        provenance.inventory(self.out)
        for file in self.out.iterdir():
            file.unlink()
        self.script.write_text("changed\n")
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MinGW notice collection", result.stderr)
        self.assertEqual(list(self.out.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
