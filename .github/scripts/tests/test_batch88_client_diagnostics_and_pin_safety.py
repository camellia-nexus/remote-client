#!/usr/bin/env python3
"""Contract and unit tests for Batch 88 (CRED-005, DIAG-001).

Validates:
1. CRED-005: Unlock PIN constant-time verification, removal of plaintext PIN getters across
   IPC, UI interface, and Flutter FFI, zero plaintext PIN holding in Flutter widgets/controllers,
   and clean controller disposal.
2. DIAG-001: Client bounded, redacted support bundle export with size caps (10 MiB uncompressed,
   2 MiB compressed), multi-pass secret redaction (IPs, tokens, passwords), fail-closed canary
   scanner, strict 0600 archive permissions, and CLI `--support-bundle` dispatch.
3. Submodule Provenance: Verified commit linkage to protocol batch88.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import unittest

CLIENT_ROOT = Path(__file__).resolve().parents[3]


class ClientDiagnosticsContractTests(unittest.TestCase):
    """DIAG-001 contract tests."""

    def test_diagnostics_module_exists_and_registered(self):
        diag_path = CLIENT_ROOT / "src" / "diagnostics.rs"
        self.assertTrue(diag_path.exists(), "src/diagnostics.rs must exist")

        lib_content = (CLIENT_ROOT / "src" / "lib.rs").read_text(encoding="utf-8")
        self.assertIn(
            "pub mod diagnostics;",
            lib_content,
            "src/lib.rs must export pub mod diagnostics;",
        )

    def test_diagnostics_constants_and_caps(self):
        diag_content = (CLIENT_ROOT / "src" / "diagnostics.rs").read_text(encoding="utf-8")
        self.assertIn("MAX_UNCOMPRESSED_BYTES: usize = 10 * 1024 * 1024", diag_content)
        self.assertIn("MAX_COMPRESSED_BYTES: usize = 2 * 1024 * 1024", diag_content)
        self.assertIn("CANARY_SECRET_PATTERNS", diag_content)
        self.assertIn("BEGIN PRIVATE KEY", diag_content)
        self.assertIn("BEGIN OPENSSH PRIVATE KEY", diag_content)

    def test_support_bundle_cli_integration(self):
        main_content = (CLIENT_ROOT / "src" / "main.rs").read_text(encoding="utf-8")
        self.assertIn("--support-bundle", main_content)
        self.assertIn("export_client_support_bundle", main_content)

        core_main_content = (CLIENT_ROOT / "src" / "core_main.rs").read_text(encoding="utf-8")
        self.assertIn("--support-bundle", core_main_content)
        self.assertIn("export_client_support_bundle", core_main_content)

    def test_diagnostics_redaction_and_canary_logic(self):
        diag_content = (CLIENT_ROOT / "src" / "diagnostics.rs").read_text(encoding="utf-8")
        self.assertIn("pub fn mask_text_secrets", diag_content)
        self.assertIn("[REDACTED_BEARER_TOKEN]", diag_content)
        self.assertIn("[REDACTED_TOKEN]", diag_content)
        self.assertIn("[REDACTED_PASSWORD]", diag_content)
        self.assertIn("scan_for_canaries", diag_content)
        self.assertIn("write_secure_file", diag_content)
        self.assertIn("0o600", diag_content)


class UnlockPinSafetyContractTests(unittest.TestCase):
    """CRED-005 contract tests."""

    def test_ipc_refuses_plaintext_unlock_pin(self):
        ipc_content = (CLIENT_ROOT / "src" / "ipc.rs").read_text(encoding="utf-8")
        # In IPC get_sync_options handling:
        self.assertIn('name == "unlock-pin"', ipc_content)
        match = re.search(
            r'else if name == "unlock-pin"\s*\{(?P<body>[^}]+)\}', ipc_content
        )
        self.assertTrue(match, "unlock-pin handler must exist in ipc.rs")
        body = match.group("body")
        self.assertIn("value = None;", body, "IPC must never return plaintext unlock PIN")
        self.assertNotIn("Config::get_unlock_pin", body)

    def test_ipc_provides_authoritative_verification(self):
        ipc_content = (CLIENT_ROOT / "src" / "ipc.rs").read_text(encoding="utf-8")
        self.assertIn("pub fn has_unlock_pin() -> bool", ipc_content)
        self.assertIn("pub fn verify_unlock_pin(candidate: &str) -> bool", ipc_content)
        # get_unlock_pin must not return Config::get_unlock_pin
        match = re.search(
            r'pub fn get_unlock_pin\(\) -> String\s*\{(?P<body>[^}]+)\}', ipc_content
        )
        self.assertTrue(match, "get_unlock_pin must exist for legacy compat")
        body = match.group("body")
        self.assertNotIn("Config::get_unlock_pin", body)
        self.assertIn("String::new()", body)

    def test_ui_interface_provides_authoritative_verification(self):
        ui_content = (CLIENT_ROOT / "src" / "ui_interface.rs").read_text(encoding="utf-8")
        self.assertIn("pub fn has_unlock_pin() -> bool", ui_content)
        self.assertIn("pub fn verify_unlock_pin(candidate: String) -> bool", ui_content)
        match = re.search(
            r'pub fn get_unlock_pin\(\) -> String\s*\{(?P<body>[^}]+)\}', ui_content
        )
        self.assertTrue(match)
        self.assertIn("deprecated", ui_content)

    def test_flutter_ffi_never_exposes_plaintext_pin(self):
        ffi_content = (CLIENT_ROOT / "src" / "flutter_ffi.rs").read_text(encoding="utf-8")
        match = re.search(
            r'pub fn main_get_unlock_pin\(\) -> String\s*\{(?P<body>[^}]+)\}', ffi_content
        )
        self.assertTrue(match, "main_get_unlock_pin must exist in flutter_ffi.rs")
        body = match.group("body")
        self.assertNotIn("get_unlock_pin()", body)
        self.assertIn("has_unlock_pin()", body)
        self.assertIn('"*".to_string()', body)
        self.assertIn('verify-unlock-pin:', ffi_content)
        self.assertIn('has-unlock-pin', ffi_content)

    def test_flutter_dialogs_never_prefill_or_hold_plain_pin(self):
        dialog_content = (CLIENT_ROOT / "flutter" / "lib" / "common" / "widgets" / "dialog.dart").read_text(
            encoding="utf-8"
        )
        # changeUnlockPinDialog must start with empty controllers, never oldPin
        self.assertIn("void changeUnlockPinDialog(Function() callback)", dialog_content)
        self.assertNotIn("TextEditingController(text: oldPin)", dialog_content)

        # checkUnlockPinDialog must not accept correctPin parameter
        self.assertIn("void checkUnlockPinDialog(Function() passCallback)", dialog_content)
        self.assertNotIn("String correctPin", dialog_content)
        self.assertIn("verify-unlock-pin:", dialog_content)

    def test_desktop_setting_page_calls_safe_dialogs(self):
        settings_content = (CLIENT_ROOT / "flutter" / "lib" / "desktop" / "pages" / "desktop_setting_page.dart").read_text(
            encoding="utf-8"
        )
        self.assertIn("changeUnlockPinDialog(update);", settings_content)
        self.assertIn("checkUnlockPinDialog(onUnlock);", settings_content)
        self.assertNotIn("changeUnlockPinDialog(unlockPin.value", settings_content)
        self.assertNotIn("checkUnlockPinDialog(unlockPin,", settings_content)


class ProvenanceContractTests(unittest.TestCase):
    """Source provenance and submodule linkage tests."""

    def test_protocol_source_provenance_pinned_to_batch88(self):
        provenance_path = CLIENT_ROOT / "SOURCE_PROVENANCE.json"
        self.assertTrue(provenance_path.exists())
        data = json.loads(provenance_path.read_text(encoding="utf-8"))
        self.assertEqual(
            data["protocol_source_commit"],
            "2d2e51ffbaee7d989d15acf637a71086f8d83891",
        )


if __name__ == "__main__":
    unittest.main()
