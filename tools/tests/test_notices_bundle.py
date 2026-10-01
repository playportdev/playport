# SPDX-License-Identifier: GPL-3.0-or-later
"""The app's Licenses/ is a whole `pp notices` output: build/notices-bundle.py
refuses any defect and stages without debris, and `pp verify` fails a
distribution without a release-reviewed bundle."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bundle = load("notices_bundle", "build/notices-bundle.py")
verify = load("verify_ipa", "build/verify-ipa.py")


def make(root, files, status="incomplete-inventory"):
    """A bundle laid out as build/notices-assemble.sh publishes one."""
    root.mkdir(parents=True)
    for name, body in files.items():
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_bytes(body)
    entries = [{"name": n, "size": len(b), "sha256": hashlib.sha256(b).hexdigest()} for n, b in sorted(files.items())]
    (root / "inventory.json").write_text(json.dumps({"schema": 1, "status": status, "files": entries}))
    resum(root)
    return root


def resum(root):
    names = sorted(p.relative_to(root).as_posix() for p in root.rglob("*")
                   if p.is_file() and p != root / "SHA256SUMS")
    (root / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256((root / n).read_bytes()).hexdigest()}  ./{n}\n" for n in names))


FILES = {"Playport-LICENSE.txt": b"GPL\n", "wine-COPYING.LIB": b"LGPL\r\n\xff",
         "llvm-runtime/SHA256SUMS": b"inner sums\n", "llvm-runtime/libcxx-LICENSE.TXT": b"Apache\n"}


class Bundle(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.src = make(self.root / "notices", FILES)

    def tearDown(self):
        self.temp.cleanup()

    def refused(self, pattern, root=None, **kw):
        with self.assertRaisesRegex(ValueError, pattern):
            bundle.check(root or self.src, **kw)

    def test_a_whole_bundle_passes_with_its_status(self):
        r = bundle.check(self.src)
        self.assertEqual(r, {"status": "incomplete-inventory", "files": 4,
                             "bytes": sum(len(b) for b in FILES.values())})

    def test_distribution_needs_a_release_reviewed_inventory(self):
        self.refused("not distributable", distribution=True)
        ready = make(self.root / "ready", FILES, status=bundle.RELEASE_STATUS)
        self.assertEqual(bundle.check(ready, distribution=True)["status"], bundle.RELEASE_STATUS)

    def test_a_missing_file_fails(self):
        (self.src / "wine-COPYING.LIB").unlink()
        self.refused("lists missing files: wine-COPYING.LIB")

    def test_a_changed_file_fails(self):
        (self.src / "llvm-runtime/libcxx-LICENSE.TXT").write_bytes(b"Apache!\n")
        self.refused("differ from SHA256SUMS: llvm-runtime/libcxx-LICENSE.TXT")

    def test_a_changed_file_with_new_sums_still_disagrees_with_the_inventory(self):
        (self.src / "Playport-LICENSE.txt").write_bytes(b"not the GPL\n")
        resum(self.src)
        self.refused("records Playport-LICENSE.txt differently")

    def test_an_unlisted_file_fails(self):
        (self.src / "extra.txt").write_bytes(b"x")
        self.refused("not in SHA256SUMS: extra.txt")
        resum(self.src)
        self.refused("inventory.json and the files differ: extra.txt")

    def test_an_inventory_entry_without_a_file_fails(self):
        data = json.loads((self.src / "inventory.json").read_text())
        data["files"].append({"name": "gone.txt", "size": 1, "sha256": "0" * 64})
        (self.src / "inventory.json").write_text(json.dumps(data))
        resum(self.src)
        self.refused("inventory.json and the files differ: gone.txt")

    def test_symlinks_and_special_files_fail(self):
        (self.src / "link.txt").symlink_to("Playport-LICENSE.txt")
        self.refused("symlink: link.txt")
        (self.src / "link.txt").unlink()
        (self.src / "dir-link").symlink_to("llvm-runtime")
        self.refused("symlink: dir-link")
        (self.src / "dir-link").unlink()
        os.mkfifo(self.src / "fifo")
        self.refused("not a regular file: fifo")

    def test_a_symlinked_bundle_fails(self):
        (self.root / "link").symlink_to(self.src)
        self.refused("not a directory", root=self.root / "link")

    def test_an_empty_directory_fails(self):
        (self.src / "empty").mkdir()
        self.refused("empty directory: empty")

    def test_malformed_unsafe_and_duplicate_sums_fail(self):
        sums = (self.src / "SHA256SUMS").read_text()
        for text, pattern in ((sums + "junk\n", "malformed"),
                              (sums + "0" * 64 + "  ./../escape\n", "unsafe"),
                              (sums + sums.splitlines()[0] + "\n", "twice"),
                              (sums + "0" * 64 + "  ./SHA256SUMS\n", "unsafe")):
            (self.src / "SHA256SUMS").write_text(text)
            self.refused(pattern)

    def test_missing_or_malformed_manifests_fail(self):
        (self.src / "inventory.json").write_text('{"schema": 2}')
        resum(self.src)
        self.refused("not a schema 1 inventory")
        (self.src / "inventory.json").unlink()
        resum(self.src)
        self.refused("missing inventory.json")
        fresh = make(self.root / "fresh", FILES)
        (fresh / "SHA256SUMS").unlink()
        self.refused("missing SHA256SUMS", root=fresh)

    def test_stage_copies_byte_for_byte_and_replaces(self):
        dest = self.root / "app/Staged/Licenses"
        dest.mkdir(parents=True)
        (dest / "stale.txt").write_bytes(b"old")
        bundle.stage(self.src, dest)
        self.assertEqual(bundle.check(dest), bundle.check(self.src))
        self.assertFalse((dest / "stale.txt").exists())
        for name, body in FILES.items():
            self.assertEqual((dest / name).read_bytes(), body)
        self.assertEqual(sorted(p.name for p in dest.parent.iterdir()), ["Licenses"])

    def test_a_failed_stage_leaves_the_destination_as_it_was(self):
        dest = self.root / "app/Staged/Licenses"
        dest.mkdir(parents=True)
        (dest / "kept.txt").write_bytes(b"kept")
        (self.src / "Playport-LICENSE.txt").write_bytes(b"tampered\n")
        with self.assertRaises(ValueError):
            bundle.stage(self.src, dest)
        self.assertEqual(sorted(p.name for p in dest.iterdir()), ["kept.txt"])
        self.assertEqual(sorted(p.name for p in dest.parent.iterdir()), ["Licenses"])

    def test_stage_refuses_overlap_and_a_file_destination(self):
        with self.assertRaisesRegex(ValueError, "overlap"):
            bundle.stage(self.src, self.src / "Licenses")
        (self.root / "file").write_bytes(b"x")
        with self.assertRaisesRegex(ValueError, "not a directory"):
            bundle.stage(self.src, self.root / "file")

    def test_cli(self):
        run = lambda *a: subprocess.run([sys.executable, str(REPO / "build/notices-bundle.py"), *map(str, a)],
                                        capture_output=True, text=True)
        r = run("check", self.src)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("4 files", r.stdout)
        self.assertIn("not distributable", r.stdout)
        self.assertNotEqual(run("check", self.src, "--distribution").returncode, 0)
        self.assertEqual(run("stage", self.src, self.root / "out").returncode, 0)
        (self.src / "wine-COPYING.LIB").unlink()
        r = run("stage", self.src, self.root / "out2")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("notice bundle:", r.stderr)
        self.assertFalse((self.root / "out2").exists())


class Verify(unittest.TestCase):
    """build/verify-ipa.py's notices check, on an unpacked app."""

    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.app = self.root / "Playport.app"
        self.app.mkdir()
        self.src = make(self.root / "notices", FILES)
        verify.failures.clear()

    def tearDown(self):
        verify.failures.clear()
        self.temp.cleanup()

    def run_check(self, **kw):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            verify.notice_checks(self.app, **kw)
        return list(verify.failures), out.getvalue()

    def test_no_licenses_is_reported_and_fails_only_a_distribution(self):
        failures, out = self.run_check()
        self.assertEqual(failures, [])
        self.assertIn("not distributable", out)
        self.assertTrue(self.run_check(distribution=True)[0])
        verify.failures.clear()
        self.assertTrue(self.run_check(notices=self.src)[0])

    def test_a_bundled_incomplete_inventory_passes_until_a_distribution(self):
        bundle.stage(self.src, self.app / "Licenses")
        failures, out = self.run_check(notices=self.src)
        self.assertEqual(failures, [])
        self.assertIn("status incomplete-inventory (not distributable)", out)
        failures, _ = self.run_check(notices=self.src, distribution=True)
        self.assertEqual(len(failures), 2)
        self.assertIn("components.json", failures[0])
        self.assertIn("release-reviewed", failures[1])

    def test_a_tampered_or_different_bundle_fails(self):
        bundle.stage(self.src, self.app / "Licenses")
        other = make(self.root / "other", {**FILES, "Playport-LICENSE.txt": b"other\n"})
        self.assertTrue(self.run_check(notices=other)[0])
        verify.failures.clear()
        (self.app / "Licenses/wine-COPYING.LIB").write_bytes(b"changed")
        failures, _ = self.run_check()
        self.assertTrue(failures)
        self.assertIn("SHA256SUMS", failures[0])

    def test_a_distribution_needs_an_app_selection(self):
        ready = make(self.root / "ready", FILES, status=bundle.RELEASE_STATUS)
        bundle.stage(ready, self.app / "Licenses")
        failures, _ = self.run_check(notices=ready, distribution=True)
        self.assertEqual(len(failures), 1)
        self.assertIn("components.json", failures[0])

if __name__ == "__main__":
    unittest.main()
