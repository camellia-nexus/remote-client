//! Integration and contract tests for Batch 61:
//! LOG-001 — Rust 日志默认级别与无界/直接输出加固.

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_log001_constants_and_contract_boundaries() {
    assert_eq!(
        camellia_remote::common::DEFAULT_LOG_FILTER,
        "info,reqwest=warn,rustls=warn,webrtc-sctp=warn,webrtc=warn",
        "Default release log level must be bounded to info, not debug"
    );
    assert_eq!(
        camellia_remote::common::LOG_BUFFER_CAPACITY,
        64 * 1024,
        "Buffer capacity must be strictly 64 KiB (65536 bytes)"
    );
    assert_eq!(
        camellia_remote::common::LOG_FLUSH_INTERVAL,
        Duration::from_secs(1),
        "Flush interval must be 1 second"
    );
    assert_eq!(
        camellia_remote::common::LOG_MAX_FILE_SIZE,
        10 * 1024 * 1024,
        "Max log file size must be 10 MiB"
    );
    assert_eq!(
        camellia_remote::common::LOG_MAX_ROTATED_FILES,
        14,
        "Max rotated files must be 14"
    );

    // Bounded total log disk footprint: 14 * 10 MiB = 140 MiB
    let max_total_disk_footprint = camellia_remote::common::LOG_MAX_FILE_SIZE
        * (camellia_remote::common::LOG_MAX_ROTATED_FILES as u64);
    assert!(
        max_total_disk_footprint <= 150 * 1024 * 1024,
        "Max total disk footprint must not exceed 150 MiB"
    );

    // Safe no-op flush and handle query before initialization
    assert!(camellia_remote::common::get_logger_handle().is_none());
    camellia_remote::common::flush_log();
    camellia_remote::common::global_clean();
}

#[test]
fn test_log001_concurrent_flush_and_poison_resilience() {
    let client_root = get_client_root();
    let protocol_lib_path = client_root
        .join("libs")
        .join("camellia_remote_protocol")
        .join("src")
        .join("lib.rs");

    let content = fs::read_to_string(&protocol_lib_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", protocol_lib_path.display(), e));

    assert!(
        content.contains("unwrap_or_else(|poisoned| poisoned.into_inner())"),
        "Protocol logger handle lock must recover from poison"
    );

    // Simulate multi-threaded flush calls and poison recovery
    let poison_mutex: Arc<Mutex<Option<u32>>> = Arc::new(Mutex::new(Some(42)));
    let poison_clone = poison_mutex.clone();

    // Force poison the mutex
    let _ = thread::spawn(move || {
        let _guard = poison_clone.lock().unwrap();
        panic!("Intentional panic to poison logger mutex");
    })
    .join();

    assert!(
        poison_mutex.is_poisoned(),
        "Mutex should be poisoned for testing recovery"
    );

    // Poison recovery via into_inner()
    let recovered_val = *poison_mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    assert_eq!(
        recovered_val,
        Some(42),
        "Must recover value despite poisoned mutex"
    );

    // Concurrent stress test across 16 threads calling flush_log()
    let mut handles = Vec::new();
    for _ in 0..16 {
        handles.push(thread::spawn(|| {
            for _ in 0..100 {
                camellia_remote::common::flush_log();
            }
        }));
    }

    for handle in handles {
        handle.join().expect("Worker thread must not panic");
    }
}

#[test]
fn test_log001_source_ast_invariants() {
    let client_root = get_client_root();

    // 1. Check common.rs
    let common_rs = fs::read_to_string(client_root.join("src").join("common.rs"))
        .expect("Failed to read src/common.rs");
    assert!(
        common_rs.contains("pub const DEFAULT_LOG_FILTER"),
        "common.rs must export DEFAULT_LOG_FILTER"
    );
    assert!(
        common_rs.contains("pub fn init_log("),
        "common.rs must export init_log"
    );
    assert!(
        common_rs.contains("pub fn get_logger_handle()"),
        "common.rs must export get_logger_handle"
    );
    assert!(
        common_rs.contains("pub fn flush_log()"),
        "common.rs must export flush_log"
    );
    assert!(
        common_rs.contains("flush_log();"),
        "global_clean in common.rs must call flush_log()"
    );

    // 2. Check flutter_ffi.rs
    let flutter_ffi_rs = fs::read_to_string(client_root.join("src").join("flutter_ffi.rs"))
        .expect("Failed to read src/flutter_ffi.rs");
    assert!(
        flutter_ffi_rs.contains("crate::common::init_log(false, \"\");"),
        "flutter_ffi.rs must call crate::common::init_log"
    );
    assert!(
        flutter_ffi_rs.contains("crate::common::init_log(false, \"flutter_ffi\");"),
        "flutter_ffi.rs must call crate::common::init_log"
    );
    assert!(
        !flutter_ffi_rs.contains("eprintln!(\n            \"cannot load last transfer job"),
        "flutter_ffi.rs must not contain eprintln! in session_load_last_transfer_jobs"
    );
    assert!(
        flutter_ffi_rs.contains("log::warn!(\n            \"cannot load last transfer job"),
        "flutter_ffi.rs must use log::warn! in session_load_last_transfer_jobs"
    );

    // 3. Check service.rs & core_main.rs
    let service_rs = fs::read_to_string(client_root.join("src").join("service.rs"))
        .expect("Failed to read src/service.rs");
    assert!(
        service_rs.contains("crate::common::init_log(false, \"service\");"),
        "service.rs must call crate::common::init_log"
    );

    let core_main_rs = fs::read_to_string(client_root.join("src").join("core_main.rs"))
        .expect("Failed to read src/core_main.rs");
    assert!(
        core_main_rs.contains("crate::common::init_log(false, &log_name);"),
        "core_main.rs must call crate::common::init_log"
    );

    // 4. Check flutter.rs hot path print elimination
    let flutter_rs = fs::read_to_string(client_root.join("src").join("flutter.rs"))
        .expect("Failed to read src/flutter.rs");
    assert!(
        !flutter_rs.contains("println!(\n                    \"Push event {} failed."),
        "flutter.rs push_global_event must not use println!"
    );
    assert!(
        flutter_rs.contains("log::debug!(\n                    \"Push event {} failed."),
        "flutter.rs push_global_event must use log::debug!"
    );

    // 5. Check portable_service.rs hot path print elimination
    let portable_rs = fs::read_to_string(
        client_root
            .join("src")
            .join("server")
            .join("portable_service.rs"),
    )
    .expect("Failed to read src/server/portable_service.rs");
    assert!(
        !portable_rs.contains("println!(\"unreachable!\");"),
        "portable_service.rs must not use println!(\"unreachable!\")"
    );
    assert!(
        portable_rs.contains("log::warn!(\"unreachable portable service event\");"),
        "portable_service.rs must use log::warn!"
    );

    // 6. Check windows.rs SendMessageW hot path print elimination
    let windows_rs =
        fs::read_to_string(client_root.join("src").join("platform").join("windows.rs"))
            .expect("Failed to read src/platform/windows.rs");
    assert!(
        !windows_rs.contains("println!(\"send {:?}\", data_zero);"),
        "windows.rs must not use println! before SendMessageW"
    );
    assert!(
        windows_rs.contains("log::debug!(\"send {:?}\", data_zero);"),
        "windows.rs must use log::debug! before SendMessageW"
    );
    assert!(
        !windows_rs
            .contains("eprintln!(\"SetDllDirectoryW failed: {}\", io::Error::last_os_error());"),
        "windows.rs must not use eprintln! for SetDllDirectoryW failure"
    );
    assert!(
        windows_rs
            .contains("log::error!(\"SetDllDirectoryW failed: {}\", io::Error::last_os_error());"),
        "windows.rs must use log::error! for SetDllDirectoryW failure"
    );
    assert!(
        !windows_rs.contains("eprintln!(\"CString::new failed: {}\", e);"),
        "windows.rs must not use eprintln! for CString::new failure"
    );
    assert!(
        windows_rs.contains("log::error!(\"CString::new failed: {}\", e);"),
        "windows.rs must use log::error! for CString::new failure"
    );

    // 7. Check linux.rs & macos.rs Ctrl-C error logging
    let linux_rs = fs::read_to_string(client_root.join("src").join("platform").join("linux.rs"))
        .expect("Failed to read src/platform/linux.rs");
    assert!(
        !linux_rs.contains("println!(\"Failed to set Ctrl-C handler: {}\", err);"),
        "linux.rs must not use println! for Ctrl-C handler error"
    );
    assert!(
        linux_rs.contains("log::error!(\"Failed to set Ctrl-C handler: {}\", err);"),
        "linux.rs must use log::error! for Ctrl-C handler error"
    );

    let macos_rs = fs::read_to_string(client_root.join("src").join("platform").join("macos.rs"))
        .expect("Failed to read src/platform/macos.rs");
    assert!(
        !macos_rs.contains("println!(\"Failed to set Ctrl-C handler: {}\", err);"),
        "macos.rs must not use println! for Ctrl-C handler error"
    );
    assert!(
        macos_rs.contains("log::error!(\"Failed to set Ctrl-C handler: {}\", err);"),
        "macos.rs must use log::error! for Ctrl-C handler error"
    );
    assert!(
        !macos_rs.contains("println!(\"Starting update from DMG: {}\", dmg_path);"),
        "macos.rs update_from_dmg must not use println!"
    );
    assert!(
        macos_rs.contains("log::info!(\"Starting update from DMG: {}\", dmg_path);"),
        "macos.rs update_from_dmg must use log::info!"
    );
}
