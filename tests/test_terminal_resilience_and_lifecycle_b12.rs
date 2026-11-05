#![cfg(not(any(target_os = "android", target_os = "ios")))]

use camellia_remote::server::terminal_service::{
    get_or_create_service, get_terminal_session_count, list_services, remove_service, OutputBuffer,
    TerminalServiceProxy, MAX_OUTPUT_BUFFER_SIZE, MAX_SERVICES,
};
use camellia_remote_protocol::message_proto::{
    terminal_action, CloseTerminal, ResizeTerminal, TerminalAction, TerminalData,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

static TEST_REGISTRY_MUTEX: Mutex<()> = Mutex::new(());

// ============================================================================
// RES-022 Tests: OutputBuffer Strict Byte Bounding and Invariant Checks
// ============================================================================

#[test]
fn test_res022_output_buffer_without_newlines_enforces_byte_bound() {
    let mut buffer = OutputBuffer::new();

    // Stream 4 MiB of continuous ASCII without any newlines
    let large_chunk = vec![b'a'; 4 * 1024 * 1024];
    buffer.append(&large_chunk);

    assert!(
        buffer.total_size() <= MAX_OUTPUT_BUFFER_SIZE,
        "RES-022: buffer.total_size ({}) must not exceed MAX_OUTPUT_BUFFER_SIZE ({})",
        buffer.total_size(),
        MAX_OUTPUT_BUFFER_SIZE
    );
    assert!(buffer.total_size() > 0, "Buffer should not be empty");

    // Replay buffer must return exactly the requested recent bytes
    let recent = buffer.get_recent(8192);
    assert_eq!(recent.len(), 8192);
    assert!(recent.iter().all(|&b| b == b'a'));
}

#[test]
fn test_res022_output_buffer_many_incomplete_chunks_maintain_exact_size() {
    let mut buffer = OutputBuffer::new();

    buffer.append(b"prefix_without_newline_");

    // Append 500 chunks of 4 KiB without any newlines
    let chunk = vec![b'k'; 4096];
    for _ in 0..500 {
        buffer.append(&chunk);
        assert!(buffer.total_size() <= MAX_OUTPUT_BUFFER_SIZE);
    }

    assert!(
        buffer.total_size() <= MAX_OUTPUT_BUFFER_SIZE,
        "Buffer size {} must be bounded by {}",
        buffer.total_size(),
        MAX_OUTPUT_BUFFER_SIZE
    );

    // Verify recent retrieval works and doesn't panic, bounded by requested max_bytes
    let recent = buffer.get_recent(16384);
    assert!(recent.len() <= 16384 && !recent.is_empty());
    assert!(recent.iter().all(|&b| b == b'k'));
}

#[test]
fn test_res022_output_buffer_mixed_newlines_and_giant_chunks() {
    let mut buffer = OutputBuffer::new();

    for i in 0..20 {
        if i % 2 == 0 {
            // Giant chunk without newlines
            let chunk = vec![b'A' + (i as u8 % 26); 128 * 1024];
            buffer.append(&chunk);
        } else {
            // Multiple short lines
            let text = b"line 1\nline 2\nline 3\n";
            buffer.append(text);
        }
        assert!(buffer.total_size() <= MAX_OUTPUT_BUFFER_SIZE);
    }

    assert!(buffer.total_size() <= MAX_OUTPUT_BUFFER_SIZE);
    assert!(buffer.line_count() <= 10000);
}

// ============================================================================
// RES-020 Tests: Session and Service Limit Hardening
// ============================================================================

#[test]
fn test_res020_service_limits_and_session_count_accuracy() {
    let _lock = TEST_REGISTRY_MUTEX.lock().unwrap();
    let test_svc_id = format!("test_res020_svc_{}", uuid::Uuid::new_v4());

    // Create service
    let svc = get_or_create_service(test_svc_id.clone(), false, false)
        .expect("get_or_create_service should succeed");

    // Initially 0 sessions in this service
    assert_eq!(svc.lock().unwrap().list_terminals().len(), 0);

    let count_before = get_terminal_session_count(false);

    // Verify list_services includes our test service
    let services = list_services();
    assert!(services.iter().any(|s| s.service_id == test_svc_id));

    // Cleanup
    remove_service(&test_svc_id);
    let count_after = get_terminal_session_count(false);
    assert_eq!(count_before, count_after);
}

#[test]
fn test_res020_max_services_limit_rejection() {
    let _lock = TEST_REGISTRY_MUTEX.lock().unwrap();
    let mut created_ids = Vec::new();

    // Create services up to MAX_SERVICES
    for i in 0..MAX_SERVICES + 5 {
        let sid = format!("limit_test_svc_{}_{}", i, uuid::Uuid::new_v4());
        match get_or_create_service(sid.clone(), false, false) {
            Ok(_) => created_ids.push(sid),
            Err(e) => {
                // Should hit the limit
                assert!(
                    e.to_string()
                        .contains("Maximum number of terminal services"),
                    "Expected max services error, got: {}",
                    e
                );
                break;
            }
        }
    }

    // Clean up created services
    for sid in created_ids {
        remove_service(&sid);
    }
}

// ============================================================================
// RES-021 Tests: Non-Blocking Actions, Clamping & Wire Payload Capping
// ============================================================================

#[test]
fn test_res021_oversized_terminal_data_does_not_panic_or_freeze() {
    let _lock = TEST_REGISTRY_MUTEX.lock().unwrap();
    let test_svc_id = format!("test_res021_svc_{}", uuid::Uuid::new_v4());
    let _svc = get_or_create_service(test_svc_id.clone(), true, false)
        .expect("Service creation must succeed");

    let mut proxy = TerminalServiceProxy::new(test_svc_id.clone(), Some(true), None);

    // Send TerminalData with payload exceeding MAX_TERMINAL_DATA_PAYLOAD (e.g. 512 KiB)
    let mut data = TerminalData::new();
    data.terminal_id = 9999; // non-existent session
    data.data = vec![b'Q'; 512 * 1024].into();

    let mut action = TerminalAction::new();
    action.union = Some(terminal_action::Union::Data(data));

    // Must handle cleanly without blocking or failing
    let res = proxy.handle_action(&action);
    assert!(res.is_ok());

    remove_service(&test_svc_id);
}

#[test]
fn test_res021_terminal_resize_extreme_dimensions_clamped() {
    let _lock = TEST_REGISTRY_MUTEX.lock().unwrap();
    let test_svc_id = format!("test_res021_resize_{}", uuid::Uuid::new_v4());
    let _svc = get_or_create_service(test_svc_id.clone(), true, false)
        .expect("Service creation must succeed");

    let mut proxy = TerminalServiceProxy::new(test_svc_id.clone(), Some(true), None);

    // Resize with 0 dimensions
    let mut resize_zero = ResizeTerminal::new();
    resize_zero.terminal_id = 9999;
    resize_zero.rows = 0;
    resize_zero.cols = 0;

    let mut action_zero = TerminalAction::new();
    action_zero.union = Some(terminal_action::Union::Resize(resize_zero));
    assert!(proxy.handle_action(&action_zero).is_ok());

    // Resize with extreme dimensions
    let mut resize_extreme = ResizeTerminal::new();
    resize_extreme.terminal_id = 9999;
    resize_extreme.rows = 65535;
    resize_extreme.cols = 65535;

    let mut action_extreme = TerminalAction::new();
    action_extreme.union = Some(terminal_action::Union::Resize(resize_extreme));
    assert!(proxy.handle_action(&action_extreme).is_ok());

    remove_service(&test_svc_id);
}

// ============================================================================
// RES-023 Tests: Teardown Sequencing, Idempotence & Lock Freedom
// ============================================================================

#[test]
fn test_res023_remove_service_does_not_deadlock_with_concurrent_lookup() {
    let _lock = TEST_REGISTRY_MUTEX.lock().unwrap();
    let test_svc_id = format!("test_res023_deadlock_{}", uuid::Uuid::new_v4());
    let _svc = get_or_create_service(test_svc_id.clone(), true, false)
        .expect("Service creation must succeed");

    let done = Arc::new(AtomicBool::new(false));
    let done_clone = done.clone();

    // Spawn concurrent thread querying services list
    let query_thread = std::thread::spawn(move || {
        while !done_clone.load(Ordering::Relaxed) {
            let _ = list_services();
            let _ = get_terminal_session_count(false);
            std::thread::sleep(Duration::from_millis(1));
        }
    });

    // Remove service while queries are actively running
    remove_service(&test_svc_id);

    done.store(true, Ordering::Relaxed);
    query_thread.join().expect("Query thread must not deadlock");
}

#[test]
fn test_res023_handle_close_non_existent_session_returns_ok_none() {
    let _lock = TEST_REGISTRY_MUTEX.lock().unwrap();
    let test_svc_id = format!("test_res023_close_{}", uuid::Uuid::new_v4());
    let _svc = get_or_create_service(test_svc_id.clone(), true, false)
        .expect("Service creation must succeed");

    let mut proxy = TerminalServiceProxy::new(test_svc_id.clone(), Some(true), None);

    let mut close = CloseTerminal::new();
    close.terminal_id = 8888; // non-existent session

    let mut action = TerminalAction::new();
    action.union = Some(terminal_action::Union::Close(close));

    let res = proxy.handle_action(&action);
    assert!(res.is_ok());
    assert!(res.unwrap().is_none());

    remove_service(&test_svc_id);
}
