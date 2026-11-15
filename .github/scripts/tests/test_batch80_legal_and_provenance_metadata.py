#!/usr/bin/env python3
"""Contract and static analysis tests for Batch 79:
- LEGAL-002: Distribution artifacts compliance bundle and provenance tracking
- LEGAL-003: Client workspace and duplicated components license metadata
"""

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
CLIENT_ROOT = REPO_ROOT


class TestBatch79LegalAndProvenanceMetadata(unittest.TestCase):
    def test_legal003_workspace_manifests_license_metadata(self):
        """LEGAL-003: All internal workspace crates must declare AGPL-3.0-only and repository metadata."""
        workspace_crates = [
            "libs/clipboard/Cargo.toml",
            "libs/portable/Cargo.toml",
            "libs/remote_printer/Cargo.toml",
            "libs/virtual_display/Cargo.toml",
            "libs/virtual_display/dylib/Cargo.toml",
            "libs/libxdo-sys-stub/Cargo.toml",
            "libs/hwcodec/Cargo.toml",
        ]

        for rel_path in workspace_crates:
            manifest_path = CLIENT_ROOT / rel_path
            self.assertTrue(manifest_path.is_file(), f"Manifest {rel_path} must exist")
            content = manifest_path.read_text(encoding="utf-8")
            self.assertIn(
                'license = "AGPL-3.0-only"',
                content,
                f"LEGAL-003 violation: {rel_path} must declare license = \"AGPL-3.0-only\"",
            )
            self.assertIn(
                'repository = "https://github.com/camellia-nexus/remote-client"',
                content,
                f"LEGAL-003 violation: {rel_path} must declare repository URL",
            )

    def test_legal003_permissive_crates_license_texts(self):
        """LEGAL-003: Third-party permissive crates in libs/ must retain independent license text."""
        scrap_license = CLIENT_ROOT / "libs" / "scrap" / "LICENSE"
        self.assertTrue(scrap_license.is_file(), "libs/scrap/LICENSE must exist")
        content = scrap_license.read_text(encoding="utf-8")
        self.assertIn("MIT License", content)
        self.assertIn("Ram <quadrupleslap@gmail.com>", content)

        enigo_license = CLIENT_ROOT / "libs" / "enigo" / "LICENSE"
        self.assertTrue(enigo_license.is_file(), "libs/enigo/LICENSE must exist")
        enigo_content = enigo_license.read_text(encoding="utf-8")
        self.assertIn("MIT License", enigo_content)

    def test_legal003_notice_component_mapping(self):
        """LEGAL-003: Client NOTICE must document workspace and third-party permissive components."""
        notice_path = CLIENT_ROOT / "NOTICE"
        self.assertTrue(notice_path.is_file(), "client/NOTICE must exist")
        content = notice_path.read_text(encoding="utf-8")
        self.assertIn("Workspace Components Licensing & Attribution", content)
        self.assertIn("AGPL-3.0-only Core and Platform Integrations", content)
        self.assertIn("Third-Party Permissive Components", content)

    def test_legal002_flutter_asset_bundle_compliance(self):
        """LEGAL-002: Flutter assets must include legal compliance bundle and pubspec references."""
        legal_dir = CLIENT_ROOT / "flutter" / "assets" / "legal"
        self.assertTrue((legal_dir / "LICENSE").is_file(), "LICENSE must exist in assets/legal")
        self.assertTrue((legal_dir / "NOTICE").is_file(), "NOTICE must exist in assets/legal")
        self.assertTrue((legal_dir / "OFL.txt").is_file(), "OFL.txt must exist in assets/legal")
        self.assertTrue(
            (legal_dir / "SOURCE_PROVENANCE.json").is_file(),
            "SOURCE_PROVENANCE.json must exist in assets/legal",
        )

        pubspec_path = CLIENT_ROOT / "flutter" / "pubspec.yaml"
        content = pubspec_path.read_text(encoding="utf-8")
        self.assertIn("- assets/legal/", content)
        self.assertIn("- assets/fonts/OFL.txt", content)


if __name__ == "__main__":
    unittest.main()
