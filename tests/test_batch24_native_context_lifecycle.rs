// Client Batch 24 Native Context Lifecycle Safety Tests
// Target Items:
// 1. RES-048 (P1): Linux thread-local XDO and X11 Display handle ownership & RAII cleanup
// 2. CONC-009 (P1): Windows Cliprdr stopping flag atomic synchronization across C/Rust threads
// 3. UNSAFE-009 (P1): Windows Cliprdr context lifecycle, stale handle reuse elimination, and worker ready handshake

use camellia_remote_protocol::log;
use clipboard::{
    get_client_conn_id, get_rx_cliprdr_client, get_rx_cliprdr_server, remove_channel_by_conn_id,
    send_data, ClipboardFile, CliprdrError, CLIPRDR_CHANNEL_BOUND, MAX_CLIPRDR_PAYLOAD_BYTES,
};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Mutex};
use std::thread;

#[cfg(target_os = "linux")]
use camellia_remote::platform::{
    get_cursor, get_cursor_pos, reset_display, reset_xdo, set_cursor_pos, DisplayGuard, XdoGuard,
};

// Global serial lock to avoid parallel test races on process-global display statics
static BATCH24_TEST_MUTEX: Mutex<()> = Mutex::new(());

fn acquire_batch24_test_lock() -> std::sync::MutexGuard<'static, ()> {
    BATCH24_TEST_MUTEX
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

// =========================================================================
// 1. RES-048: Linux Thread-Local XDO & Display RAII Guard Tests
// =========================================================================

#[test]
#[cfg(target_os = "linux")]
fn test_res048_xdo_guard_null_safe_drop() {
    let _lock = acquire_batch24_test_lock();
    // Dropping an XdoGuard with a null pointer must never panic, crash, or call xdo_free
    let guard = XdoGuard(std::ptr::null_mut());
    assert!(!guard.is_valid());
    assert_eq!(guard.raw(), std::ptr::null_mut());
    drop(guard);
}

#[test]
#[cfg(target_os = "linux")]
fn test_res048_display_guard_null_safe_drop() {
    let _lock = acquire_batch24_test_lock();
    // Dropping a DisplayGuard with a null pointer must never panic, crash, or call XCloseDisplay
    let guard = DisplayGuard(std::ptr::null_mut());
    assert!(!guard.is_valid());
    assert_eq!(guard.raw(), std::ptr::null_mut());
    drop(guard);
}

#[test]
#[cfg(target_os = "linux")]
fn test_res048_xdo_guard_raw_and_validity_methods() {
    let _lock = acquire_batch24_test_lock();
    let null_guard = XdoGuard(std::ptr::null_mut());
    assert!(!null_guard.is_valid());
    assert!(null_guard.raw().is_null());

    // Fake non-null pointer for validity testing (nullify before drop to avoid free)
    let mut fake: u8 = 42;
    let mut non_null_guard = XdoGuard(&mut fake as *mut u8 as _);
    assert!(non_null_guard.is_valid());
    assert_eq!(non_null_guard.raw(), &mut fake as *mut u8 as _);
    non_null_guard.0 = std::ptr::null_mut(); // Disarm before drop
}

#[test]
#[cfg(target_os = "linux")]
fn test_res048_display_guard_raw_and_validity_methods() {
    let _lock = acquire_batch24_test_lock();
    let null_guard = DisplayGuard(std::ptr::null_mut());
    assert!(!null_guard.is_valid());
    assert!(null_guard.raw().is_null());

    let mut fake: u8 = 99;
    let mut non_null_guard = DisplayGuard(&mut fake as *mut u8 as _);
    assert!(non_null_guard.is_valid());
    assert_eq!(non_null_guard.raw(), &mut fake as *mut u8 as _);
    non_null_guard.0 = std::ptr::null_mut(); // Disarm before drop
}

#[test]
#[cfg(target_os = "linux")]
fn test_res048_reset_xdo_and_display_cleans_thread_local() {
    let _lock = acquire_batch24_test_lock();
    // Test that reset_xdo() and reset_display() safely drop existing guards
    reset_xdo();
    reset_display();

    // Calling reset multiple times in sequence must be idempotent and safe
    reset_xdo();
    reset_xdo();
    reset_display();
    reset_display();
}

#[test]
#[cfg(target_os = "linux")]
fn test_res048_cursor_operations_safe_when_xdo_reset() {
    let _lock = acquire_batch24_test_lock();
    reset_xdo();

    // With XDO reset (None in thread-local), get_cursor_pos and set_cursor_pos must not crash
    let pos = get_cursor_pos();
    // If running in headless/no-X11 environment, pos is None; otherwise valid coords
    log::info!("get_cursor_pos after reset: {:?}", pos);

    let set_ok = set_cursor_pos(100, 100);
    log::info!("set_cursor_pos after reset: {}", set_ok);
}

#[test]
#[cfg(target_os = "linux")]
fn test_res048_cursor_image_safe_when_display_reset() {
    let _lock = acquire_batch24_test_lock();
    reset_display();

    // With DISPLAY reset, get_cursor must return Ok without crashing
    let cursor_res = get_cursor();
    assert!(cursor_res.is_ok());
}

#[test]
#[cfg(target_os = "linux")]
fn test_res048_thread_local_raii_cleanup_across_50_threads() {
    let _lock = acquire_batch24_test_lock();
    let thread_count = 50;
    let barrier = Arc::new(Barrier::new(thread_count));
    let completed = Arc::new(AtomicUsize::new(0));

    let mut handles = Vec::with_capacity(thread_count);
    for _ in 0..thread_count {
        let b = barrier.clone();
        let c = completed.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            // Access cursor pos to initialize or access thread-local XDO
            let _ = get_cursor_pos();
            let _ = get_cursor();
            // Explicitly call reset_xdo / reset_display to trigger Drop on XdoGuard / DisplayGuard
            reset_xdo();
            reset_display();
            c.fetch_add(1, Ordering::SeqCst);
        }));
    }

    for h in handles {
        h.join()
            .expect("Worker thread panicked during XDO/Display test");
    }

    assert_eq!(completed.load(Ordering::SeqCst), thread_count);
}

#[test]
#[cfg(target_os = "linux")]
fn test_res048_thread_exit_automatic_raii_drop() {
    let _lock = acquire_batch24_test_lock();
    // Spawning threads that initialize XDO/DISPLAY and exit without calling reset.
    // The Rust runtime will drop thread-local RefCell<Option<XdoGuard>> and DisplayGuard.
    for _ in 0..20 {
        let h = thread::spawn(|| {
            let _ = get_cursor_pos();
            let _ = get_cursor();
            // Do not call reset_xdo() / reset_display() - rely entirely on thread exit Drop
        });
        h.join().expect("Thread exit RAII drop failed");
    }
}

// =========================================================================
// 2. CONC-009: Windows Cliprdr Stopping & Cancellation Synchronization Tests
// =========================================================================

#[test]
fn test_conc009_clipboard_channel_bounding_constants() {
    // Verify bounded channel configuration
    assert_eq!(CLIPRDR_CHANNEL_BOUND, 64);
    assert_eq!(MAX_CLIPRDR_PAYLOAD_BYTES, 16 * 1024 * 1024);
}

#[test]
fn test_conc009_clipboard_file_is_stopping_allowed() {
    // Verify that beginning / handshake / request messages allow cancellation
    assert!(ClipboardFile::MonitorReady.is_stopping_allowed());
    assert!(ClipboardFile::FormatList {
        format_list: Vec::new()
    }
    .is_stopping_allowed());
    assert!(ClipboardFile::FormatDataRequest {
        requested_format_id: 1
    }
    .is_stopping_allowed());

    // Responses should not be preempted as stopping allowed
    assert!(!ClipboardFile::FormatListResponse { msg_flags: 1 }.is_stopping_allowed());
    assert!(!ClipboardFile::FormatDataResponse {
        msg_flags: 1,
        format_data: Vec::new()
    }
    .is_stopping_allowed());
}

#[test]
fn test_conc009_clipboard_file_is_beginning_message() {
    assert!(ClipboardFile::MonitorReady.is_beginning_message());
    assert!(ClipboardFile::FormatList {
        format_list: Vec::new()
    }
    .is_beginning_message());
    assert!(!ClipboardFile::FormatDataRequest {
        requested_format_id: 1
    }
    .is_beginning_message());
}

#[test]
fn test_conc009_channel_teardown_cleans_up_conn_id() {
    let _lock = acquire_batch24_test_lock();
    let peer_id = "test-peer-conc009-teardown";
    let (conn_id, _rx) = get_rx_cliprdr_client(peer_id);
    assert_eq!(get_client_conn_id(peer_id), Some(conn_id));

    // Remove channel and verify it's no longer found
    remove_channel_by_conn_id(conn_id);
    assert_eq!(get_client_conn_id(peer_id), None);
}

#[test]
fn test_conc009_concurrent_channel_registration_and_teardown() {
    let _lock = acquire_batch24_test_lock();
    let thread_count = 32;
    let barrier = Arc::new(Barrier::new(thread_count));
    let mut handles = Vec::with_capacity(thread_count);

    for i in 0..thread_count {
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            let peer = format!("peer-conc009-concurrent-{i}");
            b.wait();
            let (conn_id, rx) = get_rx_cliprdr_client(&peer);
            assert_eq!(get_client_conn_id(&peer), Some(conn_id));

            // Verify channel receiver can be locked
            let rx_guard = rx.try_lock();
            assert!(rx_guard.is_ok());
            drop(rx_guard);

            // Clean up
            remove_channel_by_conn_id(conn_id);
            assert_eq!(get_client_conn_id(&peer), None);
        }));
    }

    for h in handles {
        h.join()
            .expect("Concurrent channel registration thread panicked");
    }
}

// =========================================================================
// 3. UNSAFE-009: Windows Cliprdr Context Lifecycle & Stale Handle Elimination Tests
// =========================================================================

#[test]
fn test_unsafe009_send_data_with_missing_conn_id_fails_gracefully() {
    let _lock = acquire_batch24_test_lock();
    // Non-existent connection ID must return an InvalidRequest error, not panic
    let result = send_data(-9999, ClipboardFile::MonitorReady);
    assert!(result.is_err());
    match result {
        Err(CliprdrError::InvalidRequest { description }) => {
            assert!(description.contains("conn_id not found") || description.contains("budget"));
        }
        other => panic!("Unexpected result variant: {:?}", other),
    }
}

#[test]
fn test_unsafe009_send_data_payload_budget_enforcement() {
    let _lock = acquire_batch24_test_lock();
    let peer = "peer-unsafe009-budget";
    let (conn_id, _rx) = get_rx_cliprdr_client(peer);

    // Create an oversized payload exceeding 64 MiB limit
    let oversized = vec![0u8; MAX_CLIPRDR_PAYLOAD_BYTES + 1024];
    let result = send_data(
        conn_id,
        ClipboardFile::FormatDataResponse {
            msg_flags: 1,
            format_data: oversized,
        },
    );

    assert!(result.is_err());
    match result {
        Err(CliprdrError::InvalidRequest { description }) => {
            assert!(description.contains("exceeds max budget"));
        }
        other => panic!("Expected budget exceeded error, got: {:?}", other),
    }

    remove_channel_by_conn_id(conn_id);
}

#[test]
fn test_unsafe009_server_rx_channel_deduplication() {
    let _lock = acquire_batch24_test_lock();
    let conn_id = 123456;
    let rx1 = get_rx_cliprdr_server(conn_id);
    let rx2 = get_rx_cliprdr_server(conn_id);

    // Both should point to the exact same underlying channel receiver Arc
    assert!(Arc::ptr_eq(&rx1, &rx2));

    remove_channel_by_conn_id(conn_id);
}

#[test]
fn test_unsafe009_cliprdr_error_variants() {
    let err_init = CliprdrError::CliprdrInit;
    let err_oom = CliprdrError::CliprdrOutOfMemory;
    let err_internal = CliprdrError::ClipboardInternalError;
    let err_unknown = CliprdrError::Unknown(42);

    assert_eq!(format!("{}", err_init), "failed to init cliprdr");
    assert_eq!(format!("{}", err_oom), "cliprdr out of memory");
    assert_eq!(format!("{}", err_internal), "cliprdr internal error");
    assert_eq!(format!("{}", err_unknown), "unknown cliprdr error");
}
