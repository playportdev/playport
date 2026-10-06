# SPDX-License-Identifier: GPL-3.0-or-later
"""pp sync (tools/sync.py) against a small synthetic Madeira, its components and a
Playport copy, all local repositories: every replay class, the resolve flags,
the no-op, upstream-broken and the recorded-result reuse, the local main
fast-forward and the candidate build's own run and out directories. No
network, no toolchain, no device.

  python3 -m unittest discover -s tools/tests
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOL = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "sync.py"))
PIPELINE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "build", "pipeline"))
ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@localhost", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@localhost", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
       "GIT_ALLOW_PROTOCOL": "file"}


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, text=True, capture_output=True,
                          env=dict(os.environ, **ENV)).stdout.strip()


def write(repo, path, text):
    p = os.path.join(repo, path)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)


def commit(repo, msg, links=(), **files):
    """Commit files, then the gitlinks (path, sha): `add -A` would drop a gitlink with no checkout."""
    for path, text in files.items():
        write(repo, path, text)
    git(repo, "add", "-A")
    for path, sha in links:
        link(repo, path, sha)
    git(repo, "commit", "-q", "--allow-empty", "-m", msg)
    return git(repo, "rev-parse", "HEAD")


def lines(n, **changed):
    return "".join(changed.get(f"l{i}", f"line {i}") + "\n" for i in range(1, n + 1))


def new_repo(path):
    os.makedirs(path)
    git(path, "init", "-q", "-b", "main")
    for k, v in (("uploadpack.allowFilter", "true"), ("uploadpack.allowAnySHA1InWant", "true")):
        git(path, "config", k, v)
    return path


def link(repo, path, sha):
    git(repo, "update-index", "--add", "--cacheinfo", f"160000,{sha},{path}")


class UpstreamSync(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="upstream-sync-test-")
        t = cls.tmp
        # rpmalloc and fex are pinned on their own (FEX-Emu's); Madeira's FEX is
        # fex-port and its External/rpmalloc is rpmalloc-port, separate forks.
        rpm = new_repo(f"{t}/rpmalloc")
        cls.rpm = commit(rpm, "rpmalloc", **{"r.c": lines(5)})
        commit(rpm, "madeira rpmalloc", **{"r.c": lines(5, l2="line 2 ported")})
        cls.rpm_port_patches = f"{t}/rpmalloc-port-patches"
        git(rpm, "format-patch", "-q", "--zero-commit", "-o", cls.rpm_port_patches, "HEAD~1..HEAD")
        git(rpm, "reset", "-q", "--hard", cls.rpm)
        rport = new_repo(f"{t}/rpmalloc-port")
        cls.rport = commit(rport, "madeira rpmalloc fork", **{"rp.c": "rp\n"})
        fex = new_repo(f"{t}/FEX")
        write(fex, ".gitmodules", '[submodule "rpmalloc"]\n\tpath = External/rpmalloc\n\turl = x\n')
        cls.fex = commit(fex, "fex", links=[("External/rpmalloc", cls.rpm)], **{"f.c": lines(10)})
        # patches/fex-port adds a line that patches/fex then edits: fex only applies on top of it.
        commit(fex, "port", links=[("External/rpmalloc", cls.rpm)], **{"f.c": lines(10) + "ported\n"})
        commit(fex, "playport", links=[("External/rpmalloc", cls.rpm)], **{"f.c": lines(10) + "ported, patched\n"})
        cls.fex_port_patches, cls.fex_patches = f"{t}/fex-port-patches", f"{t}/fex-patches"
        git(fex, "format-patch", "-q", "--zero-commit", "-o", cls.fex_port_patches, "HEAD~2..HEAD~1")
        git(fex, "format-patch", "-q", "--zero-commit", "-o", cls.fex_patches, "HEAD~1..HEAD")
        git(fex, "reset", "-q", "--hard", cls.fex)
        fport = new_repo(f"{t}/FEX-port")
        write(fport, ".gitmodules", '[submodule "rpmalloc"]\n\tpath = External/rpmalloc\n\turl = x\n')
        cls.fport = commit(fport, "madeira fex", links=[("External/rpmalloc", cls.rport)], **{"fp.c": "fp\n"})
        cls.fport2 = commit(fport, "madeira fex moves", links=[("External/rpmalloc", cls.rport)], **{"fp.c": "fp2\n"})
        git(fport, "reset", "-q", "--hard", cls.fport)
        git(fport, "update-ref", "refs/keep/fport2", cls.fport2)
        # dxmt is pinned on its own; Madeira's dxmt submodule (research/dxmt before
        # its reorganisation) is dxmt-port, a separate fork.
        dxmt = new_repo(f"{t}/dxmt")
        cls.dxmt = commit(dxmt, "dxmt", **{"d.c": lines(10)})
        # patches/dxmt-port adds a line that patches/dxmt then edits: dxmt only applies on top of it.
        commit(dxmt, "port", **{"d.c": lines(10) + "ported\n"})
        commit(dxmt, "playport", **{"d.c": lines(10) + "ported, patched\n"})
        cls.dxmt_port_patches, cls.dxmt_patches = f"{t}/dxmt-port-patches", f"{t}/dxmt-patches"
        git(dxmt, "format-patch", "-q", "--zero-commit", "-o", cls.dxmt_port_patches, "HEAD~2..HEAD~1")
        git(dxmt, "format-patch", "-q", "--zero-commit", "-o", cls.dxmt_patches, "HEAD~1..HEAD")
        git(dxmt, "reset", "-q", "--hard", cls.dxmt)
        port = new_repo(f"{t}/dxmt-port")
        cls.port = commit(port, "madeira dxmt", **{"p.c": "p\n"})
        cls.port2 = commit(port, "madeira dxmt moves", **{"p.c": "p2\n"})
        git(port, "reset", "-q", "--hard", cls.port)
        git(port, "update-ref", "refs/keep/port2", cls.port2)

        # wine is pinned on its own (WineHQ's); Madeira's wine is wine-port, a separate fork.
        wine = new_repo(f"{t}/wine")
        cls.wine = commit(wine, "wine", **{"w.c": lines(10)})
        # patches/wine-port adds a line that patches/wine-valve and then patches/wine-unix
        # edit: each only applies on top of the series before it.
        commit(wine, "port", **{"w.c": lines(10) + "ported\n"})
        commit(wine, "valve", **{"w.c": lines(10) + "ported, picked\n"})
        commit(wine, "playport", **{"w.c": lines(10) + "ported, picked, patched\n"})
        cls.wine_port_patches, cls.wine_patches = f"{t}/wine-port-patches", f"{t}/wine-patches"
        cls.wine_valve_patches = f"{t}/wine-valve-patches"
        git(wine, "format-patch", "-q", "--zero-commit", "-o", cls.wine_port_patches, "HEAD~3..HEAD~2")
        git(wine, "format-patch", "-q", "--zero-commit", "-o", cls.wine_valve_patches, "HEAD~2..HEAD~1")
        git(wine, "format-patch", "-q", "--zero-commit", "-o", cls.wine_patches, "HEAD~1..HEAD")
        git(wine, "reset", "-q", "--hard", cls.wine)
        wport = new_repo(f"{t}/wine-port")
        cls.wport = commit(wport, "madeira wine", **{"wp.c": "wp\n"})
        cls.wport2 = commit(wport, "madeira wine moves", **{"wp.c": "wp2\n"})
        git(wport, "reset", "-q", "--hard", cls.wport)
        git(wport, "update-ref", "refs/keep/wport2", cls.wport2)

        # Madeira itself is the component that moves: its own code carries the
        # replay-class series (patches/madeira-unix: clean, already-upstream,
        # merged-3way, conflict).
        mad = new_repo(f"{t}/Madeira")
        gm = ('[submodule "wine"]\n\tpath = wine\n\turl = x\n\tbranch = {b}\n'
              '[submodule "FEX"]\n\tpath = FEX\n\turl = x\n\tbranch = main\n'
              '[submodule "research/dxmt"]\n\tpath = research/dxmt\n\turl = x\n\tbranch = main\n')
        write(mad, ".gitmodules", gm.format(b="main"))
        links = [("wine", cls.wport), ("FEX", cls.fport), ("research/dxmt", cls.port)]
        base = {"src.c": lines(30), "other.c": lines(10), "COPYING.LIB": "lgpl\n", "unix.c": lines(10)}
        cls.m0 = commit(mad, "madeira", links=links, **base)
        commit(mad, "p1 other", links=links, **{"other.c": lines(10, l5="other five patched")})
        commit(mad, "p2 fix line 3", links=links, **{"src.c": lines(30, l3="line 3 fixed")})
        commit(mad, "p3 patch line 15", links=links, **{"src.c": lines(30, l3="line 3 fixed", l15="line 15 patched")})
        commit(mad, "p4 patch line 25", links=links, **{"src.c": lines(30, l3="line 3 fixed", l15="line 15 patched",
                                                                         l25="line 25 ours")})
        cls.mad_patches = f"{t}/mad-patches"
        git(mad, "format-patch", "-q", "--zero-commit", "-o", cls.mad_patches, f"{cls.m0}..HEAD")
        git(mad, "reset", "-q", "--hard", cls.m0)
        # m1: a force-push (not a descendant of m0) that fixes line 3, edits lines
        # 13 and 25 and the licence text, and switches the wine branch.
        git(mad, "checkout", "-q", "--orphan", "rewrite")
        commit(mad, "madeira rewritten", links=links, **base)
        cls.u1 = commit(mad, "upstream fixes line 3", links=links, **{"src.c": lines(30, l3="line 3 fixed")})
        commit(mad, "upstream edits line 13", links=links,
               **{"src.c": lines(30, l3="line 3 fixed", l13="line 13 upstream")})
        write(mad, ".gitmodules", gm.format(b="main-lgpl"))
        cls.m1 = commit(mad, "upstream edits line 25 and the licence text", links=links,
                        **{"src.c": lines(30, l3="line 3 fixed", l13="line 13 upstream", l25="line 25 theirs"),
                           "COPYING.LIB": "lgpl, amended\n"})
        # m2: a plain descendant of m0 that changes only code no patch touches.
        git(mad, "checkout", "-q", "-f", "main")
        cls.m2 = commit(mad, "madeira moves", links=links, **{"unix.c": lines(10, l9="line 9 upstream")})
        git(mad, "reset", "-q", "--hard", cls.m0)
        # m3: a descendant of m0 where 0002 is upstream and 0003 needs a 3-way merge.
        cls.u3 = commit(mad, "upstream fixes line 3", links=links, **{"src.c": lines(30, l3="line 3 fixed")})
        cls.m3 = commit(mad, "upstream edits line 13 only", links=links,
                        **{"src.c": lines(30, l3="line 3 fixed", l13="line 13 upstream")})
        git(mad, "reset", "-q", "--hard", cls.m0)
        # m4: a descendant of m0 moving only research/dxmt.
        cls.m4 = commit(mad, "madeira moves its DXMT", links=[("wine", cls.wport), ("FEX", cls.fport),
                                                              ("research/dxmt", cls.port2)])
        git(mad, "reset", "-q", "--hard", cls.m0)
        # m5: a descendant of m0 moving only FEX.
        cls.m5 = commit(mad, "madeira moves its FEX", links=[("wine", cls.wport), ("FEX", cls.fport2),
                                                             ("research/dxmt", cls.port)])
        git(mad, "reset", "-q", "--hard", cls.m0)
        # m6: a descendant of m0 moving only its Wine.
        cls.m6 = commit(mad, "madeira moves its Wine", links=[("wine", cls.wport2), ("FEX", cls.fport),
                                                              ("research/dxmt", cls.port)])
        git(mad, "reset", "-q", "--hard", cls.m0)
        # m7: Madeira's reorganisation (its 79e28f0) on m0: the dxmt submodule moves from
        # research/dxmt to dxmt at the same commit, and a madeira-dock submodule appears.
        # m8 on m7 then moves the dxmt gitlink at its new path.
        write(mad, ".gitmodules", gm.format(b="main").replace("research/dxmt", "dxmt")
              + '[submodule "madeira-dock"]\n\tpath = madeira-dock\n\turl = x\n\tbranch = main\n')
        dock = ("madeira-dock", cls.port)
        cls.m7 = commit(mad, "Reorganize the repository", links=[("wine", cls.wport), ("FEX", cls.fport),
                                                                 ("dxmt", cls.port), dock])
        cls.m8 = commit(mad, "madeira moves its DXMT at the new path",
                        links=[("wine", cls.wport), ("FEX", cls.fport), ("dxmt", cls.port2), dock])
        git(mad, "reset", "-q", "--hard", cls.m0)
        # A stacked series (patches/madeira-unix replaced in its tests): 0001 edits unix.c, 0002
        # edits unix.c again, so 0002's preimage blob exists only where 0001 was applied to the
        # pin; 0003 edits other.c with an index line naming no blob anywhere (a hand-edited
        # patch). They are made in a clone, so Madeira's mirror never holds those blobs.
        stack = f"{t}/mad-stack"
        subprocess.run(["git", "clone", "-q", "--no-local", mad, stack], check=True, env=dict(os.environ, **ENV))
        git(stack, "checkout", "-q", "--detach", cls.m0)
        commit(stack, "s1 unix line 2", links=links, **{"unix.c": lines(10, l2="line 2 ours")})
        commit(stack, "s2 unix line 8", links=links, **{"unix.c": lines(10, l2="line 2 ours", l8="line 8 ours")})
        commit(stack, "s3 other line 7", links=links, **{"other.c": lines(10, l7="line 7 ours")})
        cls.stack_patches = f"{t}/stack-patches"
        git(stack, "format-patch", "-q", "--zero-commit", "-o", cls.stack_patches, f"{cls.m0}..HEAD")
        p3 = os.path.join(cls.stack_patches, sorted(os.listdir(cls.stack_patches))[2])
        with open(p3) as f:
            text = f.read()
        pre = git(stack, "rev-parse", f"{cls.m0}:other.c")[:7]
        assert f"index {pre}.." in text, text
        with open(p3, "w") as f:
            f.write(text.replace(f"index {pre}..", "index 1234567.."))
        shutil.rmtree(stack)
        # m9: a descendant of m0 that edits unix.c line 8 and other.c line 7, where 0002 and 0003
        # of the stacked series conflict and 0001 stays clean.
        cls.m9 = commit(mad, "upstream edits unix line 8 and other line 7", links=links,
                        **{"unix.c": lines(10, l8="line 8 theirs"), "other.c": lines(10, l7="line 7 theirs")})
        git(mad, "reset", "-q", "--hard", cls.m0)
        # Valve's branch (the wine-valve row's): v0 the pin, v1 a new commit on it;
        # vr the branch rebased onto a later base, keeping v0's subject and adds another.
        valve = new_repo(f"{t}/valve")
        vbase = commit(valve, "wine-11.0", **{"w.c": "w\n"})
        git(valve, "checkout", "-q", "-b", "proton_11.0")
        cls.v0 = commit(valve, "valve: picked fix", **{"v.c": "v0\n"})
        cls.v1 = commit(valve, "valve: new game fix", **{"g.c": "g\n"})
        git(valve, "checkout", "-q", "-b", "rewrite", vbase)
        commit(valve, "wine-11.0.1", **{"w.c": "w1\n"})
        commit(valve, "valve: picked fix", **{"v.c": "v0\n"})
        cls.vr = commit(valve, "valve: another fix", **{"h.c": "h\n"})
        git(valve, "checkout", "-q", "-f", "proton_11.0")
        # Keep the moves reachable for fetches by SHA.
        for n in ("m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8", "m9"):
            git(mad, "update-ref", f"refs/keep/{n}", getattr(cls, n))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def playport(self, name, valve=None):
        """A Playport copy pinned at m0, with its own build area (and a wine-valve row at valve)."""
        t = self.tmp
        pp = new_repo(f"{t}/{name}")
        os.makedirs(f"{pp}/tools")
        shutil.copy(TOOL, f"{pp}/tools/sync.py")
        for m in ("phonelib.py", "checks.py"):   # the modules sync.py imports
            shutil.copy(os.path.join(os.path.dirname(TOOL), m), f"{pp}/tools/{m}")
        os.makedirs(f"{pp}/build")
        shutil.copy(os.path.join(os.path.dirname(TOOL), "..", "build", "inputs.py"), f"{pp}/build/inputs.py")
        write(pp, ".gitignore", "__pycache__/\n")   # as the real one: sync.py imports its modules
        write(pp, "pp", "#!/bin/sh\n[ \"$1\" = names ] && echo 'pp names: clean'\n")
        write(pp, "build/pipeline", "#!/bin/sh\nmkdir -p \"$PLAYPORT_RUN/logs\" \"$PLAYPORT_OUT/x\"\n"
              "echo partial > \"$PLAYPORT_OUT/x/Playport-26.5-0.ipa\"\n"
              "echo 'x.c:1:1: error: upstream broke this' > \"$PLAYPORT_RUN/logs/unix.log\"\n"
              "echo \"FAILED: bash unix (log: $PLAYPORT_RUN/logs/unix.log)\"\nexit 1\n")
        os.chmod(f"{pp}/build/pipeline", 0o755)
        os.chmod(f"{pp}/pp", 0o755)
        write(pp, "pins.lock", "# name commit repository branch\n"
              f"madeira      {self.m0}  {t}/Madeira  main\n"
              f"wine         {self.wine}  {t}/wine  main\n"
              f"wine-port    {self.wport}  {t}/wine-port  main\n"
              f"fex          {self.fex}  {t}/FEX  main\n"
              f"fex-port     {self.fport}  {t}/FEX-port  main\n"
              f"dxmt         {self.dxmt}  {t}/dxmt  main\n"
              f"dxmt-port    {self.port}  {t}/dxmt-port  main\n"
              f"rpmalloc     {self.rpm}  {t}/rpmalloc  main\n"
              f"rpmalloc-port {self.rport}  {t}/rpmalloc-port  main\n"
              + (f"wine-valve   {valve}  {t}/valve  proton_11.0\n" if valve else ""))
        write(pp, ".gitmodules", f'[submodule "upstream/madeira"]\n\tpath = upstream/madeira\n\turl = {t}/Madeira\n')
        for target, src in (("wine-port", self.wine_port_patches), ("wine-valve", self.wine_valve_patches),
                            ("wine-unix", self.wine_patches),
                            ("madeira-unix", self.mad_patches),
                            ("fex-port", self.fex_port_patches), ("fex", self.fex_patches),
                            ("rpmalloc-port", self.rpm_port_patches),
                            ("dxmt-port", self.dxmt_port_patches), ("dxmt", self.dxmt_patches)):
            names = sorted(os.listdir(src))
            os.makedirs(f"{pp}/patches/{target}")
            for n in names:
                shutil.copy(f"{src}/{n}", f"{pp}/patches/{target}/{n}")
            write(pp, f"patches/{target}/series", f"# {target}\n" + "".join(n + "\n" for n in names))
        write(pp, "patches/mesa/series", "# mesa: a pin no Madeira commit moves, never replayed\n")
        os.makedirs(f"{pp}/upstream/madeira")  # an uninitialised submodule
        commit(pp, "playport", links=[("upstream/madeira", self.m0)])
        build = f"{t}/{name}-build"
        return pp, build

    def run_tool(self, pp, build, *args, watch=False, **extra):
        """sync.py with args; a pin move (the default here) carries --move-pin-0054, a watch none."""
        args = args if watch else (*args, "--move-pin-0054")
        # A pymobiledevice3 that finds no phone: no test may reach a real device.
        stub = f"{self.tmp}/bin"
        if not os.path.exists(f"{stub}/pymobiledevice3"):
            write(stub, "pymobiledevice3", "#!/bin/sh\necho 'no device' >&2\nexit 1\n")
            os.chmod(f"{stub}/pymobiledevice3", 0o755)
        env = dict(os.environ, **ENV, PLAYPORT_BUILD=build, PLAYPORT_DEVICE_DIR=build, PLAYPORT_DEVICE_LOCK=f"{build}/device.lock",
                   PLAYPORT_USBMUX_SOCKET=f"{self.tmp}/no-such.sock", PATH=f"{stub}:{os.environ['PATH']}", **extra)
        r = subprocess.run([sys.executable, f"{pp}/tools/sync.py", *args], text=True, capture_output=True, env=env)
        return r.returncode, r.stdout + r.stderr

    def result(self, build, sha, dry):
        d = os.path.join(build, "sync", sha[:8] + ("-dry-run" if dry else ""))
        with open(os.path.join(d, "result.json")) as f:
            return json.load(f)

    def test_watch_lists_what_playport_builds_and_moves_nothing(self):
        pp, build = self.playport("pp-watch")
        head = git(pp, "rev-parse", "HEAD")
        # m3 edits src.c, which patches/madeira-unix patches: both commits are listed, marked.
        st, out = self.run_tool(pp, build, self.m3, "--replay", watch=True)
        self.assertEqual(st, 0, out)
        self.assertIn("no pin moved", out)
        d = f"{build}/sync/watch-{self.m3[:8]}"
        with open(f"{d}/watch.tsv") as f:
            rows = [l.rstrip("\n").split("\t") for l in f if not l.startswith("#")]
        self.assertEqual([(r[0], r[1], r[3], r[4]) for r in rows],
                         [("madeira", self.u3, "upstream fixes line 3", "src.c"),
                          ("madeira", self.m3, "upstream edits line 13 only", "src.c")])
        with open(f"{d}/WATCH.md") as f:
            report = f.read()
        self.assertIn("Would it apply", report)
        self.assertIn("| madeira-unix | 2 | 1 | 1 | 0 |", report)
        # m2 touches only unix.c, which Playport neither builds nor patches; m5 moves Madeira's FEX:
        # its fork's commit is listed, the gitlink-only Madeira commit is not.
        st, out = self.run_tool(pp, build, self.m2, watch=True)
        self.assertEqual(st, 0, out)
        self.assertIn("0 commit(s), 1 more touching nothing Playport builds", out)
        st, out = self.run_tool(pp, build, self.m5, watch=True)
        self.assertEqual(st, 0, out)
        with open(f"{build}/sync/watch-{self.m5[:8]}/watch.tsv") as f:
            rows = [l.rstrip("\n").split("\t") for l in f if not l.startswith("#")]
        self.assertEqual([(r[0], r[1], r[3], r[5]) for r in rows],
                         [("fex-port", self.fport2, "madeira fex moves", "fp.c")])
        self.assertIn("fex-port-moved", out)
        # No commit: the pinned branch's head (m0, the pin itself) has nothing new.
        st, out = self.run_tool(pp, build, watch=True)
        self.assertEqual(st, 0, out)
        self.assertIn(f"watch {self.m0[:12]}: 0 commit(s)", out)
        # Nothing moved: no commit, branch, changed file or watched pin mirror.
        self.assertEqual(git(pp, "rev-parse", "HEAD"), head)
        self.assertEqual(git(pp, "status", "--porcelain"), "")
        self.assertNotIn("sync/", git(pp, "branch", "--list"))
        self.assertFalse(os.path.exists(f"{build}/sync/madeira-pin.git"))

    def test_a_pin_move_needs_the_0054_override(self):
        pp, build = self.playport("pp-frozen")
        for args in ((self.m2, "--dry-run"), (self.m2, "--push"), (self.m2, "--move-pin-0054", "--replay"),
                     ("--move-pin-0054",)):
            st, out = self.run_tool(pp, build, *args, watch=True)
            self.assertEqual(st, 2, out)
        self.assertIn("decision 0054", self.run_tool(pp, build, self.m2, "--dry-run", watch=True)[1])
        self.assertFalse(os.path.exists(f"{build}/sync/{self.m2[:8]}-dry-run"))

    def test_current_pin_is_a_no_op(self):
        pp, build = self.playport("pp-noop")
        st, out = self.run_tool(pp, build, self.m0, "--dry-run")
        self.assertEqual(st, 0, out)
        r = self.result(build, self.m0, True)
        self.assertEqual(r["result"]["outcome"], "no-op")
        self.assertEqual({p["class"] for t in r["replay"] for p in t["patches"]}, {"clean"})
        # The watched pin mirror records the pin.
        self.assertEqual(git(f"{build}/sync/madeira-pin.git", "rev-parse", "main"), self.m0)
        st, out = self.run_tool(pp, build, self.m0)
        self.assertEqual(st, 0, out)
        self.assertIn("no-op", out)

    def test_wine_dxmt_and_fex_keep_their_pins_and_replay_on_the_ports(self):
        pp, build = self.playport("pp-dxmt")
        st, out = self.run_tool(pp, build, self.m2, "--dry-run")
        self.assertEqual(st, 0, out)
        r = self.result(build, self.m2, True)
        self.assertEqual(r["result"]["outcome"], "replay-clean")
        self.assertEqual(r["resolve"]["new"]["wine"], self.wine)
        self.assertEqual(r["resolve"]["new"]["wine-port"], self.wport)
        self.assertEqual(r["resolve"]["new"]["dxmt"], self.dxmt)
        self.assertEqual(r["resolve"]["new"]["dxmt-port"], self.port)
        self.assertEqual(r["resolve"]["new"]["fex"], self.fex)
        self.assertEqual(r["resolve"]["new"]["fex-port"], self.fport)
        self.assertEqual(r["resolve"]["new"]["rpmalloc"], self.rpm)
        self.assertEqual(r["resolve"]["new"]["rpmalloc-port"], self.rport)
        got = {t["target"]: [p["class"] for p in t["patches"]] for t in r["replay"]}
        for target in ("wine-port", "wine-valve", "wine-unix", "dxmt-port", "dxmt", "fex-port", "fex",
                       "rpmalloc-port"):
            self.assertEqual(got[target], ["clean"], target)

    def test_a_moved_madeira_fex_holds_before_the_build(self):
        pp, build = self.playport("pp-fex-moved")
        st, out = self.run_tool(pp, build, self.m5)
        self.assertEqual(st, 10, out)
        r = self.result(build, self.m5, False)
        self.assertEqual(r["result"]["outcome"], "hold")
        kinds = {f["kind"]: f for f in r["resolve"]["flags"]}
        self.assertTrue(kinds["fex-port-moved"]["hold"])
        self.assertIn(self.fport2[:12], kinds["fex-port-moved"]["detail"])
        self.assertNotIn("rpmalloc-port-moved", kinds)
        self.assertNotIn("build", r["result"])
        self.assertNotIn("sync/", git(pp, "branch", "--list"))

    def test_a_moved_madeira_wine_holds_before_the_build(self):
        pp, build = self.playport("pp-wine-moved")
        st, out = self.run_tool(pp, build, self.m6)
        self.assertEqual(st, 10, out)
        r = self.result(build, self.m6, False)
        self.assertEqual(r["result"]["outcome"], "hold")
        kinds = {f["kind"]: f for f in r["resolve"]["flags"]}
        self.assertTrue(kinds["wine-port-moved"]["hold"])
        self.assertIn(self.wport2[:12], kinds["wine-port-moved"]["detail"])
        self.assertNotIn("build", r["result"])
        self.assertNotIn("sync/", git(pp, "branch", "--list"))

    def test_new_valve_commits_are_written_to_a_file_and_never_hold(self):
        pp, build = self.playport("pp-valve", valve=self.v0)
        stable = f"{build}/sync/wine-valve-new.tsv"
        st, out = self.run_tool(pp, build, self.m0)
        self.assertEqual(st, 0, out)   # the no-op stays a no-op
        self.assertIn(f"new Valve commit(s) past the wine-valve pin: {stable}", out)
        with open(stable) as f:
            rows = [l.split("\t") for l in f if not l.startswith("#")]
        self.assertEqual([(r[0], r[2], r[3].strip()) for r in rows], [(self.v1[:11], "valve: new game fix", "g.c")])
        r = self.result(build, self.m0, False)
        self.assertEqual(r["result"]["valve"]["new"], 1)
        self.assertTrue(os.path.exists(f"{build}/sync/{self.m0[:8]}/wine-valve-new.tsv"))
        # A recorded result still reports it.
        st, out = self.run_tool(pp, build, self.m0)
        self.assertEqual(st, 0, out)
        self.assertIn("1 new Valve commit(s)", out)
        # A rewritten branch: only the subjects the pin lacks are new (the new base's too).
        git(f"{self.tmp}/valve", "update-ref", "refs/heads/proton_11.0", self.vr)
        try:
            st, out = self.run_tool(pp, build, self.m0, "--rerun")
        finally:
            git(f"{self.tmp}/valve", "update-ref", "refs/heads/proton_11.0", self.v1)
        self.assertEqual(st, 0, out)
        self.assertIn("branch rewritten", out)
        with open(stable) as f:
            rows = [l.split("\t")[2] for l in f if not l.startswith("#")]
        self.assertEqual(rows, ["wine-11.0.1", "valve: another fix"])
        # Nothing new: the sync-level file goes away.
        pp2, build2 = self.playport("pp-valve-head", valve=self.v1)
        os.makedirs(f"{build2}/sync", exist_ok=True)
        write(build2, "sync/wine-valve-new.tsv", "stale\n")
        st, out = self.run_tool(pp2, build2, self.m0)
        self.assertEqual(st, 0, out)
        self.assertIn("has nothing past the pin", out)
        self.assertFalse(os.path.exists(f"{build2}/sync/wine-valve-new.tsv"))

    def test_a_moved_madeira_dxmt_holds_before_the_build(self):
        pp, build = self.playport("pp-dxmt-moved")
        st, out = self.run_tool(pp, build, self.m4)
        self.assertEqual(st, 10, out)
        r = self.result(build, self.m4, False)
        self.assertEqual(r["result"]["outcome"], "hold")
        kinds = {f["kind"]: f for f in r["resolve"]["flags"]}
        self.assertTrue(kinds["dxmt-port-moved"]["hold"])
        self.assertIn(self.port2[:12], kinds["dxmt-port-moved"]["detail"])
        self.assertNotIn("build", r["result"])
        self.assertNotIn("sync/", git(pp, "branch", "--list"))

    def test_reorganised_madeira_reads_dxmt_at_its_new_path(self):
        # The pin m0 has research/dxmt; m7 has dxmt (same commit) and madeira-dock.
        pp, build = self.playport("pp-reorg")
        st, out = self.run_tool(pp, build, self.m7, "--dry-run")
        self.assertEqual(st, 10, out)   # a .gitmodules change holds for review
        r = self.result(build, self.m7, True)
        self.assertEqual(r["resolve"]["new"]["dxmt-port"], self.port)
        kinds = {}
        for f in r["resolve"]["flags"]:
            kinds.setdefault(f["kind"], []).append(f["detail"])
        self.assertNotIn("dxmt-port-moved", kinds)
        for detail in ("research/dxmt path: research/dxmt -> None", "dxmt path: None -> dxmt",
                       "madeira-dock path: None -> madeira-dock"):
            self.assertIn("madeira .gitmodules " + detail, kinds["gitmodules"])
        self.assertTrue(any(i.startswith("Madeira submodule madeira-dock is no pins.lock row")
                            for i in r["resolve"]["info"]), r["resolve"]["info"])
        got = {t["target"]: [p["class"] for p in t["patches"]] for t in r["replay"]}
        self.assertEqual(got["dxmt"], ["clean"])
        # A dxmt move at the new path is a dxmt-port move, as before the reorganisation.
        st, out = self.run_tool(pp, build, self.m8)
        self.assertEqual(st, 10, out)
        r = self.result(build, self.m8, False)
        kinds = {f["kind"]: f for f in r["resolve"]["flags"]}
        self.assertTrue(kinds["dxmt-port-moved"]["hold"])
        self.assertIn(self.port2[:12], kinds["dxmt-port-moved"]["detail"])
        self.assertNotIn("build", r["result"])

    def test_every_class_and_flag(self):
        pp, build = self.playport("pp-classes")
        st, out = self.run_tool(pp, build, self.m1, "--dry-run")
        self.assertEqual(st, 10, out)
        r = self.result(build, self.m1, True)
        got = {p["patch"][:4]: p for t in r["replay"] if t["target"] == "madeira-unix" for p in t["patches"]}
        self.assertEqual({k: v["class"] for k, v in got.items()},
                         {"0001": "clean", "0002": "already-upstream", "0003": "merged-3way", "0004": "conflict"})
        self.assertTrue(got["0002"]["superseded_by"].startswith(self.u1[:12]), got["0002"])
        hunk = got["0004"]["files"][0]["hunks"][0]
        self.assertEqual(got["0004"]["files"][0]["file"], "src.c")
        self.assertTrue(any("upstream edits line 25" in c for c in hunk["upstream"]), hunk)
        kinds = {f["kind"]: f for f in r["resolve"]["flags"]}
        self.assertIn("non-fast-forward", kinds)
        self.assertFalse(kinds["non-fast-forward"]["hold"])
        self.assertTrue(kinds["gitmodules"]["hold"])
        self.assertIn("main-lgpl", kinds["gitmodules"]["detail"])
        self.assertTrue(kinds["licence"]["hold"])
        self.assertIn("COPYING.LIB", kinds["licence"]["detail"])
        with open(os.path.join(build, "sync", self.m1[:8] + "-dry-run", "REPORT.md")) as f:
            report = f.read()
        self.assertIn("### Conflict: patches/madeira-unix/0004", report)
        # A dry run leaves the repository alone.
        self.assertEqual(git(pp, "status", "--porcelain"), "")
        self.assertNotIn("sync/", git(pp, "branch", "--list"))

    def test_a_later_patch_on_a_file_an_earlier_one_touched_conflicts_not_upstream(self):
        # The 3-way merge of 0002 needs the blob 0001 makes on the pin; a merge with no
        # preimage at all (0003's hand-edited index line) is a conflict too, never already-upstream.
        pp, build = self.playport("pp-stacked")
        sdir = f"{pp}/patches/madeira-unix"
        shutil.rmtree(sdir)
        os.makedirs(sdir)
        names = sorted(os.listdir(self.stack_patches))
        for n in names:
            shutil.copy(f"{self.stack_patches}/{n}", f"{sdir}/{n}")
        write(pp, "patches/madeira-unix/series", "# madeira-unix\n" + "".join(n + "\n" for n in names))
        commit(pp, "a stacked series", links=[("upstream/madeira", self.m0)])
        st, out = self.run_tool(pp, build, self.m9, "--dry-run")
        self.assertEqual(st, 10, out)
        r = self.result(build, self.m9, True)
        got = {p["patch"][:4]: p for t in r["replay"] if t["target"] == "madeira-unix" for p in t["patches"]}
        self.assertEqual({k: v["class"] for k, v in got.items()},
                         {"0001": "clean", "0002": "conflict", "0003": "conflict"})
        # 0002 merged against its real preimage: a conflict block in unix.c.
        self.assertNotIn("no_preimage", got["0002"])
        self.assertEqual(got["0002"]["files"][0]["file"], "unix.c")
        hunk = got["0002"]["files"][0]["hunks"][0]
        self.assertIn("line 8 theirs", hunk["text"])
        self.assertIn("line 8 ours", hunk["text"])
        # 0003 had no preimage: no markers, named as such, with the file's upstream commits.
        self.assertTrue(got["0003"]["no_preimage"], got["0003"])
        self.assertEqual(got["0003"]["files"][0]["file"], "other.c")
        self.assertTrue(any("other line 7" in c for c in got["0003"]["files"][0]["upstream"]), got["0003"])
        with open(os.path.join(build, "sync", self.m9[:8] + "-dry-run", "REPORT.md")) as f:
            report = f.read()
        self.assertIn("No 3-way merge: `git am -3` found no preimage blob", report)
        self.assertNotIn("already-upstream", report)

    def test_upstream_broken_is_recorded_and_reused(self):
        pp, build = self.playport("pp-broken")
        st, out = self.run_tool(pp, build, self.m2)
        self.assertEqual(st, 11, out)
        r = self.result(build, self.m2, False)["result"]
        self.assertEqual(r["outcome"], "upstream-broken")
        self.assertIn("upstream broke this", r["build"]["first_error"])
        # The candidate build ran in its own run directory, not the shared one.
        rundir = f"{build}/sync/{self.m2[:8]}"
        self.assertFalse(os.path.exists(f"{build}/run"))
        # Its trees are gone once it ends; its logs stay with the report.
        self.assertEqual(r["build"]["stage_log"], f"{rundir}/logs/build/unix.log")
        with open(r["build"]["stage_log"]) as f:
            self.assertIn("upstream broke this", f.read())
        self.assertFalse(os.path.exists(f"{rundir}/build-run"))
        self.assertFalse(os.path.exists(f"{rundir}/build-out"))
        # The candidate checkout is gone too; its branch stays, fetched into the repository.
        self.assertFalse(os.path.exists(f"{rundir}/playport"))
        branch = f"sync/{self.m2[:8]}"
        self.assertEqual(git(pp, "ls-tree", branch, "upstream/madeira").split()[2], self.m2)
        self.assertIn(self.m2, git(pp, "show", f"{branch}:pins.lock"))
        self.assertEqual(git(pp, "rev-parse", "main"), git(pp, "rev-parse", "HEAD"))
        # main and the watched pin did not move.
        self.assertEqual(git(f"{build}/sync/madeira-pin.git", "rev-parse", "main"), self.m0)
        st, out = self.run_tool(pp, build, self.m2)
        self.assertEqual(st, 11, out)
        self.assertIn("(recorded;", out)

    def test_candidate_drops_and_refreshes_patches(self):
        pp, build = self.playport("pp-refresh")
        st, out = self.run_tool(pp, build, self.m3)
        # The stand-in build always fails; with a merged-3way patch that is a hold naming it, not upstream-broken.
        self.assertEqual(st, 10, out)
        r = self.result(build, self.m3, False)
        self.assertEqual(r["result"]["outcome"], "hold")
        self.assertTrue(any("suspects" in x and "madeira-unix/0003-" in x for x in r["result"]["reasons"]), r["result"])
        got = {p["patch"][:4]: p["class"] for t in r["replay"] if t["target"] == "madeira-unix" for p in t["patches"]}
        self.assertEqual(got, {"0001": "clean", "0002": "already-upstream", "0003": "merged-3way", "0004": "clean"})
        branch = f"sync/{self.m3[:8]}"
        series = git(pp, "show", f"{branch}:patches/madeira-unix/series")
        self.assertNotIn("0002-", series)
        self.assertIn("0003-", series)
        msg = git(pp, "log", "-1", "--format=%B", f"{branch}~0")
        self.assertIn(f"superseded by madeira {self.u3[:12]} upstream fixes line 3", msg)
        self.assertIn("Refresh patches/madeira-unix/0003", msg)
        p3 = [n for n in series.splitlines() if n.startswith("0003-")][0]
        refreshed = git(pp, "show", f"{branch}:patches/madeira-unix/{p3}")
        self.assertIn("line 13 upstream", refreshed)  # its context is the new upstream text
        self.assertIn("pins.lock", git(pp, "show", "--stat", "--format=", branch))

    def test_built_candidate_pauses_for_the_device_and_resumes(self):
        pp, build = self.playport("pp-paused")
        write(pp, "build/pipeline", "#!/bin/sh\nset -e\nmkdir -p \"$PLAYPORT_OUT/x\" \"$PLAYPORT_RUN/logs\"\n"
              "echo linked > \"$PLAYPORT_RUN/logs/app.log\"\n"
              "echo ipa > \"$PLAYPORT_OUT/x/Playport-26.5-0.ipa\"\necho rebuilt > app/artifacts.tsv\n"
              "echo \"12:00:00  IPA $PLAYPORT_OUT/x/Playport-26.5-0.ipa\"\n"
              "echo \"12:00:00  sha256 $(printf '0%.0s' $(seq 64))\"\n")
        for d in ("app/HostIOKit", "app/ContentKit", "app/GOGClient", "app/EpicClient", "app/SteamClient", "app/PlayportKit", "build/generated"):
            write(pp, f"{d}/.keep", "")
        write(pp, "app/artifacts.tsv", "old\n")
        commit(pp, "a buildable stand-in", links=[("upstream/madeira", self.m0)])
        swift = f"{self.tmp}/pp-paused-swift"
        write(self.tmp, "pp-paused-swift", "#!/bin/sh\nwhile [ $# -gt 0 ]; do\n"
              "[ \"$1\" = --scratch-path ] && mkdir -p \"$2\"\nshift\ndone\n")
        os.chmod(swift, 0o755)
        st, out = self.run_tool(pp, build, self.m2, SWIFT=swift)
        self.assertEqual(st, 12, out)
        r = self.result(build, self.m2, False)["result"]
        self.assertEqual(r["outcome"], "paused")
        self.assertTrue(all(g["ok"] for g in r["gates"].values()), r["gates"])
        self.assertIn("swift-test PlayportKit", r["gates"])
        branch = f"sync/{self.m2[:8]}"
        self.assertEqual(git(pp, "show", f"{branch}:app/artifacts.tsv"), "rebuilt")
        self.assertIn("build outputs", git(pp, "log", "-1", "--format=%s", branch))
        # The run tree is gone, its logs kept; the IPA stays for the resume.
        rundir = f"{build}/sync/{self.m2[:8]}"
        self.assertFalse(os.path.exists(f"{rundir}/build-run"))
        self.assertTrue(os.path.exists(f"{rundir}/logs/build/app.log"))
        self.assertTrue(os.path.exists(r["build"]["ipa"]))
        self.assertTrue(os.path.isdir(r["candidate"]))
        self.assertFalse(os.path.exists(f"{rundir}/swift"))
        # The rerun resumes at the device gates: no second build.
        os.remove(f"{pp}/build/pipeline")
        st, out = self.run_tool(pp, build, self.m2, SWIFT="true")
        self.assertEqual(st, 12, out)
        self.assertIn("resuming there", out)

    def load_tool(self, pp):
        loader = importlib.machinery.SourceFileLoader("upstream_sync_" + os.path.basename(pp), f"{pp}/tools/sync.py")
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(mod)
        return mod

    def candidate(self, pp, sha8):
        """sync/<sha8>, one commit ahead of main, made in a clone and fetched back as the tool does."""
        cand = f"{self.tmp}/{os.path.basename(pp)}-cand-{sha8}"
        git(pp, "clone", "-q", "--shared", pp, cand)
        git(cand, "checkout", "-q", "-B", f"sync/{sha8}", "main")
        head = commit(cand, "the pin move", **{"moved.txt": sha8 + "\n"})
        git(pp, "fetch", "-q", cand, f"+refs/heads/sync/{sha8}:refs/heads/sync/{sha8}")
        return cand, head

    def test_merge_fast_forwards_a_checked_out_main(self):
        pp, _ = self.playport("pp-ff")
        tool = self.load_tool(pp)
        cand, head = self.candidate(pp, "aaaaaaaa")
        ok, notes = tool.ff_main("aaaaaaaa", False)
        self.assertTrue(ok, notes)
        self.assertEqual(git(pp, "rev-parse", "main"), head)
        self.assertTrue(os.path.exists(f"{pp}/moved.txt"))  # the checkout moved with it
        self.assertEqual(git(pp, "status", "--porcelain", "--untracked-files=no"), "")
        # A checkout of main with uncommitted changes is left alone, and the merge holds.
        cand, head2 = self.candidate(pp, "bbbbbbbb")
        write(pp, "pins.lock", "edited\n")
        ok, notes = tool.ff_main("bbbbbbbb", False)
        self.assertFalse(ok)
        self.assertIn("uncommitted changes", notes[0])
        self.assertEqual(git(pp, "rev-parse", "main"), head)
        git(pp, "checkout", "-q", "--", "pins.lock")
        # With main checked out nowhere, the ref alone moves.
        git(pp, "checkout", "-q", "--detach")
        ok, notes = tool.ff_main("bbbbbbbb", False)
        self.assertTrue(ok, notes)
        self.assertEqual(git(pp, "rev-parse", "main"), head2)
        # A main that is not an ancestor of the candidate is never moved.
        git(pp, "checkout", "-q", "main")
        diverged = commit(pp, "a commit on main")
        ok, notes = tool.ff_main("bbbbbbbb", False)
        self.assertFalse(ok)
        self.assertEqual(git(pp, "rev-parse", "main"), diverged)

    def test_build_run_and_out_overrides_leave_the_shared_area_alone(self):
        area = f"{self.tmp}/bfp-area"
        for d in ("run", "out/older"):
            write(area, f"{d}/keep", "x\n")
        own = f"{self.tmp}/bfp-own"
        # LD64 and XTOOL outside their default paths: the inputs stage reports them
        # missing instead of building both toolchains (minutes) in the empty area.
        subprocess.run([PIPELINE, "--to", "inputs"], text=True, capture_output=True,
                       env=dict(os.environ, PLAYPORT_BUILD=area, PLAYPORT_RUN=f"{own}/run", PLAYPORT_OUT=f"{own}/out",
                                LD64=f"{self.tmp}/absent/ld64", XTOOL=f"{self.tmp}/absent/xtool"))
        self.assertTrue(os.path.exists(f"{own}/run/logs/build.log"))
        self.assertTrue(os.path.exists(f"{area}/run/keep"))
        self.assertTrue(os.path.exists(f"{area}/out/older/keep"))
        self.assertFalse(os.path.exists(f"{area}/run/logs"))


if __name__ == "__main__":
    unittest.main()
