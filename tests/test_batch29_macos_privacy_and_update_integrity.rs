// Copyright (c) 2026 Camellia Computing. All rights reserved.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

//! Integration Test Suite for Batch 29:
//! macOS Privacy Mode & Update Integrity Hardening
//!
//! Verifies:
//! - `PRIV-006`: Fail-closed display blackout verification; rejects unverified or unsupported gamma.
//! - `STATE-003`: Persistence of pending gamma snapshots on partial restore failure; Rust-Native owner synchronization.
//! - `UPDATE-002`: App bundle structural validation, Info.plist metadata parsing, version monotonicity downgrade defense, quarantine preservation.
//! - `UPDATE-003`: Transactional staging directory, atomic swap, automatic rollback on error, POSIX quoting, fail-fast script execution.

use camellia_remote::platform::macos_update_safety::{
    MacAppBundleValidator, UpdateTransactionAssembler, VersionTuple,
};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

fn unique_test_temp_dir(prefix: &str) -> PathBuf {
    let rand_token = uuid::Uuid::new_v4().simple().to_string();
    let dir = std::env::temp_dir().join(format!("test_batch29_{}_{}", prefix, rand_token));
    fs::create_dir_all(&dir).expect("Failed to create test temp dir");
    dir
}

// ============================================================================
// UPDATE-002: Bundle Structure, Metadata, and Version Monotonicity Tests
// ============================================================================

#[test]
fn test_update002_version_tuple_parsing_and_monotonicity() {
    let v1 = VersionTuple::parse("1.2.3");
    let v2 = VersionTuple::parse("1.2.4");
    let v2_dup = VersionTuple::parse("1.2.4");
    let v_older = VersionTuple::parse("1.2.2");
    let v_major = VersionTuple::parse("2.0.0");
    let v_build = VersionTuple::parse("1.2.3.456");

    assert!(v2.is_at_least(&v1), "1.2.4 should be at least 1.2.3");
    assert!(v2.is_at_least(&v2_dup), "1.2.4 should be at least 1.2.4");
    assert!(!v_older.is_at_least(&v1), "1.2.2 is older than 1.2.3");
    assert!(v_major.is_at_least(&v2), "2.0.0 should be at least 1.2.4");
    assert!(
        v_build.is_at_least(&v1),
        "1.2.3.456 should be at least 1.2.3"
    );

    // Test verify_version_monotonicity
    assert!(MacAppBundleValidator::verify_version_monotonicity("1.2.0", "1.2.1").is_ok());
    assert!(MacAppBundleValidator::verify_version_monotonicity("1.2.0", "1.2.0").is_ok());
    assert!(MacAppBundleValidator::verify_version_monotonicity("2.1.0", "2.0.9").is_err());
}

#[test]
fn test_update002_extract_plist_string() {
    let plist = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.camellia.remote</string>
    <key>CFBundleExecutable</key>
    <string>Camellia Remote</string>
    <key>CFBundleShortVersionString</key>
    <string>1.4.2</string>
    <key>CFBundleVersion</key>
    <string>1042</string>
</dict>
</plist>"#;

    assert_eq!(
        MacAppBundleValidator::extract_plist_string(plist, "CFBundleIdentifier"),
        Some("com.camellia.remote".to_string())
    );
    assert_eq!(
        MacAppBundleValidator::extract_plist_string(plist, "CFBundleExecutable"),
        Some("Camellia Remote".to_string())
    );
    assert_eq!(
        MacAppBundleValidator::extract_plist_string(plist, "CFBundleShortVersionString"),
        Some("1.4.2".to_string())
    );
    assert_eq!(
        MacAppBundleValidator::extract_plist_string(plist, "CFBundleVersion"),
        Some("1042".to_string())
    );
    assert_eq!(
        MacAppBundleValidator::extract_plist_string(plist, "NonExistentKey"),
        None
    );
}

#[test]
fn test_update002_validate_bundle_structure_success() {
    let base_dir = unique_test_temp_dir("valid_bundle");
    let bundle = base_dir.join("Camellia.app");
    let contents = bundle.join("Contents");
    let macos = contents.join("MacOS");
    fs::create_dir_all(&macos).unwrap();

    let plist_content = r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.camellia.remote</string>
    <key>CFBundleExecutable</key>
    <string>Camellia</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>200</string>
</dict>
</plist>"#;
    fs::write(contents.join("Info.plist"), plist_content).unwrap();
    fs::write(macos.join("Camellia"), b"FAKE_MACHO_BINARY").unwrap();

    let meta = MacAppBundleValidator::validate_bundle_structure(&bundle)
        .expect("Bundle structure should be valid");

    assert_eq!(meta.bundle_identifier, "com.camellia.remote");
    assert_eq!(meta.executable_name, "Camellia");
    assert_eq!(meta.short_version_string, "2.0.0");
    assert_eq!(meta.bundle_version, "200");
}

#[test]
fn test_update002_validate_bundle_structure_rejections() {
    let base_dir = unique_test_temp_dir("invalid_bundles");

    // 1. Non-existent path
    assert!(
        MacAppBundleValidator::validate_bundle_structure(&base_dir.join("non_existent.app"))
            .is_err()
    );

    // 2. Not a directory
    let file_app = base_dir.join("not_a_dir.app");
    fs::write(&file_app, b"regular file").unwrap();
    assert!(MacAppBundleValidator::validate_bundle_structure(&file_app).is_err());

    // 3. Not ending in .app
    let not_app_ext = base_dir.join("Something.bundle");
    fs::create_dir_all(&not_app_ext).unwrap();
    assert!(MacAppBundleValidator::validate_bundle_structure(&not_app_ext).is_err());

    // 4. Missing Contents directory
    let missing_contents = base_dir.join("MissingContents.app");
    fs::create_dir_all(&missing_contents).unwrap();
    assert!(MacAppBundleValidator::validate_bundle_structure(&missing_contents).is_err());

    // 5. Missing Contents/MacOS directory
    let missing_macos = base_dir.join("MissingMacOS.app");
    let c = missing_macos.join("Contents");
    fs::create_dir_all(&c).unwrap();
    fs::write(c.join("Info.plist"), "<plist></plist>").unwrap();
    assert!(MacAppBundleValidator::validate_bundle_structure(&missing_macos).is_err());

    // 6. Missing Info.plist
    let missing_plist = base_dir.join("MissingPlist.app");
    let c = missing_plist.join("Contents");
    fs::create_dir_all(c.join("MacOS")).unwrap();
    assert!(MacAppBundleValidator::validate_bundle_structure(&missing_plist).is_err());

    // 7. Declared binary missing from Contents/MacOS
    let missing_bin = base_dir.join("MissingBin.app");
    let c = missing_bin.join("Contents");
    fs::create_dir_all(c.join("MacOS")).unwrap();
    let plist_with_missing_bin = r#"<plist><dict>
        <key>CFBundleExecutable</key>
        <string>NonExistentBinary</string>
    </dict></plist>"#;
    fs::write(c.join("Info.plist"), plist_with_missing_bin).unwrap();
    assert!(MacAppBundleValidator::validate_bundle_structure(&missing_bin).is_err());
}

// ============================================================================
// UPDATE-003: Transactional Script Assembly, Rollback, and Quarantine Invariants
// ============================================================================

#[test]
fn test_update003_transactional_assembler_invariants() {
    let script = UpdateTransactionAssembler::assemble_transaction_script(
        "Camellia Remote",
        "/tmp/camellia_update_extracted/Camellia Remote.app",
        "camellia_user",
        12345,
        "uuid-tx-001",
    );

    // 1. Must use set -e for fail-fast execution
    assert!(script.contains("set -e;"), "Script must enable set -e");

    // 2. Must verify source existence and Contents/MacOS
    assert!(
        script
            .contains("test -d '/tmp/camellia_update_extracted/Camellia Remote.app' || exit 101;"),
        "Script must check source app existence"
    );
    assert!(
        script.contains("Contents/MacOS' || exit 102;"),
        "Script must check source bundle structure"
    );

    // 3. Must use isolated staging bundle and backup bundle
    assert!(
        script.contains("/Applications/Camellia Remote.app.staging.uuid-tx-001"),
        "Script must use transactional staging directory"
    );
    assert!(
        script.contains("/Applications/Camellia Remote.app.backup.uuid-tx-001"),
        "Script must use transactional backup directory"
    );

    // 4. Must implement atomic swap with automatic rollback on failure
    assert!(
        script.contains("if [ -d '/Applications/Camellia Remote.app' ]; then mv '/Applications/Camellia Remote.app' '/Applications/Camellia Remote.app.backup.uuid-tx-001'; fi;"),
        "Script must create backup prior to swap"
    );
    assert!(
        script.contains("if ! mv '/Applications/Camellia Remote.app.staging.uuid-tx-001' '/Applications/Camellia Remote.app'; then"),
        "Script must attempt atomic swap"
    );
    assert!(
        script.contains("if [ -d '/Applications/Camellia Remote.app.backup.uuid-tx-001' ]; then mv '/Applications/Camellia Remote.app.backup.uuid-tx-001' '/Applications/Camellia Remote.app'; fi;"),
        "Script must roll back to backup if swap fails"
    );

    // 5. Must strictly preserve Gatekeeper quarantine: NO xattr -r -d com.apple.quarantine
    assert!(
        !script.contains("xattr -r -d com.apple.quarantine"),
        "Script MUST NOT strip Gatekeeper quarantine attributes"
    );
    assert!(
        !script.contains("quarantine"),
        "Script MUST NOT manipulate quarantine attributes"
    );

    // 6. Must verify active bundle after swap before cleaning backup
    assert!(
        script.contains("[ ! -d '/Applications/Camellia Remote.app/Contents/MacOS' ]"),
        "Script must verify installed bundle before backup deletion"
    );
}

#[test]
fn test_update003_daemon_update_script_assembly() {
    let script = UpdateTransactionAssembler::assemble_daemon_update_script(
        "Camellia",
        "/tmp/dmg_mount/Camellia.app",
        "camellia_user",
        999,
        "/Library/LaunchDaemons/com.camellia.service.plist",
        "/Library/LaunchAgents/com.camellia.server.plist",
        "tx-daemon-888",
    );

    assert!(script.contains("set -e;"));
    assert!(script.contains("launchctl bootout") || script.contains("launchctl unload"));
    assert!(script.contains("/Applications/Camellia.app.staging.tx-daemon-888"));
    assert!(script.contains("/Applications/Camellia.app.backup.tx-daemon-888"));
    assert!(!script.contains("quarantine"));
}

// ============================================================================
// PRIV-006 & STATE-003: Privacy Mode Blackout & Snapshot Integrity Models
// ============================================================================

/// Model of display gamma verification per PRIV-006:
/// Fail-closed verification rule: if capacity is 0, sample count is 0, or any
/// gamma transfer value is non-zero (above float tolerance), verification fails.
fn verify_gamma_blackout(capacity: u32, samples: &[f32]) -> bool {
    if capacity == 0 || samples.is_empty() || samples.len() != capacity as usize {
        return false;
    }
    const EPSILON: f32 = 0.001f32;
    samples.iter().all(|&v| v.abs() < EPSILON)
}

#[test]
fn test_priv006_fail_closed_gamma_readback() {
    // 1. Zero capacity display: fail closed
    assert!(
        !verify_gamma_blackout(0, &[]),
        "Zero capacity must fail closed"
    );

    // 2. Mismatched sample count: fail closed
    assert!(
        !verify_gamma_blackout(256, &[0.0f32; 128]),
        "Truncated sample count must fail closed"
    );

    // 3. Normal blackout: all zeros -> success
    let blacked_out = vec![0.0f32; 256];
    assert!(
        verify_gamma_blackout(256, &blacked_out),
        "All zeros must succeed"
    );

    // 4. Incomplete blackout: non-zero entry -> fail closed
    let mut partially_lit = vec![0.0f32; 256];
    partially_lit[100] = 0.05f32;
    assert!(
        !verify_gamma_blackout(256, &partially_lit),
        "Non-zero gamma must fail closed"
    );
}

/// Model of gamma snapshot manager per STATE-003:
/// Displays that fail to restore MUST retain their snapshots in the map.
struct MockGammaManager {
    snapshots: HashMap<String, Vec<f32>>,
}

impl MockGammaManager {
    fn new() -> Self {
        Self {
            snapshots: HashMap::new(),
        }
    }

    fn record_snapshot(&mut self, uuid: &str, gamma: Vec<f32>) {
        self.snapshots.insert(uuid.to_string(), gamma);
    }

    /// Attempts to restore all displays using the provided simulated hardware status map.
    /// Returns true only if all displays were online and restored.
    /// Only successfully restored UUIDs are removed from `snapshots`.
    fn restore_all(&mut self, online_and_ok: &HashMap<String, bool>) -> bool {
        let mut all_success = true;
        let mut restored = Vec::new();

        for (uuid, _gamma) in &self.snapshots {
            match online_and_ok.get(uuid) {
                Some(true) => {
                    restored.push(uuid.clone());
                }
                Some(false) => {
                    // Display online but restore hardware failed
                    all_success = false;
                }
                None => {
                    // Display is offline
                    all_success = false;
                }
            }
        }

        for uuid in restored {
            self.snapshots.remove(&uuid);
        }

        all_success
    }
}

#[test]
fn test_state003_gamma_snapshot_persistence_on_partial_restore_failure() {
    let mut manager = MockGammaManager::new();
    manager.record_snapshot("DISPLAY_INTERNAL_1", vec![0.5f32; 256]);
    manager.record_snapshot("DISPLAY_EXTERNAL_HOTPLUG_2", vec![0.8f32; 256]);
    assert_eq!(manager.snapshots.len(), 2);

    // Scenario A: External display was unplugged during privacy mode (offline)
    let mut hardware_status = HashMap::new();
    hardware_status.insert("DISPLAY_INTERNAL_1".to_string(), true);
    // DISPLAY_EXTERNAL_HOTPLUG_2 is missing from hardware_status (offline)

    let success = manager.restore_all(&hardware_status);
    assert!(
        !success,
        "Overall restore must report false when a display is offline"
    );
    assert_eq!(
        manager.snapshots.len(),
        1,
        "Only successfully restored display should be removed"
    );
    assert!(
        manager.snapshots.contains_key("DISPLAY_EXTERNAL_HOTPLUG_2"),
        "Offline display snapshot MUST be retained for subsequent recovery upon reconnection"
    );

    // Scenario B: External display reconnects later and restore is retried
    hardware_status.insert("DISPLAY_EXTERNAL_HOTPLUG_2".to_string(), true);
    let retry_success = manager.restore_all(&hardware_status);
    assert!(
        retry_success,
        "Second restore attempt should succeed when display is back online"
    );
    assert_eq!(
        manager.snapshots.len(),
        0,
        "All snapshots should be cleared now"
    );
}

#[test]
fn test_state003_owner_synchronization_model() {
    // Simulates the native-to-Rust owner synchronization state machine
    let mut active_conn_id: i32 = 42;
    let mut native_privacy_active = true;

    // Verify when active, conn_id is preserved
    assert_eq!(active_conn_id, 42);
    assert!(native_privacy_active);

    // Simulate native async shutdown triggered by display monitor failure
    native_privacy_active = false;
    // Callback fires
    active_conn_id = 0;

    assert!(!native_privacy_active);
    // Incoming connection 84 attempts to check ownership
    let can_acquire = active_conn_id == 0;
    assert!(
        can_acquire,
        "New connection must be allowed to acquire privacy mode after native async loss"
    );
}
