# SPDX-License-Identifier: GPL-3.0-or-later
"""Playport's Steam client serves methods by the generated slot table (decision 0115).

app/SteamClientShim/steamclient_slots.h is generated from the pinned SDK headers by
build/steamclient-vtables.py (the build stage checks it is theirs). Here: the slots the
launcher's steam_api surely calls sit where the public SDK documents them, every method the
shim serves by name exists in its family's table, the classes returned through MSVC's
hidden pointer are the CSteamID getters, the i386 argument sizes are those the SDK's
signatures take, and every version string an i386 steam_api of the old and new SDKs asks
for is in the table (an i386 client cannot answer a version it has no sizes for)."""

import os
import re
import unittest
from pathlib import Path

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SLOTS = os.path.join(ROOT, "app", "SteamClientShim", "steamclient_slots.h")
SHIM = os.path.join(ROOT, "app", "SteamClientShim", "steamclient.c")


def tables():
    text = Path(SLOTS).read_text()
    names = {m.group(1): re.findall(r'"(~?\w+)",', m.group(2))
             for m in re.finditer(r"pp_names_(\w+)\[\d+\] = \{(.*?)\};", text, re.S)}
    hidden = dict(re.findall(r'pp_hidden_(\w+)\[\] = "([01]*)";', text))
    floats = dict(re.findall(r'pp_float_(\w+)\[\] = "([01]*)";', text))
    words = {k: [int(w) for w in v.split(",")] for k, v in re.findall(r"pp_words_(\w+)\[\d+\] = \{ ([\d, ]+) \};", text)}
    count = {k: int(v) for k, v in re.findall(r"#define PP_SLOTS_(\w+) (\d+)", text)}
    versions = dict((v, c) for c, v in re.findall(r'^    X\((\w+), "([^"]+)"\)', text, re.M))
    return names, hidden, count, words, floats, versions


class SteamClientSlots(unittest.TestCase):
    def test_every_interface_has_names_flags_sizes_and_a_count_that_agree(self):
        names, hidden, count, words, floats, versions = tables()
        self.assertEqual(set(names), set(count))
        self.assertEqual(set(names), set(versions.values()))
        for k in names:
            self.assertEqual(len(names[k]), count[k], k)
            self.assertEqual(len(hidden[k]), count[k], k)
            self.assertEqual(len(words[k]), count[k], k)
            self.assertEqual(len(floats[k]), count[k], k)
            self.assertLessEqual(count[k], 128, k)   # the shim's trampolines and thunks (MAX_SLOTS)

    def test_the_init_path_sits_where_the_sdk_puts_it(self):
        names, _, _, words, _, versions = tables()
        for v in range(7, 24):
            c = names[versions[f"SteamClient{v:03d}"]]
            self.assertEqual(c[:3], ["CreateSteamPipe", "BReleaseSteamPipe", "ConnectToGlobalUser"], v)
            self.assertIn("GetISteamUser", c)
        for v in range(9, 24):
            self.assertEqual(names[versions[f"SteamUser{v:03d}"]][:3], ["GetHSteamUser", "BLoggedOn", "GetSteamID"], v)
        self.assertEqual(names["ISteamClient006"][:4], ["CreateSteamPipe", "BReleaseSteamPipe", "CreateGlobalUser",
                                                         "ConnectToGlobalUser"])
        self.assertEqual(names["ISteamHTMLSurface"][0], "~ISteamHTMLSurface")
        self.assertEqual(words["ISteamHTMLSurface"][0], 1)   # MSVC's deleting destructor takes its flags
        self.assertEqual(names["ISteamUtils010"].index("GetAppID"), 9)
        self.assertEqual(names["ISteamApps008"].index("BIsSubscribedApp"), 6)
        self.assertEqual(names["ISteamUser022"].index("GetAuthSessionTicket"), 13)
        # i386: what each takes on the stack after this, in 4-byte words.
        u = names["ISteamUser022"]
        self.assertEqual(words["ISteamUser022"][u.index("GetSteamID")], 1)              # the hidden pointer
        self.assertEqual(words["ISteamUser022"][u.index("GetAuthSessionTicket")], 4)    # buf, cap, size, identity
        self.assertEqual(words["ISteamUser022"][u.index("UserHasLicenseForApp")], 3)    # CSteamID, app
        t = names["ISteamUtils010"]
        self.assertEqual(words["ISteamUtils010"][t.index("GetAPICallResult")], 6)       # uint64 call, buf, size, cb, failed
        c = names["ISteamClient017"]
        self.assertEqual(words["ISteamClient017"][c.index("GetISteamUtils")], 2)
        self.assertEqual(words["ISteamClient017"][c.index("GetISteamUser")], 3)
        self.assertEqual(words["ISteamClient017"][c.index("DEPRECATED_GetISteamUnifiedMessages")], 3)

    def test_what_an_i386_steam_api_asks_for_is_in_the_table(self):
        # Half-Life's (SDK 1.5x) and an older SDK's i386 steam_api.dll, read with strings.
        _, _, _, _, _, versions = tables()
        for v in ("SteamClient017", "SteamClient020", "SteamUser018", "SteamUser021", "SteamFriends015", "SteamFriends017",
                  "SteamUtils007", "SteamUtils010", "SteamMatchMaking009", "SteamMatchMakingServers002",
                  "STEAMUSERSTATS_INTERFACE_VERSION011", "STEAMUSERSTATS_INTERFACE_VERSION012",
                  "STEAMAPPS_INTERFACE_VERSION007", "STEAMAPPS_INTERFACE_VERSION008", "SteamNetworking005",
                  "SteamNetworking006", "STEAMREMOTESTORAGE_INTERFACE_VERSION013", "STEAMREMOTESTORAGE_INTERFACE_VERSION016",
                  "STEAMSCREENSHOTS_INTERFACE_VERSION002", "STEAMHTTP_INTERFACE_VERSION002",
                  "STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001", "SteamController003", "SteamController008", "SteamInput006",
                  "STEAMUGC_INTERFACE_VERSION007", "STEAMUGC_INTERFACE_VERSION016", "STEAMAPPLIST_INTERFACE_VERSION001",
                  "STEAMMUSIC_INTERFACE_VERSION001", "STEAMMUSICREMOTE_INTERFACE_VERSION001", "SteamGameServer012",
                  "SteamGameServerStats001", "SteamNetworkingSockets012", "SteamNetworkingUtils004"):
            self.assertIn(v, versions)

    def test_class_returns_are_the_steamid_getters(self):
        names, hidden, _, _, _, _ = tables()
        for k in names:
            returned = {names[k][i] for i, f in enumerate(hidden[k]) if f == "1"}
            if re.fullmatch(r"ISteamUser\d*", k):
                self.assertEqual(returned - {"GetSteamID", "GetPublicIP"}, set(), k)
                if "GetSteamID" in names[k]:
                    self.assertIn("GetSteamID", returned, k)
            if re.fullmatch(r"ISteam(Client|Utils)\d*", k):
                self.assertEqual(returned, set(), k)
            if re.fullmatch(r"ISteamApps\d*", k) and "GetAppOwner" in names[k]:
                self.assertEqual(returned, {"GetAppOwner"}, k)

    def test_every_served_method_is_in_its_familys_table(self):
        names, _, _, _, floats, _ = tables()
        served = re.findall(r'\{ "(ISteam\w+)", "(\w+)", \(void \*\)\w+ \}', Path(SHIM).read_text())
        self.assertGreater(len(served), 40)
        for family, method in served:
            have = [k for k in names if re.fullmatch(family + r"\d*", k) and method in names[k]]
            self.assertTrue(have, f"{family}::{method} is in no table")
            # The i386 thunk calls a served method with integer results only.
            for k in have:
                self.assertEqual(floats[k][names[k].index(method)], "0", f"{k}::{method} returns a float")


if __name__ == "__main__":
    unittest.main()
