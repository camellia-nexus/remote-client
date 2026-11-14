#!/usr/bin/env python3
"""Contract tests for Linux packaging, MIME scheme registration, and service lifecycle.

Validates BUILD-011, BUILD-012, and BUILD-013:
- BUILD-011: Desktop entry and link desktop registration for x-scheme-handler/camellia-remote.
- BUILD-012: Systemd service unit definition, safe maintainer scripts lifecycle, and Rust platform bindings.
- BUILD-013: AppImage runtime dependency closure, AppRun environment wrapper, and package validation script.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
import unittest

REPO_ROOT = Path(__file__).resolve().parents[3]


class LinuxPackagingAndServiceLifecycleContractTests(unittest.TestCase):
    """Contract verification for Linux packaging and systemd service lifecycle."""

    def test_build011_desktop_entry_mime_scheme(self) -> None:
        """Verify camellia-remote.desktop defines MIME scheme and correct metadata."""
        desktop_file = REPO_ROOT / "res" / "camellia-remote.desktop"
        self.assertTrue(desktop_file.exists(), "res/camellia-remote.desktop must exist")

        content = desktop_file.read_text(encoding="utf-8")
        self.assertIn("Name=Camellia Remote", content)
        self.assertIn("Exec=camellia-remote %u", content)
        self.assertIn("MimeType=x-scheme-handler/camellia-remote;", content)
        self.assertIn("StartupWMClass=camellia-remote", content)
        self.assertIn("Icon=camellia-remote", content)

    def test_build011_desktop_link_entry_mime_scheme(self) -> None:
        """Verify camellia-remote-link.desktop defines NoDisplay and MIME scheme."""
        link_file = REPO_ROOT / "res" / "camellia-remote-link.desktop"
        self.assertTrue(link_file.exists(), "res/camellia-remote-link.desktop must exist")

        content = link_file.read_text(encoding="utf-8")
        self.assertIn("Name=Camellia Remote", content)
        self.assertIn("NoDisplay=true", content)
        self.assertIn("MimeType=x-scheme-handler/camellia-remote;", content)
        self.assertIn("Exec=camellia-remote %u", content)
        self.assertIn("StartupWMClass=camellia-remote", content)

    def test_build012_systemd_service_unit_contract(self) -> None:
        """Verify camellia-remote.service has robust structure, no broad pkill, no PIDFile."""
        service_file = REPO_ROOT / "res" / "camellia-remote.service"
        self.assertTrue(service_file.exists(), "res/camellia-remote.service must exist")

        content = service_file.read_text(encoding="utf-8")
        self.assertIn("Description=Camellia Remote Service", content)
        self.assertIn("ExecStart=/usr/bin/camellia-remote --service", content)
        self.assertIn("Restart=on-failure", content)
        self.assertIn("KillMode=mixed", content)
        self.assertIn("WantedBy=multi-user.target", content)

        # Defense against broad pkill and unowned PIDFile
        self.assertNotIn("pkill", content, "Service must not use unsafe broad pkill in ExecStop")
        self.assertNotIn("PIDFile", content, "Service must not use unowned PIDFile in Type=simple")

    def test_build012_debian_maintainer_scripts(self) -> None:
        """Verify Debian maintainer scripts exist, are executable, and follow safe lifecycle."""
        debian_dir = REPO_ROOT / "res" / "DEBIAN"
        for script_name in ("preinst", "postinst", "prerm", "postrm"):
            script_path = debian_dir / script_name
            self.assertTrue(script_path.exists(), f"res/DEBIAN/{script_name} must exist")
            self.assertTrue(
                os.access(script_path, os.X_OK),
                f"res/DEBIAN/{script_name} must be executable",
            )
            content = script_path.read_text(encoding="utf-8")
            self.assertTrue(content.startswith("#!/bin/sh"), f"{script_name} must use #!/bin/sh")
            self.assertIn("set -e", content, f"{script_name} must use set -e")

        preinst_content = (debian_dir / "preinst").read_text(encoding="utf-8")
        self.assertIn("systemctl stop camellia-remote.service", preinst_content)

        postinst_content = (debian_dir / "postinst").read_text(encoding="utf-8")
        self.assertIn("systemctl --system daemon-reload", postinst_content)
        self.assertIn("update-desktop-database", postinst_content)
        self.assertIn("update-mime-database", postinst_content)

        prerm_content = (debian_dir / "prerm").read_text(encoding="utf-8")
        self.assertIn("systemctl --system stop camellia-remote.service", prerm_content)
        self.assertIn("systemctl --system disable camellia-remote.service", prerm_content)

        postrm_content = (debian_dir / "postrm").read_text(encoding="utf-8")
        self.assertIn("systemctl --system daemon-reload", postrm_content)
        self.assertIn("update-desktop-database", postrm_content)
        self.assertIn("update-mime-database", postrm_content)
        self.assertIn("camellia-remote", postrm_content)

    def test_build012_pacman_install_service_names(self) -> None:
        """Verify pacman_install consistently references camellia-remote.service."""
        pacman_file = REPO_ROOT / "res" / "pacman_install"
        self.assertTrue(pacman_file.exists(), "res/pacman_install must exist")

        content = pacman_file.read_text(encoding="utf-8")
        self.assertIn("systemctl enable camellia-remote", content)
        self.assertIn("systemctl start camellia-remote", content)
        self.assertIn("systemctl stop camellia-remote", content)
        self.assertNotIn("systemctl enable camellia\n", content)
        self.assertNotIn("systemctl start camellia\n", content)

    def test_build012_linux_rust_install_service_safety(self) -> None:
        """Verify install_service and uninstall_service handle errors and return false on failure."""
        linux_rs = REPO_ROOT / "src" / "platform" / "linux.rs"
        self.assertTrue(linux_rs.exists(), "src/platform/linux.rs must exist")

        content = linux_rs.read_text(encoding="utf-8")

        # install_service check
        self.assertIn("pub fn install_service() -> bool", content)
        self.assertIn("systemctl daemon-reload", content)
        self.assertIn("systemctl enable {SERVICE_UNIT}; systemctl start {SERVICE_UNIT}", content)
        # Verify it checks run_cmds_privileged result and does not return true unconditionally
        self.assertIn("let ok = run_cmds_privileged(", content)
        self.assertIn("if !ok {\n        Config::set_option(\"stop-service\".into(), \"Y\".into());\n        return false;\n    }", content)

        # uninstall_service check
        self.assertIn("pub fn uninstall_service(show_new_window: bool, _: bool) -> bool", content)
        self.assertIn("systemctl stop {SERVICE_UNIT}; systemctl disable {SERVICE_UNIT}", content)
        self.assertIn("if !ok {\n        Config::set_option(\"stop-service\".into(), \"\".into());\n        return false;\n    }", content)

    def test_build013_package_linux_deb_and_appimage_structure(self) -> None:
        """Verify package-linux.sh installs service unit, desktop entries, and builds AppRun."""
        package_sh = REPO_ROOT / ".github" / "scripts" / "package-linux.sh"
        self.assertTrue(package_sh.exists(), ".github/scripts/package-linux.sh must exist")

        content = package_sh.read_text(encoding="utf-8")
        # DEB packaging checks
        self.assertIn("res/camellia-remote.desktop", content)
        self.assertIn("res/camellia-remote-link.desktop", content)
        self.assertIn("res/camellia-remote.service", content)
        self.assertIn("res/DEBIAN/$script", content)
        self.assertIn("package_root/lib/systemd/system", content)

        # AppImage packaging checks
        self.assertIn("appdir/usr/share/applications/camellia-remote-link.desktop", content)
        self.assertIn("appdir/camellia-remote.desktop", content)
        self.assertIn("appdir/.DirIcon", content)
        self.assertIn("export LD_LIBRARY_PATH=", content)
        self.assertIn("export XDG_DATA_DIRS=", content)
        self.assertIn("APPIMAGETOOL_VERSION=\"1.9.1\"", content)
        self.assertIn("Verifying native runtime dependency closure", content)

    def test_build013_check_linux_package_script_integrity(self) -> None:
        """Verify check-linux-package.sh script exists, is executable, and contains validation gates."""
        check_sh = REPO_ROOT / ".github" / "scripts" / "check-linux-package.sh"
        self.assertTrue(check_sh.exists(), ".github/scripts/check-linux-package.sh must exist")
        self.assertTrue(
            os.access(check_sh, os.X_OK),
            ".github/scripts/check-linux-package.sh must be executable",
        )

        content = check_sh.read_text(encoding="utf-8")
        self.assertIn("MimeType=x-scheme-handler/camellia-remote;", content)
        self.assertIn("camellia-remote.service", content)
        self.assertIn("AppRun", content)
        self.assertIn("LD_LIBRARY_PATH", content)

    def test_build005_linux_ci_check_appdir_path(self) -> None:
        """Verify Linux CI passes artifacts/CamelliaRemote.AppDir to check-linux-package.sh."""
        ci_path = REPO_ROOT / ".github" / "workflows" / "ci.yml"
        ci_content = ci_path.read_text(encoding="utf-8")
        self.assertIn(
            'check-linux-package.sh "artifacts/camellia-remote-${{ needs.metadata.outputs.version }}-linux-x64.deb" "artifacts/CamelliaRemote.AppDir" "x86_64"',
            ci_content,
        )


if __name__ == "__main__":
    unittest.main()
