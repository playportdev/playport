# SPDX-License-Identifier: GPL-3.0-or-later
"""The app's Licenses/ selection (build/app-notices.json, build/notices-app.py): every
IPA part has a component, every collected file is classified, and the output is a
whole bundle that `pp verify --distribution` accepts only once reviewed."""

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
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


app = load("notices_app", "build/notices-app.py")
verify = load("verify_ipa", "build/verify-ipa.py")
bundle = app.bundle
SELECTION = app.load()
UNREVIEWED = copy.deepcopy(SELECTION)
UNREVIEWED["review"] = {"status": "unreviewed", "open": ["a question a reviewer must settle"]}
EXCLUDED = ["tree-provenance.json", "notice-origins.json", "gstreamer-source-inventory.json",
            "llvm-runtime/SHA256SUMS", "llvm-runtime/SCOPE.txt", "llvm-runtime/llvm-runtime-provenance.json",
            "llvm-runtime/llvm-runtime-libcxx-test-std-foo.cpp", "rust-plist_ffi-1.0.0-src-plist.h",
            "rust-plist-macro-0.1.0-README.md"]


def concrete(pattern):
    return re.sub(r"\[0-9\]", "1", pattern).replace("*", "x")


def collected():
    """One file per include pattern, and files every exclude group drops."""
    names = {concrete(p) for c in SELECTION["components"] for p in c["include"]}
    return {n: f"notice {n}\n".encode() for n in sorted(names | set(EXCLUDED))}


def make(root, files):
    root.mkdir(parents=True)
    for name, body in files.items():
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_bytes(body)
    entries = [{"name": n, "size": len(b), "sha256": hashlib.sha256(b).hexdigest()} for n, b in sorted(files.items())]
    (root / "inventory.json").write_text(json.dumps({"schema": 1, "status": "incomplete-inventory", "files": entries}))
    names = sorted(files) + ["inventory.json"]
    (root / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256((root / n).read_bytes()).hexdigest()}  ./{n}\n" for n in names))
    return root


class Selection(unittest.TestCase):
    def setUp(self):
        scratch = REPO / ".work/tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.temp.name)
        self.files = collected()
        self.src = make(self.root / "notices", self.files)
        self.out = self.root / "Licenses"

    def tearDown(self):
        self.temp.cleanup()

    def test_every_part_of_the_committed_ipa_has_a_component(self):
        self.assertEqual(app.coverage(SELECTION, app.ARTIFACTS.read_text()), [])

    def test_coverage_finds_a_new_part_and_an_unknown_one(self):
        tsv = app.ARTIFACTS.read_text() + "resource\tRuntime/new.dll\t1\t" + "0" * 64 + "\tr\ts\tP99-new\n"
        self.assertEqual(app.coverage(SELECTION, tsv), ["no component covers P99-new"])
        sel = copy.deepcopy(SELECTION)
        sel["components"][0]["covers"].append("P0-gone")
        self.assertEqual(app.coverage(sel, app.ARTIFACTS.read_text()), ["a component covers unknown part P0-gone"])
        gap = "gap\tRuntime/x.drv\tnot built\n"
        self.assertEqual(app.artifact_keys(gap), set())

    def test_select_carries_the_components_files_and_drops_the_excluded(self):
        r = app.select(self.src, self.out, UNREVIEWED)
        self.assertEqual(r["status"], app.UNREVIEWED)
        self.assertEqual(bundle.check(self.out)["status"], app.UNREVIEWED)
        for name in EXCLUDED:
            self.assertFalse((self.out / name).exists(), name)
        self.assertEqual((self.out / "llvm-runtime/llvm-runtime-libcxx-LICENSE.TXT").read_bytes(),
                         self.files["llvm-runtime/llvm-runtime-libcxx-LICENSE.TXT"])
        data = json.loads((self.out / "components.json").read_text())
        by = {c["name"]: c for c in data["components"]}
        self.assertEqual(by["Playport"]["files"], ["Playport-LICENSE-EXCEPTION.md", "Playport-LICENSE.txt"])
        self.assertIn("LGPL-2.1.txt", by["Wine"]["files"])
        self.assertIn("LGPL-2.1.txt", by["DXMT"]["files"])
        self.assertEqual(data["credits"], SELECTION["credits"])
        self.assertEqual(data["open"], UNREVIEWED["review"]["open"])
        self.assertIn("Independent JPEG Group", (self.out / "CREDITS.txt").read_text())
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["Licenses", "notices"])

    def test_except_keeps_other_files_out_of_a_component(self):
        app.select(self.src, self.out)
        idevice = next(c for c in json.loads((self.out / "components.json").read_text())["components"]
                       if c["covers"] == ["P10-idevice"])
        self.assertIn("rust-x-1x", idevice["files"])
        self.assertFalse(any(f.startswith(("rust-source-", "rust-licenses-", "rust-plist")) for f in idevice["files"]))

    def test_an_unclassified_file_fails_without_output(self):
        files = {**self.files, "newlib-LICENSE.txt": b"new\n"}
        src = make(self.root / "more", files)
        with self.assertRaisesRegex(ValueError, "does not classify: newlib-LICENSE.txt"):
            app.select(src, self.out)
        self.assertFalse(self.out.exists())
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["more", "notices"])

    def test_a_pattern_naming_no_file_fails(self):
        files = dict(self.files)
        del files["StikJIT-LICENSE.txt"]
        with self.assertRaisesRegex(ValueError, "StikJIT: StikJIT-LICENSE.txt"):
            app.select(make(self.root / "fewer", files), self.out)

    def test_a_damaged_collection_or_existing_output_is_refused(self):
        (self.src / "FEX-x").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "differ from SHA256SUMS"):
            app.select(self.src, self.out)
        self.out.mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            app.select(make(self.root / "fresh", self.files), self.out)

    def test_malformed_selections_are_refused(self):
        for change in (lambda s: s.update(schema=2), lambda s: s["components"][0].pop("licence"),
                       lambda s: s["components"].append(dict(s["components"][0])),
                       lambda s: s["exclude"].append({"why": "", "patterns": ["x"]}),
                       lambda s: s["components"][0].update(extra=1)):
            sel = copy.deepcopy(SELECTION)
            change(sel)
            path = self.root / "sel.json"
            path.write_text(json.dumps(sel))
            with self.assertRaises(ValueError):
                app.load(path)

    def test_a_reviewed_selection_is_distributable_in_pp_verify(self):
        sel = copy.deepcopy(SELECTION)
        sel["review"]["status"] = bundle.RELEASE_STATUS
        app.select(self.src, self.root / "Playport.app/Licenses", sel)
        verify.failures.clear()
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                verify.notice_checks(self.root / "Playport.app", distribution=True, artifacts=app.ARTIFACTS.read_text())
            self.assertEqual(verify.failures, [])
            with contextlib.redirect_stdout(io.StringIO()):
                verify.notice_checks(self.root / "Playport.app", artifacts="resource\tx\t1\th\tr\ts\tP99-new\n")
            self.assertEqual(len(verify.failures), 1)
            self.assertIn("P99-new", verify.failures[0])
        finally:
            verify.failures.clear()

    def test_the_committed_selection_records_its_review(self):
        # Reviewed with nothing open, or not reviewed with what is open named
        # (the fallback fonts wait for the owner's review: docs/DISTRIBUTION.md).
        review = SELECTION["review"]
        self.assertTrue(review["reviewed_by"] and review["date"] and review["answers"])
        self.assertTrue((REPO / review["decision"]).is_file())
        self.assertEqual(review["status"] == bundle.RELEASE_STATUS, review["open"] == [])

    def test_an_unreviewed_selection_fails_a_distribution(self):
        app.select(self.src, self.root / "Playport.app/Licenses", UNREVIEWED)
        verify.failures.clear()
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                verify.notice_checks(self.root / "Playport.app", distribution=True, artifacts=app.ARTIFACTS.read_text())
            self.assertEqual(len(verify.failures), 1)
            self.assertIn("release-reviewed", verify.failures[0])
        finally:
            verify.failures.clear()

    def test_cli(self):
        run = lambda *a: subprocess.run([sys.executable, str(REPO / "build/notices-app.py"), *map(str, a)],
                                        capture_output=True, text=True)
        self.assertEqual(run("coverage").returncode, 0)
        r = run("select", self.src, self.out)
        self.assertEqual(r.returncode, 0, r.stderr)
        reviewed = SELECTION["review"]["status"] == bundle.RELEASE_STATUS
        self.assertIn("status " + (bundle.RELEASE_STATUS if reviewed else app.UNREVIEWED), r.stdout)
        r = run("select", self.src, self.out)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("app notices:", r.stderr)


if __name__ == "__main__":
    unittest.main()
