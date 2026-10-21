# SPDX-License-Identifier: GPL-3.0-or-later
"""The FEX disk cache's process bucket keys on every environment switch that changes a compiled block
(patches/fex 0081, IosCodegenSwitches.h): the header's AppendIosCodegenSwitches, and every variable a
fex patch reads either listed there or named below as changing no block."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PATCHES = REPO / "patches/fex"
PATCH = PATCHES / "0081-DiskCache-key-the-iOS-process-bucket-on-every-codege.patch"
HEADER = "FEXCore/Source/Interface/Core/IosCodegenSwitches.h"

# Variables fex patches read that change no compiled block, and why.
NOT_CODEGEN = {
    "FEX_EC_CALL_RING": "Module.S's call ring, a runtime path",
    "FEX_SMCCHECKS_FOR": "sets SMCChecks, a config option SerializeForCache keys",
    "MADEIRA_FEX_BATCH2": "Module.S's transitions, the sweeper, where a backpatch is written",
    "MADEIRA_FEX_BATCH2_SKIP": "narrows MADEIRA_FEX_BATCH2",
    "MADEIRA_FEX_EC_BITMAP_CACHE": "the dispatcher, emitted each run",
    "MADEIRA_FEX_EC_CALLRET_POP": "the dispatcher, emitted each run",
    "MADEIRA_FEX_EC_EXIT_LEAN": "which ExitFunctionEC a thread's frame points at",
    "MADEIRA_FEX_SMC_FASTPATH": "Module.cpp's store-fault path",
    "MADEIRA_KEEP_SMC": "the invalidation tracker's write protection",
    "MADEIRA_NO_DIAGNOSTICS": "log lines only",
    "WINE_IOS_JIT_RW": "the JIT pool's addresses",
    "WINE_IOS_JIT_RX": "the JIT pool's addresses",
}


def new_file(patch: str, path: str) -> str:
    section = patch.split(f"+++ b/{path}\n", 1)[1]
    lines = []
    for line in section.splitlines():
        if line.startswith("diff --git") or line.startswith("-- "):
            break
        if line.startswith("+"):
            lines.append(line[1:])
    return "\n".join(lines) + "\n"


class FexCodegenSwitches(unittest.TestCase):
    def setUp(self):
        self.header = new_file(PATCH.read_text(), HEADER)
        listing = self.header.split("IosCodegenSwitchNames[] = {", 1)[1].split("};", 1)[0]
        self.keyed = re.findall(r'"([A-Z0-9_]+)"', listing)

    def test_every_patch_variable_is_keyed_or_named(self):
        read = set()
        for patch in sorted(PATCHES.glob("*.patch")):
            for line in patch.read_text(errors="replace").splitlines():
                if line.startswith("+"):
                    read.update(re.findall(r'getenv\("([A-Za-z0-9_]+)"\)', line))
        self.assertIn("MADEIRA_FEX_AFPOFF_FPCR", read)
        unknown = sorted(read - set(self.keyed) - set(NOT_CODEGEN))
        self.assertEqual(unknown, [], "a fex patch reads a variable neither IosCodegenSwitches.h keys nor "
                                      "NOT_CODEGEN names")
        self.assertEqual(sorted(set(self.keyed) & set(NOT_CODEGEN)), [])

    def test_append(self):
        self.assertEqual(self.keyed, ["MADEIRA_FEX_EC_RET", "MADEIRA_X64_QPC_FASTPATH", "MADEIRA_FEX_AFPOFF_FPCR",
                                      "MADEIRA_NO_DFE", "FEX_TRACE_RIP"])
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="fex-codegen-switches-", dir=work) as tmp:
            root = Path(tmp)
            (root / "IosCodegenSwitches.h").write_text(self.header)
            (root / "test.cpp").write_text(r'''
#include <cassert>
#include <map>
#include <string>
#include "IosCodegenSwitches.h"

static std::string Key(const std::map<std::string, std::string>& Env) {
  std::string Out;
  FEXCore::DiskCache::AppendIosCodegenSwitches(Out, [&Env](const char* Name) -> const char* {
    auto It = Env.find(Name);
    return It == Env.end() ? nullptr : It->second.c_str();
  });
  return Out;
}

int main() {
  assert(Key({}).empty());
  assert(Key({{"MADEIRA_FEX_BATCH2", "1"}, {"MADEIRA_FEX_EC_CALLRET_POP", "1"}}).empty());
  assert(Key({{"MADEIRA_X64_QPC_FASTPATH", "1"}}) == std::string("MADEIRA_X64_QPC_FASTPATH=1\0", 27));
  assert(Key({{"MADEIRA_FEX_AFPOFF_FPCR", "fiz"}}) != Key({{"MADEIRA_FEX_AFPOFF_FPCR", "ah"}}));
  assert(Key({{"MADEIRA_FEX_EC_RET", "0"}}) != Key({}));
  assert(Key({{"MADEIRA_FEX_EC_RET", ""}}) != Key({}));
  const std::string All = Key({{"FEX_TRACE_RIP", "401000"}, {"MADEIRA_FEX_EC_RET", "0"}});
  assert(All == std::string("MADEIRA_FEX_EC_RET=0\0FEX_TRACE_RIP=401000\0", 42));
  return 0;
}
''')
            subprocess.run(["c++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-o", str(root / "test"),
                            str(root / "test.cpp")], check=True)
            subprocess.run([str(root / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
