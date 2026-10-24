# SPDX-License-Identifier: GPL-3.0-or-later
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("ipa_identity", Path(__file__).resolve().parents[2] / "build/verify-ipa.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class HelperIdentityTests(unittest.TestCase):
    def test_rejects_shared_missing_wildcard_or_wrong_default_groups(self):
        main = {"application-identifier": "TEST.main", "keychain-access-groups": ["TEST.main"]}
        helper = {"application-identifier": "TEST.helper", "keychain-access-groups": ["TEST.helper"]}
        self.assertTrue(verify.helper_keychain_isolated(main, helper))
        self.assertFalse(verify.helper_keychain_isolated(main, main))
        self.assertFalse(verify.helper_keychain_isolated({}, helper))
        self.assertFalse(verify.helper_keychain_isolated(main | {"keychain-access-groups": ["TEST.main", "TEST.*"]}, helper))
        self.assertFalse(verify.helper_keychain_isolated(main | {"keychain-access-groups": ["TEST.main", "TEST.helper"]}, helper))
        self.assertFalse(verify.helper_keychain_isolated(main, helper | {"keychain-access-groups": ["TEST.main", "TEST.helper"]}))
        self.assertFalse(verify.helper_keychain_isolated(main, helper | {"keychain-access-groups": ["TEST.helper", "TEST.main"]}))

    def test_profile_cannot_allow_another_identity_or_non_string_value(self):
        profile = {"application-identifier": "TEST.helper", "keychain-access-groups": ["TEST.*"]}
        self.assertTrue(verify.entitlement_allowed(profile, "application-identifier", "TEST.helper"))
        self.assertFalse(verify.entitlement_allowed(profile, "application-identifier", "TEST.main"))
        self.assertTrue(verify.entitlement_allowed(profile, "keychain-access-groups", ["TEST.helper"]))
        self.assertFalse(verify.entitlement_allowed(profile, "keychain-access-groups", ["OTHER.helper"]))
        self.assertFalse(verify.entitlement_allowed(profile, "keychain-access-groups", [True]))


if __name__ == "__main__":
    unittest.main()
