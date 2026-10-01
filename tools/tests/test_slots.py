# SPDX-License-Identifier: GPL-3.0-or-later
"""tools/slots.py (pp slots): winemetal's thunks against the unix call tables,
on a synthetic tree in the shape of the patched DXMT one."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
import slots  # noqa: E402

THUNKS = """\
#define UNIX_CALL(code, params) WINE_UNIX_CALL(code, params)

WINEMETAL_API void
NSObject_retain(obj_handle_t obj) {
  UNIX_CALL(0, &obj);
}

WINEMETAL_API obj_handle_t
WMTCopyAllDevices() {
  struct unixcall_generic_obj_ret params;
  if (x) { y(); }
  UNIX_CALL(1, &params);
  return params.ret;
}
"""
AIRCONV_H = """\
enum airconv_unixcalls {
  unix_sm50_initialize = 2,
  unix_sm50_compile_tessellation_hull,
};
#define UNIX_CALL(code, params) WINE_UNIX_CALL(unix_##code, params)
"""
AIRCONV = """\
AIRCONV_API int SM50Initialize(
    const void *pBytecode, size_t BytecodeSize) {
  status = UNIX_CALL(sm50_initialize, &params);
}
AIRCONV_API int SM50CompileTessellationPipelineHull(void *p) {
  status = UNIX_CALL(sm50_compile_tessellation_hull, &params);
}
"""
TABLES = """\
const void *__wine_unix_call_funcs[] = {
    &_NSObject_retain,
    &_MTLCopyAllDevices,
    &thunk_SM50Initialize,
    &thunk_SM50CompileTessellationPipelineHull,
};

const void *__wine_unix_call_wow64_funcs[] = {
    &_NSObject_retain,
    &_MTLCopyAllDevices_wow64,
    &thunk32_SM50Initialize,
    &thunk32_SM50CompileTessellationPipelineHull,
};
"""


class Slots(unittest.TestCase):
    def tree(self, tables=TABLES, airconv_h=AIRCONV_H):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = tmp.name
        wm = os.path.join(root, "src", "winemetal")
        os.makedirs(os.path.join(wm, "unix"))
        for path, text in (("winemetal_thunks.c", THUNKS), ("airconv_thunks.h", airconv_h),
                           ("airconv_thunks.c", AIRCONV), ("unix/winemetal_unix.c", tables)):
            with open(os.path.join(wm, path), "w") as f:
                f.write(text)
        return root

    def test_matching_tree(self):
        self.assertEqual(slots.check(self.tree()), (4, 4, []))

    def test_swapped_entries(self):
        swapped = TABLES.replace("&_NSObject_retain,\n    &_MTLCopyAllDevices,\n",
                                 "&_MTLCopyAllDevices,\n    &_NSObject_retain,\n", 1)
        bad = slots.check(self.tree(tables=swapped))[2]
        self.assertIn("slot   0: native _MTLCopyAllDevices, wow64 _NSObject_retain", bad)
        self.assertIn("slot   0: thunk NSObject_retain, native _MTLCopyAllDevices", bad)

    def test_shifted_airconv_enum(self):
        bad = slots.check(self.tree(airconv_h=AIRCONV_H.replace("= 2", "= 1")))[2]
        self.assertIn("slot   1: thunk SM50Initialize, native _MTLCopyAllDevices", bad)
        self.assertIn("slot   2: thunk SM50CompileTessellationPipelineHull, native thunk_SM50Initialize", bad)

    def test_call_past_the_table(self):
        bad = slots.check(self.tree(airconv_h=AIRCONV_H.replace("= 2", "= 3")))[2]
        self.assertTrue(any("past the end" in b for b in bad))


if __name__ == "__main__":
    unittest.main()
