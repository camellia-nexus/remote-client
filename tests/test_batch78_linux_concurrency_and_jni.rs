//! Contract and behavioral verification tests for Batch 78 Client Hardening:
//! CONC-005: Thread-safe Wayland PipeWire GStreamer initialization
//! CONC-008: Eradicate repeated XSetErrorHandler from 33ms window focus hot path
//! FFI-001: Android JNI FFI panic shielding, clipboard bounding, and poison-safe mutex recovery

#![deny(warnings)]

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
use std::sync::{Arc, OnceLock};
use std::thread;

fn get_workspace_client_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn test_conc005_pipewire_gstreamer_initialization_contract() {
    let client_dir = get_workspace_client_dir();
    let pipewire_path = client_dir.join("libs/scrap/src/wayland/pipewire.rs");

    assert!(
        pipewire_path.exists(),
        "pipewire.rs must exist at libs/scrap/src/wayland/pipewire.rs"
    );

    let content = fs::read_to_string(&pipewire_path).expect("Failed to read pipewire.rs");

    // 1. Must eradicate static mut INIT
    assert!(
        !content.contains("static mut INIT"),
        "CONC-005 violation: static mut INIT found in pipewire.rs"
    );

    // 2. Must declare thread-safe OnceLock
    assert!(
        content.contains("static GSTREAMER_INIT: std::sync::OnceLock<Result<(), String>> = std::sync::OnceLock::new();")
            || content.contains("std::sync::OnceLock"),
        "CONC-005 violation: std::sync::OnceLock must be used for GStreamer init in pipewire.rs"
    );

    // 3. Must declare public function ensure_gstreamer_initialized
    assert!(
        content.contains("pub fn ensure_gstreamer_initialized() -> ResultType<()>"),
        "CONC-005 violation: ensure_gstreamer_initialized function must be declared"
    );

    // 4. request_remote_desktop must invoke ensure_gstreamer_initialized
    assert!(
        content.contains("ensure_gstreamer_initialized()?;"),
        "CONC-005 violation: request_remote_desktop must call ensure_gstreamer_initialized()?"
    );
}

#[test]
fn test_conc005_oncelock_concurrency_simulation() {
    static TEST_INIT: OnceLock<Result<(), String>> = OnceLock::new();

    let mut handles = Vec::new();
    for _ in 0..16 {
        handles.push(thread::spawn(|| {
            let res = TEST_INIT.get_or_init(|| Ok(()));
            assert!(res.is_ok());
        }));
    }

    for handle in handles {
        handle.join().expect("thread join failed");
    }

    assert_eq!(TEST_INIT.get(), Some(&Ok(())));
}

#[test]
fn test_conc008_x_error_handler_unified_lifecycle_contract() {
    let client_dir = get_workspace_client_dir();
    let linux_path = client_dir.join("src/platform/linux.rs");

    assert!(
        linux_path.exists(),
        "linux.rs must exist at src/platform/linux.rs"
    );

    let content = fs::read_to_string(&linux_path).expect("Failed to read linux.rs");

    // 1. Must declare process-lifetime Once initialization
    assert!(
        content.contains("UNIFIED_X_HANDLER_INIT: std::sync::Once = std::sync::Once::new();")
            || content.contains("UNIFIED_X_HANDLER_INIT: std::sync::Once"),
        "CONC-008 violation: UNIFIED_X_HANDLER_INIT Once not declared in linux.rs"
    );

    // 2. Must store previous handler for chain forwarding
    assert!(
        content.contains("PREVIOUS_X_ERROR_HANDLER"),
        "CONC-008 violation: PREVIOUS_X_ERROR_HANDLER atomic pointer missing in linux.rs"
    );

    // 3. Must define ensure_unified_x_error_handler_installed
    assert!(
        content.contains("fn ensure_unified_x_error_handler_installed()"),
        "CONC-008 violation: ensure_unified_x_error_handler_installed not defined in linux.rs"
    );

    // 4. Hot path get_focused_display must call ensure_unified_x_error_handler_installed
    assert!(
        content.contains("ensure_unified_x_error_handler_installed();"),
        "CONC-008 violation: get_focused_display must call ensure_unified_x_error_handler_installed()"
    );

    // 5. Must track display pointer and in-flight state without mutating error handler repeatedly
    assert!(
        content.contains("ACTIVE_GEOMETRY_DISPLAY"),
        "CONC-008 violation: ACTIVE_GEOMETRY_DISPLAY tracking missing"
    );
    assert!(
        content.contains("ACTIVE_GEOMETRY_IN_FLIGHT"),
        "CONC-008 violation: ACTIVE_GEOMETRY_IN_FLIGHT tracking missing"
    );
    assert!(
        content.contains("ACTIVE_GEOMETRY_BAD_WINDOW"),
        "CONC-008 violation: ACTIVE_GEOMETRY_BAD_WINDOW tracking missing"
    );
}

#[test]
fn test_conc008_geometry_error_state_machine_simulation() {
    struct MockGeometryQueryScope {
        active_display: AtomicPtr<std::ffi::c_void>,
        in_flight: AtomicBool,
        bad_window_detected: AtomicBool,
        unexpected_error_detected: AtomicBool,
        forwarded_count: AtomicBool,
    }

    impl MockGeometryQueryScope {
        fn new() -> Self {
            Self {
                active_display: AtomicPtr::new(std::ptr::null_mut()),
                in_flight: AtomicBool::new(false),
                bad_window_detected: AtomicBool::new(false),
                unexpected_error_detected: AtomicBool::new(false),
                forwarded_count: AtomicBool::new(false),
            }
        }

        fn handle_mock_error(&self, display: *mut std::ffi::c_void, error_code: u8) -> i32 {
            let active_disp = self.active_display.load(Ordering::SeqCst);
            let in_flight = self.in_flight.load(Ordering::SeqCst);

            if in_flight && !active_disp.is_null() && display == active_disp {
                if error_code == 3 {
                    // BadWindow
                    self.bad_window_detected.store(true, Ordering::SeqCst);
                    return 0;
                } else {
                    self.unexpected_error_detected.store(true, Ordering::SeqCst);
                    return 0;
                }
            }

            self.forwarded_count.store(true, Ordering::SeqCst);
            0
        }
    }

    let scope = Arc::new(MockGeometryQueryScope::new());
    let dummy_display1 = 0x1000 as *mut std::ffi::c_void;
    let dummy_display2 = 0x2000 as *mut std::ffi::c_void;

    // Case 1: Out-of-flight error -> forwarded
    scope.handle_mock_error(dummy_display1, 3);
    assert!(scope.forwarded_count.load(Ordering::SeqCst));
    assert!(!scope.bad_window_detected.load(Ordering::SeqCst));

    // Reset
    scope.forwarded_count.store(false, Ordering::SeqCst);

    // Case 2: In-flight error on matching display -> caught BadWindow
    scope.active_display.store(dummy_display1, Ordering::SeqCst);
    scope.in_flight.store(true, Ordering::SeqCst);
    scope.handle_mock_error(dummy_display1, 3);
    assert!(!scope.forwarded_count.load(Ordering::SeqCst));
    assert!(scope.bad_window_detected.load(Ordering::SeqCst));

    // Case 3: In-flight error on different display -> forwarded
    scope.handle_mock_error(dummy_display2, 3);
    assert!(scope.forwarded_count.load(Ordering::SeqCst));
}

#[test]
fn test_ffi001_android_jni_panic_and_bounds_contracts() {
    let client_dir = get_workspace_client_dir();
    let ffi_path = client_dir.join("libs/scrap/src/android/ffi.rs");

    assert!(
        ffi_path.exists(),
        "ffi.rs must exist at libs/scrap/src/android/ffi.rs"
    );

    let content = fs::read_to_string(&ffi_path).expect("Failed to read ffi.rs");

    // 1. Payload bounds
    assert!(
        content.contains("pub const MAX_CLIPBOARD_PAYLOAD_BYTES: usize = 32 * 1024 * 1024;"),
        "FFI-001 violation: MAX_CLIPBOARD_PAYLOAD_BYTES must be 32 MiB"
    );

    // 2. Safe processing function signature
    assert!(
        content
            .contains("pub fn process_clipboard_bytes(data: &[u8]) -> Result<bool, &'static str>"),
        "FFI-001 violation: process_clipboard_bytes must be declared with bounds checks"
    );

    // 3. Error variants
    assert!(content.contains("\"empty_buffer\""));
    assert!(content.contains("\"buffer_too_large\""));
    assert!(content.contains("\"invalid_protobuf\""));

    // 4. Poison-safe mutex recovery
    assert!(
        content.contains("unwrap_or_else(|p| p.into_inner())"),
        "FFI-001 violation: mutex locks must recover from poisoned states"
    );

    // 5. Catch unwind on JNI exports
    assert!(
        content.contains("std::panic::catch_unwind"),
        "FFI-001 violation: catch_unwind must be present for JNI exports"
    );
}
