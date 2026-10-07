# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/checks.py: the secret patterns and the patch series checks pp test runs."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import checks  # noqa: E402

PIN = "1" * 40
PATCH = """From 0 Mon Sep 17 00:00:00 2001
Subject: [PATCH] a change

Why it is needed.

Class: build-fix
Evidence: docs/evidence/x.md
Offered-upstream: no
---
diff --git a/f b/f
"""


class Secrets(unittest.TestCase):
    def test_hits_and_fixtures(self):
        # Made up, and split so that pp secrets does not find them in this file.
        steam_id, team = "7656119" + "8000000000", "XTL-" + "ABCDE12345."
        self.assertEqual([w for w, _ in checks.secret_hits(f"id {steam_id}\nnothing here")], ["SteamID64"])
        self.assertEqual(checks.secret_hits("XTL-TEAMIDXXXX.dev.playport.app"), [])
        self.assertEqual([w for w, _ in checks.secret_hits(team + "com.x")], ["team ID in a bundle ID"])

    def test_encrypted_app_ticket(self):
        line = "tic" + "ket=" + "CAIQ" * 20   # split, as above
        self.assertEqual([w for w, _ in checks.secret_hits(line)], ["Steam encrypted app ticket"])
        self.assertEqual(checks.secret_hits("ticket=CAIQ/wB/ ticket=<redacted> ticket: fetched, 240 bytes"), [])

    def test_home_paths(self):
        home = "/ho" + "me/alice/"   # split, as above
        self.assertEqual([w for w, _ in checks.secret_hits(f"IPA {home}x.ipa")], ["a workstation's home path"])
        self.assertEqual([w for w, _ in checks.secret_hits("/Us" + "ers/bob/x")], ["a workstation's home path"])
        self.assertEqual(checks.secret_hits("IPA $PLAYPORT_BUILD/out/x.ipa ~/.local/bin .work/run /home/someone/x"), [])

    def test_evidence_media(self):
        import re
        hit = lambda f: bool(re.search(checks.EVIDENCE_MEDIA, f, re.I))
        self.assertTrue(hit("docs/evidence/2026-09-30-x/title.JPG"))
        self.assertTrue(hit("docs/evidence/a/b/run.mp4"))
        self.assertFalse(hit("app/Icon/AppIcon.png"))
        self.assertFalse(hit("docs/evidence/2026-09-30-x.md"))


class Inputs(unittest.TestCase):
    """build/inputs.py: this machine's tool paths, from inputs.local or the environment."""

    def setUp(self):
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build"))
        import inputs
        self.inputs = inputs
        self.dir = tempfile.mkdtemp()
        self.file = __import__("pathlib").Path(self.dir, "inputs.local")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def test_round_trip_and_shell(self):
        self.inputs.write({"LLVM_MINGW": "/opt/llvm mingw", "EXTRA": "x"}, self.file)
        self.assertEqual(self.inputs.read(self.file), {"LLVM_MINGW": "/opt/llvm mingw", "EXTRA": "x"})
        # build/env.sh sources the same file.
        got = subprocess.run(["bash", "-c", f". '{self.file}' && echo \"$LLVM_MINGW\""],
                             capture_output=True, text=True).stdout
        self.assertEqual(got, "/opt/llvm mingw\n")

    def test_absent_file(self):
        self.assertEqual(self.inputs.read(self.file), {})


class Patches(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp()
        subprocess.run(["git", "init", "-q", self.repo], check=True)
        subprocess.run(["git", "-C", self.repo, "update-index", "--add", "--cacheinfo",
                        f"160000,{PIN},upstream/madeira"], check=True)
        with open(os.path.join(self.repo, "pins.lock"), "w") as f:
            f.write(f"# name commit repository branch\nmadeira {PIN} url main\n")
        self.d = os.path.join(self.repo, "patches", "wine-pe")
        os.makedirs(self.d)
        self.add("0001-a.patch", PATCH)
        self.series("0001-a.patch")

    def tearDown(self):
        shutil.rmtree(self.repo)

    def add(self, name, text):
        with open(os.path.join(self.d, name), "w") as f:
            f.write(text)

    def series(self, *names):
        with open(os.path.join(self.d, "series"), "w") as f:
            f.write("# wine-pe\n" + "".join(n + "\n" for n in names))

    def test_clean(self):
        self.assertEqual(checks.patch_problems(self.repo), [])

    def test_each_problem(self):
        self.add("0002-b.patch", PATCH.replace("Offered-upstream: no\n", ""))
        self.add("0003-c.patch", PATCH.replace("build-fix", "madeira-port"))
        self.series("0001-a.patch", "0002-b.patch", "0003-c.patch", "0004-gone.patch")
        self.add("0005-stray.patch", PATCH.replace("build-fix", "misc"))
        with open(os.path.join(self.repo, "pins.lock"), "w") as f:
            f.write("madeira " + "2" * 40 + " url main\n")
        bad = "\n".join(checks.patch_problems(self.repo))
        self.assertIn("is not the upstream/madeira gitlink", bad)
        self.assertIn("0002-b.patch has no Offered-upstream: trailer", bad)
        self.assertIn("0003-c.patch: Class: madeira-port belongs in a *-port series or madeira-unix only", bad)
        self.assertIn("lists 0004-gone.patch, which does not exist", bad)
        self.assertIn("0005-stray.patch is not in its series", bad)
        self.assertIn("Class: misc is not one of", bad)

    def test_valve_class_only_in_wine_valve(self):
        self.add("0002-b.patch", PATCH.replace("build-fix", "valve"))
        self.series("0001-a.patch", "0002-b.patch")
        self.assertIn("0002-b.patch: patches/wine-valve holds class valve, and only it",
                      "\n".join(checks.patch_problems(self.repo)))
        self.d = os.path.join(self.repo, "patches", "wine-valve")
        os.makedirs(self.d)
        valve = PATCH.replace("Class: build-fix", "Valve-commit: " + "3" * 40 + "\nPicked: clean\nClass: valve")
        self.add("0001-v.patch", valve)
        self.add("0002-w.patch", valve.replace("Picked: clean\n", ""))
        self.add("0003-x.patch", PATCH)
        self.series("0001-v.patch", "0002-w.patch", "0003-x.patch")
        bad = "\n".join(checks.patch_problems(self.repo))
        self.assertNotIn("0001-v.patch", bad)
        self.assertIn("patches/wine-valve/0002-w.patch has no Picked: trailer", bad)
        self.assertIn("0003-x.patch: patches/wine-valve holds class valve, and only it", bad)

    def test_a_trailer_in_the_diff_does_not_count(self):
        self.add("0001-a.patch", PATCH.replace("Evidence: docs/evidence/x.md\n", "") + "+Evidence: x\n")
        self.assertIn("has no Evidence: trailer", "\n".join(checks.patch_problems(self.repo)))



def load_pp():
    """The pp script as a module (it has no .py name)."""
    import importlib.machinery
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "pp")
    loader = importlib.machinery.SourceFileLoader("pp_cli", path)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("pp_cli", loader))
    loader.exec_module(mod)
    return mod


class Cli(unittest.TestCase):
    """pp's own argument handling that runs nothing."""

    @classmethod
    def setUpClass(cls):
        cls.pp = load_pp()

    def test_swift_package_by_short_name(self):
        self.assertEqual(self.pp.swift_package("PlayportKit"), "app/PlayportKit")
        self.assertEqual(self.pp.swift_package("app/SteamClient/"), "app/SteamClient")
        self.assertIsNone(self.pp.swift_package("Nope"))
        self.assertEqual(self.pp.swift_test("app/PlayportKit", ["--filter", "X"])[-2:], ["--filter", "X"])

    def test_usage_has_continuation_lines(self):
        u = self.pp.usage("test")
        self.assertTrue(u.startswith("  pp test [--quick]"))
        self.assertIn("--swift PKG", u)
        self.assertNotIn("pp names", u)



PIPELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "pipeline")


class KeepRecords(unittest.TestCase):
    """build/pipeline keep_records: only the checkout's own .work/run keeps the
    committed build records; elsewhere (PLAYPORT_RUN, a pp sync candidate) they go
    beside the IPA."""

    def setUp(self):
        self.d = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
        self.main = os.path.join(self.d, "main")
        os.makedirs(os.path.join(self.main, "app"))
        os.makedirs(os.path.join(self.main, "build", "generated"))
        git = lambda *a, cwd=self.main: subprocess.run(["git", "-C", cwd, *a], check=True, capture_output=True)
        git("init", "-q")
        for f in ("app/artifacts.tsv", "build/generated/wine-pe-aarch64-windows.tsv"):
            with open(os.path.join(self.main, f), "w") as fh:
                fh.write("committed\n")
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x")
        with open(PIPELINE) as f:
            text = f.read()
        self.fn = text[text.index("keep_records() {"):]
        self.fn = self.fn[:self.fn.index("\n}\n") + 3]

    def tearDown(self):
        shutil.rmtree(self.d)

    def keep(self, repo, run, recorded=True):
        for f in ("app/artifacts.tsv", "build/generated/wine-pe-aarch64-windows.tsv"):
            with open(os.path.join(repo, f), "w") as fh:
                fh.write("rebuilt\n")
        dest = os.path.join(self.d, "out")
        script = self.fn + '\nsay() { echo "$*"; }\nkeep_records "$DEST"\n'
        env = dict(os.environ, RUN=run, PLAYPORT_REPO=repo, APP=repo + "/app", DEST=dest,
                   RECORDED="1" if recorded else "0")
        out = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, check=True).stdout
        with open(os.path.join(repo, "app/artifacts.tsv")) as f:
            return out, dest, f.read()

    def test_main_run_keeps_the_records(self):
        out, dest, now = self.keep(self.main, os.path.join(self.main, ".work", "run"))
        self.assertEqual((out, now), ("", "rebuilt\n"))
        self.assertFalse(os.path.exists(dest))

    def test_a_run_that_wrote_no_records_leaves_them_alone(self):
        # A run elsewhere that stopped before the stage stage (pp test runs one to
        # --to inputs): the records in the checkout are someone else's to commit.
        out, dest, now = self.keep(self.main, os.path.join(self.d, "elsewhere", "run"), recorded=False)
        self.assertEqual((out, now), ("", "rebuilt\n"))
        self.assertFalse(os.path.exists(dest))

    def test_another_run_directory_puts_them_back(self):
        out, dest, now = self.keep(self.main, os.path.join(self.d, "sync", "build-run"))
        self.assertEqual(now, "committed\n")
        self.assertIn("not kept", out)
        self.assertEqual(sorted(os.listdir(os.path.join(dest, "records"))),
                         ["artifacts.tsv", "wine-pe-aarch64-windows.tsv"])
        with open(os.path.join(dest, "records", "artifacts.tsv")) as f:
            self.assertEqual(f.read(), "rebuilt\n")


if __name__ == "__main__":
    unittest.main()
