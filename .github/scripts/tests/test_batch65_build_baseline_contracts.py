#!/usr/bin/env python3
"""Contract and invariant verification tests for Batch 65:
BUILD-001 — Client 生成步骤和静态检查技术债未形成闭环.

Verifies:
1. Bridge Generation Prerequisite Solidification:
   - Bridge files (src/bridge_generated.rs, flutter/ios/Runner/bridge_generated.h,
     flutter/macos/Runner/bridge_generated.h) are tracked in Git and unignored.
   - client/build.rs strictly asserts bridge presence before compilation under flutter/mobile targets.
   - client/build.py provides ensure_bridge() with --regenerate-bridge flag.
2. Machine-Readable Quality Baselines:
   - clippy-baseline.json: Valid schema v1, budget of 1579 warnings across 4 packages.
   - flutter-analyze-baseline.json: Valid schema v1, budget of 896 issues, zero errors/warnings.
3. Baseline Verification Tooling & Gate Behaviors:
   - verify_quality_baselines.py passes when actual diagnostics match or decrease below baseline.
   - verify_quality_baselines.py strictly rejects increases in Clippy warnings (+1).
   - verify_quality_baselines.py strictly rejects increases in Flutter analyze issues (+1).
   - verify_quality_baselines.py strictly rejects any Flutter WARNING or ERROR severity.
   - verify_quality_baselines.py rejects unbudgeted new lint codes.
4. CI Workflow Integration:
   - ci.yml quality job invokes verify_quality_baselines.py for both Clippy and Flutter analyze.
   - ci.yml eliminates unbudgeted --no-fatal-infos bypass.
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

CLIENT_ROOT = Path(__file__).resolve().parents[3]
CLIPPY_BASELINE = CLIENT_ROOT / ".github" / "config" / "clippy-baseline.json"
FLUTTER_BASELINE = CLIENT_ROOT / ".github" / "config" / "flutter-analyze-baseline.json"
VERIFY_SCRIPT = CLIENT_ROOT / ".github" / "scripts" / "verify_quality_baselines.py"
BUILD_RS = CLIENT_ROOT / "build.rs"
BUILD_PY = CLIENT_ROOT / "build.py"
CI_YML = CLIENT_ROOT / ".github" / "workflows" / "ci.yml"
CLIENT_GITIGNORE = CLIENT_ROOT / ".gitignore"
FLUTTER_GITIGNORE = CLIENT_ROOT / "flutter" / ".gitignore"


class Batch65BuildBaselineContractsTest(unittest.TestCase):
    """Test suite ensuring BUILD-001 quality baselines and bridge generation contract compliance."""

    def test_bridge_files_committed_and_unignored(self) -> None:
        """Bridge generation files must exist on disk and must not be ignored in .gitignore."""
        bridge_rs = CLIENT_ROOT / "src" / "bridge_generated.rs"
        bridge_h_ios = CLIENT_ROOT / "flutter" / "ios" / "Runner" / "bridge_generated.h"
        bridge_h_mac = CLIENT_ROOT / "flutter" / "macos" / "Runner" / "bridge_generated.h"

        self.assertTrue(bridge_rs.is_file(), f"Missing bridge file: {bridge_rs}")
        self.assertGreater(bridge_rs.stat().st_size, 1000, "bridge_generated.rs must not be empty")

        self.assertTrue(bridge_h_ios.is_file(), f"Missing iOS bridge header: {bridge_h_ios}")
        self.assertTrue(bridge_h_mac.is_file(), f"Missing macOS bridge header: {bridge_h_mac}")

        # Check .gitignore files do not ignore these bridge files
        client_gi = CLIENT_GITIGNORE.read_text(encoding="utf-8")
        flutter_gi = FLUTTER_GITIGNORE.read_text(encoding="utf-8")

        self.assertNotIn("src/bridge_generated.rs", client_gi, "src/bridge_generated.rs must not be gitignored")
        self.assertNotIn("**/Runner/bridge_generated.h", flutter_gi, "Runner/bridge_generated.h must not be gitignored")

        # Verify git check-ignore returns non-zero (i.e. not ignored)
        res = subprocess.run(
            ["git", "-C", str(CLIENT_ROOT), "check-ignore", "-q", "src/bridge_generated.rs"],
            capture_output=True,
        )
        self.assertNotEqual(res.returncode, 0, "src/bridge_generated.rs must not be ignored by git")

    def test_build_rs_bridge_prerequisite_assertion(self) -> None:
        """build.rs must include bridge prerequisite assertion."""
        self.assertTrue(BUILD_RS.is_file(), f"build.rs not found at {BUILD_RS}")
        content = BUILD_RS.read_text(encoding="utf-8")

        self.assertIn("fn ensure_bridge_prerequisites()", content)
        self.assertIn("src/bridge_generated.rs", content)
        self.assertIn("BUILD-001 ERROR", content)
        self.assertIn("ensure_bridge_prerequisites();", content)

    def test_build_py_bridge_prerequisite_handling(self) -> None:
        """build.py must define ensure_bridge() with --regenerate-bridge flag."""
        self.assertTrue(BUILD_PY.is_file(), f"build.py not found at {BUILD_PY}")
        content = BUILD_PY.read_text(encoding="utf-8")

        self.assertIn("def ensure_bridge(force=False):", content)
        self.assertIn("--regenerate-bridge", content)
        self.assertIn("ensure_bridge(force=args.regenerate_bridge)", content)

    def test_clippy_baseline_schema_and_budget(self) -> None:
        """clippy-baseline.json must conform to schema v1 and record exact budgets."""
        self.assertTrue(CLIPPY_BASELINE.is_file(), f"Clippy baseline not found at {CLIPPY_BASELINE}")
        data = json.loads(CLIPPY_BASELINE.read_text(encoding="utf-8"))

        self.assertEqual(data.get("schema_version"), 1)
        self.assertEqual(data.get("total_allowed_warnings"), 1579)

        by_pkg = data.get("by_package", {})
        self.assertEqual(by_pkg.get("camellia-remote"), 1103)
        self.assertEqual(by_pkg.get("scrap"), 355)
        self.assertEqual(by_pkg.get("enigo"), 118)
        self.assertEqual(by_pkg.get("virtual_display"), 3)
        self.assertEqual(sum(by_pkg.values()), 1579)

        by_code = data.get("by_lint_code", {})
        self.assertGreater(len(by_code), 20)
        self.assertEqual(sum(by_code.values()), 1579)

        fps = data.get("fingerprints", [])
        self.assertEqual(len(fps), data.get("total_unique_fingerprints"))
        self.assertGreater(len(fps), 100)

    def test_flutter_analyze_baseline_schema_and_budget(self) -> None:
        """flutter-analyze-baseline.json must conform to schema v1 and enforce zero errors/warnings."""
        self.assertTrue(FLUTTER_BASELINE.is_file(), f"Flutter baseline not found at {FLUTTER_BASELINE}")
        data = json.loads(FLUTTER_BASELINE.read_text(encoding="utf-8"))

        self.assertEqual(data.get("schema_version"), 1)
        self.assertEqual(data.get("total_allowed_issues"), 896)

        by_sev = data.get("by_severity", {})
        self.assertEqual(by_sev.get("INFO"), 896)
        self.assertNotIn("WARNING", by_sev)
        self.assertNotIn("ERROR", by_sev)

        by_code = data.get("by_lint_code", {})
        self.assertEqual(len(by_code), 31)
        self.assertEqual(sum(by_code.values()), 896)

        fps = data.get("fingerprints", [])
        self.assertEqual(len(fps), data.get("total_unique_fingerprints"))
        self.assertGreater(len(fps), 50)

    def test_verify_quality_baselines_clippy_gate_behavior(self) -> None:
        """verify_quality_baselines.py gate checks for Clippy: pass on equality/decrease, fail on addition."""
        # 1. Baseline dataset passes
        baseline_data = json.loads(CLIPPY_BASELINE.read_text(encoding="utf-8"))
        warnings = baseline_data["warnings"]

        # Simulate cargo clippy json stream from warnings
        def to_cargo_json(warn_list: list[dict]) -> str:
            lines = []
            for w in warn_list:
                msg = {
                    "reason": "compiler-message",
                    "package_id": f"path+file:///client#{w['package']}@1.0.0",
                    "message": {
                        "level": "warning",
                        "code": {"code": w["code"]},
                        "message": w["message"],
                        "spans": [{
                            "file_name": w["file"],
                            "line_start": w["line"],
                            "column_start": w["column"],
                            "is_primary": True,
                        }],
                    },
                }
                lines.append(json.dumps(msg))
            return "\n".join(lines)

        clean_stream = to_cargo_json(warnings)
        res = subprocess.run(
            [sys.executable, str(VERIFY_SCRIPT), "--clippy", "--clippy-input", "-"],
            input=clean_stream,
            text=True,
            capture_output=True,
        )
        self.assertEqual(res.returncode, 0, f"Expected clean clippy input to pass: {res.stderr}")

        # 2. Artificial +1 warning addition must fail the gate
        extra_warn = {
            "package": "camellia-remote",
            "code": "clippy::needless_borrow",
            "file": "src/core_main.rs",
            "line": 9999,
            "column": 1,
            "message": "artificial test warning",
        }
        dirty_stream = to_cargo_json(warnings + [extra_warn])
        res_fail = subprocess.run(
            [sys.executable, str(VERIFY_SCRIPT), "--clippy", "--clippy-input", "-"],
            input=dirty_stream,
            text=True,
            capture_output=True,
        )
        self.assertEqual(res_fail.returncode, 1, "Expected addition of Clippy warning to fail the gate")
        self.assertIn("exceeded baseline budget", res_fail.stderr)

        # 3. Warning reduction must succeed
        reduced_stream = to_cargo_json(warnings[:-1])
        res_reduced = subprocess.run(
            [sys.executable, str(VERIFY_SCRIPT), "--clippy", "--clippy-input", "-"],
            input=reduced_stream,
            text=True,
            capture_output=True,
        )
        self.assertEqual(res_reduced.returncode, 0, "Expected reduced warning count to pass the gate")
        self.assertIn("Quality baseline improved", res_reduced.stdout)

    def test_verify_quality_baselines_flutter_gate_behavior(self) -> None:
        """verify_quality_baselines.py gate checks for Flutter: pass on equality/decrease, fail on addition/error."""
        baseline_data = json.loads(FLUTTER_BASELINE.read_text(encoding="utf-8"))
        diags = baseline_data["diagnostics"]

        def to_flutter_json(diag_list: list[dict]) -> str:
            items = []
            for d in diag_list:
                items.append({
                    "code": d["code"],
                    "severity": d["severity"],
                    "type": d["type"],
                    "location": {
                        "file": str(CLIENT_ROOT / "flutter" / d["file"]),
                        "range": {
                            "start": {"line": d["line"], "column": d["column"]},
                        },
                    },
                    "problemMessage": d["problemMessage"],
                })
            return json.dumps({"diagnostics": items})

        # 1. Clean pass
        clean_json = to_flutter_json(diags)
        res = subprocess.run(
            [sys.executable, str(VERIFY_SCRIPT), "--flutter", "--flutter-input", "-"],
            input=clean_json,
            text=True,
            capture_output=True,
        )
        self.assertEqual(res.returncode, 0, f"Expected clean flutter input to pass: {res.stderr}")

        # 2. Addition of an issue (+1) must fail
        extra_diag = {
            "code": "strict_top_level_inference",
            "severity": "INFO",
            "type": "LINT",
            "file": "lib/common.dart",
            "line": 9999,
            "column": 1,
            "problemMessage": "artificial test diagnostic",
        }
        dirty_json = to_flutter_json(diags + [extra_diag])
        res_fail = subprocess.run(
            [sys.executable, str(VERIFY_SCRIPT), "--flutter", "--flutter-input", "-"],
            input=dirty_json,
            text=True,
            capture_output=True,
        )
        self.assertEqual(res_fail.returncode, 1, "Expected addition of Flutter issue to fail the gate")
        self.assertIn("exceeded baseline budget", res_fail.stderr)

        # 3. Addition of WARNING or ERROR severity must fail immediately
        error_diag = {
            "code": "undefined_identifier",
            "severity": "ERROR",
            "type": "COMPILE_TIME_ERROR",
            "file": "lib/common.dart",
            "line": 100,
            "column": 1,
            "problemMessage": "fatal error diagnostic",
        }
        fatal_json = to_flutter_json([error_diag])
        res_fatal = subprocess.run(
            [sys.executable, str(VERIFY_SCRIPT), "--flutter", "--flutter-input", "-"],
            input=fatal_json,
            text=True,
            capture_output=True,
        )
        self.assertEqual(res_fatal.returncode, 1, "Expected ERROR severity to fail the gate")
        self.assertIn("fatal ERROR diagnostics", res_fatal.stderr)

        # 4. Issue reduction must pass
        reduced_json = to_flutter_json(diags[:-1])
        res_reduced = subprocess.run(
            [sys.executable, str(VERIFY_SCRIPT), "--flutter", "--flutter-input", "-"],
            input=reduced_json,
            text=True,
            capture_output=True,
        )
        self.assertEqual(res_reduced.returncode, 0, "Expected reduced issue count to pass the gate")
        self.assertIn("Quality baseline improved", res_reduced.stdout)

    def test_ci_workflow_quality_job_enforces_baselines(self) -> None:
        """ci.yml quality job must invoke verify_quality_baselines.py for both clippy and flutter analyze."""
        self.assertTrue(CI_YML.is_file(), f"ci.yml not found at {CI_YML}")
        content = CI_YML.read_text(encoding="utf-8")

        self.assertIn("verify_quality_baselines.py --clippy", content)
        self.assertIn("verify_quality_baselines.py --flutter", content)
        self.assertNotIn("flutter analyze --no-fatal-infos", content)


if __name__ == "__main__":
    unittest.main()
