#!/usr/bin/env python3
"""Contract and static analysis tests for Batch 84 Apple Security & Compliance:
- SIGN-001: macOS Release entitlement least privilege (eradication of allow-jit in Release AOT builds)
- COMPLIANCE-001: iOS cryptographic export compliance inventory and Info.plist alignment
"""

import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

REPO_ROOT = Path(__file__).resolve().parents[3]
CLIENT_ROOT = REPO_ROOT
MACOS_RELEASE_ENTITLEMENTS = (
    CLIENT_ROOT / "flutter" / "macos" / "Runner" / "Release.entitlements"
)
MACOS_DEBUG_ENTITLEMENTS = (
    CLIENT_ROOT / "flutter" / "macos" / "Runner" / "DebugProfile.entitlements"
)
IOS_INFO_PLIST = CLIENT_ROOT / "flutter" / "ios" / "Runner" / "Info.plist"
IOS_EXPORT_COMPLIANCE_JSON = (
    CLIENT_ROOT / "flutter" / "ios" / "export_compliance.json"
)


class TestBatch84AppleSecurityAndCompliance(unittest.TestCase):
    def test_sign001_macos_release_entitlements_omits_allow_jit(self):
        """SIGN-001: Release.entitlements must NOT contain com.apple.security.cs.allow-jit."""
        self.assertTrue(
            MACOS_RELEASE_ENTITLEMENTS.is_file(),
            f"Missing file: {MACOS_RELEASE_ENTITLEMENTS}",
        )
        content = MACOS_RELEASE_ENTITLEMENTS.read_text(encoding="utf-8")
        self.assertNotIn(
            "com.apple.security.cs.allow-jit",
            content,
            "SIGN-001 violation: com.apple.security.cs.allow-jit found in Release.entitlements",
        )

        # Parse XML to verify valid plist structure
        tree = ET.fromstring(content)
        dict_elem = tree.find("dict")
        self.assertIsNotNone(dict_elem, "Missing <dict> element in Release.entitlements")

        keys = [elem.text for elem in dict_elem.findall("key")]
        self.assertNotIn("com.apple.security.cs.allow-jit", keys)
        self.assertIn("com.apple.security.network.client", keys)

    def test_sign001_macos_debug_profile_retains_allow_jit(self):
        """SIGN-001: DebugProfile.entitlements must retain allow-jit for developer JIT execution."""
        self.assertTrue(
            MACOS_DEBUG_ENTITLEMENTS.is_file(),
            f"Missing file: {MACOS_DEBUG_ENTITLEMENTS}",
        )
        content = MACOS_DEBUG_ENTITLEMENTS.read_text(encoding="utf-8")
        self.assertIn(
            "com.apple.security.cs.allow-jit",
            content,
            "DebugProfile.entitlements should preserve allow-jit for JIT debug builds",
        )

    def test_compliance001_ios_info_plist_non_exempt_encryption_declared_false(self):
        """COMPLIANCE-001: iOS Info.plist must declare ITSAppUsesNonExemptEncryption as false."""
        self.assertTrue(IOS_INFO_PLIST.is_file(), f"Missing file: {IOS_INFO_PLIST}")
        content = IOS_INFO_PLIST.read_text(encoding="utf-8")
        self.assertIn(
            "<key>ITSAppUsesNonExemptEncryption</key>",
            content,
            "COMPLIANCE-001 violation: ITSAppUsesNonExemptEncryption key missing from iOS Info.plist",
        )

        tree = ET.fromstring(content)
        dict_elem = tree.find("dict")
        self.assertIsNotNone(dict_elem, "Missing <dict> element in iOS Info.plist")

        elements = list(dict_elem)
        key_found = False
        val_tag = None
        for i, elem in enumerate(elements):
            if elem.tag == "key" and elem.text == "ITSAppUsesNonExemptEncryption":
                key_found = True
                if i + 1 < len(elements):
                    val_tag = elements[i + 1].tag
                break

        self.assertTrue(key_found, "ITSAppUsesNonExemptEncryption key not located in dict")
        self.assertEqual(
            val_tag,
            "false",
            "COMPLIANCE-001 violation: ITSAppUsesNonExemptEncryption must be boolean <false/>",
        )

    def test_compliance001_export_compliance_manifest_structure(self):
        """COMPLIANCE-001: export_compliance.json must exist with complete cryptographic inventory and ECCN classification."""
        self.assertTrue(
            IOS_EXPORT_COMPLIANCE_JSON.is_file(),
            f"Missing file: {IOS_EXPORT_COMPLIANCE_JSON}",
        )
        with open(IOS_EXPORT_COMPLIANCE_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)

        self.assertEqual(data.get("version"), "1.0.0")
        self.assertEqual(data.get("app_identifier"), "com.camellia.remote")

        plist_decl = data.get("apple_info_plist_declaration", {})
        self.assertEqual(plist_decl.get("key"), "ITSAppUsesNonExemptEncryption")
        self.assertIs(plist_decl.get("value"), False)
        self.assertGreater(len(plist_decl.get("rationale", "")), 10)

        classification = data.get("export_compliance_classification", {})
        self.assertEqual(classification.get("us_eccn"), "5D992.c")
        self.assertIn("mass_market", classification.get("exemption_category", ""))
        self.assertIn(
            "app-store-connect",
            classification.get("approved_distribution_channels", []),
        )

        inventory = data.get("cryptographic_inventory", [])
        self.assertGreaterEqual(len(inventory), 3, "Inventory must contain at least 3 crypto components")

        crates = {item.get("crate") for item in inventory}
        self.assertIn("crypto_box", crates)
        self.assertIn("crypto_secretbox", crates)
        self.assertIn("tokio-rustls", crates)

        for item in inventory:
            self.assertTrue(item.get("algorithm"))
            self.assertGreaterEqual(item.get("key_length_bits", 0), 128)
            self.assertTrue(item.get("purpose"))


if __name__ == "__main__":
    unittest.main()
