#!/usr/bin/env python3
"""Contract and static analysis tests for Batch 56:
- PRIV-010: Android Host Storage Permission Decoupling, Scoped Storage & SAF Perimeter
- PROV-006: Flutter-Rust Bridge Codegen Provenance Lock, --locked Flag & Zero-Drift Verification
"""

import json
import os
import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
MANIFEST_PATH = REPO_ROOT / "flutter" / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
SERVER_MODEL_PATH = REPO_ROOT / "flutter" / "lib" / "models" / "server_model.dart"
NATIVE_MODEL_PATH = REPO_ROOT / "flutter" / "lib" / "models" / "native_model.dart"
COMMON_DART_PATH = REPO_ROOT / "flutter" / "lib" / "common.dart"
MAIN_ACTIVITY_PATH = REPO_ROOT / "flutter" / "android" / "app" / "src" / "main" / "kotlin" / "com" / "camellia" / "remote" / "MainActivity.kt"
COMMON_KT_PATH = REPO_ROOT / "flutter" / "android" / "app" / "src" / "main" / "kotlin" / "com" / "camellia" / "remote" / "common.kt"
PROVENANCE_JSON_PATH = REPO_ROOT / ".github" / "config" / "bridge-codegen-provenance.json"
GENERATE_BRIDGE_SH_PATH = REPO_ROOT / ".github" / "scripts" / "generate-bridge.sh"
CI_YML_PATH = REPO_ROOT / ".github" / "workflows" / "ci.yml"


class TestBatch56StoragePrivacyAndCodegenContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest_text = MANIFEST_PATH.read_text(encoding="utf-8")
        cls.server_model_text = SERVER_MODEL_PATH.read_text(encoding="utf-8")
        cls.native_model_text = NATIVE_MODEL_PATH.read_text(encoding="utf-8")
        cls.common_dart_text = COMMON_DART_PATH.read_text(encoding="utf-8")
        cls.main_activity_text = MAIN_ACTIVITY_PATH.read_text(encoding="utf-8")
        cls.common_kt_text = COMMON_KT_PATH.read_text(encoding="utf-8")
        cls.generate_bridge_text = GENERATE_BRIDGE_SH_PATH.read_text(encoding="utf-8")
        cls.ci_yml_text = CI_YML_PATH.read_text(encoding="utf-8")
        cls.provenance_data = json.loads(PROVENANCE_JSON_PATH.read_text(encoding="utf-8"))

    # =========================================================================
    # PRIV-010: Android Manifest Invariants
    # =========================================================================

    def test_priv010_manifest_no_legacy_storage_flags_or_permissions(self):
        """PRIV-010: AndroidManifest.xml must not declare legacy or all-files storage permissions."""
        self.assertNotIn(
            "android.permission.MANAGE_EXTERNAL_STORAGE",
            self.manifest_text,
            "PRIV-010 violation: MANAGE_EXTERNAL_STORAGE must be removed from standard manifest",
        )
        self.assertNotIn(
            "android.permission.READ_EXTERNAL_STORAGE",
            self.manifest_text,
            "PRIV-010 violation: READ_EXTERNAL_STORAGE is deprecated and must not be declared",
        )
        self.assertNotIn(
            "android.permission.WRITE_EXTERNAL_STORAGE",
            self.manifest_text,
            "PRIV-010 violation: WRITE_EXTERNAL_STORAGE is deprecated and must not be declared",
        )
        self.assertNotIn(
            "requestLegacyExternalStorage",
            self.manifest_text,
            "PRIV-010 violation: requestLegacyExternalStorage must not be present on Android target 37",
        )

    def test_priv010_manifest_xml_structure_valid(self):
        """PRIV-010: Manifest XML must parse cleanly and retain essential foreground service permissions."""
        tree = ET.parse(MANIFEST_PATH)
        root = tree.getroot()
        permissions = [
            elem.attrib.get("{http://schemas.android.com/apk/res/android}name")
            for elem in root.findall("uses-permission")
        ]
        self.assertIn("android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION", permissions)
        self.assertIn("android.permission.POST_NOTIFICATIONS", permissions)
        self.assertNotIn("android.permission.MANAGE_EXTERNAL_STORAGE", permissions)

    # =========================================================================
    # PRIV-010: Flutter Dart Models & Common Invariants
    # =========================================================================

    def test_priv010_server_model_service_starts_without_storage_permission(self):
        """PRIV-010: toggleService and startService must have ZERO storage permission prompts."""
        # Find toggleService implementation
        start_idx = self.server_model_text.find("toggleService()")
        self.assertGreater(start_idx, 0, "toggleService() not found in server_model.dart")
        end_idx = self.server_model_text.find("Future<void> startService()", start_idx)
        self.assertGreater(end_idx, start_idx)
        toggle_body = self.server_model_text[start_idx:end_idx]

        self.assertNotIn(
            "kManageExternalStorage",
            toggle_body,
            "PRIV-010 violation: toggleService must not check or request kManageExternalStorage",
        )
        self.assertNotIn(
            "MANAGE_EXTERNAL_STORAGE",
            toggle_body,
            "PRIV-010 violation: toggleService must not reference MANAGE_EXTERNAL_STORAGE",
        )

    def test_priv010_server_model_permission_check_decoupled_from_storage(self):
        """PRIV-010: checkAndroidPermission must not gate file capability on kManageExternalStorage."""
        start_idx = self.server_model_text.find("checkAndroidPermission()")
        self.assertGreater(start_idx, 0, "checkAndroidPermission() not found")
        end_idx = self.server_model_text.find("updatePasswordModel()", start_idx)
        self.assertGreater(end_idx, start_idx)
        check_body = self.server_model_text[start_idx:end_idx]

        self.assertNotIn(
            "kManageExternalStorage",
            check_body,
            "PRIV-010 violation: checkAndroidPermission must decouple file capability from kManageExternalStorage",
        )

    def test_priv010_server_model_toggle_file_and_session_invalidation(self):
        """PRIV-010: toggleFile and stopService invalidate storage session generation."""
        self.assertIn(
            "storageGeneration",
            self.server_model_text,
            "PRIV-010 violation: ServerModel must expose storageGeneration counter",
        )
        self.assertIn(
            "invalidateStorageCapability",
            self.server_model_text,
            "PRIV-010 violation: ServerModel must provide invalidateStorageCapability()",
        )
        self.assertIn(
            "requestSafDirectoryGrant",
            self.server_model_text,
            "PRIV-010 violation: ServerModel must provide SAF directory grant request method",
        )

    def test_priv010_native_model_scoped_sandbox_directory(self):
        """PRIV-010: native_model.dart must use an app-scoped sandbox directory instead of unconstrained storage root."""
        self.assertNotIn(
            "ExternalPath.getExternalStorageDirectories",
            self.native_model_text,
            "PRIV-010 violation: native_model.dart must not query unconstrained external storage directories",
        )
        self.assertIn(
            "/shared",
            self.native_model_text,
            "PRIV-010 violation: native_model.dart must initialize scoped shared sandbox directory",
        )

    def test_priv010_common_dart_connect_file_transfer_no_storage_prompt(self):
        """PRIV-010: connect(isFileTransfer: true) must not demand kManageExternalStorage."""
        connect_idx = self.common_dart_text.find("connect(\n  BuildContext context,")
        if connect_idx < 0:
            connect_idx = self.common_dart_text.find("connect(")
        self.assertGreater(connect_idx, 0, "connect() not found in common.dart")
        connect_body = self.common_dart_text[connect_idx : connect_idx + 4000]

        # Ensure no kManageExternalStorage request in file transfer connection check
        file_transfer_idx = connect_body.find("if (isFileTransfer)")
        self.assertGreater(file_transfer_idx, 0, "if (isFileTransfer) branch not found in connect")
        file_branch = connect_body[file_transfer_idx : file_transfer_idx + 300]
        self.assertNotIn(
            "kManageExternalStorage",
            file_branch,
            "PRIV-010 violation: connect(isFileTransfer) must not demand kManageExternalStorage",
        )

    # =========================================================================
    # PRIV-010: Android Native SAF Channel Invariants
    # =========================================================================

    def test_priv010_android_saf_native_bridge_contract(self):
        """PRIV-010: MainActivity.kt and common.kt must provide SAF handlers and request code."""
        self.assertIn(
            "REQ_OPEN_DOCUMENT_TREE",
            self.common_kt_text,
            "PRIV-010 violation: REQ_OPEN_DOCUMENT_TREE constant must be defined in common.kt",
        )
        self.assertIn(
            "saf_open_document_tree",
            self.main_activity_text,
            "PRIV-010 violation: saf_open_document_tree MethodChannel handler missing in MainActivity.kt",
        )
        self.assertIn(
            "saf_list_persisted_roots",
            self.main_activity_text,
            "PRIV-010 violation: saf_list_persisted_roots MethodChannel handler missing in MainActivity.kt",
        )
        self.assertIn(
            "saf_revoke_persisted_root",
            self.main_activity_text,
            "PRIV-010 violation: saf_revoke_persisted_root MethodChannel handler missing in MainActivity.kt",
        )
        self.assertIn(
            "takePersistableUriPermission",
            self.main_activity_text,
            "PRIV-010 violation: MainActivity.kt must take persistable URI permissions on SAF tree grant",
        )

    # =========================================================================
    # PROV-006: FRB Codegen Provenance & Zero-Drift Invariants
    # =========================================================================

    def test_prov006_provenance_manifest_schema_and_checksums(self):
        """PROV-006: bridge-codegen-provenance.json must contain audited cryptographic digests."""
        self.assertEqual(self.provenance_data.get("schema_version"), 1)
        self.assertEqual(self.provenance_data.get("default_version"), "2.13.0")
        versions = self.provenance_data.get("versions", {})

        # Check 2.13.0
        self.assertIn("2.13.0", versions)
        v213 = versions["2.13.0"]
        self.assertEqual(
            v213["crate_sha256"],
            "701a8e577f9f5f59f651e1e932add36ee5dfb82d0fa20215225ea177d4dbbe4b",
        )
        self.assertEqual(
            v213["lockfile_sha256"],
            "226c2a5c9116415265d5c0c289f419c21d8d24e92dbbbe87456f7a9789d3ee57",
        )

        # Check 2.12.0
        self.assertIn("2.12.0", versions)
        v212 = versions["2.12.0"]
        self.assertEqual(
            v212["crate_sha256"],
            "13823e8157bada9dc828d67cd23e4bcebcfffa9313175dacad0325fc3188940c",
        )
        self.assertEqual(
            v212["lockfile_sha256"],
            "3b4351639c7cbd5c6df393e493ad084b6e7c01ae9ea36fb0097ab775af4e6785",
        )

    def test_prov006_generate_bridge_enforces_locked_and_provenance(self):
        """PROV-006: generate-bridge.sh must enforce --locked, repo root normalization, and checksum validation."""
        self.assertIn(
            "--locked",
            self.generate_bridge_text,
            "PROV-006 violation: cargo install in generate-bridge.sh must include --locked",
        )
        self.assertIn(
            "git rev-parse --show-toplevel",
            self.generate_bridge_text,
            "PROV-006 violation: generate-bridge.sh must normalize to repository root",
        )
        self.assertIn(
            "bridge-codegen-provenance.json",
            self.generate_bridge_text,
            "PROV-006 violation: generate-bridge.sh must validate against provenance manifest",
        )
        self.assertIn(
            "CARGO_HOME",
            self.generate_bridge_text,
            "PROV-006 violation: generate-bridge.sh must inspect CARGO_HOME environment variable",
        )
        self.assertIn(
            "if not crate_matches:",
            self.generate_bridge_text,
            "PROV-006 violation: generate-bridge.sh must fail-closed if crate_matches is empty",
        )
        self.assertIn(
            "if not lock_matches:",
            self.generate_bridge_text,
            "PROV-006 violation: generate-bridge.sh must fail-closed if lock_matches is empty",
        )

    def test_prov006_generate_bridge_unsupported_version_diagnostic(self):
        """PROV-006: generate-bridge.sh must provide clean diagnostic without NameError on unsupported version."""
        import subprocess

        env = os.environ.copy()
        env["FRB_CODEGEN_VERSION"] = "9.99.9"
        proc = subprocess.run(
            ["bash", str(GENERATE_BRIDGE_SH_PATH)],
            cwd=str(REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(proc.returncode, 0)
        combined_output = proc.stdout + proc.stderr
        self.assertIn("Unsupported FRB codegen version 9.99.9", combined_output)
        self.assertNotIn("NameError", combined_output)

    def test_prov006_ci_workflow_enforces_zero_bridge_drift(self):
        """PROV-006: ci.yml generate_bridge job must assert git diff --exit-code on bridge outputs."""
        gen_job_idx = self.ci_yml_text.find("generate_bridge:")
        self.assertGreater(gen_job_idx, 0, "generate_bridge job not found in ci.yml")
        next_job_idx = self.ci_yml_text.find("windows_rust:", gen_job_idx)
        self.assertGreater(next_job_idx, gen_job_idx)
        job_body = self.ci_yml_text[gen_job_idx:next_job_idx]

        self.assertIn(
            "Verify zero bridge drift",
            job_body,
            "PROV-006 violation: ci.yml must include 'Verify zero bridge drift' step",
        )
        self.assertIn(
            "git diff --exit-code",
            job_body,
            "PROV-006 violation: ci.yml must assert git diff --exit-code on bridge outputs",
        )
        self.assertIn("src/bridge_generated*.rs", job_body)
        self.assertIn("flutter/lib/generated_bridge", job_body)


if __name__ == "__main__":
    unittest.main()
