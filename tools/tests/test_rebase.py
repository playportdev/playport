# SPDX-License-Identifier: GPL-3.0-or-later
"""pp rebase (tools/rebase.py) on a small synthetic FEX, its patches/fex-port and
patches/fex and a Playport copy, all local: a clean replay, the trial's
conflict counted once, a stop and --continue, rerere reusing that resolution on
a second run, the range-diff flag on an auto-merged patch, the Rebased: trailer,
a patch already upstream, and the re-export applied again and matched by
build/lib.sh check_series. No network, no toolchain.

  python3 -m unittest discover -s tools/tests
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_upstream_sync import ENV, commit, git, lines, new_repo

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TOOL = os.path.join(ROOT, "tools", "rebase.py")
LIB = os.path.join(ROOT, "build", "lib.sh")


def read(path):
    with open(path) as f:
        return f.read()


def trailer(msg, rebased=None):
    return msg + ("\n\nMadeira-commit: 0\nRebased: " + rebased if rebased else "\n") + \
        "\nClass: madeira-port\nEvidence: x\nOffered-upstream: no"


class Rebase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rebase-test-")
        t = self.tmp
        rpm = new_repo(f"{t}/rpmalloc")
        self.rpm = commit(rpm, "rpmalloc", **{"r.c": "r\n"})
        self.rpm2 = commit(rpm, "rpmalloc moves", **{"r.c": "r2\n"})
        fex = new_repo(f"{t}/FEX")
        base = {"a.c": lines(20), "b.c": lines(20), "c.c": lines(20), "e.c": lines(5)}
        self.b0 = commit(fex, "fex", links=[("External/rpmalloc", self.rpm)], **base)
        link = [("External/rpmalloc", self.rpm)]
        # fex-port: P1 a.c, P2 b.c line 10 (upstream edits it too), P3 b.c line 12
        # (its context has line 10: applies only on P2), P5 e.c (upstream makes the same change).
        commit(fex, trailer("P1 port a", "resolved"), links=link, **{"a.c": lines(20, l2="port 2")})
        commit(fex, trailer("P2 port b10", "clean"), links=link, **{"b.c": lines(20, l10="port 10")})
        commit(fex, trailer("P3 port b12", "clean"), links=link, **{"b.c": lines(20, l10="port 10", l12="port 12")})
        commit(fex, trailer("P5 port e3", "clean"), links=link, **{"e.c": lines(5, l3="both")})
        # fex: P4 c.c line 5 (upstream edits line 7, in its context: a 3-way merge).
        commit(fex, trailer("P4 playport c5"), links=link, **{"c.c": lines(20, l5="fex 5")})
        repo = self.repo = f"{t}/playport"
        for s, rng in (("fex-port", f"{self.b0}..HEAD~1"), ("fex", "HEAD~1..HEAD")):
            d = f"{repo}/patches/{s}"
            git(fex, "-c", "core.abbrev=7", "format-patch", "-q", "--zero-commit", "--no-signature", "-o", d, rng)
            with open(f"{d}/series", "w") as f:
                f.write(f"# {s}\n" + "".join(n + "\n" for n in sorted(os.listdir(d)) if n.endswith(".patch")))
        git(fex, "reset", "-q", "--hard", self.b0)
        # n0: upstream touches only d.c; n1: edits b.c line 10, c.c line 7, e.c line 3, rpmalloc.
        self.n0 = commit(fex, "upstream d", links=link, **{"d.c": "d\n"})
        self.n1 = commit(fex, "upstream b, c, e", links=[("External/rpmalloc", self.rpm2)],
                         **{"b.c": lines(20, l10="up 10"), "c.c": lines(20, l7="up 7"), "e.c": lines(5, l3="both")})
        git(fex, "branch", "-q", "next", self.n1)
        with open(f"{repo}/pins.lock", "w") as f:
            f.write(f"fex {self.b0} {fex} main\nrpmalloc {self.rpm} {rpm} fex\n")
        self.originals = {s: {n: read(f"{repo}/patches/{s}/{n}") for n in os.listdir(f"{repo}/patches/{s}")}
                          for s in ("fex-port", "fex")}
        self.build = f"{t}/build"
        os.makedirs(f"{self.build}/cache")
        subprocess.run(["git", "clone", "-q", "--bare", fex, f"{self.build}/cache/fex.git"], check=True,
                       env=dict(os.environ, **ENV))
        self.run_dir = f"{self.build}/rebase/fex"
        self.tree = f"{self.run_dir}/tree"

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def pp(self, *args, code=0):
        r = subprocess.run([sys.executable, TOOL, *args], text=True, capture_output=True,
                           env=dict(os.environ, **ENV, PLAYPORT_REPO=self.repo, PLAYPORT_BUILD=self.build))
        self.assertEqual(r.returncode, code, r.stdout + r.stderr)
        return r.stdout

    def trial_classes(self, new):
        with open(f"{self.run_dir}/trial-{new[:12]}.tsv") as f:
            return {l.split("\t")[1][:7]: l.split("\t")[2] for l in f.read().splitlines()[1:]}

    def check_series(self, tree, pin):
        """build/lib.sh check_series, reading this test's patches/."""
        r = subprocess.run(["bash", "-c", f'. "{LIB}"; PLAYPORT_REPO="{self.repo}"; '
                            f'check_series "{tree}" "fex-port fex" {pin} External/rpmalloc'],
                           text=True, capture_output=True, env=dict(os.environ, **ENV, PLAYPORT_BUILD=self.build))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def resolve_p2(self):
        with open(f"{self.tree}/b.c", "w") as f:
            f.write(lines(20, l10="up 10, port 10"))
        git(self.tree, "add", "b.c")

    def test_clean_replay_reexports_the_same_series(self):
        self.pp("fex", self.n0)
        self.assertEqual(read(f"{self.run_dir}/flags.txt"), "")
        self.assertEqual(read(f"{self.run_dir}/series.diff"), "")
        for s, files in self.originals.items():
            for n, text in files.items():
                self.assertEqual(read(f"{self.run_dir}/patches/{s}/{n}"), text, n)

    def test_trial_counts_a_conflict_once(self):
        out = self.pp("fex", "next", "--trial")
        c = self.trial_classes(self.n1)
        self.assertEqual(c, {"0001-P1": "clean", "0002-P2": "conflict", "0003-P3": "clean", "0004-P5": "upstream",
                             "0001-P4": "3-way"}, out)
        self.assertIn("moves rpmalloc", out)
        self.assertFalse(os.path.exists(self.tree))
        self.assertEqual(os.listdir(f"{self.build}/rebase/rr-cache/fex"), [])

    def test_conflict_stop_continue_rerere_range_diff_and_reexport(self):
        out = self.pp("fex", "next", code=10)
        self.assertIn("0002-P2", out)
        self.pp("fex", "--continue", code=1)  # b.c is still unmerged
        self.resolve_p2()
        out = self.pp("fex", "--continue")
        flags = read(f"{self.run_dir}/flags.txt")
        # P3's and P4's context changed under them with no person looking; P2 a person resolved.
        self.assertIn("0003-P3", flags)
        self.assertIn("0001-P4", flags)
        self.assertNotIn("0002-P2", flags)
        self.assertIn(" ! ", read(f"{self.run_dir}/range-diff.txt"))
        p2 = read(f"{self.run_dir}/patches/fex-port/0002-P2-port-b10.patch")
        self.assertIn("Rebased: resolved\n", p2)
        self.assertIn("up 10, port 10", p2)
        self.assertIn("Rebased: resolved\n", read(f"{self.run_dir}/patches/fex-port/0001-P1-port-a.patch"))
        self.assertIn("Rebased: clean\n", read(f"{self.run_dir}/patches/fex-port/0003-P3-port-b12.patch"))
        self.assertNotIn("0004-P5", read(f"{self.run_dir}/patches/fex-port/series"))
        self.assertIn("0004-P5", read(f"{self.run_dir}/series.diff"))
        # The re-export: into patches/ with the pin, then matched by patch-id and applied again.
        self.pp("fex", "--write", "--pins")
        self.assertFalse(os.path.exists(f"{self.repo}/patches/fex-port/0004-P5-port-e3.patch"))
        self.assertIn(f"fex {self.n1} ", read(f"{self.repo}/pins.lock"))
        self.assertIn(" next\n", read(f"{self.repo}/pins.lock"))
        self.assertIn(f"rpmalloc {self.rpm} ", read(f"{self.repo}/pins.lock"))
        self.check_series(self.tree, self.n1)
        fresh = f"{self.tmp}/fresh"
        git(self.tmp, "clone", "-q", "--shared", f"{self.build}/cache/fex.git", fresh)
        git(fresh, "checkout", "-q", "-f", self.n1)
        for s in ("fex-port", "fex"):
            names = [l for l in read(f"{self.repo}/patches/{s}/series").splitlines() if not l.startswith("#")]
            git(fresh, "am", "-3", "-q", *[f"{self.repo}/patches/{s}/{n}" for n in names])
        self.check_series(fresh, self.n1)

        # A second run settles P2 with the recorded resolution and does not stop.
        self.repo_restore()
        self.pp("fex", "next", "--trial")
        self.assertEqual(self.trial_classes(self.n1)["0002-P2"], "rerere")
        self.pp("fex", "--abort")
        self.assertTrue(os.path.exists(f"{self.run_dir}/trial-{self.n1[:12]}.tsv"))
        self.pp("fex", "next")
        p2 = read(f"{self.run_dir}/patches/fex-port/0002-P2-port-b10.patch")
        self.assertIn("up 10, port 10", p2)
        self.assertIn("Rebased: resolved\n", p2)

    def repo_restore(self):
        """patches/ and pins.lock as before --write."""
        for s, files in self.originals.items():
            for n, text in files.items():
                with open(f"{self.repo}/patches/{s}/{n}", "w") as f:
                    f.write(text)
        with open(f"{self.repo}/pins.lock") as f:
            text = f.read()
        with open(f"{self.repo}/pins.lock", "w") as f:
            f.write(text.replace(self.n1, self.b0).replace(" next\n", " main\n"))

    def test_a_later_patch_on_a_file_an_earlier_one_touched_conflicts_not_upstream(self):
        # pp sync once called such a patch already-upstream (its 3-way merge found no preimage).
        # Here the old tree is built in the run's own clone and its commits are cherry-picked, so
        # P3 (b.c line 12, over P2's line 10) merges against its real parent and conflicts.
        fex = f"{self.tmp}/FEX"
        git(fex, "checkout", "-q", "-b", "up12", self.b0)
        n2 = commit(fex, "upstream b12", links=[("External/rpmalloc", self.rpm)], **{"b.c": lines(20, l12="up 12")})
        out = self.pp("fex", "up12", "--trial")
        c = self.trial_classes(n2)
        self.assertEqual(c["0002-P2"], "3-way", out)
        self.assertEqual(c["0003-P3"], "conflict", out)
        self.assertEqual(c["0004-P5"], "clean", out)

    def test_a_stopped_run_must_be_continued_or_aborted(self):
        self.pp("fex", "next", code=10)
        self.pp("fex", self.n0, code=1)
        self.pp("fex", "--write", code=1)
        self.pp("fex", "--abort")
        self.pp("fex", self.n0)


if __name__ == "__main__":
    unittest.main()
