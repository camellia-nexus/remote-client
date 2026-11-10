#!/usr/bin/env python3
"""Contract and static analysis tests for Android dependency verification and Protobuf upgrade (Batch 55).

Validates:
- PROV-005: JitPack repository has strict content filtering (only com.github.* allowed).
- PROV-005: Gradle dependency verification metadata (verification-metadata.xml) is established.
- DEP-003: Protobuf runtime and compiler are upgraded from 3.20.1 to >= 3.25.5 (0 OSV CVEs).
- DEP-003: Rust bridge strips/clears unknown fields and groups before serializing protobuf to JNI.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
ANDROID_DIR = REPO_ROOT / "flutter" / "android"
ROOT_BUILD_GRADLE = ANDROID_DIR / "build.gradle"
APP_BUILD_GRADLE = ANDROID_DIR / "app" / "build.gradle"
VERIFICATION_METADATA = ANDROID_DIR / "gradle" / "verification-metadata.xml"
CONNECTION_RS = REPO_ROOT / "src" / "server" / "connection.rs"
CLIPBOARD_RS = REPO_ROOT / "src" / "clipboard.rs"


class TestAndroidDependencyAndProtobufContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root_gradle = ROOT_BUILD_GRADLE.read_text(encoding="utf-8")
        cls.app_gradle = APP_BUILD_GRADLE.read_text(encoding="utf-8")
        cls.connection_rs = CONNECTION_RS.read_text(encoding="utf-8")
        cls.clipboard_rs = CLIPBOARD_RS.read_text(encoding="utf-8")

    def test_jitpack_repository_content_filtering(self):
        """PROV-005: JitPack repository must have content filtering restricting allowed groups."""
        self.assertIn("jitpack.io", self.root_gradle)
        # Match content { ... includeGroup ... }
        jitpack_pattern = r"url\s+['\"]https://jitpack\.io['\"][\s\S]*?content\s*\{[\s\S]*?includeGroup"
        match = re.search(jitpack_pattern, self.root_gradle)
        self.assertIsNotNone(
            match,
            "PROV-005 violation: JitPack repository block must include a content { includeGroup... } filter",
        )

    def test_protobuf_javalite_version_upgraded(self):
        """DEP-003: protobuf-javalite must be upgraded to 3.25.5 and not contain vulnerable 3.20.1."""
        self.assertNotIn(
            "protobuf-javalite:3.20.1",
            self.app_gradle,
            "DEP-003 violation: protobuf-javalite 3.20.1 contains known CVEs and must be upgraded",
        )
        self.assertIn(
            "protobuf-javalite:3.25.5",
            self.app_gradle,
            "DEP-003 violation: protobuf-javalite must be upgraded to at least 3.25.5",
        )

    def test_protoc_artifact_version_upgraded(self):
        """DEP-003: protoc artifact must match runtime version >= 3.25.5 and not contain 3.20.1."""
        self.assertNotIn(
            "com.google.protobuf:protoc:3.20.1",
            self.app_gradle,
            "DEP-003 violation: protoc 3.20.1 must be upgraded",
        )
        self.assertIn(
            "com.google.protobuf:protoc:3.25.5",
            self.app_gradle,
            "DEP-003 violation: protoc must be upgraded to at least 3.25.5",
        )

    def test_gradle_verification_metadata_exists(self):
        """PROV-005: Gradle verification-metadata.xml must exist with sha256 checksums."""
        self.assertTrue(
            VERIFICATION_METADATA.exists(),
            f"PROV-005 violation: {VERIFICATION_METADATA} must exist",
        )
        content = VERIFICATION_METADATA.read_text(encoding="utf-8")
        self.assertIn("<verification-metadata", content)
        self.assertIn("sha256", content)

    def test_rust_bridge_clears_unknown_fields_key_event(self):
        """DEP-003: Rust KeyEvent handler must clear unknown fields before sending to JNI."""
        idx = self.connection_rs.find("call_main_service_key_event(&data)")
        self.assertGreater(idx, 0, "call_main_service_key_event call not found")
        surrounding_block = self.connection_rs[idx - 400 : idx]
        self.assertIn(
            "special_fields.clear()",
            surrounding_block,
            "DEP-003 violation: KeyEvent must clear special_fields before serializing to JNI",
        )

    def test_rust_bridge_clears_unknown_fields_clipboard(self):
        """DEP-003: Rust MultiClipboards handlers must clear unknown fields before sending to JNI."""
        idx = self.clipboard_rs.find("call_clipboard_manager_update_clipboard(&bytes)")
        self.assertGreater(idx, 0, "call_clipboard_manager_update_clipboard call not found")
        # Ensure special_fields.clear() is present in clipboard.rs
        self.assertIn(
            "special_fields.clear()",
            self.clipboard_rs,
            "DEP-003 violation: MultiClipboards must clear special_fields before serializing to JNI",
        )


if __name__ == "__main__":
    unittest.main()
