# SPDX-License-Identifier: GPL-3.0-or-later
"""FEX's multiblock decoder does not continue past a CALL in writable code on iOS (patches/fex 0096, PLA-873).

Mono emits each method's exception throws at its end as `call` to a throw helper that never
returns, and it writes the next method right after it: `memcpy`, then the calls are patched in
place. Decoding past that last call translates the next method's bytes, possibly before they are
patched. Upstream stops only when Mono was detected by its DLL's name; on iOS it stops in every
writable executable range."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PATCH = REPO / "patches/fex/0096-FEXCore-on-iOS-decode-no-further-than-a-call-in-writ.patch"
HEADER = "FEXCore/Source/Interface/Core/IosMultiblock.h"


def new_file(patch: str, path: str) -> str:
    section = patch.split(f"+++ b/{path}\n", 1)[1]
    lines = []
    for line in section.splitlines():
        if line.startswith("diff --git") or line.startswith("-- "):
            break
        if line.startswith("+"):
            lines.append(line[1:])
    return "\n".join(lines) + "\n"


class DecodePastCall(unittest.TestCase):
    def test_rule(self):
        patch = PATCH.read_text()
        header = new_file(patch, HEADER)
        # The decoder's CALL branch asks the rule, with the range's writability and Mono's state.
        frontend = patch.split("+++ b/FEXCore/Source/Interface/Core/Frontend.cpp\n", 1)[1].split("diff --git", 1)[0]
        self.assertIn("+#include \"Interface/Core/IosMultiblock.h\"", frontend)
        self.assertIn("+    if (!DecodesPastCall(ExecutableRangeWritable, CTX->AreMonoHacksActive())) {", frontend)
        self.assertIn("-    if (ExecutableRangeWritable && CTX->AreMonoHacksActive()) {", frontend)
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="fex-decode-past-call-", dir=work) as tmp:
            root = Path(tmp)
            (root / "IosMultiblock.h").write_text(header)
            (root / "test.cpp").write_text(r'''
#include <cassert>
#include "IosMultiblock.h"
using FEXCore::Frontend::DecodesPastCall;

int main() {
#ifdef FEX_IOS_HOST
  // Writable code (a JIT's): never past a call, Mono detected or not.
  assert(!DecodesPastCall(true, false));
  assert(!DecodesPastCall(true, true));
#else
  // Upstream: only Mono's writable code stops there.
  assert(DecodesPastCall(true, false));
  assert(!DecodesPastCall(true, true));
#endif
  // An image's code, never written: past calls, as upstream.
  assert(DecodesPastCall(false, false));
  assert(DecodesPastCall(false, true));
  return 0;
}
''')
            for defines in (["-DFEX_IOS_HOST"], []):
                subprocess.run(["c++", "-std=c++20", "-Wall", "-Wextra", "-Werror", *defines, "-o", str(root / "test"),
                                str(root / "test.cpp")], check=True)
                subprocess.run([str(root / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
