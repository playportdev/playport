# SPDX-License-Identifier: GPL-3.0-or-later
"""Khronos notices retain per-checkout attribution and declared source origins."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("khronos_notices", REPO / "build/notices-khronos.py")
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)
p = notices.provenance


def commit(tree):
    p.git(tree, "add", ".")
    p.git(tree, "commit", "-qm", "fixture")


class KhronosNotices(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.out = self.root / "out"
        self.out.mkdir()
        self.components = {name: self.root / name for name in notices.ROOTS}
        self.repositories = []
        for component, roots in notices.ROOTS.items():
            paths = {".", *roots}
            if component == "dxvk":
                paths.add("subprojects/dxbc-spirv")
            else:
                paths.update(("subprojects/dxil-spirv", "subprojects/dxil-spirv/subprojects/dxbc-spirv"))
            repos = [self.components[component] / name for name in paths]
            for tree in repos:
                tree.mkdir(parents=True, exist_ok=True)
                for args in (("init", "-q"), ("config", "user.name", "fixture"),
                             ("config", "user.email", "fixture@localhost")):
                    p.git(tree, *args)
            for path, files in roots.items():
                for name in files:
                    source = self.components[component] / path / name
                    source.parent.mkdir(parents=True, exist_ok=True)
                    source.write_bytes(f"Copyright fixture {component}/{path}/{name}\r\n".encode() + b"raw\xff\n")
            for tree in sorted(repos, key=lambda t: len(t.parts), reverse=True):
                commit(tree)
            self.repositories.extend(repos)
        self.header = self.components["dxvk"] / "include/vulkan"
        self.log = self.out / ".copy-sources.tsv"

    def tearDown(self):
        self.temp.cleanup()

    def collect(self):
        return notices.collect(self.components, self.out, self.log)

    def test_all_roots_bytes_origins_and_superset(self):
        before = {str(t): p.git(t, "status", "--porcelain") for t in self.repositories}
        names = self.collect()
        self.assertEqual(len(names), 21)
        self.assertEqual(len(set(names)), 21)
        entries = dict(line.split("\t") for line in self.log.read_text().splitlines())
        self.assertEqual(set(entries), set(names))
        for name, source in entries.items():
            self.assertEqual((self.out / name).read_bytes(), Path(source).read_bytes())
        with patch.object(p, "source_roots", return_value=list(self.components.items())), patch.dict(os.environ, RUST_ROOT=str(self.root / "rust")):
            record = p.validate_copies(REPO, self.log)
        self.assertEqual(len(record["files"]), 21)
        self.assertNotIn(str(self.root), str(record))
        self.assertEqual(before, {str(t): p.git(t, "status", "--porcelain") for t in self.repositories})
        self.assertTrue(any("CC-BY-4.0" in name for name in names))

    def test_recursive_notice_and_license_directory_non_candidate_names(self):
        for name in ("nested/NOTICE", "LICENSES/exceptions/extra.txt"):
            source = self.header / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(b"additional tracked attribution\n")
        commit(self.header)
        names = self.collect()
        self.assertEqual(len(names), 23)
        self.assertIn("khronos-dxvk-include-vulkan-LICENSES-exceptions-extra.txt", names)

    def test_missing_mandatory_files_leave_no_output(self):
        for relative in notices.ROOTS["dxvk"]["include/vulkan"]:
            source = self.header / relative
            original = source.read_bytes()
            source.unlink()
            with self.assertRaisesRegex(ValueError, "missing regular"):
                self.collect()
            self.assertEqual(list(self.out.iterdir()), [])
            source.write_bytes(original)

    def test_changed_untracked_and_symlink_notices_refused(self):
        source = self.header / "LICENSE.md"
        original = source.read_bytes()
        source.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "bytes differ"):
            self.collect()
        source.write_bytes(original)
        extra = self.header / "NOTICE"
        extra.write_bytes(b"untracked")
        with self.assertRaisesRegex(ValueError, "untracked notice"):
            self.collect()
        extra.unlink()
        extra.symlink_to(source)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [])

    def test_symlink_directory_and_component_root_refused(self):
        folder = self.header / "LICENSES"
        folder.rename(self.header / "saved")
        folder.symlink_to(self.header / "saved", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.collect()
        folder.unlink()
        (self.header / "saved").rename(folder)
        alias = self.root / "alias"
        alias.symlink_to(self.components["dxvk"], target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            notices.collect({**self.components, "dxvk": alias}, self.out)
        self.assertEqual(list(self.out.iterdir()), [])

    def test_missing_nested_checkout_and_undeclared_repository_refused(self):
        nested = self.components["dxvk"] / "subprojects/dxbc-spirv/submodules/spirv_headers"
        nested.rename(self.root / "saved")
        nested.mkdir()
        with self.assertRaisesRegex(ValueError, "not a populated repository"):
            self.collect()
        nested.rmdir()
        (self.root / "saved").rename(nested)
        # The checkout still exists but its parent no longer declares the gitlink.
        p.git(nested.parent.parent, "rm", "--cached", "submodules/spirv_headers")
        p.git(nested.parent.parent, "commit", "-qm", "remove declaration")
        with self.assertRaisesRegex(ValueError, "Git root escapes"):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [])

    def test_collisions_existing_outputs_and_log_symlinks_refused(self):
        a = self.header / "LICENSES/a.txt"
        b = self.header / "LICENSES-a.txt"
        a.write_bytes(b"one")
        b.write_bytes(b"two")
        commit(self.header)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.collect()
        a.unlink()
        b.unlink()
        commit(self.header)
        saved = self.out / "khronos-dxvk-include-vulkan-LICENSE.md"
        saved.write_bytes(b"keep")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.collect()
        self.assertEqual(saved.read_bytes(), b"keep")
        saved.unlink()
        self.log.symlink_to(self.header / "LICENSE.md")
        with self.assertRaisesRegex(ValueError, "origins log"):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [self.log])

    def test_control_character_cannot_inject_origin_log_entries(self):
        (self.header / "NOTICE\tbroken").write_bytes(b"tracked notice")
        commit(self.header)
        with self.assertRaisesRegex(ValueError, "control character"):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [])

    def test_overlapping_output_refused(self):
        with self.assertRaisesRegex(ValueError, "overlaps"):
            notices.collect(self.components, self.header)

    def test_write_failure_rolls_back_only_created_payloads(self):
        (self.out / "keep").write_bytes(b"keep")
        original = Path.open
        writes = 0

        def fail(path, mode="r", *args, **kwargs):
            nonlocal writes
            if mode == "xb":
                writes += 1
                if writes == 2:
                    raise OSError("fixture write failure")
            return original(path, mode, *args, **kwargs)

        with patch.object(Path, "open", fail), self.assertRaisesRegex(OSError, "write failure"):
            self.collect()
        self.assertEqual([f.name for f in self.out.iterdir()], ["keep"])

    def test_nested_required_submodules_checked_recursively(self):
        tree = self.components["vkd3d"]
        required = tuple(notices.ROOTS["vkd3d"])
        pin = p.git(tree, "rev-parse", "HEAD").decode().strip()
        record = p.verify_tree(tree, pin, [], self.root, required=required)
        self.assertNotIn(str(self.root), str(record))
        deepest = tree / required[-1]
        deepest.rename(self.root / "saved")
        with self.assertRaisesRegex(ValueError, "required notice submodule is absent"):
            p.verify_tree(tree, pin, [], self.root, required=required)
        (self.root / "saved").rename(deepest)
        (deepest / "LICENSE").write_bytes(b"dirty")
        with self.assertRaises(ValueError):
            p.verify_tree(tree, pin, [], self.root, required=required)

    def test_undeclared_required_path_fails_tree_gate(self):
        tree = self.components["dxvk"]
        pin = p.git(tree, "rev-parse", "HEAD").decode().strip()
        for required in (("missing",), ("subprojects/dxbc-spirv/missing",)):
            with self.assertRaisesRegex(ValueError, "not declared"):
                p.verify_tree(tree, pin, [], self.root, required=required)

    def test_assembly_tree_gate_requires_every_collected_header_root(self):
        required = {}

        def verify(tree, pin, patches, scratch, overrides, roots, omitted):
            required[tree.name] = set(roots)
            return {}

        variables = ("WINE", "FEX", "MYTHIC", "DXMT", "LLVM", "FREETYPE", "MESA", "DXVK", "VKD3D", "GBE", "ABSL", "STIKJIT", "IDEVICE")
        env = {key: str(self.root / key) for key in variables}
        with patch.dict(os.environ, env), patch.object(p, "verify_tree", verify), patch.object(p, "series", return_value=[]):
            p.collect(REPO, self.root)
        self.assertTrue(set(notices.ROOTS["dxvk"]) <= required["DXVK"])
        self.assertTrue(set(notices.ROOTS["vkd3d"]) <= required["VKD3D"])
        self.assertIn("notices-khronos.py", (REPO / "build/notices-assemble.sh").read_text())

    def test_cli_failure_leaves_no_payloads(self):
        (self.header / "LICENSE.md").unlink()
        result = subprocess.run([sys.executable, str(REPO / "build/notices-khronos.py"),
                                 str(self.components["dxvk"]), str(self.components["vkd3d"]),
                                 str(self.out), "--origins-log", str(self.log)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Khronos notice collection:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(list(self.out.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
