# SPDX-License-Identifier: GPL-3.0-or-later
"""Strict offline GStreamer preparatory inventory fixtures; no runtime build."""

import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("notices_gstreamer", ROOT / "build/notices-gstreamer.py")
gst = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gst)
provenance_spec = importlib.util.spec_from_file_location("gst_provenance", ROOT / "build/notices-provenance.py")
p = importlib.util.module_from_spec(provenance_spec)
provenance_spec.loader.exec_module(p)


class GStreamerNoticesTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".work").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / ".work")
        self.repo = Path(self.temp.name)
        self.sources = self.repo / ".work/sources"
        self.sources.mkdir(parents=True)
        self.output = self.repo / ".work/result"
        (self.repo / "build/stages").mkdir(parents=True)
        self.stage = b"SHA256=" + b"a" * 64 + b"\n"
        (self.repo / "build/stages/gstreamer.sh").write_bytes(self.stage)
        (self.repo / "pins.lock").write_text("gstreamer 1.28.7 https://example.test -\n")
        self.source = self.sources / "sample.tar.gz"
        self.members = [("sample/COPYING", b"Copyright A\r\nAll rights reserved.\n"),
                        ("sample/LICENSES/MIT.txt", b"Copyright B\n"),
                        ("sample/src/notice.c", b"/* a candidate, not a licence determination */"),
                        ("sample/README", b"Required non-candidate notice\n")]
        self.write_tar(self.source, self.members)
        self.source_spec = {"archive": self.source.name, "root": "sample", "sha256": gst.digest(self.source.read_bytes()),
                            "version": "1.0", "recipe": "recipes/sample.recipe", "reviewed_download_url": "https://example.test/source",
                            "required_notices": ["COPYING", "README"]}
        self.recipe = (f"class Recipe(recipe.Recipe):\n    version = '1.0'\n    tarball_checksum = '{self.source_spec['sha256']}'\n").encode()
        self.source_spec["recipe_sha256"] = gst.digest(self.recipe)
        self.cerbero = self.sources / "cerbero.tar.gz"
        self.write_tar(self.cerbero, [("cerbero/recipes/sample.recipe", self.recipe), ("cerbero/config/ios.config", b"review")])
        self.lock = {"schema": 1, "status": "preparatory-source-review-not-binary-build-lock", "release": "1.28.7",
                     "stage_sha256": gst.digest(self.stage), "binary_archive_sha256": "a" * 64,
                     "cerbero": {"archive": "cerbero.tar.gz", "root": "cerbero", "sha256": gst.digest(self.cerbero.read_bytes()),
                                 "commit": "b" * 40, "review_files": {"config/ios.config": gst.digest(b"review")}},
                     "components": {"sample": self.source_spec}, "unresolved": ["binary derivation"]}
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.commit_lock()

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def write_tar(path, members):
        with tarfile.open(path, "w:gz") as tar:
            for name, data in members:
                member = tarfile.TarInfo(name)
                if isinstance(data, tuple):
                    member.type, member.linkname = data
                else:
                    member.size = len(data)
                tar.addfile(member, io.BytesIO(data) if isinstance(data, bytes) else None)

    def commit_lock(self):
        (self.repo / gst.LOCK).write_text(json.dumps(self.lock))
        subprocess.run(["git", "-C", str(self.repo), "add", "build", "pins.lock"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                        "commit", "-qm", "fixture", "--allow-empty"], check=True)

    def run_prepare(self, selected=None):
        return gst.prepare(self.repo, self.cerbero, self.sources, self.output, selected)

    def source_changed(self, members):
        self.write_tar(self.source, members)
        self.source_spec["sha256"] = gst.digest(self.source.read_bytes())
        self.recipe = (f"class Recipe(recipe.Recipe):\n    version = '1.0'\n    tarball_checksum = '{self.source_spec['sha256']}'\n").encode()
        self.source_spec["recipe_sha256"] = gst.digest(self.recipe)
        self.write_tar(self.cerbero, [("cerbero/recipes/sample.recipe", self.recipe), ("cerbero/config/ios.config", b"review")])
        self.lock["cerbero"]["sha256"] = gst.digest(self.cerbero.read_bytes())
        self.commit_lock()

    def assert_refused(self):
        with self.assertRaises((ValueError, OSError, tarfile.TarError)):
            self.run_prepare()
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.output.parent.glob("result.partial.*")))

    def test_exact_bytes_origins_path_independence_and_read_only(self):
        before = {p: gst.digest(p.read_bytes()) for p in [self.source, self.cerbero]}
        result = self.run_prepare()
        self.assertEqual(result["status"], "incomplete-preparatory-notice-superset")
        self.assertNotIn(str(self.repo), json.dumps(result))
        for source, record in result["components"]["sample"]["notices"].items():
            data = (self.output / record["output"]).read_bytes()
            self.assertEqual(data, dict(self.members)["sample/" + source])
            self.assertEqual(record["archive_member"], "sample/" + source)
            self.assertEqual(gst.digest(data), record["sha256"])
        self.assertIn("LICENSES/MIT.txt", result["components"]["sample"]["notices"])
        self.assertEqual(before, {p: gst.digest(p.read_bytes()) for p in before})

    def test_missing_corrupt_archives(self):
        self.source.write_bytes(b"not the locked archive")
        self.assert_refused()
        self.source.unlink()
        self.assert_refused()

    def test_uncommitted_lock_stage_and_pin_changes(self):
        path = self.repo / gst.LOCK
        original = path.read_bytes()
        path.write_bytes(original + b"\n")
        self.assert_refused()
        path.write_bytes(original)
        (self.repo / "build/stages/gstreamer.sh").write_bytes(self.stage + b"changed")
        self.assert_refused()
        (self.repo / "build/stages/gstreamer.sh").write_bytes(self.stage)
        (self.repo / "pins.lock").write_text("gstreamer wrong\n")
        self.assert_refused()

    def test_recipe_hash_and_declaration_checks(self):
        self.lock["components"]["sample"]["recipe_sha256"] = "a" * 64
        self.commit_lock()
        self.assert_refused()
        self.source_spec["recipe_sha256"] = gst.digest(self.recipe)
        self.source_spec["version"] = "2.0"
        self.commit_lock()
        self.assert_refused()

    def test_missing_mandatory_notice_cleanup(self):
        self.source_changed([m for m in self.members if not m[0].endswith("README")])
        self.assert_refused()

    def test_unsafe_duplicate_special_wrong_root_colliding_members(self):
        cases = [[("sample/../escape", b"x")], [("/absolute", b"x")], [("sample/bad\nname", b"x")],
                 [("sample/a", b"x"), ("sample/a", b"y")], [("wrong/COPYING", b"x")],
                 [("sample/file", b"x"), ("sample/file/child", b"y")],
                 [("sample/device", (tarfile.FIFOTYPE, ""))], [("sample/C:\\file", b"x")]]
        for extra in cases:
            with self.subTest(extra=extra):
                self.source_changed(self.members + extra)
                self.assert_refused()

    def test_internal_glib_style_alias_preserves_origin(self):
        self.source_changed([m for m in self.members if not m[0].endswith("COPYING")] +
                            [("sample/COPYING", (tarfile.SYMTYPE, "LICENSES/MIT.txt"))])
        result = self.run_prepare()
        record = result["components"]["sample"]["notices"]["COPYING"]
        self.assertEqual(record["archive_member"], "sample/LICENSES/MIT.txt")
        self.assertEqual(record["alias"]["target"], "LICENSES/MIT.txt")
        self.assertEqual((self.output / record["output"]).read_bytes(), b"Copyright B\n")

    def test_external_dangling_chain_hardlinks_are_refused(self):
        for target in ["../../escape", "/external", "absent", "alias"]:
            with self.subTest(target=target):
                extra = [("sample/alias", (tarfile.SYMTYPE, "COPYING")),
                         ("sample/link", (tarfile.SYMTYPE, target))]
                self.source_changed(self.members + extra)
                self.assert_refused()
        self.source_changed(self.members + [("sample/hard", (tarfile.LNKTYPE, "sample/COPYING"))])
        self.assert_refused()

    def test_filesystem_symlinks_and_existing_output_preserved(self):
        original = self.source.read_bytes()
        self.source.unlink()
        other = self.sources / "other"
        other.write_bytes(original)
        self.source.symlink_to(other.name)
        self.assert_refused()
        self.source.unlink()
        self.source.write_bytes(original)
        self.output.mkdir()
        sentinel = self.output / "keep"
        sentinel.write_text("unchanged")
        with self.assertRaises(ValueError):
            self.run_prepare()
        self.assertEqual(sentinel.read_text(), "unchanged")

    def test_selection_and_output_boundary(self):
        for selected in [[], ["absent"], ["sample", "sample"]]:
            with self.assertRaises(ValueError):
                self.run_prepare(selected)
        self.output = self.repo / "outside-work"
        self.assert_refused()

    def test_payload_failure_and_racing_destination(self):
        original = Path.write_bytes
        def fail(path, data):
            if "notices" in path.parts:
                raise OSError("fixture write failure")
            return original(path, data)
        with patch.object(Path, "write_bytes", fail):
            self.assert_refused()
        run = subprocess.run
        def race(command, **kwargs):
            if command[0] == "mv":
                self.output.mkdir()
                (self.output / "keep").write_text("race")
            return run(command, **kwargs)
        with patch.object(gst.subprocess, "run", race):
            with self.assertRaises(ValueError):
                self.run_prepare()
        self.assertEqual((self.output / "keep").read_text(), "race")
        self.assertFalse(list(self.output.parent.glob("result.partial.*")))

    def test_partial_subset_explicitly_records_omissions(self):
        self.lock["components"]["omitted"] = copy.deepcopy(self.source_spec)
        self.commit_lock()
        result = self.run_prepare(["sample"])
        self.assertEqual(result["omitted_components"], ["omitted"])
        self.assertEqual(set(result["components"]), {"sample"})
        self.assertEqual(result["status"], "incomplete-preparatory-notice-superset")

    def test_manifest_write_failure_rolls_back(self):
        original = Path.write_text
        def fail(path, data, *args, **kwargs):
            if path.name == "gstreamer-source-inventory.json":
                raise OSError("fixture manifest failure")
            return original(path, data, *args, **kwargs)
        with patch.object(Path, "write_text", fail):
            self.assert_refused()

    def test_config_hash_and_symlinked_input_parent(self):
        self.lock["cerbero"]["review_files"]["config/ios.config"] = "f" * 64
        self.commit_lock()
        self.assert_refused()
        alias = self.repo / ".work/source-alias"
        alias.symlink_to(self.sources.name, target_is_directory=True)
        self.sources = alias
        self.assert_refused()

    def assemble(self):
        self.output.mkdir()
        return gst.collect(self.repo, self.cerbero, self.sources, self.output)

    def validate(self):
        return gst.validate(self.repo, self.cerbero, self.sources, self.output)

    def test_assembly_complete_flat_bytes_origins_and_inventory(self):
        before = {path: path.read_bytes() for path in (self.source, self.cerbero)}
        manifest = self.assemble()
        self.assertEqual(self.validate(), manifest)
        for name, origin in gst.assembly_payloads(manifest).items():
            self.assertEqual((self.output / name).read_bytes(), dict(self.members)[origin["archive_member"]])
        env = {"GST_NOTICE_CERBERO": str(self.cerbero), "GST_NOTICE_SOURCES": str(self.sources)}
        validator = p.validate_gstreamer_notices
        with patch.dict(os.environ, env), patch.object(p, "validate_gstreamer_notices",
                lambda out: validator(out, self.repo)):
            record = p.inventory(self.output)
        self.assertEqual(record["status"], "incomplete-inventory")
        self.assertEqual(len(record["files"]), len(manifest["components"]["sample"]["notices"]) + 1)
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        self.assertNotIn(str(self.repo), json.dumps(manifest))
        self.assertFalse(list((self.repo / ".work/tmp").iterdir()))

    def test_assembly_alias_retains_target_and_link_origins(self):
        self.source_changed([m for m in self.members if not m[0].endswith("COPYING")] +
                            [("sample/COPYING", (tarfile.SYMTYPE, "LICENSES/MIT.txt"))])
        manifest = self.assemble()
        origin = gst.assembly_payloads(manifest)["gstreamer-source-sample-COPYING"]
        self.assertEqual(origin["archive_member"], "sample/LICENSES/MIT.txt")
        self.assertEqual(origin["alias"]["target"], "LICENSES/MIT.txt")
        self.validate()

    def test_assembly_refuses_flattened_collisions_before_writes(self):
        self.source_changed(self.members + [("sample/LICENSE/a-b", b"a"), ("sample/LICENSE-a/b", b"b")])
        # Both paths must be candidates, even with non-notice basenames.
        self.source_spec["required_notices"] += ["LICENSE/a-b", "LICENSE-a/b"]
        self.commit_lock()
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, "collision"):
            gst.collect(self.repo, self.cerbero, self.sources, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_assembly_preexisting_and_racing_payloads_preserved(self):
        self.output.mkdir()
        sentinel = self.output / "gstreamer-source-sample-COPYING"
        sentinel.write_bytes(b"keep")
        with self.assertRaises(ValueError):
            gst.collect(self.repo, self.cerbero, self.sources, self.output)
        self.assertEqual(sentinel.read_bytes(), b"keep")
        sentinel.unlink()
        original = Path.open
        def race(path, mode="r", *args, **kwargs):
            if path == sentinel and mode == "xb":
                with original(path, "wb") as stream:
                    stream.write(b"race")
            return original(path, mode, *args, **kwargs)
        with patch.object(Path, "open", race), self.assertRaises(FileExistsError):
            gst.collect(self.repo, self.cerbero, self.sources, self.output)
        self.assertEqual(sentinel.read_bytes(), b"race")
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_assembly_manifest_failure_rolls_back_only_own_payloads(self):
        self.output.mkdir()
        sentinel = self.output / "unrelated.txt"
        sentinel.write_text("keep")
        original = Path.open
        def fail(path, mode="r", *args, **kwargs):
            if path.name == gst.MANIFEST and mode == "x":
                raise OSError("fixture failure")
            return original(path, mode, *args, **kwargs)
        with patch.object(Path, "open", fail), self.assertRaises(OSError):
            gst.collect(self.repo, self.cerbero, self.sources, self.output)
        self.assertEqual(list(self.output.iterdir()), [sentinel])
        self.assertFalse(list((self.repo / ".work/tmp").iterdir()))

    def test_assembly_payload_write_failure_rolls_back(self):
        self.output.mkdir()
        original = Path.open
        class FailingStream:
            def __enter__(inner):
                return inner
            def write(inner, data):
                raise OSError("fixture payload failure")
            def __exit__(inner, *args):
                inner.stream.close()
        def fail(path, mode="r", *args, **kwargs):
            stream = original(path, mode, *args, **kwargs)
            if mode == "xb" and path.name.startswith(gst.PREFIX):
                wrapper = FailingStream()
                wrapper.stream = stream
                return wrapper
            return stream
        with patch.object(Path, "open", fail), self.assertRaises(OSError):
            gst.collect(self.repo, self.cerbero, self.sources, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_assembly_missing_extra_changed_symlinked_payloads(self):
        manifest = self.assemble()
        payload = self.output / next(iter(gst.assembly_payloads(manifest)))
        original = payload.read_bytes()
        payload.unlink()
        with self.assertRaises(ValueError):
            self.validate()
        payload.write_bytes(b"changed")
        with self.assertRaises(ValueError):
            self.validate()
        payload.unlink()
        payload.symlink_to(self.source)
        with self.assertRaises(ValueError):
            self.validate()
        payload.unlink()
        payload.write_bytes(original)
        extra = self.output / "gstreamer-source-extra"
        extra.write_bytes(b"extra")
        with self.assertRaises(ValueError):
            self.validate()
        extra.unlink()
        self.validate()

    def test_assembly_recomputes_manifest_and_candidate_coverage(self):
        manifest = self.assemble()
        path = self.output / gst.MANIFEST
        for field in ("notices", "files", "symlinks"):
            changed = copy.deepcopy(manifest)
            changed["components"]["sample"][field] = {"forged": {}}
            path.write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError, "provenance differs"):
                self.validate()
        changed = copy.deepcopy(manifest)
        changed["omitted_components"] = ["sample"]
        path.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            self.validate()
        path.write_text(json.dumps(manifest))
        self.validate()

    def test_assembly_rechecks_archives_and_committed_lock(self):
        self.assemble()
        data = self.source.read_bytes()
        self.source.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.validate()
        self.source.write_bytes(data)
        path = self.repo / gst.LOCK
        path.write_text(path.read_text() + "\n")
        with self.assertRaisesRegex(ValueError, "committed"):
            self.validate()

    def test_assembly_output_overlap_and_parent_links(self):
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, "overlap"):
            gst.collect(self.repo, self.cerbero, self.sources, self.sources)
        alias = self.repo / ".work/alias"
        alias.symlink_to(self.output.name, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            gst.collect(self.repo, self.cerbero, self.sources, alias)

    def test_inventory_missing_manifest_and_required_collection(self):
        self.output.mkdir()
        gate = self.output / "tree-provenance.json"
        gate.write_text(json.dumps({"required_collections": ["gstreamer"]}))
        with self.assertRaisesRegex(ValueError, "lack preparatory"):
            p.inventory(self.output)
        gate.unlink()
        manifest = self.output / gst.MANIFEST
        manifest.symlink_to(self.output / "missing")
        with self.assertRaisesRegex(ValueError, "lack preparatory"):
            p.inventory(self.output)

    def test_inventory_requires_source_inputs_and_rejects_orphan_payload(self):
        self.assemble()
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, "requires source"):
            p.inventory(self.output)
        (self.output / gst.MANIFEST).unlink()
        with self.assertRaisesRegex(ValueError, "lack preparatory"):
            p.inventory(self.output)

    def test_cli_assembly_and_verification_and_subset_refusal(self):
        self.output.mkdir()
        command = ["python3", str(ROOT / "build/notices-gstreamer.py"), str(self.cerbero),
                   str(self.sources), str(self.output), "--repo", str(self.repo)]
        for option in ("--assemble", "--verify-assembly"):
            result = subprocess.run(command + [option], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("release gate remains open", result.stdout)
        result = subprocess.run(command + ["--assemble", "--component", "sample"], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.validate()

    def test_shell_gstreamer_failure_cleans_entire_assembly(self):
        bin_dir = self.repo / ".work/bin"
        bin_dir.mkdir()
        python = bin_dir / "python3"
        python.write_text('#!/bin/sh\ncase "$1" in *notices-gstreamer.py) '
                          'echo "fixture GStreamer refusal" >&2; exit 1 ;; esac\nexit 0\n')
        python.chmod(0o755)
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   PLAYPORT_BUILD=str(self.repo / ".work"))
        result = subprocess.run(["bash", str(ROOT / "build/notices-assemble.sh"), str(self.output)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture GStreamer refusal", result.stderr)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.output.parent.glob("result.partial.*")))

    def test_cli_failure_leaves_no_partial_output(self):
        self.source.unlink()
        result = subprocess.run(["python3", str(ROOT / "build/notices-gstreamer.py"), str(self.cerbero),
                                 str(self.sources), str(self.output), "--repo", str(self.repo)], capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
