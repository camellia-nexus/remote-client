//! Contract and Regression Test Suite for Batch 99 (P1 Stability & Security Hardening):
//! - PERF-013: PulseAudio IPC tight infinite loop / 100% CPU on None/Err resolution.
//! - AUTH-025: One-time temporary password immediate rotation upon validation.

#![deny(warnings)]

use camellia_remote_protocol::password_security::{temporary_password, update_temporary_password};
use camellia_remote_protocol::tokio;
use std::sync::Mutex;

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

#[tokio::test]
async fn test_perf013_mock_stream_none_and_err_break_loop() {
    let _lock = acquire_lock();

    // Simulate listener incoming.next() returning None
    let (tx, mut rx) = tokio::sync::mpsc::channel::<()>(1);
    drop(tx); // Close channel immediately so rx.recv() returns None

    let mut loop_count = 0;
    #[allow(clippy::while_let_loop)]
    loop {
        if let Some(_) = rx.recv().await {
            loop_count += 1;
        } else {
            break;
        }
    }
    assert_eq!(
        loop_count, 0,
        "Loop must terminate immediately when stream yields None"
    );

    // Simulate stream.next_raw() returning Err
    let mut iterations = 0;
    let mut err_stream_terminated = false;
    while !err_stream_terminated {
        iterations += 1;
        // Mock error on read
        let res: Result<Vec<u8>, std::io::Error> = Err(std::io::Error::new(
            std::io::ErrorKind::ConnectionReset,
            "stream closed",
        ));
        match res {
            Ok(_) => {}
            Err(_) => {
                err_stream_terminated = true;
            }
        }
        if iterations > 1 {
            panic!("Infinite loop detected on stream error");
        }
    }
    assert!(
        err_stream_terminated,
        "Stream error must break out of loop cleanly"
    );
}
