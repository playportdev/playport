# SPDX-License-Identifier: GPL-3.0-or-later
"""Exact offline LLVM source notices, not legal or binary release approval."""

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
spec = importlib.util.spec_from_file_location("llvm_runtime_test", REPO / "build/notices-llvm-runtime.py")
llvm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(llvm)
provenance_spec = importlib.util.spec_from_file_location("llvm_assembly_provenance", REPO / "build/notices-provenance.py")
p = importlib.util.module_from_spec(provenance_spec)
provenance_spec.loader.exec_module(p)


class LLVMRuntimeNotices(unittest.TestCase):
    def setUp(self):
        temp = REPO / ".work/tmp"
        temp.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=temp)
        self.root = Path(self.temp.name)
        self.repo, self.source, self.mingw = (self.root / p for p in ("repo", "source", "mingw"))
        for tree in (self.repo, self.source, self.mingw):
            tree.mkdir()
            for args in (("init", "-q"), ("config", "user.name", "fixture"),
                         ("config", "user.email", "fixture@localhost")):
                llvm.git(tree, *args)
        for path in llvm.REQUIRED:
            self.file(path, b"Copyright fixture\r\npermission \xff\n" + path.encode())
        self.file("libcxx/nested/NOTICE.txt", b"recursive notice\r\n\xff")
        self.file("compiler-rt/nested/LICENSES/plain", b"arbitrary licence basename")
        self.file("libcxx/include/extra.h", b"// third party attribution\r\n// Public domain\nint data;\n")
        self.file("libcxx/test/unused.cpp", b"// Copyright test-only credit\n")
        self.file("libcxx/no-marker.cpp", b"int no_marker;\n")
        self.file("outside.c", b"outside scanned scope\n")
        for path in llvm.SCRIPTS:
            data = b"script fixture\n"
            if path == "build-llvm.sh":
                data = b": ${LLVM_REPOSITORY:=https://github.com/llvm/llvm-project.git}\n: ${LLVM_VERSION:=fixture-tag}\n"
            (self.mingw / path).write_bytes(data)
        self.lock_path = self.repo / llvm.LOCK
        self.lock_path.parent.mkdir()
        self.lock = {"schema": 1, "policy": llvm.POLICY,
                     "llvm": {"repository": "https://github.com/llvm/llvm-project.git", "tag": "fixture-tag"},
                     "llvm_mingw": {"release": "fixture"}}
        self.relock()
        self.out = self.root / "out"

    def tearDown(self):
        self.temp.cleanup()

    def file(self, path, data):
        file = self.source / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(data)
        return file

    def commit(self, root):
        llvm.git(root, "add", ".")
        llvm.git(root, "commit", "--allow-empty", "-qm", "fixture")
        return {"commit": llvm.git(root, "rev-parse", "HEAD").decode().strip(),
                "tree": llvm.git(root, "rev-parse", "HEAD^{tree}").decode().strip()}

    def save_lock(self):
        self.lock_path.write_bytes(llvm.encoded(self.lock))
        self.commit(self.repo)

    def relock(self):
        self.lock["llvm"].update(self.commit(self.source))
        self.lock["llvm_mingw"].update(self.commit(self.mingw))
        self.lock["scripts"] = {p: llvm.details((self.mingw / p).read_bytes()) for p in llvm.SCRIPTS}
        self.lock["required_inputs"] = {p: llvm.details((self.source / p).read_bytes())
                                        for p in llvm.REQUIRED if (self.source / p).is_file()}
        self.save_lock()

    def collect(self):
        return llvm.collect(self.repo, self.source, self.mingw, self.out)

    def verify(self):
        return llvm.verify(self.repo, self.source, self.mingw, self.out)

    def reject(self, pattern=".*"):
        with self.assertRaisesRegex((ValueError, OSError, KeyError), pattern):
            self.collect()
        self.assertFalse(self.out.exists())
        self.assertEqual(list(self.root.glob("out.partial.*")), [])

    def test_byte_preserving_recursive_header_superset_and_readonly(self):
        before = {r: llvm.git(r, "status", "--porcelain") for r in (self.repo, self.source, self.mingw)}
        record = self.collect()
        self.assertFalse(record["complete"])
        self.assertNotIn(str(self.root), json.dumps(record))
        selected = {o["source"] for o in record["collected_notices"].values()}
        self.assertEqual(selected, set(llvm.REQUIRED) | {"libcxx/nested/NOTICE.txt",
                         "compiler-rt/nested/LICENSES/plain", "libcxx/include/extra.h", "libcxx/test/unused.cpp"})
        self.assertEqual(record["scanned_files"]["libcxx/no-marker.cpp"]["selected_by"], [])
        for name, origin in record["collected_notices"].items():
            self.assertEqual((self.out / name).read_bytes(), (self.source / origin["source"]).read_bytes())
            self.assertEqual(origin["selector"], "whole-file")
        self.assertEqual(record, self.verify())
        for root, status in before.items():
            self.assertEqual(llvm.git(root, "status", "--porcelain"), status)

    def test_path_independent_relocated_inputs_and_output(self):
        original = self.collect()
        self.source.rename(self.root / "moved-source")
        self.source = self.root / "moved-source"
        self.mingw.rename(self.root / "moved-mingw")
        self.mingw = self.root / "moved-mingw"
        self.out.rename(self.root / "moved-out")
        self.out = self.root / "moved-out"
        self.assertEqual(original, self.verify())

    def test_uncommitted_staged_symlink_and_duplicate_key_locks(self):
        original = self.lock_path.read_bytes()
        self.lock_path.write_bytes(original + b" ")
        self.reject("committed")
        llvm.git(self.repo, "add", llvm.LOCK)
        self.reject("committed")
        llvm.git(self.repo, "reset", "-q", "HEAD", "--", llvm.LOCK)
        self.lock_path.unlink()
        self.lock_path.symlink_to(self.source / "LICENSE.TXT")
        self.reject("symlink")
        self.lock_path.unlink()
        self.lock_path.write_bytes(b'{"schema":1,"schema":1}')
        self.commit(self.repo)
        self.reject("duplicate JSON")

    def test_bad_lock_identities_policy_and_omitted_required_inputs(self):
        original = copy.deepcopy(self.lock)
        for mutate in (lambda l: l["llvm"].update(commit="HEAD"),
                       lambda l: l["llvm"].update(tree="0" * 40),
                       lambda l: l.update(policy="guessed"),
                       lambda l: l["scripts"].pop("release.sh"),
                       lambda l: l["required_inputs"].pop("compiler-rt/CREDITS.TXT"),
                       lambda l: l["llvm"].update(repository="unexpected")):
            self.lock = copy.deepcopy(original)
            mutate(self.lock)
            self.save_lock()
            self.reject()

    def test_script_hash_and_overridable_defaults_must_match_lock(self):
        self.lock["scripts"]["release.sh"]["sha256"] = "0" * 64
        self.save_lock()
        self.reject("checksum")
        for text in (b": ${LLVM_VERSION:=other}\n", b": ${LLVM_VERSION:=fixture-tag}\n: ${LLVM_VERSION:=fixture-tag}\n"):
            (self.mingw / "build-llvm.sh").write_bytes(text)
            self.relock()
            self.reject("default")

    def test_mandatory_root_credit_and_reviewed_header_bytes(self):
        self.lock["required_inputs"]["libcxx/include/__mdspan/extents.h"]["sha256"] = "0" * 64
        self.save_lock()
        self.reject("mandatory notice/credit checksum")
        missing = self.source / "compiler-rt/CREDITS.TXT"
        missing.unlink()
        self.lock["llvm"].update(self.commit(self.source))
        self.save_lock()
        self.reject("missing mandatory source")

    def test_missing_scoped_payload_even_without_credit_markers_fails(self):
        (self.source / "libcxx/no-marker.cpp").unlink()
        llvm.git(self.source, "update-index", "--skip-worktree", "libcxx/no-marker.cpp")
        self.reject("regular")

    def test_dirty_staged_wrong_and_descendant_trees(self):
        file = self.source / "outside.c"
        original = file.read_bytes()
        file.write_bytes(original + b"dirty")
        self.reject()
        llvm.git(self.source, "add", "outside.c")
        self.reject()
        self.commit(self.source)
        self.reject("exact commit/tree")
        (self.mingw / "Dockerfile").write_bytes(b"dirty")
        self.reject()

    def test_assume_unchanged_and_skip_worktree_flags_cannot_hide_dirty_inputs(self):
        for flag in ("--assume-unchanged", "--skip-worktree"):
            llvm.git(self.source, "update-index", flag, "outside.c")
            self.reject("hidden")
            llvm.git(self.source, "update-index", "--no-assume-unchanged", "--no-skip-worktree", "outside.c")

    def test_untracked_and_ignored_generated_source_files_fail(self):
        extra = self.file("libcxx/generated.h", b"Copyright extra")
        self.reject("untracked")
        extra.unlink()
        self.file(".gitignore", b"generated.h\n")
        self.relock()
        self.file("libcxx/generated.h", b"Copyright ignored")
        self.reject("untracked")

    def test_symlinked_sources_parents_and_notice_entries_fail(self):
        alias = self.root / "alias"
        alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            llvm.collect(self.repo, alias, self.mingw, self.out)
        file = self.source / "libcxx/nested/NOTICE.txt"
        file.unlink()
        file.symlink_to("../../LICENSE.TXT")
        self.lock["llvm"].update(self.commit(self.source))
        self.save_lock()
        self.reject("non-regular")

    def test_symlinked_git_metadata_is_refused(self):
        metadata = self.source / ".git"
        saved = self.root / "saved-metadata"
        metadata.rename(saved)
        metadata.symlink_to(saved, target_is_directory=True)
        self.reject("symlink")

    def test_sparse_absent_unneeded_sources_are_supported_offline(self):
        self.file("unneeded/source.c", b"int unused_source;\n")
        self.relock()
        oid = llvm.blob((self.source / "unneeded/source.c").read_bytes())
        llvm.git(self.source, "sparse-checkout", "init", "--cone")
        llvm.git(self.source, "sparse-checkout", "set", *llvm.SCOPES)
        self.assertFalse((self.source / "unneeded/source.c").exists())
        (self.source / ".git/objects" / oid[:2] / oid[2:]).unlink()
        self.collect()
        self.verify()

    def test_nested_gitlinks_and_unsafe_committed_paths_fail(self):
        llvm.git(self.source, "update-index", "--add", "--cacheinfo", "160000",
                 self.lock["llvm"]["commit"], "libcxx/nested-child")
        (self.source / "libcxx/nested-child").mkdir()
        llvm.git(self.source, "commit", "-qm", "fixture gitlink")
        self.lock["llvm"].update({"commit": llvm.git(self.source, "rev-parse", "HEAD").decode().strip(),
                                   "tree": llvm.git(self.source, "rev-parse", "HEAD^{tree}").decode().strip()})
        self.save_lock()
        self.reject("non-regular")
        llvm.git(self.source, "rm", "--cached", "libcxx/nested-child")
        self.file("libcxx/bad\nNOTICE", b"credit")
        self.relock()
        self.reject("unsafe")
        for path in ("../LICENSE", "/LICENSE", "C:/NOTICE", "a\\LICENSE", "a\tLICENSE"):
            self.assertFalse(llvm.safe_source(path))

    def test_flattened_collisions_fail_without_publication(self):
        self.file("libcxx/a/NOTICE-b", b"notice")
        self.file("libcxx/a-NOTICE/b", b"Copyright collision")
        self.relock()
        self.reject("collision")

    def test_binary_credit_match_is_rejected_not_published_as_text(self):
        self.file("compiler-rt/test/binary", b"binary\0Copyright fixture")
        self.relock()
        self.reject("binary")

    def test_output_overlap_symlinks_existing_and_racing_destinations_preserved(self):
        for root in (self.source, self.mingw, self.repo):
            with self.assertRaisesRegex(ValueError, "overlaps"):
                llvm.collect(self.repo, self.source, self.mingw, root / "out")
            self.assertFalse((root / "out").exists())
        self.out.symlink_to(self.root / "missing")
        self.reject("symlink")
        self.out.unlink()
        self.out.mkdir()
        (self.out / "keep").write_bytes(b"keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.collect()
        self.assertEqual((self.out / "keep").read_bytes(), b"keep")
        (self.out / "keep").unlink()
        self.out.rmdir()
        original = llvm.publish
        def race(stage, out):
            out.mkdir()
            original(stage, out)
        with patch.object(llvm, "publish", race), self.assertRaises(OSError):
            self.collect()
        self.assertEqual(list(self.out.iterdir()), [])
        self.assertEqual(list(self.root.glob("out.partial.*")), [])

    def test_failed_payload_or_manifest_write_rolls_back_stage(self):
        original = Path.open
        for name in ("llvm-runtime-LICENSE.TXT", llvm.MANIFEST, "SHA256SUMS"):
            def fail(path, *args, **kwargs):
                if path.name == name and ".partial." in path.parent.name:
                    raise OSError("fixture failed write")
                return original(path, *args, **kwargs)
            with patch.object(Path, "open", fail):
                self.reject("failed write")

    def test_source_and_lock_changes_before_publication_are_revalidated(self):
        original = llvm.verify
        def mutate(repo, source, mingw, out):
            (source / "libcxx/no-marker.cpp").write_bytes(b"Copyright mutation")
            return original(repo, source, mingw, out)
        with patch.object(llvm, "verify", mutate):
            self.reject()
        llvm.git(self.source, "checkout", "--", "libcxx/no-marker.cpp")
        def mutate_lock(repo, source, mingw, out):
            self.lock_path.write_bytes(self.lock_path.read_bytes() + b" ")
            return original(repo, source, mingw, out)
        with patch.object(llvm, "verify", mutate_lock):
            self.reject("committed")

    def test_complete_output_revalidation_rejects_missing_extra_modified_and_links(self):
        record = self.collect()
        file = self.out / next(iter(record["collected_notices"]))
        data = file.read_bytes()
        file.unlink()
        with self.assertRaisesRegex(ValueError, "payload set"):
            self.verify()
        file.write_bytes(data + b"changed")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.verify()
        file.unlink()
        file.symlink_to(self.source / record["collected_notices"][file.name]["source"])
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()
        file.unlink()
        file.write_bytes(data)
        (self.out / "extra").mkdir()
        with self.assertRaisesRegex(ValueError, "payload set"):
            self.verify()

    def test_forged_origins_coverage_checksums_and_scope_are_rejected(self):
        record = self.collect()
        manifest = self.out / llvm.MANIFEST
        for mutate in (lambda r: r["collected_notices"].pop(next(iter(r["collected_notices"]))),
                       lambda r: r["scanned_files"].pop("libcxx/no-marker.cpp"),
                       lambda r: r.update(complete=True),
                       lambda r: r["collected_notices"][next(iter(r["collected_notices"]))].update(source="../evil"),
                       lambda r: r["lock"]["llvm"].update(commit="0" * 40)):
            changed = copy.deepcopy(record)
            mutate(changed)
            manifest.write_bytes(llvm.encoded(changed))
            # Rewriting the checksum list cannot legitimise fabricated origins.
            sums = "".join(f"{llvm.sha(p.read_bytes())}  {p.name}\n" for p in sorted(self.out.iterdir()) if p.name != "SHA256SUMS")
            (self.out / "SHA256SUMS").write_text(sums)
            with self.assertRaisesRegex(ValueError, "changed"):
                self.verify()
        manifest.write_bytes(llvm.encoded(record))
        (self.out / "SCOPE.txt").write_text("complete")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.verify()

    def test_offline_git_environment_and_missing_objects_fail(self):
        original = llvm.helpers.provenance.git
        environments = []
        def capture(root, *args, env=None):
            environments.append(env)
            return original(root, *args, env=env)
        with patch.object(llvm.helpers.provenance, "git", capture):
            self.collect()
        self.assertTrue(environments)
        self.assertTrue(all(e["GIT_NO_LAZY_FETCH"] == "1" and e["GIT_OPTIONAL_LOCKS"] == "0" for e in environments))
        oid = self.lock["llvm"]["commit"]
        (self.source / ".git/objects" / oid[:2] / oid[2:]).unlink()
        with self.assertRaises(ValueError):
            self.verify()

    def assembly(self):
        self.bundle = self.repo / ".work/assembly"
        self.bundle.mkdir(parents=True)
        self.out = self.bundle / "llvm-runtime"
        return self.collect()

    def inventory(self):
        validator = p.validate_llvm_runtime_notices
        env = {"LLVM_RUNTIME_SOURCE": str(self.source), "LLVM_MINGW_SOURCE": str(self.mingw)}
        with patch.dict(os.environ, env), patch.object(p, "validate_llvm_runtime_notices",
                lambda out: validator(out, self.repo)):
            return p.inventory(self.bundle)

    def test_assembly_preserves_full_separate_contract_and_inventory(self):
        record = self.assembly()
        (self.bundle / "unrelated.txt").write_bytes(b"unrelated")
        inventory = self.inventory()
        self.assertEqual(inventory["status"], "incomplete-inventory")
        names = {f["name"] for f in inventory["files"]}
        self.assertEqual(names, {"unrelated.txt"} | {"llvm-runtime/" + n for n in llvm.output_bytes(
            *llvm.prepare(self.repo, self.source, self.mingw))})
        self.assertIn("llvm-runtime/SCOPE.txt", names)
        self.assertIn("llvm-runtime/SHA256SUMS", names)
        self.assertEqual(self.verify(), record)
        for file in inventory["files"]:
            self.assertEqual(file["sha256"], llvm.sha((self.bundle / file["name"]).read_bytes()))

    def test_assembly_inventory_rechecks_missing_extra_changed_and_forged_outputs(self):
        record = self.assembly()
        name = next(iter(record["collected_notices"]))
        payload = self.out / name
        data = payload.read_bytes()
        payload.unlink()
        with self.assertRaisesRegex(ValueError, "payload set"):
            self.inventory()
        payload.write_bytes(data + b"changed")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.inventory()
        payload.write_bytes(data)
        extra = self.out / "unexpected"
        extra.write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "payload set"):
            self.inventory()
        extra.unlink()
        manifest = self.out / llvm.MANIFEST
        original = manifest.read_bytes()
        changed = copy.deepcopy(record)
        changed["complete"] = True
        manifest.write_bytes(llvm.encoded(changed))
        with self.assertRaisesRegex(ValueError, "changed"):
            self.inventory()
        manifest.write_bytes(original)
        self.inventory()

    def test_assembly_inventory_rechecks_scope_and_inner_checksums(self):
        self.assembly()
        for name in ("SCOPE.txt", "SHA256SUMS"):
            file = self.out / name
            original = file.read_bytes()
            file.write_bytes(b"forged")
            with self.assertRaisesRegex(ValueError, "changed"):
                self.inventory()
            file.write_bytes(original)
        self.inventory()

    def test_assembly_inventory_refuses_symlinked_directory_and_nested_extra(self):
        self.assembly()
        saved = self.bundle / "saved"
        self.out.rename(saved)
        self.out.symlink_to(saved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.inventory()
        self.out.unlink()
        saved.rename(self.out)
        (self.out / "extra-folder").mkdir()
        with self.assertRaisesRegex(ValueError, "payload set"):
            self.inventory()

    def test_assembly_inventory_requires_exact_inputs(self):
        self.assembly()
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, "requires exact"):
            p.inventory(self.bundle)
        (self.source / "libcxx/no-marker.cpp").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            self.inventory()

    def test_assembly_required_collection_cannot_be_omitted(self):
        self.bundle = self.repo / ".work/assembly"
        self.bundle.mkdir(parents=True)
        gate = self.bundle / "tree-provenance.json"
        gate.write_text(json.dumps({"required_collections": ["llvm-runtime"]}))
        with self.assertRaisesRegex(ValueError, "lack separate"):
            p.inventory(self.bundle)
        gate.unlink()
        (self.bundle / "llvm-runtime").symlink_to(self.bundle / "missing")
        with self.assertRaisesRegex(ValueError, "lack separate"):
            p.inventory(self.bundle)

    def test_assembly_rejects_flattened_root_superset_and_arbitrary_directories(self):
        self.assembly()
        extra = self.bundle / "llvm-runtime-forged"
        extra.write_bytes(b"root superset forbidden")
        with self.assertRaisesRegex(ValueError, "separate directory"):
            self.inventory()
        extra.unlink()
        (self.bundle / "unrelated-directory").mkdir()
        with self.assertRaisesRegex(ValueError, "not a regular"):
            self.inventory()

    def test_assembly_shell_failure_removes_outer_and_inner_partials(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        python = bin_dir / "python3"
        python.write_text('#!/bin/sh\ncase "$1" in *notices-llvm-runtime.py) '
                          'mkdir -p "$6"; echo "fixture LLVM refusal" >&2; exit 1 ;; esac\nexit 0\n')
        python.chmod(0o755)
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                   PLAYPORT_BUILD=str(self.repo / ".work"))
        result = subprocess.run(["bash", str(REPO / "build/notices-assemble.sh"), str(self.out)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture LLVM refusal", result.stderr)
        self.assertFalse(self.out.exists())
        self.assertFalse(list(self.root.glob("out.partial.*")))

    def test_assembly_outer_checksums_include_nested_checksum_list(self):
        self.assembly()
        self.inventory()
        command = ('find . -type f ! -path ./SHA256SUMS -print0 | sort -z | '
                   'xargs -0 sha256sum -- >SHA256SUMS && sha256sum -c --quiet SHA256SUMS')
        subprocess.run(["bash", "-c", command], cwd=self.bundle, check=True, capture_output=True)
        sums = (self.bundle / "SHA256SUMS").read_text()
        self.assertIn("  ./llvm-runtime/SHA256SUMS\n", sums)
        self.assertNotIn("  ./SHA256SUMS\n", sums)
        self.assertEqual(len(sums.splitlines()), len(list(self.out.iterdir())))

    def test_cli_inspect_collect_verify_and_failure_cleanup(self):
        base = [sys.executable, str(REPO / "build/notices-llvm-runtime.py")]
        roots = list(map(str, (self.repo, self.source, self.mingw)))
        result = subprocess.run(base + ["inspect", *roots], check=True, capture_output=True)
        self.assertFalse(json.loads(result.stdout)["complete"])
        self.assertFalse(self.out.exists())
        subprocess.run(base + ["collect", *roots, str(self.out)], check=True, capture_output=True)
        subprocess.run(base + ["verify", *roots, str(self.out)], check=True, capture_output=True)
        result = subprocess.run(base + ["collect", *roots, str(self.out)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"LLVM runtime notices", result.stderr)
        self.verify()


if __name__ == "__main__":
    unittest.main()
