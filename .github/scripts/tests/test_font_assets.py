import hashlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class FontAssetTests(unittest.TestCase):
    def test_pinned_noto_cjk_fonts_are_unmodified(self) -> None:
        expected = {
            "NotoSansSC-VF.ttf": (
                17_773_132,
                "d68bafcb48a2707749396aa12bbbd833cb70401f3a9a689fd2902c7e0d295964",
            ),
            "NotoSansTC-VF.ttf": (
                11_942_800,
                "ac091cc8cd19e848202afc8fe6d3809b4526c8fdbdb4be82da20c4f785949591",
            ),
        }
        font_directory = ROOT / "flutter" / "assets" / "fonts"
        for name, (size, digest) in expected.items():
            payload = (font_directory / name).read_bytes()
            self.assertEqual(len(payload), size)
            self.assertEqual(hashlib.sha256(payload).hexdigest(), digest)

    def test_font_license_is_distributed(self) -> None:
        license_text = (
            ROOT / "flutter" / "assets" / "fonts" / "OFL.txt"
        ).read_text(encoding="utf-8")
        self.assertIn("SIL OPEN FONT LICENSE Version 1.1", license_text)

        # LEGAL-002: Verify bundled legal compliance assets in flutter/assets/legal/
        legal_dir = ROOT / "flutter" / "assets" / "legal"
        self.assertTrue((legal_dir / "OFL.txt").is_file(), "OFL.txt missing in assets/legal")
        self.assertTrue((legal_dir / "LICENSE").is_file(), "LICENSE missing in assets/legal")
        self.assertTrue((legal_dir / "NOTICE").is_file(), "NOTICE missing in assets/legal")
        self.assertTrue((legal_dir / "SOURCE_PROVENANCE.json").is_file(), "SOURCE_PROVENANCE missing in assets/legal")

        # Verify pubspec.yaml includes legal assets
        pubspec_text = (ROOT / "flutter" / "pubspec.yaml").read_text(encoding="utf-8")
        self.assertIn("- assets/legal/", pubspec_text, "assets/legal/ must be declared in pubspec.yaml")
        self.assertIn("- assets/fonts/OFL.txt", pubspec_text, "assets/fonts/OFL.txt must be declared in pubspec.yaml")


if __name__ == "__main__":
    unittest.main()
