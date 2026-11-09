//! Batch 51 Contract Verification: Linux Packaging, URI Association, & Service Lifecycle
//! Covers:
//! - BUILD-011: Official DEB/AppImage registers camellia-remote:// scheme handler via desktop entries.
//! - BUILD-012: Systemd service unit definition, safe maintainer scripts lifecycle, and Rust platform bindings.
//! - BUILD-013: AppImage runtime dependency closure, AppRun environment wrapper, and package validation script.

use std::fs;
use std::path::PathBuf;

fn get_workspace_client_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_build011_desktop_entries_mime_scheme_contract() {
    let client_dir = get_workspace_client_dir();
    let main_desktop = client_dir.join("res/camellia-remote.desktop");
    let link_desktop = client_dir.join("res/camellia-remote-link.desktop");

    assert!(
        main_desktop.exists(),
        "res/camellia-remote.desktop must exist"
    );
    assert!(
        link_desktop.exists(),
        "res/camellia-remote-link.desktop must exist"
    );

    let main_content =
        fs::read_to_string(&main_desktop).expect("Failed to read camellia-remote.desktop");
    let link_content =
        fs::read_to_string(&link_desktop).expect("Failed to read camellia-remote-link.desktop");

    // Main desktop entry assertions
    assert!(
        main_content.contains("Name=Camellia Remote"),
        "Main desktop entry must declare Name=Camellia Remote"
    );
    assert!(
        main_content.contains("Exec=camellia-remote %u"),
        "Main desktop entry must support %u URI parameter"
    );
    assert!(
        main_content.contains("MimeType=x-scheme-handler/camellia-remote;"),
        "Main desktop entry must register x-scheme-handler/camellia-remote"
    );
    assert!(
        main_content.contains("StartupWMClass=camellia-remote"),
        "Main desktop entry must declare StartupWMClass=camellia-remote"
    );

    // Link desktop entry assertions
    assert!(
        link_content.contains("NoDisplay=true"),
        "Link desktop entry must declare NoDisplay=true"
    );
    assert!(
        link_content.contains("MimeType=x-scheme-handler/camellia-remote;"),
        "Link desktop entry must register x-scheme-handler/camellia-remote"
    );
    assert!(
        link_content.contains("Exec=camellia-remote %u"),
        "Link desktop entry must support %u URI parameter"
    );
}

#[test]
fn test_build012_systemd_service_unit_contract() {
    let client_dir = get_workspace_client_dir();
    let service_path = client_dir.join("res/camellia-remote.service");

    assert!(
        service_path.exists(),
        "res/camellia-remote.service must exist"
    );
    let content =
        fs::read_to_string(&service_path).expect("Failed to read camellia-remote.service");

    assert!(
        content.contains("Description=Camellia Remote Service"),
        "Unit must have descriptive name"
    );
    assert!(
        content.contains("ExecStart=/usr/bin/camellia-remote --service"),
        "ExecStart must use canonical binary path and --service flag"
    );
    assert!(
        content.contains("Restart=on-failure"),
        "Service must specify Restart=on-failure"
    );
    assert!(
        content.contains("KillMode=mixed"),
        "Service must use KillMode=mixed"
    );
    assert!(
        content.contains("WantedBy=multi-user.target"),
        "Service must install to multi-user.target"
    );

    // Ensure unsafe constructs are absent
    assert!(
        !content.contains("pkill"),
        "Service must not use broad pkill"
    );
    assert!(
        !content.contains("PIDFile"),
        "Service must not declare unowned PIDFile"
    );
}

#[test]
fn test_build012_maintainer_scripts_lifecycle_contract() {
    let client_dir = get_workspace_client_dir();
    let debian_dir = client_dir.join("res/DEBIAN");

    for script_name in &["preinst", "postinst", "prerm", "postrm"] {
        let script_path = debian_dir.join(script_name);
        assert!(script_path.exists(), "res/DEBIAN/{script_name} must exist");
        let content = fs::read_to_string(&script_path)
            .unwrap_or_else(|_| panic!("Failed to read {script_name}"));
        assert!(
            content.starts_with("#!/bin/sh"),
            "{script_name} must start with #!/bin/sh"
        );
        assert!(
            content.contains("set -e"),
            "{script_name} must enable set -e"
        );
    }

    let preinst = fs::read_to_string(debian_dir.join("preinst")).unwrap();
    assert!(
        preinst.contains("systemctl stop camellia-remote.service"),
        "preinst must stop service on install/upgrade"
    );

    let postinst = fs::read_to_string(debian_dir.join("postinst")).unwrap();
    assert!(
        postinst.contains("systemctl --system daemon-reload"),
        "postinst must reload systemd daemon"
    );
    assert!(
        postinst.contains("update-desktop-database"),
        "postinst must update desktop database"
    );
    assert!(
        postinst.contains("update-mime-database"),
        "postinst must update mime database"
    );

    let prerm = fs::read_to_string(debian_dir.join("prerm")).unwrap();
    assert!(
        prerm.contains("systemctl --system stop camellia-remote.service"),
        "prerm must stop service"
    );
    assert!(
        prerm.contains("systemctl --system disable camellia-remote.service"),
        "prerm must disable service"
    );

    let postrm = fs::read_to_string(debian_dir.join("postrm")).unwrap();
    assert!(
        postrm.contains("systemctl --system daemon-reload"),
        "postrm must reload daemon on remove/purge"
    );
    assert!(
        postrm.contains("camellia-remote"),
        "postrm must reference camellia-remote config cleanup"
    );
}

#[test]
fn test_build012_linux_rust_service_bindings_contract() {
    let client_dir = get_workspace_client_dir();
    let linux_rs = client_dir.join("src/platform/linux.rs");

    assert!(linux_rs.exists(), "src/platform/linux.rs must exist");
    let content = fs::read_to_string(&linux_rs).expect("Failed to read src/platform/linux.rs");

    // Check install_service implementation
    assert!(
        content.contains("pub fn install_service() -> bool"),
        "install_service must be defined"
    );
    assert!(
        content.contains("systemctl daemon-reload"),
        "install_service must invoke daemon-reload"
    );
    assert!(
        content.contains("systemctl enable {SERVICE_UNIT}; systemctl start {SERVICE_UNIT}"),
        "install_service must enable and start SERVICE_UNIT"
    );
    assert!(
        content.contains("if !ok {\n        Config::set_option(\"stop-service\".into(), \"Y\".into());\n        return false;\n    }"),
        "install_service must return false when privileged command fails"
    );

    // Check uninstall_service implementation
    assert!(
        content.contains("pub fn uninstall_service(show_new_window: bool, _: bool) -> bool"),
        "uninstall_service must be defined"
    );
    assert!(
        content.contains("systemctl stop {SERVICE_UNIT}; systemctl disable {SERVICE_UNIT}"),
        "uninstall_service must stop and disable SERVICE_UNIT"
    );
    assert!(
        content.contains("if !ok {\n        Config::set_option(\"stop-service\".into(), \"\".into());\n        return false;\n    }"),
        "uninstall_service must return false when privileged command fails"
    );
}

#[test]
fn test_build013_package_linux_and_check_script_contract() {
    let client_dir = get_workspace_client_dir();
    let pkg_sh = client_dir.join(".github/scripts/package-linux.sh");
    let check_sh = client_dir.join(".github/scripts/check-linux-package.sh");

    assert!(pkg_sh.exists(), "package-linux.sh must exist");
    assert!(check_sh.exists(), "check-linux-package.sh must exist");

    let pkg_content = fs::read_to_string(&pkg_sh).expect("Failed to read package-linux.sh");
    let check_content =
        fs::read_to_string(&check_sh).expect("Failed to read check-linux-package.sh");

    // Package script assertions
    assert!(
        pkg_content.contains("res/camellia-remote-link.desktop"),
        "package-linux.sh must package camellia-remote-link.desktop"
    );
    assert!(
        pkg_content.contains("res/camellia-remote.service"),
        "package-linux.sh must package camellia-remote.service"
    );
    assert!(
        pkg_content.contains("res/DEBIAN/$script"),
        "package-linux.sh must package DEBIAN maintainer scripts"
    );
    assert!(
        pkg_content.contains("export LD_LIBRARY_PATH="),
        "AppRun must configure LD_LIBRARY_PATH"
    );
    assert!(
        pkg_content.contains("export XDG_DATA_DIRS="),
        "AppRun must configure XDG_DATA_DIRS"
    );
    assert!(
        pkg_content.contains("APPIMAGETOOL_VERSION=\"1.9.1\""),
        "package-linux.sh must lock appimagetool to 1.9.1"
    );

    // Check script assertions
    assert!(
        check_content.contains("MimeType=x-scheme-handler/camellia-remote;"),
        "check-linux-package.sh must assert MIME scheme handler"
    );
    assert!(
        check_content.contains("camellia-remote.service"),
        "check-linux-package.sh must assert service unit presence"
    );
    assert!(
        check_content.contains("AppRun"),
        "check-linux-package.sh must assert AppRun presence and execution"
    );
}
