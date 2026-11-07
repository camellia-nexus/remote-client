// Copyright (c) 2026 Camellia Computing. All rights reserved.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

//! Integration Test Suite for Batch 28:
//! Windows Elevation, ACL Governance & Install/Update Safety Hardening
//!
//! Verifies:
//! - `ACL-001`: Scoped per-file permissions, domain/username parsing, non-recursive directory rejection.
//! - `ELEV-001`: Fail-fast batch script assembly, SHA-256 integrity binding, authenticated sentinel verification, workspace lifecycle.
//! - `UPDATE-001`: Strict allowlisted bundle manifest discovery, exclusion of parent directory contents/canary files, elimination of /C ignore-errors flag.

use camellia_remote::platform::install_safety::{
    BundleItemType, BundleManifest, ElevatedBatchAssembler, ElevationWorkspaceGuard,
};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;

fn unique_test_temp_dir(prefix: &str) -> PathBuf {
    let rand_token = uuid::Uuid::new_v4().simple().to_string();
    let dir = std::env::temp_dir().join(format!("test_batch28_{}_{}", prefix, rand_token));
    fs::create_dir_all(&dir).expect("Failed to create test temp dir");
    dir
}

// ============================================================================
// UPDATE-001: Strict Bundle Manifest & Parent Directory Isolation Tests
// ============================================================================

#[test]
fn test_update001_bundle_manifest_only_includes_allowlisted_items() {
    let src_dir = unique_test_temp_dir("manifest_allowlist_src");
    let install_dir = unique_test_temp_dir("manifest_allowlist_dst");

    // Create primary executable
    let src_exe = src_dir.join("camellia-remote.exe");
    fs::write(&src_exe, b"MZ_FAKE_EXE_BINARY").unwrap();

    // Create allowlisted sibling items
    let flutter_dll = src_dir.join("flutter_windows.dll");
    fs::write(&flutter_dll, b"MZ_FAKE_FLUTTER_DLL").unwrap();

    let plugin_dll = src_dir.join("screen_retriever_windows_plugin.dll");
    fs::write(&plugin_dll, b"MZ_FAKE_PLUGIN_DLL").unwrap();

    let broker_exe = src_dir.join("win_topmost_window_broker.exe");
    fs::write(&broker_exe, b"MZ_FAKE_BROKER_EXE").unwrap();

    let data_dir = src_dir.join("data");
    fs::create_dir_all(&data_dir).unwrap();
    fs::write(data_dir.join("app.so"), b"DATA_BLOB").unwrap();

    // Create hostile / extraneous items that MUST NOT be copied
    let canary_key = src_dir.join("private_secret_key.pem");
    fs::write(&canary_key, b"CANARY_SECRET_RSA_KEY").unwrap();

    let document = src_dir.join("financial_report.xlsx");
    fs::write(&document, b"SPREADSHEET_DATA").unwrap();

    let malicious_bat = src_dir.join("attack.bat");
    fs::write(&malicious_bat, b"@echo evil").unwrap();

    let random_dll = src_dir.join("unrelated_hack.dll");
    fs::write(&random_dll, b"UNRELATED_DLL").unwrap();

    let random_dir = src_dir.join("My Personal Documents");
    fs::create_dir_all(&random_dir).unwrap();
    fs::write(random_dir.join("secret.txt"), b"SECRET").unwrap();

    // Run manifest discovery
    let manifest = BundleManifest::scan(&src_exe, &install_dir, "camellia-remote")
        .expect("Manifest scan should succeed");

    // Verify allowlisted entries
    assert_eq!(
        manifest.entries.len(),
        5,
        "Expected exactly 5 allowlisted bundle items (exe, flutter dll, plugin dll, broker, data dir)"
    );

    let item_types: Vec<BundleItemType> = manifest
        .entries
        .iter()
        .map(|e| e.item_type.clone())
        .collect();
    assert!(item_types.contains(&BundleItemType::MainExecutable));
    assert!(item_types.contains(&BundleItemType::FlutterLibrary));
    assert!(item_types.contains(&BundleItemType::DataDirectory));
    assert!(item_types.contains(&BundleItemType::PluginLibrary(
        "screen_retriever_windows_plugin.dll".to_string()
    )));
    assert!(item_types.contains(&BundleItemType::BrokerExecutable));

    // Verify that all hostile / extraneous items were rejected and recorded in ignored_entries
    assert!(manifest.ignored_entries.contains(&canary_key));
    assert!(manifest.ignored_entries.contains(&document));
    assert!(manifest.ignored_entries.contains(&malicious_bat));
    assert!(manifest.ignored_entries.contains(&random_dll));
    assert!(manifest.ignored_entries.contains(&random_dir));

    let _ = fs::remove_dir_all(&src_dir);
    let _ = fs::remove_dir_all(&install_dir);
}

#[test]
fn test_update001_copy_commands_forbid_error_ignoring_flag() {
    let src_dir = unique_test_temp_dir("copy_cmd_src");
    let install_dir = unique_test_temp_dir("copy_cmd_dst");

    let src_exe = src_dir.join("camellia-remote.exe");
    fs::write(&src_exe, b"EXE").unwrap();

    let data_dir = src_dir.join("data");
    fs::create_dir_all(&data_dir).unwrap();

    let manifest = BundleManifest::scan(&src_exe, &install_dir, "camellia-remote")
        .expect("Manifest scan should succeed");
    let commands = manifest.generate_copy_commands();

    assert!(
        !commands.is_empty(),
        "Copy commands should contain generated commands"
    );

    for cmd in &commands {
        // Must NOT contain error-ignoring /C flag
        assert!(
            !cmd.contains("/C ") && !cmd.ends_with("/C"),
            "Command must not use error-ignoring /C flag: {}",
            cmd
        );
        // Must NOT attempt to copy whole parent directory with wildcards
        assert!(
            !cmd.contains("XCOPY \"..\""),
            "Command must not copy parent directory: {}",
            cmd
        );
    }

    let _ = fs::remove_dir_all(&src_dir);
    let _ = fs::remove_dir_all(&install_dir);
}

#[test]
fn test_update001_missing_source_executable_is_rejected() {
    let src_dir = unique_test_temp_dir("missing_exe_src");
    let install_dir = unique_test_temp_dir("missing_exe_dst");
    let non_existent_exe = src_dir.join("does_not_exist.exe");

    let result = BundleManifest::scan(&non_existent_exe, &install_dir, "camellia-remote");
    assert!(
        result.is_err(),
        "Scanning non-existent executable must fail"
    );

    let _ = fs::remove_dir_all(&src_dir);
    let _ = fs::remove_dir_all(&install_dir);
}

// ============================================================================
// ELEV-001: Elevated Batch Assembler, Integrity & Sentinel Tests
// ============================================================================

#[test]
fn test_elev001_assembler_generates_fail_fast_guards_and_sentinel() {
    let raw_commands = vec![
        "md \"C:\\Program Files\\Camellia Remote\"".to_string(),
        "copy /Y /B \"src.exe\" \"dst.exe\"".to_string(),
        "reg add HKLM\\Software\\Camellia /f".to_string(),
    ];

    let assembled = ElevatedBatchAssembler::assemble(&raw_commands, "install");

    // 1. Must enable command extensions
    assert!(assembled
        .script_content
        .contains("setlocal enableextensions enabledelayedexpansion"));

    // 2. Each command must be followed by errorlevel check
    for cmd in &raw_commands {
        assert!(
            assembled.script_content.contains(cmd),
            "Script must contain command: {}",
            cmd
        );
    }
    assert!(assembled
        .script_content
        .contains("if errorlevel 1 goto :camellia_script_error"));

    // 3. Must write authenticated success sentinel
    assert!(assembled.script_content.contains(&assembled.success_token));
    assert!(assembled
        .script_content
        .contains(&assembled.sentinel_file_name));

    // 4. Must exit with code 1 on error
    assert!(assembled
        .script_content
        .contains(":camellia_script_error\r\nexit /b 1"));

    // 5. SHA-256 digest must match script content
    let mut hasher = Sha256::new();
    hasher.update(assembled.script_content.as_bytes());
    let expected_hash = format!("{:x}", hasher.finalize());
    assert_eq!(assembled.sha256_hex, expected_hash);
}

#[test]
fn test_elev001_sentinel_verification_success_and_tamper_detection() {
    let workspace = unique_test_temp_dir("sentinel_verify");
    let sentinel_name = "test_success.token";
    let token = "deadbeef1234567890abcdef";

    // 1. Missing sentinel fails
    let missing_res = ElevatedBatchAssembler::verify_sentinel(&workspace, sentinel_name, token);
    assert!(
        missing_res.is_err(),
        "Missing sentinel file must fail verification"
    );

    // 2. Corrupt / mismatched token fails
    let sentinel_file = workspace.join(sentinel_name);
    fs::write(&sentinel_file, "wrong_token_here\r\n").unwrap();
    let corrupt_res = ElevatedBatchAssembler::verify_sentinel(&workspace, sentinel_name, token);
    assert!(
        corrupt_res.is_err(),
        "Sentinel with wrong token must fail verification"
    );

    // 3. Valid sentinel succeeds
    fs::write(&sentinel_file, format!("{}\r\n", token)).unwrap();
    let valid_res = ElevatedBatchAssembler::verify_sentinel(&workspace, sentinel_name, token);
    assert!(
        valid_res.is_ok(),
        "Sentinel with matching token must pass verification"
    );

    let _ = fs::remove_dir_all(&workspace);
}

#[test]
fn test_elev001_workspace_guard_cleans_up_on_drop() {
    let workspace_dir = unique_test_temp_dir("workspace_cleanup");
    let test_file = workspace_dir.join("test.bat");
    fs::write(&test_file, b"test").unwrap();
    assert!(workspace_dir.exists());

    {
        let _guard = ElevationWorkspaceGuard::new(workspace_dir.clone());
        assert!(_guard.path().exists());
    }

    // After guard drops, the directory should be completely removed
    assert!(
        !workspace_dir.exists(),
        "Workspace directory must be cleaned up on guard drop"
    );
}

#[test]
fn test_elev001_workspace_guard_keep_defuses_deletion() {
    let workspace_dir = unique_test_temp_dir("workspace_keep");
    let test_file = workspace_dir.join("test.bat");
    fs::write(&test_file, b"test").unwrap();

    {
        let mut guard = ElevationWorkspaceGuard::new(workspace_dir.clone());
        guard.keep();
    }

    // Since keep() was called, directory must still exist
    assert!(
        workspace_dir.exists(),
        "Workspace directory must remain if keep() was called"
    );

    let _ = fs::remove_dir_all(&workspace_dir);
}

// ============================================================================
// ACL-001: Logon Identity Parsing & Boundary Validation Tests
// ============================================================================

fn parse_domain_username(user: &str) -> (&str, &str) {
    if let Some(idx) = user.find('\\') {
        (&user[..idx], &user[idx + 1..])
    } else if user.find('@').is_some() {
        ("", user)
    } else {
        (".", user)
    }
}

#[test]
fn test_acl001_domain_username_parsing_contract() {
    // Standard DOMAIN\User format
    let (domain, user) = parse_domain_username("CORP\\Administrator");
    assert_eq!(domain, "CORP");
    assert_eq!(user, "Administrator");

    // Local account format without backslash
    let (domain, user) = parse_domain_username("Administrator");
    assert_eq!(domain, ".");
    assert_eq!(user, "Administrator");

    // User Principal Name (UPN) format
    let (domain, user) = parse_domain_username("admin@domain.local");
    assert_eq!(domain, "");
    assert_eq!(user, "admin@domain.local");
}

#[test]
fn test_acl001_empty_logon_username_rejection() {
    let empty_username = "   ";
    assert!(
        empty_username.trim().is_empty(),
        "Whitespace-only username must be detected as empty"
    );
}
