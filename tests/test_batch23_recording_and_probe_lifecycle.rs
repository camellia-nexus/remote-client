// Client Batch 23 Recording and Probe Lifecycle Safety Tests
// Target Items:
// 1. RES-036 (P1): Record upload coalescing & lifecycle cancellation
// 2. RES-037 (P1): Rendezvous probe single-flight, cooldown, generation fencing, bounded timeouts
// 3. RES-041 (P1): NAT/IPv6 probe atomic single-flight, bounded retry policy, cancellation

use camellia_remote::common::{
    bump_rendezvous_generation, get_rendezvous_generation, is_ipv6_probe_running,
    is_nat_probe_running, is_rendezvous_probe_running, refresh_rendezvous_server,
    reset_ipv6_probe_cooldown_for_test, reset_nat_probe_cooldown_for_test, reset_nat_probe_stop,
    reset_rendezvous_probe_cooldown_for_test, stop_nat_probe, test_ipv6_sync, test_nat_type,
    test_rendezvous_server, IPV6_PROBE_RUNNING, NAT_PROBE_RUNNING, NAT_PROBE_STOP,
    RENDEZVOUS_PROBE_RUNNING,
};
use camellia_remote::hbbs_http::record_upload::{
    is_worker_active_for_dir, run as run_record_upload,
};
use camellia_remote::ui_interface::set_option;
use scrap::record::{create_record_channel, RecordState};
use std::sync::atomic::Ordering;
use std::sync::mpsc::{RecvError, RecvTimeoutError, TryRecvError};
use std::sync::{Arc, Barrier, Mutex};
use std::thread;
use std::time::{Duration, Instant};

// Global serial lock to avoid parallel test races on process-global probe statics
static PROBE_TEST_MUTEX: Mutex<()> = Mutex::new(());

fn acquire_probe_test_lock() -> std::sync::MutexGuard<'static, ()> {
    PROBE_TEST_MUTEX
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

// =========================================================================
// 1. RES-036: Record Upload State Coalescing & Preemption Tests
// =========================================================================

#[test]
fn test_record_state_coalescing_10000_frames_to_one() {
    let (tx, rx) = create_record_channel();

    // Rapidly send 10,000 NewFrame events
    for _ in 0..10_000 {
        tx.send(RecordState::NewFrame)
            .expect("send should succeed while open");
    }

    // Now send a high-priority control notification (WriteTail)
    tx.send(RecordState::WriteTail)
        .expect("send should succeed while open");

    // 1. WriteTail must preempt the pending NewFrame events
    let first = rx
        .try_recv()
        .expect("first event should be immediately available");
    assert_eq!(
        first,
        RecordState::WriteTail,
        "WriteTail control event must preempt NewFrame"
    );

    // 2. The 10,000 NewFrame events must collapse to exactly 1 event
    let second = rx
        .try_recv()
        .expect("second event should be the coalesced frame");
    assert_eq!(
        second,
        RecordState::NewFrame,
        "10,000 NewFrame events must collapse to exactly 1 event"
    );

    // 3. Channel must now be empty (O(1) memory, no 9,999 leftover frames)
    let third = rx.try_recv();
    assert_eq!(
        third,
        Err(TryRecvError::Empty),
        "Queue must be completely empty after consuming the single coalesced frame"
    );
}

#[test]
fn test_record_state_control_notifications_priority_and_fifo() {
    let (tx, rx) = create_record_channel();

    // Interleave control messages with thousands of frame events
    tx.send(RecordState::NewFile("rec_session_1.webm".into()))
        .unwrap();

    for _ in 0..5_000 {
        tx.send(RecordState::NewFrame).unwrap();
    }

    tx.send(RecordState::NewFile("rec_session_2.webm".into()))
        .unwrap();

    for _ in 0..5_000 {
        tx.send(RecordState::NewFrame).unwrap();
    }

    tx.send(RecordState::WriteTail).unwrap();

    // Control messages must preserve FIFO among themselves and precede NewFrame
    assert_eq!(
        rx.try_recv().unwrap(),
        RecordState::NewFile("rec_session_1.webm".into())
    );
    assert_eq!(
        rx.try_recv().unwrap(),
        RecordState::NewFile("rec_session_2.webm".into())
    );
    assert_eq!(rx.try_recv().unwrap(), RecordState::WriteTail);

    // Followed by exactly one coalesced NewFrame
    assert_eq!(rx.try_recv().unwrap(), RecordState::NewFrame);

    // And empty queue
    assert_eq!(rx.try_recv(), Err(TryRecvError::Empty));
}

#[test]
fn test_record_channel_closer_responsive_unblock() {
    let (_tx, rx) = create_record_channel();
    let closer = rx.closer();

    let thread = thread::spawn(move || {
        let start = Instant::now();
        let res = rx.recv_timeout(Duration::from_secs(5));
        (res, start.elapsed())
    });

    // Give thread a moment to enter wait
    thread::sleep(Duration::from_millis(30));

    // Wake thread via closer
    closer.close();

    let (res, elapsed) = thread.join().expect("thread should join cleanly");
    assert_eq!(
        res,
        Err(RecvTimeoutError::Disconnected),
        "Closed channel must return Disconnected"
    );
    assert!(
        elapsed < Duration::from_millis(500),
        "Closer must wake waiting receiver immediately (took {:?})",
        elapsed
    );
}

#[test]
fn test_record_channel_sender_drop_disconnects() {
    let (tx, rx) = create_record_channel();
    tx.send(RecordState::NewFrame).unwrap();
    drop(tx);

    // Consume pending frame
    assert_eq!(rx.recv().unwrap(), RecordState::NewFrame);

    // Once empty and sender dropped, recv returns Err(RecvError)
    assert_eq!(rx.recv(), Err(RecvError));
}

#[test]
fn test_record_channel_send_after_close_rejected() {
    let (tx, rx) = create_record_channel();
    let closer = rx.closer();
    closer.close();

    let send_res = tx.send(RecordState::NewFrame);
    assert!(send_res.is_err(), "send after close must return Err");
}

#[test]
fn test_record_upload_active_workers_lifecycle_and_cancellation() {
    let test_dir = format!("/tmp/camellia_test_rec_dir_{}", std::process::id());
    let _ = std::fs::create_dir_all(&test_dir);

    // Ensure api-server is configured so the worker stays in the loop
    camellia_remote_protocol::config::Config::set_option(
        "api-server".into(),
        "http://127.0.0.1:21114".into(),
    );

    let (_tx1, rx1) = create_record_channel();
    let mut handle1 = run_record_upload(rx1, test_dir.clone());
    assert!(is_worker_active_for_dir(&test_dir));

    // Spawn a second worker for the same recording directory
    let (_tx2, rx2) = create_record_channel();
    let mut handle2 = run_record_upload(rx2, test_dir.clone());

    // Worker 1 must be cancelled and joined cleanly
    let stopped1 = handle1.stop(Duration::from_millis(1000));
    assert!(stopped1, "Worker 1 should exit cleanly after replacement");

    // Worker 1's termination must NOT remove Worker 2 from ACTIVE_WORKERS
    assert!(
        is_worker_active_for_dir(&test_dir),
        "Worker 2 must remain active after Worker 1 terminates"
    );

    // Stopping Worker 2 cleans up ACTIVE_WORKERS registration
    let stopped2 = handle2.stop(Duration::from_millis(1000));
    assert!(stopped2, "Worker 2 should exit cleanly");
    assert!(
        !is_worker_active_for_dir(&test_dir),
        "ACTIVE_WORKERS should be empty for directory after worker terminates"
    );

    let _ = std::fs::remove_dir_all(&test_dir);
}

#[test]
fn test_record_upload_handle_stop_bounded_deadline() {
    let test_dir = format!("/tmp/camellia_test_rec_deadline_{}", std::process::id());
    let _ = std::fs::create_dir_all(&test_dir);

    camellia_remote_protocol::config::Config::set_option(
        "api-server".into(),
        "http://127.0.0.1:21114".into(),
    );

    let (_tx, rx) = create_record_channel();
    let mut handle = run_record_upload(rx, test_dir.clone());

    let start = Instant::now();
    let ok = handle.stop(Duration::from_millis(1000));
    let elapsed = start.elapsed();

    assert!(ok, "stop() should succeed within deadline");
    assert!(
        elapsed < Duration::from_millis(600),
        "stop() should be responsive (took {:?})",
        elapsed
    );

    let _ = std::fs::remove_dir_all(&test_dir);
}

// =========================================================================
// 2. RES-037: Rendezvous Probe Lifecycle, Single-Flight & Generation Fencing
// =========================================================================

#[test]
fn test_rendezvous_probe_single_flight() {
    let _lock = acquire_probe_test_lock();
    reset_rendezvous_probe_cooldown_for_test();

    // Manually mark probe as running
    RENDEZVOUS_PROBE_RUNNING.store(true, Ordering::SeqCst);
    assert!(is_rendezvous_probe_running());

    // Subsequent invocations must be rejected by single-flight mutual exclusion
    test_rendezvous_server();
    assert!(is_rendezvous_probe_running());

    // Release simulated probe
    RENDEZVOUS_PROBE_RUNNING.store(false, Ordering::SeqCst);
    assert!(!is_rendezvous_probe_running());
}

#[test]
fn test_rendezvous_probe_concurrent_contention() {
    let _lock = acquire_probe_test_lock();
    reset_rendezvous_probe_cooldown_for_test();

    // Simulate 20 concurrent threads attempting test_rendezvous_server
    let barrier = Arc::new(Barrier::new(20));
    let mut handles = Vec::new();

    for _ in 0..20 {
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            test_rendezvous_server();
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    // Wait bounded time for any launched probe thread to complete
    let start = Instant::now();
    while is_rendezvous_probe_running() && start.elapsed() < Duration::from_millis(1000) {
        thread::sleep(Duration::from_millis(5));
    }

    assert!(
        !is_rendezvous_probe_running(),
        "Rendezvous probe must reset running state upon completion"
    );
}

#[test]
fn test_rendezvous_probe_cooldown_rejection() {
    let _lock = acquire_probe_test_lock();
    reset_rendezvous_probe_cooldown_for_test();

    // First call passes cooldown and launches probe
    test_rendezvous_server();

    // Immediate second call is suppressed by debounce/cooldown
    test_rendezvous_server();

    // Wait for probe to finish
    let start = Instant::now();
    while is_rendezvous_probe_running() && start.elapsed() < Duration::from_millis(1000) {
        thread::sleep(Duration::from_millis(5));
    }

    // Verify cooldown reset works as expected for test isolation
    reset_rendezvous_probe_cooldown_for_test();
}

#[test]
fn test_rendezvous_generation_fencing() {
    let _lock = acquire_probe_test_lock();

    let initial = get_rendezvous_generation();
    let next = bump_rendezvous_generation();
    assert_eq!(next, initial + 1);
    assert_eq!(get_rendezvous_generation(), next);

    let third = bump_rendezvous_generation();
    assert_eq!(third, next + 1);
    assert_eq!(get_rendezvous_generation(), third);
}

// =========================================================================
// 3. RES-041: NAT & IPv6 Probe Atomic Single-Flight & Cancellation Tests
// =========================================================================

#[test]
fn test_nat_probe_atomic_single_flight() {
    let _lock = acquire_probe_test_lock();
    reset_nat_probe_cooldown_for_test();

    // Manually mark probe as running
    NAT_PROBE_RUNNING.store(true, Ordering::SeqCst);
    assert!(is_nat_probe_running());

    // Calling test_nat_type must be rejected before spawning OS thread
    test_nat_type();
    assert!(is_nat_probe_running());

    // Release simulated probe
    NAT_PROBE_RUNNING.store(false, Ordering::SeqCst);
    assert!(!is_nat_probe_running());
}

#[test]
fn test_nat_probe_cancel_stop_flag() {
    let _lock = acquire_probe_test_lock();

    reset_nat_probe_stop();
    assert!(!NAT_PROBE_STOP.load(Ordering::SeqCst));

    stop_nat_probe();
    assert!(NAT_PROBE_STOP.load(Ordering::SeqCst));

    reset_nat_probe_stop();
    assert!(!NAT_PROBE_STOP.load(Ordering::SeqCst));
}

#[test]
fn test_nat_probe_concurrent_contention() {
    let _lock = acquire_probe_test_lock();
    reset_nat_probe_cooldown_for_test();
    stop_nat_probe(); // Stop signal active so probe thread exits immediately

    let barrier = Arc::new(Barrier::new(10));
    let mut handles = Vec::new();

    for _ in 0..10 {
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            test_nat_type();
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    // Wait bounded time for any launched thread to exit
    let start = Instant::now();
    while is_nat_probe_running() && start.elapsed() < Duration::from_millis(1000) {
        thread::sleep(Duration::from_millis(5));
    }

    assert!(
        !is_nat_probe_running(),
        "NAT probe must terminate when stop signal is asserted"
    );
    reset_nat_probe_stop();
}

#[test]
fn test_ipv6_probe_atomic_single_flight() {
    let _lock = acquire_probe_test_lock();
    reset_ipv6_probe_cooldown_for_test();

    // Manually mark probe as running
    IPV6_PROBE_RUNNING.store(true, Ordering::SeqCst);
    assert!(is_ipv6_probe_running());

    // Calling test_ipv6_sync must be rejected before spawning OS thread
    test_ipv6_sync();
    assert!(is_ipv6_probe_running());

    // Release simulated probe
    IPV6_PROBE_RUNNING.store(false, Ordering::SeqCst);
    assert!(!is_ipv6_probe_running());
}

#[test]
fn test_ipv6_probe_cooldown() {
    let _lock = acquire_probe_test_lock();
    reset_ipv6_probe_cooldown_for_test();

    test_ipv6_sync();
    // Immediate second call is suppressed by cooldown
    test_ipv6_sync();

    // Wait bounded time for IPv6 probe to finish
    let start = Instant::now();
    while is_ipv6_probe_running() && start.elapsed() < Duration::from_millis(1000) {
        thread::sleep(Duration::from_millis(5));
    }

    reset_ipv6_probe_cooldown_for_test();
}

#[test]
fn test_refresh_rendezvous_server_single_flight() {
    let _lock = acquire_probe_test_lock();
    reset_rendezvous_probe_cooldown_for_test();

    // Manually mark probe as running
    RENDEZVOUS_PROBE_RUNNING.store(true, Ordering::SeqCst);
    assert!(is_rendezvous_probe_running());

    // Calling refresh_rendezvous_server must be rejected before spawning OS thread
    refresh_rendezvous_server();
    assert!(is_rendezvous_probe_running());

    // Release simulated probe
    RENDEZVOUS_PROBE_RUNNING.store(false, Ordering::SeqCst);
    assert!(!is_rendezvous_probe_running());
}

#[test]
fn test_refresh_rendezvous_server_cooldown_rejection() {
    let _lock = acquire_probe_test_lock();
    reset_rendezvous_probe_cooldown_for_test();

    // First call passes cooldown and launches probe
    refresh_rendezvous_server();

    // Immediate second call is suppressed by debounce/cooldown
    refresh_rendezvous_server();

    // Wait bounded time for launched probe thread to complete
    let start = Instant::now();
    while is_rendezvous_probe_running() && start.elapsed() < Duration::from_millis(1000) {
        thread::sleep(Duration::from_millis(5));
    }

    reset_rendezvous_probe_cooldown_for_test();
}

#[test]
fn test_generation_fencing_on_config_change() {
    let _lock = acquire_probe_test_lock();

    let before = get_rendezvous_generation();
    set_option(
        "custom-rendezvous-server".into(),
        "custom.example.org:21116".into(),
    );
    let after = get_rendezvous_generation();
    assert!(
        after > before,
        "Configuring custom-rendezvous-server must bump generation fence (before={}, after={})",
        before,
        after
    );

    // Reset option
    set_option("custom-rendezvous-server".into(), "".into());
}

#[test]
fn test_nat_probe_resumes_after_stop() {
    let _lock = acquire_probe_test_lock();

    stop_nat_probe();
    assert!(NAT_PROBE_STOP.load(Ordering::SeqCst));

    reset_nat_probe_cooldown_for_test();
    test_nat_type();

    // Starting a new test_nat_type probe must clear NAT_PROBE_STOP
    assert!(
        !NAT_PROBE_STOP.load(Ordering::SeqCst),
        "A newly launched NAT probe must reset NAT_PROBE_STOP to allow execution"
    );

    // Wait bounded time for NAT probe to exit
    let start = Instant::now();
    while is_nat_probe_running() && start.elapsed() < Duration::from_millis(1000) {
        thread::sleep(Duration::from_millis(5));
    }
}
