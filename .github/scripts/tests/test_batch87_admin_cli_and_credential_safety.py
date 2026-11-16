#!/usr/bin/env python3
"""Contract tests for Batch 87 (DEP-004, CRED-003, CRED-006).

Validates:
1. DEP-004: camellia-remote-admin Python packaging, locked dependencies (uv.lock & requirements.lock),
   clean offline missing-dependency guidance, and CI automation gate enforcement.
2. CRED-003: Windows Logon elevation zeroization contracts across Windows FFI, portable service,
   IO loop message lifecycle, Flutter elevation dialog, and Web bridge fail-closed rejection.
3. CRED-006: Redaction of transient credentials from desktop tab pages and Peer safe JSON projection.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

CLIENT_ROOT = Path(__file__).resolve().parents[3]


class AdminCliPackagingContractTests(unittest.TestCase):
    """DEP-004 contract tests."""

    def test_pyproject_configuration_and_metadata(self):
        pyproject_path = CLIENT_ROOT / "pyproject.toml"
        self.assertTrue(pyproject_path.exists(), "pyproject.toml must exist at client root")
        content = pyproject_path.read_text(encoding="utf-8")

        self.assertIn('name = "camellia-remote-admin"', content)
        self.assertIn('requires-python = ">=3.13,<3.16"', content)
        self.assertIn('license = "AGPL-3.0-only"', content)
        self.assertIn('camellia-remote-admin = "camellia_remote_admin.__main__:main"', content)
        self.assertIn('module-name = "camellia_remote_admin"', content)
        self.assertIn('module-root = "tools/admin-cli/src"', content)

    def test_locked_dependency_files_and_hashes(self):
        uv_lock = CLIENT_ROOT / "uv.lock"
        req_lock = CLIENT_ROOT / "tools" / "admin-cli" / "requirements.lock"

        self.assertTrue(uv_lock.exists(), "uv.lock must exist at client root")
        self.assertTrue(req_lock.exists(), "requirements.lock must exist")

        req_content = req_lock.read_text(encoding="utf-8")
        self.assertIn("--hash=sha256:", req_content, "requirements.lock must enforce sha256 hashes")
        self.assertIn("requests==", req_content, "requests must be explicitly locked")

    def test_ci_workflow_enforces_admin_cli_validation(self):
        ci_path = CLIENT_ROOT / ".github" / "workflows" / "ci.yml"
        content = ci_path.read_text(encoding="utf-8")

        self.assertIn("Set up uv", content, "CI must configure uv")
        self.assertIn("Validate Admin CLI package and quality", content)
        self.assertIn("uv sync --locked", content)
        self.assertIn("uv run ruff check tools/admin-cli", content)
        self.assertIn("uv build", content)

    def test_missing_dependency_guidance_without_traceback(self):
        env = dict(os.environ)
        env["PYTHONPATH"] = str(CLIENT_ROOT / "tools" / "admin-cli" / "src")
        # Run without installed requests dependency
        cmd = [sys.executable, "-m", "camellia_remote_admin", "users", "--help"]
        proc = subprocess.run(cmd, env=env, capture_output=True, text=True)

        self.assertEqual(proc.returncode, 2, f"Expected exit code 2, got {proc.returncode}")
        self.assertIn("CLI dependencies are missing", proc.stderr)
        self.assertIn("uv sync --locked", proc.stderr)
        self.assertNotIn("Traceback (most recent call last)", proc.stderr)


class WindowsLogonZeroizationContractTests(unittest.TestCase):
    """CRED-003 contract tests."""

    def test_create_process_with_logon_uses_zeroizing_wide_string(self):
        windows_rs = CLIENT_ROOT / "src" / "platform" / "windows.rs"
        content = windows_rs.read_text(encoding="utf-8")

        self.assertIn(
            "zeroize::Zeroizing::new(wide_string(pwd))",
            content,
            "create_process_with_logon must wrap password wide string in Zeroizing",
        )

    def test_portable_service_zeroizes_logon_password(self):
        service_rs = CLIENT_ROOT / "src" / "server" / "portable_service.rs"
        content = service_rs.read_text(encoding="utf-8")

        self.assertIn(
            "password.zeroize();",
            content,
            "StartPara::Logon handler must zeroize password immediately after process launch",
        )

    def test_io_loop_zeroizes_password_and_cleans_message(self):
        io_loop_rs = CLIENT_ROOT / "src" / "client" / "io_loop.rs"
        content = io_loop_rs.read_text(encoding="utf-8")

        match = re.search(
            r"Data::ElevateWithLogon\(username, mut password\).*?password\.zeroize\(\);",
            content,
            re.DOTALL,
        )
        self.assertIsNotNone(match, "Data::ElevateWithLogon must zeroize password upon sending")

    def test_flutter_elevation_dialog_clears_controllers_on_submit_and_finally(self):
        dialog_dart = CLIENT_ROOT / "flutter" / "lib" / "common" / "widgets" / "dialog.dart"
        content = dialog_dart.read_text(encoding="utf-8")

        self.assertIn(
            "pwdController.clear();",
            content,
            "showRequestElevationDialog must clear pwdController before dispatch and upon dispose",
        )

    def test_web_bridge_rejects_session_elevate_with_logon_without_serializing(self):
        bridge_dart = CLIENT_ROOT / "flutter" / "lib" / "web" / "bridge.dart"
        content = bridge_dart.read_text(encoding="utf-8")

        self.assertIn(
            'throw UnsupportedError("Windows Logon elevation is not supported in Web Client");',
            content,
            "Web bridge must throw UnsupportedError rather than encoding password to JSON",
        )
        self.assertNotIn(
            "elevate_with_logon",
            content,
            "Web bridge must not serialize elevate_with_logon messages",
        )


class CredentialRetentionBoundingContractTests(unittest.TestCase):
    """CRED-006 contract tests."""

    def test_tab_pages_redact_transient_credentials(self):
        pages = [
            CLIENT_ROOT / "flutter" / "lib" / "desktop" / "pages" / "file_manager_tab_page.dart",
            CLIENT_ROOT / "flutter" / "lib" / "desktop" / "pages" / "port_forward_tab_page.dart",
            CLIENT_ROOT / "flutter" / "lib" / "desktop" / "pages" / "remote_tab_page.dart",
            CLIENT_ROOT / "flutter" / "lib" / "desktop" / "pages" / "terminal_tab_page.dart",
            CLIENT_ROOT / "flutter" / "lib" / "desktop" / "pages" / "view_camera_tab_page.dart",
        ]

        for page in pages:
            content = page.read_text(encoding="utf-8")
            self.assertIn(
                "params['password'] = null;",
                content,
                f"{page.name} must nullify params['password'] after consumption",
            )

    def test_peer_model_provides_safe_json_without_credentials(self):
        peer_model = CLIENT_ROOT / "flutter" / "lib" / "models" / "peer_model.dart"
        content = peer_model.read_text(encoding="utf-8")

        self.assertIn("toSafeJson()", content, "Peer must define toSafeJson()")
        self.assertIn("res.remove('hash');", content)
        self.assertIn("res.remove('password');", content)


if __name__ == "__main__":
    unittest.main()
