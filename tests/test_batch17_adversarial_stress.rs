use camellia_remote_protocol::{
    tokio::{self, sync::oneshot},
    ResultType,
};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::channel,
        Arc,
    },
    time::Duration,
};

use camellia_remote::privacy_mode::{
    PrivacyOwner, PrivacyTransactionState, PrivacyTransactionSupervisor,
    INVALID_PRIVACY_MODE_CONN_ID, OCCUPIED,
};

/// EMPIRICAL BUG 1:
/// When supervisor enters `UnknownRestoring` due to hard timeout, subsequent calls to
/// `turn_off_or_abort_for_owner` return false and fail to restore state to `Idle`.
/// As a consequence, ALL future connection activation attempts are permanently rejected.
#[test]
fn test_stress_unknown_restoring_deadlock_on_subsequent_activation() {
    let supervisor = PrivacyTransactionSupervisor::new();
    let owner1 = PrivacyOwner {
        conn_id: 1001,
        generation: 1,
    };

    let (req1, cancel_token1) = supervisor.begin_activation(owner1).expect("begin 1");

    // Simulate hard timeout where worker is stuck
    let (_tx, mut rx) = oneshot::channel::<Option<ResultType<bool>>>();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let res = rt.block_on(supervisor.handle_timeout(
        req1,
        cancel_token1.clone(),
        Duration::from_millis(10),
        &mut rx,
    ));

    assert!(res.is_some());
    assert_eq!(
        supervisor.get_state(),
        PrivacyTransactionState::UnknownRestoring {
            owner: Some(owner1)
        }
    );

    // Teardown / recovery is performed for owner 1
    let turned_off = supervisor.turn_off_or_abort_for_owner(owner1);
    let state_after = supervisor.get_state();
    println!("turn_off_or_abort_for_owner returned: {}", turned_off);
    println!("supervisor state after teardown: {:?}", state_after);

    // Connection 2 attempts activation after teardown
    let owner2 = PrivacyOwner {
        conn_id: 1002,
        generation: 1,
    };
    let activation_res = supervisor.begin_activation(owner2);
    println!("activation_res for owner2: {:?}", activation_res);

    assert!(
        activation_res.is_ok(),
        "CRITICAL BUG: Supervisor is permanently stuck in UnknownRestoring! Error: {:?}",
        activation_res.err()
    );
}

/// EMPIRICAL BUG 2:
/// When Ctrl+P triggers emergency exit, it calls `turn_off_privacy(INVALID_PRIVACY_MODE_CONN_ID, ...)`.
/// But `turn_off_privacy` contains:
/// `if conn_id != INVALID_PRIVACY_MODE_CONN_ID { SUPERVISOR.turn_off_or_abort_for_owner(...) }`
/// Because `conn_id == 0`, SUPERVISOR is NEVER updated and remains `Active { owner }`!
/// This causes `is_in_privacy_mode()` to permanently return true and blocks all future activations with OCCUPIED!
#[test]
fn test_stress_ctrl_p_invalid_conn_id_desync_leaves_supervisor_active() {
    let supervisor = Arc::new(PrivacyTransactionSupervisor::new());
    let owner = PrivacyOwner {
        conn_id: 2001,
        generation: 1,
    };

    let (req, token) = supervisor
        .begin_activation(owner)
        .expect("begin activation");
    supervisor
        .commit_active(req, &token)
        .expect("commit active");

    assert_eq!(
        supervisor.get_state(),
        PrivacyTransactionState::Active { owner }
    );

    // Simulate what remediated turn_off_privacy(INVALID_PRIVACY_MODE_CONN_ID, ...) does:
    let conn_id = INVALID_PRIVACY_MODE_CONN_ID;
    supervisor.turn_off_or_abort_for_owner(PrivacyOwner {
        conn_id,
        generation: 0,
    });

    // Check if supervisor is reset to Idle:
    let current_state = supervisor.get_state();
    println!("State after Ctrl+P unhook: {:?}", current_state);
    assert_eq!(current_state, PrivacyTransactionState::Idle);

    // A new connection arrives and wants to activate:
    let new_owner = PrivacyOwner {
        conn_id: 2002,
        generation: 1,
    };
    let new_res = supervisor.begin_activation(new_owner);

    assert!(
        new_res.is_ok(),
        "CRITICAL BUG: Ctrl+P emergency unhook leaves SUPERVISOR active, blocking subsequent connections! Error: {:?}",
        new_res.err()
    );
}

#[test]
fn test_stress_ctrl_p_global_turn_off_privacy_resets_supervisor() {
    let owner = PrivacyOwner {
        conn_id: 2005,
        generation: 1,
    };
    let (req, token) = camellia_remote::privacy_mode::SUPERVISOR
        .begin_activation(owner)
        .expect("begin");
    camellia_remote::privacy_mode::SUPERVISOR
        .commit_active(req, &token)
        .expect("commit");

    assert_eq!(
        camellia_remote::privacy_mode::SUPERVISOR.get_state(),
        PrivacyTransactionState::Active { owner }
    );

    // Call public turn_off_privacy with INVALID_PRIVACY_MODE_CONN_ID (as Ctrl+P does)
    let _ = camellia_remote::privacy_mode::turn_off_privacy(
        INVALID_PRIVACY_MODE_CONN_ID,
        Some(camellia_remote::privacy_mode::PrivacyModeState::OffByPeer),
    );

    assert_eq!(
        camellia_remote::privacy_mode::SUPERVISOR.get_state(),
        PrivacyTransactionState::Idle
    );
    assert!(!camellia_remote::privacy_mode::is_in_privacy_mode());
}

/// Stress Test 1: Concurrency Contention across 50 threads over 10 consecutive rounds
#[test]
fn test_stress_concurrency_contention_50_threads_multi_round() {
    let supervisor = Arc::new(PrivacyTransactionSupervisor::new());

    for round in 0..10 {
        let (tx, rx) = channel();
        let mut handles = Vec::new();

        for i in 1..=50 {
            let s = supervisor.clone();
            let tx_clone = tx.clone();
            let conn_id = round * 100 + i;
            let h = std::thread::spawn(move || {
                let owner = PrivacyOwner {
                    conn_id,
                    generation: 1,
                };
                let res = s.begin_activation(owner);
                tx_clone.send((conn_id, res)).unwrap();
            });
            handles.push(h);
        }

        for h in handles {
            h.join().unwrap();
        }

        let mut successes = Vec::new();
        let mut occupied_count = 0;

        for _ in 1..=50 {
            let (cid, res) = rx.recv().unwrap();
            match res {
                Ok((req, token)) => successes.push((cid, req, token)),
                Err(e) => {
                    assert_eq!(e.to_string(), OCCUPIED);
                    occupied_count += 1;
                }
            }
        }

        // Exactly one thread wins the activation race
        assert_eq!(
            successes.len(),
            1,
            "Round {}: Exactly 1 thread must succeed in begin_activation",
            round
        );
        assert_eq!(
            occupied_count, 49,
            "Round {}: Exactly 49 threads must be rejected with OCCUPIED",
            round
        );

        let (winner_cid, winner_req, winner_token) = successes.pop().unwrap();
        supervisor
            .commit_active(winner_req, &winner_token)
            .expect("winner commit");

        assert_eq!(
            supervisor.get_active_owner(),
            Some(PrivacyOwner {
                conn_id: winner_cid,
                generation: 1
            })
        );

        // Turn off and verify return to Idle for next round
        let turned_off = supervisor.turn_off_or_abort_for_owner(PrivacyOwner {
            conn_id: winner_cid,
            generation: 1,
        });
        assert!(turned_off);
        assert_eq!(supervisor.get_state(), PrivacyTransactionState::Idle);
    }
}

/// Stress Test 2: Rapid Retry Storm with 100 sequential requests and cancellation
#[test]
fn test_stress_rapid_retry_storm_cancellation_100_requests() {
    let supervisor = PrivacyTransactionSupervisor::new();
    let owner = PrivacyOwner {
        conn_id: 3001,
        generation: 1,
    };

    let mut tokens = Vec::new();
    let mut reqs = Vec::new();

    for _ in 0..100 {
        let (req, token) = supervisor
            .begin_activation(owner)
            .expect("retry activation");
        tokens.push(token);
        reqs.push(req);
    }

    // Verify all prior tokens (0..99) are marked cancelled
    for i in 0..99 {
        assert!(
            tokens[i].load(Ordering::SeqCst),
            "Token {} must be cancelled by subsequent retries",
            i
        );
        let commit_err = supervisor.commit_active(reqs[i], &tokens[i]);
        assert!(
            commit_err.is_err(),
            "Prior request {} must not be able to commit",
            i
        );
    }

    // Verify only the 100th request (index 99) is NOT cancelled
    assert!(!tokens[99].load(Ordering::SeqCst));
    supervisor
        .commit_active(reqs[99], &tokens[99])
        .expect("final retry commit");

    assert_eq!(supervisor.get_active_owner(), Some(owner));
    assert_eq!(
        supervisor.get_state(),
        PrivacyTransactionState::Active { owner }
    );
}

/// Stress Test 3: Generation race & stale commit rejection under concurrent threads
#[test]
fn test_stress_generation_race_stale_commit_rejection() {
    let supervisor = Arc::new(PrivacyTransactionSupervisor::new());
    let conn_id = 4001;

    for gen in 1..=20 {
        let owner = PrivacyOwner {
            conn_id,
            generation: gen,
        };
        let (req, token) = supervisor.begin_activation(owner).expect("activation");

        // Spawn a thread attempting to commit with stale generation from previous turn
        let s_clone = supervisor.clone();
        let stale_owner = PrivacyOwner {
            conn_id,
            generation: gen - 1,
        };
        let stale_token = Arc::new(AtomicBool::new(false));
        let stale_req = camellia_remote::privacy_mode::PrivacyRequestId {
            owner: stale_owner,
            seq: req.seq - 1,
        };

        let stale_handle =
            std::thread::spawn(move || s_clone.commit_active(stale_req, &stale_token));

        let stale_res = stale_handle.join().unwrap();
        assert!(
            stale_res.is_err(),
            "Commit with stale generation must be rejected"
        );

        // Fresh commit succeeds
        supervisor.commit_active(req, &token).expect("fresh commit");

        // Turn off for next iteration
        supervisor.turn_off_or_abort_for_owner(owner);
    }
}
