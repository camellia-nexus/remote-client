#!/usr/bin/env python3
"""Contract and static analysis tests for Batch 57:
- BUILD-015: Advanced Multi-Language CodeQL Matrix & SARIF Security Analysis
"""

import unittest
from pathlib import Path
import yaml

REPO_ROOT = Path(__file__).resolve().parents[3]
CODEQL_YML_PATH = REPO_ROOT / ".github" / "workflows" / "codeql.yml"
CODEQL_CONFIG_PATH = REPO_ROOT / ".github" / "codeql" / "codeql-config.yml"


class TestBatch57CodeQLMultilangContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.codeql_text = CODEQL_YML_PATH.read_text(encoding="utf-8")
        cls.codeql_data = yaml.safe_load(cls.codeql_text)
        cls.config_text = CODEQL_CONFIG_PATH.read_text(encoding="utf-8")
        cls.config_data = yaml.safe_load(cls.config_text)

    # =========================================================================
    # BUILD-015: Workflow Schema & Trigger Invariants
    # =========================================================================

    def test_build015_workflow_exists_and_is_valid_yaml(self):
        """BUILD-015: .github/workflows/codeql.yml must parse cleanly as YAML."""
        self.assertTrue(CODEQL_YML_PATH.is_file(), "codeql.yml must exist")
        self.assertIsInstance(self.codeql_data, dict, "codeql.yml must be a valid YAML mapping")
        self.assertEqual(self.codeql_data.get("name"), "CodeQL Advanced")

    def test_build015_permissions_are_minimal_and_sufficient(self):
        """BUILD-015: CodeQL workflow must declare required security-events and read permissions."""
        permissions = self.codeql_data.get("permissions", {})
        self.assertEqual(permissions.get("security-events"), "write", "security-events must be write")
        self.assertEqual(permissions.get("contents"), "read", "contents must be read")
        self.assertEqual(permissions.get("actions"), "read", "actions must be read")

    def test_build015_concurrency_group_and_cancel_in_progress(self):
        """BUILD-015: Concurrency group must isolate PR runs and cancel obsolete in-progress jobs."""
        concurrency = self.codeql_data.get("concurrency", {})
        self.assertIn("client-codeql-", str(concurrency.get("group")))
        self.assertIn("cancel-in-progress", concurrency)

    # =========================================================================
    # BUILD-015: Multi-Language Matrix Coverage (Closing Gaps)
    # =========================================================================

    def test_build015_all_seven_mandatory_languages_present(self):
        """BUILD-015: Matrix must include actions, c-cpp, java-kotlin, javascript-typescript, python, rust, swift."""
        jobs = self.codeql_data.get("jobs", {})
        analyze_job = jobs.get("analyze", {})
        strategy = analyze_job.get("strategy", {})
        matrix = strategy.get("matrix", {})
        includes = matrix.get("include", [])

        matrix_languages = {item.get("language") for item in includes}
        required_languages = {
            "actions",
            "c-cpp",
            "java-kotlin",
            "javascript-typescript",
            "python",
            "rust",
            "swift",
        }
        self.assertTrue(
            required_languages.issubset(matrix_languages),
            f"Missing required languages: {required_languages - matrix_languages}",
        )

    def test_build015_java_kotlin_coverage_and_configuration(self):
        """BUILD-015: java-kotlin must be covered to scan Android Kotlin and Java native glue."""
        jobs = self.codeql_data.get("jobs", {})
        includes = jobs.get("analyze", {}).get("strategy", {}).get("matrix", {}).get("include", [])
        jk = next((item for item in includes if item.get("language") == "java-kotlin"), None)
        self.assertIsNotNone(jk, "java-kotlin must be present in CodeQL matrix")
        self.assertEqual(jk.get("os"), "ubuntu-24.04")
        self.assertEqual(jk.get("build-mode"), "none")

        # Verify repo actually has Kotlin/Java files to analyze
        kotlin_files = list(REPO_ROOT.glob("flutter/android/**/*.kt"))
        java_files = list(REPO_ROOT.glob("flutter/android/**/*.java"))
        self.assertGreater(len(kotlin_files) + len(java_files), 10, "Expected >10 Kotlin/Java files in repo")

    def test_build015_swift_coverage_and_configuration(self):
        """BUILD-015: swift must be covered on macOS runner to scan Apple native glue."""
        jobs = self.codeql_data.get("jobs", {})
        includes = jobs.get("analyze", {}).get("strategy", {}).get("matrix", {}).get("include", [])
        swift = next((item for item in includes if item.get("language") == "swift"), None)
        self.assertIsNotNone(swift, "swift must be present in CodeQL matrix")
        self.assertEqual(swift.get("os"), "macos-15")
        self.assertEqual(swift.get("build-mode"), "manual")
        self.assertIn("xcodebuild", self.codeql_text)
        self.assertIn("handle_applicationShouldOpenUntitledFile", self.codeql_text)
        self.assertIn("camellia_remote_core_main", self.codeql_text)

        # Verify repo actually has Swift files to analyze
        swift_files = list(REPO_ROOT.glob("flutter/**/*.swift"))
        self.assertGreater(len(swift_files), 5, "Expected >5 Swift files in repo")

    def test_build015_c_cpp_coverage_and_configuration(self):
        """BUILD-015: c-cpp must be covered across all platforms with target-aware AST extraction."""
        jobs = self.codeql_data.get("jobs", {})
        includes = jobs.get("analyze", {}).get("strategy", {}).get("matrix", {}).get("include", [])
        cpp = next((item for item in includes if item.get("language") == "c-cpp"), None)
        self.assertIsNotNone(cpp, "c-cpp must be present in CodeQL matrix")
        self.assertEqual(cpp.get("build-mode"), "none")

        # Verify repo actually has C/C++ files to analyze
        cpp_files = list(REPO_ROOT.glob("flutter/**/*.cc")) + list(REPO_ROOT.glob("flutter/**/*.cpp"))
        self.assertGreater(len(cpp_files), 20, "Expected >20 C/C++ files in repo")

    def test_build015_rust_build_mode(self):
        """BUILD-015: rust uses build-mode: none for direct AST extraction in CodeQL CLI 2.27+."""
        jobs = self.codeql_data.get("jobs", {})
        includes = jobs.get("analyze", {}).get("strategy", {}).get("matrix", {}).get("include", [])
        rust = next((item for item in includes if item.get("language") == "rust"), None)
        self.assertIsNotNone(rust, "rust must be present in CodeQL matrix")
        self.assertEqual(rust.get("build-mode"), "none")

    # =========================================================================
    # BUILD-015: Security Supply Chain & SARIF Integrity
    # =========================================================================

    def test_build015_action_pins_are_immutable_full_shas(self):
        """BUILD-015: All GitHub Actions must use immutable 40-character commit SHAs."""
        import re
        uses_matches = re.findall(r"uses:\s+([^\s]+)", self.codeql_text)
        for action_ref in uses_matches:
            if action_ref.startswith("./"):
                continue
            parts = action_ref.split("@")
            self.assertEqual(len(parts), 2, f"Action reference must specify @SHA: {action_ref}")
            action_name, sha = parts
            self.assertEqual(len(sha), 40, f"Action {action_name} must use full 40-char SHA: {sha}")

    def test_build015_sarif_category_per_matrix_language(self):
        """BUILD-015: CodeQL analyze step must publish SARIF with explicit category per language."""
        self.assertIn(
            'category: "/language:${{ matrix.language }}"',
            self.codeql_text,
            "SARIF category must be specified as /language:${{ matrix.language }}",
        )

    def test_build015_codeql_config_file_exists_and_scopes_paths(self):
        """BUILD-015: .github/codeql/codeql-config.yml must scope paths and ignore generated bridge files."""
        self.assertTrue(CODEQL_CONFIG_PATH.is_file(), "codeql-config.yml must exist")
        self.assertIn("paths", self.config_data)
        self.assertIn("paths-ignore", self.config_data)

        paths_ignore = self.config_data["paths-ignore"]
        self.assertTrue(any("bridge_generated" in p for p in paths_ignore), "Must ignore bridge_generated")
        self.assertTrue(any("generated_bridge" in p for p in paths_ignore), "Must ignore generated_bridge")


if __name__ == "__main__":
    unittest.main()
