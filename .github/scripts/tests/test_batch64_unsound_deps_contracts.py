#!/usr/bin/env python3
"""Contract and invariant verification tests for Batch 64:
DEP-001 — Client 保留两个未修复的 unsound 依赖告警 (glib 0.18.5 & atty 0.2.14).

Verifies:
1. Cargo.lock invariants:
   - atty is completely absent from Cargo.lock.
   - glib 0.18.5 is patched to local audited path and has no crates.io registry source.
   - obsolete bindgen 0.59.2 and clap 2.34.0 / ansi_term 0.12.1 are absent.
2. Cargo.toml invariants:
   - libs/glib, libs/magnum-opus, libs/hwcodec are excluded from workspace members.
   - [patch.crates-io] patches glib to libs/glib.
   - [patch."..."] patches magnum-opus and hwcodec to local in-tree paths.
3. Cargo audit policy invariants:
   - .github/config/cargo-audit-policy.json has valid schema and review date >= 2026-11-11.
   - Zero unsound advisory exemptions remain across all exception groups.
   - No atty (RUSTSEC-2021-0145 / RUSTSEC-2024-0375) or glib (RUSTSEC-2024-0429) warnings.
4. Dependency risk register invariants:
   - docs/dependency-risk-register.md documents DEP-001 remediation with review date 2026-11-11.
5. In-tree patch fixes:
   - libs/glib/src/variant_iter.rs contains upstream fix for RUSTSEC-2024-0429.
   - libs/magnum-opus/Cargo.toml and libs/hwcodec/Cargo.toml specify bindgen = "0.71".
6. Policy auditor invocation:
   - audit_cargo_dependencies.py --policy-only passes cleanly.
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

CLIENT_ROOT = Path(__file__).resolve().parents[3]
CARGO_LOCK = CLIENT_ROOT / "Cargo.lock"
CARGO_TOML = CLIENT_ROOT / "Cargo.toml"
POLICY_JSON = CLIENT_ROOT / ".github" / "config" / "cargo-audit-policy.json"
RISK_REGISTER = CLIENT_ROOT / "docs" / "dependency-risk-register.md"
AUDIT_SCRIPT = CLIENT_ROOT / ".github" / "scripts" / "audit_cargo_dependencies.py"


class Batch64UnsoundDepsContractsTest(unittest.TestCase):
    """Test suite ensuring DEP-001 unsound dependencies are completely eliminated."""

    def test_cargo_lock_purges_atty_and_obsolete_bindgen(self) -> None:
        """Cargo.lock must not contain atty or obsolete bindgen 0.59.2."""
        self.assertTrue(CARGO_LOCK.is_file(), f"Cargo.lock not found at {CARGO_LOCK}")
        lock_content = CARGO_LOCK.read_text(encoding="utf-8")

        # Parse package blocks: [[package]]\nname = "..."\nversion = "..."
        package_pattern = re.compile(
            r'\[\[package\]\]\s+name = "([^"]+)"\s+version = "([^"]+)"',
            re.MULTILINE,
        )
        packages = package_pattern.findall(lock_content)
        package_names = [name for name, _ in packages]

        # 1. atty must be completely gone
        self.assertNotIn(
            "atty",
            package_names,
            "atty must be completely absent from Cargo.lock",
        )

        # 2. obsolete clap 2.x and ansi_term must be absent
        self.assertNotIn(
            "ansi_term",
            package_names,
            "ansi_term must be absent from Cargo.lock",
        )

        # 3. bindgen 0.59.2 (which pulled atty via clap 2) must be absent
        bindgen_versions = [ver for name, ver in packages if name == "bindgen"]
        self.assertTrue(bindgen_versions, "bindgen expected in Cargo.lock")
        for ver in bindgen_versions:
            self.assertFalse(
                ver.startswith("0.59"),
                f"Obsolete bindgen 0.59.x found in Cargo.lock: {ver}",
            )
            major, minor = (int(x) for x in ver.split(".")[:2])
            self.assertGreaterEqual(
                (major, minor),
                (0, 60),
                f"bindgen must be >= 0.60 to avoid atty dependency, but found {ver}",
            )

    def test_cargo_lock_glib_018_is_patched_locally_without_crates_io_source(self) -> None:
        """glib 0.18.5 in Cargo.lock must not have a crates.io registry source."""
        lock_content = CARGO_LOCK.read_text(encoding="utf-8")

        # Match package blocks
        blocks = re.split(r'\n(?=\[\[package\]\])', lock_content)
        glib_018_found = False
        for block in blocks:
            if 'name = "glib"' in block and 'version = "0.18.5"' in block:
                glib_018_found = True
                self.assertNotIn(
                    "source = ",
                    block,
                    f"glib 0.18.5 must not have a crates.io registry source (must be in-tree patched):\n{block}",
                )

        self.assertTrue(glib_018_found, "glib 0.18.5 package block not found in Cargo.lock")

    def test_cargo_toml_patch_and_workspace_invariants(self) -> None:
        """Cargo.toml must configure patch tables and workspace exclusions."""
        self.assertTrue(CARGO_TOML.is_file(), f"Cargo.toml not found at {CARGO_TOML}")
        content = CARGO_TOML.read_text(encoding="utf-8")

        # Exclusions
        self.assertIn('"libs/glib"', content, "libs/glib must be in workspace.exclude")
        self.assertIn('"libs/magnum-opus"', content, "libs/magnum-opus must be in workspace.exclude")
        self.assertIn('"libs/hwcodec"', content, "libs/hwcodec must be in workspace.exclude")

        # Patches
        self.assertIn(
            '[patch.crates-io]',
            content,
            "[patch.crates-io] section must exist",
        )
        self.assertIn(
            'glib = { path = "libs/glib" }',
            content,
            "glib patch in [patch.crates-io] must point to libs/glib",
        )
        self.assertIn(
            '[patch."https://github.com/rustdesk-org/magnum-opus"]',
            content,
            "magnum-opus git patch section must exist",
        )
        self.assertIn(
            '[patch."https://github.com/rustdesk-org/hwcodec"]',
            content,
            "hwcodec git patch section must exist",
        )

    def test_cargo_audit_policy_has_zero_unsound_exceptions(self) -> None:
        """cargo-audit-policy.json must contain zero 'unsound' warnings and valid dates."""
        self.assertTrue(POLICY_JSON.is_file(), f"Policy not found at {POLICY_JSON}")
        policy = json.loads(POLICY_JSON.read_text(encoding="utf-8"))

        self.assertEqual(policy.get("schema_version"), 1)
        self.assertGreaterEqual(policy.get("reviewed_on", ""), "2026-11-11")

        all_warnings = []
        for group in policy.get("exception_groups", []):
            self.assertGreater(
                group.get("expires_on", ""),
                policy.get("reviewed_on", ""),
                f"Group {group.get('id')} expires_on must be strictly after reviewed_on",
            )
            for warn in group.get("warnings", []):
                all_warnings.append((group.get("id"), warn))

        # Check for unsound warnings
        unsound_warnings = [
            (gid, w) for gid, w in all_warnings if w.get("category") == "unsound"
        ]
        self.assertEqual(
            unsound_warnings,
            [],
            f"Zero unsound warnings permitted in audit policy, found: {unsound_warnings}",
        )

        # Check for atty or glib specifically
        forbidden_packages = {"atty", "ansi_term"}
        found_forbidden = [
            (gid, w) for gid, w in all_warnings if w.get("package") in forbidden_packages
        ]
        self.assertEqual(
            found_forbidden,
            [],
            f"Forbidden packages found in audit policy: {found_forbidden}",
        )

        forbidden_advisories = {
            "RUSTSEC-2024-0429",  # glib unsound
            "RUSTSEC-2021-0145",  # atty unsound
            "RUSTSEC-2024-0375",  # atty unmaintained
            "RUSTSEC-2021-0139",  # ansi_term unmaintained
        }
        found_advisories = [
            (gid, w) for gid, w in all_warnings if w.get("advisory_id") in forbidden_advisories
        ]
        self.assertEqual(
            found_advisories,
            [],
            f"Forbidden advisories found in audit policy: {found_advisories}",
        )

        # Check total remaining unmaintained warning budget: exactly 24 (down from 28)
        self.assertEqual(
            len(all_warnings),
            24,
            f"Expected exactly 24 approved warnings after eliminating 2 unsound and 2 unmaintained warnings, got {len(all_warnings)}",
        )
        group_counts = {
            group["id"]: len(group.get("warnings", []))
            for group in policy.get("exception_groups", [])
        }
        self.assertEqual(
            group_counts.get("gtk3-stack-migration"),
            9,
            "gtk3-stack-migration must have exactly 9 warnings",
        )
        self.assertEqual(
            group_counts.get("inherited-transitive-modernization"),
            15,
            "inherited-transitive-modernization must have exactly 15 warnings",
        )

    def test_docs_dependency_risk_register_reflects_batch64_remediation(self) -> None:
        """docs/dependency-risk-register.md must be updated with Batch 64 evidence."""
        self.assertTrue(RISK_REGISTER.is_file(), f"Risk register not found at {RISK_REGISTER}")
        content = RISK_REGISTER.read_text(encoding="utf-8")

        self.assertIn("Review date: 2026-11-11", content)
        self.assertIn("Batch 64", content)
        self.assertIn("DEP-001", content)
        self.assertIn("RUSTSEC-2024-0429", content)
        self.assertIn("RUSTSEC-2021-0145", content)

    def test_in_tree_glib_patch_fixes_variant_str_iter_mutability(self) -> None:
        """libs/glib/src/variant_iter.rs must contain the PR 1343 / RUSTSEC-2024-0429 fix."""
        variant_iter = CLIENT_ROOT / "libs" / "glib" / "src" / "variant_iter.rs"
        self.assertTrue(variant_iter.is_file(), f"variant_iter.rs not found at {variant_iter}")
        content = variant_iter.read_text(encoding="utf-8")

        # The fix replaces let mut p: *const libc::c_char with *mut libc::c_char and &mut p
        self.assertIn(
            "let mut p: *mut libc::c_char = std::ptr::null_mut();",
            content,
            "variant_iter.rs must declare mutable pointer for g_variant_iter_next",
        )
        self.assertIn(
            "&mut p",
            content,
            "variant_iter.rs must pass &mut p to ffi::g_variant_iter_next",
        )

    def test_in_tree_codecs_use_modern_bindgen(self) -> None:
        """Vendored magnum-opus and hwcodec must specify modern bindgen >= 0.70."""
        for name in ["magnum-opus", "hwcodec"]:
            cargo_file = CLIENT_ROOT / "libs" / name / "Cargo.toml"
            self.assertTrue(cargo_file.is_file(), f"{cargo_file} must exist")
            content = cargo_file.read_text(encoding="utf-8")
            self.assertIn(
                'bindgen = "0.71"',
                content,
                f"{name}/Cargo.toml must pin bindgen = 0.71",
            )
            self.assertNotIn(
                '0.59',
                content,
                f"{name}/Cargo.toml must not reference bindgen 0.59",
            )

    def test_policy_only_script_passes_cleanly(self) -> None:
        """audit_cargo_dependencies.py --policy-only must return 0."""
        res = subprocess.run(
            [sys.executable, str(AUDIT_SCRIPT), "--policy-only"],
            cwd=str(CLIENT_ROOT),
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            res.returncode,
            0,
            f"audit_cargo_dependencies.py failed: {res.stdout}\n{res.stderr}",
        )
        self.assertIn("Dependency policy structure and deadlines are valid", res.stdout)


if __name__ == "__main__":
    unittest.main()
