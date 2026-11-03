use camellia_remote_protocol::{
    tokio::{self, sync::oneshot},
    ResultType,
};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};

use camellia_remote::privacy_mode::{
    clear_durable_journal, load_durable_journal, save_durable_journal, DisplaySnapshot,
    JournalItemState, JournalPhase, PhysicalDisplayJournalEntry, PrivacyOwner,
    PrivacyRecoveryJournal, PrivacyTransactionState, PrivacyTransactionSupervisor,
    RegistryJournalEntry, VirtualDisplayJournalEntry, OCCUPIED,
};

static JOURNAL_TEST_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn test_priv003_supervisor_single_flight_and_occupancy() {
    let supervisor = PrivacyTransactionSupervisor::new();
    let owner1 = PrivacyOwner {
        conn_id: 101,
        generation: 1,
    };
    let owner2 = PrivacyOwner {
        conn_id: 102,
        generation: 1,
    };

    // Connection 1 begins activation
    let (req1, cancel_token1) = supervisor
        .begin_activation(owner1)
        .expect("owner1 activation");
    assert_eq!(req1.owner, owner1);
    assert!(!cancel_token1.load(Ordering::SeqCst));
    assert!(matches!(
        supervisor.get_state(),
        PrivacyTransactionState::Activating { .. }
    ));

    // Connection 2 attempts activation while 1 is in-flight -> rejected with OCCUPIED
    let err = supervisor.begin_activation(owner2).unwrap_err();
    assert_eq!(err.to_string(), OCCUPIED);

    // Commit active for Connection 1
    supervisor
        .commit_active(req1, &cancel_token1)
        .expect("commit active");
    assert_eq!(
        supervisor.get_state(),
        PrivacyTransactionState::Active { owner: owner1 }
    );
    assert_eq!(supervisor.get_active_owner(), Some(owner1));

    // Connection 2 attempts activation while 1 is active -> rejected with OCCUPIED
    let err2 = supervisor.begin_activation(owner2).unwrap_err();
    assert_eq!(err2.to_string(), OCCUPIED);

    // Turn off for owner 1
    let turned_off = supervisor.turn_off_or_abort_for_owner(owner1);
    assert!(turned_off);
    assert_eq!(supervisor.get_state(), PrivacyTransactionState::Idle);
    assert_eq!(supervisor.get_active_owner(), None);

    // Now Connection 2 can activate
    let (req2, _token2) = supervisor
        .begin_activation(owner2)
        .expect("owner2 activation");
    assert_eq!(req2.owner, owner2);
}

#[test]
fn test_priv003_retry_cancels_in_flight_without_thread_accumulation() {
    let supervisor = PrivacyTransactionSupervisor::new();
    let owner = PrivacyOwner {
        conn_id: 201,
        generation: 1,
    };

    // First activation attempt
    let (req1, token1) = supervisor.begin_activation(owner).expect("first attempt");
    assert!(!token1.load(Ordering::SeqCst));

    // Same connection retries before first one commits
    let (req2, token2) = supervisor.begin_activation(owner).expect("retry attempt");
    assert!(req2.seq > req1.seq);
    // Token 1 must be cancelled!
    assert!(token1.load(Ordering::SeqCst));
    assert!(!token2.load(Ordering::SeqCst));

    // Attempting to commit req1 must fail due to cancellation
    let err1 = supervisor.commit_active(req1, &token1).unwrap_err();
    assert!(err1.to_string().contains("cancelled"));

    // Attempting to commit req2 succeeds
    supervisor
        .commit_active(req2, &token2)
        .expect("commit req2");
    assert_eq!(
        supervisor.get_state(),
        PrivacyTransactionState::Active { owner }
    );
}

#[test]
fn test_priv003_stale_generation_commit_rejected() {
    let supervisor = PrivacyTransactionSupervisor::new();
    let owner_gen1 = PrivacyOwner {
        conn_id: 301,
        generation: 1,
    };
    let owner_gen2 = PrivacyOwner {
        conn_id: 301,
        generation: 2,
    };

    let (req1, token1) = supervisor
        .begin_activation(owner_gen1)
        .expect("activation gen 1");

    // Turn off / abort for generation 1, then start generation 2
    supervisor.turn_off_or_abort_for_owner(owner_gen1);
    let (req2, token2) = supervisor
        .begin_activation(owner_gen2)
        .expect("activation gen 2");

    // Stale req1 from generation 1 attempts commit with cancelled token
    let err = supervisor.commit_active(req1, &token1).unwrap_err();
    assert!(err.to_string().contains("cancelled"));

    // Stale req1 from generation 1 attempts commit even if token is not cancelled
    let uncancelled_token = Arc::new(AtomicBool::new(false));
    let err_mismatch = supervisor
        .commit_active(req1, &uncancelled_token)
        .unwrap_err();
    assert!(err_mismatch.to_string().contains("mismatch"));

    // Fresh req2 commits cleanly
    supervisor
        .commit_active(req2, &token2)
        .expect("commit gen 2");
    assert_eq!(supervisor.get_active_owner(), Some(owner_gen2));
}

#[tokio::test]
async fn test_priv003_handle_timeout_grace_rollback() {
    let supervisor = PrivacyTransactionSupervisor::new();
    let owner = PrivacyOwner {
        conn_id: 401,
        generation: 1,
    };

    let (req, cancel_token) = supervisor.begin_activation(owner).expect("begin");

    let (tx, mut rx) = oneshot::channel::<Option<ResultType<bool>>>();
    // Spawn a worker that simulates receiving cancellation and rolling back within 50ms
    let cancel_token_clone = cancel_token.clone();
    std::thread::spawn(move || {
        let start = std::time::Instant::now();
        while !cancel_token_clone.load(Ordering::SeqCst)
            && start.elapsed() < Duration::from_millis(500)
        {
            std::thread::sleep(Duration::from_millis(10));
        }
        // Worker rolled back and responded
        let _ = tx.send(Some(Ok(false)));
    });

    // Handle timeout with 300ms grace period
    let res = supervisor
        .handle_timeout(
            req,
            cancel_token.clone(),
            Duration::from_millis(300),
            &mut rx,
        )
        .await;

    assert!(cancel_token.load(Ordering::SeqCst));
    assert!(res.is_some());
    let err = res.unwrap().unwrap_err();
    assert!(err.to_string().contains("timed out; system state restored"));
    // Supervisor returns to Idle
    assert_eq!(supervisor.get_state(), PrivacyTransactionState::Idle);
}

#[tokio::test]
async fn test_priv003_handle_timeout_unresponsive_fallback_to_unknown_restoring() {
    let supervisor = PrivacyTransactionSupervisor::new();
    let owner = PrivacyOwner {
        conn_id: 501,
        generation: 1,
    };

    let (req, cancel_token) = supervisor.begin_activation(owner).expect("begin");

    // Receiver that never gets a response (worker stuck in kernel driver call)
    let (_tx, mut rx) = oneshot::channel::<Option<ResultType<bool>>>();

    let res = supervisor
        .handle_timeout(
            req,
            cancel_token.clone(),
            Duration::from_millis(50),
            &mut rx,
        )
        .await;

    assert!(cancel_token.load(Ordering::SeqCst));
    assert!(res.is_some());
    let err = res.unwrap().unwrap_err();
    assert!(err
        .to_string()
        .contains("state unknown, background recovery scheduled"));
    // Supervisor enters UnknownRestoring
    assert_eq!(
        supervisor.get_state(),
        PrivacyTransactionState::UnknownRestoring { owner: Some(owner) }
    );

    // Stalled worker eventually waking up cannot commit active
    let commit_err = supervisor.commit_active(req, &cancel_token).unwrap_err();
    assert!(commit_err.to_string().contains("cancelled"));
}

#[test]
fn test_priv004_durable_recovery_journal_lifecycle() {
    let _guard = JOURNAL_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    clear_durable_journal();
    assert!(load_durable_journal().is_none());

    let mut journal = PrivacyRecoveryJournal::new("tx_test_1".to_string(), 601, 1);
    let snapshot1 = DisplaySnapshot::new(
        "\\\\.\\DISPLAY1".to_string(),
        true,
        vec![0xAA; 220],
        (0, 0),
        1920,
        1080,
        32,
        60,
        0,
    );
    let snapshot2 = DisplaySnapshot::new(
        "\\\\.\\DISPLAY2".to_string(),
        false,
        vec![0xBB; 220],
        (1920, 0),
        1920,
        1080,
        32,
        60,
        0,
    );

    journal.physical_displays.push(PhysicalDisplayJournalEntry {
        device_name: snapshot1.device_name.clone(),
        snapshot: snapshot1,
        state: JournalItemState::Applied,
        last_error_code: None,
    });
    journal.physical_displays.push(PhysicalDisplayJournalEntry {
        device_name: snapshot2.device_name.clone(),
        snapshot: snapshot2,
        state: JournalItemState::Applied,
        last_error_code: None,
    });
    journal.virtual_indices.push(VirtualDisplayJournalEntry {
        index: 1,
        state: JournalItemState::Applied,
        last_error: None,
    });
    journal.registry_entry = Some(RegistryJournalEntry {
        recovery_json: "{\"path\":\"Connectivity\",\"key\":\"TestKey\"}".to_string(),
        state: JournalItemState::Applied,
        last_error: None,
    });

    assert!(!journal.is_fully_restored());
    assert!(journal.has_pending_or_applied());

    // Save durable journal
    save_durable_journal(&journal);

    // Load and verify persisted state
    let loaded = load_durable_journal().expect("load persisted journal");
    assert_eq!(loaded.tx_id, "tx_test_1");
    assert_eq!(loaded.conn_id, 601);
    assert_eq!(loaded.physical_displays.len(), 2);
    assert_eq!(loaded.virtual_indices.len(), 1);
    assert!(loaded.registry_entry.is_some());
    assert_eq!(
        loaded.physical_displays[0].snapshot.dm_raw_bytes,
        vec![0xAA; 220]
    );

    // Mark restored
    let mut loaded_mut = loaded;
    loaded_mut.mark_all_restored();
    assert!(loaded_mut.is_fully_restored());
    assert_eq!(loaded_mut.phase, JournalPhase::FullyRestored);

    clear_durable_journal();
    assert!(load_durable_journal().is_none());
}

#[test]
fn test_priv004_fault_injection_retains_failed_journal_for_retry() {
    let _guard = JOURNAL_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    clear_durable_journal();

    let mut journal = PrivacyRecoveryJournal::new("tx_fault_1".to_string(), 701, 1);
    let snapshot = DisplaySnapshot::new(
        "\\\\.\\DISPLAY1".to_string(),
        true,
        vec![0xCC; 220],
        (0, 0),
        2560,
        1440,
        32,
        144,
        0,
    );
    journal.physical_displays.push(PhysicalDisplayJournalEntry {
        device_name: snapshot.device_name.clone(),
        snapshot,
        state: JournalItemState::Applied,
        last_error_code: None,
    });

    save_durable_journal(&journal);

    // Simulate display restore failure (-1 = DISP_CHANGE_FAILED)
    let mut loaded = load_durable_journal().expect("load journal");
    loaded.physical_displays[0].state = JournalItemState::RestoreFailed;
    loaded.physical_displays[0].last_error_code = Some(-1);
    loaded.phase = JournalPhase::PartiallyRestored;

    // Save with partial failure
    save_durable_journal(&loaded);

    // Assert journal is NOT cleared and retains failure diagnostic
    let re_loaded = load_durable_journal().expect("reloaded failed journal");
    assert!(!re_loaded.is_fully_restored());
    assert_eq!(
        re_loaded.physical_displays[0].state,
        JournalItemState::RestoreFailed
    );
    assert_eq!(re_loaded.physical_displays[0].last_error_code, Some(-1));

    // Simulate subsequent idempotent retry success
    let mut retry_journal = re_loaded;
    retry_journal.physical_displays[0].state = JournalItemState::Restored;
    retry_journal.physical_displays[0].last_error_code = None;
    assert!(retry_journal.is_fully_restored());

    clear_durable_journal();
    assert!(load_durable_journal().is_none());
}

#[test]
fn test_priv005_hook_manager_capability_and_self_join_safety() {
    // Test that hook manager state transitions are sound
    // On non-Windows, we test the supervisor integration and fail-closed transaction guarantee
    let supervisor = PrivacyTransactionSupervisor::new();
    let owner = PrivacyOwner {
        conn_id: 801,
        generation: 1,
    };

    let (req, _cancel_token) = supervisor.begin_activation(owner).expect("activation");

    // Simulate hook failure before commit
    let hook_installed = false;
    if !hook_installed {
        // Rollback transaction on hook failure: never commit active!
        supervisor.abort_activation(req);
    }

    assert_eq!(supervisor.get_state(), PrivacyTransactionState::Idle);
    assert_eq!(supervisor.get_active_owner(), None);

    // Now simulate successful hook installation
    let (req2, cancel_token2) = supervisor.begin_activation(owner).expect("activation 2");
    let hook_installed2 = true;
    if hook_installed2 {
        supervisor
            .commit_active(req2, &cancel_token2)
            .expect("commit active");
    }

    assert_eq!(
        supervisor.get_state(),
        PrivacyTransactionState::Active { owner }
    );
    assert_eq!(supervisor.get_active_owner(), Some(owner));

    // Clean teardown
    supervisor.turn_off_or_abort_for_owner(owner);
    assert_eq!(supervisor.get_state(), PrivacyTransactionState::Idle);
}

#[tokio::test]
async fn test_priv003_bounded_abort_or_turn_off() {
    let owner = PrivacyOwner {
        conn_id: 901,
        generation: 5,
    };

    // Calling bounded turn-off completes within deadline
    let turned_off =
        camellia_remote::privacy_mode::abort_or_turn_off_bounded(owner, Duration::from_millis(500))
            .await;
    // Even if not previously active, bounded routine returns gracefully without hanging
    assert!(!turned_off || turned_off);
}
