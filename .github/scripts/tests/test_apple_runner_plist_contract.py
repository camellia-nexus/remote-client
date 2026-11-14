#!/usr/bin/env python3
"""Automated regression test suite for Apple Runner Plist Contract and Expat Validator."""

import importlib.util
from pathlib import Path
import plistlib
import unittest

MODULE_PATH = Path(__file__).resolve().parents[1] / "verify_apple_deployment.py"
SPEC = importlib.util.spec_from_file_location("verify_apple_deployment", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
apple_policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(apple_policy)

SourcePlistValidator = apple_policy.SourcePlistValidator
APPLE_PLIST_TYPE_SCHEMA = apple_policy.APPLE_PLIST_TYPE_SCHEMA
DuplicateRejectingDict = apple_policy.DuplicateRejectingDict
PolicyError = apple_policy.PolicyError
verify_apple_runner_plists = apple_policy.verify_apple_runner_plists


class AppleRunnerPlistContractTests(unittest.TestCase):
    """Test suite covering the 9 validation fixtures and repository plists."""

    def test_fixture_1_valid_plist_passes(self):
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.camellia.remote</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
        </dict>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>"""
        v = SourcePlistValidator("valid.plist", APPLE_PLIST_TYPE_SCHEMA, {"CFBundleIdentifier", "LSUIElement"})
        errors = v.validate(xml)
        self.assertEqual(errors, [])

    def test_fixture_2_duplicate_key_same_value_rejected(self):
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CADisableMinimumFrameDurationOnPhone</key>
    <true/>
    <key>CADisableMinimumFrameDurationOnPhone</key>
    <true/>
</dict>
</plist>"""
        v = SourcePlistValidator("dup_same.plist", APPLE_PLIST_TYPE_SCHEMA)
        errors = v.validate(xml)
        self.assertEqual(len(errors), 1)
        self.assertIn("Duplicate key 'CADisableMinimumFrameDurationOnPhone'", errors[0])
        self.assertIn("first defined at line 4", errors[0])

    def test_fixture_3_duplicate_key_different_value_rejected(self):
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CADisableMinimumFrameDurationOnPhone</key>
    <false/>
    <key>CADisableMinimumFrameDurationOnPhone</key>
    <true/>
</dict>
</plist>"""
        v = SourcePlistValidator("dup_diff.plist", APPLE_PLIST_TYPE_SCHEMA)
        errors = v.validate(xml)
        self.assertEqual(len(errors), 1)
        self.assertIn("Duplicate key 'CADisableMinimumFrameDurationOnPhone'", errors[0])

    def test_fixture_4_wrong_value_type_boolean_as_string_rejected(self):
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <string>1</string>
</dict>
</plist>"""
        v = SourcePlistValidator("wrong_type.plist", APPLE_PLIST_TYPE_SCHEMA)
        errors = v.validate(xml)
        self.assertEqual(len(errors), 1)
        self.assertIn("Key 'LSUIElement' expected boolean, got <string> (string)", errors[0])

    def test_fixture_5_wrong_value_type_boolean_as_integer_rejected(self):
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CADisableMinimumFrameDurationOnPhone</key>
    <integer>1</integer>
</dict>
</plist>"""
        v = SourcePlistValidator("wrong_type.plist", APPLE_PLIST_TYPE_SCHEMA)
        errors = v.validate(xml)
        self.assertEqual(len(errors), 1)
        self.assertIn("Key 'CADisableMinimumFrameDurationOnPhone' expected boolean, got <integer> (integer)", errors[0])

    def test_fixture_6_nested_dict_duplicate_key_rejected(self):
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>"""
        v = SourcePlistValidator("nested_dup.plist", APPLE_PLIST_TYPE_SCHEMA)
        errors = v.validate(xml)
        self.assertEqual(len(errors), 1)
        self.assertIn("Duplicate key 'CFBundleTypeRole' in dict", errors[0])

    def test_fixture_7_missing_required_key_rejected(self):
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.camellia.remote</string>
</dict>
</plist>"""
        v = SourcePlistValidator("missing_key.plist", APPLE_PLIST_TYPE_SCHEMA, {"CFBundleIdentifier", "LSUIElement"})
        errors = v.validate(xml)
        self.assertEqual(len(errors), 1)
        self.assertIn("Missing required root keys: ['LSUIElement']", errors[0])

    def test_fixture_8_unclosed_dict_rejected(self):
        xml = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.camellia.remote</string>
</plist>"""
        v = SourcePlistValidator("unclosed.plist", APPLE_PLIST_TYPE_SCHEMA)
        errors = v.validate(xml)
        self.assertTrue(any("XML syntax error" in e or "Unclosed dict scope" in e for e in errors))

    def test_fixture_9_plistlib_duplicate_rejecting_dict(self):
        xml = b"""<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>A</key><string>1</string>
    <key>A</key><string>2</string>
</dict>
</plist>"""
        with self.assertRaises(PolicyError) as ctx:
            plistlib.loads(xml, dict_type=DuplicateRejectingDict)
        self.assertIn("Duplicate key detected in dict: 'A'", str(ctx.exception))

    def test_repository_apple_runner_plists_pass_validation(self):
        # Must pass cleanly with zero errors on repository files
        verify_apple_runner_plists()


if __name__ == "__main__":
    unittest.main()
