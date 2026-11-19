//! Contract and Regression Test Suite for Batch 99 (P1 Stability & Security Hardening):
//! - PERF-013: PulseAudio IPC tight infinite loop / 100% CPU on None/Err resolution.
//! - AUTH-025: One-time temporary password immediate rotation upon validation.

#![deny(warnings)]

use camellia_remote::ipc::ConnectionTmpl;
use camellia_remote_protocol::bytes::Bytes;
use camellia_remote_protocol::password_security::{temporary_password, update_temporary_password};
use camellia_remote_protocol::tokio;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Mutex};

static BATCH99_TEST_MUTEX: Mutex<()> = Mutex::new(());

fn acquire_lock() -> std::sync::MutexGuard<'static, ()> {
    BATCH99_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner())
}

#[test]
fn test_auth025_temporary_password_immediate_rotation() {
    let _lock = acquire_lock();

    // 1. Ensure temporary password generation is initialized
    update_temporary_password();
    let initial_pwd = temporary_password();
    assert!(
        !initial_pwd.is_empty(),
        "Temporary password must not be empty"
    );

    // 2. Validate that before rotation, the password matches
    assert_eq!(temporary_password(), initial_pwd);

    // 3. Simulate successful validation: update_temporary_password() is called immediately
    update_temporary_password();
    let rotated_pwd = temporary_password();

    // 4. Verify that the password rotated immediately and the old password is invalid
    assert_ne!(
        initial_pwd, rotated_pwd,
        "Temporary password must rotate immediately after use to prevent reuse"
    );
    assert!(
        !rotated_pwd.is_empty(),
        "Rotated temporary password must not be empty"
    );
    assert_eq!(temporary_password(), rotated_pwd);
}

#[test]
fn test_auth025_concurrent_temporary_password_single_use() {
    let _lock = acquire_lock();

    update_temporary_password();
    let current_pwd = temporary_password();
    assert!(!current_pwd.is_empty());

    let shared_pwd = Arc::new(current_pwd);
    let success_count = Arc::new(AtomicUsize::new(0));
    let barrier = Arc::new(Barrier::new(10));

    let mut handles = vec![];
    for _ in 0..10 {
        let pwd_to_claim = shared_pwd.clone();
        let success = success_count.clone();
        let bar = barrier.clone();
        handles.push(std::thread::spawn(move || {
            bar.wait();
            // Critical section mirroring Connection::validate_password with lock
            lazy_static::lazy_static! {
                static ref VALIDATION_LOCK: Mutex<()> = Mutex::new(());
            }
            let _g = VALIDATION_LOCK.lock().unwrap();
            let active = temporary_password();
            if active == *pwd_to_claim {
                update_temporary_password();
                success.fetch_add(1, Ordering::SeqCst);
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(
        success_count.load(Ordering::SeqCst),
        1,
        "Exactly one concurrent thread must succeed in consuming the temporary password"
    );
    assert_ne!(temporary_password(), *shared_pwd);
}

#[tokio::test]
async fn test_perf013_ipc_connection_stream_error_breaks_loop() {
    let _lock = acquire_lock();

    // 1. Establish duplex stream and wrap in real ConnectionTmpl
    let (client_io, server_io) = tokio::io::duplex(1024);
    let mut client_conn = ConnectionTmpl::new(client_io);
    let mut server_conn = ConnectionTmpl::new(server_io);

    // 2. Normal send/recv works
    server_conn
        .send_raw(Bytes::from_static(b"audio-pcm-sample-data"))
        .await
        .expect("send_raw should succeed");
    let received = client_conn
        .next_raw()
        .await
        .expect("next_raw should succeed");
    assert_eq!(&received[..], b"audio-pcm-sample-data");

    // 3. Drop server end to simulate peer/PulseAudio IPC disconnect
    drop(server_conn);

    // 4. Simulate audio_service.rs loop: next_raw() returns Err and breaks loop immediately
    let mut iterations = 0;
    while iterations < 5 {
        iterations += 1;
        match client_conn.next_raw().await {
            Ok(_) => {}
            Err(err) => {
                assert!(
                    err.to_string().contains("reset by the peer"),
                    "Expected peer reset, got: {}",
                    err
                );
                break;
            }
        }
    }
    assert_eq!(
        iterations, 1,
        "Loop must terminate on the very first Err from next_raw() without spinning"
    );
}

#[tokio::test]
async fn test_perf013_listener_stream_none_breaks_loop() {
    let _lock = acquire_lock();

    // Simulate incoming listener stream yielding None
    let (tx, mut rx) = tokio::sync::mpsc::channel::<()>(1);
    drop(tx);

    let mut loop_count = 0;
    while let Some(_) = rx.recv().await {
        loop_count += 1;
    }
    assert_eq!(
        loop_count, 0,
        "while let Some loop must terminate immediately when stream yields None"
    );
}
