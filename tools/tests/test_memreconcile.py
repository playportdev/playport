# SPDX-License-Identifier: GPL-3.0-or-later
"""The reconciliation rule of tools/memreconcile.py (PLA-808): DXVK's census breakdown against
its device memory, that memory plus KosmicKrisp's own allocations against KosmicKrisp's Metal
size, within 10 %, and which [kk-mem] line a [dxvk-mem] line is checked against. The lines here
carry only the fields the rule reads."""
import importlib.util
import io
import pathlib
import tempfile
import unittest
from contextlib import redirect_stdout

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("memreconcile", ROOT / "tools/memreconcile.py")
memreconcile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memreconcile)


def kk(metal, memory=0, internal=0, descriptor=0, query=0, command=0, pooled=None):
    line = (f"[kk-mem] metal={metal} memory=1/{memory} internal=1/{internal} descriptor=1/{descriptor} "
            f"query=1/{query} command=1/{command}")
    return line + (f" command-pooled=1/{pooled}" if pooled is not None else "")


def dxvk(allocated, metal=None, growing=False, kinds=None, pending=0, cached=0, free=None, drop=()):
    """A [dxvk-mem] line; by default its live memory is all in buffers=, and the kinds,
    pending=, cached= and free= add up to allocated=."""
    kinds = {**dict(rt=0, sampled=0, storage=0, staging=0, buffers=allocated - pending - cached - (free or 0)),
             **(kinds or {})}
    parts = [f"{k}=1/{v}" for k, v in kinds.items() if k not in drop]
    line = (f"info:  [dxvk-mem] metal={'-' if metal is None else metal} allocated={allocated} used=0 | "
            + " ".join(parts) + f" pending=2/{pending} oldest=0.25 s | cached={cached} free={free or 0} MiB")
    return line + (" | growing live+70 MiB" if growing else "")


class Rule(unittest.TestCase):
    def test_within_ten_percent(self):
        gap, share, ok = memreconcile.reconcile(758, 5, 777)
        self.assertEqual(gap, 14)
        self.assertTrue(ok)
        self.assertAlmostEqual(share, 14 / 777)
        # exactly 10 % either way is within; past it is a gap
        self.assertTrue(memreconcile.reconcile(900, 0, 1000)[2])
        self.assertTrue(memreconcile.reconcile(1100, 0, 1000)[2])
        self.assertFalse(memreconcile.reconcile(899, 0, 1000)[2])
        self.assertFalse(memreconcile.reconcile(1000, 101, 1000)[2])
        # a gap is named with its sign: Metal holding more than both, or less
        self.assertEqual(memreconcile.reconcile(500, 5, 777)[0], 272)
        self.assertEqual(memreconcile.reconcile(900, 0, 777)[0], -123)
        # no Metal memory: only nothing on both sides reconciles
        self.assertTrue(memreconcile.reconcile(0, 0, 0)[2])
        self.assertFalse(memreconcile.reconcile(1, 0, 0)[2])

    def test_kosmickrisps_own(self):
        """internal, descriptor, query, command and pooled command BOs; not the application's memory="""
        fields = memreconcile.fields(kk(800, memory=700, internal=1, descriptor=2, query=3, command=4, pooled=5),
                                     "[kk-mem]")
        self.assertEqual(memreconcile.kk_own(fields), 15)
        # a [kk-mem] line from before the pooled command BOs were counted
        self.assertEqual(memreconcile.kk_own(memreconcile.fields(kk(800, command=4), "[kk-mem]")), 4)


class Breakdown(unittest.TestCase):
    def breakdown(self, line):
        return memreconcile.breakdown(memreconcile.fields(line, "[dxvk-mem]"))

    def test_the_census_partitions_allocated(self):
        """the kinds, pending, cached and free add up to allocated=, MiB rounding aside"""
        live, unattributed, ok = self.breakdown(
            dxvk(1000, kinds=dict(rt=300, sampled=200, storage=50, staging=40, buffers=200), pending=60,
                 cached=100, free=50))
        self.assertEqual((live, unattributed, ok), (850, 150, True))
        # each part is rounded to the MiB on its own
        self.assertTrue(self.breakdown(dxvk(1004, kinds=dict(rt=300, sampled=200, storage=50, staging=40,
                                                             buffers=200), pending=60, cached=100, free=50))[2])

    def test_kinds_that_do_not_add_up(self):
        # an allocation the census counts under no kind, or a kind the line lost
        self.assertFalse(self.breakdown(
            dxvk(1000, kinds=dict(rt=300, sampled=200, storage=50, staging=40, buffers=150), pending=60,
                 cached=100, free=50))[2])
        self.assertFalse(self.breakdown(dxvk(1000, drop=("rt",)))[2])
        # the census counting more than the allocator hands out
        self.assertFalse(self.breakdown(
            dxvk(1000, kinds=dict(rt=300, sampled=200, storage=50, staging=40, buffers=480), pending=60,
                 cached=-180, free=50))[2])


class Pairing(unittest.TestCase):
    def test_nearest_metal_beside_it(self):
        lines = [kk(43, memory=40), "other", kk(777, memory=758, command=2), dxvk(760, metal=790, growing=True),
                 kk(800, memory=780, command=3), dxvk(780), kk(900)]
        found = memreconcile.pairs(lines)
        self.assertEqual([(d["allocated"], k["metal"], n, e) for d, k, n, e in found],
                         [("760", "800", 4, True), ("780", "800", 6, False)])

    def test_pairs_stay_within_their_log(self):
        """a [dxvk-mem] line is paired only with a [kk-mem] line of its own log"""
        with tempfile.TemporaryDirectory() as tmp:
            first, second = pathlib.Path(tmp) / "a.log", pathlib.Path(tmp) / "b.log"
            first.write_text("\n".join([kk(500, memory=480), dxvk(760, metal=800)]) + "\n")
            second.write_text("\n".join([kk(800, memory=780), dxvk(780, metal=800)]) + "\n")
            found = memreconcile.log_pairs([str(first), str(second)])
        self.assertEqual([(pathlib.Path(p).name, d["allocated"], k["metal"], n) for p, d, k, n, _ in found],
                         [("a.log", "760", "500", 2), ("b.log", "780", "800", 2)])

    def test_main_names_a_gap(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = pathlib.Path(tmp) / "s1-host.log"
            log.write_text("\n".join([kk(777, memory=758, command=2), dxvk(758, metal=777)]) + "\n")
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(memreconcile.main([str(log)]), 0)
            log.write_text("\n".join([kk(777, memory=758, command=2), dxvk(400, metal=777)]) + "\n")
            with redirect_stdout(out):
                self.assertEqual(memreconcile.main([str(log)]), 1)
            # Metal reconciles, but DXVK's kinds do not add up to its allocated=
            log.write_text("\n".join([kk(777, memory=758, command=2),
                                      dxvk(758, metal=777, kinds=dict(rt=100), drop=("buffers",))]) + "\n")
            with redirect_stdout(out):
                self.assertEqual(memreconcile.main([str(log)]), 1)
            log.write_text(kk(777) + "\n")
            with redirect_stdout(out):
                self.assertEqual(memreconcile.main([str(log)]), 2)


if __name__ == "__main__":
    unittest.main()
