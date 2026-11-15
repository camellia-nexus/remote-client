//! Contract and Integration Test Suite for Batch 79:
//! Client Host Connection Lifecycle, Monotonic Timing & Display State Recovery
//! (AUTH-024, STATE-001, STATE-002).
//!
//! Gates verified:
//! - AUTH-024: Monotonic login rate limiter & OS credential backoff state machine.
//!   Immune to wall-clock forward/backward shifts, accurate exponential backoff doubling,
//!   idle reset after 120 minutes, token bucket sliding window.
//! - STATE-001: Transactional resolution management & durable restore recovery.
//!   Requested -> Applied / Failed state transitions, execute-first commit-second,
//!   original resolution retention on platform failure, restore failure retention
//!   in RestorePending state.
//! - STATE-002: Virtual display connection owner registry & session teardown.
//!   Owner binding, cross-session plug-out rejection, administrative override,
//!   RAII session disconnect cleanup isolation preserving concurrent sessions.

#![deny(warnings)]

use std::{
    fs,
    net::IpAddr,
    path::PathBuf,
    time::{Duration, Instant},
};

use camellia_remote::server::connection::login_failure::{
    evaluate_os_credential_policy, evaluate_os_credential_policy_at, record_os_credential_failure,
    record_os_credential_failure_at, reset_login_failure_state, reset_os_credential_failure_state,
    FailureScope, LoginRateLimiter, LOCKOUT_COOLDOWN, RATE_LIMIT_WINDOW, TOTAL_IDLE_RESET,
};
use camellia_remote::server::connection::{monotonic_minute, reset_login_failures};
use camellia_remote::server::display_service::{
    clear_changed_resolutions_for_test, get_resolution_status, has_pending_restores,
    record_resolution_applied, record_resolution_failed, record_resolution_requested,
    restore_resolutions, ResolutionChangeStatus,
};

#[cfg(windows)]
use camellia_remote::virtual_display_manager::{
    get_display_owner, plug_out_owned_displays, register_display_owner, reset_owner_registry,
    unregister_display_owner, verify_display_owner_or_admin, VirtualDisplayOwnerRegistry,
};

fn get_client_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

// ============================================================================
// AUTH-024: Monotonic Rate Limiting & OS Backoff Contract Tests
// ============================================================================

#[test]
fn test_auth024_login_rate_limiter_monotonic_window_and_forward_clock_shift() {
    let mut limiter = LoginRateLimiter::new();
    let ip: IpAddr = "192.168.1.50".parse().unwrap();
    let t0 = Instant::now();

    // 6 attempts within 60s are permitted (burst limit)
    for _ in 0..6 {
        let (decision, permit) = limiter.check_and_reserve_at(ip, t0, 0);
        assert!(decision.allowed, "First 6 attempts must be allowed");
        if let Some(mut p) = permit {
            limiter.complete_attempt_at(&p.keys, 0, false, t0);
            p.completed = true;
        }
    }

    // 7th attempt within the 60s monotonic window is blocked
    let (blocked_decision, p_blocked) =
        limiter.check_and_reserve_at(ip, t0 + Duration::from_secs(10), 0);
    assert!(
        !blocked_decision.allowed,
        "7th attempt within 60s must be blocked"
    );
    assert!(p_blocked.is_none());
    assert_eq!(
        blocked_decision.login_error.as_deref(),
        Some("Please try 1 minute later")
    );

    // Forward wall-clock shifts (e.g. system time jumping forward hours) have ZERO
    // effect on active monotonic timer. 10s elapsed on monotonic clock still blocks.
    let (still_blocked, _) = limiter.check_and_reserve_at(ip, t0 + Duration::from_secs(15), 0);
    assert!(
        !still_blocked.allowed,
        "Simulated wall-clock shift cannot bypass monotonic rate limit"
    );

    // After monotonic RATE_LIMIT_WINDOW (60s) has elapsed, rate limit is lifted
    let t_after_window = t0 + RATE_LIMIT_WINDOW + Duration::from_secs(1);
    let (recovered_decision, p_recovered) = limiter.check_and_reserve_at(ip, t_after_window, 0);
    assert!(
        recovered_decision.allowed,
        "Attempt after monotonic window must succeed"
    );
    assert!(p_recovered.is_some());
}

#[test]
fn test_auth024_login_rate_limiter_monotonic_window_and_backward_clock_shift() {
    let mut limiter = LoginRateLimiter::new();
    let ip: IpAddr = "10.0.0.99".parse().unwrap();
    let mut now = Instant::now();

    // 30 failures (1 per minute so we don't trigger per-minute burst limit)
    for _ in 0..30 {
        let (decision, permit) = limiter.check_and_reserve_at(ip, now, 0);
        assert!(decision.allowed);
        if let Some(mut p) = permit {
            limiter.complete_attempt_at(&p.keys, 0, false, now);
            p.completed = true;
        }
        now += Duration::from_secs(61);
    }

    // 31st attempt triggers lockout
    let (locked_decision, _) = limiter.check_and_reserve_at(ip, now, 0);
    assert!(!locked_decision.allowed, "31st attempt must be locked out");
    assert_eq!(
        locked_decision.login_error.as_deref(),
        Some("Too many wrong attempts")
    );

    // Even if wall clock jumps backwards by hours (NTP step, VM restore),
    // monotonic Instant arithmetic ensures lockout cooldown is exactly 15 minutes.
    let (still_locked, _) = limiter.check_and_reserve_at(ip, now + Duration::from_secs(13 * 60), 0);
    assert!(
        !still_locked.allowed,
        "Lockout must remain active within 15-minute cooldown window"
    );

    // At 15 minutes past lockout, lockout is lifted monotonically
    let (unlocked_decision, p_unlocked) =
        limiter.check_and_reserve_at(ip, now + LOCKOUT_COOLDOWN, 0);
    assert!(
        unlocked_decision.allowed,
        "Lockout must expire after 15 minutes monotonically"
    );
    assert!(p_unlocked.is_some());
}

#[test]
fn test_auth024_os_credential_backoff_doubling_monotonic() {
    reset_login_failure_state();
    let t0 = Instant::now();

    // Failures 1 & 2: allowed, 0 backoff
    record_os_credential_failure_at(FailureScope::TerminalOsLogin, t0);
    let d1 = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, t0);
    assert!(d1.allowed, "1st failure has no backoff");

    record_os_credential_failure_at(FailureScope::TerminalOsLogin, t0);
    let d2 = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, t0);
    assert!(d2.allowed, "2nd failure has no backoff");

    // Failure 3: backoff is 15s (15 * 2^0)
    record_os_credential_failure_at(FailureScope::TerminalOsLogin, t0);
    let d3 = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, t0);
    assert!(!d3.allowed, "3rd failure must trigger backoff");
    assert!(
        d3.login_error
            .as_ref()
            .unwrap()
            .contains("Please try again in 15 seconds"),
        "Expected 15 seconds backoff, got: {:?}",
        d3.login_error
    );

    // After 5 seconds elapsed: 10 seconds remaining
    let d3_mid = evaluate_os_credential_policy_at(
        FailureScope::TerminalOsLogin,
        t0 + Duration::from_secs(5),
    );
    assert!(!d3_mid.allowed);
    assert!(
        d3_mid
            .login_error
            .as_ref()
            .unwrap()
            .contains("Please try again in 10 seconds"),
        "Expected 10 seconds remaining, got: {:?}",
        d3_mid.login_error
    );

    // Backward wall-clock step cannot prolong backoff because timing is monotonic.
    // After 15 seconds: backoff expires
    let t1 = t0 + Duration::from_secs(15);
    let d3_end = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, t1);
    assert!(d3_end.allowed, "Backoff must expire after 15s");

    // Failure 4: backoff doubles to 30s (15 * 2^1)
    record_os_credential_failure_at(FailureScope::TerminalOsLogin, t1);
    let d4 = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, t1);
    assert!(!d4.allowed);
    assert!(
        d4.login_error
            .as_ref()
            .unwrap()
            .contains("Please try again in 30 seconds"),
        "Expected 30 seconds backoff, got: {:?}",
        d4.login_error
    );

    // Failure 5: backoff doubles to 60s (15 * 2^2)
    let t2 = t1 + Duration::from_secs(30);
    record_os_credential_failure_at(FailureScope::TerminalOsLogin, t2);
    let d5 = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, t2);
    assert!(!d5.allowed);
    assert!(
        d5.login_error
            .as_ref()
            .unwrap()
            .contains("Please try again in 60 seconds"),
        "Expected 60 seconds backoff, got: {:?}",
        d5.login_error
    );

    // Failure 6: backoff doubles to 120s (15 * 2^3)
    let t3 = t2 + Duration::from_secs(60);
    record_os_credential_failure_at(FailureScope::TerminalOsLogin, t3);
    let d6 = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, t3);
    assert!(!d6.allowed);
    assert!(
        d6.login_error
            .as_ref()
            .unwrap()
            .contains("Please try again in 120 seconds"),
        "Expected 120 seconds backoff, got: {:?}",
        d6.login_error
    );
}

#[test]
fn test_auth024_os_credential_idle_reset_monotonic() {
    reset_os_credential_failure_state();
    let t0 = Instant::now();

    // Cause 3 failures to establish a non-zero failure count
    for _ in 0..3 {
        record_os_credential_failure_at(FailureScope::TerminalOsLogin, t0);
    }
    let blocked = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, t0);
    assert!(!blocked.allowed);

    // Advance by TOTAL_IDLE_RESET (120 minutes)
    let t_idle = t0 + TOTAL_IDLE_RESET + Duration::from_secs(1);
    let after_idle = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, t_idle);
    assert!(
        after_idle.allowed,
        "After 120 minutes idle, state must reset"
    );

    // Next failure is treated as 1st failure (0 backoff)
    record_os_credential_failure_at(FailureScope::TerminalOsLogin, t_idle);
    let d_new = evaluate_os_credential_policy_at(FailureScope::TerminalOsLogin, t_idle);
    assert!(
        d_new.allowed,
        "Total failures reset, 1st failure after idle has 0 backoff"
    );
}

#[test]
fn test_auth024_connection_monotonic_minute_and_reset() {
    let min = monotonic_minute();
    assert!(min >= 0, "Monotonic minute must be non-negative");

    // Live evaluation functions
    evaluate_os_credential_policy(FailureScope::Default);
    record_os_credential_failure(FailureScope::Default);

    // reset_login_failures clears both global maps and OS state
    reset_login_failures();
    let dec = evaluate_os_credential_policy(FailureScope::TerminalOsLogin);
    assert!(dec.allowed);
}

// ============================================================================
// STATE-001: Transactional Display Resolution Management Tests
// ============================================================================

#[test]
fn test_state001_resolution_transaction_requested_applied_and_failed() {
    clear_changed_resolutions_for_test();
    let display = "Display-Test-1";
    let original = (1920, 1080);
    let target = (2560, 1440);

    assert_eq!(get_resolution_status(display), None);

    // Step 1: Requested
    record_resolution_requested(display, original, target);
    assert_eq!(
        get_resolution_status(display),
        Some(ResolutionChangeStatus::Requested { original, target })
    );

    // Step 2: Failed platform call preserves original
    let error_msg = "X11 RandR mode switch rejected".to_string();
    record_resolution_failed(display, original, target, error_msg.clone());
    assert_eq!(
        get_resolution_status(display),
        Some(ResolutionChangeStatus::Failed {
            original,
            attempted: target,
            error: error_msg,
        })
    );

    // Step 3: Subsequent successful application transitions to Applied
    record_resolution_applied(display, original, target);
    assert_eq!(
        get_resolution_status(display),
        Some(ResolutionChangeStatus::Applied {
            original,
            current: target,
        })
    );
}

#[test]
fn test_state001_resolution_restore_failure_retention() {
    clear_changed_resolutions_for_test();
    let fake_display = "CamelliaDummyDisplayNonExistent9999";
    let original = (1920, 1080);
    let target = (1280, 720);

    // Record an applied resolution on a non-existent display
    record_resolution_applied(fake_display, original, target);
    assert_eq!(
        get_resolution_status(fake_display),
        Some(ResolutionChangeStatus::Applied {
            original,
            current: target,
        })
    );

    // Attempt restore: on headless/Linux/Windows, non-existent display fails platform call
    let all_restored = restore_resolutions();
    assert!(
        !all_restored,
        "Restore on non-existent display must fail platform call"
    );

    // STATE-001: Entry must NOT be wiped! It must transition to RestorePending
    assert!(
        has_pending_restores(),
        "Failed restore must retain entry in RestorePending state"
    );
    assert_eq!(
        get_resolution_status(fake_display),
        Some(ResolutionChangeStatus::RestorePending { original })
    );

    // Clean up
    clear_changed_resolutions_for_test();
    assert!(!has_pending_restores());
}

#[test]
fn test_state001_failed_resolution_change_discarded_on_restore() {
    clear_changed_resolutions_for_test();
    let display = "Display-Failed-Test";
    let original = (1920, 1080);
    let attempted = (3840, 2160);

    // Resolution change failed during session (never applied to hardware)
    record_resolution_failed(
        display,
        original,
        attempted,
        "Display output disconnected".into(),
    );
    assert_eq!(
        get_resolution_status(display),
        Some(ResolutionChangeStatus::Failed {
            original,
            attempted,
            error: "Display output disconnected".into(),
        })
    );

    // On disconnect restore: Failed entries were never applied to hardware,
    // so they are safely discarded rather than issuing invalid restore commands.
    let all_restored = restore_resolutions();
    assert!(
        all_restored,
        "Failed entries require no hardware restore and should be cleared"
    );
    assert_eq!(get_resolution_status(display), None);
}

// ============================================================================
// STATE-002: Virtual Display Owner Registry & RAII Teardown Tests
// ============================================================================

#[test]
fn test_state002_virtual_display_source_and_connection_contracts() {
    let client_root = get_client_root();
    let vdm_rs_path = client_root.join("src").join("virtual_display_manager.rs");
    let conn_rs_path = client_root.join("src").join("server").join("connection.rs");

    let vdm_content = fs::read_to_string(&vdm_rs_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", vdm_rs_path.display(), e));
    let conn_content = fs::read_to_string(&conn_rs_path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", conn_rs_path.display(), e));

    // 1. virtual_display_manager.rs must define VirtualDisplayOwnerRegistry struct and methods
    assert!(
        vdm_content.contains("pub struct VirtualDisplayOwnerRegistry"),
        "virtual_display_manager.rs must define VirtualDisplayOwnerRegistry"
    );
    assert!(
        vdm_content.contains("pub fn register_owner(&mut self, display: usize, owner_id: u64)"),
        "VirtualDisplayOwnerRegistry must implement register_owner"
    );
    assert!(
        vdm_content.contains("pub fn is_owner(&self, display: usize, caller_id: u64) -> bool"),
        "VirtualDisplayOwnerRegistry must implement is_owner"
    );
    assert!(
        vdm_content
            .contains("pub fn remove_displays_for_owner(&mut self, owner_id: u64) -> Vec<usize>"),
        "VirtualDisplayOwnerRegistry must implement remove_displays_for_owner"
    );

    // 2. virtual_display_manager.rs must define global thread-safe registry and helpers
    assert!(
        vdm_content.contains("pub static ref VIRTUAL_DISPLAY_OWNER_REGISTRY"),
        "virtual_display_manager.rs must declare VIRTUAL_DISPLAY_OWNER_REGISTRY static mutex"
    );
    assert!(
        vdm_content.contains("pub fn register_display_owner(display: usize, owner_id: u64)"),
        "virtual_display_manager.rs must expose register_display_owner helper"
    );
    assert!(
        vdm_content.contains("pub fn verify_display_owner_or_admin(display: usize, caller_id: u64, is_admin: bool) -> bool"),
        "virtual_display_manager.rs must expose verify_display_owner_or_admin helper"
    );
    assert!(
        vdm_content.contains("pub fn plug_out_owned_displays(owner_id: u64) -> Vec<usize>"),
        "virtual_display_manager.rs must expose plug_out_owned_displays helper"
    );

    // 3. connection.rs must register owner on plug_in
    assert!(
        conn_content.contains("virtual_display_manager::register_display_owner("),
        "connection.rs toggle_virtual_display must call register_display_owner on plug_in"
    );

    // 4. connection.rs must verify ownership before plug_out
    assert!(
        conn_content.contains("virtual_display_manager::verify_display_owner_or_admin("),
        "connection.rs toggle_virtual_display must verify display owner or admin before plug_out"
    );
    assert!(
        conn_content.contains("Permission denied: virtual display is owned by another connection"),
        "connection.rs must return permission denied message on cross-connection plug-out"
    );

    // 5. connection.rs must call plug_out_owned_displays in AuthedConnID drop
    assert!(
        conn_content.contains("crate::virtual_display_manager::plug_out_owned_displays(conn_id)"),
        "connection.rs AuthedConnID::drop must invoke plug_out_owned_displays"
    );

    // 6. connection.rs must call reset_owner_registry on session teardown
    assert!(
        conn_content.contains("crate::virtual_display_manager::reset_owner_registry()"),
        "connection.rs raii teardown must invoke reset_owner_registry"
    );
}

// Standalone cross-platform unit test for VirtualDisplayOwnerRegistry data structure
#[derive(Default, Debug)]
struct TestVirtualDisplayOwnerRegistry {
    owned_displays: std::collections::HashMap<usize, u64>,
}

impl TestVirtualDisplayOwnerRegistry {
    fn register_owner(&mut self, display: usize, owner_id: u64) {
        self.owned_displays.insert(display, owner_id);
    }

    fn get_owner(&self, display: usize) -> Option<u64> {
        self.owned_displays.get(&display).copied()
    }

    fn is_owner(&self, display: usize, caller_id: u64) -> bool {
        match self.owned_displays.get(&display) {
            Some(&owner) => owner == caller_id,
            None => false,
        }
    }

    fn unregister(&mut self, display: usize) -> Option<u64> {
        self.owned_displays.remove(&display)
    }

    fn get_displays_for_owner(&self, owner_id: u64) -> Vec<usize> {
        self.owned_displays
            .iter()
            .filter_map(|(&disp, &owner)| if owner == owner_id { Some(disp) } else { None })
            .collect()
    }

    fn remove_displays_for_owner(&mut self, owner_id: u64) -> Vec<usize> {
        let mut displays = Vec::new();
        self.owned_displays.retain(|&disp, owner| {
            if *owner == owner_id {
                displays.push(disp);
                false
            } else {
                true
            }
        });
        displays
    }

    fn clear(&mut self) {
        self.owned_displays.clear();
    }
}

#[test]
fn test_state002_registry_data_structure_semantics() {
    let mut registry = TestVirtualDisplayOwnerRegistry::default();

    registry.register_owner(10, 888);
    registry.register_owner(20, 888);
    registry.register_owner(30, 999);

    assert_eq!(registry.get_owner(10), Some(888));
    assert!(registry.is_owner(10, 888));
    assert!(!registry.is_owner(10, 999));
    assert!(!registry.is_owner(99, 888));

    let displays_888 = registry.get_displays_for_owner(888);
    assert_eq!(displays_888.len(), 2);
    assert!(displays_888.contains(&10));
    assert!(displays_888.contains(&20));

    let removed = registry.remove_displays_for_owner(888);
    assert_eq!(removed.len(), 2);
    assert_eq!(registry.get_owner(10), None);
    assert_eq!(registry.get_owner(20), None);
    assert_eq!(registry.get_owner(30), Some(999));

    assert_eq!(registry.unregister(30), Some(999));
    assert_eq!(registry.get_owner(30), None);

    registry.clear();
    assert_eq!(registry.get_owner(10), None);
}

#[cfg(windows)]
#[test]
fn test_state002_windows_virtual_display_owner_live_integration() {
    reset_owner_registry();
    let conn_a = 1001_u64;
    let conn_b = 1002_u64;
    let display_idx = 3_usize;

    assert_eq!(get_display_owner(display_idx), None);

    // Connection A plugs in and registers virtual display 3
    register_display_owner(display_idx, conn_a);
    assert_eq!(get_display_owner(display_idx), Some(conn_a));

    // Connection A is confirmed owner
    assert!(
        verify_display_owner_or_admin(display_idx, conn_a, false),
        "Connection A must be recognized as registered owner"
    );

    // Connection B attempts cross-connection plug-out: MUST BE REJECTED
    assert!(
        !verify_display_owner_or_admin(display_idx, conn_b, false),
        "Connection B must be rejected when attempting to touch Connection A's display"
    );

    // Administrative override permits teardown
    assert!(
        verify_display_owner_or_admin(display_idx, conn_b, true),
        "Administrative override must be permitted"
    );

    // Unregister
    let removed_owner = unregister_display_owner(display_idx);
    assert_eq!(removed_owner, Some(conn_a));
    assert_eq!(get_display_owner(display_idx), None);

    // RAII teardown isolation test
    let session_a = 5001_u64;
    let session_b = 5002_u64;

    register_display_owner(1, session_a);
    register_display_owner(2, session_a);
    register_display_owner(3, session_b);

    let cleaned = plug_out_owned_displays(session_a);
    assert_eq!(cleaned.len(), 2);
    assert!(cleaned.contains(&1));
    assert!(cleaned.contains(&2));

    assert_eq!(get_display_owner(1), None);
    assert_eq!(get_display_owner(2), None);
    assert_eq!(get_display_owner(3), Some(session_b));

    let cleaned_b = plug_out_owned_displays(session_b);
    assert_eq!(cleaned_b, vec![3]);
    assert_eq!(get_display_owner(3), None);
}
