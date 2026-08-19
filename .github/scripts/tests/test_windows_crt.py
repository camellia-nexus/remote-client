import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "verify_windows_crt.py"
SPEC = importlib.util.spec_from_file_location("verify_windows_crt", MODULE_PATH)
crt = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(crt)


class WindowsCrtPolicyTests(unittest.TestCase):
    def test_repository_policy_is_consistent(self) -> None:
        crt.verify_source()

    def test_archive_accepts_exact_runtime_for_each_configuration(self) -> None:
        fixtures = (
            ("static", "release", ' /DEFAULTLIB:"LIBCMT" /DEFAULTLIB:OLDNAMES'),
            ("static", "debug", " /DEFAULTLIB:LIBCMTD /DEFAULTLIB:OLDNAMES"),
            ("dynamic", "release", " /DEFAULTLIB:MSVCRT /DEFAULTLIB:KERNEL32"),
            ("dynamic", "debug", ' /DEFAULTLIB:"MSVCRTD.lib"'),
        )
        for linkage, configuration, output in fixtures:
            with self.subTest(linkage=linkage, configuration=configuration):
                crt.verify_archive_output(output, linkage, configuration)

    def test_archive_rejects_mixed_missing_and_wrong_runtimes(self) -> None:
        fixtures = (
            ("static", "release", "/DEFAULTLIB:LIBCMT /DEFAULTLIB:MSVCRT"),
            ("static", "release", "/DEFAULTLIB:KERNEL32"),
            ("static", "debug", "/DEFAULTLIB:LIBCMT"),
            ("dynamic", "release", "/DEFAULTLIB:LIBCMT"),
            ("dynamic", "debug", "/DEFAULTLIB:MSVCRT"),
        )
        for linkage, configuration, output in fixtures:
            with self.subTest(linkage=linkage, configuration=configuration):
                with self.assertRaises(crt.CrtPolicyError):
                    crt.verify_archive_output(output, linkage, configuration)

    def test_link_log_rejects_each_crt_warning(self) -> None:
        crt.verify_link_log_text("Finished release build")
        for code in crt.LINKER_WARNING_CODES:
            with self.subTest(code=code), self.assertRaises(crt.CrtPolicyError):
                crt.verify_link_log_text(f"warning {code}: incompatible runtime")

    def test_image_rejects_dynamic_crt_dependencies(self) -> None:
        crt.verify_image_output(
            "Image has the following dependencies:\n KERNEL32.dll\n USER32.dll\n"
        )
        for dependency in (
            "VCRUNTIME140.dll",
            "VCRUNTIME140_1D.dll",
            "MSVCP140.dll",
            "MSVCP140_ATOMIC_WAIT.dll",
            "MSVCP_WIN.dll",
            "MSVCR120D.dll",
            "CONCRT140.dll",
            "VCCORLIB140D.dll",
            "ucrtbase.dll",
            "api-ms-win-crt-runtime-l1-1-0.dll",
        ):
            with self.subTest(dependency=dependency), self.assertRaises(
                crt.CrtPolicyError
            ):
                crt.verify_image_output(
                    f"Image has the following dependencies:\n {dependency}\n"
                )

    def test_source_mutations_are_rejected(self) -> None:
        mutations = (
            (
                "res/vcpkg/opus/portfile.cmake",
                '-DOPUS_STATIC_RUNTIME=ON',
                '-DOPUS_STATIC_RUNTIME=AUTO',
            ),
            (
                ".cargo/config.toml",
                'rustflags = ["-C", "target-feature=+crt-static"]',
                'rustflags = ["-C", "target-feature=+crt-static", "-C", "link-args=/NODEFAULTLIB:MSVCRT"]',
            ),
            (
                ".github/workflows/release.yml",
                "image --path ",
                "image-check-removed --path ",
            ),
        )
        for relative, old, new in mutations:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as tmp:
                root = self.copy_policy_files(Path(tmp))
                path = root / relative
                text = path.read_text(encoding="utf-8")
                self.assertIn(old, text)
                path.write_text(text.replace(old, new, 1), encoding="utf-8")
                with self.assertRaises(crt.CrtPolicyError):
                    crt.verify_source(root)

    @staticmethod
    def copy_policy_files(root: Path) -> Path:
        for relative in (
            "res/vcpkg/opus/portfile.cmake",
            "res/vcpkg/opus/vcpkg.json",
            ".cargo/config.toml",
            ".github/workflows/ci.yml",
            ".github/workflows/release.yml",
        ):
            source = crt.ROOT / relative
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        return root


if __name__ == "__main__":
    unittest.main()
