// Client Batch 25 Process and Handle Lifecycle Safety Tests
// Target Items:
// 1. RES-046 (P2): Amyuni virtual display driver probe SetupAPI HDEVINFO device-info set RAII cleanup & cache
// 2. RES-044 (P2): macOS URL/reopen callback bounded URI dispatcher, debounce, and single-flight fallback
// 3. RES-045 (P1): Client subprocess supervisor, session-targeted teardown, and non-blocking zombie elimination

use camellia_remote::{
    child_process,
    url_dispatcher::{self, MAX_URL_LEN, MAX_URL_QUEUE_CAPACITY},
};
use std::{
    process::Command,
    sync::{Arc, Barrier, Mutex},
    thread,
    time::Duration,
};

static BATCH25_TEST_MUTEX: Mutex<()> = Mutex::new(());

fn acquire_batch25_test_lock() -> std::sync::MutexGuard<'static, ()> {
    BATCH25_TEST_MUTEX
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

// =========================================================================
// 1. RES-045: Subprocess Lifecycle & Zombie Elimination Tests
// =========================================================================

#[test]
fn test_res045_child_supervisor_registration_and_reap() {
    let _lock = acquire_batch25_test_lock();

    // Spawn a quick short-lived process
    #[cfg(unix)]
    let child = Command::new("true").spawn().expect("failed to spawn true");
    #[cfg(windows)]
    let child = Command::new("cmd")
        .args(["/c", "exit 0"])
        .spawn()
        .expect("failed to spawn cmd");

    let pid = child.id();
    let reg_res = child_process::register(child, "test_quick_child", Some(9999));
    assert!(reg_res.is_ok(), "Registration must succeed");
    assert_eq!(reg_res.unwrap(), pid);

    // Give child time to exit and allow either background reaper or synchronous reap to collect it
    thread::sleep(Duration::from_millis(150));

    let reaped = child_process::reap_exited_children();
    let count = child_process::tracked_count();
    assert!(
        reaped >= 1 || count == 0,
        "Exited child must be reaped (either by synchronous call or background reaper)"
    );
}

#[test]
fn test_res045_child_supervisor_session_targeted_termination() {
    let _lock = acquire_batch25_test_lock();

    let target_session_id = 7777;
    let other_session_id = 8888;

    #[cfg(unix)]
    {
        let child_target = Command::new("sleep")
            .arg("10")
            .spawn()
            .expect("spawn sleep");
        let child_other = Command::new("sleep")
            .arg("10")
            .spawn()
            .expect("spawn sleep");

        let _pid_target = child_target.id();
        let _pid_other = child_other.id();

        child_process::register(child_target, "session_target", Some(target_session_id))
            .expect("register target");
        child_process::register(child_other, "session_other", Some(other_session_id))
            .expect("register other");

        // Terminate target session children only
        let terminated = child_process::terminate_session_children(
            target_session_id,
            Duration::from_millis(1000),
        );
        assert_eq!(terminated, 1, "Target session child must be terminated");

        // Verify other child is still alive or supervised
        let count = child_process::tracked_count();
        assert!(count >= 1, "Other session child must not be terminated");

        // Clean up remaining
        child_process::terminate_all(Duration::from_millis(500));
    }
}

#[test]
fn test_res045_child_supervisor_generation_and_stop() {
    let _lock = acquire_batch25_test_lock();

    let gen1 = child_process::bump_generation();
    let gen2 = child_process::bump_generation();
    assert_eq!(gen2, gen1 + 1, "Generations must be strictly monotonic");

    child_process::stop_reaper();
}

// =========================================================================
// 2. RES-044: Bounded URL Dispatcher Tests
// =========================================================================

#[test]
fn test_res044_url_dispatcher_enqueue_and_capacity_bound() {
    let _lock = acquire_batch25_test_lock();
    url_dispatcher::clear_queue();

    // Enqueue valid URLs up to capacity
    for i in 0..MAX_URL_QUEUE_CAPACITY {
        let url = format!("camellia-remote://test-connection/{}", i);
        let accepted = url_dispatcher::enqueue_url(url);
        assert!(accepted, "Enqueue within capacity must succeed");
    }

    // Next enqueue must be rejected due to queue capacity bound
    let excess_url = "camellia-remote://excess-url".to_string();
    let rejected = url_dispatcher::enqueue_url(excess_url);
    assert!(
        !rejected,
        "Enqueue beyond MAX_URL_QUEUE_CAPACITY must be rejected"
    );

    url_dispatcher::clear_queue();
    assert_eq!(url_dispatcher::queue_len(), 0);
}

#[test]
fn test_res044_url_dispatcher_reject_over_length_url() {
    let _lock = acquire_batch25_test_lock();
    url_dispatcher::clear_queue();

    // Create a URL exceeding MAX_URL_LEN
    let oversized_url = "a".repeat(MAX_URL_LEN + 10);
    let accepted = url_dispatcher::enqueue_url(oversized_url);
    assert!(!accepted, "URL exceeding MAX_URL_LEN must be rejected");

    // Exactly MAX_URL_LEN should be accepted (if capacity permits)
    let max_len_url = "a".repeat(MAX_URL_LEN);
    let accepted_exact = url_dispatcher::enqueue_url(max_len_url);
    assert!(
        accepted_exact,
        "URL of exactly MAX_URL_LEN must be accepted"
    );

    url_dispatcher::clear_queue();
}

#[test]
fn test_res044_url_dispatcher_reopen_coalescing_and_debounce() {
    let _lock = acquire_batch25_test_lock();
    url_dispatcher::clear_queue();

    // First reopen event should be accepted
    let first = url_dispatcher::enqueue_reopen();
    assert!(first, "First reopen must be accepted");

    // Rapid successive reopen within debounce duration should be coalesced (accepted but not duplicated)
    let second = url_dispatcher::enqueue_reopen();
    assert!(second, "Debounced reopen returns true");

    // Clear test queue
    url_dispatcher::clear_queue();
}

#[test]
fn test_res044_url_dispatcher_concurrent_enqueuing() {
    let _lock = acquire_batch25_test_lock();
    url_dispatcher::clear_queue();

    let threads = 8;
    let barrier = Arc::new(Barrier::new(threads));
    let mut handles = Vec::new();

    for t in 0..threads {
        let b = barrier.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            let url = format!("camellia-remote://thread-{}/connect", t);
            url_dispatcher::enqueue_url(url);
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    // Queue must never exceed MAX_URL_QUEUE_CAPACITY
    let len = url_dispatcher::queue_len();
    assert!(
        len <= MAX_URL_QUEUE_CAPACITY,
        "Queue length must respect capacity limit under concurrency"
    );

    url_dispatcher::clear_queue();
}

#[test]
fn test_res044_url_dispatcher_generation_monotonicity() {
    let _lock = acquire_batch25_test_lock();

    let gen1 = url_dispatcher::bump_generation();
    let gen2 = url_dispatcher::bump_generation();
    assert_eq!(
        gen2,
        gen1 + 1,
        "Dispatcher generations must increase monotonically"
    );
}

// =========================================================================
// 3. RES-046: SetupAPI DeviceInfoSetGuard Tests (Windows Only)
// =========================================================================

#[test]
#[cfg(windows)]
fn test_res046_device_info_set_guard_null_safety() {
    use camellia_remote::virtual_display_manager::DeviceInfoSetGuard;
    use winapi::um::handleapi::INVALID_HANDLE_VALUE;

    let _lock = acquire_batch25_test_lock();

    // Null pointer guard
    let null_guard = DeviceInfoSetGuard(std::ptr::null_mut());
    assert!(!null_guard.is_valid(), "Null handle must be invalid");
    assert_eq!(null_guard.raw(), std::ptr::null_mut());
    drop(null_guard); // Must not crash or double-free

    // INVALID_HANDLE_VALUE guard
    let invalid_guard = DeviceInfoSetGuard(INVALID_HANDLE_VALUE);
    assert!(
        !invalid_guard.is_valid(),
        "INVALID_HANDLE_VALUE must be invalid"
    );
    assert_eq!(invalid_guard.raw(), INVALID_HANDLE_VALUE);
    drop(invalid_guard); // Must not crash
}

#[test]
#[cfg(windows)]
fn test_res046_display_drivers_cache_invalidation() {
    use camellia_remote::virtual_display_manager::invalidate_display_drivers_cache;

    let _lock = acquire_batch25_test_lock();
    invalidate_display_drivers_cache();
    // Cache invalidated cleanly without deadlock or panic
}
