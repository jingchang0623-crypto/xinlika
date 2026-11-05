import copy
import datetime
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("apple_signing", Path(__file__).with_name("prepare-apple-signing.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class AppleSigningTests(unittest.TestCase):
    def profile(self, bundle="com.zaowuyun.shennao"):
        return {"UUID": "12345678-1234-1234-1234-123456789ABC", "TeamIdentifier": ["TESTTEAM01"],
                "ApplicationIdentifierPrefix": ["OLDPREFIX1"],
                "ExpirationDate": datetime.datetime(2099, 1, 1),
                "Entitlements": {"application-identifier": f"OLDPREFIX1.{bundle}",
                                 "com.apple.developer.team-identifier": "TESTTEAM01", "get-task-allow": False}}

    def test_valid_exact_app_id_with_legacy_prefix(self):
        self.assertEqual(signing.validate_profile(self.profile(), "com.zaowuyun.shennao", "TESTTEAM01"), self.profile()["UUID"])

    def test_rejects_wrong_bundle_team_expired_and_non_appstore_profiles(self):
        for change in [
            {"ExpirationDate": datetime.datetime(2000, 1, 1)},
            {"TeamIdentifier": ["OTHERTEAM1"]},
            {"Entitlements": {"application-identifier": "OLDPREFIX1.*", "com.apple.developer.team-identifier": "TESTTEAM01"}},
            {"ProvisionedDevices": ["synthetic-device"]},
            {"ProvisionsAllDevices": True},
            {"UUID": "../../invalid"},
        ]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                signing.validate_profile(self.profile() | change, "com.zaowuyun.shennao", "TESTTEAM01")

    def test_rejects_debug_entitlement_even_without_device_list(self):
        profile = self.profile()
        profile["Entitlements"]["get-task-allow"] = True
        with self.assertRaises(ValueError):
            signing.validate_profile(profile, "com.zaowuyun.shennao", "TESTTEAM01")

    def test_missing_secrets_reports_names_without_values(self):
        with patch.dict(os.environ, {"APPLE_TEAM_ID": "SENSITIVE-SYNTHETIC-VALUE"}, clear=True):
            with self.assertRaises(ValueError) as error:
                signing.check_inputs()
        self.assertIn("ASC_PRIVATE_KEY_BASE64", str(error.exception))
        self.assertNotIn("SENSITIVE-SYNTHETIC-VALUE", str(error.exception))

    def test_generates_matching_phone_watch_manual_signing_and_export(self):
        env = dict.fromkeys(signing.REQUIRED, "synthetic-only")
        env.update(APPLE_TEAM_ID="TESTTEAM01", ASC_KEY_ID="TESTKEY001")
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, env, clear=True):
            root = Path(tmp)
            for target, bundle in signing.TARGETS.items():
                profile = copy.deepcopy(self.profile(bundle))
                if target == "XinlikaWatch":
                    profile["UUID"] = "87654321-1234-1234-1234-123456789ABC"
                (root / f"{target}.plist").write_bytes(plistlib.dumps(profile))
            signing.prepare(root, root / "spec.json", "100.1.2")
            generated = json.loads((root / "spec.json").read_text())
            exported = plistlib.loads((root / "ExportOptions.plist").read_bytes())
            self.assertEqual(generated["settings"]["base"]["CURRENT_PROJECT_VERSION"], "100.1.2")
            self.assertEqual(exported["destination"], "upload")
            self.assertFalse(exported["manageAppVersionAndBuildNumber"])
            for target, bundle in signing.TARGETS.items():
                settings = generated["targets"][target]["settings"]["base"]
                self.assertEqual(settings["CODE_SIGN_STYLE"], "Manual")
                self.assertEqual(settings["CODE_SIGN_IDENTITY"], signing.SIGNING_CERTIFICATE)
                self.assertEqual(settings["PROVISIONING_PROFILE_SPECIFIER"], exported["provisioningProfiles"][bundle])
            self.assertEqual(exported["signingCertificate"], signing.SIGNING_CERTIFICATE)
            with self.assertRaises(ValueError):
                signing.prepare(root, root / "spec.json", "100.1.2; unsafe")


if __name__ == "__main__":
    unittest.main()
