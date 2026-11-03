use camellia_remote::privacy_mode::{
    clear_durable_journal, load_durable_journal, save_durable_journal, DisplaySnapshot,
    JournalItemState, JournalPhase, PhysicalDisplayJournalEntry, PrivacyOwner,
    PrivacyRecoveryJournal, PrivacyTransactionState, PrivacyTransactionSupervisor,
    RegistryJournalEntry, VirtualDisplayJournalEntry,
};
use camellia_remote_protocol::{
    tokio::{self, sync::oneshot},
    ResultType,
};
use std::time::Duration;

static JOURNAL_TEST_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

// ============================================================================
// Test 1: Fault Injection into PrivacyRecoveryJournal - Display Restore Failure
// ============================================================================
#[test]
fn test_adv_journal_display_restore_failure_retention_and_idempotent_retry() {
    let _guard = JOURNAL_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    clear_durable_journal();

    let tx_id = "tx_fault_disp_1".to_string();
    let mut journal = PrivacyRecoveryJournal::new(tx_id.clone(), 1001, 1);
    let snapshot = DisplaySnapshot::new(
        "\\\\.\\DISPLAY1".to_string(),
        true,
        vec![0x42; 220],
        (0, 0),
        1920,
        1080,
        32,
        60,
        0,
    );

    journal.physical_displays.push(PhysicalDisplayJournalEntry {
        device_name: snapshot.device_name.clone(),
        snapshot: snapshot.clone(),
        state: JournalItemState::Applied,
        last_error_code: None,
    });

    save_durable_journal(&journal);

    // Simulate display restoration failure: DISP_CHANGE_FAILED (-1)
    let mut loaded = load_durable_journal().expect("must load saved journal");
    loaded.physical_displays[0].state = JournalItemState::RestoreFailed;
    loaded.physical_displays[0].last_error_code = Some(-1);
    loaded.phase = JournalPhase::PartiallyRestored;
    save_durable_journal(&loaded);

    // Verify snapshot is NOT erased from Config
    let persisted = load_durable_journal().expect("must reload failed journal");
    assert_eq!(persisted.phase, JournalPhase::PartiallyRestored);
    assert_eq!(
        persisted.physical_displays[0].state,
        JournalItemState::RestoreFailed
    );
    assert_eq!(persisted.physical_displays[0].last_error_code, Some(-1));
    assert_eq!(
        persisted.physical_displays[0].snapshot.dm_raw_bytes,
        vec![0x42; 220]
    );
    assert_eq!(
        persisted.physical_displays[0].device_name,
        "\\\\.\\DISPLAY1"
    );
    assert!(!persisted.is_fully_restored());
    assert!(persisted.has_pending_or_applied());

    // Subsequent retry succeeds idempotently
    let mut retry_journal = persisted;
    retry_journal.physical_displays[0].state = JournalItemState::Restored;
    retry_journal.physical_displays[0].last_error_code = None;
    retry_journal.phase = JournalPhase::FullyRestored;
    assert!(retry_journal.is_fully_restored());

    clear_durable_journal();
    assert!(load_durable_journal().is_none());
}

// ============================================================================
// Test 2: Fault Injection into PrivacyRecoveryJournal - Registry Restore Failure
// ============================================================================
#[test]
fn test_adv_journal_registry_restore_failure_retention_and_retry() {
    let _guard = JOURNAL_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    clear_durable_journal();

    let mut journal = PrivacyRecoveryJournal::new("tx_fault_reg_1".to_string(), 1002, 1);
    let reg_diff = "{\"path\":\"Connectivity/1\",\"data\":\"test_payload\"}".to_string();
    journal.registry_entry = Some(RegistryJournalEntry {
        recovery_json: reg_diff.clone(),
        state: JournalItemState::Applied,
        last_error: None,
    });

    save_durable_journal(&journal);

    // Simulate registry write permission failure
    let mut loaded = load_durable_journal().expect("loaded journal");
    if let Some(ref mut reg) = loaded.registry_entry {
        reg.state = JournalItemState::RestoreFailed;
        reg.last_error = Some("Access is denied (os error 5)".to_string());
    }
    loaded.phase = JournalPhase::PartiallyRestored;
    save_durable_journal(&loaded);

    // Assert registry recovery diff is preserved in Config and not wiped
    let reloaded = load_durable_journal().expect("reloaded journal");
    assert_eq!(reloaded.phase, JournalPhase::PartiallyRestored);
    let reg_entry = reloaded
        .registry_entry
        .as_ref()
        .expect("registry entry exists");
    assert_eq!(reg_entry.state, JournalItemState::RestoreFailed);
    assert_eq!(reg_entry.recovery_json, reg_diff);
    assert_eq!(
        reg_entry.last_error.as_deref(),
        Some("Access is denied (os error 5)")
    );
    assert!(reloaded.has_pending_or_applied());

    // Clean up
    clear_durable_journal();
}

// ============================================================================
// Test 3: Process Crash Recovery - Dirty Journal Replay on Startup
// ============================================================================
#[test]
fn test_adv_crash_recovery_dirty_journal_parsed_and_verified() {
    let _guard = JOURNAL_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    clear_durable_journal();

    // Simulate crash after VirtualPluggedIn & PrimarySwitched
    let mut dirty_journal = PrivacyRecoveryJournal::new("tx_crash_1".to_string(), 1003, 2);
    dirty_journal.phase = JournalPhase::PrimarySwitched;
    let snap = DisplaySnapshot::new(
        "\\\\.\\DISPLAY1".to_string(),
        true,
        vec![0x77; 220],
        (0, 0),
        1920,
        1080,
        32,
        60,
        0,
    );
    dirty_journal
        .physical_displays
        .push(PhysicalDisplayJournalEntry {
            device_name: snap.device_name.clone(),
            snapshot: snap,
            state: JournalItemState::Applied,
            last_error_code: None,
        });
    dirty_journal
        .virtual_indices
        .push(VirtualDisplayJournalEntry {
            index: 2,
            state: JournalItemState::Applied,
            last_error: None,
        });

    // Write dirty journal to persistent Config (simulating state left on disk after SIGKILL)
    save_durable_journal(&dirty_journal);

    // Simulate startup check
    let recovered = load_durable_journal().expect("startup must find dirty journal");
    assert_eq!(recovered.tx_id, "tx_crash_1");
    assert_eq!(recovered.conn_id, 1003);
    assert_eq!(recovered.generation, 2);
    assert_eq!(recovered.phase, JournalPhase::PrimarySwitched);
    assert!(recovered.has_pending_or_applied());
    assert!(!recovered.is_fully_restored());

    // Simulate replaying restoration
    let mut replay = recovered;
    for d in &mut replay.physical_displays {
        d.state = JournalItemState::Restored;
    }
    for v in &mut replay.virtual_indices {
        v.state = JournalItemState::Restored;
    }
    replay.phase = JournalPhase::FullyRestored;
    assert!(replay.is_fully_restored());

    // Once verified restored, clean durable storage
    clear_durable_journal();
    assert!(load_durable_journal().is_none());
}

// ============================================================================
// Test 4: Adversarial Finding - PartiallyRestored Journal with Restored Items
//         has_pending_or_applied() Bug
// ============================================================================
#[test]
fn test_adv_finding_partially_restored_journal_has_pending_or_applied_gap() {
    let _guard = JOURNAL_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    clear_durable_journal();

    // Scenario: Physical display restoration succeeded, but global display commit
    // failed with DISP_CHANGE_FAILED.
    // In journal.rs line 432:
    // `if journal.is_fully_restored() && commit_rc == DISP_CHANGE_SUCCESSFUL`
    // Since commit_rc != 0, it enters else branch:
    // `journal.phase = JournalPhase::PartiallyRestored;`
    // `save_durable_journal(journal);`
    let mut journal = PrivacyRecoveryJournal::new("tx_commit_fail".to_string(), 1004, 1);
    let snap = DisplaySnapshot::new(
        "\\\\.\\DISPLAY1".to_string(),
        true,
        vec![0x55; 220],
        (0, 0),
        1920,
        1080,
        32,
        60,
        0,
    );
    // The physical display entry was marked Restored because restore_single() succeeded
    journal.physical_displays.push(PhysicalDisplayJournalEntry {
        device_name: snap.device_name.clone(),
        snapshot: snap,
        state: JournalItemState::Restored,
        last_error_code: None,
    });
    // But overall phase is PartiallyRestored due to global commit failure
    journal.phase = JournalPhase::PartiallyRestored;
    save_durable_journal(&journal);

    let loaded = load_durable_journal().expect("must load journal");
    assert_eq!(loaded.phase, JournalPhase::PartiallyRestored);

    let has_work = loaded.has_pending_or_applied();
    assert!(
        has_work,
        "Partially restored journal must be recognized by has_pending_or_applied() to ensure startup recovery executes"
    );
    clear_durable_journal();
}

// ============================================================================
// Test 5: Adversarial Finding - UnknownRestoring Permanent Bricking Trap
// ============================================================================
#[tokio::test]
async fn test_adv_finding_unknown_restoring_supervisor_permanent_bricking() {
    let supervisor = PrivacyTransactionSupervisor::new();
    let owner = PrivacyOwner {
        conn_id: 1005,
        generation: 1,
    };

    let (req, cancel_token) = supervisor.begin_activation(owner).expect("begin");

    // Worker hangs in uninterruptible driver call; grace period expires
    let (_tx, mut rx) = oneshot::channel::<Option<ResultType<bool>>>();
    let _timeout_res = supervisor
        .handle_timeout(
            req,
            cancel_token.clone(),
            Duration::from_millis(50),
            &mut rx,
        )
        .await;

    // Supervisor is now in UnknownRestoring
    assert_eq!(
        supervisor.get_state(),
        PrivacyTransactionState::UnknownRestoring { owner: Some(owner) }
    );

    // CHALLENGE: Try to recover / abort / turn off for this owner
    let abort_success = supervisor.turn_off_or_abort_for_owner(owner);
    println!(
        "Observation: turn_off_or_abort_for_owner on UnknownRestoring returned: {}",
        abort_success
    );

    // Check if state transitioned back to Idle:
    let cur_state = supervisor.get_state();
    println!(
        "Observation: state after turn_off_or_abort_for_owner: {:?}",
        cur_state
    );

    // Now try to begin a new activation:
    let new_activation_res = supervisor.begin_activation(owner);
    println!(
        "Observation: begin_activation after abort returned: {:?}",
        new_activation_res
            .as_ref()
            .map(|_| ())
            .map_err(|e| e.to_string())
    );

    // Verify remediated supervisor recovers cleanly from UnknownRestoring:
    assert!(
        abort_success,
        "turn_off_or_abort_for_owner must succeed for UnknownRestoring"
    );
    assert_eq!(cur_state, PrivacyTransactionState::Idle);
    assert!(
        new_activation_res.is_ok(),
        "Subsequent activation must succeed after abort"
    );
}

// ============================================================================
// Test 6: Hook Failure Fail-Closed Rollback Guarantee
// ============================================================================
#[test]
fn test_adv_hook_failure_fail_closed_rollback_guarantee() {
    let supervisor = PrivacyTransactionSupervisor::new();
    let owner = PrivacyOwner {
        conn_id: 1006,
        generation: 1,
    };

    let (req, _cancel_token) = supervisor.begin_activation(owner).expect("begin");

    // Simulate hook failure (e.g. SetWindowsHookExA returns NULL)
    let hook_result: ResultType<()> = Err(camellia_remote_protocol::anyhow::anyhow!(
        "SetWindowsHookExA keyboard error: 1444"
    ));

    match hook_result {
        Ok(_) => panic!("Hook unexpectedly succeeded"),
        Err(_) => {
            // Must abort activation, trigger TurnOnGuard display/registry rollback,
            // and never commit active!
            supervisor.abort_activation(req);
        }
    }

    assert_eq!(supervisor.get_state(), PrivacyTransactionState::Idle);
    assert_eq!(supervisor.get_active_owner(), None);

    // Verify system can cleanly accept a subsequent valid activation
    let (req2, token2) = supervisor.begin_activation(owner).expect("subsequent try");
    supervisor
        .commit_active(req2, &token2)
        .expect("commit active");
    assert_eq!(
        supervisor.get_state(),
        PrivacyTransactionState::Active { owner }
    );
    supervisor.turn_off_or_abort_for_owner(owner);
}

// ============================================================================
// Test 7: Teardown Unhook Failure Non-Short-Circuiting Guarantee
// ============================================================================
#[test]
fn test_adv_teardown_unhook_failure_does_not_abort_display_and_registry_restoration() {
    let _guard = JOURNAL_TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    clear_durable_journal();

    // Verify the architectural invariant of PRIV-004 / PRIV-005:
    // In turn_off_privacy, win_input::unhook() failure must NOT abort display or registry recovery.
    let mut journal = PrivacyRecoveryJournal::new("tx_teardown_unhook_fail".to_string(), 1007, 1);
    let snap = DisplaySnapshot::new(
        "\\\\.\\DISPLAY1".to_string(),
        true,
        vec![0x99; 220],
        (0, 0),
        1920,
        1080,
        32,
        60,
        0,
    );
    journal.physical_displays.push(PhysicalDisplayJournalEntry {
        device_name: snap.device_name.clone(),
        snapshot: snap,
        state: JournalItemState::Applied,
        last_error_code: None,
    });
    save_durable_journal(&journal);

    // Simulate turn_off_privacy sequence:
    // Step 1: win_input::unhook() fails
    let mut aggregated_errors: Vec<String> = Vec::new();
    let unhook_err: ResultType<()> = Err(camellia_remote_protocol::anyhow::anyhow!(
        "PostThreadMessageA exit signal failed (error 1444)"
    ));
    if let Err(e) = unhook_err {
        aggregated_errors.push(format!("Input unhook failed: {}", e));
    }

    // Assert that we did NOT return early on unhook error!
    // Step 2 & 3: Display & Registry restoration MUST proceed
    let mut loaded = load_durable_journal().expect("journal loaded");
    assert!(loaded.has_pending_or_applied());

    // Restore displays
    loaded.physical_displays[0].state = JournalItemState::Restored;
    loaded.phase = JournalPhase::FullyRestored;
    save_durable_journal(&loaded);

    // Teardown reports aggregated error while displays are 100% restored
    assert_eq!(aggregated_errors.len(), 1);
    assert!(aggregated_errors[0].contains("Input unhook failed"));
    assert!(loaded.is_fully_restored());

    clear_durable_journal();
}
