# SPDX-License-Identifier: GPL-3.0-or-later
"""Mesa header credits: complete bytes, fail-closed origins and publication."""

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
spec = importlib.util.spec_from_file_location("mesa_notices", REPO / "build/notices-mesa.py")
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)
p = notices.provenance


class MesaNotices(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.tree = self.root / "mesa"
        self.tree.mkdir()
        self.out = self.root / "out"
        self.out.mkdir()
        for args in (("init", "-q"), ("config", "user.name", "fixture"),
                     ("config", "user.email", "fixture@localhost")):
            p.git(self.tree, *args)
        for relative in notices.REQUIRED:
            source = self.tree / relative
            source.parent.mkdir(parents=True, exist_ok=True)
            # Notices deliberately not all at the start; full-header selection
            # must retain permission text, multiple authors and normative warning.
            source.write_bytes(b"#define CODE 1\r\n/* Copyright fixture " + relative.encode()
                               + b"\r\nPermission is hereby granted\r\n*/\r\n"
                               + b"/* Another copyright; normative warning */\nraw\xff\n")
        self.source = self.tree / notices.REQUIRED[0]
        self.commit()
        self.pin = p.git(self.tree, "rev-parse", "HEAD").decode().strip()

    def tearDown(self):
        self.temp.cleanup()

    def commit(self):
        p.git(self.tree, "add", ".")
        p.git(self.tree, "commit", "-qm", "fixture")

    def collect(self):
        return notices.collect(self.tree, self.out)

    def inventory(self):
        with patch.dict(os.environ, MESA=str(self.tree)):
            return p.inventory(self.out)

    def test_full_headers_exact_origins_and_read_only(self):
        before = p.git(self.tree, "status", "--porcelain")
        index = Path(p.git(self.tree, "rev-parse", "--git-path", "index").decode().strip())
        if not index.is_absolute():
            index = self.tree / index
        index_bytes = index.read_bytes()
        record = self.collect()
        self.assertEqual(len(record["files"]), len(notices.REQUIRED))
        self.assertNotIn(str(self.root), json.dumps(record))
        for name, origin in record["files"].items():
            data = (self.tree / origin["source"]).read_bytes()
            self.assertEqual((self.out / name).read_bytes(), data)
            self.assertEqual(origin["first_line"], 1)
            self.assertEqual(origin["last_line"], len(data.split(b"\n")) - 1)
            self.assertEqual(origin["sha256"], origin["source_sha256"])
            self.assertEqual(origin["verification"], "committed-bytes")
            self.assertEqual(origin["kind"], "full-header")
        self.assertEqual(self.inventory()["status"], "incomplete-inventory")
        self.assertEqual(index.read_bytes(), index_bytes)
        self.assertEqual(before, p.git(self.tree, "status", "--porcelain"))

    def test_recursive_vulkan_and_video_local_spirv_superset(self):
        for relative in ("include/vulkan/nested/extra.h", "include/vk_video/extra.h",
                         "src/compiler/spirv/vtn_private.h", "src/compiler/spirv/tests/helper.h"):
            source = self.tree / relative
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(b"full header copyright\n")
        self.commit()
        record = self.collect()
        self.assertEqual(len(record["files"]), len(notices.REQUIRED) + 3)
        self.assertNotIn("src/compiler/spirv/tests/helper.h", {o["source"] for o in record["files"].values()})
        self.inventory()

    def test_dirty_staged_untracked_and_ignored_header_inputs(self):
        original = self.source.read_bytes()
        self.source.write_bytes(b"dirty")
        with self.assertRaisesRegex(ValueError, "dirty"):
            self.collect()
        p.git(self.tree, "add", ".")
        self.source.write_bytes(original)
        with self.assertRaisesRegex(ValueError, "dirty"):
            self.collect()
        p.git(self.tree, "add", ".")
        extra = self.tree / "include/vulkan/extra.h"
        extra.write_bytes(b"untracked")
        with self.assertRaisesRegex(ValueError, "untracked"):
            self.collect()
        extra.unlink()
        (self.tree / ".gitignore").write_text("extra.h\n")
        self.commit()
        extra.write_bytes(b"ignored")
        with self.assertRaisesRegex(ValueError, "untracked"):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [])

    def test_dirty_non_header_input_also_refused(self):
        (self.tree / "build-input.c").write_bytes(b"original")
        self.commit()
        (self.tree / "build-input.c").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "dirty"):
            self.collect()

    def test_missing_tracked_and_missing_committed_required_headers(self):
        self.source.unlink()
        with self.assertRaises(ValueError):
            self.collect()
        self.commit()
        with self.assertRaisesRegex(ValueError, "missing required"):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [])

    def test_empty_committed_header_refused(self):
        self.source.write_bytes(b"")
        self.commit()
        with self.assertRaisesRegex(ValueError, "empty Mesa header"):
            self.collect()

    def test_source_root_parent_and_header_symlinks(self):
        alias = self.root / "alias"
        alias.symlink_to(self.tree, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            notices.collect(alias, self.out)
        alias.unlink()
        self.source.unlink()
        self.source.symlink_to(self.tree / notices.REQUIRED[1])
        self.commit()
        with self.assertRaisesRegex(ValueError, "committed regular"):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [])

    def test_symlink_directory_and_output_parents_refused(self):
        hidden = self.tree / "include/vulkan/hidden"
        hidden.symlink_to(self.root, target_is_directory=True)
        (self.tree / ".gitignore").write_text("hidden\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.collect()
        alias = self.root / "out-alias"
        alias.symlink_to(self.out, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            notices.collect(self.tree, alias)
        with self.assertRaisesRegex(ValueError, "symlink"):
            notices.collect(self.tree, alias / ".")

    def test_nested_repository_cannot_supply_matching_headers(self):
        nested = self.tree / "include/vulkan"
        p.git(nested, "init", "-q")
        p.git(nested, "config", "user.name", "fixture")
        p.git(nested, "config", "user.email", "fixture@localhost")
        p.git(nested, "add", ".")
        p.git(nested, "commit", "-qm", "nested")
        with self.assertRaisesRegex(ValueError, "Git root escapes"):
            self.collect()

    def test_flattening_and_existing_payload_manifest_collisions(self):
        for relative in ("include/vulkan/a/b.h", "include/vulkan/a-b.h"):
            source = self.tree / relative
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(b"copyright\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.collect()
        (self.tree / "include/vulkan/a-b.h").unlink()
        self.commit()
        record, _ = notices.snapshot(self.tree)
        for name in (next(iter(record["files"])), notices.MANIFEST):
            saved = self.out / name
            saved.write_bytes(b"keep")
            with self.assertRaisesRegex(ValueError, "duplicate"):
                self.collect()
            self.assertEqual(saved.read_bytes(), b"keep")
            saved.unlink()
        (self.out / notices.MANIFEST).symlink_to(self.source)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.collect()

    def test_control_character_path_refused(self):
        (self.tree / "include/vulkan/extra\tbad.h").write_bytes(b"copyright\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "control character"):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [])

    def test_overlapping_output_refused_both_directions(self):
        for out in (self.tree / "include/vulkan", self.root):
            with self.assertRaisesRegex(ValueError, "overlaps"):
                notices.collect(self.tree, out)

    def test_failed_payload_and_manifest_writes_roll_back(self):
        (self.out / "keep").write_bytes(b"keep")
        original = Path.open
        for failing_name in (notices.PREFIX + notices.REQUIRED[1].replace("/", "-") + ".txt", notices.MANIFEST):
            def fail(path, mode="r", *args, **kwargs):
                if mode == "xb" and path.name == failing_name:
                    raise OSError("fixture write failure")
                return original(path, mode, *args, **kwargs)
            with patch.object(Path, "open", fail), self.assertRaisesRegex(OSError, "write failure"):
                self.collect()
            self.assertEqual([p.name for p in self.out.iterdir()], ["keep"])

    def test_inventory_missing_extra_changed_symlink_payloads(self):
        record = self.collect()
        name = next(iter(record["files"]))
        payload = self.out / name
        original = payload.read_bytes()
        payload.unlink()
        with self.assertRaisesRegex(ValueError, "payload set"):
            self.inventory()
        payload.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "changed after"):
            self.inventory()
        payload.unlink()
        payload.symlink_to(self.source)
        with self.assertRaisesRegex(ValueError, "regular notice payload"):
            self.inventory()
        payload.unlink()
        payload.write_bytes(original)
        (self.out / (notices.PREFIX + "extra")).write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "payload set"):
            self.inventory()

    def test_inventory_origin_omissions_ranges_and_changed_sources(self):
        record = self.collect()
        manifest = self.out / notices.MANIFEST
        name = next(iter(record["files"]))
        for mutate in (lambda r: r["files"].pop(name),
                       lambda r: r["files"][name].update(last_line=1),
                       lambda r: r.update(tree="wrong"),
                       lambda r: r.update(selection={})):
            altered = json.loads(json.dumps(record))
            mutate(altered)
            manifest.write_text(json.dumps(altered))
            with self.assertRaisesRegex(ValueError, "origin/selection"):
                self.inventory()
        manifest.write_text(json.dumps(record))
        self.source.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "dirty"):
            self.inventory()

    def test_inventory_requires_source_and_manifest_tree_gate_binding(self):
        self.collect()
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, "requires MESA"):
            p.inventory(self.out)
        gate = self.out / "tree-provenance.json"
        gate.write_text(json.dumps({"trees": {"mesa": {"tree": "wrong"}}}))
        with self.assertRaisesRegex(ValueError, "exact tree gate"):
            self.inventory()
        gate.unlink()
        (self.out / notices.MANIFEST).unlink()
        with self.assertRaisesRegex(ValueError, "lack committed"):
            self.inventory()

    def test_inventory_refuses_omitted_collector_and_added_committed_headers(self):
        gate = self.out / "tree-provenance.json"
        gate.write_text(json.dumps({"trees": {"mesa": {"tree": "fixture"}}}))
        with self.assertRaisesRegex(ValueError, "lack committed"):
            self.inventory()
        gate.unlink()
        self.collect()
        (self.tree / "include/vulkan/new.h").write_bytes(b"additional notice\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "origin/selection"):
            self.inventory()

    def test_exact_tree_gate_refuses_clean_arbitrary_descendant(self):
        p.verify_tree(self.tree, self.pin, [], self.root)
        self.source.write_bytes(b"other committed header\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "exact pin"):
            p.verify_tree(self.tree, self.pin, [], self.root)

    def test_cli_success_and_failure_and_assembly_integration(self):
        command = [sys.executable, str(REPO / "build/notices-mesa.py"), str(self.tree), str(self.out)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.inventory()
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Mesa notice collection:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        shell = (REPO / "build/notices-assemble.sh").read_text()
        self.assertLess(shell.index(' trees "$REPO"'), shell.index("notices-mesa.py"))
        self.assertLess(shell.index("notices-mesa.py"), shell.index(' inventory "$OUT"'))
        self.assertIn('trap \'rm -rf -- "$OUT"\' EXIT', shell)


if __name__ == "__main__":
    unittest.main()
