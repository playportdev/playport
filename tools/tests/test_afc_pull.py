# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/afc.py pull_file (pp phone pull, the drivers' log pulls): small reads, a dropped
connection reopened and resumed at its offset, and no file left behind when it fails,
run here against an in-memory AFC."""

import asyncio
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import phonelib  # noqa: E402

afc = phonelib.afc_tool()


class Dropped(ConnectionError):
    pass


class FakeAfc:
    """One AFC connection to a container holding FILES; it drops after `reads` reads."""

    def __init__(self, files, reads):
        self.files, self.reads, self.pos = files, reads, {}

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def exists(self, path):
        return path in self.files

    async def stat(self, path):
        return {"st_ifmt": "S_IFREG", "st_size": len(self.files[path])}

    async def fopen(self, path):
        self.pos[1] = (path, 0)
        return 1

    async def fseek(self, h, offset):
        self.pos[h] = (self.pos[h][0], offset)

    async def fread(self, h, size):
        if self.reads <= 0:
            raise Dropped("Connection was terminated abruptly")
        self.reads -= 1
        path, at = self.pos[h]
        self.pos[h] = (path, at + size)
        return self.files[path][at:at + size]

    async def fclose(self, h):
        del self.pos[h]


def connector(files, reads_per_connection):
    """connect() for pull_file: each call is a new connection, with the next read budget."""
    budgets = iter(reads_per_connection)
    opened = []

    async def connect():
        opened.append(1)
        return FakeAfc(files, next(budgets))
    return connect, opened


DATA = bytes(range(256)) * 41   # 10,496 bytes: not a multiple of the chunk


class PullFile(unittest.TestCase):
    def pull(self, reads, remote="Documents/s1-host.log", chunk=1000, tries=3):
        connect, opened = connector({"Documents/s1-host.log": DATA}, reads)
        os.makedirs(os.path.join(phonelib.BUILD, "tmp"), exist_ok=True)
        d = tempfile.mkdtemp(dir=os.path.join(phonelib.BUILD, "tmp"))
        self.addCleanup(shutil.rmtree, d)
        local = os.path.join(d, "s1-host.log")
        return local, opened, lambda: asyncio.run(afc.pull_file(connect, remote, local, chunk=chunk, tries=tries))

    def test_whole_file_in_one_connection(self):
        local, opened, run = self.pull([100])
        self.assertEqual(run(), len(DATA))
        self.assertEqual(open(local, "rb").read(), DATA)
        self.assertEqual(len(opened), 1)
        self.assertFalse(os.path.exists(local + ".part"))

    def test_dropped_connections_resume_at_their_offset(self):
        local, opened, run = self.pull([3, 0, 4, 100])
        self.assertEqual(run(), len(DATA))
        self.assertEqual(open(local, "rb").read(), DATA)
        self.assertEqual(len(opened), 4)

    def test_no_progress_gives_up_and_leaves_no_file(self):
        local, opened, run = self.pull([2, 0, 0, 0, 100])
        with self.assertRaises(SystemExit) as e:
            run()
        self.assertIn("2000 of 10496 bytes", str(e.exception))
        self.assertFalse(os.path.exists(local))
        self.assertFalse(os.path.exists(local + ".part"))

    def test_absent_file_is_refused(self):
        local, _, run = self.pull([100], remote="Documents/nope.log")
        with self.assertRaises(SystemExit) as e:
            run()
        self.assertIn("no such file", str(e.exception))
        self.assertFalse(os.path.exists(local))


if __name__ == "__main__":
    unittest.main()
