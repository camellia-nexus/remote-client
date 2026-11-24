import argparse
import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest
import unittest.mock

MODULE_PATH = Path(__file__).resolve().parents[3] / "res" / "msi" / "preprocess.py"
SPEC = importlib.util.spec_from_file_location("msi_preprocess", MODULE_PATH)
preprocess = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(preprocess)


class MsiPreprocessTests(unittest.TestCase):
    def test_tag_generation_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "Package"
            package.mkdir()
            target = package / "fixture.wxs"
            target.write_text(
                "before\n<!-- start -->\nstale\n<!-- end -->\nafter\n",
                encoding="utf-8",
            )

            def render(lines: list[str], start: int) -> None:
                lines.insert(start + 1, "generated\n")

            with unittest.mock.patch.object(preprocess, "PACKAGE_DIR", package):
                for _ in range(2):
                    preprocess.gen_content_between_tags(
                        "Package/fixture.wxs", "<!-- start -->", "<!-- end -->", render
                    )
            self.assertEqual(
                target.read_text(encoding="utf-8"),
                "before\n<!-- start -->\ngenerated\n<!-- end -->\nafter\n",
            )

    def test_generated_component_guids_are_stable_and_paths_are_escaped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            distribution = Path(directory)
            (distribution / "nested").mkdir()
            (distribution / "nested" / "a&b.dll").write_bytes(b"fixture")
            first = ["start\n", "end\n"]
            second = ["start\n", "end\n"]
            preprocess.insert_components_between_tags(
                first, 0, "Camellia Remote", "camellia-remote", distribution
            )
            preprocess.insert_components_between_tags(
                second, 0, "Camellia Remote", "camellia-remote", distribution
            )
            self.assertEqual(first, second)
            self.assertIn("a&amp;b.dll", "".join(first))

    def test_product_and_version_inputs_are_strict(self) -> None:
        self.assertEqual(preprocess.stable_semver("1.2.3"), ("1", "2", "3"))
        for invalid in ["1.2.3suffix", "01.2.3", "1.2", "1.2.3.4"]:
            self.assertIsNone(preprocess.stable_semver(invalid))
        self.assertEqual(
            preprocess.distribution_directory("arm64"),
            preprocess.ARM64_DISTRIBUTION_DIRECTORY,
        )
        self.assertEqual(
            preprocess.distribution_directory("x64"),
            preprocess.X64_DISTRIBUTION_DIRECTORY,
        )
        with self.assertRaisesRegex(ValueError, "unsupported Windows architecture"):
            preprocess.distribution_directory("../x64")
        self.assertIsNotNone(preprocess.PRODUCT_TEXT.fullmatch("Camellia Remote"))
        for invalid in ['Bad "Name"', "Bad<Name", "Bad&Name", "line\nbreak"]:
            self.assertIsNone(preprocess.PRODUCT_TEXT.fullmatch(invalid))

    def test_distribution_tree_rejects_symbolic_links(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            distribution = Path(directory)
            target = distribution / "target.dll"
            target.write_bytes(b"fixture")
            (distribution / "link.dll").symlink_to(target)
            with self.assertRaisesRegex(ValueError, "symbolic link"):
                preprocess.insert_components_between_tags(
                    ["start\n", "end\n"],
                    0,
                    "Camellia Remote",
                    "camellia-remote",
                    distribution,
                )

    def test_distribution_executable_must_be_a_regular_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(version="1.2.3", revision_version=1)
            with redirect_stdout(io.StringIO()):
                self.assertFalse(preprocess.init_global_vars(Path(directory), args))

    def test_shared_wix_variables_require_the_shared_include(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            fragment = package / "Fragments" / "Upgrades.wxs"
            fragment.parent.mkdir()
            fragment.write_text(
                '<Wix><Fragment><Upgrade Id="$(var.UpgradeCode)" /></Fragment></Wix>\n',
                encoding="utf-8",
            )
            with unittest.mock.patch.object(preprocess, "PACKAGE_DIR", package):
                with self.assertRaisesRegex(ValueError, "Upgrades.wxs.*UpgradeCode"):
                    preprocess.validate_shared_preprocessor_contract()
                fragment.write_text(
                    '<Wix><?include ../Includes.wxi?><Fragment>'
                    '<Upgrade Id="$(var.UpgradeCode)" /></Fragment></Wix>\n',
                    encoding="utf-8",
                )
                self.assertTrue(preprocess.validate_shared_preprocessor_contract())
                fragment.write_text(
                    '<Wix><Fragment><Upgrade Id="$(var.UpgradeCode)" /></Fragment>'
                    '<?include ../Includes.wxi?></Wix>\n',
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(ValueError, "Upgrades.wxs.*UpgradeCode"):
                    preprocess.validate_shared_preprocessor_contract()

    def test_checked_in_upgrade_fragment_loads_shared_definitions(self) -> None:
        fragment = preprocess.PACKAGE_DIR / "Fragments" / "Upgrades.wxs"
        self.assertRegex(fragment.read_text(encoding="utf-8"), preprocess.SHARED_INCLUDE)


if __name__ == "__main__":
    unittest.main()
