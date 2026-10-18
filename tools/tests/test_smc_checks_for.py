# SPDX-License-Identifier: GPL-3.0-or-later
"""FEX_SMCCHECKS_FOR's parsing and matching (patches/fex 0050, PLA-401). That its value
survives a game's Runtime keys row is PublisherLauncherTests'."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
PATCH = REPO / "patches/fex/0050-ARM64EC-give-one-executable-its-own-SMC-checks-on-iO.patch"
HEADER = "Source/Windows/Common/SMCChecksFor.h"


def new_file(patch: str, path: str) -> str:
    section = patch.split(f"+++ b/{path}\n", 1)[1]
    lines = []
    for line in section.splitlines():
        if line.startswith("diff --git") or line.startswith("-- "):
            break
        if line.startswith("+"):
            lines.append(line[1:])
    return "\n".join(lines) + "\n"


class SMCChecksFor(unittest.TestCase):
    def test_parse_and_match(self):
        header = new_file(PATCH.read_text(), HEADER)
        work = REPO / ".work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="smc-checks-for-", dir=work) as tmp:
            root = Path(tmp)
            (root / "SMCChecksFor.h").write_text(header)
            (root / "test.cpp").write_text(r'''
#include <cassert>
#include "SMCChecksFor.h"
using FEX::Windows::ParseSMCChecksFor;
using K = FEX::Windows::SMCChecksForResult::KindType;

static bool is(FEX::Windows::SMCChecksForResult r, K kind, int mode = 0) {
  return r.Kind == kind && (kind != K::Apply || r.Mode == mode);
}

int main() {
  assert(is(ParseSMCChecksFor("Launcher.exe=mtrack", "Launcher.exe"), K::Apply, 1));
  assert(is(ParseSMCChecksFor("launcher.EXE=mtrack", "Launcher.exe"), K::Apply, 1));
  assert(is(ParseSMCChecksFor("Launcher.exe=none", "Launcher.exe"), K::Apply, 0));
  assert(is(ParseSMCChecksFor("Launcher.exe=full", "Launcher.exe"), K::Apply, 2));
  assert(is(ParseSMCChecksFor("Launcher.exe=mtrack", "SocialClubHelper.exe"), K::OtherProcess));
  assert(is(ParseSMCChecksFor("Launcher.exe=mtrack", "Launcher.exe2"), K::OtherProcess));
  assert(is(ParseSMCChecksFor("Launcher.exe=mtrack", ""), K::OtherProcess));
  assert(is(ParseSMCChecksFor("Launcher.exe=MTrack", "Launcher.exe"), K::Invalid));
  assert(is(ParseSMCChecksFor("Launcher.exe=", "Launcher.exe"), K::Invalid));
  assert(is(ParseSMCChecksFor("Launcher.exe", "Launcher.exe"), K::Invalid));
  assert(is(ParseSMCChecksFor("=mtrack", "Launcher.exe"), K::Invalid));
  assert(is(ParseSMCChecksFor("", "Launcher.exe"), K::Invalid));
  return 0;
}
''')
            subprocess.run(["c++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-o", str(root / "test"),
                            str(root / "test.cpp")], check=True)
            subprocess.run([str(root / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
