# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/afc.py pull_tree (pp gpu capture's bundle pull): several connections at once, links
kept as links, dropped connections reopened and their task retried, and a stopped pull
resumed (files already whole kept), run here against an in-memory AFC."""

import asyncio
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import phonelib  # noqa: E402

afc = phonelib.afc_tool()

ROOT = "Documents/g/x.gputrace"


def bundle():
    """A bundle tree: path -> bytes (a file), None (a directory) or ("link", target)."""
    t = {ROOT: None, ROOT + "/sub": None}
    for i in range(30):
        t[f"{ROOT}/MTLBuffer-{i}"] = bytes([i]) * (1000 + 37 * i)
    for i in range(10):
        t[f"{ROOT}/MTLHeap-{i}"] = ("link", "MTLBuffer-0")
    t[ROOT + "/sub/metadata"] = b"meta" * 300
    t[ROOT + "/empty"] = b""
    return t


class Dropped(ConnectionError):
    pass


class FakeAfc:
    """One AFC connection; `state` is shared: the tree, a budget of requests after which
    this connection drops, how many connections are in a request at once."""

    def __init__(self, state, budget):
        self.s, self.budget, self.h = state, budget, {}

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def _req(self):
        if self.budget <= 0:
            raise Dropped("Connection was terminated abruptly")
        self.budget -= 1
        self.s["busy"] += 1
        self.s["peak"] = max(self.s["peak"], self.s["busy"])
        await asyncio.sleep(0.001)
        self.s["busy"] -= 1
        self.s["requests"] += 1

    async def listdir(self, path):
        await self._req()
        return [".", ".."] + [p[len(path) + 1:] for p in self.s["tree"] if p.startswith(path + "/") and "/" not in p[len(path) + 1:]]

    async def stat(self, path):
        await self._req()
        v = self.s["tree"][path]
        if v is None:
            return {"st_ifmt": "S_IFDIR"}
        if isinstance(v, tuple):
            return {"st_ifmt": "S_IFLNK", "LinkTarget": v[1]}
        return {"st_ifmt": "S_IFREG", "st_size": len(v)}

    async def fopen(self, path):
        await self._req()
        self.h[1] = [path, 0]
        return 1

    async def fseek(self, h, offset):
        await self._req()
        self.h[h][1] = offset

    async def fread(self, h, size):
        await self._req()
        path, at = self.h[h]
        self.h[h][1] = at + size
        self.s["read"] += min(size, len(self.s["tree"][path]) - at)
        return self.s["tree"][path][at:at + size]

    async def fclose(self, h):
        await self._req()
        del self.h[h]


class PullTree(unittest.TestCase):
    def setUp(self):
        os.makedirs(os.path.join(phonelib.BUILD, "tmp"), exist_ok=True)
        self.d = tempfile.mkdtemp(dir=os.path.join(phonelib.BUILD, "tmp"))
        self.addCleanup(shutil.rmtree, self.d)
        self.local = os.path.join(self.d, "x.gputrace")

    def run_pull(self, tree, budgets=None, workers=4, tries=3):
        state = {"tree": tree, "busy": 0, "peak": 0, "requests": 0, "read": 0, "opened": 0}
        budgets = iter(budgets or [])

        async def connect():
            state["opened"] += 1
            return FakeAfc(state, next(budgets, 10 ** 9))
        n = asyncio.run(afc.pull_tree(connect, ROOT, self.local, workers=workers, chunk=256, tries=tries))
        return n, state

    def check_copy(self, tree):
        for p, v in tree.items():
            dst = os.path.join(self.d, p[len("Documents/g/"):])
            if v is None:
                self.assertTrue(os.path.isdir(dst), p)
            elif isinstance(v, tuple):
                self.assertEqual(os.readlink(dst), v[1], p)
            else:
                self.assertEqual(open(dst, "rb").read(), v, p)
        parts = [n for _, _, ns in os.walk(self.d) for n in ns if n.endswith(".part")]
        self.assertEqual(parts, [])

    def test_whole_tree_with_several_connections(self):
        tree = bundle()
        n, state = self.run_pull(tree)
        self.check_copy(tree)
        files = [v for v in tree.values() if isinstance(v, bytes)]
        self.assertEqual(n, (len(files), sum(map(len, files)), 10, 0))
        self.assertGreater(state["peak"], 1, "requests should overlap across connections")
        self.assertLessEqual(state["opened"], 4)

    def test_dropped_connections_are_reopened(self):
        tree = bundle()
        n, state = self.run_pull(tree, budgets=[5, 3, 7, 2, 9, 4, 6, 1])
        self.check_copy(tree)
        self.assertGreater(state["opened"], 4)

    def test_stopped_pull_resumes_and_keeps_whole_files(self):
        tree = bundle()
        self.run_pull(tree)
        os.remove(os.path.join(self.local, "MTLBuffer-3"))
        with open(os.path.join(self.local, "MTLBuffer-4"), "wb") as f:   # cut short
            f.write(b"\4" * 10)
        os.remove(os.path.join(self.local, "MTLHeap-2"))
        n, state = self.run_pull(tree)
        self.check_copy(tree)
        files = [v for v in tree.values() if isinstance(v, bytes)]
        self.assertEqual(n[3], len(files) - 2)
        self.assertEqual(state["read"], len(tree[ROOT + "/MTLBuffer-3"]) + len(tree[ROOT + "/MTLBuffer-4"]))

    def test_a_task_failing_every_connection_ends_the_pull(self):
        with self.assertRaises(SystemExit) as e:
            self.run_pull(bundle(), budgets=[0] * 50, workers=2, tries=3)
        self.assertIn("3 connections in a row failed", str(e.exception))


if __name__ == "__main__":
    unittest.main()
