#![deny(warnings)]

use std::fs;
use std::path::PathBuf;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_platform008_host_channel_null_and_bounds_contracts() {
    let client_root = get_client_root();
    let flutter_window_path = client_root
        .join("flutter")
        .join("windows")
        .join("runner")
        .join("flutter_window.cpp");

    let content = fs::read_to_string(&flutter_window_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", flutter_window_path.display(), e));

    assert!(
        content.contains("arguments == nullptr"),
        "flutter_window.cpp must check arguments for nullptr"
    );
    assert!(
        content.contains("kMaxCoordDelta"),
        "flutter_window.cpp must enforce coordinate bounds"
    );
    assert!(
        content.contains("result->NotImplemented()"),
        "flutter_window.cpp must reply NotImplemented for unknown methods"
    );
}

#[test]
fn test_platform009_startup_and_message_loop_contracts() {
    let client_root = get_client_root();
    let main_path = client_root
        .join("flutter")
        .join("windows")
        .join("runner")
        .join("main.cpp");

    let content = fs::read_to_string(&main_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", main_path.display(), e));

    assert!(
        content.contains("class ScopedComInitializer"),
        "main.cpp must encapsulate COM initialization in RAII"
    );
    assert!(
        content.contains("bRet == -1"),
        "main.cpp message loop must handle GetMessage error (-1)"
    );
}

#[test]
fn test_crash002_font_change_null_guard_contract() {
    let client_root = get_client_root();
    let flutter_window_path = client_root
        .join("flutter")
        .join("windows")
        .join("runner")
        .join("flutter_window.cpp");

    let content = fs::read_to_string(&flutter_window_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", flutter_window_path.display(), e));

    assert!(
        content.contains("flutter_controller_ && flutter_controller_->engine()"),
        "flutter_window.cpp must guard WM_FONTCHANGE with controller and engine check"
    );
}

#[test]
fn test_ipc001_copydata_bounds_and_ack_contract() {
    let client_root = get_client_root();
    let uni_links_h = client_root
        .join("flutter")
        .join("plugins")
        .join("uni_links_desktop")
        .join("windows")
        .join("include")
        .join("uni_links_desktop")
        .join("uni_links_desktop_plugin.h");

    let content = fs::read_to_string(&uni_links_h)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", uni_links_h.display(), e));

    assert!(
        content.contains("UNI_LINKS_DESKTOP_ACK"),
        "uni_links_desktop_plugin.h must define typed ACK constant"
    );
    assert!(
        content.contains("UNI_LINKS_MAX_URL_LENGTH"),
        "uni_links_desktop_plugin.h must define maximum URL length"
    );
}
