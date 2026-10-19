# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/gpu.py (pp gpu): the play's pad times, validation.txt from a play's
log, device log and crash report, and a capture's space check and its bundle's
removal from the phone (tools/afc.py rm-bundle, run here against an in-memory AFC)."""

import asyncio
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gpu  # noqa: E402
import phonelib  # noqa: E402

afc = phonelib.afc_tool()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class When(unittest.TestCase):
    def test_pad_times(self):
        self.assertEqual(gpu.when_of("35"), (False, 35.0))
        self.assertEqual(gpu.when_of("first-frame+90"), (True, 90.0))
        self.assertIsNone(gpu.when_of("ff+90"))


class Validation(unittest.TestCase):
    def test_report_groups_findings(self):
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "run", "pull", "s1-host.log")
            write(log, "title: diagnostics: Metal validation (API and shaders); device class MTLDebugDevice\n"
                       "2026-09-29 18:54:37.499 S1Probe[1323:143149] Set Stencil Reference Value Validation\n"
                       "redundant setStencilReferenceValue.\n"
                       "previous setStencilReferenceValue was unused.\n"
                       "2026-09-29 18:54:37.499 S1Probe[1323:143149] End Encoding Validation\n"
                       "unused vertex binding in render encoder at Buffer index 1.\n"
                       "info:  [FRAME_STATS] #64 cmdbufs=2\n"
                       "err:   Frame 3: INF or NAN detected in interpolant 'reg2_0'\n"
                       "err:   vertex function: \"vs_756ae290_5b6d\"\n"
                       "err:   \n"
                       "err:   pipeline: \"(null)\", pipeline UID: \"20AA\"\n"
                       "err:   Error detected in drawIndexedPrimitives: in encoder with label \"<no label>\"\n"
                       "err:   Frame 4: INF or NAN detected in interpolant 'reg2_0'\n"
                       "err:   vertex function: \"vs_756ae290_5b6d\"\n"
                       "err:   Device error at frame 9: Invalid Resource\n"
                       "err:   [mem-census] unrelated\n")
            write(os.path.join(d, "device-log.txt"),
                  "2026-09-29 18:42:16.711542 S1Probe{Metal}[1238] <NOTICE>: Metal API Validation Enabled\n"
                  "2026-09-29 18:42:29.392369 S1Probe{Metal}[1238] <ERROR>: <private>\n")
            r = gpu.validation_report(d, log, "shaders")
            text = open(os.path.join(d, "validation.txt")).read()
        self.assertTrue(r["armed"])
        self.assertEqual((r["shader_findings"], r["api_findings"], r["cmdbuf_errors"]), (2, 3, 1))
        self.assertIn("in 2 frames", text)
        self.assertIn("2  INF or NAN detected in interpolant 'reg2_0'  [vertex vs_756ae290_5b6d]", text)
        self.assertIn("Set Stencil Reference Value Validation: previous setStencilReferenceValue was unused.", text)
        self.assertIn("End Encoding Validation: unused vertex binding in render encoder at Buffer index 1.", text)
        self.assertIn("Device error at frame N: Invalid Resource", text)
        self.assertIn("device log: 1 Metal ERROR lines", text)

    def test_stop_quotes_the_crash_reports_assertion(self):
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "run", "pull", "s1-host.log")
            write(log, "title: diagnostics: Metal validation (API, ending at the first error); device class MTLDebugDevice\n")
            doc = {"asi": {"libsystem_c.dylib": ["-[MTLDebugRenderCommandEncoder validateCommonDrawErrors:]:5970: "
                                                 "failed assertion `Draw Errors Validation'"]}}
            write(os.path.join(d, "run", "crashes", "S1Probe-2026-09-29-184500.ips"),
                  json.dumps({"app_name": "S1Probe"}) + "\n" + json.dumps(doc))
            r = gpu.validation_report(d, log, "stop")
        self.assertEqual(len(r["stopped_at"]), 1)
        self.assertIn("validateCommonDrawErrors", r["stopped_at"][0])


class Space(unittest.TestCase):
    def test_a_capture_must_leave_the_reserve(self):
        self.assertIsNone(gpu.space_refusal(5.0, 1.0))
        self.assertIsNone(gpu.space_refusal(4.5, 1.0))
        self.assertIn("reserve", gpu.space_refusal(5.0, 3.0))
        self.assertIn("could not be read", gpu.space_refusal(None, 1.0))


class FakeAfc:
    """A container as AFC shows it: path -> ("dir",), ("file", size) or ("link", target)."""

    def __init__(self, entries):
        self.entries = dict(entries)
        self.removed = []

    async def exists(self, path):
        return path in self.entries

    async def stat(self, path):
        e = self.entries[path]
        return {"dir": {"st_ifmt": "S_IFDIR"}, "file": {"st_ifmt": "S_IFREG", "st_size": e[-1]},
                "link": {"st_ifmt": "S_IFLNK", "LinkTarget": e[-1]}}[e[0]]

    async def listdir(self, path):
        return [".", ".."] + [p[len(path) + 1:] for p in self.entries if os.path.dirname(p) == path]

    async def rm_single(self, path):
        if any(os.path.dirname(p) == path for p in self.entries):
            raise OSError(f"{path}: not empty")
        del self.entries[path]
        self.removed.append(path)


B = "Documents/prefix/drive_c/Games/RDR2/kk-frame3000-1.gputrace"
BUNDLE = {"Documents": ("dir",), "Documents/prefix/drive_c/Games/RDR2/RDR2.exe": ("file", 9),
          B: ("dir",), B + "/capture": ("file", 100), B + "/store0": ("dir",),
          B + "/store0/MTLBuffer-1": ("file", 20), B + "/store0/MTLTexture-2": ("link", "../MTLBuffer-1"),
          B + "/store0/up": ("link", "/")}


class RmBundle(unittest.TestCase):
    def test_only_a_gputrace_under_documents(self):
        for ok in (B, B + "/", "Documents/x.gputrace"):
            self.assertIsNone(afc.bundle_refusal(ok), ok)
        for bad in ("Documents", "Documents/", "Documents/prefix", "Documents/s1-host.log", "Library/x.gputrace",
                    "Documents/../x.gputrace", "Documents/a/./x.gputrace", "Documents//x.gputrace",
                    "Documents/.gputrace", "/Documents/x.gputrace", "Documents/x.gputrace/../prefix",
                    "Documents/x.gputrace.zip", "Documents/a;b.gputrace"):
            self.assertIsNotNone(afc.bundle_refusal(bad), bad)

    def test_removes_the_bundle_whose_counts_match_and_follows_no_link(self):
        fake = FakeAfc(BUNDLE)
        said = asyncio.run(afc.rm_bundle(fake, B, (2, 120, 2)))
        self.assertIn("removed (2 files, 120 bytes, 2 links)", said)
        self.assertEqual(set(fake.entries), {"Documents", "Documents/prefix/drive_c/Games/RDR2/RDR2.exe"})
        self.assertEqual(fake.removed[-1], B)

    def test_a_count_that_differs_deletes_nothing(self):
        for expect in ((2, 119, 2), (1, 120, 2), (2, 120, 1)):
            fake = FakeAfc(BUNDLE)
            with self.assertRaises(SystemExit) as e:
                asyncio.run(afc.rm_bundle(fake, B, expect))
            self.assertIn("left in place", str(e.exception))
            self.assertEqual(fake.removed, [])

    def test_the_local_copy_counts_as_the_phone_does(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as d:
            write(os.path.join(d, "b.gputrace", "capture"), "x" * 100)
            write(os.path.join(d, "b.gputrace", "store0", "MTLBuffer-1"), "y" * 20)
            os.symlink("../MTLBuffer-1", os.path.join(d, "b.gputrace", "store0", "MTLTexture-2"))
            os.symlink("/", os.path.join(d, "b.gputrace", "store0", "up"))
            self.assertEqual(gpu.local_counts(os.path.join(d, "b.gputrace")), (2, 120, 2))
        self.assertEqual(afc.counts(asyncio.run(afc.tree(FakeAfc(BUNDLE), B))), (2, 120, 2))


if __name__ == "__main__":
    unittest.main()
