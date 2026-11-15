//! Batch 81 Integration and Defensive Verification Tests:
//! INIT-001: Flutter native initialization staged transactions and rollback
//! NAV-001: Mobile File Manager back navigation and route pop resilience

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_workspace_client_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_init001_native_model_staged_startup_contracts() {
    let client_dir = get_workspace_client_dir();
    let native_model_path = client_dir.join("flutter/lib/models/native_model.dart");
    assert!(
        native_model_path.exists(),
        "flutter/lib/models/native_model.dart must exist"
    );

    let content = fs::read_to_string(&native_model_path)
        .expect("Failed to read native_model.dart");

    // 1. Verify StartupStage enum definitions
    assert!(
        content.contains("enum StartupStage"),
        "native_model.dart must define enum StartupStage"
    );
    assert!(
        content.contains("uninitialized,"),
        "StartupStage must include uninitialized"
    );
    assert!(
        content.contains("libraryLoaded,"),
        "StartupStage must include libraryLoaded"
    );
    assert!(
        content.contains("bridgeInitialized,"),
        "StartupStage must include bridgeInitialized"
    );
    assert!(
        content.contains("eventListenerStarted,"),
        "StartupStage must include eventListenerStarted"
    );
    assert!(
        content.contains("deviceConfigured,"),
        "StartupStage must include deviceConfigured"
    );
    assert!(
        content.contains("fullyInitialized,"),
        "StartupStage must include fullyInitialized"
    );
    assert!(
        content.contains("failed,"),
        "StartupStage must include failed"
    );

    // 2. Verify StartupResult class
    assert!(
        content.contains("class StartupResult"),
        "native_model.dart must define class StartupResult"
    );
    assert!(
        content.contains("final bool isSuccess;"),
        "StartupResult must declare isSuccess"
    );
    assert!(
        content.contains("final StartupStage stage;"),
        "StartupResult must declare stage"
    );

    // 3. Verify typed init return and rollback methods
    assert!(
        content.contains("Future<StartupResult> init(String appType)"),
        "PlatformFFI.init must return Future<StartupResult>"
    );
    assert!(
        content.contains("void rollback(StartupStage failedAt)"),
        "PlatformFFI must provide explicit rollback method"
    );
    assert!(
        content.contains("void resetForRetry()"),
        "PlatformFFI must provide explicit resetForRetry method"
    );
}

#[test]
fn test_init001_main_dart_fail_closed_startup_contracts() {
    let client_dir = get_workspace_client_dir();
    let main_path = client_dir.join("flutter/lib/main.dart");
    assert!(main_path.exists(), "flutter/lib/main.dart must exist");

    let content = fs::read_to_string(&main_path).expect("Failed to read main.dart");

    assert!(
        content.contains("Future<StartupResult> initEnv(String appType)"),
        "main.dart must declare Future<StartupResult> initEnv"
    );
    assert!(
        content.contains("if (!result.isSuccess)"),
        "initEnv must evaluate result.isSuccess"
    );
    assert!(
        content.contains("if (!startupResult.isSuccess)"),
        "runMainApp must fail closed if startupResult is not success"
    );
}

#[test]
fn test_nav001_file_model_and_page_back_contracts() {
    let client_dir = get_workspace_client_dir();
    let file_model_path = client_dir.join("flutter/lib/models/file_model.dart");
    let file_page_path = client_dir.join("flutter/lib/mobile/pages/file_manager_page.dart");

    assert!(file_model_path.exists(), "file_model.dart must exist");
    assert!(file_page_path.exists(), "file_manager_page.dart must exist");

    let model_content = fs::read_to_string(&file_model_path)
        .expect("Failed to read file_model.dart");
    let page_content = fs::read_to_string(&file_page_path)
        .expect("Failed to read file_manager_page.dart");

    // Verify FileController canGoBack and bool goBack()
    assert!(
        model_content.contains("bool get canGoBack => history.isNotEmpty;"),
        "FileController must define canGoBack getter based on history"
    );
    assert!(
        model_content.contains("bool goBack()"),
        "FileController.goBack must return bool indicating navigation success"
    );
    assert!(
        model_content.contains("if (history.isEmpty) return false;"),
        "FileController.goBack must return false when history is empty"
    );

    // Verify PopScope and root back pop handling
    assert!(
        page_content.contains("PopScope("),
        "file_manager_page.dart must use PopScope instead of deprecated WillPopScope"
    );
    assert!(
        !page_content.contains("WillPopScope("),
        "file_manager_page.dart must not contain WillPopScope"
    );
    assert!(
        page_content.contains("if (currentFileController.canGoBack)"),
        "file_manager_page must check currentFileController.canGoBack"
    );
    assert!(
        page_content.contains("clientClose(gFFI.sessionId, gFFI)"),
        "file_manager_page must invoke clientClose on empty history root back"
    );
}
