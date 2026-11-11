//! Integration and contract tests for Batch 62:
//! COMPAT-001 — Client 默认公开 Change ID 但当前 Remote Server 明确拒绝全部改 ID 请求.

#![deny(warnings)]

use camellia_remote_protocol::tokio;
use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_compat001_common_is_change_id_disabled_default() {
    // By default, without explicit 'N' configuration, change ID must be disabled
    assert!(
        camellia_remote::common::is_change_id_disabled(),
        "Change ID must be disabled by default"
    );

    // Option value must default to "Y"
    let default_val = camellia_remote::common::get_builtin_option(
        camellia_remote_protocol::config::keys::OPTION_DISABLE_CHANGE_ID,
    );
    assert_eq!(
        default_val, "Y",
        "keys::OPTION_DISABLE_CHANGE_ID must return 'Y' by default"
    );

    // ui_interface re-export must match
    assert!(
        camellia_remote::ui_interface::is_change_id_disabled(),
        "ui_interface::is_change_id_disabled must return true by default"
    );
}

#[test]
fn test_compat001_ui_interface_fail_fast_without_thread_or_sentinel() {
    // When change ID is disabled, calling change_id() must immediately set status to "server_not_support"
    // and must NOT leave the initial polling sentinel " " or spawn long-running network workers.
    camellia_remote::ui_interface::change_id("target-device-id".to_string());

    let status = camellia_remote::ui_interface::get_async_job_status();
    assert_eq!(
        status, "server_not_support",
        "Async job status must immediately be 'server_not_support' without lingering polling state"
    );
}

#[tokio::test]
async fn test_compat001_change_id_shared_fails_fast_on_disabled() {
    // change_id_shared_ must fail fast and return "server_not_support" immediately
    let res = camellia_remote::ui_interface::change_id_shared_(
        "valid-new-id".to_string(),
        "old-id".to_string(),
    )
    .await;

    assert_eq!(
        res, "server_not_support",
        "change_id_shared_ must return 'server_not_support' when change ID is disabled"
    );
}

#[test]
fn test_compat001_core_main_cli_fail_fast_contract() {
    let client_root = get_client_root();
    let core_main_path = client_root.join("src").join("core_main.rs");
    let content = fs::read_to_string(&core_main_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", core_main_path.display(), e));

    let cli_target = "Changing device ID is not supported by the remote rendezvous server";
    assert!(
        content.contains(cli_target),
        "core_main.rs must contain the exact fail-fast error message for --set-id"
    );

    assert!(
        content.contains("crate::common::is_change_id_disabled()"),
        "core_main.rs must check crate::common::is_change_id_disabled() for --set-id"
    );
}

#[test]
fn test_compat001_source_invariants_and_guard_contracts() {
    let client_root = get_client_root();

    // 1. common.rs
    let common_path = client_root.join("src").join("common.rs");
    let common_content = fs::read_to_string(&common_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", common_path.display(), e));
    assert!(
        common_content.contains("OPTION_DISABLE_CHANGE_ID"),
        "common.rs must handle OPTION_DISABLE_CHANGE_ID"
    );
    assert!(
        common_content.contains("pub fn is_change_id_disabled() -> bool"),
        "common.rs must export is_change_id_disabled"
    );

    // 2. ui_interface.rs
    let ui_path = client_root.join("src").join("ui_interface.rs");
    let ui_content = fs::read_to_string(&ui_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", ui_path.display(), e));
    assert!(
        ui_content.contains("crate::common::is_change_id_disabled()"),
        "ui_interface.rs must check is_change_id_disabled"
    );
    assert!(
        ui_content
            .contains("*ASYNC_JOB_STATUS.lock().unwrap() = \"server_not_support\".to_string();"),
        "ui_interface.rs must set status to server_not_support on disabled"
    );

    // 3. flutter common.dart
    let flutter_common_path = client_root.join("flutter").join("lib").join("common.dart");
    let flutter_common_content = fs::read_to_string(&flutter_common_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", flutter_common_path.display(), e));
    assert!(
        flutter_common_content.contains("bool isChangeIdDisabled()"),
        "common.dart must define isChangeIdDisabled()"
    );
    assert!(
        flutter_common_content.contains("opt != 'N'"),
        "isChangeIdDisabled must only enable when explicitly 'N'"
    );

    // 4. ipc.rs guards id write against disabled capability
    let ipc_path = client_root.join("src").join("ipc.rs");
    let ipc_content = fs::read_to_string(&ipc_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", ipc_path.display(), e));
    let some_val_idx = ipc_content
        .find("Some(value) => {")
        .expect("ipc Some(value) arm");
    let id_write_idx = ipc_content[some_val_idx..]
        .find("if name == \"id\"")
        .expect("ipc name == id write arm");
    let id_block = &ipc_content[some_val_idx + id_write_idx..some_val_idx + id_write_idx + 400];
    assert!(
        id_block.contains("crate::common::is_change_id_disabled()"),
        "ipc.rs must check is_change_id_disabled on id write"
    );
}
