//! Batch 79 Integration and Defensive Verification Tests:
//! LEGAL-002: Distribution artifact legal compliance bundle & provenance
//! LEGAL-003: Workspace crate license metadata & attribution

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_workspace_client_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_legal003_workspace_manifests_license_and_repository() {
    let client_dir = get_workspace_client_dir();
    let manifests = [
        "libs/clipboard/Cargo.toml",
        "libs/portable/Cargo.toml",
        "libs/remote_printer/Cargo.toml",
        "libs/virtual_display/Cargo.toml",
        "libs/virtual_display/dylib/Cargo.toml",
        "libs/libxdo-sys-stub/Cargo.toml",
        "libs/hwcodec/Cargo.toml",
    ];

    for rel in manifests {
        let path = client_dir.join(rel);
        assert!(path.exists(), "Manifest {:?} must exist", path);
        let content = fs::read_to_string(&path).expect("Failed to read Cargo.toml");
        assert!(
            content.contains("license = \"AGPL-3.0-only\""),
            "{rel} must declare license = AGPL-3.0-only"
        );
        assert!(
            content.contains("repository = \"https://github.com/camellia-nexus/remote-client\""),
            "{rel} must declare repository URL"
        );
    }
}

#[test]
fn test_legal003_third_party_license_files() {
    let client_dir = get_workspace_client_dir();
    let scrap_license = client_dir.join("libs/scrap/LICENSE");
    let enigo_license = client_dir.join("libs/enigo/LICENSE");

    assert!(scrap_license.exists(), "libs/scrap/LICENSE must exist");
    let scrap_text = fs::read_to_string(&scrap_license).expect("Failed to read scrap LICENSE");
    assert!(scrap_text.contains("MIT License"));
    assert!(scrap_text.contains("Ram <quadrupleslap@gmail.com>"));

    assert!(enigo_license.exists(), "libs/enigo/LICENSE must exist");
    let enigo_text = fs::read_to_string(&enigo_license).expect("Failed to read enigo LICENSE");
    assert!(enigo_text.contains("MIT License"));
}

#[test]
fn test_legal002_flutter_compliance_bundle() {
    let client_dir = get_workspace_client_dir();
    let legal_dir = client_dir.join("flutter/assets/legal");

    assert!(
        legal_dir.join("LICENSE").exists(),
        "assets/legal/LICENSE must exist"
    );
    assert!(
        legal_dir.join("NOTICE").exists(),
        "assets/legal/NOTICE must exist"
    );
    assert!(
        legal_dir.join("OFL.txt").exists(),
        "assets/legal/OFL.txt must exist"
    );
    assert!(
        legal_dir.join("SOURCE_PROVENANCE.json").exists(),
        "assets/legal/SOURCE_PROVENANCE.json must exist"
    );

    let pubspec_path = client_dir.join("flutter/pubspec.yaml");
    let pubspec_text = fs::read_to_string(&pubspec_path).expect("Failed to read pubspec.yaml");
    assert!(pubspec_text.contains("- assets/legal/"));
    assert!(pubspec_text.contains("- assets/fonts/OFL.txt"));
}
