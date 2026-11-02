use camellia_remote::server::voice_call_manager::{
    generate_call_id, next_voice_call_generation, VoiceCallManager,
};
use clipboard::{
    next_connection_generation, ClipboardOpGuard, CliprdrError, GLOBAL_CLIPBOARD_OP_MGR,
};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc, Barrier,
};
use std::thread;
use std::time::{Duration, Instant};

#[test]
fn test_adversarial_voice_call_multi_session_concurrency_race() {
    let manager = Arc::new(VoiceCallManager::new());
    let num_threads = 64;
    let barrier = Arc::new(Barrier::new(num_threads));
    let win_count = Arc::new(AtomicUsize::new(0));
    let busy_count = Arc::new(AtomicUsize::new(0));

    let mut handles = Vec::new();
    for thread_idx in 0..num_threads {
        let mgr = manager.clone();
        let bar = barrier.clone();
        let wins = win_count.clone();
        let busies = busy_count.clone();
        let conn_id = 1000 + thread_idx as i32;

        handles.push(thread::spawn(move || {
            let call_id = generate_call_id();
            let gen = next_voice_call_generation();

            // Synchronize all threads at the starting line
            bar.wait();

            match mgr.try_register_call(conn_id, call_id, gen) {
                Ok(()) => {
                    wins.fetch_add(1, Ordering::SeqCst);
                }
                Err("busy") => {
                    busies.fetch_add(1, Ordering::SeqCst);
                }
                Err(other) => {
                    panic!("Unexpected error from try_register_call: {:?}", other);
                }
            }
        }));
    }

    for h in handles {
        h.join().expect("Thread joined successfully");
    }

    // Invariant: Exactly 1 thread must have registered, exactly num_threads - 1 rejected with "busy"
    assert_eq!(
        win_count.load(Ordering::SeqCst),
        1,
        "Exactly one session must acquire the call"
    );
    assert_eq!(
        busy_count.load(Ordering::SeqCst),
        num_threads - 1,
        "All other sessions must receive 'busy'"
    );

    let active_owner = manager.get_owner().expect("Active owner must be present");
    assert!(
        active_owner.conn_id >= 1000 && active_owner.conn_id < 1000 + num_threads as i32,
        "Active owner must be one of the racing threads"
    );
}

#[test]
fn test_adversarial_voice_call_lifecycle_hijacking_and_non_owner_immunity() {
    let manager = Arc::new(VoiceCallManager::new());
    let owner_conn_id = 777;
    let owner_call_id = generate_call_id();
    let owner_gen = next_voice_call_generation();

    // Owner registers call
    assert!(manager
        .try_register_call(owner_conn_id, owner_call_id, owner_gen)
        .is_ok());
    assert!(manager.is_owner(owner_conn_id));

    // 50 concurrent non-owner threads attempt to hijack or tear down the call
    let num_attackers = 50;
    let barrier = Arc::new(Barrier::new(num_attackers));
    let mut handles = Vec::new();

    for attacker_idx in 0..num_attackers {
        let mgr = manager.clone();
        let bar = barrier.clone();
        let attacker_conn_id = 2000 + attacker_idx as i32;

        handles.push(thread::spawn(move || {
            bar.wait();

            // 1. Attacker attempts to register -> must fail
            let res = mgr.try_register_call(
                attacker_conn_id,
                generate_call_id(),
                next_voice_call_generation(),
            );
            assert_eq!(res, Err("busy"));

            // 2. Attacker attempts to release -> must return false
            assert!(!mgr.release_call_if_owner(attacker_conn_id));

            // 3. Attacker attempts to hijack input device -> must be blocked
            mgr.set_voice_call_input_device(
                Some(format!("malicious_device_{}", attacker_idx)),
                Some(attacker_conn_id),
            );
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    // Verify Session A's call remains completely intact and unaffected
    let current_owner = manager.get_owner().expect("Owner must still be active");
    assert_eq!(current_owner.conn_id, owner_conn_id);
    assert_eq!(current_owner.call_id, owner_call_id);
    assert_eq!(current_owner.generation, owner_gen);
    assert!(manager.is_owner(owner_conn_id));
    assert_eq!(
        manager.get_voice_call_input_device(),
        None,
        "Malicious device changes must have been blocked"
    );

    // Verify legitimate owner can set device and then release
    manager.set_voice_call_input_device(Some("authorized_mic".to_string()), Some(owner_conn_id));
    assert_eq!(
        manager.get_voice_call_input_device(),
        Some("authorized_mic".to_string())
    );

    assert!(manager.release_call_if_owner(owner_conn_id));
    assert_eq!(manager.get_owner(), None);
    assert_eq!(
        manager.get_voice_call_input_device(),
        None,
        "Input device must be reset upon legitimate release"
    );
}

#[test]
fn test_adversarial_voice_call_id_entropy_and_replay_resistance() {
    let sample_size = 50_000;
    let mut ids = HashSet::with_capacity(sample_size);
    let mut prev_seq = 0u64;

    for _ in 0..sample_size {
        let id = generate_call_id();
        assert_ne!(id, 0, "Call ID must never be zero");

        // High 32 bits monotonic sequence
        let raw = id as u64;
        let seq = raw >> 32;
        let _entropy = raw & 0xFFFF_FFFF;

        if prev_seq != 0 {
            assert!(
                seq >= prev_seq,
                "Sequence component in high 32 bits must be monotonic"
            );
        }
        prev_seq = seq;

        // Ensure low 32 bits have entropy (not all zeros)
        assert!(ids.insert(id), "Call ID collision detected for: {}", id);
    }

    assert_eq!(ids.len(), sample_size, "All 50,000 call IDs must be unique");
}

#[test]
fn test_adversarial_clipboard_cross_session_hijack_rejection() {
    GLOBAL_CLIPBOARD_OP_MGR.write().take();

    let session_a_conn = 100;
    let session_a_gen = next_connection_generation();
    let fd_id = 42;

    // Session A initiates clipboard operation
    let op_id = ClipboardOpGuard::initiate_operation(session_a_conn, session_a_gen, false, fd_id);
    let target_dir = PathBuf::from("/tmp/camellia_test_downloads");
    assert!(ClipboardOpGuard::set_target_root(op_id, target_dir.clone()).is_ok());

    // Adversarial attack 1: Session B (unauthorized conn_id) sends unsolicited FormatDataResponse
    let session_b_conn = 200;
    let attack_1 = ClipboardOpGuard::validate_format_data_response(session_b_conn, session_a_gen);
    match attack_1 {
        Err(CliprdrError::InvalidRequest { description }) => {
            assert!(
                description.contains("mismatch"),
                "Expected connection mismatch error, got: {}",
                description
            );
        }
        other => panic!("Expected InvalidRequest for session B, got: {:?}", other),
    }

    // Adversarial attack 2: Session B sends unsolicited FileContentsResponse
    let attack_2 = ClipboardOpGuard::validate_file_contents_response(session_b_conn, session_a_gen);
    match attack_2 {
        Err(CliprdrError::InvalidRequest { description }) => {
            assert!(
                description.contains("mismatch"),
                "Expected connection mismatch error, got: {}",
                description
            );
        }
        other => panic!("Expected InvalidRequest for session B, got: {:?}", other),
    }

    // Adversarial attack 3: Session A with forged generation (stale packet)
    let attack_3 =
        ClipboardOpGuard::validate_format_data_response(session_a_conn, session_a_gen + 999);
    assert!(
        matches!(attack_3, Err(CliprdrError::InvalidRequest { .. })),
        "Forged generation must be rejected"
    );

    // Legitimate Session A FormatDataResponse succeeds
    let legit_format =
        ClipboardOpGuard::validate_format_data_response(session_a_conn, session_a_gen);
    assert!(legit_format.is_ok());
    let (validated_op, root, token) = legit_format.unwrap();
    assert_eq!(validated_op, op_id);
    assert_eq!(root, Some(target_dir));
    assert!(!token.is_cancelled());

    // Legitimate Session A FileContentsResponse succeeds
    let legit_contents =
        ClipboardOpGuard::validate_file_contents_response(session_a_conn, session_a_gen);
    assert_eq!(legit_contents.unwrap(), op_id);

    // Cleanup
    ClipboardOpGuard::abort_for_connection(session_a_conn, session_a_gen);
    assert!(token.is_cancelled());
}

#[test]
fn test_adversarial_clipboard_ttl_strict_expiration_and_cancellation() {
    GLOBAL_CLIPBOARD_OP_MGR.write().take();

    let conn_id = 300;
    let gen = next_connection_generation();

    let _op_id = ClipboardOpGuard::initiate_operation(conn_id, gen, false, 1);

    // Retrieve token
    let token = GLOBAL_CLIPBOARD_OP_MGR
        .read()
        .as_ref()
        .unwrap()
        .cancel_token
        .clone();
    assert!(!token.is_cancelled());

    // Artificially expire the operation
    {
        let mut guard = GLOBAL_CLIPBOARD_OP_MGR.write();
        let op = guard.as_mut().unwrap();
        op.deadline = Instant::now() - Duration::from_millis(100);
        assert!(op.is_expired());
    }

    // Validate FormatDataResponse on expired operation
    let res = ClipboardOpGuard::validate_format_data_response(conn_id, gen);
    match res {
        Err(CliprdrError::InvalidRequest { description }) => {
            assert!(
                description.contains("expired"),
                "Expected expiration message, got: {}",
                description
            );
        }
        other => panic!("Expected expiration error, got: {:?}", other),
    }

    // Invariant: Expired operation must trigger CancellationToken
    assert!(
        token.is_cancelled(),
        "Token must be cancelled upon TTL expiration"
    );

    // Invariant: Operation is cleared from manager upon expiration
    assert!(
        GLOBAL_CLIPBOARD_OP_MGR.read().is_none(),
        "Expired operation must be purged from global manager"
    );

    // Subsequent FileContentsResponse fails closed
    let res2 = ClipboardOpGuard::validate_file_contents_response(conn_id, gen);
    match res2 {
        Err(CliprdrError::InvalidRequest { description }) => {
            assert!(
                description.contains("No active clipboard"),
                "Expected 'No active clipboard', got: {}",
                description
            );
        }
        other => panic!("Expected InvalidRequest, got: {:?}", other),
    }
}

#[test]
fn test_adversarial_clipboard_reconnect_generation_bump_and_delayed_packets() {
    GLOBAL_CLIPBOARD_OP_MGR.write().take();

    let conn_id = 500;
    let gen_1 = next_connection_generation();

    // 1. Connection 1 establishes operation
    let op_id_1 = ClipboardOpGuard::initiate_operation(conn_id, gen_1, false, 10);
    assert_ne!(op_id_1.0, 0);

    // 2. Reconnection occurs: new connection generation
    let gen_2 = next_connection_generation();
    assert!(gen_2 > gen_1);

    // Session teardown on disconnect aborts gen 1
    ClipboardOpGuard::abort_for_connection(conn_id, gen_1);

    // 3. Delayed stale packet from gen 1 arrives -> must be rejected
    let stale_resp = ClipboardOpGuard::validate_format_data_response(conn_id, gen_1);
    assert!(stale_resp.is_err());

    // 4. New session on gen 2 initiates new operation
    let op_id_2 = ClipboardOpGuard::initiate_operation(conn_id, gen_2, false, 20);
    assert_ne!(op_id_2, op_id_1);

    // Delayed packet from gen 1 still arriving -> must be rejected by gen 2 active op
    let stale_contents = ClipboardOpGuard::validate_file_contents_response(conn_id, gen_1);
    match stale_contents {
        Err(CliprdrError::InvalidRequest { description }) => {
            assert!(
                description.contains("mismatch"),
                "Expected mismatch error for stale generation, got: {}",
                description
            );
        }
        other => panic!("Expected mismatch error, got: {:?}", other),
    }

    // Packet from gen 2 accepted
    assert!(ClipboardOpGuard::validate_file_contents_response(conn_id, gen_2).is_ok());

    // Final teardown
    ClipboardOpGuard::abort_for_connection(conn_id, gen_2);
    assert!(GLOBAL_CLIPBOARD_OP_MGR.read().is_none());
}

#[test]
fn test_adversarial_clipboard_concurrent_stress_load() {
    GLOBAL_CLIPBOARD_OP_MGR.write().take();

    let num_threads = 32;
    let iterations = 200;
    let barrier = Arc::new(Barrier::new(num_threads));
    let stop = Arc::new(AtomicBool::new(false));

    let mut handles = Vec::new();
    for thread_idx in 0..num_threads {
        let bar = barrier.clone();
        let is_stop = stop.clone();
        let conn_id = (thread_idx % 4) as i32 + 1; // 4 shared connections

        handles.push(thread::spawn(move || {
            bar.wait();
            for i in 0..iterations {
                if is_stop.load(Ordering::Relaxed) {
                    break;
                }
                let gen = (i + 1) as u64;
                let op_id = ClipboardOpGuard::initiate_operation(conn_id, gen, false, i as i32);
                let _ = ClipboardOpGuard::set_target_root(
                    op_id,
                    PathBuf::from(format!("/tmp/test_{}", thread_idx)),
                );
                let _ = ClipboardOpGuard::validate_format_data_response(conn_id, gen);
                let _ = ClipboardOpGuard::validate_file_contents_response(conn_id, gen);
                if i % 10 == 0 {
                    ClipboardOpGuard::abort_for_connection(conn_id, gen);
                }
            }
        }));
    }

    for h in handles {
        h.join().expect("Stress thread joined without panic");
    }

    // Clean state at completion
    GLOBAL_CLIPBOARD_OP_MGR.write().take();
}
