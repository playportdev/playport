# SPDX-License-Identifier: GPL-3.0-or-later
"""Playport's steamclient64.dll serves methods by the generated slot table (decision 0115).

app/SteamClientShim/steamclient_slots.h is generated from the pinned SDK headers by
build/steamclient-vtables.py (the build stage checks it is theirs). Here: the slots the
launcher's steam_api surely calls sit where the public SDK documents them, every method the
shim serves by name exists in its family's table, and the classes returned through MSVC's
hidden pointer are the CSteamID getters."""

import os
import re
import unittest
from pathlib import Path

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SLOTS = os.path.join(ROOT, "app", "SteamClientShim", "steamclient_slots.h")
SHIM = os.path.join(ROOT, "app", "SteamClientShim", "steamclient.c")


def tables():
    text = Path(SLOTS).read_text()
    names = {m.group(1): re.findall(r'"(\w+)",', m.group(2))
             for m in re.finditer(r"pp_names_(\w+)\[\d+\] = \{(.*?)\};", text, re.S)}
    hidden = dict(re.findall(r'pp_hidden_(\w+)\[\] = "([01]*)";', text))
    count = {k: int(v) for k, v in re.findall(r"#define PP_SLOTS_(\w+) (\d+)", text)}
    return names, hidden, count


class SteamClientSlots(unittest.TestCase):
    def test_every_interface_has_names_flags_and_a_count_that_agree(self):
        names, hidden, count = tables()
        self.assertEqual(set(names), set(count))
        for k in names:
            self.assertEqual(len(names[k]), count[k], k)
            self.assertEqual(len(hidden[k]), count[k], k)
            self.assertLessEqual(count[k], 100, k)   # the shim's trampolines (MAX_SLOTS)

    def test_the_init_path_sits_where_the_sdk_puts_it(self):
        names, _, _ = tables()
        for v in ("017", "018", "019", "020", "021", "022", "023"):
            c = names["ISteamClient" + v]
            self.assertEqual(c[:3], ["CreateSteamPipe", "BReleaseSteamPipe", "ConnectToGlobalUser"], v)
            self.assertIn("GetISteamGenericInterface", c)
        for v in ("017", "018", "019", "020", "021", "022", "023"):
            self.assertEqual(names["ISteamUser" + v][:3], ["GetHSteamUser", "BLoggedOn", "GetSteamID"], v)
        self.assertEqual(names["ISteamUtils010"].index("GetAppID"), 9)
        self.assertEqual(names["ISteamApps008"].index("BIsSubscribedApp"), 6)
        self.assertEqual(names["ISteamUser022"].index("GetAuthSessionTicket"), 13)

    def test_class_returns_are_the_steamid_getters(self):
        names, hidden, _ = tables()
        for k in names:
            returned = {names[k][i] for i, f in enumerate(hidden[k]) if f == "1"}
            if k.startswith("ISteamUser"):
                self.assertEqual(returned, {"GetSteamID"}, k)
            if k.startswith("ISteamClient") or k.startswith("ISteamUtils"):
                self.assertEqual(returned, set(), k)
            if k.startswith("ISteamApps"):
                self.assertEqual(returned, {"GetAppOwner"}, k)

    def test_every_served_method_is_in_its_familys_table(self):
        names, _, _ = tables()
        served = re.findall(r'\{ "(ISteam\w+)", "(\w+)", \(void \*\)\w+ \}', Path(SHIM).read_text())
        self.assertGreater(len(served), 40)
        for family, method in served:
            have = [k for k in names if k.startswith(family) and method in names[k]]
            self.assertTrue(have, f"{family}::{method} is in no table")


if __name__ == "__main__":
    unittest.main()
