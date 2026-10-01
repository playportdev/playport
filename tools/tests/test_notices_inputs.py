# SPDX-License-Identifier: GPL-3.0-or-later
"""The notice collection's inputs (build/notices-inputs.py) come only from their
committed locks, are prepared without debris and never replace what is there, and
the pipeline's notices stage stages the app's Licenses/ for both variants."""

import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml

REPO = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


inputs = load("notices_inputs", "build/notices-inputs.py")
stage_artifacts = load("stage_artifacts", "build/stages/stage-artifacts.py")


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


class Locks(unittest.TestCase):
    def test_every_input_comes_from_a_lock_with_a_full_identity(self):
        items = inputs.inputs(env={})
        kinds = [i[0] for i in items]
        self.assertEqual(kinds.count("git"), 3)
        self.assertEqual(len([i for i in items if i[1].startswith("rust-dist/")]), 3)
        self.assertEqual(len([i for i in items if i[1].startswith("gstreamer-notices/sources/")]), 17)
        self.assertEqual(len({i[1] for i in items}), len(items))
        for kind, rel, source, ident, extra, var in items:
            self.assertTrue(source.startswith("https://"), rel)
            self.assertRegex(ident, r"^[0-9a-f]{40}$" if kind == "git" else r"^[0-9a-f]{64}$")
        runtime = next(i for i in items if i[1] == "llvm-runtime-notices")
        self.assertEqual(runtime[4], list(inputs.llvm_runtime.SCOPES))

    def test_an_input_named_by_its_variable_is_left_alone(self):
        items = inputs.inputs(env={"GST_NOTICE_SOURCES": "/elsewhere", "MINGW_SOURCE": "/elsewhere"})
        rels = [i[1] for i in items]
        self.assertNotIn("mingw-w64-notices", rels)
        self.assertFalse(any(r.startswith("gstreamer-notices/sources/") for r in rels))
        self.assertIn("gstreamer-notices/cerbero.tar.gz", rels)


class Prepare(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp(dir=os.environ.get("TMPDIR")))
        self.body = b"locked bytes\n"
        self.item = ("file", "dist/a.tar.xz", "https://example.invalid/a", hashlib.sha256(self.body).hexdigest(),
                     None, "SOME_VAR")
        self.calls = []

    def tearDown(self):
        shutil.rmtree(self.d)

    def fetchers(self, body):
        def fetch(src, ident, extra, part):
            self.calls.append(src)
            part.write_bytes(body)
        return {"file": fetch}

    def debris(self):
        return [p.name for p in (self.d / "dist").iterdir() if ".partial." in p.name] if (self.d / "dist").exists() else []

    def test_a_missing_input_is_prepared_once(self):
        self.assertEqual(inputs.prepare(self.d, [self.item], fetchers=self.fetchers(self.body)), ["dist/a.tar.xz"])
        self.assertEqual((self.d / "dist/a.tar.xz").read_bytes(), self.body)
        self.assertEqual(inputs.prepare(self.d, [self.item], fetchers=self.fetchers(self.body)), [])
        self.assertEqual(len(self.calls), 1)

    def test_plan_fetches_nothing(self):
        self.assertEqual(inputs.prepare(self.d, [self.item], plan=True, fetchers=self.fetchers(self.body)),
                         ["dist/a.tar.xz"])
        self.assertEqual(self.calls, [])
        self.assertFalse((self.d / "dist").exists())

    def test_wrong_bytes_leave_nothing(self):
        with self.assertRaises(ValueError):
            inputs.prepare(self.d, [self.item], fetchers=self.fetchers(b"other\n"))
        self.assertFalse((self.d / "dist/a.tar.xz").exists())
        self.assertEqual(self.debris(), [])

    def test_a_failed_fetch_leaves_nothing(self):
        def fail(src, ident, extra, part):
            part.write_bytes(b"half")
            raise subprocess.CalledProcessError(22, "curl")
        with self.assertRaises(subprocess.CalledProcessError):
            inputs.prepare(self.d, [self.item], fetchers={"file": fail})
        self.assertFalse((self.d / "dist/a.tar.xz").exists())
        self.assertEqual(self.debris(), [])

    def test_a_different_file_is_refused_not_replaced(self):
        (self.d / "dist").mkdir()
        (self.d / "dist/a.tar.xz").write_bytes(b"someone else's\n")
        with self.assertRaisesRegex(ValueError, "remove it to prepare it again, or name another with SOME_VAR"):
            inputs.prepare(self.d, [self.item], fetchers=self.fetchers(self.body))
        self.assertEqual((self.d / "dist/a.tar.xz").read_bytes(), b"someone else's\n")
        self.assertEqual(self.calls, [])

    def test_a_symlinked_input_is_refused(self):
        (self.d / "dist").mkdir()
        (self.d / "real").write_bytes(self.body)
        (self.d / "dist/a.tar.xz").symlink_to(self.d / "real")
        with self.assertRaisesRegex(ValueError, "symlink"):
            inputs.prepare(self.d, [self.item], fetchers=self.fetchers(self.body))


class GitInputs(unittest.TestCase):
    """fetch_git against a local repository: the locked commit, sparse scopes with
    the root's files, no remote left to fetch a missing blob from."""

    def setUp(self):
        self.d = Path(tempfile.mkdtemp(dir=os.environ.get("TMPDIR")))
        self.src = self.d / "src"
        self.src.mkdir()
        git(self.src, "init", "-q")
        for rel, body in {"LICENSE.TXT": "L\n", "libcxx/x.h": "x\n", "llvm/big.c": "big\n"}.items():
            (self.src / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.src / rel).write_text(body)
        git(self.src, "add", "-A")
        git(self.src, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "one")
        self.commit = git(self.src, "rev-parse", "HEAD")
        self.big = git(self.src, "rev-parse", "HEAD:llvm/big.c")
        (self.src / "later").write_text("later\n")
        git(self.src, "add", "-A")
        git(self.src, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "two")
        git(self.src, "config", "uploadpack.allowFilter", "true")
        git(self.src, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.url = "file://" + str(self.src)

    def tearDown(self):
        shutil.rmtree(self.d)

    def test_a_sparse_checkout_at_the_locked_commit(self):
        out = self.d / "cache" / "llvm-runtime-notices"
        out.parent.mkdir()
        inputs.fetch_git(self.url, self.commit, ["libcxx"], out)
        self.assertEqual(git(out, "rev-parse", "HEAD"), self.commit)
        self.assertTrue((out / "LICENSE.TXT").is_file())
        self.assertTrue((out / "libcxx/x.h").is_file())
        self.assertFalse((out / "llvm").exists())
        self.assertFalse((out / "later").exists())
        self.assertEqual(inputs.state("git", out, self.commit), "ok")
        self.assertEqual(git(out, "remote"), "")
        r = subprocess.run(["git", "-C", str(out), "cat-file", "-p", self.big], capture_output=True)
        self.assertNotEqual(r.returncode, 0)

    def test_a_wrong_or_dirty_checkout_is_reported(self):
        out = self.d / "mingw"
        inputs.fetch_git(self.url, self.commit, None, out)
        self.assertEqual(inputs.state("git", out, self.commit), "ok")
        self.assertTrue((out / "llvm/big.c").is_file())
        self.assertIn("is at", inputs.state("git", out, "0" * 40))
        (out / "stray").write_text("x\n")
        self.assertIn("local changes", inputs.state("git", out, self.commit))
        (out / "stray").unlink()
        (out / "libcxx/x.h").write_text("edited\n")
        self.assertIn("local changes", inputs.state("git", out, self.commit))
        self.assertIn("not a Git checkout root", inputs.state("git", out / "libcxx", self.commit))


class Pipeline(unittest.TestCase):
    def setUp(self):
        self.text = (REPO / "build/pipeline").read_text()

    def test_notices_runs_between_stage_and_app(self):
        stages = re.search(r"^STAGES=\((.*)\)$", self.text, re.M).group(1).split()
        self.assertEqual(stages[stages.index("stage"):], ["stage", "notices", "app", "verify"])
        agents = (REPO / "AGENTS.md").read_text()
        self.assertIn("`" + " ".join(stages) + "`", agents)

    def test_its_digest_names_files_the_repository_has(self):
        case = re.search(r"^        notices\) (.*?);;$", self.text, re.M | re.S).group(1)
        words = case.replace("\\\n", " ").split()
        files = words[words.index("files") + 1:words.index("for")]
        for f in files:
            # Globs are git pathspecs, quoted so the shell does not expand them elsewhere.
            if "*" in f:
                self.assertTrue(f.startswith("'") and f.endswith("'"), f)
            got = subprocess.run(["git", "-C", str(REPO), "ls-files", "--", f.strip("'")],
                                 capture_output=True, text=True, check=True).stdout.split()
            self.assertTrue(got, f"{f} names no tracked file")
        self.assertIn("build/app-notices.json", files)

    def test_both_variants_ship_the_staged_licenses(self):
        dev = (REPO / "app/xtool.yml").read_text()
        self.assertIn("Staged/Licenses", yaml.safe_load(dev)["resources"])
        rel = yaml.safe_load(stage_artifacts.release_xtool_yml(dev))
        self.assertIn("Staged/Licenses", rel["resources"])
        self.assertIn("Staged", stage_artifacts.RELEASE_LINKS)

    def test_verify_compares_the_ipa_with_the_staged_bundle(self):
        self.assertIn('--notices "$APP/Staged/Licenses"', self.text)


if __name__ == "__main__":
    unittest.main()
