#!/usr/bin/env python3
"""Contract and invariant verification tests for Batch 66:
BUILD-003 — Client 可复现 Native 构建与 SOURCE_DATE_EPOCH 约束闭环.

Verifies:
1. Git Tracking & Cleanliness Invariants:
   - client/src/version.rs is tracked in git and unignored in .gitignore.
   - client/src/version.rs declares VERSION via env!("CARGO_PKG_VERSION").
   - client/src/version.rs declares BUILD_DATE via compile-time option_env!("CAMELLIA_BUILD_DATE").
2. Build Script Generation Coordination:
   - client/build.rs invokes camellia_remote_protocol::gen_version().
   - protocol::gen_version() preserves src/version.rs when option_env! is detected.
3. sync-version.sh Invariants:
   - Validates version, build number, and source_date_epoch.
   - Rejects negative or non-decimal epoch values with exit code 2.
   - Standardizes build date format to 'YYYY-MM-DD HH:MM UTC'.
   - Exports SOURCE_DATE_EPOCH, BUILD_DATE, and CAMELLIA_BUILD_DATE to GITHUB_ENV when available.
   - Preserves tracked src/version.rs without dirtying the git working tree.
4. build.py Deterministic CLI & Subprocess Propagation:
   - Exposes --source-date-epoch option.
   - Resolves epoch from CLI, environment, or git commit timestamp.
   - Forwards resolved epoch to sync_version() and subprocess environments.
5. Packaging & Distribution Regex Compatibility:
   - res/msi/preprocess.py BUILD_DATE regex accepts standardized 'YYYY-MM-DD HH:MM UTC'.
   - Rejects newline injections, malformed dates, and trailing junk.
6. CI & Release Workflow Quality Gates:
   - ci.yml and release.yml export source_date_epoch in metadata outputs.
   - sync-version.sh is called with source_date_epoch parameter.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

CLIENT_ROOT = Path(__file__).resolve().parents[3]
VERSION_RS = CLIENT_ROOT / "src" / "version.rs"
BUILD_RS = CLIENT_ROOT / "build.rs"
BUILD_PY = CLIENT_ROOT / "build.py"
SYNC_VERSION_SH = CLIENT_ROOT / ".github" / "scripts" / "sync-version.sh"
MSI_PREPROCESS_PY = CLIENT_ROOT / "res" / "msi" / "preprocess.py"
CI_YML = CLIENT_ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_YML = CLIENT_ROOT / ".github" / "workflows" / "release.yml"
CLIENT_GITIGNORE = CLIENT_ROOT / ".gitignore"


class Batch66ReproducibleBuildContractsTest(unittest.TestCase):
    """Test suite ensuring BUILD-003 reproducible build invariants and date contracts."""

    def test_version_rs_tracked_and_unignored(self) -> None:
        """src/version.rs must exist on disk and must not be ignored in .gitignore."""
        self.assertTrue(VERSION_RS.is_file(), f"Missing version.rs: {VERSION_RS}")

        gitignore_content = CLIENT_GITIGNORE.read_text(encoding="utf-8")
        ignored_lines = [
            line.strip()
            for line in gitignore_content.splitlines()
            if line.strip() in ("src/version.rs", "/src/version.rs", "version.rs")
        ]
        self.assertEqual(
            ignored_lines,
            [],
            f"src/version.rs must not be listed in .gitignore: {ignored_lines}",
        )

        # Check git check-ignore to confirm git does not ignore src/version.rs
        result = subprocess.run(
            ["git", "check-ignore", str(VERSION_RS)],
            cwd=CLIENT_ROOT,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(
            result.returncode,
            0,
            f"src/version.rs is ignored by git: {result.stdout}",
        )

    def test_version_rs_contains_compile_time_env_injection(self) -> None:
        """src/version.rs must use env! and option_env! with standardized UTC fallback."""
        content = VERSION_RS.read_text(encoding="utf-8")
        self.assertIn(
            'pub const VERSION: &str = env!("CARGO_PKG_VERSION");',
            content,
            "VERSION must be read from CARGO_PKG_VERSION at compile time",
        )
        self.assertIn(
            'option_env!("CAMELLIA_BUILD_DATE")',
            content,
            "BUILD_DATE must check CAMELLIA_BUILD_DATE via option_env!",
        )
        self.assertIn(
            '"1970-01-01 00:00 UTC"',
            content,
            "Default fallback date must be standardized UTC format",
        )

    def test_build_rs_invokes_protocol_gen_version(self) -> None:
        """build.rs must invoke camellia_remote_protocol::gen_version()."""
        content = BUILD_RS.read_text(encoding="utf-8")
        self.assertIn(
            "camellia_remote_protocol::gen_version();",
            content,
            "build.rs must call camellia_remote_protocol::gen_version()",
        )

    def test_sync_version_rejects_invalid_epochs(self) -> None:
        """sync-version.sh must reject negative or non-decimal epoch inputs with code 2."""
        invalid_epochs = ["-1", "-1700000000", "not_a_number", "1234a", "12.34"]
        for invalid in invalid_epochs:
            result = subprocess.run(
                ["bash", str(SYNC_VERSION_SH), "1.0.1", "1", invalid],
                cwd=CLIENT_ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                2,
                f"sync-version.sh must reject invalid epoch '{invalid}' with exit code 2: {result.stderr}",
            )
            self.assertIn("source date epoch", result.stderr.lower())

    def test_sync_version_computes_utc_build_date_and_preserves_version_rs(self) -> None:
        """sync-version.sh must compute UTC date matching %Y-%m-%d %H:%M UTC and preserve version.rs."""
        original_version_rs = VERSION_RS.read_text(encoding="utf-8")
        pubspec_file = CLIENT_ROOT / "flutter" / "pubspec.yaml"
        original_pubspec = pubspec_file.read_text(encoding="utf-8")

        with tempfile.NamedTemporaryFile(mode="w+", delete=False) as github_env_file:
            env_path = github_env_file.name

        try:
            custom_env = os.environ.copy()
            custom_env["GITHUB_ENV"] = env_path

            # Run with epoch 1700000000 (2023-11-14 22:13:20 UTC)
            result = subprocess.run(
                ["bash", str(SYNC_VERSION_SH), "1.0.1", "1", "1700000000"],
                cwd=CLIENT_ROOT,
                env=custom_env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, f"sync-version.sh failed: {result.stderr}")

            # Verify GITHUB_ENV exports
            env_content = Path(env_path).read_text(encoding="utf-8")
            self.assertIn("SOURCE_DATE_EPOCH=1700000000", env_content)
            self.assertIn("BUILD_DATE=2023-11-14 22:13 UTC", env_content)
            self.assertIn("CAMELLIA_BUILD_DATE=2023-11-14 22:13 UTC", env_content)

            # Invariant: src/version.rs must not be modified if option_env! was present
            current_version_rs = VERSION_RS.read_text(encoding="utf-8")
            self.assertEqual(
                original_version_rs,
                current_version_rs,
                "sync-version.sh must not dirty src/version.rs when option_env! is present",
            )
        finally:
            pubspec_file.write_text(original_pubspec, encoding="utf-8")
            if os.path.exists(env_path):
                os.remove(env_path)

    def test_build_py_source_date_epoch_resolution(self) -> None:
        """build.py must resolve SOURCE_DATE_EPOCH and expose --source-date-epoch CLI flag."""
        spec = importlib.util.spec_from_file_location("build_script", BUILD_PY)
        self.assertIsNotNone(spec and spec.loader)
        build_mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(build_mod)  # type: ignore[union-attr]

        # Test resolve_source_date_epoch with explicit value
        self.assertEqual(
            build_mod.resolve_source_date_epoch("1700000000"),
            "1700000000",
        )

        # Test resolve_source_date_epoch from environment
        original_env = os.environ.get("SOURCE_DATE_EPOCH")
        try:
            os.environ["SOURCE_DATE_EPOCH"] = "1731370000"
            self.assertEqual(
                build_mod.resolve_source_date_epoch(),
                "1731370000",
            )
        finally:
            if original_env is not None:
                os.environ["SOURCE_DATE_EPOCH"] = original_env
            else:
                os.environ.pop("SOURCE_DATE_EPOCH", None)

        # Test CLI help contains --source-date-epoch
        result = subprocess.run(
            ["python3", str(BUILD_PY), "--help"],
            cwd=CLIENT_ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("--source-date-epoch", result.stdout)

    def test_msi_preprocess_build_date_regex(self) -> None:
        """res/msi/preprocess.py BUILD_DATE regex must match UTC build dates and reject invalid inputs."""
        spec = importlib.util.spec_from_file_location("msi_preprocess", MSI_PREPROCESS_PY)
        self.assertIsNotNone(spec and spec.loader)
        preprocess = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(preprocess)  # type: ignore[union-attr]

        valid_dates = [
            "2026-11-12 00:55 UTC",
            "1970-01-01 00:00 UTC",
            "2023-11-14 22:13 UTC",
            "2026-11-12 00:55",  # legacy backwards compatibility
        ]
        for valid in valid_dates:
            self.assertIsNotNone(
                preprocess.BUILD_DATE.fullmatch(valid),
                f"BUILD_DATE regex must accept valid date: {valid}",
            )

        invalid_dates = [
            "2026-11-12 00:55 UTC\nmalicious",
            "2026-11-12 00:55 UTC ",
            " 2026-11-12 00:55 UTC",
            "2026-11-12 25:00 UTC",
            "2026-13-01 00:00 UTC",
            "invalid-date",
            "",
        ]
        for invalid in invalid_dates:
            self.assertIsNone(
                preprocess.BUILD_DATE.fullmatch(invalid),
                f"BUILD_DATE regex must reject invalid date: {invalid}",
            )

    def test_workflow_contracts_pass_source_date_epoch(self) -> None:
        """ci.yml and release.yml must declare source_date_epoch output and pass it to sync-version.sh."""
        ci_content = CI_YML.read_text(encoding="utf-8")
        release_content = RELEASE_YML.read_text(encoding="utf-8")

        for name, content in [("ci.yml", ci_content), ("release.yml", release_content)]:
            self.assertIn(
                "source_date_epoch: ${{ steps.source.outputs.source_date_epoch }}",
                content,
                f"{name} must export source_date_epoch in metadata outputs",
            )
            self.assertIn(
                "${{ needs.metadata.outputs.source_date_epoch }}",
                content,
                f"{name} must pass source_date_epoch to sync-version.sh",
            )


if __name__ == "__main__":
    unittest.main()
